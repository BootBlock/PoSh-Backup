# Modules\Core\Operations.psm1
<#
.SYNOPSIS
    Manages the core backup operations for a single backup job within the PoSh-Backup solution.
    This module now orchestrates calls to sub-modules for local archive processing and remote
    target transfers, while still handling VSS, password management, local retention,
    and hook script execution. This module now resides in 'Modules\Core\'.
    It also incorporates logic to skip remote transfers if local archive verification fails
    and the 'VerifyLocalArchiveBeforeTransfer' option is enabled.

.DESCRIPTION
    The Operations module encapsulates the entire lifecycle of processing a single, defined backup job.
    It acts as the main orchestrator for each backup task, taking a job's configuration and performing all
    necessary steps to create a local archive and then optionally transfer it to one or more
    defined remote targets.

    The primary exported function, Invoke-PoShBackupJob, performs the following sequence:
    1.  Receives the effective configuration.
    2.  Performs early accessibility checks.
    3.  Validates/creates local destination directory (staging or final).
    4.  Retrieves archive password.
    5.  Executes pre-backup hook scripts.
    6.  Handles VSS shadow copy creation (via VssManager.psm1).
    7.  Calls 'Invoke-LocalArchiveOperation' (from Modules\Operations\LocalArchiveProcessor.psm1) to:
        a.  Check local destination free space.
        b.  Construct 7-Zip arguments.
        c.  Execute 7-Zip for archiving to the local directory (now supporting CPU affinity).
        d.  Optionally generate an archive checksum file.
        e.  Optionally test local archive integrity and verify checksum. This test is also triggered
            if 'VerifyLocalArchiveBeforeTransfer' is enabled.
    8.  Checks if local archive verification (if enabled by 'VerifyLocalArchiveBeforeTransfer') passed.
        If not, remote transfers are skipped.
    9.  Applies local retention policy (via RetentionManager.psm1).
    10. If local operations were successful (including pre-transfer verification if enabled) and
        remote targets are defined, calls 'Invoke-RemoteTargetTransferOrchestration'
        (from Modules\Operations\RemoteTransferOrchestrator.psm1) to handle transfers.
    11. Cleans up VSS shadow copies.
    12. Securely disposes of temporary password files.
    13. Executes post-backup hook scripts.
    14. Returns overall job status.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.20.2 # Added logic to skip remote transfers if VerifyLocalArchiveBeforeTransfer fails.
    DateCreated:    10-May-2025
    LastModified:   26-May-2025
    Purpose:        Handles the execution logic for individual backup jobs, including remote target transfers and checksums.
    Prerequisites:  PowerShell 5.1+, 7-Zip installed.
                    All core PoSh-Backup modules and target provider modules.
                    Administrator privileges for VSS.
#>

# Explicitly import Utils.psm1 and other direct dependencies.
# $PSScriptRoot here refers to the directory of Operations.psm1 (Modules\Core).
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\PasswordManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\HookManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\VssManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\RetentionManager.psm1") -Force -ErrorAction Stop
    # Import sub-modules from Modules\Operations\
    Import-Module -Name (Join-Path $PSScriptRoot "..\Operations\LocalArchiveProcessor.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\Operations\RemoteTransferOrchestrator.psm1") -Force -ErrorAction Stop
} catch {
    Write-Error "Operations.psm1 (in Core) FATAL: Could not import one or more dependent modules. Error: $($_.Exception.Message)"
    throw
}

