# Modules\Core\Operations\JobExecutor.psm1
<#
.SYNOPSIS
    Executes the core backup operations for a single PoSh-Backup job.
    This module is a sub-component of the Core Operations facade.
    It now delegates pre-processing (including snapshot orchestration), local archiving,
    post-job hook execution, local retention policy execution, remote transfer orchestration,
    snapshot/VSS cleanup, and report data finalisation to respective sub-modules.

.DESCRIPTION
    The JobExecutor module orchestrates the lifecycle of processing a single backup job.
    It is called by the Operations.psm1 facade (in Modules\Core).

    The primary exported function, Invoke-PoShBackupJob, performs the following sequence:
    1.  Receives the effective configuration.
    2.  Calls 'Invoke-PoShBackupLocalBackupExecution' to handle pre-processing (including
        infrastructure snapshots via SnapshotManager), and local archive creation/testing.
    3.  Calls 'Invoke-PoShBackupLocalRetentionExecution'.
    4.  If local operations were successful and remote targets are defined (and not skipped),
        calls 'Invoke-PoShBackupRemoteTransferExecution'.
    5.  In the 'finally' block:
        a.  Calls 'Invoke-PoShBackupSnapshotCleanup' to remove any infrastructure snapshots.
        b.  Calls 'Invoke-PoShBackupVssCleanup' to remove any OS-level shadow copies.
        c.  Clears any in-memory plain text password.
        d.  Calls 'Invoke-PoShBackupJobFinalisation'.
        e.  Calls 'Invoke-PoShBackupPostJobHook'.
    6.  Returns overall job status.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.7.0 # Added Snapshot orchestration and cleanup.
    DateCreated:    30-May-2025
    LastModified:   10-Jun-2025
    Purpose:        Handles the execution logic for individual backup jobs.
    Prerequisites:  PowerShell 5.1+, 7-Zip installed.
                    All core PoSh-Backup modules and target provider modules.
                    All JobExecutor.*.psm1 sub-modules.
                    Administrator privileges for VSS and potentially for snapshot providers.
#>

