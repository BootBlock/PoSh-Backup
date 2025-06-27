# Modules\Operations\RemoteTransferOrchestrator.psm1
<#
.SYNOPSIS
    Acts as a facade to orchestrate the transfer of a local backup archive to remote targets.
.DESCRIPTION
    This module is a sub-component of the main Operations module for PoSh-Backup.
    It orchestrates the entire remote transfer process by calling specialised sub-modules:
    1.  'StagedFileDiscoverer.psm1': To identify all local files that constitute a single
        backup instance (volumes, manifests, etc.).
    2.  'TargetProcessor.psm1': To iterate through the configured remote targets and dispatch
        the actual file transfer operations to the correct provider modules.
    3.  'StagedFileCleanupHandler.psm1': To handle the deletion of local staged files if all
        transfers were successful and the job is configured to do so.

    This facade approach simplifies the remote transfer logic and improves maintainability.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.0.0 # Refactored into a facade with sub-modules.
    DateCreated:    24-May-2025
    LastModified:   26-Jun-2025
    Purpose:        To orchestrate remote target transfer logic.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Operations
$subModulePath = Join-Path -Path $PSScriptRoot -ChildPath "RemoteTransferOrchestrator"
try {
    Import-Module -Name (Join-Path $subModulePath "StagedFileDiscoverer.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $subModulePath "TargetProcessor.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $subModulePath "StagedFileCleanupHandler.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "RemoteTransferOrchestrator.psm1 (Facade) FATAL: Could not import a required sub-module. Error: $($_.Exception.Message)"
    throw
}
#endregion

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

    # --- 1. Discover all local staged files for this backup instance ---
    $discovererParams = @{
        LocalFinalArchivePath = $LocalFinalArchivePath
        ArchiveFileNameOnly   = $ArchiveFileNameOnly
        EffectiveJobConfig    = $EffectiveJobConfig
        ReportData            = $JobReportDataRef.Value
        Logger                = $Logger
        IsSimulateMode        = $IsSimulateMode.IsPresent
    }
    $localFilesToTransfer = Find-PoShBackupStagedFile @discovererParams

    if ($localFilesToTransfer.Count -eq 0) {
        & $LocalWriteLog -Message "[ERROR] RemoteTransferOrchestrator (Facade): No local files were found for transfer. Aborting remote transfer stage." -Level "ERROR"
        return @{ AllTransfersSuccessful = $false }
    }

    # --- 2. Process all targets, transferring all discovered files to each ---
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

    # --- 3. Clean up local staged files if all transfers succeeded ---
    $cleanupParams = @{
        AllTransfersSucceeded = $allTransfersSuccessful
        EffectiveJobConfig    = $EffectiveJobConfig
        LocalFilesToTransfer  = $localFilesToTransfer
        IsSimulateMode        = $IsSimulateMode.IsPresent
        Logger                = $Logger
        PSCmdletInstance      = $PSCmdlet
    }
    Invoke-PoShBackupStagedFileCleanup @cleanupParams

    # --- 4. Return the final status ---
    if ($allTransfersSuccessful) {
        & $LocalWriteLog -Message "[INFO] RemoteTransferOrchestrator (Facade): All remote target transfers for job '$JobName' completed successfully." -Level "SUCCESS"
    } else {
        & $LocalWriteLog -Message "[WARNING] RemoteTransferOrchestrator (Facade): One or more remote target transfers for job '$JobName' FAILED or were skipped." -Level "WARNING"
    }

    return @{ AllTransfersSuccessful = $allTransfersSuccessful }
}

Export-ModuleMember -Function Invoke-RemoteTargetTransferOrchestration
