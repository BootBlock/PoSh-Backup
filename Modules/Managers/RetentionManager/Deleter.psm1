# Modules\Managers\RetentionManager\Deleter.psm1
<#
.SYNOPSIS
    Sub-module for RetentionManager. Handles the deletion of backup archive instances.
.DESCRIPTION
    This module contains the 'Remove-OldBackupArchiveInstance' function, which takes a list
    of backup instances (each potentially comprising multiple files for split archives)
    and deletes them according to the specified parameters (Recycle Bin, simulation mode, etc.).
    It now includes a safety check to test an archive's integrity before deleting it if configured,
    and a retry loop to handle file-locking race conditions.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.2 # Enhanced -Simulate output to be more descriptive.
    DateCreated:    29-May-2025
    LastModified:   23-Jun-2025
    Purpose:        Backup archive deletion logic for RetentionManager.
    Prerequisites:  PowerShell 5.1+.
                    Microsoft.VisualBasic assembly for Recycle Bin functionality.
#>

# Explicitly import dependent modules from the main Modules directory.
# $PSScriptRoot here is Modules\Managers\RetentionManager.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\7ZipManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\PasswordManager.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "Deleter.psm1 (RetentionManager submodule) FATAL: Could not import a dependent module. Error: $($_.Exception.Message)"
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
function Remove-OldBackupArchiveInstance {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [array]$InstancesToDelete,
        [Parameter(Mandatory = $true)]
        [bool]$EffectiveSendToRecycleBin,
        [Parameter(Mandatory = $true)]
        [bool]$RetentionConfirmDeleteFromConfig, # True = Prompt (respect $ConfirmPreference), False = No Prompt (-Confirm:$false)
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )

    & $Logger -Message "RetentionManager/Deleter/Remove-OldBackupArchiveInstance: Logger active. Instances to delete count: $($InstancesToDelete.Count). RetentionConfirmDeleteFromConfig: $RetentionConfirmDeleteFromConfig" -Level "DEBUG" -ErrorAction SilentlyContinue
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

        # --- Test Before Delete Logic ---
        if ($EffectiveJobConfig.TestArchiveBeforeDeletion) {
            & $LocalWriteLog -Message "     - TestArchiveBeforeDeletion is TRUE. Performing integrity test before deleting instance '$instanceIdentifierToDelete'." -Level "INFO"
            
            # Find the primary archive file to test (.001 for split, or the main file)
            $fileToTest = $instanceFilesToDelete | Where-Object { $_.Name -match '\.001$' -or $_.Name -eq $instanceIdentifierToDelete } | Sort-Object Name | Select-Object -First 1
            
            if ($null -eq $fileToTest) {
                & $LocalWriteLog -Message "[ERROR] Could not find a primary archive file to test for instance '$instanceIdentifierToDelete'. Skipping deletion of this instance as a safety measure." -Level "ERROR"
                continue
            }

            if ($IsSimulateMode.IsPresent) {
                & $LocalWriteLog -Message "SIMULATE: The integrity of archive instance '$instanceIdentifierToDelete' would be tested before deletion." -Level "SIMULATE"
            } else {
                $passwordForTest = $null
                if ($EffectiveJobConfig.PasswordInUseFor7Zip) {
                    $passwordResult = Get-PoShBackupArchivePassword -JobConfigForPassword $EffectiveJobConfig -JobName "Retention Test for $($EffectiveJobConfig.JobName)" -Logger $Logger
                    $passwordForTest = $passwordResult.PlainTextPassword
                }
                
                $testResult = Test-7ZipArchive -SevenZipPathExe $EffectiveJobConfig.GlobalConfigRef.SevenZipPath `
                                                -ArchivePath $fileToTest.FullName `
                                                -PlainTextPassword $passwordForTest `
                                                -TreatWarningsAsSuccess $EffectiveJobConfig.TreatSevenZipWarningsAsSuccess `
                                                -Logger $Logger
                
                if ($testResult.ExitCode -ne 0 -and ($testResult.ExitCode -ne 1 -or -not $EffectiveJobConfig.TreatSevenZipWarningsAsSuccess)) {
                    & $LocalWriteLog -Message "[CRITICAL] SAFETY HALT: Integrity test FAILED for old archive instance '$instanceIdentifierToDelete' (Exit Code: $($testResult.ExitCode)). This instance WILL NOT be deleted by retention to prevent data loss." -Level "ERROR"
                    continue # Skip to the next instance, do not delete this one.
                } else {
                    & $LocalWriteLog -Message "     - Integrity test PASSED for old archive instance '$instanceIdentifierToDelete'. Proceeding with deletion." -Level "SUCCESS"
                }
            }
        }
        # --- END: Test Before Delete Logic ---

        if ($IsSimulateMode.IsPresent) {
            $simMessage = "SIMULATE: The backup instance '$instanceIdentifierToDelete' (created on '$instanceSortTime') would be removed to comply with retention policy."
            if ($EffectiveSendToRecycleBin) {
                $simMessage += " The files would be sent to the Recycle Bin."
            } else {
                $simMessage += " The files would be permanently deleted."
            }
            if ($EffectiveJobConfig.TestArchiveBeforeDeletion) {
                $simMessage += " This would happen only after a successful integrity test of the archive."
            }
            & $LocalWriteLog -Message $simMessage -Level "SIMULATE"
            continue
        }

        foreach ($fileToDeleteInfo in $instanceFilesToDelete) {
            $deleteActionMessage = if ($EffectiveSendToRecycleBin) {"Send to Recycle Bin"} else {"Permanently Delete"}
            $shouldProcessTarget = $fileToDeleteInfo.FullName

            if (-not $PSCmdlet.ShouldProcess($shouldProcessTarget, $deleteActionMessage)) {
                & $LocalWriteLog -Message "       - RetentionManager/Deleter: Deletion of file '$($fileToDeleteInfo.FullName)' skipped by user (ShouldProcess)." -Level "WARNING"
                continue
            }

            & $LocalWriteLog -Message "       - Deleting: $($fileToDeleteInfo.FullName) (Created: $($fileToDeleteInfo.CreationTime))" -Level "WARNING"
            
            # --- Retry loop for deletion ---
            $maxDeleteRetries = 3
            $deleteRetryDelaySeconds = 2

            for ($attempt = 1; $attempt -le $maxDeleteRetries; $attempt++) {
                try {
                    if ($EffectiveSendToRecycleBin) {
                        $vbUIOption = if ($RetentionConfirmDeleteFromConfig) { [Microsoft.VisualBasic.FileIO.UIOption]::AllDialogs } else { [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs }
                        Invoke-VisualBasicFileOperationInternal -Path $fileToDeleteInfo.FullName -Operation "DeleteFile" `
                            -RecycleOption ([Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin) `
                            -UIOption $vbUIOption `
                            -Logger $Logger
                        & $LocalWriteLog -Message "         - Status: MOVED TO RECYCLE BIN" -Level "SUCCESS"
                    } else {
                        $removeItemParams = @{ LiteralPath = $fileToDeleteInfo.FullName; Force = $true; ErrorAction = 'Stop' }
                        if (-not $RetentionConfirmDeleteFromConfig) { $removeItemParams.Add('Confirm', $false) }
                        Remove-Item @removeItemParams
                        & $LocalWriteLog -Message "         - Status: DELETED PERMANENTLY" -Level "SUCCESS"
                    }
                    break # Exit loop on success
                } catch {
                    if ($attempt -lt $maxDeleteRetries) {
                        & $LocalWriteLog -Message "         - Status: FAILED (Attempt $attempt/$maxDeleteRetries). Retrying in $deleteRetryDelaySeconds seconds... Error: $($_.Exception.Message)" -Level "WARNING"
                        Start-Sleep -Seconds $deleteRetryDelaySeconds
                    } else {
                        & $LocalWriteLog -Message "         - Status: FAILED! Final attempt failed. Error: $($_.Exception.Message)" -Level "ERROR"
                    }
                }
            }
            # --- END: Retry loop for deletion ---
        }
    }
}
#endregion

Export-ModuleMember -Function Remove-OldBackupArchiveInstance
