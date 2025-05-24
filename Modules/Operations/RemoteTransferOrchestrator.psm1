# Modules\Operations\RemoteTransferOrchestrator.psm1
<#
.SYNOPSIS
    Orchestrates the transfer of a local backup archive to multiple configured remote targets.
.DESCRIPTION
    This module is a sub-component of the main Operations module for PoSh-Backup.
    It encapsulates the logic for:
    - Iterating through resolved remote target instances defined for a job.
    - Dynamically loading the appropriate target provider module (e.g., UNC.Target.psm1, SFTP.Target.psm1)
      from the 'Modules\Targets\' directory.
    - Invoking the 'Invoke-PoShBackupTargetTransfer' function within the loaded provider module.
    - Aggregating the results from each target transfer.
    - Handling the deletion of the local staged archive if all transfers are successful and configured.
    - Updating the job report data with the outcomes of all remote transfers.

    It is designed to be called by the main Invoke-PoShBackupJob function in Operations.psm1
    after the local archive has been successfully created and (optionally) verified.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.1 # Renamed Invoke-AllRemoteTargetTransfers to Invoke-RemoteTargetTransferOrchestration.
    DateCreated:    24-May-2025
    LastModified:   24-May-2025
    Purpose:        To modularise remote target transfer orchestration from the main Operations module.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Utils.psm1 from the parent 'Modules' directory.
                    Target provider modules must exist in 'Modules\Targets\'.
#>

