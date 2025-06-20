# Modules\Managers\RetentionManager.psm1
<#
.SYNOPSIS
    Manages backup archive retention policies for PoSh-Backup. This module now acts as a facade,
    delegating scanning and deletion tasks to sub-modules.
.DESCRIPTION
    The RetentionManager module centralises the logic for applying retention policies.
    It uses sub-modules for specific tasks:
    - 'Scanner.psm1': Finds and groups backup archive instances, and identifies pinned backups.
    - 'Deleter.psm1': Handles the actual deletion of identified instances.

    The main function, Invoke-BackupRetentionPolicy, orchestrates these steps, ensuring that
    any backups marked as 'pinned' are excluded from the retention policy and are not deleted.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.4.0 # Added EffectiveJobConfig parameter for TestBeforeDelete feature.
    DateCreated:    17-May-2025
    LastModified:   15-Jun-2025
    Purpose:        Facade for centralised backup retention policy management.
    Prerequisites:  PowerShell 5.1+.
                    Sub-modules (Scanner.psm1, Deleter.psm1) must exist in '.\Modules\Managers\RetentionManager\'.
#>

# Explicitly import Utils.psm1 from the main Modules directory.
# $PSScriptRoot here is Modules\Managers.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "RetentionManager.psm1 (Facade) FATAL: Could not import main Utils.psm1. Error: $($_.Exception.Message)"
    throw
}

#region --- Sub-Module Imports ---
$subModulesPath = Join-Path -Path $PSScriptRoot -ChildPath "RetentionManager"

