# Modules\Operations\RemoteTransferOrchestrator.psm1
<#
.SYNOPSIS
    Acts as a facade to orchestrate the transfer of a local backup archive to remote targets.
.DESCRIPTION
    This module is a sub-component of the main Operations module for PoSh-Backup.
    It orchestrates the entire remote transfer process by lazy-loading and calling specialised sub-modules:
    1.  'StagedFileDiscoverer.psm1': To identify all local files that constitute a single
        backup instance (volumes, manifests, etc.).
    2.  'TargetProcessor.psm1': To iterate through the configured remote targets and dispatch
        the actual file transfer operations to the correct provider modules.
    3.  'StagedFileCleanupHandler.psm1': To handle the deletion of local staged files if all
        transfers were successful and the job is configured to do so.

    This facade approach simplifies the remote transfer logic and improves maintainability.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.1.0 # Refactored to lazy-load sub-modules.
    DateCreated:    24-May-2025
    LastModified:   02-Jul-2025
    Purpose:        To orchestrate remote target transfer logic.
    Prerequisites:  PowerShell 5.1+.
#>

function Invoke-RemoteTargetTransferOrchestration {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $true)]
        [string]$LocalFinalArchivePath,
        [Parameter(Mandatory = $true)]
        [string]$JobName,
        [Parameter(Mandatory = $true)]
        [string]$ArchiveFileNameOnly,
        [Parameter(Mandatory = $true)]
        [ref]$JobReportDataRef,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet,
        [Parameter(Mandatory = $true)]
        [string]$PSScriptRootForPaths
    )

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    & $Logger -Message "RemoteTransferOrchestrator (Facade): Initialising for job '$JobName'." -Level "DEBUG"

    if ($EffectiveJobConfig.ResolvedTargetInstances.Count -eq 0) {
        & $LocalWriteLog -Message "[INFO] RemoteTransferOrchestrator (Facade): No remote targets configured. Skipping." -Level "INFO"
        return @{ AllTransfersSuccessful = $true }
    }

    $allTransfersSuccessful = $false # Default to false until we know otherwise
    $localFilesToTransfer = $null

    try {
        # --- 1. Discover all local staged files for this backup instance ---
        try {
            Import-Module -Name (Join-Path $PSScriptRoot "RemoteTransferOrchestrator\StagedFileDiscoverer.psm1") -Force -ErrorAction Stop
            $discovererParams = @{
                LocalFinalArchivePath = $LocalFinalArchivePath
                ArchiveFileNameOnly   = $ArchiveFileNameOnly
                EffectiveJobConfig    = $EffectiveJobConfig
                ReportData            = $JobReportDataRef.Value
                Logger                = $Logger
                IsSimulateMode        = $IsSimulateMode.IsPresent
            }
            $localFilesToTransfer = Find-PoShBackupStagedFile @discovererParams
        }
        catch {
            $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Operations\RemoteTransferOrchestrator\StagedFileDiscoverer.psm1' exists and is not corrupted."
            & $LocalWriteLog -Message "[FATAL] RemoteTransferOrchestrator: Could not load or execute the StagedFileDiscoverer module. Remote transfers cannot proceed. Error: $($_.Exception.Message)" -Level "ERROR"
            & $LocalWriteLog -Message $advice -Level "ADVICE"
            throw
        }

        if ($localFilesToTransfer.Count -eq 0) {
            & $LocalWriteLog -Message "[ERROR] RemoteTransferOrchestrator (Facade): No local files were found for transfer. Aborting remote transfer stage." -Level "ERROR"
            return @{ AllTransfersSuccessful = $false }
        }

        # --- 2. Process all targets, transferring all discovered files to each ---
        try {
            Import-Module -Name (Join-Path $PSScriptRoot "RemoteTransferOrchestrator\TargetProcessor.psm1") -Force -ErrorAction Stop
            $processorParams = @{
                EffectiveJobConfig   = $EffectiveJobConfig
                LocalFilesToTransfer = $localFilesToTransfer
                JobName              = $JobName
                JobReportDataRef     = $JobReportDataRef
                IsSimulateMode       = $IsSimulateMode.IsPresent
                Logger               = $Logger
                PSCmdlet             = $PSCmdlet
                PSScriptRootForPaths = $PSScriptRootForPaths
            }
            $allTransfersSuccessful = Invoke-PoShBackupTargetProcessing @processorParams
        }
        catch {
            $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Operations\RemoteTransferOrchestrator\TargetProcessor.psm1' exists and is not corrupted."
            & $LocalWriteLog -Message "[FATAL] RemoteTransferOrchestrator: Could not load or execute the TargetProcessor module. Remote transfers failed. Error: $($_.Exception.Message)" -Level "ERROR"
            & $LocalWriteLog -Message $advice -Level "ADVICE"
            throw
        }
    }
    catch {
        # This will catch re-thrown errors from the sub-module loading blocks.
        & $LocalWriteLog -Message "[ERROR] RemoteTransferOrchestrator (Facade): A critical failure occurred during transfer orchestration. Error: $($_.Exception.Message)" -Level "ERROR"
        return @{ AllTransfersSuccessful = $false }
    }
    finally {
        # --- 3. Clean up local staged files if all transfers succeeded ---
        if ($null -ne $localFilesToTransfer) {
            try {
                Import-Module -Name (Join-Path $PSScriptRoot "RemoteTransferOrchestrator\StagedFileCleanupHandler.psm1") -Force -ErrorAction Stop
                $cleanupParams = @{
                    AllTransfersSucceeded = $allTransfersSuccessful
                    EffectiveJobConfig    = $EffectiveJobConfig
                    LocalFilesToTransfer  = $localFilesToTransfer
                    IsSimulateMode        = $IsSimulateMode.IsPresent
                    Logger                = $Logger
                    PSCmdletInstance      = $PSCmdlet
                }
                Invoke-PoShBackupStagedFileCleanup @cleanupParams
            }
            catch {
                # Don't throw from a finally block, just log the error.
                 & $LocalWriteLog -Message "[ERROR] RemoteTransferOrchestrator: Could not load or execute the StagedFileCleanupHandler. Local files may not have been cleaned up. Error: $($_.Exception.Message)" -Level "ERROR"
            }
        }
    }

    # --- 4. Return the final status ---
    if ($allTransfersSuccessful) {
        & $LocalWriteLog -Message "[INFO] RemoteTransferOrchestrator (Facade): All remote target transfers for job '$JobName' completed successfully." -Level "SUCCESS"
    }
    else {
        & $LocalWriteLog -Message "[WARNING] RemoteTransferOrchestrator (Facade): One or more remote target transfers for job '$JobName' FAILED or were skipped." -Level "WARNING"
    }

    return @{ AllTransfersSuccessful = $allTransfersSuccessful }
}

Export-ModuleMember -Function Invoke-RemoteTargetTransferOrchestration
