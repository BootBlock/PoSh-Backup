# Modules\Targets\UNC\UNCRetentionApplicator.psm1
<#
.SYNOPSIS
    A sub-module for UNC.Target.psm1. Handles the remote retention policy on a UNC share.
.DESCRIPTION
    This module provides the 'Invoke-UNCRetentionPolicy' function. It is responsible for
    applying a count-based retention policy to a remote UNC destination. It scans the
    directory, groups backup files into instances using the centralised RetentionUtils,
    and deletes the oldest instances to meet the configured retention count.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    27-Jun-2025
    LastModified:   27-Jun-2025
    Purpose:        To isolate the UNC remote retention logic.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Targets\UNC
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utilities\RetentionUtils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "UNCRetentionApplicator.psm1 FATAL: Could not import a dependent module. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Invoke-UNCRetentionPolicy {
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

    & $Logger -Message "UNCRetentionApplicator: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    $keepCount = $RetentionSettings.KeepCount
    & $LocalWriteLog -Message ("  - UNCRetentionApplicator: Applying remote retention (KeepCount: {0}) in directory '{1}'." -f $keepCount, $RemoteDirectory) -Level "INFO"

    try {
        if (-not (Test-Path -LiteralPath $RemoteDirectory -PathType Container)) {
            & $LocalWriteLog -Message "    - UNCRetentionApplicator: Directory '$RemoteDirectory' not found for retention. Skipping." -Level "WARNING"
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
            & $LocalWriteLog -Message ("    - UNCRetentionApplicator: Found {0} remote instances. Will delete files for {1} older instance(s)." -f $allRemoteInstances.Count, $instancesToDelete.Count) -Level "INFO"
            
            foreach ($instanceEntry in $instancesToDelete) {
                & $LocalWriteLog "      - UNCRetentionApplicator: Preparing to delete instance '$($instanceEntry.Name)' (SortTime: $($instanceEntry.Value.SortTime))." -Level "WARNING"
                foreach ($fileObject in $instanceEntry.Value.Files) {
                    $remoteFileToDelete = $fileObject.OriginalObject
                    if (-not $PSCmdletInstance.ShouldProcess($remoteFileToDelete.FullName, "Delete Remote Archive File/Part (Retention)")) {
                        & $LocalWriteLog "        - Deletion of '$($remoteFileToDelete.FullName)' skipped by user." -Level "WARNING"; continue
                    }
                    & $LocalWriteLog "        - Deleting: '$($remoteFileToDelete.FullName)'" -Level "WARNING"
                    try { Remove-Item -LiteralPath $remoteFileToDelete.FullName -Force -ErrorAction Stop; & $LocalWriteLog "          - Status: DELETED" -Level "SUCCESS" }
                    catch { & $LocalWriteLog "          - Status: FAILED to delete! Error: $($_.Exception.Message)" -Level "ERROR" }
                }
            }
        }
        else { & $LocalWriteLog ("    - UNCRetentionApplicator: No old instances to delete based on retention count {0} (Found: $($allRemoteInstances.Count))." -f $keepCount) -Level "INFO" }
    }
    catch {
        & $LocalWriteLog -Message "[WARNING] UNCRetentionApplicator: Error during remote retention execution: $($_.Exception.Message)" -Level "WARNING"
    }
}

Export-ModuleMember -Function Invoke-UNCRetentionPolicy
