<#
.SYNOPSIS
    Manages the core backup operations for a single backup job within the PoSh-Backup solution.
    This includes gathering effective job configurations (via ConfigManager.psm1), handling VSS
    (via VssManager.psm1), executing 7-Zip (via 7ZipManager.psm1), applying retention policies
    (via RetentionManager.psm1), and checking destination free space (via Utils.psm1).
    It also orchestrates password retrieval and hook script execution.

.DESCRIPTION
    The Operations module encapsulates the entire lifecycle of processing a single, defined backup job.
    It acts as the workhorse for each backup task, taking a job's configuration and performing all
    necessary steps to create an archive.

    The primary exported function, Invoke-PoShBackupJob, performs the following sequence:
    1.  Gathers effective configuration (ConfigManager.psm1).
    2.  Validates/creates destination directory.
    3.  Retrieves archive password (PasswordManager.psm1).
    4.  Executes pre-backup hook scripts.
    5.  Handles VSS shadow copy creation if enabled (VssManager.psm1).
    6.  Checks destination free space (Utils.psm1).
    7.  Applies retention policy (RetentionManager.psm1).
    8.  Constructs 7-Zip arguments (7ZipManager.psm1).
    9.  Executes 7-Zip for archiving (7ZipManager.psm1).
    10. Optionally tests archive integrity (7ZipManager.psm1).
    11. Cleans up VSS shadow copies (VssManager.psm1).
    12. Securely disposes of temporary password files.
    13. Executes post-backup hook scripts.
    14. Returns job status.

    This module relies on other PoSh-Backup modules like Utils.psm1, PasswordManager.psm1,
    7ZipManager.psm1, VssManager.psm1, RetentionManager.psm1, and ConfigManager.psm1.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.12.0 # Moved Test-DestinationFreeSpace to Utils.psm1.
    DateCreated:    10-May-2025
    LastModified:   17-May-2025
    Purpose:        Handles the execution logic for individual backup jobs.
    Prerequisites:  PowerShell 5.1+, 7-Zip installed.
                    All core PoSh-Backup modules.
                    Administrator privileges for VSS.
#>

