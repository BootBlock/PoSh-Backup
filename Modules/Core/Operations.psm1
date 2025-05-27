# Modules\Core\Operations.psm1
<#
.SYNOPSIS
    Manages the core backup operations for a single PoSh-Backup job within the PoSh-Backup solution.
    This module now orchestrates calls to sub-modules for pre-processing (like VSS, password,
    hooks), local archive processing, and remote target transfers, while still handling
    local retention and final hook script execution. This module now resides in 'Modules\Core\'.
    It also incorporates logic to skip remote transfers if local archive verification fails
    and the 'VerifyLocalArchiveBeforeTransfer' option is enabled.

.DESCRIPTION
    The Operations module encapsulates the entire lifecycle of processing a single, defined backup job.
    It acts as the main orchestrator for each backup task, taking a job's configuration and performing all
    necessary steps to create a local archive and then optionally transfer it to one or more
    defined remote targets.

    The primary exported function, Invoke-PoShBackupJob, performs the following sequence:
    1.  Receives the effective configuration.
    2.  Calls 'Invoke-PoShBackupJobPreProcessing' (from Modules\Operations\JobPreProcessor.psm1) to handle:
        a.  Early accessibility checks.
        b.  Validating/creating local destination directory.
        c.  Retrieving archive password.
        d.  Executing pre-backup hook scripts.
        e.  Handling VSS shadow copy creation and determining effective source paths.
    3.  If pre-processing is successful, calls 'Invoke-LocalArchiveOperation' (from Modules\Operations\LocalArchiveProcessor.psm1) to:
        a.  Check local destination free space.
        b.  Construct 7-Zip arguments.
        c.  Execute 7-Zip for archiving to the local directory.
        d.  Optionally generate an archive checksum file.
        e.  Optionally test local archive integrity and verify checksum.
    4.  Checks if local archive verification (if 'VerifyLocalArchiveBeforeTransfer' is enabled) passed.
        If not, remote transfers are skipped.
    5.  Applies local retention policy (via RetentionManager.psm1).
    6.  If local operations were successful and remote targets are defined (and not skipped),
        calls 'Invoke-RemoteTargetTransferOrchestration' (from Modules\Operations\RemoteTransferOrchestrator.psm1).
    7.  Cleans up VSS shadow copies (via VssManager.psm1, called from finally block or by JobPreProcessor on its own error).
    8.  Securely disposes of temporary password files and clears plain text password.
    9.  Executes post-backup hook scripts.
    10. Returns overall job status.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.21.0 # Extracted pre-processing logic to JobPreProcessor.psm1.
    DateCreated:    10-May-2025
    LastModified:   27-May-2025
    Purpose:        Handles the execution logic for individual backup jobs.
    Prerequisites:  PowerShell 5.1+, 7-Zip installed.
                    All core PoSh-Backup modules and target provider modules.
                    Administrator privileges for VSS.
#>

# Explicitly import Utils.psm1 and other direct dependencies.
# $PSScriptRoot here refers to the directory of Operations.psm1 (Modules\Core).
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
    # PasswordManager, HookManager, VssManager are now primarily used by JobPreProcessor
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "..\Managers\RetentionManager.psm1") -Force -ErrorAction Stop
    # Import sub-modules from Modules\Operations\
    Import-Module -Name (Join-Path $PSScriptRoot "..\Operations\JobPreProcessor.psm1") -Force -ErrorAction Stop # NEW
    Import-Module -Name (Join-Path $PSScriptRoot "..\Operations\LocalArchiveProcessor.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\Operations\RemoteTransferOrchestrator.psm1") -Force -ErrorAction Stop
    # VssManager is still needed here for the final Remove-VSSShadowCopy in the `finally` block.
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "..\Managers\VssManager.psm1") -Force -ErrorAction Stop

} catch {
    Write-Error "Operations.psm1 (in Core) FATAL: Could not import one or more dependent modules. Error: $($_.Exception.Message)"
    throw
}

