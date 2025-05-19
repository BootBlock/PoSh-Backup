<#
.SYNOPSIS
    Manages the core backup operations for a single backup job within the PoSh-Backup solution.
    This includes gathering effective job configurations (via ConfigManager.psm1), handling VSS
    (via VssManager.psm1), executing 7-Zip (via 7ZipManager.psm1), applying retention policies
    (via RetentionManager.psm1), checking destination free space (via Utils.psm1), and orchestrating
    hook script execution (via HookManager.psm1).

.DESCRIPTION
    The Operations module encapsulates the entire lifecycle of processing a single, defined backup job.
    It acts as the workhorse for each backup task, taking a job's configuration and performing all
    necessary steps to create an archive.

    The primary exported function, Invoke-PoShBackupJob, performs the following sequence:
    1.  Gathers effective configuration (ConfigManager.psm1).
    2.  Validates/creates destination directory.
    3.  Retrieves archive password (PasswordManager.psm1).
    4.  Executes pre-backup hook scripts (HookManager.psm1).
    5.  Handles VSS shadow copy creation if enabled (VssManager.psm1).
    6.  Checks destination free space (Utils.psm1).
    7.  Applies retention policy (RetentionManager.psm1).
    8.  Constructs 7-Zip arguments (7ZipManager.psm1).
    9.  Executes 7-Zip for archiving (7ZipManager.psm1).
    10. Optionally tests archive integrity (7ZipManager.psm1).
    11. Cleans up VSS shadow copies (VssManager.psm1).
    12. Securely disposes of temporary password files.
    13. Executes post-backup hook scripts (HookManager.psm1).
    14. Returns job status.

    This module relies on other PoSh-Backup modules like Utils.psm1, PasswordManager.psm1,
    7ZipManager.psm1, VssManager.psm1, RetentionManager.psm1, ConfigManager.psm1, and HookManager.psm1.
    Functions within this module requiring logging accept a -Logger parameter.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.13.3 # Improved VSS status reporting for network paths.
    DateCreated:    10-May-2025
    LastModified:   19-May-2025
    Purpose:        Handles the execution logic for individual backup jobs.
    Prerequisites:  PowerShell 5.1+, 7-Zip installed.
                    All core PoSh-Backup modules.
                    Administrator privileges for VSS.
#>

# Explicitly import Utils.psm1 to ensure its functions are available.
# $PSScriptRoot here refers to the directory of Operations.psm1 (Modules).
try {
    Import-Module -Name (Join-Path $PSScriptRoot "Utils.psm1") -Force -ErrorAction Stop
} catch {
    # If this fails, the module cannot function. Write-Error is appropriate.
    Write-Error "Operations.psm1 FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw 
}

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
        [switch]$IsSimulateMode,
        [Parameter(Mandatory=$true)]
        [scriptblock]$Logger # Added Logger parameter
    )

    # Internal helper to use the passed-in logger consistently
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if ($null -ne $ForegroundColour) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    # Defensive PSSA appeasement line
    & $LocalWriteLog -Message "Invoke-PoShBackupJob: Logger parameter active for job '$JobName'." -Level "DEBUG" -ErrorAction SilentlyContinue


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
        # Ensure HookManager.psm1 is available if not already loaded by main script
        if (-not (Get-Command Invoke-PoShBackupHook -ErrorAction SilentlyContinue)) {
            $hookManagerPath = Join-Path -Path $PSScriptRootForPaths -ChildPath "Modules\HookManager.psm1"
            if (Test-Path -LiteralPath $hookManagerPath -PathType Leaf) {
                try {
                    Import-Module -Name $hookManagerPath -Force -ErrorAction Stop
                    & $LocalWriteLog -Message "[DEBUG] Operations: Dynamically imported HookManager.psm1." -Level "DEBUG"
                } catch {
                    throw "CRITICAL: Operations: Could not load dependent module HookManager.psm1 from '$hookManagerPath'. Error: $($_.Exception.Message)"
                }
            } else {
                throw "CRITICAL: Operations: HookManager.psm1 not found at '$hookManagerPath'. This module is now required for hook script execution."
            }
        }
        if (-not (Get-Command Invoke-PoShBackupHook -ErrorAction SilentlyContinue)) {
            throw "CRITICAL: Operations: Function 'Invoke-PoShBackupHook' from HookManager.psm1 is definitively not available even after import attempt."
        }


        if (-not (Get-Command Get-PoShBackupJobEffectiveConfiguration -ErrorAction SilentlyContinue)) {
            throw "CRITICAL: Function 'Get-PoShBackupJobEffectiveConfiguration' from ConfigManager.psm1 is not available."
        }
        # Pass the logger to Get-PoShBackupJobEffectiveConfiguration
        $effectiveJobConfig = Get-PoShBackupJobEffectiveConfiguration -JobConfig $JobConfig -GlobalConfig $GlobalConfig -CliOverrides $CliOverrides -JobReportDataRef $JobReportDataRef -Logger $Logger

        & $LocalWriteLog -Message " - Job Settings for '$JobName' (derived from configuration and CLI overrides):"
        & $LocalWriteLog -Message "   - Effective Source Path(s): $(if ($effectiveJobConfig.OriginalSourcePath -is [array]) {$effectiveJobConfig.OriginalSourcePath -join '; '} else {$effectiveJobConfig.OriginalSourcePath})"
        & $LocalWriteLog -Message "   - Destination Directory  : $($effectiveJobConfig.DestinationDir)"
        & $LocalWriteLog -Message "   - Archive Base Name      : $($effectiveJobConfig.BaseFileName)"
        & $LocalWriteLog -Message "   - Archive Password Method: $($effectiveJobConfig.ArchivePasswordMethod)"
        & $LocalWriteLog -Message "   - Treat 7-Zip Warnings as Success: $($effectiveJobConfig.TreatSevenZipWarningsAsSuccess)"


        if ([string]::IsNullOrWhiteSpace($effectiveJobConfig.DestinationDir)) {
            & $LocalWriteLog -Message "FATAL: Destination directory for job '$JobName' is not defined. Cannot proceed." -Level ERROR; throw "DestinationDir missing for job '$JobName'."
        }
        if (-not (Test-Path -LiteralPath $effectiveJobConfig.DestinationDir -PathType Container)) {
            & $LocalWriteLog -Message "[INFO] Destination directory '$($effectiveJobConfig.DestinationDir)' for job '$JobName' does not exist. Attempting to create..."
            if (-not $IsSimulateMode.IsPresent) {
                if ($PSCmdlet.ShouldProcess($effectiveJobConfig.DestinationDir, "Create Directory")) {
                    try { New-Item -Path $effectiveJobConfig.DestinationDir -ItemType Directory -Force -ErrorAction Stop | Out-Null; & $LocalWriteLog -Message "  - Destination directory created successfully." -Level SUCCESS }
                    catch { & $LocalWriteLog -Message "FATAL: Failed to create destination directory '$($effectiveJobConfig.DestinationDir)'. Error: $($_.Exception.Message)" -Level ERROR; throw "Failed to create destination directory for job '$JobName'." }
                }
            } else {
                & $LocalWriteLog -Message "SIMULATE: Would create destination directory '$($effectiveJobConfig.DestinationDir)'." -Level SIMULATE
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
                    Logger               = $Logger # Pass the logger
                }
                $passwordResult = Get-PoShBackupArchivePassword @passwordParams
                $reportData.PasswordSource = $passwordResult.PasswordSource 

                if ($null -ne $passwordResult -and (-not [string]::IsNullOrWhiteSpace($passwordResult.PlainTextPassword))) {
                    $plainTextPasswordForJob = $passwordResult.PlainTextPassword
                    $effectiveJobConfig.PasswordInUseFor7Zip = $true
                    if ($IsSimulateMode.IsPresent) {
                        $tempPasswordFilePath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "simulated_poshbackup_pass.tmp") 
                        & $LocalWriteLog -Message "SIMULATE: Would write password (obtained via $($reportData.PasswordSource)) to temporary file '$tempPasswordFilePath' for 7-Zip." -Level SIMULATE
                    } else {
                        if ($PSCmdlet.ShouldProcess("Temporary Password File", "Create and Write Password (details in DEBUG log)")) {
                            $tempPasswordFilePath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
                            Set-Content -Path $tempPasswordFilePath -Value $plainTextPasswordForJob -Encoding UTF8 -Force -ErrorAction Stop
                            & $LocalWriteLog -Message "   - Password (obtained via $($reportData.PasswordSource)) written to temporary file '$tempPasswordFilePath' for 7-Zip." -Level DEBUG
                        }
                    }
                } elseif ($isPasswordRequiredOrConfigured -and $effectiveJobConfig.ArchivePasswordMethod.ToString().ToUpperInvariant() -ne "NONE" -and (-not $IsSimulateMode.IsPresent)) {
                     & $LocalWriteLog -Message "FATAL: Password was required for job '$JobName' via method '$($effectiveJobConfig.ArchivePasswordMethod)' but could not be obtained or was empty." -Level ERROR
                     throw "Password unavailable/empty for job '$JobName' using method '$($effectiveJobConfig.ArchivePasswordMethod)'."
                }
            } catch {
                & $LocalWriteLog -Message "FATAL: Error during password retrieval process for job '$JobName'. Error: $($_.Exception.ToString())" -Level ERROR
                throw 
            }
        } elseif ($effectiveJobConfig.ArchivePasswordMethod.ToString().ToUpperInvariant() -eq "NONE") {
            $reportData.PasswordSource = "None (Explicitly Configured)"
        }

        Invoke-PoShBackupHook -ScriptPath $effectiveJobConfig.PreBackupScriptPath -HookType "PreBackup" `
                              -HookParameters @{ JobName = $JobName; Status = "PreBackup"; ConfigFile = $ActualConfigFile; SimulateMode = $IsSimulateMode.IsPresent } `
                              -IsSimulateMode:$IsSimulateMode -Logger $Logger


        $currentJobSourcePathFor7Zip = $effectiveJobConfig.OriginalSourcePath 
        if ($effectiveJobConfig.JobEnableVSS) {
            & $LocalWriteLog -Message "`n[INFO] VSS (Volume Shadow Copy Service) is enabled for job '$JobName'." -Level "VSS"
            if (-not (Test-AdminPrivilege -Logger $Logger)) { # Test-AdminPrivilege is from Utils.psm1
                & $LocalWriteLog -Message "FATAL: VSS requires Administrator privileges for job '$JobName', but script is not running as Admin." -Level ERROR
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
                Logger = $Logger 
            }
            $VSSPathsInUse = New-VSSShadowCopy @vssParams 

            # $currentJobSourcePathFor7Zip remains original path if $VSSPathsInUse is null or doesn't map
            if ($null -ne $VSSPathsInUse -and $VSSPathsInUse.Count -gt 0) {
                & $LocalWriteLog -Message "  - VSS shadow copies created/mapped. Attempting to use shadow paths for backup." -Level VSS
                $currentJobSourcePathFor7Zip = if ($effectiveJobConfig.OriginalSourcePath -is [array]) {
                    $effectiveJobConfig.OriginalSourcePath | ForEach-Object {
                        if ($VSSPathsInUse.ContainsKey($_) -and $VSSPathsInUse[$_] -ne $_) { $VSSPathsInUse[$_] } else { $_ } # Use shadow path if different, else original
                    }
                } else {
                    if ($VSSPathsInUse.ContainsKey($effectiveJobConfig.OriginalSourcePath) -and $VSSPathsInUse[$effectiveJobConfig.OriginalSourcePath] -ne $effectiveJobConfig.OriginalSourcePath) {
                         $VSSPathsInUse[$effectiveJobConfig.OriginalSourcePath]
                    } else {
                         $effectiveJobConfig.OriginalSourcePath
                    }
                }
                $reportData.VSSShadowPaths = $VSSPathsInUse 
            }
        }

        # Determine and set VSSStatus for the report based on outcomes
        if ($effectiveJobConfig.JobEnableVSS) {
            $reportData.VSSAttempted = $true # New field indicating VSS was configured for the job

            $originalSourcePathsForJob = if ($effectiveJobConfig.OriginalSourcePath -is [array]) {
                                             $effectiveJobConfig.OriginalSourcePath
                                         } else {
                                             @($effectiveJobConfig.OriginalSourcePath)
                                         }
            
            $containsUncPath = $false
            $containsLocalPath = $false
            $localPathVssUsedSuccessfully = $false # Tracks if VSS was successfully USED for at least one local path

            if ($null -ne $originalSourcePathsForJob) {
                foreach ($originalPathItem in $originalSourcePathsForJob) {
                    if (-not [string]::IsNullOrWhiteSpace($originalPathItem)) {
                        $isUncPath = $false
                        try {
                            $uriCheck = [uri]$originalPathItem
                            if ($uriCheck.IsUnc) { $isUncPath = $true }
                        } catch {
                            # Path might not be a valid URI (e.g. simple local path like "C:\Folder")
                            # Treat as local if not determinable as UNC via URI
                        }
                        
                        if ($isUncPath) {
                            $containsUncPath = $true
                        } else {
                            $containsLocalPath = $true
                            # Check if VSS was successfully used for this local path
                            if ($null -ne $VSSPathsInUse -and $VSSPathsInUse.ContainsKey($originalPathItem) -and $VSSPathsInUse[$originalPathItem] -ne $originalPathItem) {
                                $localPathVssUsedSuccessfully = $true
                            }
                        }
                    }
                }
            }

            if ($IsSimulateMode.IsPresent) {
                if ($containsLocalPath -and $containsUncPath) {
                    $reportData.VSSStatus = "Simulated (Used for local, Skipped for network)"
                } elseif ($containsUncPath -and -not $containsLocalPath) { # Only UNC paths
                    $reportData.VSSStatus = "Simulated (Skipped - All Network Paths)"
                } elseif ($containsLocalPath) { # Only local paths
                    $reportData.VSSStatus = "Simulated (Used for local paths)"
                } else { # No valid source paths provided or determined
                     $reportData.VSSStatus = "Simulated (No paths processed for VSS)"
                }
            } else { # Not Simulate Mode
                if ($containsLocalPath) {
                    if ($localPathVssUsedSuccessfully) {
                        # VSS was successfully used for at least one local path
                        $reportData.VSSStatus = if ($containsUncPath) { "Partially Used (Local success, Network skipped)" } else { "Used Successfully" }
                    } else {
                        # VSS was attempted on local paths but failed for all of them, or no VSS paths were returned for local items.
                        # $VSSPathsInUse would be null or not contain mappings for local paths.
                        $reportData.VSSStatus = if ($containsUncPath) { "Failed (Local VSS failed/skipped, Network skipped)" } else { "Failed (Local VSS failed/skipped)" }
                    }
                } elseif ($containsUncPath) { # Only UNC paths were provided, no local paths
                    $reportData.VSSStatus = "Not Applicable (All Source Paths Network)"
                } else { # No local and no UNC paths (e.g., empty SourcePath array)
                    $reportData.VSSStatus = "Not Applicable (No Source Paths Specified)"
                }
            }
        } else { # VSS not enabled for the job
            $reportData.VSSAttempted = $false
            $reportData.VSSStatus = "Not Enabled"
        }
        # Ensure EffectiveSourcePath is updated in reportData if VSS paths were used
        $reportData.EffectiveSourcePath = if ($currentJobSourcePathFor7Zip -is [array]) {$currentJobSourcePathFor7Zip} else {@($currentJobSourcePathFor7Zip)}

        & $LocalWriteLog -Message "`n[INFO] Performing Pre-Backup Operations for job '$JobName'..."
        & $LocalWriteLog -Message "   - Using source(s) for 7-Zip: $(if ($currentJobSourcePathFor7Zip -is [array]) {($currentJobSourcePathFor7Zip | Where-Object {$_}) -join '; '} else {$currentJobSourcePathFor7Zip})"

        if (-not (Get-Command Test-DestinationFreeSpace -ErrorAction SilentlyContinue)) { throw "CRITICAL: Function 'Test-DestinationFreeSpace' from Utils.psm1 is not available."}
        if (-not (Test-DestinationFreeSpace -DestDir $effectiveJobConfig.DestinationDir -MinRequiredGB $effectiveJobConfig.JobMinimumRequiredFreeSpaceGB -ExitOnLow $effectiveJobConfig.JobExitOnLowSpace -IsSimulateMode:$IsSimulateMode -Logger $Logger)) { 
            throw "Low disk space condition met and configured to halt job '$JobName'." 
        }

        $DateString = Get-Date -Format $effectiveJobConfig.JobArchiveDateFormat
        $ArchiveFileName = "$($effectiveJobConfig.BaseFileName) [$DateString]$($effectiveJobConfig.JobArchiveExtension)"
        $FinalArchivePath = Join-Path -Path $effectiveJobConfig.DestinationDir -ChildPath $ArchiveFileName
        $reportData.FinalArchivePath = $FinalArchivePath
        & $LocalWriteLog -Message "`n[INFO] Target Archive for job '$JobName': $FinalArchivePath"

        $vbLoaded = $false 
        if ($effectiveJobConfig.DeleteToRecycleBin) {
            try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop; $vbLoaded = $true }
            catch { & $LocalWriteLog -Message "[WARNING] Failed to load Microsoft.VisualBasic assembly for Recycle Bin functionality. Will use permanent deletion. Error: $($_.Exception.Message)" -Level WARNING }
        }
        
        if (-not (Get-Command Invoke-BackupRetentionPolicy -ErrorAction SilentlyContinue)) { throw "CRITICAL: Function 'Invoke-BackupRetentionPolicy' from RetentionManager.psm1 is not available."}
        Invoke-BackupRetentionPolicy -DestinationDirectory $effectiveJobConfig.DestinationDir `
                                     -ArchiveBaseFileName $effectiveJobConfig.BaseFileName `
                                     -ArchiveExtension $effectiveJobConfig.JobArchiveExtension `
                                     -RetentionCountToKeep $effectiveJobConfig.RetentionCount `
                                     -SendToRecycleBin $effectiveJobConfig.DeleteToRecycleBin `
                                     -VBAssemblyLoaded $vbLoaded `
                                     -IsSimulateMode:$IsSimulateMode `
                                     -Logger $Logger 

        if (-not (Get-Command Get-PoShBackup7ZipArgument -ErrorAction SilentlyContinue)) { throw "CRITICAL: Function 'Get-PoShBackup7ZipArgument' from 7ZipManager.psm1 is not available." }
        $sevenZipArgsArray = Get-PoShBackup7ZipArgument -EffectiveConfig $effectiveJobConfig `
                                                        -FinalArchivePath $FinalArchivePath `
                                                        -CurrentJobSourcePathFor7Zip $currentJobSourcePathFor7Zip `
                                                        -TempPasswordFile $tempPasswordFilePath `
                                                        -Logger $Logger 

        $sevenZipPathGlobal = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'SevenZipPath' # Get-ConfigValue from Utils.psm1
        if (-not (Get-Command Invoke-7ZipOperation -ErrorAction SilentlyContinue)) { throw "CRITICAL: Function 'Invoke-7ZipOperation' from 7ZipManager.psm1 is not available." }
        $zipOpParams = @{
            SevenZipPathExe = $sevenZipPathGlobal
            SevenZipArguments = $sevenZipArgsArray
            ProcessPriority = $effectiveJobConfig.JobSevenZipProcessPriority
            HideOutput = $effectiveJobConfig.HideSevenZipOutput
            MaxRetries = $effectiveJobConfig.JobMaxRetryAttempts
            RetryDelaySeconds = $effectiveJobConfig.JobRetryDelaySeconds
            EnableRetries = $effectiveJobConfig.JobEnableRetries
            TreatWarningsAsSuccess = $effectiveJobConfig.TreatSevenZipWarningsAsSuccess # Pass this new setting
            IsSimulateMode = $IsSimulateMode.IsPresent
            Logger = $Logger 
        }
        $sevenZipResult = Invoke-7ZipOperation @zipOpParams

        $reportData.SevenZipExitCode = $sevenZipResult.ExitCode
        $reportData.CompressionTime = if ($null -ne $sevenZipResult.ElapsedTime) {$sevenZipResult.ElapsedTime.ToString()} else {"N/A"}
        $reportData.RetryAttemptsMade = $sevenZipResult.AttemptsMade

        $archiveSize = "N/A (Simulated)"
        if (-not $IsSimulateMode.IsPresent -and (Test-Path -LiteralPath $FinalArchivePath -PathType Leaf)) {
             $archiveSize = Get-ArchiveSizeFormatted -PathToArchive $FinalArchivePath -Logger $Logger # Get-ArchiveSizeFormatted from Utils.psm1
        } elseif ($IsSimulateMode.IsPresent) {
            $archiveSize = "0 Bytes (Simulated)" 
        }
        $reportData.ArchiveSizeFormatted = $archiveSize

        # Determine job status based on 7-Zip exit code and TreatSevenZipWarningsAsSuccess
        if ($sevenZipResult.ExitCode -eq 0) { 
            # $currentJobStatus remains "SUCCESS"
        } elseif ($sevenZipResult.ExitCode -eq 1) { # Warning
            if ($effectiveJobConfig.TreatSevenZipWarningsAsSuccess) {
                & $LocalWriteLog -Message "[INFO] 7-Zip returned warning (Exit Code 1) but 'TreatSevenZipWarningsAsSuccess' is true. Job status remains SUCCESS." -Level "INFO"
                # $currentJobStatus remains "SUCCESS"
            } else {
                $currentJobStatus = "WARNINGS"
            }
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
                TreatWarningsAsSuccess = $effectiveJobConfig.TreatSevenZipWarningsAsSuccess # Pass this new setting
                Logger = $Logger 
            }
            $testResult = Test-7ZipArchive @testArchiveParams

            if ($testResult.ExitCode -eq 0) {
                $reportData.ArchiveTestResult = "PASSED"
            } elseif ($testResult.ExitCode -eq 1 -and $effectiveJobConfig.TreatSevenZipWarningsAsSuccess) {
                $reportData.ArchiveTestResult = "PASSED (7-Zip Test Warning Exit Code: 1, treated as success)"
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
        & $LocalWriteLog -Message "ERROR during processing of job '$JobName': $($_.Exception.ToString())" -Level ERROR
        $currentJobStatus = "FAILURE" 
        $reportData.ErrorMessage = $_.Exception.ToString() 
    } finally {
        if ($null -ne $VSSPathsInUse) { 
            if (-not (Get-Command Remove-VSSShadowCopy -ErrorAction SilentlyContinue)) {
                & $LocalWriteLog -Message "CRITICAL: Function 'Remove-VSSShadowCopy' from VssManager.psm1 is not available. VSS Shadows may not be cleaned up." -Level ERROR
            } else {
                Remove-VSSShadowCopy -IsSimulateMode:$IsSimulateMode.IsPresent -Logger $Logger 
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($plainTextPasswordForJob)) {
            try {
                $plainTextPasswordForJob = $null
                Remove-Variable plainTextPasswordForJob -Scope Script -ErrorAction SilentlyContinue
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
                & $LocalWriteLog -Message "   - Plain text password for job '$JobName' cleared from Operations module memory." -Level DEBUG
            } catch {
                & $LocalWriteLog -Message "[WARNING] Exception while clearing plain text password from Operations module memory for job '$JobName'. Error: $($_.Exception.Message)" -Level WARNING
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($tempPasswordFilePath) -and (Test-Path -LiteralPath $tempPasswordFilePath -PathType Leaf) `
            -and -not ($IsSimulateMode.IsPresent -and $tempPasswordFilePath.EndsWith("simulated_poshbackup_pass.tmp")) ) { 
            if ($PSCmdlet.ShouldProcess($tempPasswordFilePath, "Delete Temporary Password File")) {
                try {
                    Remove-Item -LiteralPath $tempPasswordFilePath -Force -ErrorAction Stop
                    & $LocalWriteLog -Message "   - Temporary password file '$tempPasswordFilePath' deleted successfully." -Level DEBUG
                }
                catch {
                    & $LocalWriteLog -Message "[WARNING] Failed to delete temporary password file '$tempPasswordFilePath'. Manual deletion may be required. Error: $($_.Exception.Message)" -Level "WARNING"
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
            Invoke-PoShBackupHook -ScriptPath $effectiveJobConfig.PostBackupScriptOnSuccessPath -HookType "PostBackupOnSuccess" -HookParameters $hookArgsForExternalScript -IsSimulateMode:$IsSimulateMode.IsPresent -Logger $Logger
        } else { 
            Invoke-PoShBackupHook -ScriptPath $effectiveJobConfig.PostBackupScriptOnFailurePath -HookType "PostBackupOnFailure" -HookParameters $hookArgsForExternalScript -IsSimulateMode:$IsSimulateMode.IsPresent -Logger $Logger
        }
        Invoke-PoShBackupHook -ScriptPath $effectiveJobConfig.PostBackupScriptAlwaysPath -HookType "PostBackupAlways" -HookParameters $hookArgsForExternalScript -IsSimulateMode:$IsSimulateMode.IsPresent -Logger $Logger
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
