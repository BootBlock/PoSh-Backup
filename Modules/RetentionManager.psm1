<#
.SYNOPSIS
    Manages backup archive retention policies for PoSh-Backup.
    This includes finding old archives based on naming patterns and a retention count,
    and deleting them, with an option to send to the Recycle Bin.

.DESCRIPTION
    The RetentionManager module centralizes the logic for applying retention policies
    to backup archives created by PoSh-Backup. It identifies and removes older backup
    files to ensure that only a specified number of recent archives are kept, helping
    to manage storage space.

    The primary function, Invoke-BackupRetentionPolicy, handles:
    - Finding existing backup archives in a destination directory that match a base filename
      and extension.
    - Sorting these archives by creation time.
    - Deleting the oldest archives that exceed the configured retention count.
    - Optionally sending deleted archives to the Recycle Bin (requires Microsoft.VisualBasic assembly).

    This module relies on utility functions (like Write-LogMessage) being made available
    globally by the main PoSh-Backup script importing Utils.psm1.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    17-May-2025
    LastModified:   17-May-2025
    Purpose:        Centralised backup retention policy management for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Core PoSh-Backup module Utils.psm1 (for Write-LogMessage)
                    should be loaded by the parent script.
                    Microsoft.VisualBasic assembly is required for Recycle Bin functionality.
#>

#region --- Private Helper: Invoke-VisualBasicFileOperation ---
# Internal helper for Recycle Bin operations using Microsoft.VisualBasic.
# This function is not exported.
function Invoke-VisualBasicFileOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [ValidateSet('DeleteFile', 'DeleteDirectory')]
        [string]$Operation,
        [Microsoft.VisualBasic.FileIO.UIOption]$UIOption = [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
        [Microsoft.VisualBasic.FileIO.RecycleOption]$RecycleOption = [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
        [Microsoft.VisualBasic.FileIO.UICancelOption]$CancelOption = [Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException
    )
    # Add-Type is called here because it's only needed if Recycle Bin is used.
    # It's assumed the caller (Invoke-BackupRetentionPolicy) checks $VBAssemblyLoaded before calling this with Recycle Bin option.
    # However, a direct call would still need this. For safety, ensure it's present.
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
    } catch {
        # This error should ideally be caught by the caller, which checks VBAssemblyLoaded.
        # If this function were called directly without that check, this would be critical.
        Write-LogMessage "[ERROR] RetentionManager: Failed to load Microsoft.VisualBasic assembly for Recycle Bin operation. Error: $($_.Exception.Message)" -Level ERROR
        throw "RetentionManager: Microsoft.VisualBasic assembly could not be loaded. Recycle Bin operations unavailable."
    }

    switch ($Operation) {
        "DeleteFile"      { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, $UIOption, $RecycleOption, $CancelOption) }
        "DeleteDirectory" { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, $UIOption, $RecycleOption, $CancelOption) }
    }
}
#endregion

