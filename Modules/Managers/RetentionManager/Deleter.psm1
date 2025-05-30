# Modules\Managers\RetentionManager\Deleter.psm1
<#
.SYNOPSIS
    Sub-module for RetentionManager. Handles the deletion of backup archive instances.
.DESCRIPTION
    This module contains the 'Remove-OldBackupArchiveInstances' function, which takes a list
    of backup instances (each potentially comprising multiple files for split archives)
    and deletes them according to the specified parameters (Recycle Bin, simulation mode, etc.).
    It also includes the internal helper for Recycle Bin operations.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.3 # Revised -Confirm switch handling for Remove-Item again.
    DateCreated:    29-May-2025
    LastModified:   29-May-2025
    Purpose:        Backup archive deletion logic for RetentionManager.
    Prerequisites:  PowerShell 5.1+.
                    Microsoft.VisualBasic assembly for Recycle Bin functionality.
#>

# Explicitly import Utils.psm1 from the main Modules directory.
# $PSScriptRoot here is Modules\Managers\RetentionManager.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "Deleter.psm1 (RetentionManager submodule) FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}

#region --- Private Helper: Invoke-VisualBasicFileOperationInternal ---
function Invoke-VisualBasicFileOperationInternal {
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
        [scriptblock]$Logger
    )
    # Removed $ForceNoUIConfirmation as UIOption directly controls this now.
    & $Logger -Message "RetentionManager/Deleter/Invoke-VisualBasicFileOperationInternal: Logger active for path '$Path'." -Level "DEBUG" -ErrorAction SilentlyContinue
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
        & $LocalWriteLog -Message "[ERROR] RetentionManager/Deleter: Failed to load Microsoft.VisualBasic assembly for Recycle Bin operation. Error: $($_.Exception.Message)" -Level ERROR
        throw "RetentionManager/Deleter: Microsoft.VisualBasic assembly could not be loaded. Recycle Bin operations unavailable."
    }

    switch ($Operation) {
        "DeleteFile"      { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, $UIOption, $RecycleOption, $CancelOption) }
        "DeleteDirectory" { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, $UIOption, $RecycleOption, $CancelOption) }
    }
}
#endregion

#region --- Archive Instance Deleter ---
function Remove-OldBackupArchiveInstances {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [array]$InstancesToDelete, 
        [Parameter(Mandatory = $true)]
        [bool]$EffectiveSendToRecycleBin,
        [Parameter(Mandatory = $true)]
        [bool]$VBAssemblyLoaded, 
        [Parameter(Mandatory = $true)]
        [bool]$RetentionConfirmDeleteFromConfig, # True = Prompt (respect $ConfirmPreference), False = No Prompt (-Confirm:$false)
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )

    & $Logger -Message "RetentionManager/Deleter/Remove-OldBackupArchiveInstances: Logger active. Instances to delete count: $($InstancesToDelete.Count). RetentionConfirmDeleteFromConfig: $RetentionConfirmDeleteFromConfig" -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    if ($InstancesToDelete.Count -eq 0) {
        & $LocalWriteLog -Message "  - RetentionManager/Deleter: No instances marked for deletion." -Level "DEBUG"
        return
    }

    foreach ($instanceEntry in $InstancesToDelete) {
        $instanceIdentifierToDelete = $instanceEntry.Name
        $instanceFilesToDelete = $instanceEntry.Value.Files
        $instanceSortTime = $instanceEntry.Value.SortTime

        & $LocalWriteLog -Message "   - RetentionManager/Deleter: Preparing to delete backup instance '$instanceIdentifierToDelete' (Sorted by Time: $instanceSortTime)." -Level "WARNING"
        
        foreach ($fileToDeleteInfo in $instanceFilesToDelete) {
            $deleteActionMessage = if ($EffectiveSendToRecycleBin) {"Send to Recycle Bin"} else {"Permanently Delete"}
            $shouldProcessTarget = $fileToDeleteInfo.FullName
            
            if ($IsSimulateMode.IsPresent) {
                & $LocalWriteLog -Message "       - SIMULATE: Would $deleteActionMessage '$($fileToDeleteInfo.FullName)' (Part of instance '$instanceIdentifierToDelete', Created: $($fileToDeleteInfo.CreationTime))" -Level "SIMULATE"
                continue 
            }

            if (-not $PSCmdlet.ShouldProcess($shouldProcessTarget, $deleteActionMessage)) {
                & $LocalWriteLog -Message "       - RetentionManager/Deleter: Deletion of file '$($fileToDeleteInfo.FullName)' skipped by user (ShouldProcess)." -Level "WARNING"
                continue
            }
            
            & $LocalWriteLog -Message "       - Deleting: $($fileToDeleteInfo.FullName) (Created: $($fileToDeleteInfo.CreationTime))" -Level "WARNING" 
            try {
                if ($EffectiveSendToRecycleBin) {
                    $vbUIOption = if ($RetentionConfirmDeleteFromConfig) { 
                                      [Microsoft.VisualBasic.FileIO.UIOption]::AllDialogs 
                                  } else { 
                                      [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs 
                                  }
                    
                    Invoke-VisualBasicFileOperationInternal -Path $fileToDeleteInfo.FullName -Operation "DeleteFile" `
                        -RecycleOption ([Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin) `
                        -UIOption $vbUIOption `
                        -Logger $Logger
                    & $LocalWriteLog -Message "         - Status: MOVED TO RECYCLE BIN" -Level "SUCCESS"
                } else {
                    $removeItemParams = @{ LiteralPath = $fileToDeleteInfo.FullName; Force = $true; ErrorAction = 'Stop' }
                    
                    # If RetentionConfirmDeleteFromConfig is $false (meaning "don't prompt from config"),
                    # then add -Confirm:$false to the splatting parameters.
                    # Otherwise, do NOT add -Confirm to splatting, allowing Remove-Item to use $ConfirmPreference.
                    if (-not $RetentionConfirmDeleteFromConfig) {
                        $removeItemParams.Add('Confirm', $false)
                    }
                    # If $RetentionConfirmDeleteFromConfig is $true, 'Confirm' is NOT added to $removeItemParams.
                    # Remove-Item will then respect $ConfirmPreference.
                    
                    Remove-Item @removeItemParams
                    & $LocalWriteLog -Message "         - Status: DELETED PERMANENTLY" -Level "SUCCESS"
                }
            } catch {
                & $LocalWriteLog -Message "         - Status: FAILED! Error: $($_.Exception.Message)" -Level "ERROR"
            }
        }
    }
}
#endregion

Export-ModuleMember -Function Remove-OldBackupArchiveInstances
