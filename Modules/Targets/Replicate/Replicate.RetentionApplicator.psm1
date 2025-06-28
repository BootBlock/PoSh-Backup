# Modules\Targets\Replicate\Replicate.RetentionApplicator.psm1
<#
.SYNOPSIS
    A sub-module for Replicate.Target.psm1. Handles the remote retention policy.
.DESCRIPTION
    This module provides the 'Invoke-ReplicateRetentionPolicy' function. It is responsible
    for applying a count-based retention policy to a single replication destination. It
    scans the directory, groups backup files into instances using the centralised
    RetentionUtils, and deletes the oldest instances to meet the configured retention count.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    28-Jun-2025
    LastModified:   28-Jun-2025
    Purpose:        To isolate the retention logic for the Replicate target.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Targets\Replicate
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utilities\RetentionUtils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "Replicate.RetentionApplicator.psm1 FATAL: Could not import a dependent module. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Invoke-ReplicateRetentionPolicy {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$RetentionSettings,
        [Parameter(Mandatory = $true)]
        [string]$RemoteDirectory,
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

    & $Logger -Message "Replicate.RetentionApplicator: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    $keepCount = $RetentionSettings.KeepCount
    & $LocalWriteLog -Message ("      - RetentionApplicator: Applying remote retention (KeepCount: {0}) in directory '{1}'." -f $keepCount, $RemoteDirectory) -Level "INFO"

    try {
        if (-not (Test-Path -LiteralPath $RemoteDirectory -PathType Container)) {
            & $LocalWriteLog -Message "        - RetentionApplicator: Directory '$RemoteDirectory' not found for retention. Skipping." -Level "WARNING"
            return
        }

        $allFilesInDest = Get-ChildItem -Path $RemoteDirectory -Filter "$ArchiveBaseName*" -File -ErrorAction SilentlyContinue
        $fileObjectListForGrouping = $allFilesInDest | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; SortTime = $_.CreationTime; OriginalObject = $_ } }

        $allRemoteInstances = Group-BackupInstancesByTimestamp -FileObjectList $fileObjectListForGrouping `
            -ArchiveBaseName $ArchiveBaseName `
            -ArchiveDateFormat $ArchiveDateFormat `
            -PrimaryArchiveExtension $ArchiveExtension `
            -Logger $Logger

        if ($allRemoteInstances.Count -gt $keepCount) {
            $sortedInstances = $allRemoteInstances.GetEnumerator() | Sort-Object { $_.Value.SortTime } -Descending
            $instancesToDelete = $sortedInstances | Select-Object -Skip $keepCount
            & $LocalWriteLog -Message ("        - RetentionApplicator: Found {0} remote instances. Will delete files for {1} older instance(s)." -f $allRemoteInstances.Count, $instancesToDelete.Count) -Level "DEBUG"

            foreach ($instanceEntry in $instancesToDelete) {
                & $LocalWriteLog "          - RetentionApplicator: Preparing to delete instance '$($instanceEntry.Name)' (SortTime: $($instanceEntry.Value.SortTime))." -Level "WARNING"
                foreach ($fileObject in $instanceEntry.Value.Files) {
                    $remoteFileToDelete = $fileObject.OriginalObject
                    if (-not $PSCmdletInstance.ShouldProcess($remoteFileToDelete.FullName, "Delete Replicated File/Part (Retention)")) {
                        & $LocalWriteLog "            - Deletion of '$($remoteFileToDelete.FullName)' skipped by user." -Level "WARNING"; continue
                    }
                    & $LocalWriteLog -Message "            - Deleting: '$($remoteFileToDelete.FullName)'" -Level "WARNING"
                    try { Remove-Item -LiteralPath $remoteFileToDelete.FullName -Force -ErrorAction Stop; & $LocalWriteLog "              - Status: DELETED" -Level "SUCCESS" }
                    catch { & $LocalWriteLog "              - Status: FAILED to delete! Error: $($_.Exception.Message)" -Level "ERROR" }
                }
            }
        }
        else { & $LocalWriteLog ("        - RetentionApplicator: No old instances to delete based on retention count {0} (Found: $($allRemoteInstances.Count))." -f $keepCount) -Level "DEBUG" }
    }
    catch {
        & $LocalWriteLog -Message "[WARNING] RetentionApplicator: Error during remote retention execution: $($_.Exception.Message)" -Level "WARNING"
    }
}

Export-ModuleMember -Function Invoke-ReplicateRetentionPolicy
