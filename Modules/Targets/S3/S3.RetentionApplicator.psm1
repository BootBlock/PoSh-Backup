# Modules\Targets\S3\S3.RetentionApplicator.psm1
<#
.SYNOPSIS
    A sub-module for S3.Target.psm1. Handles the remote retention policy.
.DESCRIPTION
    This module provides the 'Invoke-S3RetentionPolicy' function. It is responsible for
    applying a count-based retention policy to a remote S3-compatible destination. It lists
    the objects in the bucket, groups them into backup instances, and deletes the oldest
    instances using Remove-S3Object to meet the configured retention count.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    28-Jun-2025
    LastModified:   28-Jun-2025
    Purpose:        To isolate the S3 remote retention logic.
    Prerequisites:  PowerShell 5.1+, AWS.Tools.S3 module.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Targets\S3
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utilities\RetentionUtils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "S3.RetentionApplicator.psm1 FATAL: Could not import a dependent module. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Invoke-S3RetentionPolicy {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$RetentionSettings,
        [Parameter(Mandatory = $true)]
        [string]$BucketName,
        [Parameter(Mandatory = $true)]
        [string]$RemoteKeyPrefix, # e.g., "JobName/" or ""
        [Parameter(Mandatory = $true)]
        [hashtable]$S3CommonParameters,
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

    & $Logger -Message "S3.RetentionApplicator: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    $keepCount = $RetentionSettings.KeepCount
    & $LocalWriteLog -Message ("  - S3.RetentionApplicator: Applying remote retention (KeepCount: {0}) in Bucket '{1}' with Prefix '{2}'." -f $keepCount, $BucketName, $RemoteKeyPrefix) -Level "INFO"

    try {
        $getS3ListParams = $S3CommonParameters.Clone()
        $getS3ListParams.BucketName = $BucketName
        $getS3ListParams.Prefix = $RemoteKeyPrefix
        $allRemoteObjects = Get-S3ObjectV2 @getS3ListParams

        $fileObjectListForGrouping = $allRemoteObjects | ForEach-Object {
            [PSCustomObject]@{
                Name           = (Split-Path -Path $_.Key -Leaf)
                SortTime       = $_.LastModified
                OriginalObject = $_
            }
        }

        $remoteInstances = Group-BackupInstancesByTimestamp -FileObjectList $fileObjectListForGrouping `
            -ArchiveBaseName $ArchiveBaseName `
            -ArchiveDateFormat $ArchiveDateFormat `
            -PrimaryArchiveExtension $ArchiveExtension `
            -Logger $Logger

        if ($remoteInstances.Count -gt $keepCount) {
            $sortedInstances = $remoteInstances.GetEnumerator() | Sort-Object { $_.Value.SortTime } -Descending
            $instancesToDelete = $sortedInstances | Select-Object -Skip $keepCount
            & $LocalWriteLog -Message ("    - S3.RetentionApplicator: Found {0} remote instances. Will delete files for {1} older instance(s)." -f $remoteInstances.Count, $instancesToDelete.Count) -Level "DEBUG"

            foreach ($instanceEntry in $instancesToDelete) {
                & $LocalWriteLog "      - S3.RetentionApplicator: Preparing to delete instance '$($instanceEntry.Name)' (SortTime: $($instanceEntry.Value.SortTime))." -Level "WARNING"
                foreach ($s3ObjectContainer in $instanceEntry.Value.Files) {
                    $s3ObjectToDelete = $s3ObjectContainer.OriginalObject
                    if (-not $PSCmdletInstance.ShouldProcess($s3ObjectToDelete.Key, "Delete Remote S3 Object (Retention)")) {
                        & $LocalWriteLog ("        - Deletion of '{0}' skipped by user." -f $s3ObjectToDelete.Key) -Level "WARNING"; continue
                    }
                    & $LocalWriteLog -Message ("        - Deleting: '{0}'" -f $s3ObjectToDelete.Key) -Level "WARNING"
                    try {
                        $removeS3Params = $S3CommonParameters.Clone()
                        $removeS3Params.BucketName = $BucketName
                        $removeS3Params.Key = $s3ObjectToDelete.Key
                        $removeS3Params.Force = $true
                        Remove-S3Object @removeS3Params
                        & $LocalWriteLog "          - Status: DELETED" -Level "SUCCESS"
                    }
                    catch { & $LocalWriteLog "          - Status: FAILED to delete! Error: $($_.Exception.Message)" -Level "ERROR" }
                }
            }
        } else {
            & $LocalWriteLog ("    - S3.RetentionApplicator: No old instances to delete based on retention count {0} (Found: {1})." -f $keepCount, $remoteInstances.Count) -Level "DEBUG"
        }
    }
    catch {
        & $LocalWriteLog -Message "[WARNING] S3.RetentionApplicator: Error during remote retention execution: $($_.Exception.Message)" -Level "WARNING"
    }
}

Export-ModuleMember -Function Invoke-S3RetentionPolicy
