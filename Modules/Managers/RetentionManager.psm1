# Modules\Managers\RetentionManager.psm1
<#
.SYNOPSIS
    Manages backup archive retention policies for PoSh-Backup. This module now acts as a facade,
    delegating scanning and deletion tasks to sub-modules which are loaded on demand.
.DESCRIPTION
    The RetentionManager module centralises the logic for applying retention policies.
    It uses sub-modules for specific tasks:
    - 'Scanner.psm1': Finds and groups backup archive instances, and identifies pinned backups.
    - 'Deleter.psm1': Handles the actual deletion of identified instances.

    The main function, Invoke-BackupRetentionPolicy, orchestrates these steps, ensuring that
    any backups marked as 'pinned' are excluded from the retention policy and are not deleted.
    Sub-modules are now lazy-loaded to improve performance.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.5.0 # Refactored to lazy-load sub-modules.
    DateCreated:    17-May-2025
    LastModified:   02-Jul-2025
    Purpose:        Facade for centralised backup retention policy management.
    Prerequisites:  PowerShell 5.1+.
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
        $warningMessage = "RetentionManager (Facade): 'DeleteToRecycleBin' is enabled for a network destination ('$DestinationDirectory'). This can be unreliable."
        $adviceMessage = "ADVICE: It is recommended to set 'DeleteToRecycleBin = `$false' for jobs writing to network shares to ensure permanent and predictable deletion."
        & $LocalWriteLog -Message $warningMessage -Level "WARNING"
        & $LocalWriteLog -Message $adviceMessage -Level "ADVICE"
    }
    & $LocalWriteLog -Message "   - Effective Deletion Method for old archives: $(if ($effectiveSendToRecycleBin) {'Send to Recycle Bin'} else {'Permanent Delete'})"

    $oldErrorActionPreference = $ErrorActionPreference # Store original preference
    try {
        $ErrorActionPreference = 'Stop' # Force errors within this try block to be terminating
        & $LocalWriteLog -Message "RetentionManager (Facade): Temporarily set ErrorActionPreference to 'Stop'." -Level "DEBUG"

        $backupInstances = try {
            Import-Module -Name (Join-Path $PSScriptRoot "RetentionManager\Scanner.psm1") -Force -ErrorAction Stop
            & $LocalWriteLog -Message "RetentionManager (Facade): Calling Find-BackupArchiveInstance..." -Level "DEBUG"
            Find-BackupArchiveInstance -DestinationDirectory $DestinationDirectory `
                                       -ArchiveBaseFileName $ArchiveBaseFileName `
                                       -ArchiveExtension $ArchiveExtension `
                                       -ArchiveDateFormat $ArchiveDateFormat `
                                       -Logger $Logger
        } catch {
            $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Managers\RetentionManager\Scanner.psm1' exists and is not corrupted."
            & $LocalWriteLog -Message "[FATAL] RetentionManager: Could not load or execute the Scanner module. Retention cannot proceed. Error: $($_.Exception.Message)" -Level "ERROR"
            & $LocalWriteLog -Message $advice -Level "ADVICE"
            throw
        }

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
        if ($unpinnedInstances.Count -gt 0) {
            $sortedInstances = $unpinnedInstances.GetEnumerator() | Sort-Object {$_.Value.SortTime} -Descending
            & $LocalWriteLog -Message "RetentionManager (Facade): Successfully sorted instances. Count: $($sortedInstances.Count)." -Level "DEBUG"
        } else {
            $sortedInstances = @()
            & $LocalWriteLog -Message "RetentionManager (Facade): No unpinned instances to sort." -Level "DEBUG"
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

            try {
                Import-Module -Name (Join-Path $PSScriptRoot "RetentionManager\Deleter.psm1") -Force -ErrorAction Stop
                Remove-OldBackupArchiveInstance -InstancesToDelete $instancesToDelete `
                    -EffectiveSendToRecycleBin $effectiveSendToRecycleBin `
                    -RetentionConfirmDeleteFromConfig $RetentionConfirmDeleteFromConfig `
                    -EffectiveJobConfig $EffectiveJobConfig `
                    -IsSimulateMode:$IsSimulateMode `
                    -Logger $Logger `
                    -PSCmdlet $PSCmdlet
            }
            catch {
                $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Managers\RetentionManager\Deleter.psm1' exists and is not corrupted."
                & $LocalWriteLog -Message "[FATAL] RetentionManager: Could not load or execute the Deleter module. Retention cannot proceed. Error: $($_.Exception.Message)" -Level "ERROR"
                & $LocalWriteLog -Message $advice -Level "ADVICE"
                throw
            }

        } else {
            & $LocalWriteLog -Message "   - RetentionManager (Facade): Number of existing unpinned backup instances ($($sortedInstances.Count)) is at or below target old instances to preserve ($($RetentionCountToKeep)). No older instances to delete." -Level "INFO"
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