#region --- Main Job Processing Function ---
function Invoke-PoShBackupJob {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)]
        [string]$JobName,
        [Parameter(Mandatory=$true)]
        [hashtable]$JobConfig, 
        [Parameter(Mandatory=$true)]
        [hashtable]$GlobalConfig, 
        [Parameter(Mandatory=$true)]
        [hashtable]$CliOverrides,
        [Parameter(Mandatory=$true)]
        [string]$PSScriptRootForPaths,
        [Parameter(Mandatory=$true)]
        [string]$ActualConfigFile,
        [Parameter(Mandatory=$true)]
        [ref]$JobReportDataRef,
        [Parameter(Mandatory=$false)]
        [switch]$IsSimulateMode
    )

    $currentJobStatus = "SUCCESS" 
    $tempPasswordFilePath = $null
    $FinalArchivePath = $null
    $VSSPathsInUse = $null 
    $reportData = $JobReportDataRef.Value 
    $reportData.IsSimulationReport = $IsSimulateMode.IsPresent 

    if (-not ($reportData.PSObject.Properties.Name -contains 'ScriptStartTime')) {
        $reportData['ScriptStartTime'] = Get-Date 
    }

    $plainTextPasswordForJob = $null 

    try {
        if (-not (Get-Command Get-PoShBackupJobEffectiveConfiguration -ErrorAction SilentlyContinue)) {
            throw "CRITICAL: Function 'Get-PoShBackupJobEffectiveConfiguration' from ConfigManager.psm1 is not available."
        }
        $effectiveJobConfig = Get-PoShBackupJobEffectiveConfiguration -JobConfig $JobConfig -GlobalConfig $GlobalConfig -CliOverrides $CliOverrides -JobReportDataRef $JobReportDataRef

        Write-LogMessage " - Job Settings for '$JobName' (derived from configuration and CLI overrides):"
        Write-LogMessage "   - Effective Source Path(s): $(if ($effectiveJobConfig.OriginalSourcePath -is [array]) {$effectiveJobConfig.OriginalSourcePath -join '; '} else {$effectiveJobConfig.OriginalSourcePath})"
        Write-LogMessage "   - Destination Directory  : $($effectiveJobConfig.DestinationDir)"
        Write-LogMessage "   - Archive Base Name      : $($effectiveJobConfig.BaseFileName)"
        Write-LogMessage "   - Archive Password Method: $($effectiveJobConfig.ArchivePasswordMethod)"

        if ([string]::IsNullOrWhiteSpace($effectiveJobConfig.DestinationDir)) {
            Write-LogMessage "FATAL: Destination directory for job '$JobName' is not defined. Cannot proceed." -Level ERROR; throw "DestinationDir missing for job '$JobName'."
        }
        if (-not (Test-Path -LiteralPath $effectiveJobConfig.DestinationDir -PathType Container)) {
            Write-LogMessage "[INFO] Destination directory '$($effectiveJobConfig.DestinationDir)' for job '$JobName' does not exist. Attempting to create..."
            if (-not $IsSimulateMode.IsPresent) {
                if ($PSCmdlet.ShouldProcess($effectiveJobConfig.DestinationDir, "Create Directory")) {
                    try { New-Item -Path $effectiveJobConfig.DestinationDir -ItemType Directory -Force -ErrorAction Stop | Out-Null; Write-LogMessage "  - Destination directory created successfully." -Level SUCCESS }
                    catch { Write-LogMessage "FATAL: Failed to create destination directory '$($effectiveJobConfig.DestinationDir)'. Error: $($_.Exception.Message)" -Level ERROR; throw "Failed to create destination directory for job '$JobName'." }
                }
            } else {
                Write-LogMessage "SIMULATE: Would create destination directory '$($effectiveJobConfig.DestinationDir)'." -Level SIMULATE
            }
        }

        $isPasswordRequiredOrConfigured = ($effectiveJobConfig.ArchivePasswordMethod.ToString().ToUpperInvariant() -ne "NONE") -or $effectiveJobConfig.UsePassword
        $effectiveJobConfig.PasswordInUseFor7Zip = $false 

        if ($isPasswordRequiredOrConfigured) {
            try {
                $passwordManagerModulePath = Join-Path -Path $PSScriptRootForPaths -ChildPath "Modules\PasswordManager.psm1"
                if (-not (Test-Path -LiteralPath $passwordManagerModulePath -PathType Leaf)) {
                    throw "PasswordManager.psm1 module not found at '$passwordManagerModulePath'. This module is required for password handling."
                }
                Import-Module -Name $passwordManagerModulePath -Force -ErrorAction Stop

                $passwordParams = @{
                    JobConfigForPassword = $effectiveJobConfig
                    JobName              = $JobName
                    IsSimulateMode       = $IsSimulateMode.IsPresent
                    Logger               = ${function:Write-LogMessage}
                }
                $passwordResult = Get-PoShBackupArchivePassword @passwordParams
                $reportData.PasswordSource = $passwordResult.PasswordSource 

                if ($null -ne $passwordResult -and (-not [string]::IsNullOrWhiteSpace($passwordResult.PlainTextPassword))) {
                    $plainTextPasswordForJob = $passwordResult.PlainTextPassword
                    $effectiveJobConfig.PasswordInUseFor7Zip = $true
                    if ($IsSimulateMode.IsPresent) {
                        $tempPasswordFilePath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "simulated_poshbackup_pass.tmp") 
                        Write-LogMessage "SIMULATE: Would write password (obtained via $($reportData.PasswordSource)) to temporary file '$tempPasswordFilePath' for 7-Zip." -Level SIMULATE
                    } else {
                        if ($PSCmdlet.ShouldProcess("Temporary Password File", "Create and Write Password (details in DEBUG log)")) {
                            $tempPasswordFilePath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
                            Set-Content -Path $tempPasswordFilePath -Value $plainTextPasswordForJob -Encoding UTF8 -Force -ErrorAction Stop
                            Write-LogMessage "   - Password (obtained via $($reportData.PasswordSource)) written to temporary file '$tempPasswordFilePath' for 7-Zip." -Level DEBUG
                        }
                    }
                } elseif ($isPasswordRequiredOrConfigured -and $effectiveJobConfig.ArchivePasswordMethod.ToString().ToUpperInvariant() -ne "NONE" -and (-not $IsSimulateMode.IsPresent)) {
                     Write-LogMessage "FATAL: Password was required for job '$JobName' via method '$($effectiveJobConfig.ArchivePasswordMethod)' but could not be obtained or was empty." -Level ERROR
                     throw "Password unavailable/empty for job '$JobName' using method '$($effectiveJobConfig.ArchivePasswordMethod)'."
                }
            } catch {
                Write-LogMessage "FATAL: Error during password retrieval process for job '$JobName'. Error: $($_.Exception.ToString())" -Level ERROR
                throw 
            }
        } elseif ($effectiveJobConfig.ArchivePasswordMethod.ToString().ToUpperInvariant() -eq "NONE") {
            $reportData.PasswordSource = "None (Explicitly Configured)"
        }

        Invoke-HookScript -ScriptPath $effectiveJobConfig.PreBackupScriptPath -HookType "PreBackup" `
                          -HookParameters @{ JobName = $JobName; Status = "PreBackup"; ConfigFile = $ActualConfigFile; SimulateMode = $IsSimulateMode.IsPresent } `
                          -IsSimulateMode:$IsSimulateMode

        $currentJobSourcePathFor7Zip = $effectiveJobConfig.OriginalSourcePath 
        if ($effectiveJobConfig.JobEnableVSS) {
            Write-LogMessage "`n[INFO] VSS (Volume Shadow Copy Service) is enabled for job '$JobName'." -Level "VSS"
            if (-not (Test-AdminPrivilege)) { 
                Write-LogMessage "FATAL: VSS requires Administrator privileges for job '$JobName', but script is not running as Admin." -Level ERROR
                throw "VSS requires Administrator privileges for job '$JobName'."
            }
            if (-not (Get-Command New-VSSShadowCopy -ErrorAction SilentlyContinue)) { throw "CRITICAL: Function 'New-VSSShadowCopy' from VssManager.psm1 is not available."}

            $vssParams = @{
                SourcePathsToShadow = if ($effectiveJobConfig.OriginalSourcePath -is [array]) {$effectiveJobConfig.OriginalSourcePath} else {@($effectiveJobConfig.OriginalSourcePath)}
                VSSContextOption = $effectiveJobConfig.JobVSSContextOption
                MetadataCachePath = $effectiveJobConfig.VSSMetadataCachePath
                PollingTimeoutSeconds = $effectiveJobConfig.VSSPollingTimeoutSeconds
                PollingIntervalSeconds = $effectiveJobConfig.VSSPollingIntervalSeconds
                IsSimulateMode = $IsSimulateMode.IsPresent
            }
            $VSSPathsInUse = New-VSSShadowCopy @vssParams 

            if ($null -eq $VSSPathsInUse -or $VSSPathsInUse.Count -eq 0) {
                if (-not $IsSimulateMode.IsPresent) {
                    Write-LogMessage "[ERROR] VSS shadow copy creation failed or returned no usable paths for job '$JobName'. Attempting backup using original source paths." -Level ERROR
                    $reportData.VSSStatus = "Failed to create/map shadows"
                    if ($currentJobStatus -ne "FAILURE") { $currentJobStatus = "WARNINGS" }
                } else {
                     Write-LogMessage "SIMULATE: VSS shadow copy creation would have been attempted for job '$JobName'. Simulating use of original paths." -Level SIMULATE
                     $reportData.VSSStatus = "Simulated (No Shadows Created/Needed)"
                }
            } else {
                Write-LogMessage "  - VSS shadow copies successfully created/mapped for job '$JobName'. Using shadow paths for backup." -Level VSS
                $currentJobSourcePathFor7Zip = if ($effectiveJobConfig.OriginalSourcePath -is [array]) {
                    $effectiveJobConfig.OriginalSourcePath | ForEach-Object {
                        if ($VSSPathsInUse.ContainsKey($_)) { $VSSPathsInUse[$_] } else { $_ } 
                    }
                } else {
                    if ($VSSPathsInUse.ContainsKey($effectiveJobConfig.OriginalSourcePath)) { $VSSPathsInUse[$effectiveJobConfig.OriginalSourcePath] } else { $effectiveJobConfig.OriginalSourcePath }
                }
                $reportData.VSSStatus = if ($IsSimulateMode.IsPresent) { "Simulated (Used)" } else { "Used" }
                $reportData.VSSShadowPaths = $VSSPathsInUse 
            }
        } else {
            $reportData.VSSStatus = "Not Enabled"
        }
        $reportData.EffectiveSourcePath = if ($currentJobSourcePathFor7Zip -is [array]) {$currentJobSourcePathFor7Zip} else {@($currentJobSourcePathFor7Zip)}

        Write-LogMessage "`n[INFO] Performing Pre-Backup Operations for job '$JobName'..."
        Write-LogMessage "   - Using source(s) for 7-Zip: $(if ($currentJobSourcePathFor7Zip -is [array]) {($currentJobSourcePathFor7Zip | Where-Object {$_}) -join '; '} else {$currentJobSourcePathFor7Zip})"

        # Test-DestinationFreeSpace is now in Utils.psm1
        if (-not (Get-Command Test-DestinationFreeSpace -ErrorAction SilentlyContinue)) { throw "CRITICAL: Function 'Test-DestinationFreeSpace' from Utils.psm1 is not available."}
        if (-not (Test-DestinationFreeSpace -DestDir $effectiveJobConfig.DestinationDir -MinRequiredGB $effectiveJobConfig.JobMinimumRequiredFreeSpaceGB -ExitOnLow $effectiveJobConfig.JobExitOnLowSpace -IsSimulateMode:$IsSimulateMode)) {
            throw "Low disk space condition met and configured to halt job '$JobName'." 
        }

        $DateString = Get-Date -Format $effectiveJobConfig.JobArchiveDateFormat
        $ArchiveFileName = "$($effectiveJobConfig.BaseFileName) [$DateString]$($effectiveJobConfig.JobArchiveExtension)"
        $FinalArchivePath = Join-Path -Path $effectiveJobConfig.DestinationDir -ChildPath $ArchiveFileName
        $reportData.FinalArchivePath = $FinalArchivePath
        Write-LogMessage "`n[INFO] Target Archive for job '$JobName': $FinalArchivePath"

        $vbLoaded = $false 
        if ($effectiveJobConfig.DeleteToRecycleBin) {
            try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop; $vbLoaded = $true }
            catch { Write-LogMessage "[WARNING] Failed to load Microsoft.VisualBasic assembly for Recycle Bin functionality. Will use permanent deletion. Error: $($_.Exception.Message)" -Level WARNING }
        }
        
        if (-not (Get-Command Invoke-BackupRetentionPolicy -ErrorAction SilentlyContinue)) { throw "CRITICAL: Function 'Invoke-BackupRetentionPolicy' from RetentionManager.psm1 is not available."}
        Invoke-BackupRetentionPolicy -DestinationDirectory $effectiveJobConfig.DestinationDir `
                                     -ArchiveBaseFileName $effectiveJobConfig.BaseFileName `
                                     -ArchiveExtension $effectiveJobConfig.JobArchiveExtension `
                                     -RetentionCountToKeep $effectiveJobConfig.RetentionCount `
                                     -SendToRecycleBin $effectiveJobConfig.DeleteToRecycleBin `
                                     -VBAssemblyLoaded $vbLoaded `
                                     -IsSimulateMode:$IsSimulateMode

        if (-not (Get-Command Get-PoShBackup7ZipArgument -ErrorAction SilentlyContinue)) { throw "CRITICAL: Function 'Get-PoShBackup7ZipArgument' from 7ZipManager.psm1 is not available." }
        $sevenZipArgsArray = Get-PoShBackup7ZipArgument -EffectiveConfig $effectiveJobConfig `
                                                        -FinalArchivePath $FinalArchivePath `
                                                        -CurrentJobSourcePathFor7Zip $currentJobSourcePathFor7Zip `
                                                        -TempPasswordFile $tempPasswordFilePath

        $sevenZipPathGlobal = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'SevenZipPath' 
        if (-not (Get-Command Invoke-7ZipOperation -ErrorAction SilentlyContinue)) { throw "CRITICAL: Function 'Invoke-7ZipOperation' from 7ZipManager.psm1 is not available." }
        $zipOpParams = @{
            SevenZipPathExe = $sevenZipPathGlobal
            SevenZipArguments = $sevenZipArgsArray
            ProcessPriority = $effectiveJobConfig.JobSevenZipProcessPriority
            HideOutput = $effectiveJobConfig.HideSevenZipOutput
            MaxRetries = $effectiveJobConfig.JobMaxRetryAttempts
            RetryDelaySeconds = $effectiveJobConfig.JobRetryDelaySeconds
            EnableRetries = $effectiveJobConfig.JobEnableRetries
            IsSimulateMode = $IsSimulateMode.IsPresent
        }
        $sevenZipResult = Invoke-7ZipOperation @zipOpParams

        $reportData.SevenZipExitCode = $sevenZipResult.ExitCode
        $reportData.CompressionTime = if ($null -ne $sevenZipResult.ElapsedTime) {$sevenZipResult.ElapsedTime.ToString()} else {"N/A"}
        $reportData.RetryAttemptsMade = $sevenZipResult.AttemptsMade

        $archiveSize = "N/A (Simulated)"
        if (-not $IsSimulateMode.IsPresent -and (Test-Path -LiteralPath $FinalArchivePath -PathType Leaf)) {
             $archiveSize = Get-ArchiveSizeFormatted -PathToArchive $FinalArchivePath
        } elseif ($IsSimulateMode.IsPresent) {
            $archiveSize = "0 Bytes (Simulated)" 
        }
        $reportData.ArchiveSizeFormatted = $archiveSize

        if ($sevenZipResult.ExitCode -eq 0) { # Success
        } elseif ($sevenZipResult.ExitCode -eq 1) { # Warning
            $currentJobStatus = "WARNINGS"
        } else { # Failure
            $currentJobStatus = "FAILURE"
        }

        $reportData.ArchiveTested = $effectiveJobConfig.JobTestArchiveAfterCreation 
        if ($effectiveJobConfig.JobTestArchiveAfterCreation -and ($currentJobStatus -ne "FAILURE") -and (-not $IsSimulateMode.IsPresent) -and (Test-Path -LiteralPath $FinalArchivePath -PathType Leaf)) {
            if (-not (Get-Command Test-7ZipArchive -ErrorAction SilentlyContinue)) { throw "CRITICAL: Function 'Test-7ZipArchive' from 7ZipManager.psm1 is not available." }
            $testArchiveParams = @{
                SevenZipPathExe = $sevenZipPathGlobal
                ArchivePath = $FinalArchivePath
                TempPasswordFile = $tempPasswordFilePath 
                ProcessPriority = $effectiveJobConfig.JobSevenZipProcessPriority
                HideOutput = $effectiveJobConfig.HideSevenZipOutput
                MaxRetries = $effectiveJobConfig.JobMaxRetryAttempts
                RetryDelaySeconds = $effectiveJobConfig.JobRetryDelaySeconds
                EnableRetries = $effectiveJobConfig.JobEnableRetries
            }
            $testResult = Test-7ZipArchive @testArchiveParams

            if ($testResult.ExitCode -eq 0) {
                $reportData.ArchiveTestResult = "PASSED"
            } else {
                $reportData.ArchiveTestResult = "FAILED (7-Zip Test Exit Code: $($testResult.ExitCode))"
                if ($currentJobStatus -ne "FAILURE") {$currentJobStatus = "WARNINGS"} 
            }
            $reportData.TestRetryAttemptsMade = $testResult.AttemptsMade
        } elseif ($effectiveJobConfig.JobTestArchiveAfterCreation) {
             $reportData.ArchiveTestResult = if($IsSimulateMode.IsPresent){"Not Performed (Simulation Mode)"} else {"Not Performed (Archive Missing or Prior Compression Error)"}
        } else {
            $reportData.ArchiveTestResult = "Not Configured" 
        }

    } catch {
        Write-LogMessage "ERROR during processing of job '$JobName': $($_.Exception.ToString())" -Level ERROR
        $currentJobStatus = "FAILURE" 
        $reportData.ErrorMessage = $_.Exception.ToString() 
    } finally {
        if ($null -ne $VSSPathsInUse) { 
            if (-not (Get-Command Remove-VSSShadowCopy -ErrorAction SilentlyContinue)) {
                Write-LogMessage "CRITICAL: Function 'Remove-VSSShadowCopy' from VssManager.psm1 is not available. VSS Shadows may not be cleaned up." -Level ERROR
            } else {
                Remove-VSSShadowCopy -IsSimulateMode:$IsSimulateMode.IsPresent 
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($plainTextPasswordForJob)) {
            try {
                $plainTextPasswordForJob = $null
                Remove-Variable plainTextPasswordForJob -Scope Script -ErrorAction SilentlyContinue
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
                Write-LogMessage "   - Plain text password for job '$JobName' cleared from Operations module memory." -Level DEBUG
            } catch {
                Write-LogMessage "[WARNING] Exception while clearing plain text password from Operations module memory for job '$JobName'. Error: $($_.Exception.Message)" -Level WARNING
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($tempPasswordFilePath) -and (Test-Path -LiteralPath $tempPasswordFilePath -PathType Leaf) `
            -and -not ($IsSimulateMode.IsPresent -and $tempPasswordFilePath.EndsWith("simulated_poshbackup_pass.tmp")) ) { 
            if ($PSCmdlet.ShouldProcess($tempPasswordFilePath, "Delete Temporary Password File")) {
                try {
                    Remove-Item -LiteralPath $tempPasswordFilePath -Force -ErrorAction Stop
                    Write-LogMessage "   - Temporary password file '$tempPasswordFilePath' deleted successfully." -Level DEBUG
                }
                catch {
                    Write-LogMessage "[WARNING] Failed to delete temporary password file '$tempPasswordFilePath'. Manual deletion may be required. Error: $($_.Exception.Message)" -Level "WARNING"
                }
            }
        }

        if ($IsSimulateMode.IsPresent -and $currentJobStatus -ne "FAILURE" -and $currentJobStatus -ne "WARNINGS") {
            $reportData.OverallStatus = "SIMULATED_COMPLETE"
        } else {
            $reportData.OverallStatus = $currentJobStatus
        }

        $reportData.ScriptEndTime = Get-Date
        if (($reportData.PSObject.Properties.Name -contains 'ScriptStartTime') -and ($null -ne $reportData.ScriptStartTime)) {
            $reportData.TotalDuration = $reportData.ScriptEndTime - $reportData.ScriptStartTime
        } else {
            $reportData.TotalDuration = "N/A (Timing data incomplete)"
        }

        $hookArgsForExternalScript = @{
            JobName = $JobName; Status = $reportData.OverallStatus; ArchivePath = $FinalArchivePath;
            ConfigFile = $ActualConfigFile; SimulateMode = $IsSimulateMode.IsPresent
        }

        if ($reportData.OverallStatus -in @("SUCCESS", "WARNINGS", "SIMULATED_COMPLETE") ) {
            Invoke-HookScript -ScriptPath $effectiveJobConfig.PostBackupScriptOnSuccessPath -HookType "PostBackupOnSuccess" -HookParameters $hookArgsForExternalScript -IsSimulateMode:$IsSimulateMode.IsPresent
        } else { 
            Invoke-HookScript -ScriptPath $effectiveJobConfig.PostBackupScriptOnFailurePath -HookType "PostBackupOnFailure" -HookParameters $hookArgsForExternalScript -IsSimulateMode:$IsSimulateMode.IsPresent
        }
        Invoke-HookScript -ScriptPath $effectiveJobConfig.PostBackupScriptAlwaysPath -HookType "PostBackupAlways" -HookParameters $hookArgsForExternalScript -IsSimulateMode:$IsSimulateMode.IsPresent
    }

    return @{ Status = $currentJobStatus } 
}
#endregion

#region --- Removed Functions ---
# Test-DestinationFreeSpace has been moved to Modules\Utils.psm1
#endregion

#region --- Exported Functions ---
Export-ModuleMember -Function Invoke-PoShBackupJob
#endregion
