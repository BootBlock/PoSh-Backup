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
    - Allowing configuration-driven confirmation for deletions by controlling item-level cmdlets.

    This module relies on utility functions (like Write-LogMessage) being made available
    globally by the main PoSh-Backup script importing Utils.psm1, or by passing a logger
    reference.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.9
    DateCreated:    17-May-2025
    LastModified:   19-May-2025
    Purpose:        Centralised backup retention policy management for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Core PoSh-Backup module Utils.psm1 (for Write-LogMessage)
                    should be loaded by the parent script, or logger passed explicitly.
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
        [Microsoft.VisualBasic.FileIO.UICancelOption]$CancelOption = [Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException,
        [Parameter(Mandatory=$true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory=$false)] 
        [bool]$ForceNoUIConfirmation = $false
    )
    # Defensive PSSA appeasement line by directly calling the logger for this initial message
    & $Logger -Message "Invoke-VisualBasicFileOperation: Logger parameter active for path '$Path'." -Level "DEBUG" -ErrorAction SilentlyContinue

    # Internal helper to use the passed-in logger consistently for other messages
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
    } catch {
        & $LocalWriteLog -Message "[ERROR] RetentionManager/Invoke-VisualBasicFileOperation: Failed to load Microsoft.VisualBasic assembly for Recycle Bin operation. Error: $($_.Exception.Message)" -Level ERROR
        throw "RetentionManager: Microsoft.VisualBasic assembly could not be loaded. Recycle Bin operations unavailable."
    }

    $effectiveUIOption = $UIOption
    if ($ForceNoUIConfirmation) {
        $effectiveUIOption = [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs
    }

    switch ($Operation) {
        "DeleteFile"      { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, $effectiveUIOption, $RecycleOption, $CancelOption) }
        "DeleteDirectory" { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, $effectiveUIOption, $RecycleOption, $CancelOption) }
    }
}
#endregion

