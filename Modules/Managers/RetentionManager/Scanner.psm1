# Modules\Managers\RetentionManager\Scanner.psm1
<#
.SYNOPSIS
    Sub-module for RetentionManager. Handles scanning for and grouping backup archive instances,
    including their associated manifest and pin files.
.DESCRIPTION
    This module contains the 'Find-BackupArchiveInstance' function, responsible for
    identifying all relevant backup files (single or multi-volume parts), their
    associated manifest files, and any '.pinned' marker files in a given directory that
    match a base name and extension. It groups these files into logical "backup instances",
    determines a sortable timestamp for each instance, and flags whether the instance is pinned.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Added detection for .pinned files.
    DateCreated:    29-May-2025
    LastModified:   06-Jun-2025
    Purpose:        Backup archive instance discovery and grouping logic for RetentionManager.
    Prerequisites:  PowerShell 5.1+.
#>

# Explicitly import Utils.psm1 from the main Modules directory.
# $PSScriptRoot here is Modules\Managers\RetentionManager.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "Scanner.psm1 (RetentionManager submodule) FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}

#region --- Archive Instance Scanner ---
function Find-BackupArchiveInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory,
        [Parameter(Mandatory = $true)]
        [string]$ArchiveBaseFileName, # e.g., "JobName [DateStamp]"
        [Parameter(Mandatory = $true)]
        [string]$ArchiveExtension,    # e.g., ".7z" or ".exe" (primary extension before .001 for splits)
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "RetentionManager/Scanner/Find-BackupArchiveInstance: Logger active for base '$ArchiveBaseFileName', ext '$ArchiveExtension'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    $backupInstances = @{} # Key: InstanceIdentifier (e.g., "JobName [DateStamp].7z"), Value: @{SortTime=datetime; Files=List[FileInfo]; Pinned=$false}

    if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
        & $LocalWriteLog -Message "  - RetentionManager/Scanner: Destination directory '$DestinationDirectory' not found. Returning no instances." -Level "WARNING"
        return $backupInstances
    }

    # Regex to match the base archive name and primary extension, capturing it for instance identification.
    # This pattern will match "archive.7z" or "archive.exe" and also "archive.7z.001", "archive.exe.001" etc.
    # It also tries to match SFX files that might have had their original extension embedded, e.g. "archive.7z.exe"
    $literalBaseName = ($ArchiveBaseFileName -replace '([\.\^\$\*\+\?\(\)\[\]\{\}\|\\])', '\$1') + " \[\d{4}-\w{3}-\d{2}\]"
    $fileFilterPattern = "$($literalBaseName)*" # Broad filter to catch all related files, including .pinned

    & $LocalWriteLog -Message "   - RetentionManager/Scanner: Scanning for files with filter pattern: '$fileFilterPattern' in '$DestinationDirectory'" -Level "DEBUG"
    $allMatchingFiles = Get-ChildItem -Path $DestinationDirectory -Filter $fileFilterPattern -File -ErrorAction SilentlyContinue

    if ($null -eq $allMatchingFiles -or $allMatchingFiles.Count -eq 0) {
        & $LocalWriteLog -Message "   - RetentionManager/Scanner: No files found matching pattern '$fileFilterPattern'." -Level "DEBUG"
        return $backupInstances
    }

    foreach ($fileInfo in $allMatchingFiles) {
        # Skip .pinned files in this initial loop; they will be associated later.
        if ($fileInfo.Extension -eq ".pinned") {
            continue
        }

        $instanceIdentifier = ""
        $isFirstVolumePart = $false
        $fileIsPartOfSplitSet = $false

        # Pattern for split volumes: "BaseNameAndPrimaryExt.NNN" (e.g., "MyJob [Date].7z.001")
        $splitVolumePattern = "^($([regex]::Escape($ArchiveBaseFileName + $ArchiveExtension)))\.(\d{3,})$"

        if ($fileInfo.Name -match $splitVolumePattern) {
            $instanceIdentifier = $Matches[1] # e.g., "MyJob [Date].7z"
            $fileIsPartOfSplitSet = $true
            if ($Matches[2] -eq "001") {
                $isFirstVolumePart = $true
            }
        } else {
            # For non-split files, or SFX files where ArchiveExtension might be .exe
            # The instance identifier is the full filename.
            if ($fileInfo.Name -eq ($ArchiveBaseFileName + $ArchiveExtension)) {
                 $instanceIdentifier = $fileInfo.Name
            } elseif ($ArchiveExtension -ne $fileInfo.Extension -and $fileInfo.Name -like ($ArchiveBaseFileName + "*") -and $fileInfo.Extension -eq ".exe") { # Handles SFX like "MyJob [Date].7z.exe"
                $instanceIdentifier = $fileInfo.Name
            } else {
                # This could be a manifest file, which we'll associate later.
                if ($fileInfo.Name -notlike "*.manifest.*") {
                    & $LocalWriteLog -Message "   - RetentionManager/Scanner: File '$($fileInfo.Name)' does not match expected single or split volume pattern for base '$ArchiveBaseFileName' and ext '$ArchiveExtension'. Skipping for now." -Level "DEBUG"
                }
                continue
            }
        }

        if (-not $backupInstances.ContainsKey($instanceIdentifier)) {
            $backupInstances[$instanceIdentifier] = @{
                SortTime = if ($isFirstVolumePart) { $fileInfo.CreationTime } else { [datetime]::MaxValue }
                Files    = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
                Pinned   = $false # Initialize Pinned status
            }
        }
        $backupInstances[$instanceIdentifier].Files.Add($fileInfo)

        if ($isFirstVolumePart) {
            if ($fileInfo.CreationTime -lt $backupInstances[$instanceIdentifier].SortTime) {
                $backupInstances[$instanceIdentifier].SortTime = $fileInfo.CreationTime
            }
        } elseif (-not $fileIsPartOfSplitSet) { # Single file archive
             $backupInstances[$instanceIdentifier].SortTime = $fileInfo.CreationTime
        }
    }

    # Refine SortTime for split sets that might have been processed out of order or missing .001 initially
    # And now, also look for associated manifest and pinned files for each identified instance.
    foreach ($instanceKeyToRefine in $backupInstances.Keys) {
        if ($backupInstances[$instanceKeyToRefine].SortTime -eq [datetime]::MaxValue) {
            if ($backupInstances[$instanceKeyToRefine].Files.Count -gt 0) {
                $earliestPartFoundTime = ($backupInstances[$instanceKeyToRefine].Files | Sort-Object CreationTime | Select-Object -First 1).CreationTime
                $backupInstances[$instanceKeyToRefine].SortTime = $earliestPartFoundTime
                & $LocalWriteLog -Message "[WARNING] RetentionManager/Scanner: Backup instance '$instanceKeyToRefine' appears to be missing its first volume part (e.g., .001) or was processed out of order. Using earliest found part's time for sorting. This might indicate an incomplete backup set." -Level "WARNING"
            } else {
                # Should not happen if files were added, but as a safeguard
                $backupInstances.Remove($instanceKeyToRefine)
                continue # Skip to next instance if this one is now empty
            }
        }

        # Look for manifest file associated with this instance
        # $instanceKeyToRefine is "JobName [DateStamp].<PrimaryExtension>" e.g. "MyJob [2025-06-01].7z"
        # Manifest pattern: "JobName [DateStamp].<PrimaryExtension>.manifest.*"
        $manifestPattern = [regex]::Escape($instanceKeyToRefine) + ".manifest.*"
        $manifestFile = $allMatchingFiles |
                        Where-Object { $_.Name -match $manifestPattern } |
                        Sort-Object CreationTime -Descending | # Get newest if multiple (should not happen)
                        Select-Object -First 1
        
        if ($null -ne $manifestFile) {
            & $LocalWriteLog -Message "   - RetentionManager/Scanner: Found associated manifest file '$($manifestFile.Name)' for instance '$instanceKeyToRefine'." -Level "DEBUG"
            $backupInstances[$instanceKeyToRefine].Files.Add($manifestFile)
        } else {
            & $LocalWriteLog -Message "   - RetentionManager/Scanner: No manifest file found matching pattern '$manifestPattern' for instance '$instanceKeyToRefine'." -Level "DEBUG"
        }

        # Look for a .pinned file associated with this instance
        $pinFilePath = Join-Path -Path $DestinationDirectory -ChildPath "$instanceKeyToRefine.pinned"
        if (Test-Path -LiteralPath $pinFilePath -PathType Leaf) {
            & $LocalWriteLog -Message "   - RetentionManager/Scanner: Found PINNED marker for instance '$instanceKeyToRefine'." -Level "INFO"
            $backupInstances[$instanceKeyToRefine].Pinned = $true
        }
    }

    & $LocalWriteLog -Message "   - RetentionManager/Scanner: Found $($backupInstances.Count) logical backup instance(s) after processing and manifest/pin scan." -Level "DEBUG"
    return $backupInstances
}
#endregion

Export-ModuleMember -Function Find-BackupArchiveInstance
