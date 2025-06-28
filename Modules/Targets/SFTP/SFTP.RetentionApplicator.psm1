# Modules\Targets\SFTP\SFTP.RetentionApplicator.psm1
<#
.SYNOPSIS
    A sub-module for SFTP.Target.psm1. Handles the remote retention policy.
.DESCRIPTION
    This module provides the 'Invoke-SFTPRetentionPolicy' function. It is responsible for
    applying a count-based retention policy to a remote SFTP destination. It lists the
    files in the directory, groups them into backup instances, and deletes the oldest
    instances to meet the configured retention count.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    28-Jun-2025
    LastModified:   28-Jun-2025
    Purpose:        To isolate the SFTP remote retention logic.
    Prerequisites:  PowerShell 5.1+, Posh-SSH module.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Targets\SFTP
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utilities\RetentionUtils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "SFTP.RetentionApplicator.psm1 FATAL: Could not import a dependent module. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Invoke-SFTPRetentionPolicy {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [object]$SftpSession,
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

    & $Logger -Message "SFTP.RetentionApplicator: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    $keepCount = $RetentionSettings.KeepCount
    & $LocalWriteLog -Message ("  - SFTP.RetentionApplicator: Applying remote retention (KeepCount: {0}) in '{1}'." -f $keepCount, $RemoteDirectory) -Level "INFO"

    try {
        $allRemoteFileObjects = Get-SFTPChildItem -SessionId $SftpSession.SessionId -Path $RemoteDirectory -ErrorAction Stop | Where-Object { -not $_.IsDirectory }
        $fileObjectListForGrouping = $allRemoteFileObjects | Where-Object { $_.Name -like "$ArchiveBaseName*" } | ForEach-Object { 
            [PSCustomObject]@{ 
                Name           = $_.Name
                SortTime       = $_.LastWriteTime
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
            & $LocalWriteLog -Message ("    - SFTP.RetentionApplicator: Found {0} remote instances. Will delete files for {1} older instance(s)." -f $remoteInstances.Count, $instancesToDelete.Count) -Level "DEBUG"

            foreach ($instanceEntry in $instancesToDelete) {
                & $LocalWriteLog "      - SFTP.RetentionApplicator: Preparing to delete instance '$($instanceEntry.Name)' (SortTime: $($instanceEntry.Value.SortTime))." -Level "WARNING"
                foreach ($sftpObjectContainer in $instanceEntry.Value.Files) {
                    $sftpObjectToDelete = $sftpObjectContainer.OriginalObject
                    $fileToDeletePathOnSftp = "$RemoteDirectory/$($sftpObjectToDelete.Name)"
                    
                    if (-not $PSCmdletInstance.ShouldProcess($fileToDeletePathOnSftp, "Delete Remote SFTP File (Retention)")) {
                        & $LocalWriteLog ("        - Deletion of '{0}' skipped by user." -f $fileToDeletePathOnSftp) -Level "WARNING"; continue
                    }

                    & $LocalWriteLog -Message ("        - Deleting: '{0}'" -f $fileToDeletePathOnSftp) -Level "WARNING"
                    try {
                        Remove-SFTPItem -SessionId $SftpSession.SessionId -Path $fileToDeletePathOnSftp -ErrorAction Stop
                        & $LocalWriteLog "          - Status: DELETED" -Level "SUCCESS"
                    }
                    catch {
                        # Log the error, but don't re-throw, so we can attempt to delete other files/instances.
                        # The overall transfer status will still reflect a failure if any deletion fails.
                        & $LocalWriteLog "          - Status: FAILED! Error: $($_.Exception.Message)" -Level "ERROR"
                    }
                }
            }
        }
        else { & $LocalWriteLog ("    - SFTP.RetentionApplicator: No old instances to delete based on retention count {0} (Found: {1})." -f $keepCount, $remoteInstances.Count) -Level "DEBUG" }
    }
    catch {
        # This will catch errors from the initial Get-SFTPChildItem.
        & $LocalWriteLog -Message "[WARNING] SFTP.RetentionApplicator: Error during remote retention execution: $($_.Exception.Message)" -Level "WARNING"
    }
}

Export-ModuleMember -Function Invoke-SFTPRetentionPolicy