#region --- Exported Backup Retention Policy Function ---
function Invoke-BackupRetentionPolicy {
    [CmdletBinding(SupportsShouldProcess=$true)] # ConfirmImpact='High' REMOVED
    <#
    .SYNOPSIS
        Applies the backup retention policy by finding and deleting older backup archives.
    .DESCRIPTION
        This function identifies existing backup archives in a specified directory that match
        a given base filename and extension. It then sorts these archives by creation time
        and deletes the oldest ones, ensuring that no more than the configured retention
        count remains (plus the one currently being created).
        It can optionally send files to the Recycle Bin and allows deletion confirmation
        to be controlled via configuration by setting the -Confirm parameter on item-level cmdlets.
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
    .PARAMETER RetentionConfirmDeleteFromConfig
        A boolean value from the effective job configuration. If $true, item-level cmdlets (Remove-Item)
        will respect PowerShell's $ConfirmPreference for their own prompting. If $false, item-level 
        cmdlets will be invoked with their confirmation suppressed (e.g., Remove-Item -Confirm:$false).
    .PARAMETER SendToRecycleBin
        If $true, attempts to send deleted archives to the Recycle Bin. Otherwise, performs
        a permanent deletion.
    .PARAMETER VBAssemblyLoaded
        A boolean indicating if the Microsoft.VisualBasic assembly (required for Recycle Bin)
        has been successfully loaded by the calling script. If $false and $SendToRecycleBin is $true,
        this function will fall back to permanent deletion.
    .PARAMETER IsSimulateMode
        If $true, deletion operations are simulated and logged, but no files are actually deleted.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function.
    .EXAMPLE
        # Invoke-BackupRetentionPolicy -DestinationDirectory "D:\Backups" -ArchiveBaseFileName "MyData" `
        #   -ArchiveExtension ".7z" -RetentionCountToKeep 7 -RetentionConfirmDeleteFromConfig $true `
        #   -SendToRecycleBin $true -VBAssemblyLoaded $true -Logger ${function:Write-LogMessage}
    #>
    param(
        [string]$DestinationDirectory,
        [string]$ArchiveBaseFileName,
        [string]$ArchiveExtension, 
        [int]$RetentionCountToKeep,
        [Parameter(Mandatory)] 
        [bool]$RetentionConfirmDeleteFromConfig,
        [bool]$SendToRecycleBin,
        [bool]$VBAssemblyLoaded, 
        [switch]$IsSimulateMode,
        [Parameter(Mandatory=$true)]
        [scriptblock]$Logger
    )
    # Defensive PSSA appeasement line by directly calling the logger for this initial message
    & $Logger -Message "Invoke-BackupRetentionPolicy: Logger parameter active for base name '$ArchiveBaseFileName'. ConfirmDeleteFromConfig: $RetentionConfirmDeleteFromConfig" -Level "DEBUG" -ErrorAction SilentlyContinue

    # Internal helper to use the passed-in logger consistently for other messages
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if ($null -ne $ForegroundColour) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    
    & $LocalWriteLog -Message "`n[INFO] RetentionManager: Applying Backup Retention Policy for archives matching base name '$ArchiveBaseFileName' and extension '$ArchiveExtension'..."
    & $LocalWriteLog -Message "   - Destination Directory: $DestinationDirectory"
    & $LocalWriteLog -Message "   - Configured Total Retention Count (target after current backup completes): $RetentionCountToKeep"
    & $LocalWriteLog -Message "   - Configured Retention Deletion Confirmation: $(if($RetentionConfirmDeleteFromConfig){'Enabled (Item-Level Cmdlet will respect $ConfirmPreference)'}else{'Disabled (Item-Level Cmdlet will use -Confirm:$false)'})"


    $effectiveSendToRecycleBin = $SendToRecycleBin
    if ($SendToRecycleBin -and -not $VBAssemblyLoaded) {
        & $LocalWriteLog -Message "[WARNING] RetentionManager: Deletion to Recycle Bin requested, but Microsoft.VisualBasic assembly not loaded. Falling back to PERMANENT deletion." -Level WARNING
        $effectiveSendToRecycleBin = $false
    }

    $isNetworkPath = $false
    try {
        if (-not [string]::IsNullOrWhiteSpace($DestinationDirectory)) {
            $uriCheck = [uri]$DestinationDirectory
            if ($uriCheck.IsUnc) { $isNetworkPath = $true }
        }
    } catch { /* Path is not a valid URI, likely a local path */ }

    if ($effectiveSendToRecycleBin -and $isNetworkPath) {
        & $LocalWriteLog -Message "[WARNING] RetentionManager: 'DeleteToRecycleBin' is enabled for a network destination ('$DestinationDirectory'). Sending files to the Recycle Bin from network shares can be unreliable or may not be supported by the remote server. Files might be permanently deleted or the operation could fail. Consider setting 'DeleteToRecycleBin = `$false' for network destinations if Recycle Bin functionality is critical." -Level WARNING
    }
    
    & $LocalWriteLog -Message "   - Effective Deletion Method for old archives: $(if ($effectiveSendToRecycleBin) {'Send to Recycle Bin'} else {'Permanent Delete'})"

    $literalBaseName = $ArchiveBaseFileName -replace '\*', '`*' -replace '\?', '`?' 
    $filePattern = "$($literalBaseName)*$($ArchiveExtension)" 

    try {
        if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
            & $LocalWriteLog -Message "   - RetentionManager: Policy SKIPPED. Destination directory '$DestinationDirectory' not found." -Level WARNING
            return
        }

        $existingBackups = Get-ChildItem -Path $DestinationDirectory -Filter $filePattern -File -ErrorAction SilentlyContinue | Sort-Object CreationTime -Descending

        if ($RetentionCountToKeep -le 0) { 
            & $LocalWriteLog -Message "   - RetentionManager: Retention count is $RetentionCountToKeep; all existing backups matching pattern '$filePattern' will be kept." -Level INFO
            return
        }

        $numberOfOldBackupsToPreserve = $RetentionCountToKeep - 1
        if ($numberOfOldBackupsToPreserve -lt 0) { $numberOfOldBackupsToPreserve = 0 } 

        if (($null -ne $existingBackups) -and ($existingBackups.Count -gt $numberOfOldBackupsToPreserve)) {
            $backupsToDelete = $existingBackups | Select-Object -Skip $numberOfOldBackupsToPreserve
            & $LocalWriteLog -Message "[INFO] RetentionManager: Found $($existingBackups.Count) existing backups. Will attempt to delete $($backupsToDelete.Count) older backup(s) to meet retention ($RetentionCountToKeep total)." -Level INFO

            foreach ($backupFile in $backupsToDelete) {
                $deleteActionMessage = if ($effectiveSendToRecycleBin) {"Send to Recycle Bin"} else {"Permanently Delete"}
                $shouldProcessTarget = $backupFile.FullName
                
                if ($IsSimulateMode.IsPresent) {
                    & $LocalWriteLog -Message "       - SIMULATE: Would $deleteActionMessage '$($backupFile.FullName)' (Created: $($backupFile.CreationTime))" -Level SIMULATE
                    continue 
                }

                # Call $PSCmdlet.ShouldProcess. Since this function's CmdletBinding no longer has ConfirmImpact='High',
                # this call will:
                # 1. Respect -WhatIf (log and return $false if -WhatIf is active for PoSh-Backup.ps1).
                # 2. Respect -Confirm or -Confirm:$false passed to PoSh-Backup.ps1 if Operations.psm1 also passed it down.
                #    (Operations.psm1 passes -Confirm:$false if RetentionConfirmDelete is false).
                # 3. If no explicit -Confirm was passed down, it will check $ConfirmPreference against its default Medium impact.
                #    If $ConfirmPreference is High, it WILL prompt here. If $ConfirmPreference is Medium or Low, it will NOT.
                # This is the behavior we want for the *overall* operation of this function.
                # The item-level deletion cmdlets below will then have their own confirmation controlled by RetentionConfirmDeleteFromConfig.
                if (-not $PSCmdlet.ShouldProcess($shouldProcessTarget, $deleteActionMessage)) {
                    # If ShouldProcess returns false:
                    # - It could be due to -WhatIf on the main script.
                    # - It could be due to the user responding "No" if a prompt occurred (e.g., if PoSh-Backup.ps1 was run with -Confirm and this function was called without -Confirm:$false by Operations.psm1).
                    # In either case, we skip this file.
                    continue
                }
                
                # If we reach here, $PSCmdlet.ShouldProcess returned $true.
                # This means -WhatIf was not active on the main script OR if a prompt occurred from ShouldProcess itself, the user said "Yes".
                # Now we proceed to the actual deletion, where RetentionConfirmDeleteFromConfig dictates the item-level cmdlet's confirmation.
                
                & $LocalWriteLog -Message "       - Deleting: $($backupFile.FullName) (Created: $($backupFile.CreationTime))" -Level WARNING 
                try {
                    if ($effectiveSendToRecycleBin) {
                        Invoke-VisualBasicFileOperation -Path $backupFile.FullName -Operation "DeleteFile" `
                            -RecycleOption ([Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin) `
                            -Logger $Logger `
                            -ForceNoUIConfirmation (-not $RetentionConfirmDeleteFromConfig) # If config says auto-delete, force no UI for VB
                        & $LocalWriteLog -Message "         - Status: MOVED TO RECYCLE BIN" -Level SUCCESS
                    } else {
                        $removeItemParams = @{
                            LiteralPath = $backupFile.FullName
                            Force = $true
                            ErrorAction = 'Stop'
                        }
                        # If RetentionConfirmDeleteFromConfig is $false (auto-delete), explicitly pass -Confirm:$false to Remove-Item.
                        # If $RetentionConfirmDeleteFromConfig is $true, do NOT add -Confirm:$false, so Remove-Item (HighImpact)
                        # will prompt if $ConfirmPreference is High.
                        if (-not $RetentionConfirmDeleteFromConfig) {
                            $removeItemParams.Confirm = $false
                        }
                        Remove-Item @removeItemParams
                        & $LocalWriteLog -Message "         - Status: DELETED PERMANENTLY" -Level SUCCESS
                    }
                } catch {
                    & $LocalWriteLog -Message "         - Status: FAILED! Error: $($_.Exception.Message)" -Level ERROR
                }
            }
        } elseif ($null -ne $existingBackups) {
            & $LocalWriteLog -Message "   - RetentionManager: Number of existing backups ($($existingBackups.Count)) is at or below target old backups to preserve ($numberOfOldBackupsToPreserve). No older backups to delete." -Level INFO
        } else {
            & $LocalWriteLog -Message "   - RetentionManager: No existing backups found matching pattern '$filePattern'. No retention actions needed." -Level INFO
        }
    } catch {
        & $LocalWriteLog -Message "[WARNING] RetentionManager: Error during retention policy for '$ArchiveBaseFileName'. Some old backups might not have been deleted. Error: $($_.Exception.Message)" -Level WARNING
    }
}
#endregion

Export-ModuleMember -Function Invoke-BackupRetentionPolicy
