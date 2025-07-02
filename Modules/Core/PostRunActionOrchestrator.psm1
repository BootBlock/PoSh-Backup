# Modules\Core\PostRunActionOrchestrator.psm1
<#
.SYNOPSIS
    Orchestrates the determination and invocation of post-run system actions
    (e.g., shutdown, restart) for PoSh-Backup.
.DESCRIPTION
    This module centralises the logic for deciding which post-run system state
    action should be performed after PoSh-Backup completes a job or set.
    It considers CLI overrides, set-specific configurations, job-specific
    configurations, and global defaults, in that order of precedence.

    It now lazy-loads the SystemStateManager module only when an action is triggered,
    improving startup performance for runs that do not involve post-run actions.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.2.0 # Refactored to lazy-load SystemStateManager.
    DateCreated:    27-May-2025
    LastModified:   02-Jul-2025
    Purpose:        To centralise post-run system action decision-making and invocation.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Core\
try {
    # Utils is needed for Get-ConfigValue
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "PostRunActionOrchestrator.psm1 FATAL: Could not import a required dependent module. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- Exported Function ---
function Invoke-PoShBackupPostRunActionHandler {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OverallStatus,

        [Parameter(Mandatory = $true)]
        [hashtable]$CliOverrideSettings,

        [Parameter(Mandatory = $false)]
        [hashtable]$SetSpecificPostRunAction,

        [Parameter(Mandatory = $false)]
        [hashtable]$JobSpecificPostRunActionForNonSet,

        [Parameter(Mandatory = $true)]
        [hashtable]$GlobalConfig,

        [Parameter(Mandatory = $true)]
        [bool]$IsSimulateMode,

        [Parameter(Mandatory = $true)]
        [bool]$TestConfigIsPresent,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,

        [Parameter(Mandatory = $false)]     # Not mandatory for ResolveOnly mode
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance,

        [Parameter(Mandatory = $false)]
        [string]$CurrentSetNameForLog,

        [Parameter(Mandatory = $false)]
        [string]$JobNameForLog,

        [Parameter(Mandatory = $false)]
        [switch]$ResolveOnly                # If true, just resolve the action and return it.
    )

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    $finalPostRunActionToConsider = $null
    $actionSourceForLog = "None"

    # Determine the final action based on the override hierarchy
    if ($null -ne $CliOverrideSettings.PostRunActionCli -and $CliOverrideSettings.PostRunActionCli.ToLowerInvariant() -ne "none") {
        $finalPostRunActionToConsider = @{
            Enabled         = $true
            Action          = $CliOverrideSettings.PostRunActionCli
            DelaySeconds    = if ($null -ne $CliOverrideSettings.PostRunActionDelaySecondsCli) { $CliOverrideSettings.PostRunActionDelaySecondsCli } else { 0 }
            TriggerOnStatus = if ($null -ne $CliOverrideSettings.PostRunActionTriggerOnStatusCli) { @($CliOverrideSettings.PostRunActionTriggerOnStatusCli) } else { @("ANY") }
            ForceAction     = if ($null -ne $CliOverrideSettings.PostRunActionForceCli) { $CliOverrideSettings.PostRunActionForceCli } else { $false }
        }
        $actionSourceForLog = "CLI Override"
    } elseif ($null -ne $SetSpecificPostRunAction) {
        $finalPostRunActionToConsider = $SetSpecificPostRunAction
        $actionSourceForLog = "Backup Set '$CurrentSetNameForLog'"
    } elseif ($null -ne $JobSpecificPostRunActionForNonSet) {
        $finalPostRunActionToConsider = $JobSpecificPostRunActionForNonSet
        $actionSourceForLog = "Job '$JobNameForLog'"
    } else {
        $finalPostRunActionToConsider = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'PostRunActionDefaults' -DefaultValue @{}
        $actionSourceForLog = "Global Defaults"
    }

    $isActionConfiguredAndEnabled = ($null -ne $finalPostRunActionToConsider) -and `
                                    ($finalPostRunActionToConsider.Enabled -eq $true) -and `
                                    ($finalPostRunActionToConsider.Action.ToLowerInvariant() -ne "none")

    # --- Mode 1: Resolve Only (for -TestConfig) ---
    if ($ResolveOnly.IsPresent) {
        if ($isActionConfiguredAndEnabled) {
            return @{
                Action          = $finalPostRunActionToConsider.Action
                Source          = $actionSourceForLog
                TriggerOnStatus = @($finalPostRunActionToConsider.TriggerOnStatus) -join ", "
                DelaySeconds    = $finalPostRunActionToConsider.DelaySeconds
                ForceAction     = $finalPostRunActionToConsider.ForceAction
            }
        } else {
            return @{ Action = "None"; Source = "No Action Configured/Enabled" }
        }
    }

    # --- Mode 2: Standard Execution ---
    if (-not $isActionConfiguredAndEnabled) {
        return # No active action, so nothing to do.
    }

    & $LocalWriteLog -Message "PostRunActionOrchestrator: Initialising post-run action handling. Overall Status: $OverallStatus" -Level "DEBUG"

    $triggerStatuses = @($finalPostRunActionToConsider.TriggerOnStatus | ForEach-Object { $_.ToUpperInvariant() })
    $effectiveOverallStatusForTrigger = $OverallStatus.ToUpperInvariant()
    if ($TestConfigIsPresent) { $effectiveOverallStatusForTrigger = "SIMULATED_COMPLETE" }

    if ($triggerStatuses -contains "ANY" -or $effectiveOverallStatusForTrigger -in $triggerStatuses) {
        if (-not [string]::IsNullOrWhiteSpace($actionSourceForLog) -and $actionSourceForLog -ne "None") {
            & $LocalWriteLog -Message "[INFO] PostRunActionOrchestrator: Post-Run Action determined. Using settings from: $($actionSourceForLog)." -Level "INFO"
        }
        & $LocalWriteLog -Message "[INFO] PostRunActionOrchestrator: Conditions met for action '$($finalPostRunActionToConsider.Action)' (Triggered by Status: $effectiveOverallStatusForTrigger)." -Level "INFO"

        try {
            Import-Module -Name (Join-Path $PSScriptRoot "..\Managers\SystemStateManager.psm1") -Force -ErrorAction Stop
            $systemActionParams = @{
                Action           = $finalPostRunActionToConsider.Action
                DelaySeconds     = $finalPostRunActionToConsider.DelaySeconds
                ForceAction      = $finalPostRunActionToConsider.ForceAction
                IsSimulateMode   = ($IsSimulateMode -or $TestConfigIsPresent)
                Logger           = $Logger
                PSCmdletInstance = $PSCmdletInstance
            }
            Invoke-SystemStateAction @systemActionParams
        }
        catch {
            $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Managers\SystemStateManager.psm1' exists and is not corrupted."
            & $LocalWriteLog -Message "[ERROR] PostRunActionOrchestrator: Could not load or execute the SystemStateManager. Post-run action will not be performed. Error: $($_.Exception.Message)" -Level "ERROR"
            & $LocalWriteLog -Message $advice -Level "ADVICE"
        }

    } else {
        & $LocalWriteLog -Message "[INFO] PostRunActionOrchestrator: Post-Run Action '$($finalPostRunActionToConsider.Action)' (from $actionSourceForLog) not triggered. Overall status '$effectiveOverallStatusForTrigger' does not match trigger statuses: $($triggerStatuses -join ', ')." -Level "INFO"
    }
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupPostRunActionHandler
