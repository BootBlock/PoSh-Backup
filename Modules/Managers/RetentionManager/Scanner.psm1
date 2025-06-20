# Modules\Managers\RetentionManager\Scanner.psm1
<#
.SYNOPSIS
    Sub-module for RetentionManager. Handles scanning for and grouping backup archive instances,
    including their associated manifest and pin files.
.DESCRIPTION
    This module contains the 'Find-BackupArchiveInstance' function, responsible for
    identifying all relevant backup files (single or multi-volume parts), their
    associated manifest files, and any '.pinned' marker files in a given directory that
    match a base name and extension. It now dynamically builds its search pattern based on the
    job's configured date format to correctly identify backup instances.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.2.0 # Fixed date format matching bug by dynamically building regex.
    DateCreated:    29-May-2025
    LastModified:   15-Jun-2025
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
        [string]$ArchiveBaseFileName,       # e.g., "JobName" (without date stamp)
        [Parameter(Mandatory = $true)]
        [string]$ArchiveExtension,          # e.g., ".7z" or ".exe" (primary extension before .001 for splits)
        [Parameter(Mandatory = $true)]
        [string]$ArchiveDateFormat,         # The .NET date format string, e.g., "yyyy-MM-dd_HH-mm-ss"
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

    $dateFormatRegex = $ArchiveDateFormat -replace 'yyyy', '\d{4}' `
                                          -replace 'yy', '\d{2}' `
                                          -replace 'MMM', '\w{3}' `
                                          -replace 'MM', '\d{2}' `
                                          -replace 'dd', '\d{2}' `
                                          -replace 'HH', '\d{2}' `
                                          -replace 'hh', '\d{2}' `
                                          -replace 'mm', '\d{2}' `
                                          -replace 'ss', '\d{2}' `
                                          -replace '-', '\-'

    $dateStampPattern = "\[$($dateFormatRegex)\]" # Matches [yyyy-MM-dd_HH-mm-ss] etc.

    & $LocalWriteLog -Message "   - RetentionManager/Scanner: Using dynamic date stamp regex pattern: '$dateStampPattern'" -Level "DEBUG"
    # --- End dynamic regex build ---

    $fileFilterPattern = "$($ArchiveBaseFileName)*"

    & $LocalWriteLog -Message "   - RetentionManager/Scanner: Scanning for files with filter pattern: '$fileFilterPattern' in '$DestinationDirectory'" -Level "DEBUG"
    $allMatchingFiles = Get-ChildItem -Path $DestinationDirectory -Filter $fileFilterPattern -File -ErrorAction SilentlyContinue

    if ($null -eq $allMatchingFiles -or $allMatchingFiles.Count -eq 0) {
        & $LocalWriteLog -Message "   - RetentionManager/Scanner: No files found matching pattern '$fileFilterPattern'." -Level "DEBUG"
        return $backupInstances
    }

    $baseNamePattern = [regex]::Escape($ArchiveBaseFileName)
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
