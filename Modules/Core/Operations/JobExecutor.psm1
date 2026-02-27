# Modules\Core\Operations\JobExecutor.psm1
<#
.SYNOPSIS
    Executes the core backup operations for a single PoSh-Backup job.
    This module is a sub-component of the Core Operations facade.
    It now lazy-loads its sub-modules for pre-processing, local archiving,
    post-job hook execution, local retention, remote transfers, and cleanup,
    improving overall script performance.

.DESCRIPTION
    The JobExecutor module orchestrates the lifecycle of processing a single backup job.
    It is called by the Operations.psm1 facade (in Modules\Core).

    The primary exported function, Invoke-PoShBackupJob, performs the following sequence:
    1.  Receives the effective configuration.
    2.  Lazy-loads and calls 'Invoke-PoShBackupLocalBackupExecution' to handle pre-processing and local archive creation.
    3.  Lazy-loads and calls 'Invoke-PoShBackupLocalRetentionExecution'.
    4.  If local operations were successful, lazy-loads and calls 'Invoke-PoShBackupRemoteTransferExecution'.
    5.  In the 'finally' block, it lazy-loads and calls the appropriate cleanup handlers for snapshots, VSS,
        passwords, and post-job hooks.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.8.0 # Refactored to lazy-load all sub-modules.
    DateCreated:    30-May-2025
    LastModified:   02-Jul-2025
    Purpose:        Handles the execution logic for individual backup jobs.
    Prerequisites:  PowerShell 5.1+, 7-Zip installed.
                    All core PoSh-Backup modules and target provider modules.
                    All JobExecutor.*.psm1 sub-modules.
                    Administrator privileges for VSS and potentially for snapshot providers.
#>