# Explicitly import Utils.psm1 and other direct dependencies.
# $PSScriptRoot here refers to the directory of JobExecutor.psm1 (Modules\Core\Operations).
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "JobExecutor.LocalBackupOrchestrator.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "JobExecutor.PostJobHookHandler.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "JobExecutor.LocalRetentionHandler.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "JobExecutor.RemoteTransferHandler.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "JobExecutor.VssCleanupHandler.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "JobExecutor.SnapshotCleanupHandler.psm1") -Force -ErrorAction Stop # NEW
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "JobExecutor.FinalisationHandler.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "JobExecutor.psm1 (in Modules\Core\Operations) FATAL: Could not import one or more dependent modules. Error: $($_.Exception.Message)"
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
        }
        else {
            & $Logger -Message $Message -Level $Level
        }
    }
    & $LocalWriteLog -Message "Core/Operations/JobExecutor/Invoke-PoShBackupJob: Logger parameter active for job '$JobName'." -Level "DEBUG"

    $currentJobStatus = "SUCCESS"
    $finalLocalArchivePath = $null
    $archiveFileNameOnly = $null
    $VSSPathsToCleanUp = $null
    $snapshotSessionToCleanUp = $null # NEW
    $reportData = $JobReportDataRef.Value
    $reportData.IsSimulationReport = $IsSimulateMode.IsPresent
    $reportData.TargetTransfers = [System.Collections.Generic.List[object]]::new()
    $reportData.ArchiveChecksum = "N/A"
    $reportData.ArchiveChecksumAlgorithm = "N/A"
    $reportData.ArchiveChecksumFile = "N/A"
    $reportData.ArchiveChecksumVerificationStatus = "Not Performed"
    $plainTextPasswordToClearAfterJob = $null
    $effectiveJobConfig = $null
    $skipRemoteTransfersDueToLocalVerificationFailure = $false


    if (-not ($reportData.PSObject.Properties.Name -contains 'ScriptStartTime')) {
        $reportData['ScriptStartTime'] = Get-Date
    }

    try {
        $effectiveJobConfig = $JobConfig

        # --- Call Local Backup Orchestrator (Handles PreProcessing and LocalArchiveOperation) ---
        $localBackupExecutionParams = @{
            JobName            = $JobName
            EffectiveJobConfig = $effectiveJobConfig
            GlobalConfig       = $GlobalConfig
            ActualConfigFile   = $ActualConfigFile
            JobReportDataRef   = $JobReportDataRef
            IsSimulateMode     = $IsSimulateMode.IsPresent
            Logger             = $Logger
            PSCmdlet           = $PSCmdlet
        }
        $localBackupResult = Invoke-PoShBackupLocalBackupExecution @localBackupExecutionParams

        $currentJobStatus = $localBackupResult.LocalBackupStatus
        $finalLocalArchivePath = $localBackupResult.FinalLocalArchivePath
        $archiveFileNameOnly = $localBackupResult.ArchiveFileNameOnly
        $VSSPathsToCleanUp = $localBackupResult.VSSPathsToCleanUp
        $snapshotSessionToCleanUp = $localBackupResult.SnapshotSession # NEW: Capture the session for cleanup
        $plainTextPasswordToClearAfterJob = $localBackupResult.PlainTextPasswordToClear
        $skipRemoteTransfersDueToLocalVerificationFailure = $localBackupResult.SkipRemoteTransfersDueToLocalVerification

        if ($localBackupResult.LocalBackupStatus -ne "FAILURE" -or $IsSimulateMode.IsPresent) {
            # Use $reportData.PSObject.Properties.Name for ordered dictionaries
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

        if ($currentJobStatus -ne "FAILURE") {
            Invoke-PoShBackupLocalRetentionExecution -JobName $JobName `
                -EffectiveJobConfig $effectiveJobConfig `
                -IsSimulateMode:$IsSimulateMode `
                -Logger $Logger `
                -PSCmdlet $PSCmdlet
        } else {
            & $LocalWriteLog -Message "[INFO] JobExecutor: Skipping local retention for job '$JobName' due to earlier FAILURE status." -Level "INFO"
        }

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

        if (-not $allRemoteTransfersSucceeded) {
            if ($currentJobStatus -ne "FAILURE") { $currentJobStatus = "WARNINGS" }
        }
    }
    catch {
        $errorMessageText = "FATAL UNHANDLED EXCEPTION in Invoke-PoShBackupJob for job '$JobName': $($_.Exception.ToString())"
        & $LocalWriteLog -Message $errorMessageText -Level "ERROR"
        $currentJobStatus = "FAILURE"
        $reportData.ErrorMessage = if ([string]::IsNullOrWhiteSpace($reportData.ErrorMessage)) { $_.Exception.ToString() } else { "$($reportData.ErrorMessage); $($_.Exception.ToString())" }
        Write-Error -Message $errorMessageText -Exception $_.Exception -ErrorAction Continue
    }
    finally {
        # NEW: Snapshot cleanup (must run BEFORE VSS cleanup)
        Invoke-PoShBackupSnapshotCleanup -SnapshotSession $snapshotSessionToCleanUp `
            -JobName $JobName `
            -Logger $Logger `
            -PSCmdlet $PSCmdlet

        Invoke-PoShBackupVssCleanup -VSSPathsToCleanUp $VSSPathsToCleanUp `
            -JobName $JobName `
            -IsSimulateMode:$IsSimulateMode `
            -Logger $Logger

        if (-not [string]::IsNullOrWhiteSpace($plainTextPasswordToClearAfterJob)) {
            try {
                $plainTextPasswordToClearAfterJob = $null
                Remove-Variable plainTextPasswordToClearAfterJob -Scope Script -ErrorAction SilentlyContinue
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
                & $LocalWriteLog -Message "   - Plain text password for job '$JobName' cleared from JobExecutor module memory." -Level DEBUG
            }
            catch { & $LocalWriteLog -Message "[WARNING] Exception while clearing plain text password from JobExecutor module memory for job '$JobName'. Error: $($_.Exception.Message)" -Level WARNING }
        }

        Invoke-PoShBackupJobFinalisation -JobName $JobName `
            -JobReportDataRef $JobReportDataRef `
            -CurrentJobStatus $currentJobStatus `
            -IsSimulateMode:$IsSimulateMode `
            -PlainTextPasswordToClear $null `
            -Logger $Logger

        if ($null -ne $effectiveJobConfig) {
            Invoke-PoShBackupPostJobHook -JobName $JobName `
                -ReportDataOverallStatus $reportData.OverallStatus `
                -FinalLocalArchivePath $finalLocalArchivePath `
                -ActualConfigFile $ActualConfigFile `
                -IsSimulateMode:$IsSimulateMode `
                -EffectiveJobConfig $effectiveJobConfig `
                -ReportData $reportData `
                -Logger $Logger
        } else {
            & $LocalWriteLog -Message "[WARNING] JobExecutor: EffectiveJobConfig was not resolved. Post-job hooks cannot be executed for job '$JobName'." -Level "WARNING"
        }
    }

    return @{ Status = $currentJobStatus }
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupJob
