# Modules\Core\Operations\JobExecutor.LocalBackupOrchestrator.psm1
<#
.SYNOPSIS
    Orchestrates the pre-processing and local archive creation phases of a PoSh-Backup job.
    This is a sub-module of JobExecutor.psm1.
.DESCRIPTION
    This module provides the 'Invoke-PoShBackupLocalBackupExecution' function. It is
    responsible for lazy-loading and then orchestrating its sub-modules:
    1. It calls 'Invoke-PoShBackupJobPreProcessing' from 'JobPreProcessor.psm1' to handle
       snapshotting, VSS, password retrieval, path validation, and pre-backup hooks.
    2. Based on the status from pre-processing (Proceed, SkipJob, FailJob), it either:
        - Calls 'Invoke-LocalArchiveOperation' from 'LocalArchiveProcessor.psm1' to create the
          local archive, generate checksums, and perform local tests.
        - Skips the job gracefully if a source path was not found and the policy is 'SkipJob'.
        - Fails the job if pre-processing failed.
    3. It determines if remote transfers should be skipped based on local archive
       verification failures if the 'VerifyLocalArchiveBeforeTransfer' option is enabled.
    The function returns a hashtable containing the outcome of these local operations,
    paths, and any necessary data for subsequent steps like snapshot/VSS cleanup or password clearing.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.3.0 # Refactored to lazy-load dependencies.
    DateCreated:    30-May-2025
    LastModified:   02-Jul-2025
    Purpose:        To modularise the main local backup sequence from JobExecutor.
    Prerequisites:  PowerShell 5.1+.
#>

