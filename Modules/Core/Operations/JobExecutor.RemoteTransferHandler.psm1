# Modules\Core\Operations\JobExecutor.RemoteTransferHandler.psm1
<#
.SYNOPSIS
    Handles the orchestration of transferring a local backup archive to remote targets.
    This is a sub-module of JobExecutor.psm1.
.DESCRIPTION
    This module provides the 'Invoke-PoShBackupRemoteTransferExecution' function.
    It is responsible for lazy-loading and then calling the main
    'Invoke-RemoteTargetTransferOrchestration' function (from Modules\Operations\RemoteTransferOrchestrator.psm1)
    if remote targets are configured and conditions for transfer are met. It returns the
    success status of the overall remote transfer operations.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Refactored to lazy-load RemoteTransferOrchestrator.
    DateCreated:    30-May-2025
    LastModified:   02-Jul-2025
    Purpose:        To modularise remote target transfer orchestration from JobExecutor.
    Prerequisites:  PowerShell 5.1+.
#>

function Invoke-PoShBackupRemoteTransferExecution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$JobName, # For logging context
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $false)]
        [string]$FinalLocalArchivePath,
        [Parameter(Mandatory = $false)]
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
        [string]$PSScriptRootForPaths,
        [Parameter(Mandatory = $true)]
        [string]$CurrentJobStatusForTransferCheck, # The status after local archive operations
        [Parameter(Mandatory = $true)]
        [bool]$SkipRemoteTransfersDueToLocalVerificationFailure
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
    & $LocalWriteLog -Message "JobExecutor.RemoteTransferHandler/Invoke-PoShBackupRemoteTransferExecution: Initialising for job '$JobName'." -Level "DEBUG"

    $allRemoteTransfersSuccessful = $true # Assume success unless explicitly set otherwise

    if ($CurrentJobStatusForTransferCheck -ne "FAILURE" -and (-not $SkipRemoteTransfersDueToLocalVerificationFailure) -and $EffectiveJobConfig.ResolvedTargetInstances.Count -gt 0) {
        try {
            Import-Module -Name (Join-Path $PSScriptRoot "..\..\Operations\RemoteTransferOrchestrator.psm1") -Force -ErrorAction Stop
            $remoteTransferResult = Invoke-RemoteTargetTransferOrchestration -EffectiveJobConfig $EffectiveJobConfig `
                -LocalFinalArchivePath $FinalLocalArchivePath `
                -JobName $JobName `
                -ArchiveFileNameOnly $archiveFileNameOnly `
                -JobReportDataRef $JobReportDataRef `
                -IsSimulateMode:$IsSimulateMode `
                -Logger $Logger `
                -PSCmdlet $PSCmdlet `
                -PSScriptRootForPaths $PSScriptRootForPaths

            if (-not $remoteTransferResult.AllTransfersSuccessful) {
                $allRemoteTransfersSuccessful = $false
            }
        }
        catch {
            $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Operations\RemoteTransferOrchestrator.psm1' and its sub-modules exist and are not corrupted."
            & $LocalWriteLog -Message "[FATAL] RemoteTransferHandler: Could not load or execute the RemoteTransferOrchestrator. Remote transfers skipped. Error: $($_.Exception.Message)" -Level "ERROR"
            & $LocalWriteLog -Message $advice -Level "ADVICE"
            $allRemoteTransfersSuccessful = $false
        }
    }
    elseif ($CurrentJobStatusForTransferCheck -eq "FAILURE") {
        & $LocalWriteLog -Message "[WARNING] JobExecutor.RemoteTransferHandler: Remote target transfers skipped for job '$JobName' due to failure in local archive creation/testing." -Level "WARNING"
        $allRemoteTransfersSuccessful = $false
    }
    elseif ($SkipRemoteTransfersDueToLocalVerificationFailure) {
        & $LocalWriteLog -Message "[INFO] JobExecutor.RemoteTransferHandler: Remote target transfers were skipped for job '$JobName' due to local verification failure as per log." -Level "INFO"
        $allRemoteTransfersSuccessful = $false
    }
    elseif ($EffectiveJobConfig.ResolvedTargetInstances.Count -eq 0) {
        & $LocalWriteLog -Message "JobExecutor.RemoteTransferHandler: No remote targets configured for job '$JobName'. Skipping remote transfers." -Level "DEBUG"
    }

    & $LocalWriteLog -Message "JobExecutor.RemoteTransferHandler/Invoke-PoShBackupRemoteTransferExecution: Remote transfer execution phase complete for job '$JobName'. Success: $allRemoteTransfersSuccessful" -Level "DEBUG"
    return $allRemoteTransfersSuccessful
}

Export-ModuleMember -Function Invoke-PoShBackupRemoteTransferExecution
