# Modules\Operations\RemoteTransferOrchestrator.psm1
<#
.SYNOPSIS
    Orchestrates the transfer of a local backup archive (including all volumes of a
    split set and any associated manifest file) to multiple configured remote targets.
.DESCRIPTION
    This module is a sub-component of the main Operations module for PoSh-Backup.
    It encapsulates the logic for:
    - Identifying all local archive files to transfer (single file, or all volumes of a split set, plus any manifest file).
    - Iterating through resolved remote target instances defined for a job.
    - Dynamically loading the appropriate target provider module.
    - Invoking the 'Invoke-PoShBackupTargetTransfer' function within the loaded provider module for each file to be transferred.
    - Aggregating the results from each target transfer.
    - Handling the deletion of all local staged archive files (volumes and manifest) if all transfers are successful and configured.
    - Updating the job report data with the outcomes of all remote transfers.

    It is designed to be called by the main Invoke-PoShBackupJob function in Operations.psm1
    after the local archive has been successfully created and (optionally) verified.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Handles multi-volume transfer and manifest file transfer.
    DateCreated:    24-May-2025
    LastModified:   01-Jun-2025
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

function Invoke-RemoteTargetTransferOrchestration {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $true)] # Path to the first volume or the single archive file
        [string]$LocalFinalArchivePath,
        [Parameter(Mandatory = $true)] # Base archive name (e.g., MyJob [Date].7z or MyJob [Date].exe)
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
    & $LocalWriteLog -Message "RemoteTransferOrchestrator/Invoke-RemoteTargetTransferOrchestration: Logger active for job '$($EffectiveJobConfig.JobName)'." -Level "DEBUG"

    $reportData = $JobReportDataRef.Value
    $allTargetTransfersSuccessfulOverall = $true 
    $jobName = $EffectiveJobConfig.JobName
    $localFilesToTransfer = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $localManifestFile = $null

    if ($EffectiveJobConfig.ResolvedTargetInstances.Count -eq 0) {
        & $LocalWriteLog -Message "[INFO] RemoteTransferOrchestrator: No remote targets configured for job '$jobName'. Skipping remote transfers." -Level "INFO"
        return @{ AllTransfersSuccessful = $true } 
    }

    & $LocalWriteLog -Message "`n[INFO] RemoteTransferOrchestrator: Starting remote target transfers for job '$jobName'..." -Level "INFO"

    # --- Identify all local files to transfer (volumes and manifest) ---
    $baseArchiveNameForManifestAndVolumes = "$($EffectiveJobConfig.BaseFileName) [$($ReportData.ScriptStartTime | Get-Date -Format $EffectiveJobConfig.JobArchiveDateFormat)]$($EffectiveJobConfig.InternalArchiveExtension)"
    $localArchiveDirectory = Split-Path -Path $LocalFinalArchivePath -Parent

    if (-not [string]::IsNullOrWhiteSpace($EffectiveJobConfig.SplitVolumeSize)) {
        # Find all volumes: e.g., "basename.7z.001", "basename.7z.002", ...
        $volumePattern = [regex]::Escape($baseArchiveNameForManifestAndVolumes) + "\.\d{3,}"
        Get-ChildItem -Path $localArchiveDirectory -File | Where-Object { $_.Name -match $volumePattern } | ForEach-Object { $localFilesToTransfer.Add($_) }
        if ($localFilesToTransfer.Count -eq 0) {
            & $LocalWriteLog -Message "[ERROR] RemoteTransferOrchestrator: Local staged archive (first volume) '$LocalFinalArchivePath' was expected, but no volume parts found matching pattern '$volumePattern' in '$localArchiveDirectory'. Cannot proceed with remote target transfers." -Level "ERROR"
            # Add entries to TargetTransfers indicating failure for all targets
            foreach ($targetInstanceCfg in $EffectiveJobConfig.ResolvedTargetInstances) {
                $reportData.TargetTransfers.Add(@{ TargetName = $targetInstanceCfg._TargetInstanceName_; TargetType = $targetInstanceCfg.Type; Status = "Skipped"; ErrorMessage = "Local archive volumes not found."})
            }
            return @{ AllTransfersSuccessful = $false }
        }
        & $LocalWriteLog -Message "  - RemoteTransferOrchestrator: Identified $($localFilesToTransfer.Count) volume(s) for transfer." -Level "DEBUG"
    } else {
        # Single archive file
        if (Test-Path -LiteralPath $LocalFinalArchivePath -PathType Leaf) {
            $localFilesToTransfer.Add((Get-Item -LiteralPath $LocalFinalArchivePath))
        } else {
             & $LocalWriteLog -Message "[ERROR] RemoteTransferOrchestrator: Local staged archive '$LocalFinalArchivePath' not found. Cannot proceed with remote target transfers." -Level "ERROR"
            foreach ($targetInstanceCfg in $EffectiveJobConfig.ResolvedTargetInstances) {
                $reportData.TargetTransfers.Add(@{ TargetName = $targetInstanceCfg._TargetInstanceName_; TargetType = $targetInstanceCfg.Type; Status = "Skipped"; ErrorMessage = "Local source archive not found: $LocalFinalArchivePath"})
            }
            return @{ AllTransfersSuccessful = $false }
        }
    }

    # Check for and add manifest file if it exists and is configured
    if ($EffectiveJobConfig.GenerateSplitArchiveManifest -or ($EffectiveJobConfig.GenerateArchiveChecksum -and $localFilesToTransfer.Count -eq 1)) {
        $manifestBaseName = if (-not [string]::IsNullOrWhiteSpace($EffectiveJobConfig.SplitVolumeSize)) { $baseArchiveNameForManifestAndVolumes } else { $ArchiveFileNameOnly }
        $expectedManifestFileName = "$($manifestBaseName).manifest.$($EffectiveJobConfig.ChecksumAlgorithm.ToLowerInvariant())"
        if ($EffectiveJobConfig.GenerateArchiveChecksum -and $localFilesToTransfer.Count -eq 1 -and -not $EffectiveJobConfig.GenerateSplitArchiveManifest) { # Single file checksum
             $expectedManifestFileName = "$($ArchiveFileNameOnly).$($EffectiveJobConfig.ChecksumAlgorithm.ToLowerInvariant())"
        }

        $potentialManifestPath = Join-Path -Path $localArchiveDirectory -ChildPath $expectedManifestFileName
        if (Test-Path -LiteralPath $potentialManifestPath -PathType Leaf) {
            $localManifestFile = Get-Item -LiteralPath $potentialManifestPath
            $localFilesToTransfer.Add($localManifestFile) # Add manifest to the list of files to transfer
            & $LocalWriteLog -Message "  - RemoteTransferOrchestrator: Identified manifest file '$($localManifestFile.Name)' for transfer." -Level "DEBUG"
        } elseif ($EffectiveJobConfig.GenerateSplitArchiveManifest) {
             & $LocalWriteLog -Message "[WARNING] RemoteTransferOrchestrator: Manifest generation was enabled, but manifest file '$expectedManifestFileName' not found at '$localArchiveDirectory'." -Level "WARNING"
        }
    }
    
    if ($localFilesToTransfer.Count -eq 0) {
        & $LocalWriteLog -Message "[ERROR] RemoteTransferOrchestrator: No local files (archive parts or manifest) identified for transfer for job '$jobName'." -Level "ERROR"
        return @{ AllTransfersSuccessful = $false }
    }

    # --- Transfer each identified file to each target ---
    foreach ($targetInstanceConfig in $EffectiveJobConfig.ResolvedTargetInstances) {
        $targetInstanceName = $targetInstanceConfig._TargetInstanceName_
        $targetInstanceType = $targetInstanceConfig.Type
        & $LocalWriteLog -Message "  - RemoteTransferOrchestrator: Processing Target Instance: '$targetInstanceName' (Type: '$targetInstanceType')." -Level "INFO"

        $targetProviderModuleName = "$($targetInstanceType).Target.psm1"
        $targetProviderModulePath = Join-Path -Path $PSScriptRootForPaths -ChildPath "Modules\Targets\$targetProviderModuleName"

        if (-not (Test-Path -LiteralPath $targetProviderModulePath -PathType Leaf)) {
            & $LocalWriteLog -Message "[ERROR] RemoteTransferOrchestrator: Target Provider module '$targetProviderModuleName' not found. Skipping transfer to '$targetInstanceName'." -Level "ERROR"
            $reportData.TargetTransfers.Add(@{ TargetName = $targetInstanceName; TargetType = $targetInstanceType; Status = "Failure (Provider Not Found)"; ErrorMessage = "Provider module '$targetProviderModuleName' not found."})
            $allTargetTransfersSuccessfulOverall = $false
            continue
        }

        try {
            Import-Module -Name $targetProviderModulePath -Force -ErrorAction Stop -WarningAction SilentlyContinue
            $invokeTargetTransferCmd = Get-Command Invoke-PoShBackupTargetTransfer -Module (Get-Module -Name $targetProviderModuleName.Replace(".psm1", "")) -ErrorAction SilentlyContinue
            if (-not $invokeTargetTransferCmd) {
                throw "Function 'Invoke-PoShBackupTargetTransfer' not found in provider module '$targetProviderModuleName'."
            }

            foreach ($fileToTransferInfo in $localFilesToTransfer) {
                $currentFileLocalPath = $fileToTransferInfo.FullName
                $currentFileNameOnly = $fileToTransferInfo.Name
                
                & $LocalWriteLog -Message "    - RemoteTransferOrchestrator: Preparing to transfer file '$currentFileNameOnly' to Target '$targetInstanceName'." -Level "DEBUG"

                $currentTransferReport = @{
                    TargetName            = $targetInstanceName
                    TargetType            = $targetInstanceType
                    FileTransferred       = $currentFileNameOnly # New field to identify which part/manifest
                    Status                = "Skipped"
                    RemotePath            = "N/A"
                    ErrorMessage          = "Provider module load/call failed for this file."
                    TransferDuration      = "N/A"
                    TransferSize          = 0
                    TransferSizeFormatted = "N/A"
                }

                $fileSizeBytesForTransfer = $fileToTransferInfo.Length
                $fileCreationTimestampForTransfer = $fileToTransferInfo.CreationTime

                $transferParams = @{
                    LocalArchivePath            = $currentFileLocalPath # Path to the specific file (volume or manifest)
                    TargetInstanceConfiguration = $targetInstanceConfig
                    JobName                     = $jobName
                    ArchiveFileName             = $currentFileNameOnly    # Name of the specific file being transferred
                    ArchiveBaseName             = $EffectiveJobConfig.BaseFileName 
                    ArchiveExtension            = $EffectiveJobConfig.JobArchiveExtension # Primary extension
                    IsSimulateMode              = $IsSimulateMode.IsPresent
                    Logger                      = $Logger
                    EffectiveJobConfig          = $EffectiveJobConfig
                    LocalArchiveSizeBytes       = $fileSizeBytesForTransfer
                    LocalArchiveCreationTimestamp = $fileCreationTimestampForTransfer
                    PasswordInUse               = $EffectiveJobConfig.PasswordInUseFor7Zip
                    PSCmdlet                    = $PSCmdlet
                }
                $transferOutcome = & $invokeTargetTransferCmd @transferParams

                $currentTransferReport.Status = if ($transferOutcome.Success) { "Success" } else { "Failure" }
                $currentTransferReport.RemotePath = $transferOutcome.RemotePath
                $currentTransferReport.ErrorMessage = $transferOutcome.ErrorMessage
                $currentTransferReport.TransferDuration = if ($null -ne $transferOutcome.TransferDuration) { $transferOutcome.TransferDuration.ToString() } else { "N/A" }
                $currentTransferReport.TransferSize = $transferOutcome.TransferSize
                $currentTransferReport.TransferSizeFormatted = Get-UtilityArchiveSizeFormattedFromByte -Bytes $transferOutcome.TransferSize


                if ($transferOutcome.ContainsKey('ReplicationDetails') -and $transferOutcome.ReplicationDetails -is [array] -and $transferOutcome.ReplicationDetails.Count -gt 0) {
                    $currentTransferReport.ReplicationDetails = $transferOutcome.ReplicationDetails 
                }

                if (-not $transferOutcome.Success) {
                    $allTargetTransfersSuccessfulOverall = $false
                    & $LocalWriteLog -Message "[ERROR] RemoteTransferOrchestrator: Transfer of file '$currentFileNameOnly' to Target '$targetInstanceName' FAILED. Reason: $($transferOutcome.ErrorMessage)" -Level "ERROR"
                } else {
                    & $LocalWriteLog -Message "  - RemoteTransferOrchestrator: Transfer of file '$currentFileNameOnly' to Target '$targetInstanceName' SUCCEEDED. Remote Path: $($transferOutcome.RemotePath)" -Level "SUCCESS"
                }
                $reportData.TargetTransfers.Add($currentTransferReport)
                if (-not $allTargetTransfersSuccessfulOverall) { break } # If one part fails for a target, stop trying other parts for that target
            } # End foreach fileToTransferInfo
        } catch {
            & $LocalWriteLog -Message "[ERROR] RemoteTransferOrchestrator: Critical error during transfer processing for Target '$targetInstanceName' (Type: '$targetInstanceType'). Error: $($_.Exception.ToString())" -Level "ERROR"
            # Add a general failure entry for this target if not already added for a specific file
            if (-not ($reportData.TargetTransfers | Where-Object {$_.TargetName -eq $targetInstanceName -and $_.Status -like "Failure*"})) {
                 $reportData.TargetTransfers.Add(@{ TargetName = $targetInstanceName; TargetType = $targetInstanceType; FileTransferred = "N/A"; Status = "Failure (Orchestration Exception)"; ErrorMessage = $_.Exception.ToString()})
            }
            $allTargetTransfersSuccessfulOverall = $false
        }
        if (-not $allTargetTransfersSuccessfulOverall) {
             & $LocalWriteLog -Message "  - RemoteTransferOrchestrator: Halting further transfers to other targets for job '$jobName' due to failure with target '$targetInstanceName'." -Level "WARNING"
            break # Stop processing other targets if one target failed completely for any file
        }
    } # End foreach targetInstanceConfig

    if ($allTargetTransfersSuccessfulOverall -and $EffectiveJobConfig.ResolvedTargetInstances.Count -gt 0) {
        & $LocalWriteLog -Message "[INFO] RemoteTransferOrchestrator: All attempted remote target transfers for job '$jobName' (all parts and manifest if applicable) completed successfully." -Level "SUCCESS"
    } elseif ($EffectiveJobConfig.ResolvedTargetInstances.Count -gt 0) {
        & $LocalWriteLog -Message "[WARNING] RemoteTransferOrchestrator: One or more remote target transfers for job '$jobName' FAILED or were skipped due to errors." -Level "WARNING"
    }

    # Delete local staged files (all volumes and manifest) if all transfers to all targets were successful
    if ($EffectiveJobConfig.DeleteLocalArchiveAfterSuccessfulTransfer -and $allTargetTransfersSuccessfulOverall -and $EffectiveJobConfig.ResolvedTargetInstances.Count -gt 0) {
        & $LocalWriteLog -Message "[INFO] RemoteTransferOrchestrator: Deleting local staged archive files as all target transfers succeeded and DeleteLocalArchiveAfterSuccessfulTransfer is true." -Level "INFO"
        foreach($localFileToDeleteInfo in $localFilesToTransfer) {
            if ((-not $IsSimulateMode.IsPresent) -and (Test-Path -LiteralPath $localFileToDeleteInfo.FullName -PathType Leaf)) {
                if ($PSCmdlet.ShouldProcess($localFileToDeleteInfo.FullName, "Delete Local Staged Archive File (Post-All-Successful-Transfers)")) {
                    & $LocalWriteLog -Message "  - Deleting: '$($localFileToDeleteInfo.FullName)'" -Level "INFO"
                    try { Remove-Item -LiteralPath $localFileToDeleteInfo.FullName -Force -ErrorAction Stop }
                    catch { & $LocalWriteLog -Message "[WARNING] RemoteTransferOrchestrator: Failed to delete local staged file '$($localFileToDeleteInfo.FullName)'. Error: $($_.Exception.Message)" -Level "WARNING" }
                } else {
                     & $LocalWriteLog -Message "  - Deletion of local staged file '$($localFileToDeleteInfo.FullName)' skipped by user (ShouldProcess)." -Level "INFO"
                }
            } elseif ($IsSimulateMode.IsPresent) {
                & $LocalWriteLog -Message "SIMULATE: RemoteTransferOrchestrator: Would delete local staged file '$($localFileToDeleteInfo.FullName)'." -Level "SIMULATE"
            }
        }
    } elseif ($EffectiveJobConfig.DeleteLocalArchiveAfterSuccessfulTransfer -and (-not $allTargetTransfersSuccessfulOverall) -and $EffectiveJobConfig.ResolvedTargetInstances.Count -gt 0) {
        & $LocalWriteLog -Message "[INFO] RemoteTransferOrchestrator: Local staged archive files KEPT because one or more target transfers failed (and DeleteLocalArchiveAfterSuccessfulTransfer is true)." -Level "INFO"
    }

    return @{ AllTransfersSuccessful = $allTargetTransfersSuccessfulOverall }
}

Export-ModuleMember -Function Invoke-RemoteTargetTransferOrchestration
