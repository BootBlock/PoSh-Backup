# Modules\Targets\GCS\GCS.RetentionApplicator.psm1
<#
.SYNOPSIS
    A sub-module for GCS.Target.psm1. Handles the remote retention policy.
.DESCRIPTION
    This module provides the 'Invoke-GCSRetentionPolicy' function. It is responsible for
    applying a count-based retention policy to a remote GCS bucket. It lists the
    objects in the bucket using 'gcloud storage ls', groups them into backup instances,
    and deletes the oldest instances using 'gcloud storage rm' to meet the configured
    retention count.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.1 # Added comment-based help, PSSA fix, and ADVICE logging.
    DateCreated:    02-Jul-2025
    LastModified:   02-Jul-2025
    Purpose:        To isolate the GCS remote retention logic.
    Prerequisites:  PowerShell 5.1+, gcloud CLI.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Targets\GCS
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utilities\RetentionUtils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "GCS.RetentionApplicator.psm1 FATAL: Could not import a dependent module. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Invoke-GCSRetentionPolicy {
<#
.SYNOPSIS
    Applies a count-based retention policy to a Google Cloud Storage bucket/prefix.
.DESCRIPTION
    This function lists all relevant backup files in a GCS bucket, groups them into backup
    instances based on their filenames and timestamps, and then deletes the oldest instances
    to ensure that no more than the configured 'KeepCount' remain.
.PARAMETER RetentionSettings
    A hashtable containing the retention policy, which must include a 'KeepCount' key.
.PARAMETER BucketName
    The name of the GCS bucket to apply retention to.
.PARAMETER RemoteKeyPrefix
    The optional prefix (folder path) within the bucket where the job's files are stored.
.PARAMETER ArchiveBaseName
    The base name of the archive files (e.g., "JobName") used for discovery.
.PARAMETER ArchiveExtension
    The primary extension of the archive files (e.g., ".7z") used for discovery.
.PARAMETER ArchiveDateFormat
    The .NET date format string used to parse timestamps in filenames.
.PARAMETER Logger
    A mandatory scriptblock reference to the main 'Write-LogMessage' function.
.PARAMETER PSCmdletInstance
    A mandatory reference to the calling cmdlet's $PSCmdlet automatic variable, required
    for ShouldProcess support.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$RetentionSettings,
        [Parameter(Mandatory = $true)]
        [string]$BucketName,
        [Parameter(Mandatory = $true)]
        [string]$RemoteKeyPrefix, # e.g., "JobName/" or ""
        [Parameter(Mandatory = $true)]
        [string]$ArchiveBaseName,
        [Parameter(Mandatory = $true)]
        [string]$ArchiveExtension,
        [Parameter(Mandatory = $true)]
        [string]$ArchiveDateFormat,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    & $Logger -Message "GCS.RetentionApplicator: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    $keepCount = $RetentionSettings.KeepCount
    $remoteDirectoryToScan = "gs://$BucketName/$RemoteKeyPrefix"
    & $LocalWriteLog -Message ("  - GCS.RetentionApplicator: Applying remote retention (KeepCount: {0}) in '{1}'." -f $keepCount, $remoteDirectoryToScan) -Level "INFO"

    try {
        $gcloudListOutput = gcloud storage ls -l "$($remoteDirectoryToScan)$($ArchiveBaseName)*"
        if ($LASTEXITCODE -ne 0) { throw "Failed to list remote objects for retention." }

        $gcsObjects = $gcloudListOutput | ForEach-Object {
            if ($_ -match '^\s*(\d+)\s+(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\s+gs://.+/(.+)$') {
                [PSCustomObject]@{
                    Size           = [long]$Matches[1]
                    SortTime       = [datetime]$Matches[2]
                    Name           = $Matches[3]
                    OriginalObject = $_ # Keep the raw line for potential use
                }
            }
        }

        $remoteInstances = Group-BackupInstancesByTimestamp -FileObjectList $gcsObjects `
            -ArchiveBaseName $ArchiveBaseName `
            -ArchiveDateFormat $ArchiveDateFormat `
            -PrimaryArchiveExtension $ArchiveExtension `
            -Logger $Logger

        if ($remoteInstances.Count -gt $keepCount) {
            $sortedInstances = $remoteInstances.GetEnumerator() | Sort-Object { $_.Value.SortTime } -Descending
            $instancesToDelete = $sortedInstances | Select-Object -Skip $keepCount
            & $LocalWriteLog -Message ("    - GCS.RetentionApplicator: Found {0} remote instances. Will delete files for {1} older instance(s)." -f $remoteInstances.Count, $instancesToDelete.Count) -Level "DEBUG"

            foreach ($instanceEntry in $instancesToDelete) {
                & $LocalWriteLog "      - GCS.RetentionApplicator: Preparing to delete instance '$($instanceEntry.Name)' (SortTime: $($instanceEntry.Value.SortTime))." -Level "WARNING"
                foreach ($gcsObjectContainer in $instanceEntry.Value.Files) {
                    $fullBlobPathToDelete = "gs://$BucketName/$($gcsObjectContainer.Name)"

                    if (-not $PSCmdletInstance.ShouldProcess($fullBlobPathToDelete, "Delete Remote GCS Object (Retention)")) {
                        & $LocalWriteLog ("        - Deletion of '{0}' skipped by user." -f $fullBlobPathToDelete) -Level "WARNING"; continue
                    }
                    & $LocalWriteLog -Message ("        - Deleting: '{0}'" -f $fullBlobPathToDelete) -Level "WARNING"
                    try {
                        gcloud storage rm $fullBlobPathToDelete
                        if ($LASTEXITCODE -eq 0) { & $LocalWriteLog "          - Status: DELETED" -Level "SUCCESS" }
                        else { & $LocalWriteLog "          - Status: FAILED! gcloud rm exited with code $LASTEXITCODE" -Level "ERROR" }
                    }
                    catch {
                        & $LocalWriteLog -Message "          - Status: FAILED to delete! Error: $($_.Exception.Message)" -Level "ERROR"
                    }
                }
            }
        } else {
             & $LocalWriteLog ("    - GCS.RetentionApplicator: No old instances to delete based on retention count {0} (Found: {1})." -f $keepCount, $remoteInstances.Count) -Level "DEBUG"
        }
    }
    catch {
        $errorMessage = "GCS.RetentionApplicator: Error during remote retention execution: $($_.Exception.Message)"
        $adviceMessage = "ADVICE: This can happen if the authenticated account does not have the 'Storage Object Viewer' (for listing) or 'Storage Object Admin' (for deleting) roles on the target bucket."
        & $Logger -Message "[WARNING] $errorMessage" -Level "WARNING"
        & $Logger -Message $adviceMessage -Level "ADVICE"
    }
}

Export-ModuleMember -Function Invoke-GCSRetentionPolicy
