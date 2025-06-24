# Modules\Utilities\RetentionUtils.psm1
<#
.SYNOPSIS
    Provides a centralised utility function for grouping backup archive files into
    logical instances based on their filenames and timestamps.
.DESCRIPTION
    This module contains the 'Group-BackupInstancesByTimestamp' function. Its purpose is
    to take a list of file-like objects (from any source, like a local file system,
    SFTP server, or cloud storage bucket) and group them into backup "instances".

    An instance represents a single backup operation and may consist of multiple files
    (e.g., a multi-volume split archive and its manifest). The grouping is done by
    parsing filenames to find a common base name and date stamp. This removes duplicated
    logic from the various target provider modules.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    23-Jun-2025
    LastModified:   23-Jun-2025
    Purpose:        Centralised backup instance grouping logic for retention policies.
    Prerequisites:  PowerShell 5.1+.
#>

function Group-BackupInstancesByTimestamp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$FileObjectList, # An array of objects, each must have 'Name' and 'SortTime' properties.
        [Parameter(Mandatory = $true)]
        [string]$ArchiveBaseName, # e.g., "JobName"
        [Parameter(Mandatory = $true)]
        [string]$ArchiveDateFormat, # e.g., "yyyy-MM-dd_HH-mm-ss"
        [Parameter(Mandatory = $true)]
        [string]$PrimaryArchiveExtension, # e.g., ".7z"
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "RetentionUtils/Group-BackupInstancesByTimestamp: Grouping $($FileObjectList.Count) objects for base '$ArchiveBaseName'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $instances = @{}
    $escapedBaseName = [regex]::Escape($ArchiveBaseName)
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
    $dateStampPattern = "\[$($dateFormatRegex)\]"
    $fullBaseNameToMatch = "$escapedBaseName\s$dateStampPattern"

    foreach ($fileObject in $FileObjectList) {
        $fileName = $fileObject.Name
        $instanceKey = $null

        # Regex to capture the full base name including the date stamp, e.g., "JobName [2023-01-01_12-00-00]"
        if ($fileName -match "^($fullBaseNameToMatch)") {
            $baseWithDate = $Matches[1]
            # The instance key is the base name + date + primary extension. This correctly groups .7z.001 and .7z.manifest.
            $instanceKey = $baseWithDate + $PrimaryArchiveExtension
        }

        if ($null -eq $instanceKey) {
            continue
        }

        if (-not $instances.ContainsKey($instanceKey)) {
            $instances[$instanceKey] = @{
                SortTime = $fileObject.SortTime
                Files    = [System.Collections.Generic.List[object]]::new()
            }
        }
        $instances[$instanceKey].Files.Add($fileObject)

        # Refine sort time to be the earliest timestamp in the group
        if ($fileObject.SortTime -lt $instances[$instanceKey].SortTime) {
            $instances[$instanceKey].SortTime = $fileObject.SortTime
        }
    }

    return $instances
}

Export-ModuleMember -Function Group-BackupInstancesByTimestamp