#region --- Exported Backup Retention Policy Function ---
function Invoke-BackupRetentionPolicy {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')] # Deleting files is high impact
    <#
    .SYNOPSIS
        Applies the backup retention policy by finding and deleting older backup archives.
    .DESCRIPTION
        This function identifies existing backup archives in a specified directory that match
        a given base filename and extension. It then sorts these archives by creation time
        and deletes the oldest ones, ensuring that no more than the configured retention
        count remains (plus the one currently being created).
        It can optionally send files to the Recycle Bin.
    .PARAMETER DestinationDirectory
        The directory where the backup archives are stored.
    .PARAMETER ArchiveBaseFileName
        The base name of the archive files (without date stamp or extension).
    .PARAMETER ArchiveExtension
        The file extension of the archives (e.g., ".7z", ".zip").
    .PARAMETER RetentionCountToKeep
        The total number of archive versions to keep. For example, if set to 5, after the
        current backup, there should be 5 archives; older ones are deleted.
        A value of 0 or less means unlimited retention by count for this pattern.
    .PARAMETER SendToRecycleBin
        If $true, attempts to send deleted archives to the Recycle Bin. Otherwise, performs
        a permanent deletion.
    .PARAMETER VBAssemblyLoaded
        A boolean indicating if the Microsoft.VisualBasic assembly (required for Recycle Bin)
        has been successfully loaded by the calling script. If $false and $SendToRecycleBin is $true,
        this function will fall back to permanent deletion.
    .PARAMETER IsSimulateMode
        If $true, deletion operations are simulated and logged, but no files are actually deleted.
    .EXAMPLE
        # Invoke-BackupRetentionPolicy -DestinationDirectory "D:\Backups" -ArchiveBaseFileName "MyData" `
        #   -ArchiveExtension ".7z" -RetentionCountToKeep 7 -SendToRecycleBin $true -VBAssemblyLoaded $true
    #>
    param(
        [string]$DestinationDirectory,
        [string]$ArchiveBaseFileName,
        [string]$ArchiveExtension, 
        [int]$RetentionCountToKeep,
        [bool]$SendToRecycleBin,
        [bool]$VBAssemblyLoaded, 
        [switch]$IsSimulateMode
    )
    Write-LogMessage "`n[INFO] RetentionManager: Applying Backup Retention Policy for archives matching base name '$ArchiveBaseFileName' and extension '$ArchiveExtension'..."
    Write-LogMessage "   - Destination Directory: $DestinationDirectory"
    Write-LogMessage "   - Configured Total Retention Count (target after current backup completes): $RetentionCountToKeep"

    $effectiveSendToRecycleBin = $SendToRecycleBin
    if ($SendToRecycleBin -and -not $VBAssemblyLoaded) {
        Write-LogMessage "[WARNING] RetentionManager: Deletion to Recycle Bin requested, but Microsoft.VisualBasic assembly not loaded. Falling back to PERMANENT deletion." -Level WARNING
        $effectiveSendToRecycleBin = $false
    }
    Write-LogMessage "   - Effective Deletion Method for old archives: $(if ($effectiveSendToRecycleBin) {'Send to Recycle Bin'} else {'Permanent Delete'})"

    $literalBaseName = $ArchiveBaseFileName -replace '\*', '`*' -replace '\?', '`?' 
    $filePattern = "$($literalBaseName)*$($ArchiveExtension)" 

    try {
        if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
            Write-LogMessage "   - RetentionManager: Policy SKIPPED. Destination directory '$DestinationDirectory' not found." -Level WARNING
            return
        }

        $existingBackups = Get-ChildItem -Path $DestinationDirectory -Filter $filePattern -File -ErrorAction SilentlyContinue | Sort-Object CreationTime -Descending

        if ($RetentionCountToKeep -le 0) { 
            Write-LogMessage "   - RetentionManager: Retention count is $RetentionCountToKeep; all existing backups matching pattern '$filePattern' will be kept." -Level INFO
            return
        }

        $numberOfOldBackupsToPreserve = $RetentionCountToKeep - 1
        if ($numberOfOldBackupsToPreserve -lt 0) { $numberOfOldBackupsToPreserve = 0 } 

        if (($null -ne $existingBackups) -and ($existingBackups.Count -gt $numberOfOldBackupsToPreserve)) {
            $backupsToDelete = $existingBackups | Select-Object -Skip $numberOfOldBackupsToPreserve
            Write-LogMessage "[INFO] RetentionManager: Found $($existingBackups.Count) existing backups. Will attempt to delete $($backupsToDelete.Count) older backup(s) to meet retention ($RetentionCountToKeep total)." -Level INFO

            foreach ($backupFile in $backupsToDelete) {
                $deleteActionMessage = if ($effectiveSendToRecycleBin) {"Send to Recycle Bin"} else {"Permanently Delete"}
                if (-not $IsSimulateMode.IsPresent) {
                    if ($PSCmdlet.ShouldProcess($backupFile.FullName, $deleteActionMessage)) {
                        Write-LogMessage "       - Deleting: $($backupFile.FullName) (Created: $($backupFile.CreationTime))" -Level WARNING
                        try {
                            if ($effectiveSendToRecycleBin) {
                                # Ensure VB assembly is loaded before calling internal helper, though VBAssemblyLoaded param should gate this
                                if (-not (Get-Module -Name Microsoft.VisualBasic.FileIO.FileSystemWatcher -ErrorAction SilentlyContinue)) {
                                    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
                                }
                                Invoke-VisualBasicFileOperation -Path $backupFile.FullName -Operation "DeleteFile" -RecycleOption ([Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
                                Write-LogMessage "         - Status: MOVED TO RECYCLE BIN" -Level SUCCESS
                            } else {
                                Remove-Item -LiteralPath $backupFile.FullName -Force -ErrorAction Stop
                                Write-LogMessage "         - Status: DELETED PERMANENTLY" -Level SUCCESS
                            }
                        } catch {
                            Write-LogMessage "         - Status: FAILED! Error: $($_.Exception.Message)" -Level ERROR
                        }
                    } else {
                        Write-LogMessage "       - SKIPPED Deletion (ShouldProcess): $($backupFile.FullName)" -Level INFO
                    }
                } else {
                     Write-LogMessage "       - SIMULATE: Would $deleteActionMessage '$($backupFile.FullName)' (Created: $($backupFile.CreationTime))" -Level SIMULATE
                }
            }
        } elseif ($null -ne $existingBackups) {
            Write-LogMessage "   - RetentionManager: Number of existing backups ($($existingBackups.Count)) is at or below target old backups to preserve ($numberOfOldBackupsToPreserve). No older backups to delete." -Level INFO
        } else {
            Write-LogMessage "   - RetentionManager: No existing backups found matching pattern '$filePattern'. No retention actions needed." -Level INFO
        }
    } catch {
        Write-LogMessage "[WARNING] RetentionManager: Error during retention policy for '$ArchiveBaseFileName'. Some old backups might not have been deleted. Error: $($_.Exception.Message)" -Level WARNING
    }
}
#endregion

Export-ModuleMember -Function Invoke-BackupRetentionPolicy
