# Modules\Managers\RetentionManager.psm1
<#
.SYNOPSIS
    Manages backup archive retention policies for PoSh-Backup.
    This includes finding old archives based on naming patterns and a retention count,
    and deleting them, with an option to send to the Recycle Bin.
    Now correctly handles multi-volume (split) archives as single entities for retention.

.DESCRIPTION
    The RetentionManager module centralizes the logic for applying retention policies
    to backup archives created by PoSh-Backup. It identifies and removes older backup
    files/sets to ensure that only a specified number of recent archives are kept, helping
    to manage storage space.

    The primary function, Invoke-BackupRetentionPolicy, handles:
    - Finding existing backup archives in a destination directory. It now intelligently
      groups multi-volume split archives (e.g., archive.7z.001, .002, etc.) and treats
      them as a single backup instance.
    - Sorting these backup instances by creation time (using the timestamp of the first
      volume for split archives).
    - Deleting the oldest backup instances that exceed the configured retention count.
      If a multi-volume instance is deleted, all its constituent volume files are removed.
    - Optionally sending deleted archives to the Recycle Bin (requires Microsoft.VisualBasic assembly).
    - Allowing configuration-driven confirmation for deletions by controlling item-level cmdlets.

    This module relies on utility functions (like Write-LogMessage) being made available
    globally by the main PoSh-Backup script importing Utils.psm1, or by passing a logger
    reference.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Modified to correctly handle multi-volume (split) archives for retention.
    DateCreated:    17-May-2025
    LastModified:   29-May-2025
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
    [CmdletBinding(SupportsShouldProcess=$true)] 
    <#
    .SYNOPSIS
        Applies the backup retention policy by finding and deleting older backup archives/sets.
    .DESCRIPTION
        This function identifies existing backup archives in a specified directory. It now correctly
        handles single-file archives and multi-volume (split) archives, treating each logical backup
        (whether single or multi-volume) as one "instance" for retention counting.
        It sorts these instances by creation time (using the first volume's time for split sets)
        and deletes the oldest instances that exceed the configured retention count.
        When a multi-volume instance is deleted, all its associated volume files are removed.
        It can optionally send files to the Recycle Bin and allows deletion confirmation
        to be controlled via configuration.
    .PARAMETER DestinationDirectory
        The directory where the backup archives are stored.
    .PARAMETER ArchiveBaseFileName
        The base name of the archive files (e.g., "JobName [DateStamp]").
    .PARAMETER ArchiveExtension
        The primary file extension of the archives (e.g., ".7z", ".zip", or ".exe" if SFX and not split).
        For split archives, this is the extension *before* the volume number (e.g., ".7z" for "archive.7z.001").
    .PARAMETER RetentionCountToKeep
        The total number of archive instances (single files or multi-volume sets) to keep.
        A value of 0 or less means unlimited retention.
    .PARAMETER RetentionConfirmDeleteFromConfig
        A boolean value from the effective job configuration. Controls item-level cmdlet confirmation.
    .PARAMETER SendToRecycleBin
        If $true, attempts to send deleted archives to the Recycle Bin.
    .PARAMETER VBAssemblyLoaded
        A boolean indicating if the Microsoft.VisualBasic assembly is loaded.
    .PARAMETER IsSimulateMode
        If $true, deletion operations are simulated.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function.
    .EXAMPLE
        # Invoke-BackupRetentionPolicy -DestinationDirectory "D:\Backups" -ArchiveBaseFileName "MyData [2023-01-01]" `
        #   -ArchiveExtension ".7z" -RetentionCountToKeep 7 -RetentionConfirmDeleteFromConfig $true `
        #   -SendToRecycleBin $true -VBAssemblyLoaded $true -Logger ${function:Write-LogMessage}
    #>
    param(
        [string]$DestinationDirectory,
        [string]$ArchiveBaseFileName, # e.g., "JobName [DateStamp]"
        [string]$ArchiveExtension,    # e.g., ".7z" or ".exe"
        [int]$RetentionCountToKeep,
        [Parameter(Mandatory)] 
        [bool]$RetentionConfirmDeleteFromConfig,
        [bool]$SendToRecycleBin,
        [bool]$VBAssemblyLoaded, 
        [switch]$IsSimulateMode,
        [Parameter(Mandatory=$true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet # Added for ShouldProcess in main loop
    )
    # Defensive PSSA appeasement line
    & $Logger -Message "Invoke-BackupRetentionPolicy: Logger active for base '$ArchiveBaseFileName', ext '$ArchiveExtension'. ConfirmDelete: $RetentionConfirmDeleteFromConfig" -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    
    & $LocalWriteLog -Message "`n[INFO] RetentionManager: Applying Backup Retention Policy for archives matching base name '$ArchiveBaseFileName' and primary extension '$ArchiveExtension'..."
    & $LocalWriteLog -Message "   - Destination Directory: $DestinationDirectory"
    & $LocalWriteLog -Message "   - Configured Total Retention Count (target instances after current backup completes): $RetentionCountToKeep"
    & $LocalWriteLog -Message "   - Configured Retention Deletion Confirmation: $(if($RetentionConfirmDeleteFromConfig){'Enabled (Item-Level Cmdlet will respect $ConfirmPreference)'}else{'Disabled (Item-Level Cmdlet will use -Confirm:$false)'})"

    $effectiveSendToRecycleBin = $SendToRecycleBin
    if ($SendToRecycleBin -and -not $VBAssemblyLoaded) {
        & $LocalWriteLog -Message "[WARNING] RetentionManager: Deletion to Recycle Bin requested, but Microsoft.VisualBasic assembly not loaded. Falling back to PERMANENT deletion." -Level WARNING
        $effectiveSendToRecycleBin = $false
    }

    $isNetworkPath = $false; try { if (-not [string]::IsNullOrWhiteSpace($DestinationDirectory)) { $uriCheck = [uri]$DestinationDirectory; if ($uriCheck.IsUnc) { $isNetworkPath = $true } } } catch { & $LocalWriteLog -Message "  - RetentionManager: Debug: Could not parse '$DestinationDirectory' as URI to check IsUnc. Assuming not a UNC path for Recycle Bin warning. Error: $($_.Exception.Message)" -Level "DEBUG" }

    if ($effectiveSendToRecycleBin -and $isNetworkPath) {
        & $LocalWriteLog -Message "[WARNING] RetentionManager: 'DeleteToRecycleBin' is enabled for a network destination ('$DestinationDirectory'). This can be unreliable. Consider setting to `$false." -Level WARNING
    }
    & $LocalWriteLog -Message "   - Effective Deletion Method for old archives: $(if ($effectiveSendToRecycleBin) {'Send to Recycle Bin'} else {'Permanent Delete'})"

    try {
        if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
            & $LocalWriteLog -Message "   - RetentionManager: Policy SKIPPED. Destination directory '$DestinationDirectory' not found." -Level WARNING
            return
        }

        $literalBaseName = $ArchiveBaseFileName -replace '([\.\^\$\*\+\?\(\)\[\]\{\}\|\\])', '\$1' # Escape regex special chars in base name
        $fileFilterPattern = "$($literalBaseName)$([regex]::Escape($ArchiveExtension))*" # e.g., "JobName \[DateStamp\]\.7z*"
        
        & $LocalWriteLog -Message "   - RetentionManager: Scanning for files with filter pattern: '$fileFilterPattern'" -Level DEBUG
        $allMatchingFiles = Get-ChildItem -Path $DestinationDirectory -Filter $fileFilterPattern -File -ErrorAction SilentlyContinue
        
        $backupInstances = @{} # Key: InstanceIdentifier (e.g., "JobName [DateStamp].7z"), Value: @{SortTime=datetime; Files=List[FileInfo]}

        foreach ($fileInfo in $allMatchingFiles) {
            $instanceIdentifier = ""
            $isFirstVolumePart = $false
            $fileIsPartOfSplitSet = $false

            # Regex to match base.ext.001, base.ext.002 etc.
            # $ArchiveExtension is the primary extension like ".7z"
            $splitVolumePattern = "^($([regex]::Escape($ArchiveBaseFileName + $ArchiveExtension)))\.(\d{3,})$"

            if ($fileInfo.Name -match $splitVolumePattern) {
                $instanceIdentifier = $Matches[1] # This is "ArchiveBaseFileName + ArchiveExtension", e.g., "JobName [DateStamp].7z"
                $fileIsPartOfSplitSet = $true
                if ($Matches[2] -eq "001") { # Check if it's the first volume
                    $isFirstVolumePart = $true
                }
            } else {
                # Not a numbered split part. Could be a single file (e.g., "JobName [DateStamp].7z" or "JobName [DateStamp].exe")
                # For single files, the instance identifier is the full file name.
                if ($fileInfo.Name -eq ($ArchiveBaseFileName + $ArchiveExtension)) {
                     $instanceIdentifier = $fileInfo.Name
                } elseif ($ArchiveExtension -ne $fileInfo.Extension -and $fileInfo.Name -like ($ArchiveBaseFileName + "*")) {
                    # Handle cases like SFX where ArchiveExtension in config was .7z but output is .exe
                    # Or if ArchiveExtension was .exe and it's just that.
                    # This assumes the ArchiveBaseFileName is the core unique part before any extension.
                    $instanceIdentifier = $fileInfo.Name
                } else {
                    # File doesn't strictly match expected patterns, skip it for retention grouping.
                    & $LocalWriteLog -Message "   - RetentionManager: File '$($fileInfo.Name)' does not match expected single or split volume pattern for base '$ArchiveBaseFileName' and ext '$ArchiveExtension'. Skipping for retention." -Level DEBUG
                    continue
                }
            }

            if (-not $backupInstances.ContainsKey($instanceIdentifier)) {
                $backupInstances[$instanceIdentifier] = @{
                    SortTime = if ($isFirstVolumePart) { $fileInfo.CreationTime } else { [datetime]::MaxValue } # Default to max if not first part yet
                    Files    = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
                }
            }
            $backupInstances[$instanceIdentifier].Files.Add($fileInfo)
            
            # Update SortTime if this is the first volume or if it's a single file instance
            if ($isFirstVolumePart) {
                if ($fileInfo.CreationTime -lt $backupInstances[$instanceIdentifier].SortTime) {
                    $backupInstances[$instanceIdentifier].SortTime = $fileInfo.CreationTime
                }
            } elseif (-not $fileIsPartOfSplitSet) { # Single file instance
                 $backupInstances[$instanceIdentifier].SortTime = $fileInfo.CreationTime
            }
        }

        # Refine SortTime for split instances that might have missed their .001 part initially in the loop
        # or if only non-001 parts were found (orphaned set)
        foreach ($instanceKeyToRefine in $backupInstances.Keys) {
            if ($backupInstances[$instanceKeyToRefine].SortTime -eq [datetime]::MaxValue) {
                if ($backupInstances[$instanceKeyToRefine].Files.Count -gt 0) {
                    $earliestPartFoundTime = ($backupInstances[$instanceKeyToRefine].Files | Sort-Object CreationTime | Select-Object -First 1).CreationTime
                    $backupInstances[$instanceKeyToRefine].SortTime = $earliestPartFoundTime
                    & $LocalWriteLog -Message "[WARNING] RetentionManager: Backup instance '$instanceKeyToRefine' appears to be missing its first volume part (e.g., .001) or was processed out of order. Using earliest found part's time for sorting. This might indicate an incomplete backup set." -Level WARNING
                } else {
                    # Should not happen if files were added, but as a safeguard remove empty instance
                    $backupInstances.Remove($instanceKeyToRefine) 
                }
            }
        }
        
        if ($backupInstances.Count -eq 0) {
            & $LocalWriteLog -Message "   - RetentionManager: No backup instances found matching base '$ArchiveBaseFileName' and ext '$ArchiveExtension'. No retention actions needed." -Level INFO
            return
        }

        $sortedInstances = $backupInstances.GetEnumerator() | Sort-Object {$_.Value.SortTime} -Descending
        
        if ($RetentionCountToKeep -le 0) {
            & $LocalWriteLog -Message "   - RetentionManager: Retention count is $RetentionCountToKeep; all existing backup instances will be kept." -Level INFO
            return
        }
        
        # The number of *old* backup instances to preserve. The current backup isn't in this list yet.
        $numberOfOldInstancesToPreserve = $RetentionCountToKeep - 1 
        if ($numberOfOldInstancesToPreserve -lt 0) { $numberOfOldInstancesToPreserve = 0 }

        if ($sortedInstances.Count -gt $numberOfOldInstancesToPreserve) {
            $instancesToDelete = $sortedInstances | Select-Object -Skip $numberOfOldInstancesToPreserve
            & $LocalWriteLog -Message "[INFO] RetentionManager: Found $($sortedInstances.Count) existing backup instance(s). Will attempt to delete $($instancesToDelete.Count) older instance(s) to meet retention ($RetentionCountToKeep total target)." -Level INFO

            foreach ($instanceEntry in $instancesToDelete) {
                $instanceIdentifierToDelete = $instanceEntry.Name
                $instanceFilesToDelete = $instanceEntry.Value.Files
                $instanceSortTime = $instanceEntry.Value.SortTime

                & $LocalWriteLog -Message "   - RetentionManager: Preparing to delete backup instance '$instanceIdentifierToDelete' (Sorted by Time: $instanceSortTime)." -Level WARNING
                
                foreach ($fileToDeleteInfo in $instanceFilesToDelete) {
                    $deleteActionMessage = if ($effectiveSendToRecycleBin) {"Send to Recycle Bin"} else {"Permanently Delete"}
                    $shouldProcessTarget = $fileToDeleteInfo.FullName
                    
                    if ($IsSimulateMode.IsPresent) {
                        & $LocalWriteLog -Message "       - SIMULATE: Would $deleteActionMessage '$($fileToDeleteInfo.FullName)' (Part of instance '$instanceIdentifierToDelete', Created: $($fileToDeleteInfo.CreationTime))" -Level SIMULATE
                        continue 
                    }

                    if (-not $PSCmdlet.ShouldProcess($shouldProcessTarget, $deleteActionMessage)) {
                        & $LocalWriteLog -Message "       - RetentionManager: Deletion of file '$($fileToDeleteInfo.FullName)' skipped by user (ShouldProcess)." -Level WARNING
                        continue
                    }
                    
                    & $LocalWriteLog -Message "       - Deleting: $($fileToDeleteInfo.FullName) (Created: $($fileToDeleteInfo.CreationTime))" -Level WARNING 
                    try {
                        if ($effectiveSendToRecycleBin) {
                            Invoke-VisualBasicFileOperation -Path $fileToDeleteInfo.FullName -Operation "DeleteFile" `
                                -RecycleOption ([Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin) `
                                -Logger $Logger `
                                -ForceNoUIConfirmation (-not $RetentionConfirmDeleteFromConfig) 
                            & $LocalWriteLog -Message "         - Status: MOVED TO RECYCLE BIN" -Level SUCCESS
                        } else {
                            $removeItemParams = @{ LiteralPath = $fileToDeleteInfo.FullName; Force = $true; ErrorAction = 'Stop' }
                            if (-not $RetentionConfirmDeleteFromConfig) { $removeItemParams.Confirm = $false }
                            Remove-Item @removeItemParams
                            & $LocalWriteLog -Message "         - Status: DELETED PERMANENTLY" -Level SUCCESS
                        }
                    } catch {
                        & $LocalWriteLog -Message "         - Status: FAILED! Error: $($_.Exception.Message)" -Level ERROR
                    }
                }
            }
        } else {
            & $LocalWriteLog -Message "   - RetentionManager: Number of existing backup instances ($($sortedInstances.Count)) is at or below target old instances to preserve ($numberOfOldInstancesToPreserve). No older instances to delete." -Level INFO
        }
    } catch {
        & $LocalWriteLog -Message "[WARNING] RetentionManager: Error during retention policy for '$ArchiveBaseFileName'. Some old backups might not have been deleted. Error: $($_.Exception.Message)" -Level WARNING
    }
    & $LocalWriteLog -Message "[INFO] RetentionManager: Log retention policy application finished for job pattern '$ArchiveBaseFileName'." -Level "INFO" # Corrected log message
}
#endregion

Export-ModuleMember -Function Invoke-BackupRetentionPolicy
