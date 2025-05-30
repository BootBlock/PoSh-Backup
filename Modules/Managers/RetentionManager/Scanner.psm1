# Modules\Managers\RetentionManager\Scanner.psm1
<#
.SYNOPSIS
    Sub-module for RetentionManager. Handles scanning for and grouping backup archive instances.
.DESCRIPTION
    This module contains the 'Find-BackupArchiveInstances' function, responsible for
    identifying all relevant backup files (single or multi-volume parts) in a given
    directory that match a base name and extension. It groups these files into logical
    "backup instances" and determines a sortable timestamp for each instance.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    29-May-2025
    LastModified:   29-May-2025
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
function Find-BackupArchiveInstances {
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

    & $Logger -Message "RetentionManager/Scanner/Find-BackupArchiveInstances: Logger active for base '$ArchiveBaseFileName', ext '$ArchiveExtension'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    $backupInstances = @{} # Key: InstanceIdentifier (e.g., "JobName [DateStamp].7z"), Value: @{SortTime=datetime; Files=List[FileInfo]}

    if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
        & $LocalWriteLog -Message "  - RetentionManager/Scanner: Destination directory '$DestinationDirectory' not found. Returning no instances." -Level "WARNING"
        return $backupInstances
    }

    $literalBaseName = $ArchiveBaseFileName -replace '([\.\^\$\*\+\?\(\)\[\]\{\}\|\\])', '\$1'
    $fileFilterPattern = "$($literalBaseName)$([regex]::Escape($ArchiveExtension))*"
    
    & $LocalWriteLog -Message "   - RetentionManager/Scanner: Scanning for files with filter pattern: '$fileFilterPattern' in '$DestinationDirectory'" -Level "DEBUG"
    $allMatchingFiles = Get-ChildItem -Path $DestinationDirectory -Filter $fileFilterPattern -File -ErrorAction SilentlyContinue
    
    if ($null -eq $allMatchingFiles -or $allMatchingFiles.Count -eq 0) {
        & $LocalWriteLog -Message "   - RetentionManager/Scanner: No files found matching pattern '$fileFilterPattern'." -Level "DEBUG"
        return $backupInstances
    }

    foreach ($fileInfo in $allMatchingFiles) {
        $instanceIdentifier = ""
        $isFirstVolumePart = $false
        $fileIsPartOfSplitSet = $false

        $splitVolumePattern = "^($([regex]::Escape($ArchiveBaseFileName + $ArchiveExtension)))\.(\d{3,})$"

        if ($fileInfo.Name -match $splitVolumePattern) {
            $instanceIdentifier = $Matches[1] 
            $fileIsPartOfSplitSet = $true
            if ($Matches[2] -eq "001") {
                $isFirstVolumePart = $true
            }
        } else {
            if ($fileInfo.Name -eq ($ArchiveBaseFileName + $ArchiveExtension)) {
                 $instanceIdentifier = $fileInfo.Name
            } elseif ($ArchiveExtension -ne $fileInfo.Extension -and $fileInfo.Name -like ($ArchiveBaseFileName + "*")) {
                $instanceIdentifier = $fileInfo.Name
            } else {
                & $LocalWriteLog -Message "   - RetentionManager/Scanner: File '$($fileInfo.Name)' does not match expected single or split volume pattern for base '$ArchiveBaseFileName' and ext '$ArchiveExtension'. Skipping." -Level "DEBUG"
                continue
            }
        }

        if (-not $backupInstances.ContainsKey($instanceIdentifier)) {
            $backupInstances[$instanceIdentifier] = @{
                SortTime = if ($isFirstVolumePart) { $fileInfo.CreationTime } else { [datetime]::MaxValue }
                Files    = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
            }
        }
        $backupInstances[$instanceIdentifier].Files.Add($fileInfo)
        
        if ($isFirstVolumePart) {
            if ($fileInfo.CreationTime -lt $backupInstances[$instanceIdentifier].SortTime) {
                $backupInstances[$instanceIdentifier].SortTime = $fileInfo.CreationTime
            }
        } elseif (-not $fileIsPartOfSplitSet) {
             $backupInstances[$instanceIdentifier].SortTime = $fileInfo.CreationTime
        }
    }

    foreach ($instanceKeyToRefine in $backupInstances.Keys) {
        if ($backupInstances[$instanceKeyToRefine].SortTime -eq [datetime]::MaxValue) {
            if ($backupInstances[$instanceKeyToRefine].Files.Count -gt 0) {
                $earliestPartFoundTime = ($backupInstances[$instanceKeyToRefine].Files | Sort-Object CreationTime | Select-Object -First 1).CreationTime
                $backupInstances[$instanceKeyToRefine].SortTime = $earliestPartFoundTime
                & $LocalWriteLog -Message "[WARNING] RetentionManager/Scanner: Backup instance '$instanceKeyToRefine' appears to be missing its first volume part (e.g., .001) or was processed out of order. Using earliest found part's time for sorting. This might indicate an incomplete backup set." -Level "WARNING"
            } else {
                $backupInstances.Remove($instanceKeyToRefine) 
            }
        }
    }
    
    & $LocalWriteLog -Message "   - RetentionManager/Scanner: Found $($backupInstances.Count) logical backup instance(s)." -Level "DEBUG"
    return $backupInstances
}
#endregion

Export-ModuleMember -Function Find-BackupArchiveInstances