#region --- Main Job Processing Function ---
function Invoke-PoShBackupJob {
    [CmdletBinding(SupportsShouldProcess = $true)] # Removed ConfirmImpact, let sub-modules define it
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
    $tempPasswordFilePathFromPreProcessing = $null # Will be set by JobPreProcessor
    $finalLocalArchivePath = $null
    $archiveFileNameOnly = $null
    $VSSPathsToCleanUp = $null # Will be set by JobPreProcessor
    $reportData = $JobReportDataRef.Value
    $reportData.IsSimulationReport = $IsSimulateMode.IsPresent
    $reportData.TargetTransfers = [System.Collections.Generic.List[object]]::new()
    $reportData.ArchiveChecksum = "N/A"
    $reportData.ArchiveChecksumAlgorithm = "N/A"
    $reportData.ArchiveChecksumFile = "N/A"
    $reportData.ArchiveChecksumVerificationStatus = "Not Performed"
    $plainTextPasswordToClearAfterJob = $null # To hold password from pre-processor for clearing

    if (-not ($reportData.PSObject.Properties.Name -contains 'ScriptStartTime')) {
        $reportData['ScriptStartTime'] = Get-Date
    }

    try {
        $effectiveJobConfig = $JobConfig # This is already the fully resolved config

        # --- Call Job Pre-Processor ---
        $preProcessingParams = @{
            JobName              = $JobName
            EffectiveJobConfig   = $effectiveJobConfig
            IsSimulateMode       = $IsSimulateMode.IsPresent
            Logger               = $Logger
            PSCmdlet             = $PSCmdlet
            ActualConfigFile     = $ActualConfigFile
            JobReportDataRef     = $JobReportDataRef
        }
        $preProcessingResult = Invoke-PoShBackupJobPreProcessing @preProcessingParams

        if (-not $preProcessingResult.Success) {
            throw "Job pre-processing failed for job '$JobName'. Error: $($preProcessingResult.ErrorMessage)"
        }

        $currentJobSourcePathFor7Zip = $preProcessingResult.CurrentJobSourcePathFor7Zip
        $tempPasswordFilePathFromPreProcessing = $preProcessingResult.TempPasswordFilePath
        $VSSPathsToCleanUp = $preProcessingResult.VSSPathsInUse # Store for cleanup in finally
        $plainTextPasswordToClearAfterJob = $preProcessingResult.PlainTextPasswordToClear
        # $reportData is updated by reference within JobPreProcessor

        & $LocalWriteLog -Message " - Job Settings for '$JobName' (derived from configuration and CLI overrides):"
        & $LocalWriteLog -Message "   - Effective Source Path(s) (after VSS if any): $(if ($currentJobSourcePathFor7Zip -is [array]) {$currentJobSourcePathFor7Zip -join '; '} else {$currentJobSourcePathFor7Zip})"
        & $LocalWriteLog -Message "   - Destination/Staging Dir: $($effectiveJobConfig.DestinationDir)"
        & $LocalWriteLog -Message "   - Archive Base Name      : $($effectiveJobConfig.BaseFileName)"
        & $LocalWriteLog -Message "   - Archive Password Method: $($effectiveJobConfig.ArchivePasswordMethod) (Source: $($reportData.PasswordSource))"
        & $LocalWriteLog -Message "   - Treat 7-Zip Warnings as Success: $($effectiveJobConfig.TreatSevenZipWarningsAsSuccess)"
        & $LocalWriteLog -Message "   - 7-Zip CPU Affinity     : $(if ([string]::IsNullOrWhiteSpace($effectiveJobConfig.JobSevenZipCpuAffinity)) {'Not Set (Uses 7-Zip Default)'} else {$effectiveJobConfig.JobSevenZipCpuAffinity})"
        & $LocalWriteLog -Message "   - Verify Local Archive Before Transfer: $($effectiveJobConfig.VerifyLocalArchiveBeforeTransfer)"
        & $LocalWriteLog -Message "   - Local Retention Deletion Confirmation: $($effectiveJobConfig.RetentionConfirmDelete)"
        & $LocalWriteLog -Message "   - Generate Archive Checksum: $($effectiveJobConfig.GenerateArchiveChecksum)"
        & $LocalWriteLog -Message "   - Checksum Algorithm       : $($effectiveJobConfig.ChecksumAlgorithm)"
        & $LocalWriteLog -Message "   - Verify Checksum on Test  : $($effectiveJobConfig.VerifyArchiveChecksumOnTest)"
        if ($effectiveJobConfig.TargetNames.Count -gt 0) {
            & $LocalWriteLog -Message "   - Remote Target Name(s)  : $($effectiveJobConfig.TargetNames -join ', ')"
            & $LocalWriteLog -Message "   - Delete Local Staged Archive After Successful Transfer(s): $($effectiveJobConfig.DeleteLocalArchiveAfterSuccessfulTransfer)"
        } else {
            & $LocalWriteLog -Message "   - Remote Target Name(s)  : (None specified - local backup only)"
        }
        # VSS Status is now logged by JobPreProcessor and added to reportData

        # --- Call Local Archive Processor ---
        $localArchiveOpParams = @{
            EffectiveJobConfig           = $effectiveJobConfig
            CurrentJobSourcePathFor7Zip  = $currentJobSourcePathFor7Zip
            TempPasswordFilePath         = $tempPasswordFilePathFromPreProcessing
            JobReportDataRef             = $JobReportDataRef # Already a [ref]
            IsSimulateMode               = $IsSimulateMode.IsPresent
            Logger                       = $Logger
            PSCmdlet                     = $PSCmdlet
            GlobalConfig                 = $GlobalConfig # Pass the main $Configuration object
            SevenZipCpuAffinityString    = $effectiveJobConfig.JobSevenZipCpuAffinity
        }
        $localArchiveResult = Invoke-LocalArchiveOperation @localArchiveOpParams

        $currentJobStatus = $localArchiveResult.Status
        $finalLocalArchivePath = $localArchiveResult.FinalArchivePath
        $archiveFileNameOnly = $localArchiveResult.ArchiveFileNameOnly

        $skipRemoteTransfersDueToVerification = $false
        if ($effectiveJobConfig.VerifyLocalArchiveBeforeTransfer -and $currentJobStatus -ne "SUCCESS" -and $currentJobStatus -ne "SIMULATED_COMPLETE") {
            $skipRemoteTransfersDueToVerification = $true
            & $LocalWriteLog -Message "[WARNING] Operations: Remote target transfers for job '$JobName' will be SKIPPED because 'VerifyLocalArchiveBeforeTransfer' is enabled and local archive processing/verification status is '$currentJobStatus'." -Level "WARNING"
            $reportData.TargetTransfersSkippedReason = "Local archive verification failed (Status: $currentJobStatus)"
        }

        # --- Local Retention ---
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
        if ($PSCmdlet.ShouldProcess("Local Retention Policy for job '$JobName'", "Apply")) { # Added ShouldProcess here
            Invoke-BackupRetentionPolicy @retentionPolicyParams
        } else {
            & $LocalWriteLog -Message "Operations: Local retention policy for job '$JobName' skipped by user (ShouldProcess)." -Level "WARNING"
        }


        # --- Remote Target Transfers ---
        if ($currentJobStatus -ne "FAILURE" -and (-not $skipRemoteTransfersDueToVerification) -and $effectiveJobConfig.ResolvedTargetInstances.Count -gt 0) {
            $remoteTransferResult = Invoke-RemoteTargetTransferOrchestration -EffectiveJobConfig $effectiveJobConfig `
                -LocalFinalArchivePath $finalLocalArchivePath `
                -ArchiveFileNameOnly $archiveFileNameOnly `
                -JobReportDataRef $JobReportDataRef `
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
            if ($currentJobStatus -eq "SUCCESS") { $currentJobStatus = "WARNINGS" }
        }

    } catch {
        $errorMessageText = "FATAL UNHANDLED EXCEPTION in Invoke-PoShBackupJob for job '$JobName': $($_.Exception.ToString())"
        & $LocalWriteLog -Message $errorMessageText -Level "ERROR"
        $currentJobStatus = "FAILURE"
        $reportData.ErrorMessage = if ([string]::IsNullOrWhiteSpace($reportData.ErrorMessage)) { $_.Exception.ToString() } else { "$($reportData.ErrorMessage); $($_.Exception.ToString())" }
        Write-Error -Message $errorMessageText -Exception $_.Exception -ErrorAction Continue
        # No throw here, let finally block handle cleanup
    } finally {
        # VSS Cleanup (if VSSPathsToCleanUp has been populated by JobPreProcessor)
        if ($null -ne $VSSPathsToCleanUp) {
            & $LocalWriteLog -Message "Operations: Initiating VSS Cleanup via VssManager for job '$JobName'." -Level "DEBUG"
            Remove-VSSShadowCopy -IsSimulateMode:$IsSimulateMode.IsPresent -Logger $Logger # VssManager is loaded
        }

        # Securely clear plain text password if it was obtained
        if (-not [string]::IsNullOrWhiteSpace($plainTextPasswordToClearAfterJob)) {
            try {
                $plainTextPasswordToClearAfterJob = $null; Remove-Variable plainTextPasswordToClearAfterJob -Scope Script -ErrorAction SilentlyContinue; [System.GC]::Collect(); [System.GC]::WaitForPendingFinalizers()
                & $LocalWriteLog -Message "   - Plain text password for job '$JobName' cleared from Operations module memory." -Level DEBUG
            }
            catch { & $LocalWriteLog -Message "[WARNING] Exception while clearing plain text password from Operations module memory for job '$JobName'. Error: $($_.Exception.Message)" -Level WARNING }
        }
        # Securely delete temporary password file if it was created by JobPreProcessor
        if (-not [string]::IsNullOrWhiteSpace($tempPasswordFilePathFromPreProcessing) -and (Test-Path -LiteralPath $tempPasswordFilePathFromPreProcessing -PathType Leaf) `
            -and -not ($IsSimulateMode.IsPresent -and $tempPasswordFilePathFromPreProcessing.EndsWith("simulated_poshbackup_pass.tmp"))) {
            if ($PSCmdlet.ShouldProcess($tempPasswordFilePathFromPreProcessing, "Delete Temporary Password File")) {
                try { Remove-Item -LiteralPath $tempPasswordFilePathFromPreProcessing -Force -ErrorAction Stop; & $LocalWriteLog -Message "   - Temporary password file '$tempPasswordFilePathFromPreProcessing' deleted successfully." -Level DEBUG }
                catch { & $LocalWriteLog -Message "[WARNING] Failed to delete temporary password file '$tempPasswordFilePathFromPreProcessing'. Manual deletion may be required. Error: $($_.Exception.Message)" -Level "WARNING" }
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
# This function is no longer strictly needed here as LocalArchiveProcessor and Target Providers should handle their own size formatting.
# However, keeping it for now in case of any fallback scenarios or direct use.
# Consider removing if confirmed unused after thorough testing.
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
