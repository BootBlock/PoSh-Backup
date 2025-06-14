# Modules\Core\Operations\JobExecutor.LocalBackupOrchestrator.psm1
<#
.SYNOPSIS
    Orchestrates the pre-processing and local archive creation phases of a PoSh-Backup job.
    This is a sub-module of JobExecutor.psm1.
.DESCRIPTION
    This module provides the 'Invoke-PoShBackupLocalBackupExecution' function.
    It is responsible for:
    1. Calling 'Invoke-PoShBackupJobPreProcessing' to handle snapshotting, VSS, password retrieval,
       destination checks, and pre-backup hooks.
    2. If pre-processing is successful, it calls 'Invoke-LocalArchiveOperation' to
       create the local archive, generate checksums, and perform local tests.
    3. It determines if remote transfers should be skipped based on local archive
       verification failures if the 'VerifyLocalArchiveBeforeTransfer' option is enabled.
    The function returns a hashtable containing the outcome of these local operations,
    paths, and any necessary data for subsequent steps like snapshot/VSS cleanup or password clearing.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Added SnapshotSession handling.
    DateCreated:    30-May-2025
    LastModified:   10-Jun-2025
    Purpose:        To modularise the main local backup sequence from JobExecutor.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Modules\Operations\JobPreProcessor.psm1 and
                    Modules\Operations\LocalArchiveProcessor.psm1.
#>

# Explicitly import dependent modules from the 'Modules\Operations' directory.
# $PSScriptRoot here is Modules\Core\Operations.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Operations\JobPreProcessor.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Operations\LocalArchiveProcessor.psm1") -Force -ErrorAction Stop
    # Utils.psm1 is used by the imported modules, assumed to be loaded by the calling context (JobExecutor)
}
catch {
    Write-Error "JobExecutor.LocalBackupOrchestrator.psm1 FATAL: Could not import dependent modules. Error: $($_.Exception.Message)"
    throw
}

function Invoke-PoShBackupLocalBackupExecution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$JobName,
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $true)]
        [hashtable]$GlobalConfig, # For LocalArchiveProcessor
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
    & $LocalWriteLog -Message "JobExecutor.LocalBackupOrchestrator/Invoke-PoShBackupLocalBackupExecution: Initializing for job '$JobName'." -Level "DEBUG"

    $reportData = $JobReportDataRef.Value # For direct updates if needed, and passing by ref
    $currentLocalJobStatus = "SUCCESS" # Assume success initially for this scope
    $finalLocalArchivePathFromOps = $null
    $archiveFileNameOnlyFromOps = $null
    $vssPathsToCleanUpFromOps = $null
    $snapshotSessionFromOps = $null # NEW
    $plainTextPasswordToClearFromOps = $null
    $skipRemoteTransfersDueToLocalVerification = $false

    # --- Call Job Pre-Processor ---
    $preProcessingParams = @{
        JobName            = $JobName
        EffectiveJobConfig = $EffectiveJobConfig
        GlobalConfig       = $GlobalConfig
        IsSimulateMode     = $IsSimulateMode.IsPresent
        Logger             = $Logger
        PSCmdlet           = $PSCmdlet
        ActualConfigFile   = $ActualConfigFile
        JobReportDataRef   = $JobReportDataRef # Pass the ref
    }
    $preProcessingResult = Invoke-PoShBackupJobPreProcessing @preProcessingParams

    if (-not $preProcessingResult.Success) {
        $currentLocalJobStatus = "FAILURE"
        if ([string]::IsNullOrWhiteSpace($reportData.ErrorMessage) -and (-not [string]::IsNullOrWhiteSpace($preProcessingResult.ErrorMessage))) {
            $reportData.ErrorMessage = $preProcessingResult.ErrorMessage
        }
        & $LocalWriteLog -Message "[ERROR] JobExecutor.LocalBackupOrchestrator: Job pre-processing failed for job '$JobName'. Status set to FAILURE. Reason: $($preProcessingResult.ErrorMessage)" -Level "ERROR"
    }
    else {
        $currentJobSourcePathFor7Zip = $preProcessingResult.CurrentJobSourcePathFor7Zip
        $actualPlainTextPasswordFromPreProcessing = $preProcessingResult.ActualPlainTextPassword
        $vssPathsToCleanUpFromOps = $preProcessingResult.VSSPathsInUse
        $snapshotSessionFromOps = $preProcessingResult.SnapshotSession # NEW: Capture the session object
        $plainTextPasswordToClearFromOps = $preProcessingResult.PlainTextPasswordToClear

        # --- Call Local Archive Processor ---
        $localArchiveOpParams = @{
            EffectiveJobConfig          = $EffectiveJobConfig
            CurrentJobSourcePathFor7Zip = $currentJobSourcePathFor7Zip
            ArchivePasswordPlainText    = $actualPlainTextPasswordFromPreProcessing
            JobReportDataRef            = $JobReportDataRef # Pass the ref
            IsSimulateMode              = $IsSimulateMode.IsPresent
            Logger                      = $Logger
            PSCmdlet                    = $PSCmdlet
            GlobalConfig                = $GlobalConfig
            SevenZipCpuAffinityString   = $EffectiveJobConfig.JobSevenZipCpuAffinity
            ActualConfigFile            = $ActualConfigFile
        }
        $localArchiveResult = Invoke-LocalArchiveOperation @localArchiveOpParams

        $currentLocalJobStatus = $localArchiveResult.Status # This will be SUCCESS, WARNINGS, or FAILURE
        $finalLocalArchivePathFromOps = $localArchiveResult.FinalArchivePath
        $archiveFileNameOnlyFromOps = $localArchiveResult.ArchiveFileNameOnly

        if ($EffectiveJobConfig.VerifyLocalArchiveBeforeTransfer -and $currentLocalJobStatus -ne "SUCCESS" -and $currentLocalJobStatus -ne "SIMULATED_COMPLETE") {
            $skipRemoteTransfersDueToLocalVerification = $true
            # Message already logged by LocalArchiveProcessor if VerifyLocalArchiveBeforeTransfer is true and test fails
        }
    }

    & $LocalWriteLog -Message "JobExecutor.LocalBackupOrchestrator/Invoke-PoShBackupLocalBackupExecution: Local backup execution phase complete for job '$JobName'. Status: $currentLocalJobStatus" -Level "DEBUG"

    return @{
        LocalBackupStatus                           = $currentLocalJobStatus
        FinalLocalArchivePath                       = $finalLocalArchivePathFromOps
        ArchiveFileNameOnly                         = $archiveFileNameOnlyFromOps
        VSSPathsToCleanUp                           = $vssPathsToCleanUpFromOps
        SnapshotSession                             = $snapshotSessionFromOps # NEW: Return the session object
        PlainTextPasswordToClear                    = $plainTextPasswordToClearFromOps
        SkipRemoteTransfersDueToLocalVerification   = $skipRemoteTransfersDueToLocalVerification
    }
}

Export-ModuleMember -Function Invoke-PoShBackupLocalBackupExecution
