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
    $fileFilterPattern = "$($ArchiveBaseFileName)*"

    & $LocalWriteLog -Message "   - RetentionManager/Scanner: Scanning for files with filter pattern: '$fileFilterPattern' in '$DestinationDirectory'" -Level "DEBUG"
    $allMatchingFiles = Get-ChildItem -Path $DestinationDirectory -Filter $fileFilterPattern -File -ErrorAction SilentlyContinue

    if ($null -eq $allMatchingFiles -or $allMatchingFiles.Count -eq 0) {
        & $LocalWriteLog -Message "   - RetentionManager/Scanner: No files found matching pattern '$fileFilterPattern'." -Level "DEBUG"
        return $backupInstances
    }

# This regex is designed to find the common "instance key" from any related file.
# It captures the base name, the date stamp, and the primary extension.
# e.g., for "MyJob [2025-06-12].7z.001", it will capture "MyJob [2025-06-12].7z"
$baseNamePattern = [regex]::Escape($ArchiveBaseFileName)
$dateStampPattern = "\[\d{4}-\w{3}-\d{2}\]" # Matches [yyyy-MMM-dd]
$primaryExtPattern = [regex]::Escape($ArchiveExtension)
$instanceKeyPattern = "^($baseNamePattern\s$dateStampPattern$primaryExtPattern)"

foreach ($fileInfo in $allMatchingFiles) {
    if ($fileInfo.Extension -eq ".pinned") { continue }

    $instanceIdentifier = $null
    if ($fileInfo.Name -match $instanceKeyPattern) {
        $instanceIdentifier = $Matches[1]
    }
    
    if ([string]::IsNullOrWhiteSpace($instanceIdentifier)) {
        & $LocalWriteLog -Message "   - RetentionManager/Scanner: File '$($fileInfo.Name)' does not match expected instance pattern. Skipping." -Level "DEBUG"
        continue
    }

    if (-not $backupInstances.ContainsKey($instanceIdentifier)) {
        $backupInstances[$instanceIdentifier] = @{
            SortTime = $fileInfo.CreationTime # Use first file's time as initial sort time
            Files    = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
            Pinned   = $false
        }
    }
    $backupInstances[$instanceIdentifier].Files.Add($fileInfo)

    # Refine sort time - oldest creation time in the group is the most reliable.
    if ($fileInfo.CreationTime -lt $backupInstances[$instanceIdentifier].SortTime) {
        $backupInstances[$instanceIdentifier].SortTime = $fileInfo.CreationTime
    }
}

# Final pass to associate .pinned files
foreach ($instanceKey in $backupInstances.Keys) {
    $pinFilePath = Join-Path -Path $DestinationDirectory -ChildPath "$instanceKey.pinned"
    if (Test-Path -LiteralPath $pinFilePath -PathType Leaf) {
        & $LocalWriteLog -Message "   - RetentionManager/Scanner: Found PINNED marker for instance '$instanceKey'." -Level "INFO"
        $backupInstances[$instanceKey].Pinned = $true
    }
}

    & $LocalWriteLog -Message "   - RetentionManager/Scanner: Found $($backupInstances.Count) logical backup instance(s) after processing and manifest/pin scan." -Level "DEBUG"
    return $backupInstances
}
#endregion

Export-ModuleMember -Function Find-BackupArchiveInstance