# Explicitly import dependent modules from the parent 'Modules' directory.
# $PSScriptRoot here is Modules\Operations.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
} catch {
    Write-Error "RemoteTransferOrchestrator.psm1 FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}

function Invoke-RemoteTargetTransferOrchestration { # Renamed from Invoke-AllRemoteTargetTransfers
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $true)]
        [string]$LocalFinalArchivePath,
        [Parameter(Mandatory = $true)]
        [string]$ArchiveFileNameOnly, # The leaf name of the archive, e.g., MyArchive_Date.7z
        [Parameter(Mandatory = $true)]
        [ref]$JobReportDataRef,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet,
        [Parameter(Mandatory = $true)]
        [string]$PSScriptRootForPaths # Main script's PSScriptRoot for finding Target modules
    )

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    # PSSA: Logger parameter used via $LocalWriteLog
    & $LocalWriteLog -Message "RemoteTransferOrchestrator/Invoke-RemoteTargetTransferOrchestration: Logger active for job '$($EffectiveJobConfig.JobName)'." -Level "DEBUG" # Updated function name

    $reportData = $JobReportDataRef.Value
    $allTargetTransfersSuccessfulOverall = $true # Assume success until a failure occurs
    $jobName = $EffectiveJobConfig.JobName

    if ($EffectiveJobConfig.ResolvedTargetInstances.Count -eq 0) {
        & $LocalWriteLog -Message "[INFO] RemoteTransferOrchestrator: No remote targets configured for job '$jobName'. Skipping remote transfers." -Level "INFO"
        return @{ AllTransfersSuccessful = $true } 
    }

    & $LocalWriteLog -Message "`n[INFO] RemoteTransferOrchestrator: Starting remote target transfers for job '$jobName'..." -Level "INFO"

    if (-not $IsSimulateMode.IsPresent -and -not (Test-Path -LiteralPath $LocalFinalArchivePath -PathType Leaf)) {
        & $LocalWriteLog -Message "[ERROR] RemoteTransferOrchestrator: Local staged archive '$LocalFinalArchivePath' not found. Cannot proceed with remote target transfers." -Level "ERROR"
        foreach ($targetInstanceConfig in $EffectiveJobConfig.ResolvedTargetInstances) {
            $targetInstanceName = $targetInstanceConfig._TargetInstanceName_
            $targetInstanceType = $targetInstanceConfig.Type
            $reportData.TargetTransfers.Add(@{
                TargetName   = $targetInstanceName
                TargetType   = $targetInstanceType
                Status       = "Skipped"
                RemotePath   = "N/A"
                ErrorMessage = "Local source archive not found: $LocalFinalArchivePath"
                TransferDuration = "N/A"
                TransferSize = 0
                TransferSizeFormatted = "N/A"
            })
        }
        return @{ AllTransfersSuccessful = $false }
    }

    $localArchiveSizeBytesForTransfer = 0
    $localArchiveCreationTimestampForTransfer = Get-Date 
    if (-not $IsSimulateMode.IsPresent -and (Test-Path -LiteralPath $LocalFinalArchivePath -PathType Leaf)) {
        try {
            $archiveItem = Get-Item -LiteralPath $LocalFinalArchivePath
            $localArchiveSizeBytesForTransfer = $archiveItem.Length
            $localArchiveCreationTimestampForTransfer = $archiveItem.CreationTime
        } catch {
            & $LocalWriteLog -Message "[WARNING] RemoteTransferOrchestrator: Could not get size/timestamp for local archive '$LocalFinalArchivePath'. Using defaults. Error: $($_.Exception.Message)" -Level "WARNING"
        }
    } elseif ($IsSimulateMode.IsPresent) {
        $localArchiveSizeBytesForTransfer = if ($reportData.ContainsKey('ArchiveSizeBytes')) { $reportData.ArchiveSizeBytes } else { 0 }
        $localArchiveCreationTimestampForTransfer = Get-Date 
    }


    foreach ($targetInstanceConfig in $EffectiveJobConfig.ResolvedTargetInstances) {
        $targetInstanceName = $targetInstanceConfig._TargetInstanceName_
        $targetInstanceType = $targetInstanceConfig.Type
        & $LocalWriteLog -Message "  - RemoteTransferOrchestrator: Preparing transfer to Target Instance: '$targetInstanceName' (Type: '$targetInstanceType')." -Level "INFO"

        $targetProviderModuleName = "$($targetInstanceType).Target.psm1"
        $targetProviderModulePath = Join-Path -Path $PSScriptRootForPaths -ChildPath "Modules\Targets\$targetProviderModuleName"

        $currentTransferReport = @{
            TargetName            = $targetInstanceName
            TargetType            = $targetInstanceType
            Status                = "Skipped"
            RemotePath            = "N/A"
            ErrorMessage          = "Provider module load/call failed."
            TransferDuration      = "N/A"
            TransferSize          = 0
            TransferSizeFormatted = "N/A"
        }

        if (-not (Test-Path -LiteralPath $targetProviderModulePath -PathType Leaf)) {
            & $LocalWriteLog -Message "[ERROR] RemoteTransferOrchestrator: Target Provider module '$targetProviderModuleName' for type '$targetInstanceType' not found at '$targetProviderModulePath'. Skipping transfer to '$targetInstanceName'." -Level "ERROR"
            $currentTransferReport.Status = "Failure (Provider Not Found)"
            $currentTransferReport.ErrorMessage = "Provider module '$targetProviderModuleName' not found."
            $reportData.TargetTransfers.Add($currentTransferReport)
            $allTargetTransfersSuccessfulOverall = $false
            continue
        }

        try {
            Import-Module -Name $targetProviderModulePath -Force -ErrorAction Stop -WarningAction SilentlyContinue
            $invokeTargetTransferCmd = Get-Command Invoke-PoShBackupTargetTransfer -Module (Get-Module -Name $targetProviderModuleName.Replace(".psm1", "")) -ErrorAction SilentlyContinue
            if (-not $invokeTargetTransferCmd) {
                throw "Function 'Invoke-PoShBackupTargetTransfer' not found in provider module '$targetProviderModuleName'."
            }

            $transferParams = @{
                LocalArchivePath            = $LocalFinalArchivePath
                TargetInstanceConfiguration = $targetInstanceConfig
                JobName                     = $jobName
                ArchiveFileName             = $ArchiveFileNameOnly
                ArchiveBaseName             = $EffectiveJobConfig.BaseFileName 
                ArchiveExtension            = $EffectiveJobConfig.JobArchiveExtension 
                IsSimulateMode              = $IsSimulateMode.IsPresent
                Logger                      = $Logger
                EffectiveJobConfig          = $EffectiveJobConfig
                LocalArchiveSizeBytes       = $localArchiveSizeBytesForTransfer
                LocalArchiveCreationTimestamp = $localArchiveCreationTimestampForTransfer
                PasswordInUse               = $EffectiveJobConfig.PasswordInUseFor7Zip
                PSCmdlet                    = $PSCmdlet
            }
            $transferOutcome = & $invokeTargetTransferCmd @transferParams

            $currentTransferReport.Status = if ($transferOutcome.Success) { "Success" } else { "Failure" }
            $currentTransferReport.RemotePath = $transferOutcome.RemotePath
            $currentTransferReport.ErrorMessage = $transferOutcome.ErrorMessage
            $currentTransferReport.TransferDuration = if ($null -ne $transferOutcome.TransferDuration) { $transferOutcome.TransferDuration.ToString() } else { "N/A" }
            $currentTransferReport.TransferSize = $transferOutcome.TransferSize

            if (-not [string]::IsNullOrWhiteSpace($transferOutcome.RemotePath) -and $transferOutcome.Success -and (-not $IsSimulateMode.IsPresent)) {
                if (Test-Path -LiteralPath $transferOutcome.RemotePath -ErrorAction SilentlyContinue) {
                    $currentTransferReport.TransferSizeFormatted = Get-ArchiveSizeFormatted -PathToArchive $transferOutcome.RemotePath -Logger $Logger
                } else { $currentTransferReport.TransferSizeFormatted = Get-UtilityArchiveSizeFormattedFromByte -Bytes $transferOutcome.TransferSize }
            } elseif ($IsSimulateMode.IsPresent -and $transferOutcome.TransferSize -gt 0) {
                $currentTransferReport.TransferSizeFormatted = Get-UtilityArchiveSizeFormattedFromByte -Bytes $transferOutcome.TransferSize
            } else {
                $currentTransferReport.TransferSizeFormatted = "N/A"
            }
            
            if ($transferOutcome.ContainsKey('ReplicationDetails') -and $transferOutcome.ReplicationDetails -is [array] -and $transferOutcome.ReplicationDetails.Count -gt 0) {
                $currentTransferReport.ReplicationDetails = $transferOutcome.ReplicationDetails 
                & $LocalWriteLog -Message "    - RemoteTransferOrchestrator: Replication Details for Target '$targetInstanceName':" -Level "INFO"
                foreach ($detail in $transferOutcome.ReplicationDetails) {
                    $detailStatusText = if ($null -ne $detail.Status) { $detail.Status } else { "N/A" }
                    $detailPathText = if ($null -ne $detail.Path) { $detail.Path } else { "N/A" }
                    $detailErrorText = if ($null -ne $detail.Error -and -not [string]::IsNullOrWhiteSpace($detail.Error)) { $detail.Error } else { "None" }
                    & $LocalWriteLog -Message "      - Dest: '$detailPathText', Status: $detailStatusText, Error: $detailErrorText" -Level "INFO"
                }
            }

            if (-not $transferOutcome.Success) {
                $allTargetTransfersSuccessfulOverall = $false
                & $LocalWriteLog -Message "[ERROR] RemoteTransferOrchestrator: Transfer to Target '$targetInstanceName' FAILED. Reason: $($transferOutcome.ErrorMessage)" -Level "ERROR"
            } else {
                & $LocalWriteLog -Message "  - RemoteTransferOrchestrator: Transfer to Target '$targetInstanceName' SUCCEEDED. Remote Path: $($transferOutcome.RemotePath)" -Level "SUCCESS"
            }

        } catch {
            & $LocalWriteLog -Message "[ERROR] RemoteTransferOrchestrator: Critical error during transfer to Target '$targetInstanceName' (Type: '$targetInstanceType'). Error: $($_.Exception.ToString())" -Level "ERROR"
            $currentTransferReport.Status = "Failure (Exception)"
            $currentTransferReport.ErrorMessage = $_.Exception.ToString()
            $allTargetTransfersSuccessfulOverall = $false
        }
        $reportData.TargetTransfers.Add($currentTransferReport)
    }

    if ($allTargetTransfersSuccessfulOverall -and $EffectiveJobConfig.ResolvedTargetInstances.Count -gt 0) {
        & $LocalWriteLog -Message "[INFO] RemoteTransferOrchestrator: All attempted remote target transfers for job '$jobName' completed successfully." -Level "SUCCESS"
    } elseif ($EffectiveJobConfig.ResolvedTargetInstances.Count -gt 0) {
        & $LocalWriteLog -Message "[WARNING] RemoteTransferOrchestrator: One or more remote target transfers for job '$jobName' FAILED or were skipped due to errors." -Level "WARNING"
    }

    if ($EffectiveJobConfig.DeleteLocalArchiveAfterSuccessfulTransfer -and $allTargetTransfersSuccessfulOverall -and $EffectiveJobConfig.ResolvedTargetInstances.Count -gt 0) {
        if ((-not $IsSimulateMode.IsPresent) -and (Test-Path -LiteralPath $LocalFinalArchivePath -PathType Leaf)) {
            if ($PSCmdlet.ShouldProcess($LocalFinalArchivePath, "Delete Local Staged Archive (Post-All-Successful-Transfers)")) {
                & $LocalWriteLog -Message "[INFO] RemoteTransferOrchestrator: Deleting local staged archive '$LocalFinalArchivePath' as all target transfers succeeded and DeleteLocalArchiveAfterSuccessfulTransfer is true." -Level "INFO"
                try { Remove-Item -LiteralPath $LocalFinalArchivePath -Force -ErrorAction Stop }
                catch { & $LocalWriteLog -Message "[WARNING] RemoteTransferOrchestrator: Failed to delete local staged archive '$LocalFinalArchivePath'. Error: $($_.Exception.Message)" -Level "WARNING" }
            }
        } elseif ($IsSimulateMode.IsPresent) {
            & $LocalWriteLog -Message "SIMULATE: RemoteTransferOrchestrator: Would delete local staged archive '$LocalFinalArchivePath' (all target transfers successful and configured to delete)." -Level "SIMULATE"
        }
    } elseif ($EffectiveJobConfig.DeleteLocalArchiveAfterSuccessfulTransfer -and (-not $allTargetTransfersSuccessfulOverall) -and $EffectiveJobConfig.ResolvedTargetInstances.Count -gt 0) {
        & $LocalWriteLog -Message "[INFO] RemoteTransferOrchestrator: Local staged archive '$LocalFinalArchivePath' KEPT because one or more target transfers failed (and DeleteLocalArchiveAfterSuccessfulTransfer is true)." -Level "INFO"
    }

    return @{ AllTransfersSuccessful = $allTargetTransfersSuccessfulOverall }
}

Export-ModuleMember -Function Invoke-RemoteTargetTransferOrchestration # Updated export