function Invoke-PoShBackupLocalBackupExecution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$JobName,
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $true)]
        [string]$ActualConfigFile, # For JobPreProcessor
        [Parameter(Mandatory = $true)]
        [ref]$JobReportDataRef,
        [Parameter(Mandatory = $true)]
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
    & $LocalWriteLog -Message "JobExecutor.LocalBackupOrchestrator/Invoke-PoShBackupLocalBackupExecution: Initialising for job '$JobName'." -Level "DEBUG"

    $reportData = $JobReportDataRef.Value # For direct updates if needed, and passing by ref
    $currentLocalJobStatus = "SUCCESS" # Assume success initially for this scope
    $finalLocalArchivePathFromOps = $null
    $archiveFileNameOnlyFromOps = $null
    $vssPathsToCleanUpFromOps = $null
    $snapshotSessionFromOps = $null
    $plainTextPasswordToClearFromOps = $null
    $skipRemoteTransfersDueToLocalVerification = $false
    $preProcessingResult = $null

    # --- Call Job Pre-Processor ---
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "..\..\Operations\JobPreProcessor.psm1") -Force -ErrorAction Stop
        $preProcessingParams = @{
            JobName            = $JobName
            EffectiveJobConfig = $EffectiveJobConfig
            IsSimulateMode     = $IsSimulateMode.IsPresent
            Logger             = $Logger
            PSCmdlet           = $PSCmdlet
            ActualConfigFile   = $ActualConfigFile
            JobReportDataRef   = $JobReportDataRef
        }
        $preProcessingResult = Invoke-PoShBackupJobPreProcessing @preProcessingParams
    }
    catch {
        $errorMessage = "Could not load or execute the JobPreProcessor module. Job cannot proceed. Error: $($_.Exception.Message)"
        $adviceMessage = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Operations\JobPreProcessor.psm1' exists and is not corrupted."
        & $LocalWriteLog -Message "[FATAL] LocalBackupOrchestrator: $errorMessage" -Level "ERROR"
        & $LocalWriteLog -Message $adviceMessage -Level "ADVICE"
        # Since pre-processing failed critically, we must ensure the job fails.
        $preProcessingResult = @{ Status = 'FailJob'; ErrorMessage = $errorMessage }
    }

    # The pre-processor now returns a detailed status.
    switch ($preProcessingResult.Status) {
        'FailJob' {
            $currentLocalJobStatus = "FAILURE"
            if ([string]::IsNullOrWhiteSpace($reportData.ErrorMessage) -and (-not [string]::IsNullOrWhiteSpace($preProcessingResult.ErrorMessage))) {
                $reportData.ErrorMessage = $preProcessingResult.ErrorMessage
            }
            & $LocalWriteLog -Message "[ERROR] JobExecutor.LocalBackupOrchestrator: Job pre-processing failed for job '$JobName'. Status set to FAILURE. Reason: $($preProcessingResult.ErrorMessage)" -Level "ERROR"
        }
        'SkipJob' {
            $currentLocalJobStatus = "SKIPPED_SOURCE_MISSING" # New status
            if ([string]::IsNullOrWhiteSpace($reportData.ErrorMessage) -and (-not [string]::IsNullOrWhiteSpace($preProcessingResult.ErrorMessage))) {
                $reportData.ErrorMessage = $preProcessingResult.ErrorMessage
            }
            & $LocalWriteLog -Message "[WARNING] JobExecutor.LocalBackupOrchestrator: Job '$JobName' skipped as per pre-processor result (e.g., source missing). Reason: $($preProcessingResult.ErrorMessage)" -Level "WARNING"
        }
        'Proceed' {
            $currentJobSourcePathFor7Zip = $preProcessingResult.CurrentJobSourcePathFor7Zip
            $actualPlainTextPasswordFromPreProcessing = $preProcessingResult.ActualPlainTextPassword
            $vssPathsToCleanUpFromOps = $preProcessingResult.VSSPathsInUse
            $snapshotSessionFromOps = $preProcessingResult.SnapshotSession
            $plainTextPasswordToClearFromOps = $preProcessingResult.PlainTextPasswordToClear

            # --- Call Local Archive Processor ---
            try {
                Import-Module -Name (Join-Path $PSScriptRoot "..\..\Operations\LocalArchiveProcessor.psm1") -Force -ErrorAction Stop
                $localArchiveOpParams = @{
                    EffectiveJobConfig          = $EffectiveJobConfig
                    CurrentJobSourcePathFor7Zip = $currentJobSourcePathFor7Zip
                    ArchivePasswordPlainText    = $actualPlainTextPasswordFromPreProcessing
                    JobReportDataRef            = $JobReportDataRef
                    IsSimulateMode              = $IsSimulateMode.IsPresent
                    Logger                      = $Logger
                    PSCmdlet                    = $PSCmdlet
                    SevenZipCpuAffinityString   = $EffectiveJobConfig.JobSevenZipCpuAffinity
                    ActualConfigFile            = $ActualConfigFile
                }
                $localArchiveResult = Invoke-LocalArchiveOperation @localArchiveOpParams
            }
            catch {
                $errorMessage = "Could not load or execute the LocalArchiveProcessor module. Job has failed. Error: $($_.Exception.Message)"
                $adviceMessage = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Operations\LocalArchiveProcessor.psm1' exists and is not corrupted."
                & $LocalWriteLog -Message "[FATAL] LocalBackupOrchestrator: $errorMessage" -Level "ERROR"
                & $LocalWriteLog -Message $adviceMessage -Level "ADVICE"
                $localArchiveResult = @{ Status = 'FAILURE'; ErrorMessage = $errorMessage }
            }

            $currentLocalJobStatus = $localArchiveResult.Status # This will be SUCCESS, WARNINGS, or FAILURE
            $finalLocalArchivePathFromOps = $localArchiveResult.FinalArchivePath
            $archiveFileNameOnlyFromOps = $localArchiveResult.ArchiveFileNameOnly

            if ($EffectiveJobConfig.VerifyLocalArchiveBeforeTransfer -and $currentLocalJobStatus -ne "SUCCESS" -and $currentLocalJobStatus -ne "SIMULATED_COMPLETE") {
                $skipRemoteTransfersDueToLocalVerification = $true
            }
        }
        default {
            # Fallback for safety in case of an unexpected status from the pre-processor
            $currentLocalJobStatus = "FAILURE"
            $reportData.ErrorMessage = "Unknown status '$($preProcessingResult.Status)' returned from pre-processor for job '$JobName'."
            & $LocalWriteLog -Message "[ERROR] JobExecutor.LocalBackupOrchestrator: $($reportData.ErrorMessage)" -Level "ERROR"
        }
    }

    & $LocalWriteLog -Message "JobExecutor.LocalBackupOrchestrator/Invoke-PoShBackupLocalBackupExecution: Local backup execution phase complete for job '$JobName'. Status: $currentLocalJobStatus" -Level "DEBUG"

    return @{
        LocalBackupStatus                           = $currentLocalJobStatus
        FinalLocalArchivePath                       = $finalLocalArchivePathFromOps
        ArchiveFileNameOnly                         = $archiveFileNameOnlyFromOps
        VSSPathsToCleanUp                           = $vssPathsToCleanUpFromOps
        SnapshotSession                             = $snapshotSessionFromOps
        PlainTextPasswordToClear                    = $plainTextPasswordToClearFromOps
        SkipRemoteTransfersDueToLocalVerification   = $skipRemoteTransfersDueToLocalVerification
    }
}

Export-ModuleMember -Function Invoke-PoShBackupLocalBackupExecution
