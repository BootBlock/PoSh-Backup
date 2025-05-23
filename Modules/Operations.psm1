# Modules\Operations.psm1
<#
.SYNOPSIS
    Manages the core backup operations for a single backup job within the PoSh-Backup solution.
    This includes gathering effective job configurations (via ConfigManager.psm1), handling VSS
    (via VssManager.psm1), executing 7-Zip (via 7ZipManager.psm1), applying local retention policies
    (via RetentionManager.psm1), checking destination free space (via Utils.psm1), orchestrating
    hook script execution (via HookManager.psm1), and orchestrating the transfer of archives
    to remote Backup Targets, passing additional metadata like archive size and creation time.

.DESCRIPTION
    The Operations module encapsulates the entire lifecycle of processing a single, defined backup job.
    It acts as the workhorse for each backup task, taking a job's configuration and performing all
    necessary steps to create a local archive and then optionally transfer it to one or more
    defined remote targets.

    The primary exported function, Invoke-PoShBackupJob, performs the following sequence:
    1.  Receives the effective configuration (calculated by PoSh-Backup.ps1 using ConfigManager.psm1).
    2.  Performs early accessibility checks for UNC source and destination paths.
    3.  Validates/creates local staging destination directory.
    4.  Retrieves archive password (PasswordManager.psm1).
    5.  Executes pre-backup hook scripts (HookManager.psm1).
    6.  Handles VSS shadow copy creation if enabled (VssManager.psm1).
    7.  Checks local staging destination free space (Utils.psm1).
    8.  Constructs 7-Zip arguments (7ZipManager.psm1).
    9.  Executes 7-Zip for archiving to the local staging directory (7ZipManager.psm1).
    10. Optionally tests local archive integrity (7ZipManager.psm1).
    11. Applies local retention policy to the local staging directory (RetentionManager.psm1)
        using 'LocalRetentionCount'.
    12. If remote targets are defined for the job:
        a.  Loops through each specified target instance.
        b.  Dynamically loads the appropriate target provider module (e.g., from 'Modules\Targets\').
        c.  Calls 'Invoke-PoShBackupTargetTransfer' in the provider module to send the local archive
            to the remote target. Passes local archive metadata (size, creation time, password status).
            The provider module is responsible for its own remote retention.
        d.  Logs the outcome of each transfer and updates reporting data.
    13. If 'DeleteLocalArchiveAfterSuccessfulTransfer' is true and all remote transfers
        were successful (or no targets were specified but the setting implies intent),
        deletes the local staged archive.
    14. Cleans up VSS shadow copies (VssManager.psm1).
    15. Securely disposes of temporary password files.
    16. Executes post-backup hook scripts (HookManager.psm1), now potentially passing
        target transfer results.
    17. Returns overall job status, considering both local operations and remote transfers.

    This module relies on other PoSh-Backup modules. Functions within this module requiring logging
    accept a -Logger parameter.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.17.3 # Removed cliOverrides or whatever
    DateCreated:    10-May-2025
    LastModified:   22-May-2025
    Purpose:        Handles the execution logic for individual backup jobs, including remote target transfers.
    Prerequisites:  PowerShell 5.1+, 7-Zip installed.
                    All core PoSh-Backup modules and target provider modules.
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
        [hashtable]$JobConfig, # This is now expected to be the *effective* job configuration
        [Parameter(Mandatory=$true)]
        [hashtable]$GlobalConfig, 
        [Parameter(Mandatory=$true)]
        [string]$PSScriptRootForPaths, # PSScriptRoot of the main PoSh-Backup.ps1
        [Parameter(Mandatory=$true)]
        [string]$ActualConfigFile,
        [Parameter(Mandatory=$true)]
        [ref]$JobReportDataRef,
        [Parameter(Mandatory=$false)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory=$true)]
        [scriptblock]$Logger 
    )

    # Internal helper to use the passed-in logger consistently for other messages
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
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
    $reportData.TargetTransfers = [System.Collections.Generic.List[object]]::new() 

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
                    Import-Module -Name $hookManagerPath -Force -ErrorAction Stop -WarningAction SilentlyContinue
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

        # The $JobConfig parameter received by this function IS NOW THE EFFECTIVE CONFIG.
        # No need to call Get-PoShBackupJobEffectiveConfiguration again.
        $effectiveJobConfig = $JobConfig 

        & $LocalWriteLog -Message " - Job Settings for '$JobName' (derived from configuration and CLI overrides):"
        & $LocalWriteLog -Message "   - Effective Source Path(s): $(if ($effectiveJobConfig.OriginalSourcePath -is [array]) {$effectiveJobConfig.OriginalSourcePath -join '; '} else {$effectiveJobConfig.OriginalSourcePath})"
        & $LocalWriteLog -Message "   - Local Staging Directory: $($effectiveJobConfig.DestinationDir)" 
        & $LocalWriteLog -Message "   - Archive Base Name      : $($effectiveJobConfig.BaseFileName)"
        & $LocalWriteLog -Message "   - Archive Password Method: $($effectiveJobConfig.ArchivePasswordMethod)"
        & $LocalWriteLog -Message "   - Treat 7-Zip Warnings as Success: $($effectiveJobConfig.TreatSevenZipWarningsAsSuccess)"
        & $LocalWriteLog -Message "   - Local Retention Deletion Confirmation: $($effectiveJobConfig.RetentionConfirmDelete)" 
        if ($effectiveJobConfig.TargetNames.Count -gt 0) {
            & $LocalWriteLog -Message "   - Remote Target Name(s)  : $($effectiveJobConfig.TargetNames -join ', ')"
            & $LocalWriteLog -Message "   - Delete Local Staged Archive After Successful Transfer(s): $($effectiveJobConfig.DeleteLocalArchiveAfterSuccessfulTransfer)"
        } else {
            & $LocalWriteLog -Message "   - Remote Target Name(s)  : (None specified - local backup only)"
        }


        #region --- Early UNC Path Accessibility Checks ---
        & $LocalWriteLog -Message "`n[INFO] Operations: Performing early accessibility checks for configured paths..." -Level INFO

        $sourcePathsToCheck = @()
        if ($effectiveJobConfig.OriginalSourcePath -is [array]) {
            $sourcePathsToCheck = $effectiveJobConfig.OriginalSourcePath | Where-Object {-not [string]::IsNullOrWhiteSpace($_)}
        } elseif (-not [string]::IsNullOrWhiteSpace($effectiveJobConfig.OriginalSourcePath)) {
            $sourcePathsToCheck = @($effectiveJobConfig.OriginalSourcePath)
        }

        foreach ($individualSourcePath in $sourcePathsToCheck) {
            if ($individualSourcePath -match '^\\\\') { # Is UNC
                $uncPathToTestForSource = $individualSourcePath
                if ($individualSourcePath -match '[\*\?\[]') { # If source path itself contains wildcards
                    $uncPathToTestForSource = Split-Path -LiteralPath $individualSourcePath -Parent
                }

                if ([string]::IsNullOrWhiteSpace($uncPathToTestForSource) -or ($uncPathToTestForSource -match '^\\\\([^\\]+)$') ) { # Malformed or just \\server
                    & $LocalWriteLog -Message "[WARNING] Operations: Could not determine a valid UNC base directory to test accessibility for source path '$individualSourcePath' (resolved to '$uncPathToTestForSource'). Accessibility check for this source path will be skipped. Backup might fail later if it's truly inaccessible." -Level WARNING
                } else {
                    if (-not $IsSimulateMode.IsPresent) {
                        if (-not (Test-Path -LiteralPath $uncPathToTestForSource)) {
                            $errorMessage = "FATAL: Operations: UNC source path '$individualSourcePath' (base directory '$uncPathToTestForSource' for testing) is inaccessible. Job '$JobName' cannot proceed."
                            & $LocalWriteLog -Message $errorMessage -Level ERROR
                            $reportData.ErrorMessage = $errorMessage
                            throw $errorMessage
                        } else {
                            & $LocalWriteLog -Message "  - Operations: UNC source path '$individualSourcePath' (tested base: '$uncPathToTestForSource') accessibility check: PASSED." -Level DEBUG
                        }
                    } else {
                        & $LocalWriteLog -Message "SIMULATE: Operations: Would test accessibility of UNC source path '$individualSourcePath' (base directory '$uncPathToTestForSource' for testing)." -Level SIMULATE
                    }
                }
            }
        }

        if ($effectiveJobConfig.DestinationDir -match '^\\\\') { 
            $uncDestinationBasePathToTest = $null
            if ($effectiveJobConfig.DestinationDir -match '^(\\\\\\[^\\]+\\[^\\]+)') { 
                $uncDestinationBasePathToTest = $matches[1]
            } 

            if (-not [string]::IsNullOrWhiteSpace($uncDestinationBasePathToTest)) {
                if (-not $IsSimulateMode.IsPresent) {
                    if (-not (Test-Path -LiteralPath $uncDestinationBasePathToTest)) {
                        $errorMessage = "FATAL: Operations: Base UNC local staging destination share '$uncDestinationBasePathToTest' (derived from configured destination '$($effectiveJobConfig.DestinationDir)') is inaccessible. Job '$JobName' cannot proceed."
                        & $LocalWriteLog -Message $errorMessage -Level ERROR
                        $reportData.ErrorMessage = $errorMessage
                        throw $errorMessage
                    } else {
                        & $LocalWriteLog -Message "  - Operations: Base UNC local staging destination share '$uncDestinationBasePathToTest' accessibility check: PASSED." -Level DEBUG
                    }
                } else {
                    & $LocalWriteLog -Message "SIMULATE: Operations: Would test accessibility of base UNC local staging destination share '$uncDestinationBasePathToTest' (derived from configured destination '$($effectiveJobConfig.DestinationDir)')." -Level SIMULATE
                }
            } else {
                 & $LocalWriteLog -Message "[WARNING] Operations: Could not determine a valid base UNC share path to test accessibility for local staging destination '$($effectiveJobConfig.DestinationDir)'. Full path creation will be attempted later, which might fail if the share is inaccessible." -Level WARNING
            }
        }
        & $LocalWriteLog -Message "[INFO] Operations: Early accessibility checks completed." -Level INFO
        #endregion --- End Early UNC Path Accessibility Checks ---

        if ([string]::IsNullOrWhiteSpace($effectiveJobConfig.DestinationDir)) {
            & $LocalWriteLog -Message "FATAL: Local Staging Destination directory for job '$JobName' is not defined. Cannot proceed." -Level ERROR; throw "DestinationDir missing for job '$JobName'."
        }
        if (-not (Test-Path -LiteralPath $effectiveJobConfig.DestinationDir -PathType Container)) {
            & $LocalWriteLog -Message "[INFO] Local Staging Destination directory '$($effectiveJobConfig.DestinationDir)' for job '$JobName' does not exist. Attempting to create..."
            if (-not $IsSimulateMode.IsPresent) {
                if ($PSCmdlet.ShouldProcess($effectiveJobConfig.DestinationDir, "Create Local Staging Directory")) {
                    try { New-Item -Path $effectiveJobConfig.DestinationDir -ItemType Directory -Force -ErrorAction Stop | Out-Null; & $LocalWriteLog -Message "  - Local Staging Destination directory created successfully." -Level SUCCESS }
                    catch { & $LocalWriteLog -Message "FATAL: Failed to create Local Staging Destination directory '$($effectiveJobConfig.DestinationDir)'. Error: $($_.Exception.Message)" -Level ERROR; throw "Failed to create local staging destination directory for job '$JobName'." }
                }
            } else {
                & $LocalWriteLog -Message "SIMULATE: Would create Local Staging Destination directory '$($effectiveJobConfig.DestinationDir)'." -Level SIMULATE
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
                Import-Module -Name $passwordManagerModulePath -Force -ErrorAction Stop -WarningAction SilentlyContinue

                $passwordParams = @{
                    JobConfigForPassword = $effectiveJobConfig
                    JobName              = $JobName
                    IsSimulateMode       = $IsSimulateMode.IsPresent
                    Logger               = $Logger 
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
            $effectiveJobConfig.PasswordInUseFor7Zip = $false 
        }

        Invoke-PoShBackupHook -ScriptPath $effectiveJobConfig.PreBackupScriptPath -HookType "PreBackup" `
                              -HookParameters @{ JobName = $JobName; Status = "PreBackup"; ConfigFile = $ActualConfigFile; SimulateMode = $IsSimulateMode.IsPresent } `
                              -IsSimulateMode:$IsSimulateMode -Logger $Logger


        $currentJobSourcePathFor7Zip = $effectiveJobConfig.OriginalSourcePath 
        if ($effectiveJobConfig.JobEnableVSS) {
            & $LocalWriteLog -Message "`n[INFO] VSS (Volume Shadow Copy Service) is enabled for job '$JobName'." -Level "VSS"
            if (-not (Test-AdminPrivilege -Logger $Logger)) { 
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

            if ($null -ne $VSSPathsInUse -and $VSSPathsInUse.Count -gt 0) {
                & $LocalWriteLog -Message "  - VSS shadow copies created/mapped. Attempting to use shadow paths for backup." -Level VSS
                $currentJobSourcePathFor7Zip = if ($effectiveJobConfig.OriginalSourcePath -is [array]) {
                    $effectiveJobConfig.OriginalSourcePath | ForEach-Object {
                        if ($VSSPathsInUse.ContainsKey($_) -and $VSSPathsInUse[$_] -ne $_) { $VSSPathsInUse[$_] } else { $_ } 
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

        if ($effectiveJobConfig.JobEnableVSS) {
            $reportData.VSSAttempted = $true 
            $originalSourcePathsForJob = if ($effectiveJobConfig.OriginalSourcePath -is [array]) { $effectiveJobConfig.OriginalSourcePath } else { @($effectiveJobConfig.OriginalSourcePath) }
            $containsUncPath = $false; $containsLocalPath = $false; $localPathVssUsedSuccessfully = $false 
            if ($null -ne $originalSourcePathsForJob) {
                foreach ($originalPathItem in $originalSourcePathsForJob) {
                    if (-not [string]::IsNullOrWhiteSpace($originalPathItem)) {
                        $isUncPathItem = $false; try { if (([uri]$originalPathItem).IsUnc) { $isUncPathItem = $true } } catch { & $LocalWriteLog -Message "[DEBUG] Operations: Path '$originalPathItem' not a URI, assumed local for VSS check." -Level "DEBUG"}
                        if ($isUncPathItem) { $containsUncPath = $true } else { $containsLocalPath = $true
                            if ($null -ne $VSSPathsInUse -and $VSSPathsInUse.ContainsKey($originalPathItem) -and $VSSPathsInUse[$originalPathItem] -ne $originalPathItem) { $localPathVssUsedSuccessfully = $true }}
                    }
                }
            }
            if ($IsSimulateMode.IsPresent) { $reportData.VSSStatus = if ($containsLocalPath -and $containsUncPath) { "Simulated (Used for local, Skipped for network)" } elseif ($containsUncPath -and -not $containsLocalPath) { "Simulated (Skipped - All Network Paths)" } elseif ($containsLocalPath) { "Simulated (Used for local paths)"} else { "Simulated (No paths processed for VSS)"}}
            else { if ($containsLocalPath) { $reportData.VSSStatus = if ($localPathVssUsedSuccessfully) { if ($containsUncPath) { "Partially Used (Local success, Network skipped)" } else { "Used Successfully" }} else { if ($containsUncPath) { "Failed (Local VSS failed/skipped, Network skipped)" } else { "Failed (Local VSS failed/skipped)" }}} elseif ($containsUncPath) { $reportData.VSSStatus = "Not Applicable (All Source Paths Network)" } else { $reportData.VSSStatus = "Not Applicable (No Source Paths Specified)" }}
        } else { $reportData.VSSAttempted = $false; $reportData.VSSStatus = "Not Enabled" }
        $reportData.EffectiveSourcePath = if ($currentJobSourcePathFor7Zip -is [array]) {$currentJobSourcePathFor7Zip} else {@($currentJobSourcePathFor7Zip)}

        & $LocalWriteLog -Message "`n[INFO] Performing Pre-Backup Operations for job '$JobName'..."
        & $LocalWriteLog -Message "   - Using source(s) for 7-Zip: $(if ($currentJobSourcePathFor7Zip -is [array]) {($currentJobSourcePathFor7Zip | Where-Object {$_}) -join '; '} else {$currentJobSourcePathFor7Zip})"

        if (-not (Get-Command Test-DestinationFreeSpace -ErrorAction SilentlyContinue)) { throw "CRITICAL: Function 'Test-DestinationFreeSpace' from Utils.psm1 is not available."}
        if (-not (Test-DestinationFreeSpace -DestDir $effectiveJobConfig.DestinationDir -MinRequiredGB $effectiveJobConfig.JobMinimumRequiredFreeSpaceGB -ExitOnLow $effectiveJobConfig.JobExitOnLowSpace -IsSimulateMode:$IsSimulateMode -Logger $Logger)) { 
            throw "Low disk space on local staging destination and configured to halt job '$JobName'." 
        }

        $DateString = Get-Date -Format $effectiveJobConfig.JobArchiveDateFormat
        $ArchiveFileNameOnly = "$($effectiveJobConfig.BaseFileName) [$DateString]$($effectiveJobConfig.JobArchiveExtension)" 
        $FinalArchivePath = Join-Path -Path $effectiveJobConfig.DestinationDir -ChildPath $ArchiveFileNameOnly 
        $reportData.FinalArchivePath = $FinalArchivePath 
        & $LocalWriteLog -Message "`n[INFO] Target LOCAL STAGED Archive for job '$JobName': $FinalArchivePath"

        $vbLoaded = $false 
        if ($effectiveJobConfig.DeleteToRecycleBin) {
            try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop; $vbLoaded = $true }
            catch { & $LocalWriteLog -Message "[WARNING] Failed to load Microsoft.VisualBasic assembly for Recycle Bin functionality. Will use permanent deletion for local retention. Error: $($_.Exception.Message)" -Level WARNING }
        }
        
        if (-not (Get-Command Invoke-BackupRetentionPolicy -ErrorAction SilentlyContinue)) { throw "CRITICAL: Function 'Invoke-BackupRetentionPolicy' from RetentionManager.psm1 is not available."}
        
        $retentionPolicyParams = @{
            DestinationDirectory = $effectiveJobConfig.DestinationDir 
            ArchiveBaseFileName = $effectiveJobConfig.BaseFileName
            ArchiveExtension = $effectiveJobConfig.JobArchiveExtension
            RetentionCountToKeep = $effectiveJobConfig.LocalRetentionCount 
            RetentionConfirmDeleteFromConfig = $effectiveJobConfig.RetentionConfirmDelete 
            SendToRecycleBin = $effectiveJobConfig.DeleteToRecycleBin
            VBAssemblyLoaded = $vbLoaded
            IsSimulateMode = $IsSimulateMode.IsPresent
            Logger = $Logger
        }

        if (-not $effectiveJobConfig.RetentionConfirmDelete) {
            $retentionPolicyParams.Confirm = $false 
            & $LocalWriteLog -Message "   - Invoking local retention policy with auto-confirmation (RetentionConfirmDelete:False)." -Level DEBUG
        } else {
            & $LocalWriteLog -Message "   - Invoking local retention policy with standard confirmation behavior." -Level DEBUG
        }
        Invoke-BackupRetentionPolicy @retentionPolicyParams 

        if (-not (Get-Command Get-PoShBackup7ZipArgument -ErrorAction SilentlyContinue)) { throw "CRITICAL: Function 'Get-PoShBackup7ZipArgument' from 7ZipManager.psm1 is not available." }
        $sevenZipArgsArray = Get-PoShBackup7ZipArgument -EffectiveConfig $effectiveJobConfig `
                                                        -FinalArchivePath $FinalArchivePath `
                                                        -CurrentJobSourcePathFor7Zip $currentJobSourcePathFor7Zip `
                                                        -TempPasswordFile $tempPasswordFilePath `
                                                        -Logger $Logger 

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
            TreatWarningsAsSuccess = $effectiveJobConfig.TreatSevenZipWarningsAsSuccess 
            IsSimulateMode = $IsSimulateMode.IsPresent
            Logger = $Logger 
        }
        $sevenZipResult = Invoke-7ZipOperation @zipOpParams

        $reportData.SevenZipExitCode = $sevenZipResult.ExitCode
        $reportData.CompressionTime = if ($null -ne $sevenZipResult.ElapsedTime) {$sevenZipResult.ElapsedTime.ToString()} else {"N/A"}
        $reportData.RetryAttemptsMade = $sevenZipResult.AttemptsMade

        if (-not $IsSimulateMode.IsPresent -and (Test-Path -LiteralPath $FinalArchivePath -PathType Leaf)) {
             $reportData.ArchiveSizeBytes = (Get-Item -LiteralPath $FinalArchivePath).Length 
             $reportData.ArchiveSizeFormatted = Get-ArchiveSizeFormatted -PathToArchive $FinalArchivePath -Logger $Logger 
        } elseif ($IsSimulateMode.IsPresent) {
            $reportData.ArchiveSizeBytes = 0
            $reportData.ArchiveSizeFormatted = "0 Bytes (Simulated)" 
        } else {
             $reportData.ArchiveSizeBytes = 0
             $reportData.ArchiveSizeFormatted = "N/A (Archive not found after creation)"
        }

        if ($sevenZipResult.ExitCode -ne 0) { 
            if ($sevenZipResult.ExitCode -eq 1 -and $effectiveJobConfig.TreatSevenZipWarningsAsSuccess) {
                & $LocalWriteLog -Message "[INFO] 7-Zip returned warning (Exit Code 1) but 'TreatSevenZipWarningsAsSuccess' is true. Job status remains SUCCESS for local archive creation." -Level "INFO"
            } else {
                $currentJobStatus = if ($sevenZipResult.ExitCode -eq 1) { "WARNINGS" } else { "FAILURE" }
                & $LocalWriteLog -Message "[$(if($currentJobStatus -eq 'FAILURE') {'ERROR'} else {'WARNING'})] 7-Zip operation for local archive creation resulted in Exit Code $($sevenZipResult.ExitCode). This impacts overall job status." -Level $currentJobStatus
            }
        }

        $reportData.ArchiveTested = $effectiveJobConfig.JobTestArchiveAfterCreation 
        if ($effectiveJobConfig.JobTestArchiveAfterCreation -and ($currentJobStatus -ne "FAILURE") -and (-not $IsSimulateMode.IsPresent) -and (Test-Path -LiteralPath $FinalArchivePath -PathType Leaf)) {
            if (-not (Get-Command Test-7ZipArchive -ErrorAction SilentlyContinue)) { throw "CRITICAL: Function 'Test-7ZipArchive' from 7ZipManager.psm1 is not available." }
            $testArchiveParams = @{
                SevenZipPathExe = $sevenZipPathGlobal; ArchivePath = $FinalArchivePath; TempPasswordFile = $tempPasswordFilePath 
                ProcessPriority = $effectiveJobConfig.JobSevenZipProcessPriority; HideOutput = $effectiveJobConfig.HideSevenZipOutput
                MaxRetries = $effectiveJobConfig.JobMaxRetryAttempts; RetryDelaySeconds = $effectiveJobConfig.JobRetryDelaySeconds
                EnableRetries = $effectiveJobConfig.JobEnableRetries; TreatWarningsAsSuccess = $effectiveJobConfig.TreatSevenZipWarningsAsSuccess 
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

        $allTargetTransfersSuccessfulOverall = $true 
        if ($currentJobStatus -ne "FAILURE" -and $effectiveJobConfig.ResolvedTargetInstances.Count -gt 0) {
            & $LocalWriteLog -Message "`n[INFO] Operations: Starting remote target transfers for job '$JobName'..." -Level "INFO"
            
            if (-not $IsSimulateMode.IsPresent -and -not (Test-Path -LiteralPath $FinalArchivePath -PathType Leaf)) {
                & $LocalWriteLog -Message "[ERROR] Operations: Local staged archive '$FinalArchivePath' not found. Cannot proceed with remote target transfers." -Level "ERROR"
                $allTargetTransfersSuccessfulOverall = $false
                if ($currentJobStatus -ne "FAILURE") { $currentJobStatus = "WARNINGS" } 
            } else {
                $LocalArchiveCreationTimestamp = $null
                if (-not $IsSimulateMode.IsPresent -and (Test-Path -LiteralPath $FinalArchivePath -PathType Leaf)) {
                    try { $LocalArchiveCreationTimestamp = (Get-Item -LiteralPath $FinalArchivePath).CreationTime }
                    catch {
                        & $LocalWriteLog -Message "[WARNING] Operations: Could not get CreationTime for local archive '$FinalArchivePath' prior to target transfer. Error: $($_.Exception.Message)" -Level "WARNING"
                    }
                } elseif ($IsSimulateMode.IsPresent) {
                    $LocalArchiveCreationTimestamp = (Get-Date).AddMinutes(-5) 
                }
                if ($null -eq $LocalArchiveCreationTimestamp) { 
                    $LocalArchiveCreationTimestamp = (Get-Date) 
                    & $LocalWriteLog -Message "[DEBUG] Operations: Using current time as fallback for LocalArchiveCreationTimestamp for target transfers." -Level "DEBUG"
                }

                foreach ($targetInstanceConfig in $effectiveJobConfig.ResolvedTargetInstances) {
                    $targetInstanceName = $targetInstanceConfig._TargetInstanceName_ 
                    $targetInstanceType = $targetInstanceConfig.Type
                    & $LocalWriteLog -Message "  - Operations: Preparing transfer to Target Instance: '$targetInstanceName' (Type: '$targetInstanceType')." -Level "INFO"

                    $targetProviderModuleName = "$($targetInstanceType).Target.psm1" 
                    $targetProviderModulePath = Join-Path -Path $PSScriptRootForPaths -ChildPath "Modules\Targets\$targetProviderModuleName"
                    
                    $currentTransferReport = @{ TargetName = $targetInstanceName; TargetType = $targetInstanceType; Status = "Skipped"; RemotePath = "N/A"; ErrorMessage = "Provider module load/call failed."; TransferDuration = "N/A"; TransferSize=0; TransferSizeFormatted="N/A" }

                    if (-not (Test-Path -LiteralPath $targetProviderModulePath -PathType Leaf)) {
                        & $LocalWriteLog -Message "[ERROR] Operations: Target Provider module '$targetProviderModuleName' for type '$targetInstanceType' not found at '$targetProviderModulePath'. Skipping transfer to '$targetInstanceName'." -Level "ERROR"
                        $currentTransferReport.Status = "Failure (Provider Not Found)"
                        $currentTransferReport.ErrorMessage = "Provider module '$targetProviderModuleName' not found."
                        $reportData.TargetTransfers.Add($currentTransferReport)
                        $allTargetTransfersSuccessfulOverall = $false; if ($currentJobStatus -ne "FAILURE") { $currentJobStatus = "WARNINGS" }
                        continue 
                    }
                    try {
                        Import-Module -Name $targetProviderModulePath -Force -ErrorAction Stop -WarningAction SilentlyContinue
                        $invokeTargetTransferCmd = Get-Command Invoke-PoShBackupTargetTransfer -Module (Get-Module -Name $targetProviderModuleName.Replace(".psm1","")) -ErrorAction SilentlyContinue
                        if (-not $invokeTargetTransferCmd) {
                            throw "Function 'Invoke-PoShBackupTargetTransfer' not found in provider module '$targetProviderModuleName'."
                        }

                        $transferParams = @{
                            LocalArchivePath            = $FinalArchivePath 
                            TargetInstanceConfiguration = $targetInstanceConfig 
                            JobName                     = $JobName
                            ArchiveFileName             = $ArchiveFileNameOnly
                            ArchiveBaseName             = $effectiveJobConfig.BaseFileName
                            ArchiveExtension            = $effectiveJobConfig.JobArchiveExtension
                            IsSimulateMode              = $IsSimulateMode.IsPresent
                            Logger                      = $Logger
                            EffectiveJobConfig          = $effectiveJobConfig
                            LocalArchiveSizeBytes       = $reportData.ArchiveSizeBytes 
                            LocalArchiveCreationTimestamp = $LocalArchiveCreationTimestamp
                            PasswordInUse               = $effectiveJobConfig.PasswordInUseFor7Zip
                        }
                        $transferOutcome = & $invokeTargetTransferCmd @transferParams 
                        
                        $currentTransferReport.Status = if($transferOutcome.Success){"Success"}else{"Failure"}
                        $currentTransferReport.RemotePath = $transferOutcome.RemotePath
                        $currentTransferReport.ErrorMessage = $transferOutcome.ErrorMessage
                        $currentTransferReport.TransferDuration = if ($null -ne $transferOutcome.TransferDuration) {$transferOutcome.TransferDuration.ToString()} else {"N/A"}
                        $currentTransferReport.TransferSize = $transferOutcome.TransferSize 
                        
                        if (-not [string]::IsNullOrWhiteSpace($transferOutcome.RemotePath) -and $transferOutcome.Success -and (-not $IsSimulateMode.IsPresent)) {
                             if (Test-Path -LiteralPath $transferOutcome.RemotePath -ErrorAction SilentlyContinue) { 
                                 $currentTransferReport.TransferSizeFormatted = Get-ArchiveSizeFormatted -PathToArchive $transferOutcome.RemotePath -Logger $Logger
                             } else { $currentTransferReport.TransferSizeFormatted = Get-UtilityArchiveSizeFormattedFromByte -Bytes $transferOutcome.TransferSize } 
                        } elseif ($IsSimulateMode.IsPresent -and $transferOutcome.TransferSize -gt 0) {
                            $currentTransferReport.TransferSizeFormatted = Get-UtilityArchiveSizeFormattedFromByte -Bytes $transferOutcome.TransferSize 
                        } else { 
                            $currentTransferReport.TransferSizeFormatted = "N/A" 
                        }

                        if ($transferOutcome.ContainsKey('ReplicationDetails') -and $transferOutcome.ReplicationDetails -is [array] -and $transferOutcome.ReplicationDetails.Count -gt 0) {
                            & $LocalWriteLog -Message "    - Operations: Replication Details for Target '$targetInstanceName':" -Level "INFO"
                            foreach ($detail in $transferOutcome.ReplicationDetails) {
                                $detailStatusText = if ($null -ne $detail.Status) { $detail.Status } else { "N/A" } 
                                $detailPathText   = if ($null -ne $detail.Path)   { $detail.Path   } else { "N/A" } 
                                $detailErrorText  = if ($null -ne $detail.Error -and -not [string]::IsNullOrWhiteSpace($detail.Error)) { $detail.Error } else { "None" } 
                                & $LocalWriteLog -Message "      - Dest: '$detailPathText', Status: $detailStatusText, Error: $detailErrorText" -Level "INFO"
                            }
                        }
                        
                        if (-not $transferOutcome.Success) {
                            $allTargetTransfersSuccessfulOverall = $false
                            if ($currentJobStatus -ne "FAILURE") { $currentJobStatus = "WARNINGS" } 
                            & $LocalWriteLog -Message "[ERROR] Operations: Transfer to Target '$targetInstanceName' FAILED. Reason: $($transferOutcome.ErrorMessage)" -Level "ERROR"
                        } else {
                            & $LocalWriteLog -Message "  - Operations: Transfer to Target '$targetInstanceName' SUCCEEDED. Remote Path: $($transferOutcome.RemotePath)" -Level "SUCCESS"
                        }

                    } catch {
                        & $LocalWriteLog -Message "[ERROR] Operations: Critical error during transfer to Target '$targetInstanceName' (Type: '$targetInstanceType'). Error: $($_.Exception.ToString())" -Level "ERROR"
                        $currentTransferReport.Status = "Failure (Exception)"
                        $currentTransferReport.ErrorMessage = $_.Exception.ToString()
                        $allTargetTransfersSuccessfulOverall = $false
                        if ($currentJobStatus -ne "FAILURE") { $currentJobStatus = "WARNINGS" }
                    }
                    $reportData.TargetTransfers.Add($currentTransferReport)
                } 
            } 

            if ($allTargetTransfersSuccessfulOverall -and $effectiveJobConfig.ResolvedTargetInstances.Count -gt 0) { 
                & $LocalWriteLog -Message "[INFO] Operations: All attempted remote target transfers for job '$JobName' completed successfully." -Level "SUCCESS"
            } elseif ($effectiveJobConfig.ResolvedTargetInstances.Count -gt 0) { 
                & $LocalWriteLog -Message "[WARNING] Operations: One or more remote target transfers for job '$JobName' FAILED or were skipped due to errors." -Level "WARNING"
            }

            if ($effectiveJobConfig.DeleteLocalArchiveAfterSuccessfulTransfer -and $allTargetTransfersSuccessfulOverall -and $effectiveJobConfig.ResolvedTargetInstances.Count -gt 0) {
                if ((-not $IsSimulateMode.IsPresent) -and (Test-Path -LiteralPath $FinalArchivePath -PathType Leaf)) {
                    if ($PSCmdlet.ShouldProcess($FinalArchivePath, "Delete Local Staged Archive (Post-All-Successful-Transfers)")) {
                        & $LocalWriteLog -Message "[INFO] Operations: Deleting local staged archive '$FinalArchivePath' as all target transfers succeeded and DeleteLocalArchiveAfterSuccessfulTransfer is true." -Level "INFO"
                        try { Remove-Item -LiteralPath $FinalArchivePath -Force -ErrorAction Stop }
                        catch { & $LocalWriteLog -Message "[WARNING] Operations: Failed to delete local staged archive '$FinalArchivePath'. Error: $($_.Exception.Message)" -Level "WARNING"}
                    }
                } elseif ($IsSimulateMode.IsPresent) {
                    & $LocalWriteLog -Message "SIMULATE: Operations: Would delete local staged archive '$FinalArchivePath' (all target transfers successful and configured to delete)." -Level "SIMULATE"
                }
            } elseif ($effectiveJobConfig.DeleteLocalArchiveAfterSuccessfulTransfer -and (-not $allTargetTransfersSuccessfulOverall) -and $effectiveJobConfig.ResolvedTargetInstances.Count -gt 0) {
                 & $LocalWriteLog -Message "[INFO] Operations: Local staged archive '$FinalArchivePath' KEPT because one or more target transfers failed (and DeleteLocalArchiveAfterSuccessfulTransfer is true)." -Level "INFO"
            }
        } elseif ($currentJobStatus -eq "FAILURE") {
            & $LocalWriteLog -Message "[WARNING] Operations: Remote target transfers skipped for job '$JobName' due to failure in local archive creation/testing." -Level "WARNING"
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
            if ($reportData.PSObject.Properties.Name -contains 'TotalDurationSeconds' -and $reportData.TotalDuration -is [System.TimeSpan]) {
                $reportData.TotalDurationSeconds = $reportData.TotalDuration.TotalSeconds 
            } elseif ($reportData.TotalDuration -is [System.TimeSpan]) {
                 $reportData.TotalDurationSeconds = $reportData.TotalDuration.TotalSeconds
            }
        } else {
            $reportData.TotalDuration = "N/A (Timing data incomplete)"
            $reportData.TotalDurationSeconds = 0
        }

        $hookArgsForExternalScript = @{
            JobName = $JobName; Status = $reportData.OverallStatus; ArchivePath = $FinalArchivePath 
            ConfigFile = $ActualConfigFile; SimulateMode = $IsSimulateMode.IsPresent
        }
        if ($reportData.TargetTransfers.Count -gt 0) {
            $hookArgsForExternalScript.TargetTransferResults = $reportData.TargetTransfers
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

#region --- Helper Function for Formatted Size from Bytes (used by Operations if target provider does not return formatted size) ---
# This is added here because Get-ArchiveSizeFormatted in Utils.psm1 expects a path,
# but target providers return raw bytes for TransferSize.
function Get-UtilityArchiveSizeFormattedFromByte { # Name changed from ...FromBytes
    param(
        [long]$Bytes
    )
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    else { return "$Bytes Bytes" }
}
#endregion


#region --- Exported Functions ---
Export-ModuleMember -Function Invoke-PoShBackupJob
#endregion