#region --- Main Job Processing Function ---
function Invoke-PoShBackupJob {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$JobName,
        [Parameter(Mandatory = $true)]
        [hashtable]$JobConfig, # This is the *effective* job configuration
        [Parameter(Mandatory = $true)]
        [hashtable]$GlobalConfig,
        [Parameter(Mandatory = $true)]
        [string]$PSScriptRootForPaths, # PSScriptRoot of the main PoSh-Backup.ps1
        [Parameter(Mandatory = $true)]
        [string]$ActualConfigFile,
        [Parameter(Mandatory = $true)]
        [ref]$JobReportDataRef,
        [Parameter(Mandatory = $false)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    & $LocalWriteLog -Message "Operations/Invoke-PoShBackupJob: Logger parameter active for job '$JobName'." -Level "DEBUG" 

    $currentJobStatus = "SUCCESS"
    $tempPasswordFilePath = $null
    $finalLocalArchivePath = $null 
    $archiveFileNameOnly = $null   
    $VSSPathsInUse = $null
    $reportData = $JobReportDataRef.Value
    $reportData.IsSimulationReport = $IsSimulateMode.IsPresent
    $reportData.TargetTransfers = [System.Collections.Generic.List[object]]::new()
    $reportData.ArchiveChecksum = "N/A"
    $reportData.ArchiveChecksumAlgorithm = "N/A"
    $reportData.ArchiveChecksumFile = "N/A"
    $reportData.ArchiveChecksumVerificationStatus = "Not Performed"

    if (-not ($reportData.PSObject.Properties.Name -contains 'ScriptStartTime')) {
        $reportData['ScriptStartTime'] = Get-Date
    }
    $plainTextPasswordForJob = $null

    try {
        $effectiveJobConfig = $JobConfig 

        $destinationDirTerm = if ($effectiveJobConfig.ResolvedTargetInstances.Count -eq 0) { "Final Destination Directory" } else { "Local Staging Directory" }

        & $LocalWriteLog -Message " - Job Settings for '$JobName' (derived from configuration and CLI overrides):"
        & $LocalWriteLog -Message "   - Effective Source Path(s): $(if ($effectiveJobConfig.OriginalSourcePath -is [array]) {$effectiveJobConfig.OriginalSourcePath -join '; '} else {$effectiveJobConfig.OriginalSourcePath})"
        & $LocalWriteLog -Message "   - ${destinationDirTerm}: $($effectiveJobConfig.DestinationDir)"
        & $LocalWriteLog -Message "   - Archive Base Name      : $($effectiveJobConfig.BaseFileName)"
        & $LocalWriteLog -Message "   - Archive Password Method: $($effectiveJobConfig.ArchivePasswordMethod)"
        & $LocalWriteLog -Message "   - Treat 7-Zip Warnings as Success: $($effectiveJobConfig.TreatSevenZipWarningsAsSuccess)"
        & $LocalWriteLog -Message "   - 7-Zip CPU Affinity     : $(if ([string]::IsNullOrWhiteSpace($effectiveJobConfig.JobSevenZipCpuAffinity)) {'Not Set (Uses 7-Zip Default)'} else {$effectiveJobConfig.JobSevenZipCpuAffinity})" 
        & $LocalWriteLog -Message "   - Verify Local Archive Before Transfer: $($effectiveJobConfig.VerifyLocalArchiveBeforeTransfer)" # NEW
        & $LocalWriteLog -Message "   - Local Retention Deletion Confirmation: $($effectiveJobConfig.RetentionConfirmDelete)"
        & $LocalWriteLog -Message "   - Generate Archive Checksum: $($effectiveJobConfig.GenerateArchiveChecksum)"
        & $LocalWriteLog -Message "   - Checksum Algorithm       : $($effectiveJobConfig.ChecksumAlgorithm)"
        & $LocalWriteLog -Message "   - Verify Checksum on Test  : $($effectiveJobConfig.VerifyArchiveChecksumOnTest)"
        if ($effectiveJobConfig.TargetNames.Count -gt 0) {
            & $LocalWriteLog -Message "   - Remote Target Name(s)  : $($effectiveJobConfig.TargetNames -join ', ')"
            & $LocalWriteLog -Message "   - Delete Local Staged Archive After Successful Transfer(s): $($effectiveJobConfig.DeleteLocalArchiveAfterSuccessfulTransfer)"
        } else {
            & $LocalWriteLog -Message "   - Remote Target Name(s)  : (None specified - local backup only to $destinationDirTerm)"
        }

        #region --- Early UNC Path Accessibility Checks ---
        & $LocalWriteLog -Message "`n[INFO] Operations: Performing early accessibility checks for configured paths..." -Level INFO
        $sourcePathsToCheck = @()
        if ($effectiveJobConfig.OriginalSourcePath -is [array]) {
            $sourcePathsToCheck = $effectiveJobConfig.OriginalSourcePath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        } elseif (-not [string]::IsNullOrWhiteSpace($effectiveJobConfig.OriginalSourcePath)) {
            $sourcePathsToCheck = @($effectiveJobConfig.OriginalSourcePath)
        }
        foreach ($individualSourcePath in $sourcePathsToCheck) {
            if ($individualSourcePath -match '^\\\\') { 
                $uncPathToTestForSource = $individualSourcePath
                if ($individualSourcePath -match '[\*\?\[]') { $uncPathToTestForSource = Split-Path -LiteralPath $individualSourcePath -Parent }
                if ([string]::IsNullOrWhiteSpace($uncPathToTestForSource) -or ($uncPathToTestForSource -match '^\\\\([^\\]+)$')) {
                    & $LocalWriteLog -Message "[WARNING] Operations: Could not determine a valid UNC base directory to test accessibility for source path '$individualSourcePath'. Check skipped." -Level WARNING
                } else {
                    if (-not $IsSimulateMode.IsPresent) {
                        if (-not (Test-Path -LiteralPath $uncPathToTestForSource)) {
                            $errorMessage = "FATAL: Operations: UNC source path '$individualSourcePath' (base '$uncPathToTestForSource') is inaccessible. Job '$JobName' cannot proceed."
                            & $LocalWriteLog -Message $errorMessage -Level ERROR; $reportData.ErrorMessage = $errorMessage; throw $errorMessage
                        } else { & $LocalWriteLog -Message "  - Operations: UNC source path '$individualSourcePath' (tested base: '$uncPathToTestForSource') accessibility: PASSED." -Level DEBUG }
                    } else { & $LocalWriteLog -Message "SIMULATE: Operations: Would test accessibility of UNC source path '$individualSourcePath' (base '$uncPathToTestForSource')." -Level SIMULATE }
                }
            }
        }
        if ($effectiveJobConfig.DestinationDir -match '^\\\\') {
            $uncDestinationBasePathToTest = $null
            if ($effectiveJobConfig.DestinationDir -match '^(\\\\\\[^\\]+\\[^\\]+)') { $uncDestinationBasePathToTest = $matches[1] }
            if (-not [string]::IsNullOrWhiteSpace($uncDestinationBasePathToTest)) {
                if (-not $IsSimulateMode.IsPresent) {
                    if (-not (Test-Path -LiteralPath $uncDestinationBasePathToTest)) {
                        $errorMessage = "FATAL: Operations: Base UNC ${destinationDirTerm} share '$uncDestinationBasePathToTest' (from '$($effectiveJobConfig.DestinationDir)') is inaccessible. Job '$JobName' cannot proceed."
                        & $LocalWriteLog -Message $errorMessage -Level ERROR; $reportData.ErrorMessage = $errorMessage; throw $errorMessage
                    } else { & $LocalWriteLog -Message "  - Operations: Base UNC ${destinationDirTerm} share '$uncDestinationBasePathToTest' accessibility: PASSED." -Level DEBUG }
                } else { & $LocalWriteLog -Message "SIMULATE: Operations: Would test accessibility of base UNC ${destinationDirTerm} share '$uncDestinationBasePathToTest'." -Level SIMULATE }
            } else { & $LocalWriteLog -Message "[WARNING] Operations: Could not determine base UNC share for ${destinationDirTerm} '$($effectiveJobConfig.DestinationDir)'. Full path creation attempted later." -Level WARNING }
        }
        & $LocalWriteLog -Message "[INFO] Operations: Early accessibility checks completed." -Level INFO
        #endregion

        if ([string]::IsNullOrWhiteSpace($effectiveJobConfig.DestinationDir)) {
            throw "FATAL: ${destinationDirTerm} for job '$JobName' is not defined. Cannot proceed."
        }
        if (-not (Test-Path -LiteralPath $effectiveJobConfig.DestinationDir -PathType Container)) {
            & $LocalWriteLog -Message "[INFO] ${destinationDirTerm} '$($effectiveJobConfig.DestinationDir)' for job '$JobName' does not exist. Attempting to create..."
            if (-not $IsSimulateMode.IsPresent) {
                if ($PSCmdlet.ShouldProcess($effectiveJobConfig.DestinationDir, "Create ${destinationDirTerm}")) {
                    try { New-Item -Path $effectiveJobConfig.DestinationDir -ItemType Directory -Force -ErrorAction Stop | Out-Null; & $LocalWriteLog -Message "  - ${destinationDirTerm} created successfully." -Level SUCCESS }
                    catch { throw "FATAL: Failed to create ${destinationDirTerm} '$($effectiveJobConfig.DestinationDir)'. Error: $($_.Exception.Message)" }
                }
            } else {
                & $LocalWriteLog -Message "SIMULATE: Would create ${destinationDirTerm} '$($effectiveJobConfig.DestinationDir)'." -Level SIMULATE
            }
        }

        $isPasswordRequiredOrConfigured = ($effectiveJobConfig.ArchivePasswordMethod.ToString().ToUpperInvariant() -ne "NONE") -or $effectiveJobConfig.UsePassword
        $effectiveJobConfig.PasswordInUseFor7Zip = $false
        if ($isPasswordRequiredOrConfigured) {
            try {
                $passwordParams = @{
                    JobConfigForPassword = $effectiveJobConfig; JobName = $JobName
                    IsSimulateMode = $IsSimulateMode.IsPresent; Logger = $Logger
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
                    throw "FATAL: Password was required for job '$JobName' via method '$($effectiveJobConfig.ArchivePasswordMethod)' but could not be obtained or was empty."
                }
            } catch { throw "FATAL: Error during password retrieval process for job '$JobName'. Error: $($_.Exception.ToString())" }
        } elseif ($effectiveJobConfig.ArchivePasswordMethod.ToString().ToUpperInvariant() -eq "NONE") {
            $reportData.PasswordSource = "None (Explicitly Configured)"; $effectiveJobConfig.PasswordInUseFor7Zip = $false
        }

        Invoke-PoShBackupHook -ScriptPath $effectiveJobConfig.PreBackupScriptPath -HookType "PreBackup" `
            -HookParameters @{ JobName = $JobName; Status = "PreBackup"; ConfigFile = $ActualConfigFile; SimulateMode = $IsSimulateMode.IsPresent } `
            -IsSimulateMode:$IsSimulateMode -Logger $Logger

        $currentJobSourcePathFor7Zip = $effectiveJobConfig.OriginalSourcePath
        if ($effectiveJobConfig.JobEnableVSS) {
            & $LocalWriteLog -Message "`n[INFO] VSS (Volume Shadow Copy Service) is enabled for job '$JobName'." -Level "VSS"
            if (-not (Test-AdminPrivilege -Logger $Logger)) { throw "FATAL: VSS requires Administrator privileges for job '$JobName', but script is not running as Admin." }
            $vssParams = @{
                SourcePathsToShadow = if ($effectiveJobConfig.OriginalSourcePath -is [array]) {$effectiveJobConfig.OriginalSourcePath} else {@($effectiveJobConfig.OriginalSourcePath)}
                VSSContextOption = $effectiveJobConfig.JobVSSContextOption; MetadataCachePath = $effectiveJobConfig.VSSMetadataCachePath
                PollingTimeoutSeconds = $effectiveJobConfig.VSSPollingTimeoutSeconds; PollingIntervalSeconds = $effectiveJobConfig.VSSPollingIntervalSeconds
                IsSimulateMode = $IsSimulateMode.IsPresent; Logger = $Logger
            }
            $VSSPathsInUse = New-VSSShadowCopy @vssParams
            if ($null -ne $VSSPathsInUse -and $VSSPathsInUse.Count -gt 0) {
                & $LocalWriteLog -Message "  - VSS shadow copies created/mapped. Attempting to use shadow paths for backup." -Level VSS
                $currentJobSourcePathFor7Zip = if ($effectiveJobConfig.OriginalSourcePath -is [array]) {
                    $effectiveJobConfig.OriginalSourcePath | ForEach-Object { if ($VSSPathsInUse.ContainsKey($_) -and $VSSPathsInUse[$_] -ne $_) { $VSSPathsInUse[$_] } else { $_ } }
                } else { if ($VSSPathsInUse.ContainsKey($effectiveJobConfig.OriginalSourcePath) -and $VSSPathsInUse[$effectiveJobConfig.OriginalSourcePath] -ne $effectiveJobConfig.OriginalSourcePath) { $VSSPathsInUse[$effectiveJobConfig.OriginalSourcePath] } else { $effectiveJobConfig.OriginalSourcePath } }
                $reportData.VSSShadowPaths = $VSSPathsInUse
            }
        }
        if ($effectiveJobConfig.JobEnableVSS) {
            $reportData.VSSAttempted = $true; $originalSourcePathsForJob = if ($effectiveJobConfig.OriginalSourcePath -is [array]) { $effectiveJobConfig.OriginalSourcePath } else { @($effectiveJobConfig.OriginalSourcePath) }
            $containsUncPath = $false; $containsLocalPath = $false; $localPathVssUsedSuccessfully = $false
            if ($null -ne $originalSourcePathsForJob) {
                foreach ($originalPathItem in $originalSourcePathsForJob) {
                    if (-not [string]::IsNullOrWhiteSpace($originalPathItem)) {
                        $isUncPathItem = $false
                        try {
                            if (([uri]$originalPathItem).IsUnc) { $isUncPathItem = $true }
                        }
                        catch {
                            & $LocalWriteLog -Message "Operations.psm1: Path '$originalPathItem' could not be parsed as URI for UNC check. Assuming local. Error: $($_.Exception.Message)" -Level "DEBUG"
                        }
                        if ($isUncPathItem) {
                            $containsUncPath = $true
                        } else {
                            $containsLocalPath = $true
                            if ($null -ne $VSSPathsInUse -and $VSSPathsInUse.ContainsKey($originalPathItem) -and $VSSPathsInUse[$originalPathItem] -ne $originalPathItem) {
                                $localPathVssUsedSuccessfully = $true
                            }
                        }
                    }
                }
            }
            if ($IsSimulateMode.IsPresent) { $reportData.VSSStatus = if ($containsLocalPath -and $containsUncPath) { "Simulated (Used for local, Skipped for network)" } elseif ($containsUncPath -and -not $containsLocalPath) { "Simulated (Skipped - All Network Paths)" } elseif ($containsLocalPath) { "Simulated (Used for local paths)" } else { "Simulated (No paths processed for VSS)" } }
            else { if ($containsLocalPath) { $reportData.VSSStatus = if ($localPathVssUsedSuccessfully) { if ($containsUncPath) { "Partially Used (Local success, Network skipped)" } else { "Used Successfully" } } else { if ($containsUncPath) { "Failed (Local VSS failed/skipped, Network skipped)" } else { "Failed (Local VSS failed/skipped)" } } } elseif ($containsUncPath) { $reportData.VSSStatus = "Not Applicable (All Source Paths Network)" } else { $reportData.VSSStatus = "Not Applicable (No Source Paths Specified)" } }
        } else { $reportData.VSSAttempted = $false; $reportData.VSSStatus = "Not Enabled" }
        $reportData.EffectiveSourcePath = if ($currentJobSourcePathFor7Zip -is [array]) {$currentJobSourcePathFor7Zip} else {@($currentJobSourcePathFor7Zip)}

        $localArchiveOpParams = @{
            EffectiveJobConfig           = $effectiveJobConfig
            CurrentJobSourcePathFor7Zip  = $currentJobSourcePathFor7Zip
            TempPasswordFilePath         = $tempPasswordFilePath
            JobReportDataRef             = ([ref]$reportData)
            IsSimulateMode               = $IsSimulateMode.IsPresent
            Logger                       = $Logger
            PSCmdlet                     = $PSCmdlet
            GlobalConfig                 = $GlobalConfig
            SevenZipCpuAffinityString    = $effectiveJobConfig.JobSevenZipCpuAffinity 
        }
        $localArchiveResult = Invoke-LocalArchiveOperation @localArchiveOpParams

        $currentJobStatus = $localArchiveResult.Status
        $finalLocalArchivePath = $localArchiveResult.FinalArchivePath 
        $archiveFileNameOnly = $localArchiveResult.ArchiveFileNameOnly 

        # --- NEW: Check if remote transfers should be skipped due to local verification failure ---
        $skipRemoteTransfersDueToVerification = $false
        if ($effectiveJobConfig.VerifyLocalArchiveBeforeTransfer -and $currentJobStatus -ne "SUCCESS" -and $currentJobStatus -ne "SIMULATED_COMPLETE") {
            # If VerifyLocalArchiveBeforeTransfer is true, and local status is not perfect success, then skip.
            # This includes "WARNINGS" (e.g., checksum mismatch) or "FAILURE".
            $skipRemoteTransfersDueToVerification = $true
            & $LocalWriteLog -Message "[WARNING] Operations: Remote target transfers for job '$JobName' will be SKIPPED because 'VerifyLocalArchiveBeforeTransfer' is enabled and local archive processing/verification status is '$currentJobStatus'." -Level "WARNING"
            $reportData.TargetTransfersSkippedReason = "Local archive verification failed (Status: $currentJobStatus)"
        }
        # --- END NEW ---

        $vbLoaded = $false
        if ($effectiveJobConfig.DeleteToRecycleBin) {
            try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop; $vbLoaded = $true }
            catch { & $LocalWriteLog -Message "[WARNING] Failed to load Microsoft.VisualBasic assembly for Recycle Bin functionality. Will use permanent deletion for local retention. Error: $($_.Exception.Message)" -Level WARNING }
        }
        $retentionPolicyParams = @{
            DestinationDirectory = $effectiveJobConfig.DestinationDir; ArchiveBaseFileName = $effectiveJobConfig.BaseFileName
            ArchiveExtension = $effectiveJobConfig.JobArchiveExtension; RetentionCountToKeep = $effectiveJobConfig.LocalRetentionCount
            RetentionConfirmDeleteFromConfig = $effectiveJobConfig.RetentionConfirmDelete; SendToRecycleBin = $effectiveJobConfig.DeleteToRecycleBin
            VBAssemblyLoaded = $vbLoaded; IsSimulateMode = $IsSimulateMode.IsPresent; Logger = $Logger
        }
        if (-not $effectiveJobConfig.RetentionConfirmDelete) { $retentionPolicyParams.Confirm = $false }
        Invoke-BackupRetentionPolicy @retentionPolicyParams

        if ($currentJobStatus -ne "FAILURE" -and (-not $skipRemoteTransfersDueToVerification) -and $effectiveJobConfig.ResolvedTargetInstances.Count -gt 0) { # MODIFIED Condition
            $remoteTransferResult = Invoke-RemoteTargetTransferOrchestration -EffectiveJobConfig $effectiveJobConfig `
                -LocalFinalArchivePath $finalLocalArchivePath `
                -ArchiveFileNameOnly $archiveFileNameOnly `
                -JobReportDataRef ([ref]$reportData) `
                -IsSimulateMode:$IsSimulateMode `
                -Logger $Logger `
                -PSCmdlet $PSCmdlet `
                -PSScriptRootForPaths $PSScriptRootForPaths

            if (-not $remoteTransferResult.AllTransfersSuccessful) {
                if ($currentJobStatus -ne "FAILURE") { $currentJobStatus = "WARNINGS" } 
            }
        } elseif ($currentJobStatus -eq "FAILURE") {
            & $LocalWriteLog -Message "[WARNING] Operations: Remote target transfers skipped for job '$JobName' due to failure in local archive creation/testing." -Level "WARNING"
        } elseif ($skipRemoteTransfersDueToVerification) {
            # Message already logged above. Ensure overall status reflects this if it was previously SUCCESS.
            if ($currentJobStatus -eq "SUCCESS") { $currentJobStatus = "WARNINGS" } # If local was success but verification failed, it's a warning overall.
            # If $currentJobStatus was already WARNINGS or FAILURE from local processing, it remains that.
        }

    } catch {
        $errorMessageText = "FATAL UNHANDLED EXCEPTION in Invoke-PoShBackupJob for job '$JobName': $($_.Exception.ToString())"
        & $LocalWriteLog -Message $errorMessageText -Level "ERROR"
        $currentJobStatus = "FAILURE"
        $reportData.ErrorMessage = if ([string]::IsNullOrWhiteSpace($reportData.ErrorMessage)) { $_.Exception.ToString() } else { "$($reportData.ErrorMessage); $($_.Exception.ToString())" }
        Write-Error -Message $errorMessageText -Exception $_.Exception -ErrorAction Continue 
        throw $_ 
    } finally {
        if ($null -ne $VSSPathsInUse) { Remove-VSSShadowCopy -IsSimulateMode:$IsSimulateMode.IsPresent -Logger $Logger }

        if (-not [string]::IsNullOrWhiteSpace($plainTextPasswordForJob)) {
            try { $plainTextPasswordForJob = $null; Remove-Variable plainTextPasswordForJob -Scope Script -ErrorAction SilentlyContinue; [System.GC]::Collect(); [System.GC]::WaitForPendingFinalizers(); & $LocalWriteLog -Message "   - Plain text password for job '$JobName' cleared from Operations module memory." -Level DEBUG }
            catch { & $LocalWriteLog -Message "[WARNING] Exception while clearing plain text password from Operations module memory for job '$JobName'. Error: $($_.Exception.Message)" -Level WARNING }
        }
        if (-not [string]::IsNullOrWhiteSpace($tempPasswordFilePath) -and (Test-Path -LiteralPath $tempPasswordFilePath -PathType Leaf) `
            -and -not ($IsSimulateMode.IsPresent -and $tempPasswordFilePath.EndsWith("simulated_poshbackup_pass.tmp"))) {
            if ($PSCmdlet.ShouldProcess($tempPasswordFilePath, "Delete Temporary Password File")) {
                try { Remove-Item -LiteralPath $tempPasswordFilePath -Force -ErrorAction Stop; & $LocalWriteLog -Message "   - Temporary password file '$tempPasswordFilePath' deleted successfully." -Level DEBUG }
                catch { & $LocalWriteLog -Message "[WARNING] Failed to delete temporary password file '$tempPasswordFilePath'. Manual deletion may be required. Error: $($_.Exception.Message)" -Level "WARNING" }
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
            $reportData.TotalDuration = "N/A (Timing data incomplete)"; $reportData.TotalDurationSeconds = 0
        }

        $hookArgsForExternalScript = @{
            JobName = $JobName; Status = $reportData.OverallStatus; ArchivePath = $finalLocalArchivePath
            ConfigFile = $ActualConfigFile; SimulateMode = $IsSimulateMode.IsPresent
        }
        if ($reportData.TargetTransfers.Count -gt 0) { $hookArgsForExternalScript.TargetTransferResults = $reportData.TargetTransfers }
        if ($effectiveJobConfig.GenerateArchiveChecksum -and $reportData.ArchiveChecksum -ne "N/A" -and $reportData.ArchiveChecksum -ne "Skipped (Prior failure)" -and $reportData.ArchiveChecksum -notlike "Error*") {
            $hookArgsForExternalScript.ArchiveChecksum = $reportData.ArchiveChecksum
            $hookArgsForExternalScript.ArchiveChecksumAlgorithm = $reportData.ArchiveChecksumAlgorithm
            $hookArgsForExternalScript.ArchiveChecksumFile = $reportData.ArchiveChecksumFile
        }

        if ($reportData.OverallStatus -in @("SUCCESS", "WARNINGS", "SIMULATED_COMPLETE")) {
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
function Get-UtilityArchiveSizeFormattedFromByte { 
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
