# Modules\Operations\RemoteTransferOrchestrator\StagedFileCleanupHandler.psm1
<#
.SYNOPSIS
    A sub-module for RemoteTransferOrchestrator. Handles the cleanup of local staged files.
.DESCRIPTION
    This module provides the 'Invoke-PoShBackupStagedFileCleanup' function. It is responsible
    for deleting the local staged archive files (including all volumes and sidecar files)
    after all remote transfers have completed successfully, but only if the job is configured
    to do so ('DeleteLocalArchiveAfterSuccessfulTransfer' is true).
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.1 # Changed parameter type to handle mock objects from simulation.
    DateCreated:    26-Jun-2025
    LastModified:   27-Jun-2025
    Purpose:        To isolate the logic for cleaning up local staged files post-transfer.
    Prerequisites:  PowerShell 5.1+.
#>

function Invoke-PoShBackupStagedFileCleanup {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$AllTransfersSucceeded,
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]]$LocalFilesToTransfer,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    & $Logger -Message "StagedFileCleanupHandler: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    if ($EffectiveJobConfig.DeleteLocalArchiveAfterSuccessfulTransfer -and $AllTransfersSucceeded -and $EffectiveJobConfig.ResolvedTargetInstances.Count -gt 0) {
        & $LocalWriteLog -Message "[INFO] StagedFileCleanupHandler: Deleting local staged archive files as all target transfers succeeded and 'DeleteLocalArchiveAfterSuccessfulTransfer' is true." -Level "INFO"
        
        foreach($localFileToDeleteInfo in $LocalFilesToTransfer) {
            if ($IsSimulateMode.IsPresent) {
                & $LocalWriteLog -Message "SIMULATE: StagedFileCleanupHandler: Would delete local staged file '$($localFileToDeleteInfo.FullName)'." -Level "SIMULATE"
            }
            elseif ($PSCmdletInstance.ShouldProcess($localFileToDeleteInfo.FullName, "Delete Local Staged Archive File (Post-All-Successful-Transfers)")) {
                & $LocalWriteLog -Message "  - Deleting: '$($localFileToDeleteInfo.FullName)'" -Level "INFO"
                try { Remove-Item -LiteralPath $localFileToDeleteInfo.FullName -Force -ErrorAction Stop }
                catch { & $LocalWriteLog -Message "[WARNING] StagedFileCleanupHandler: Failed to delete local staged file '$($localFileToDeleteInfo.FullName)'. Error: $($_.Exception.Message)" -Level "WARNING" }
            } else {
                 & $LocalWriteLog -Message "  - Deletion of local staged file '$($localFileToDeleteInfo.FullName)' skipped by user (ShouldProcess)." -Level "INFO"
            }
        }
    }
    elseif ($EffectiveJobConfig.DeleteLocalArchiveAfterSuccessfulTransfer -and (-not $AllTransfersSucceeded) -and $EffectiveJobConfig.ResolvedTargetInstances.Count -gt 0) {
        & $LocalWriteLog -Message "[INFO] StagedFileCleanupHandler: Local staged archive files KEPT because one or more target transfers failed (and 'DeleteLocalArchiveAfterSuccessfulTransfer' is true)." -Level "INFO"
    }
}

Export-ModuleMember -Function Invoke-PoShBackupStagedFileCleanup
