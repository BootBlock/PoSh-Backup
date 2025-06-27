# Modules\Operations\RemoteTransferOrchestrator\StagedFileDiscoverer.psm1
<#
.SYNOPSIS
    A sub-module for RemoteTransferOrchestrator. Discovers all local staged files for transfer.
.DESCRIPTION
    This module provides the 'Find-PoShBackupStagedFile' function, which is responsible
    for identifying all local files that constitute a single backup "instance". This
    includes the primary archive file, any additional volumes of a split archive, and
    any associated "sidecar" files like checksums, manifests, and pin markers. It now
    correctly handles simulation mode by returning a mock list of files.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.2 # Corrected simulation mode logic to create valid mock objects.
    DateCreated:    26-Jun-2025
    LastModified:   27-Jun-2025
    Purpose:        To isolate the discovery of staged files for remote transfer.
    Prerequisites:  PowerShell 5.1+.
#>

function Find-PoShBackupStagedFile {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalFinalArchivePath, # Path to the first volume or the single archive file
        [Parameter(Mandatory = $true)]
        [string]$ArchiveFileNameOnly, # Filename of the final .exe or .7z
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $true)]
        [hashtable]$ReportData,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "StagedFileDiscoverer: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    # --- Handle Simulation Mode ---
    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "  - StagedFileDiscoverer: Running in simulation mode. Returning placeholder file list." -Level "DEBUG"
        $mockFileList = [System.Collections.Generic.List[object]]::new()
        
        # Helper to create a mock PSCustomObject that mimics a FileInfo object.
        $createMockFile = {
            param($name, $fullName)
            return [pscustomobject]@{
                Name           = $name
                FullName       = $fullName
                Length         = 0
                CreationTime   = (Get-Date)
                LastWriteTime  = (Get-Date)
                Exists         = $true
            }
        }
        
        $sidecarFileBaseName = if (-not [string]::IsNullOrWhiteSpace($EffectiveJobConfig.SplitVolumeSize)) {
            "$($EffectiveJobConfig.BaseFileName) [$($ReportData.ScriptStartTime | Get-Date -Format $EffectiveJobConfig.JobArchiveDateFormat)]$($EffectiveJobConfig.InternalArchiveExtension)"
        } else {
            $ArchiveFileNameOnly
        }
        $localArchiveDirectory = Split-Path -Path $LocalFinalArchivePath -Parent

        # Add the main archive/first volume
        $mockFileList.Add(($createMockFile.Invoke($ArchiveFileNameOnly, $LocalFinalArchivePath)))

        # Add simulated sidecar files if they would have been created
        if ($EffectiveJobConfig.GenerateContentsManifest) {
            $mockName = "$sidecarFileBaseName.contents.manifest"
            $mockFileList.Add(($createMockFile.Invoke($mockName, (Join-Path -Path $localArchiveDirectory -ChildPath $mockName))))
        }
        if ($EffectiveJobConfig.GenerateArchiveChecksum -or $EffectiveJobConfig.GenerateSplitArchiveManifest) {
            $checksumExt = if (-not [string]::IsNullOrWhiteSpace($EffectiveJobConfig.SplitVolumeSize)) {
                "manifest.$($EffectiveJobConfig.ChecksumAlgorithm.ToLowerInvariant())"
            } else {
                $EffectiveJobConfig.ChecksumAlgorithm.ToLowerInvariant()
            }
            $mockName = "$sidecarFileBaseName.$checksumExt"
            $mockFileList.Add(($createMockFile.Invoke($mockName, (Join-Path -Path $localArchiveDirectory -ChildPath $mockName))))
        }
        if ($EffectiveJobConfig.PinOnCreation) {
            $mockName = "$sidecarFileBaseName.pinned"
            $mockFileList.Add(($createMockFile.Invoke($mockName, (Join-Path -Path $localArchiveDirectory -ChildPath $mockName))))
        }

        return $mockFileList
    }
    # --- END Simulation Mode Handling ---

    $localFilesToTransfer = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $localArchiveDirectory = Split-Path -Path $LocalFinalArchivePath -Parent
    
    if (-not (Test-Path -LiteralPath $localArchiveDirectory -PathType Container)) {
        & $LocalWriteLog -Message "[ERROR] StagedFileDiscoverer: Local archive directory '$localArchiveDirectory' does not exist." -Level "ERROR"
        return $localFilesToTransfer
    }

    # --- 1. Identify all primary archive files (volumes or single file) ---
    if (-not [string]::IsNullOrWhiteSpace($EffectiveJobConfig.SplitVolumeSize)) {
        $archiveInstanceBaseName = "$($EffectiveJobConfig.BaseFileName) [$($ReportData.ScriptStartTime | Get-Date -Format $EffectiveJobConfig.JobArchiveDateFormat)]$($EffectiveJobConfig.InternalArchiveExtension)"
        $volumePattern = [regex]::Escape($archiveInstanceBaseName) + "\.\d{3,}"
        Get-ChildItem -Path $localArchiveDirectory -File | Where-Object { $_.Name -match $volumePattern } | ForEach-Object { $localFilesToTransfer.Add($_) }
        
        if ($localFilesToTransfer.Count -eq 0) {
            & $LocalWriteLog -Message "[ERROR] StagedFileDiscoverer: Local staged archive (first volume) '$LocalFinalArchivePath' was expected, but no volume parts found matching pattern '$volumePattern'." -Level "ERROR"
            return $localFilesToTransfer # Return empty list
        }
        & $LocalWriteLog -Message "  - StagedFileDiscoverer: Identified $($localFilesToTransfer.Count) volume(s) for transfer." -Level "DEBUG"
    } else {
        if (Test-Path -LiteralPath $LocalFinalArchivePath -PathType Leaf) {
            $localFilesToTransfer.Add((Get-Item -LiteralPath $LocalFinalArchivePath))
        } else {
            & $LocalWriteLog -Message "[ERROR] StagedFileDiscoverer: Local staged archive '$LocalFinalArchivePath' not found." -Level "ERROR"
            return $localFilesToTransfer # Return empty list
        }
    }

    # --- 2. Identify all associated sidecar files (manifests, checksums, pins) ---
    $sidecarFileBaseName = if (-not [string]::IsNullOrWhiteSpace($EffectiveJobConfig.SplitVolumeSize)) {
        "$($EffectiveJobConfig.BaseFileName) [$($ReportData.ScriptStartTime | Get-Date -Format $EffectiveJobConfig.JobArchiveDateFormat)]$($EffectiveJobConfig.InternalArchiveExtension)"
    } else {
        $ArchiveFileNameOnly
    }
    & $LocalWriteLog -Message "  - StagedFileDiscoverer: Scanning for sidecar files matching base name '$sidecarFileBaseName'..." -Level "DEBUG"
    
    $expectedSidecarFileNames = @(
        "$sidecarFileBaseName.contents.manifest",
        "$sidecarFileBaseName.manifest.$($EffectiveJobConfig.ChecksumAlgorithm.ToLowerInvariant())",
        "$sidecarFileBaseName.$($EffectiveJobConfig.ChecksumAlgorithm.ToLowerInvariant())",
        "$sidecarFileBaseName.pinned"
    ) | Select-Object -Unique

    $existingFileNamesInList = $localFilesToTransfer | ForEach-Object { $_.Name }

    foreach ($expectedFileName in $expectedSidecarFileNames) {
        $fullPath = Join-Path -Path $localArchiveDirectory -ChildPath $expectedFileName
        if ((Test-Path -LiteralPath $fullPath -PathType Leaf) -and ($expectedFileName -notin $existingFileNamesInList)) {
            $fileInfo = Get-Item -LiteralPath $fullPath
            $localFilesToTransfer.Add($fileInfo)
            & $LocalWriteLog -Message "  - StagedFileDiscoverer: Identified associated sidecar file '$($fileInfo.Name)' for transfer." -Level "DEBUG"
        }
    }

    return $localFilesToTransfer
}

Export-ModuleMember -Function Find-PoShBackupStagedFile