try {
    Import-Module -Name (Join-Path -Path $subModulesPath -ChildPath "Scanner.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $subModulesPath -ChildPath "Deleter.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "RetentionManager.psm1 (Facade) FATAL: Could not import one or more required sub-modules from '$subModulesPath'. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- Exported Backup Retention Policy Function ---
function Invoke-BackupRetentionPolicy {
    [CmdletBinding()]
    param(
        [string]$DestinationDirectory,
        [string]$ArchiveBaseFileName,
        [string]$ArchiveExtension,
        [string]$ArchiveDateFormat,
        [int]$RetentionCountToKeep,
        [Parameter(Mandatory)]
        [bool]$RetentionConfirmDeleteFromConfig,
        [bool]$SendToRecycleBin,
        [bool]$VBAssemblyLoaded,
        [switch]$IsSimulateMode,
        [Parameter(Mandatory=$true)]
        [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory=$true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )
    & $Logger -Message "RetentionManager/Invoke-BackupRetentionPolicy (Facade): Logger active for base '$ArchiveBaseFileName', ext '$ArchiveExtension'. ConfirmDelete: $RetentionConfirmDeleteFromConfig" -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    & $LocalWriteLog -Message "`n[DEBUG] RetentionManager (Facade): Applying Backup Retention Policy for archives matching base name '$ArchiveBaseFileName' and primary extension '$ArchiveExtension'..." -Level "DEBUG"
    & $LocalWriteLog -Message "   - Destination Directory: $DestinationDirectory"
    & $LocalWriteLog -Message "   - Configured Total Retention Count (target instances after current backup completes): $RetentionCountToKeep"
    & $LocalWriteLog -Message "   - Configured Retention Deletion Confirmation: $(if($RetentionConfirmDeleteFromConfig){'Enabled (Item-Level Cmdlet will respect $ConfirmPreference)'}else{'Disabled (Item-Level Cmdlet will use -Confirm:$false)'})"

    $effectiveSendToRecycleBin = $SendToRecycleBin
    if ($SendToRecycleBin -and -not $VBAssemblyLoaded) {
        & $LocalWriteLog -Message "[WARNING] RetentionManager (Facade): Deletion to Recycle Bin requested, but Microsoft.VisualBasic assembly not loaded. Falling back to PERMANENT deletion." -Level WARNING
        $effectiveSendToRecycleBin = $false
    }

    $isNetworkPath = $false; try { if (-not [string]::IsNullOrWhiteSpace($DestinationDirectory)) { $uriCheck = [uri]$DestinationDirectory; if ($uriCheck.IsUnc) { $isNetworkPath = $true } } } catch { & $LocalWriteLog -Message "  - RetentionManager (Facade): Debug: Could not parse '$DestinationDirectory' as URI to check IsUnc. Assuming not a UNC path for Recycle Bin warning. Error: $($_.Exception.Message)" -Level "DEBUG" }

    if ($effectiveSendToRecycleBin -and $isNetworkPath) {
        & $LocalWriteLog -Message "[WARNING] RetentionManager (Facade): 'DeleteToRecycleBin' is enabled for a network destination ('$DestinationDirectory'). This can be unreliable. Consider setting to `$false." -Level WARNING
    }
    & $LocalWriteLog -Message "   - Effective Deletion Method for old archives: $(if ($effectiveSendToRecycleBin) {'Send to Recycle Bin'} else {'Permanent Delete'})"

    $oldErrorActionPreference = $ErrorActionPreference # Store original preference
    try {
        $ErrorActionPreference = 'Stop' # Force errors within this try block to be terminating
        & $LocalWriteLog -Message "RetentionManager (Facade): Temporarily set ErrorActionPreference to 'Stop'." -Level "DEBUG"

        & $LocalWriteLog -Message "RetentionManager (Facade): Calling Find-BackupArchiveInstance..." -Level "DEBUG"
        $backupInstances = Find-BackupArchiveInstance -DestinationDirectory $DestinationDirectory `
                                                      -ArchiveBaseFileName $ArchiveBaseFileName `
                                                      -ArchiveExtension $ArchiveExtension `
                                                      -ArchiveDateFormat $ArchiveDateFormat `
                                                      -Logger $Logger
                                                      # ErrorAction Stop is now inherited

        & $LocalWriteLog -Message "RetentionManager (Facade): Find-BackupArchiveInstance returned $($backupInstances.Count) instance(s)." -Level "DEBUG"

        if ($null -eq $backupInstances) {
            & $LocalWriteLog -Message "   - RetentionManager (Facade): Find-BackupArchiveInstance returned null. No retention actions needed." -Level "WARNING"
            return
        }
        if ($backupInstances.Count -eq 0) {
            & $LocalWriteLog -Message "   - RetentionManager (Facade): No backup instances found by Scanner. No retention actions needed." -Level "INFO"
            return
        }

        # --- Filter out pinned backups ---
        $unpinnedInstances = @{}
        $pinnedInstances = @{}
        foreach ($instanceEntry in $backupInstances.GetEnumerator()) {
            if ($instanceEntry.Value.Pinned) {
                $pinnedInstances[$instanceEntry.Name] = $instanceEntry.Value
            } else {
                $unpinnedInstances[$instanceEntry.Name] = $instanceEntry.Value
            }
        }

        if ($pinnedInstances.Count -gt 0) {
            & $LocalWriteLog -Message "   - RetentionManager (Facade): Found $($pinnedInstances.Count) pinned backup instance(s) which are exempt from retention: $($pinnedInstances.Keys -join ', ')" -Level "INFO"
        }
        # --- END ---

        & $LocalWriteLog -Message "RetentionManager (Facade): Attempting to sort $($unpinnedInstances.Count) unpinned instance(s)..." -Level "DEBUG"
        $sortedInstances = $null
        if ($null -ne $unpinnedInstances.GetEnumerator()) {
            $sortedInstances = $unpinnedInstances.GetEnumerator() | Sort-Object {$_.Value.SortTime} -Descending
            # ErrorAction Stop is inherited
            & $LocalWriteLog -Message "RetentionManager (Facade): Successfully sorted instances. Count: $($sortedInstances.Count)." -Level "DEBUG"
        } else {
            & $LocalWriteLog -Message "[WARNING] RetentionManager (Facade): unpinnedInstances.GetEnumerator() was null. Cannot sort. Instance count: $($unpinnedInstances.Count)" -Level "WARNING"
            $sortedInstances = @()
        }

        if ($RetentionCountToKeep -le 0) {
            & $LocalWriteLog -Message "   - RetentionManager (Facade): Retention count is $RetentionCountToKeep; all existing unpinned backup instances will be kept." -Level "INFO"
            return
        }

        & $LocalWriteLog -Message "RetentionManager (Facade): Total sorted unpinned instances: $($sortedInstances.Count). Configured to keep: $RetentionCountToKeep." -Level "DEBUG"

        if ($sortedInstances.Count -gt $RetentionCountToKeep) {
            $instancesToDelete = $sortedInstances | Select-Object -Skip $RetentionCountToKeep
            & $LocalWriteLog -Message "[INFO] RetentionManager (Facade): Found $($sortedInstances.Count) existing unpinned backup instance(s). Will attempt to delete $($instancesToDelete.Count) older instance(s) to meet retention ($RetentionCountToKeep total target)." -Level "INFO"
            & $LocalWriteLog -Message "RetentionManager (Facade): Calling Remove-OldBackupArchiveInstance..." -Level "DEBUG"

            Remove-OldBackupArchiveInstance -InstancesToDelete $instancesToDelete `
                -EffectiveSendToRecycleBin $effectiveSendToRecycleBin `
                -RetentionConfirmDeleteFromConfig $RetentionConfirmDeleteFromConfig `
                -EffectiveJobConfig $EffectiveJobConfig `
                -IsSimulateMode:$IsSimulateMode `
                -Logger $Logger `
                -PSCmdlet $PSCmdlet
        } else {
            & $LocalWriteLog -Message "   - RetentionManager (Facade): Number of existing unpinned backup instances ($($sortedInstances.Count)) is at or below target old instances to preserve ($numberOfOldInstancesToPreserve). No older instances to delete." -Level "INFO"
        }
    } catch {
        & $LocalWriteLog -Message "[ERROR] RetentionManager (Facade): Error during retention policy for '$ArchiveBaseFileName'. Some old backups might not have been deleted. Error: $($_.Exception.Message). Stack: $($_.ScriptStackTrace)" -Level "ERROR"
        throw # This error will propagate up to Invoke-PoShBackupJob's catch block
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference # Restore original preference
        & $LocalWriteLog -Message "RetentionManager (Facade): Restored ErrorActionPreference to '$oldErrorActionPreference'." -Level "DEBUG"
    }
    & $LocalWriteLog -Message "[INFO] RetentionManager (Facade): Retention policy application finished for job pattern '$ArchiveBaseFileName'." -Level "INFO"
}
#endregion

Export-ModuleMember -Function Invoke-BackupRetentionPolicy, Find-BackupArchiveInstance