# Explicitly import Utils.psm1 as it's used directly by this orchestrator.
# $PSScriptRoot here is Modules\Core\Operations.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "JobExecutor.psm1 (in Modules\Core\Operations) FATAL: Could not import Utils.psm1. Error: $($_.Exception.Message)"
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
        }
        else {
            & $Logger -Message $Message -Level $Level
        }
    }
    & $LocalWriteLog -Message "Core/Operations/JobExecutor/Invoke-PoShBackupJob: Logger parameter active for job '$JobName'." -Level "DEBUG"

    # Initialise job-specific state variables
    $currentJobStatus = "SUCCESS"
    $finalLocalArchivePath = $null
    $archiveFileNameOnly = $null
    $VSSPathsToCleanUp = $null
    $snapshotSessionToCleanUp = $null
    $reportData = $JobReportDataRef.Value
    $plainTextPasswordToClearAfterJob = $null
    $effectiveJobConfig = $null
    $skipRemoteTransfersDueToLocalVerificationFailure = $false

    # Initialise global and report data structures for this job run
    $Global:GlobalJobLogEntries = [System.Collections.Generic.List[object]]::new()
    $Global:GlobalJobHookScriptData = [System.Collections.Generic.List[object]]::new()
    $reportData.IsSimulationReport = $IsSimulateMode.IsPresent
    $reportData.TargetTransfers = [System.Collections.Generic.List[object]]::new()
    $reportData.HookScripts = $Global:GlobalJobHookScriptData # Assign the reference
    $reportData.ArchiveChecksum = "N/A"
    $reportData.ArchiveChecksumAlgorithm = "N/A"
    $reportData.ArchiveChecksumFile = "N/A"
    $reportData.ArchiveChecksumVerificationStatus = "Not Performed"

    if (-not ($reportData.PSObject.Properties.Name -contains 'ScriptStartTime')) {
        $reportData['ScriptStartTime'] = Get-Date
    }

    try {
        $effectiveJobConfig = $JobConfig

        # --- Call Local Backup Orchestrator (Handles PreProcessing and LocalArchiveOperation) ---
        try {
            Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "JobExecutor.LocalBackupOrchestrator.psm1") -Force -ErrorAction Stop
            $localBackupExecutionParams = @{
                JobName            = $JobName
                EffectiveJobConfig = $effectiveJobConfig
                ActualConfigFile   = $ActualConfigFile
                JobReportDataRef   = $JobReportDataRef
                IsSimulateMode     = $IsSimulateMode.IsPresent
                Logger             = $Logger
                PSCmdlet           = $PSCmdlet
            }
            $localBackupResult = Invoke-PoShBackupLocalBackupExecution @localBackupExecutionParams
        }
        catch {
            $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Core\Operations\JobExecutor.LocalBackupOrchestrator.psm1' exists and is not corrupted."
            & $LocalWriteLog -Message "[FATAL] JobExecutor: Could not load or execute the LocalBackupOrchestrator. Job cannot proceed. Error: $($_.Exception.Message)" -Level "ERROR"
            & $LocalWriteLog -Message $advice -Level "ADVICE"
            throw # Re-throw as this is a critical failure
        }

        $currentJobStatus = $localBackupResult.LocalBackupStatus
        $finalLocalArchivePath = $localBackupResult.FinalLocalArchivePath
        $archiveFileNameOnly = $localBackupResult.ArchiveFileNameOnly
        $VSSPathsToCleanUp = $localBackupResult.VSSPathsToCleanUp
        $snapshotSessionToCleanUp = $localBackupResult.SnapshotSession
        $plainTextPasswordToClearAfterJob = $localBackupResult.PlainTextPasswordToClear
        $skipRemoteTransfersDueToLocalVerificationFailure = $localBackupResult.SkipRemoteTransfersDueToLocalVerification

        # Log the job settings regardless of the outcome, as long as it wasn't a catastrophic failure before this.
        if ($null -ne $effectiveJobConfig) {
            $resolvedSourcePathForLog = if ($reportData.PSObject.Properties.Name -contains 'EffectiveSourcePath') { $reportData.EffectiveSourcePath } else { $effectiveJobConfig.OriginalSourcePath }
            & $LocalWriteLog -Message " - Job Settings for '$JobName' (derived from configuration and CLI overrides):"
            & $LocalWriteLog -Message "   - Effective Source Path(s) (after VSS/Snapshot if any): $(if ($resolvedSourcePathForLog -is [array]) {$resolvedSourcePathForLog -join '; '} else {$resolvedSourcePathForLog})"
            & $LocalWriteLog -Message "   - Destination/Staging Dir: $($effectiveJobConfig.DestinationDir)"
            & $LocalWriteLog -Message "   - Archive Base Name      : $($effectiveJobConfig.BaseFileName)"
            & $LocalWriteLog -Message "   - Archive Password Method: $($effectiveJobConfig.ArchivePasswordMethod) (Source: $($reportData.PasswordSource))"
            & $LocalWriteLog -Message "   - Treat 7-Zip Warnings as Success: $($effectiveJobConfig.TreatSevenZipWarningsAsSuccess)"
            & $LocalWriteLog -Message "   - 7-Zip CPU Affinity     : $(if ([string]::IsNullOrWhiteSpace($effectiveJobConfig.JobSevenZipCpuAffinity)) {'Not Set (Uses 7-Zip Default)'} else {$effectiveJobConfig.JobSevenZipCpuAffinity})"
            & $LocalWriteLog -Message "   - Split Volume Size      : $(if ([string]::IsNullOrWhiteSpace($effectiveJobConfig.SplitVolumeSize)) {'Not Set (Single Volume)'} else {$effectiveJobConfig.SplitVolumeSize})"
            & $LocalWriteLog -Message "   - Verify Local Archive Before Transfer: $($effectiveJobConfig.VerifyLocalArchiveBeforeTransfer)"
            & $LocalWriteLog -Message "   - Local Retention Deletion Confirmation: $($effectiveJobConfig.RetentionConfirmDelete)"
            & $LocalWriteLog -Message "   - Generate Archive Checksum: $($effectiveJobConfig.GenerateArchiveChecksum)"
            & $LocalWriteLog -Message "   - Checksum Algorithm       : $($effectiveJobConfig.ChecksumAlgorithm)"
            & $LocalWriteLog -Message "   - Verify Checksum on Test  : $($effectiveJobConfig.VerifyArchiveChecksumOnTest)"
            if ($effectiveJobConfig.TargetNames.Count -gt 0) {
                & $LocalWriteLog -Message "   - Remote Target Name(s)  : $($effectiveJobConfig.TargetNames -join ', ')"
                & $LocalWriteLog -Message "   - Delete Local Staged Archive After Successful Transfer(s): $($effectiveJobConfig.DeleteLocalArchiveAfterSuccessfulTransfer)"
            }
            else {
                & $LocalWriteLog -Message "   - Remote Target Name(s)  : (None specified - local backup only)"
            }
        }

        # Only proceed with retention and remote transfers if the local backup operation was successful or had warnings.
        $allRemoteTransfersSucceeded = $true
        if ($currentJobStatus -in 'SUCCESS', 'WARNINGS') {
            try {
                Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "JobExecutor.LocalRetentionHandler.psm1") -Force -ErrorAction Stop
                Invoke-PoShBackupLocalRetentionExecution -JobName $JobName `
                    -EffectiveJobConfig $effectiveJobConfig `
                    -IsSimulateMode:$IsSimulateMode `
                    -Logger $Logger `
                    -PSCmdlet $PSCmdlet
            }
            catch { & $LocalWriteLog -Message "[ERROR] JobExecutor: Could not load or execute the LocalRetentionHandler. Local retention skipped. Error: $($_.Exception.Message)" -Level "ERROR" }

            try {
                Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "JobExecutor.RemoteTransferHandler.psm1") -Force -ErrorAction Stop
                $allRemoteTransfersSucceeded = Invoke-PoShBackupRemoteTransferExecution -JobName $JobName `
                    -EffectiveJobConfig $effectiveJobConfig `
                    -FinalLocalArchivePath $finalLocalArchivePath `
                    -ArchiveFileNameOnly $archiveFileNameOnly `
                    -JobReportDataRef $JobReportDataRef `
                    -IsSimulateMode:$IsSimulateMode `
                    -Logger $Logger `
                    -PSCmdlet $PSCmdlet `
                    -PSScriptRootForPaths $PSScriptRootForPaths `
                    -CurrentJobStatusForTransferCheck $currentJobStatus `
                    -SkipRemoteTransfersDueToLocalVerificationFailure $skipRemoteTransfersDueToLocalVerificationFailure
            }
            catch { & $LocalWriteLog -Message "[ERROR] JobExecutor: Could not load or execute the RemoteTransferHandler. Remote transfers skipped. Error: $($_.Exception.Message)" -Level "ERROR"; $allRemoteTransfersSucceeded = $false }

            if (-not $allRemoteTransfersSucceeded) {
                if ($currentJobStatus -ne "FAILURE") { $currentJobStatus = "WARNINGS" }
            }
        }
        else {
            & $LocalWriteLog -Message "[INFO] JobExecutor: Skipping local retention and remote transfers for job '$JobName' due to local operation status: '$currentJobStatus'." -Level "INFO"
            $allRemoteTransfersSucceeded = $false
        }
    }
    catch {
        $errorMessageText = "FATAL UNHANDLED EXCEPTION in Invoke-PoShBackupJob for job '$JobName': $($_.Exception.ToString())"
        & $LocalWriteLog -Message $errorMessageText -Level "ERROR"
        & $LocalWriteLog -Message "ADVICE: An unexpected error occurred. This could be due to a misconfiguration, a permissions issue, or a bug. Review the full error message above for clues." -Level "ADVICE"
        $currentJobStatus = "FAILURE"
        $reportData.ErrorMessage = if ([string]::IsNullOrWhiteSpace($reportData.ErrorMessage)) { $_.Exception.ToString() } else { "$($reportData.ErrorMessage); $($_.Exception.ToString())" }
        Write-Error -Message $errorMessageText -Exception $_.Exception -ErrorAction Continue
    }
    finally {
        try { Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "JobExecutor.SnapshotCleanupHandler.psm1") -Force -ErrorAction Stop; Invoke-PoShBackupSnapshotCleanup -SnapshotSession $snapshotSessionToCleanUp -JobName $JobName -Logger $Logger -PSCmdlet $PSCmdlet -IsSimulateMode:$IsSimulateMode.IsPresent } catch { & $LocalWriteLog "[ERROR] JobExecutor: Failed to load/run SnapshotCleanupHandler. Error: $($_.Exception.Message)" "ERROR" }
        try { Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "JobExecutor.VssCleanupHandler.psm1") -Force -ErrorAction Stop; Invoke-PoShBackupVssCleanup -VSSPathsToCleanUp $VSSPathsToCleanUp -JobName $JobName -IsSimulateMode:$IsSimulateMode.IsPresent -Logger $Logger } catch { & $LocalWriteLog "[ERROR] JobExecutor: Failed to load/run VssCleanupHandler. Error: $($_.Exception.Message)" "ERROR" }

        if (-not [string]::IsNullOrWhiteSpace($plainTextPasswordToClearAfterJob)) {
            try { $plainTextPasswordToClearAfterJob = $null; Remove-Variable plainTextPasswordToClearAfterJob -Scope Local -ErrorAction SilentlyContinue; [System.GC]::Collect(); [System.GC]::WaitForPendingFinalizers(); & $LocalWriteLog -Message "   - Plain text password for job '$JobName' cleared from JobExecutor module memory." -Level DEBUG }
            catch { & $LocalWriteLog -Message "[WARNING] Exception while clearing plain text password from JobExecutor module memory for job '$JobName'. Error: $($_.Exception.Message)" -Level WARNING }
        }

        $reportData.LogEntries = $Global:GlobalJobLogEntries

        try { Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "JobExecutor.FinalisationHandler.psm1") -Force -ErrorAction Stop; Invoke-PoShBackupJobFinalisation -JobName $JobName -JobReportDataRef $JobReportDataRef -CurrentJobStatus $currentJobStatus -IsSimulateMode:$IsSimulateMode -PlainTextPasswordToClear $null -Logger $Logger } catch { & $LocalWriteLog "[ERROR] JobExecutor: Failed to load/run FinalisationHandler. Error: $($_.Exception.Message)" "ERROR" }

        if ($null -ne $effectiveJobConfig) {
            try { Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "JobExecutor.PostJobHookHandler.psm1") -Force -ErrorAction Stop; Invoke-PoShBackupPostJobHook -JobName $JobName -ReportDataOverallStatus $reportData.OverallStatus -FinalLocalArchivePath $finalLocalArchivePath -ActualConfigFile $ActualConfigFile -IsSimulateMode:$IsSimulateMode -EffectiveJobConfig $effectiveJobConfig -ReportData $reportData -Logger $Logger } catch { & $LocalWriteLog "[ERROR] JobExecutor: Failed to load/run PostJobHookHandler. Error: $($_.Exception.Message)" "ERROR" }
        }
        else { & $LocalWriteLog -Message "[WARNING] JobExecutor: EffectiveJobConfig was not resolved. Post-job hooks cannot be executed for job '$JobName'." -Level "WARNING" }
    }

    return @{ Status = $currentJobStatus }
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupJob
