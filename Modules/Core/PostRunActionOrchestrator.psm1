# Modules\Core\PostRunActionOrchestrator.psm1
<#
.SYNOPSIS
    Orchestrates the determination and invocation of post-run system actions
    (e.g., shutdown, restart) for PoSh-Backup.
.DESCRIPTION
    This module centralises the logic for deciding which post-run system state
    action should be performed after PoSh-Backup completes a job or set.
    It considers CLI overrides, set-specific configurations, job-specific
    configurations (for single jobs not in a set with an action), and global
    defaults, in that order of precedence.

    The main exported function, Invoke-PoShBackupPostRunActionHandler, takes the
    overall script status and relevant configuration pieces, determines the
    final action to consider, checks if its trigger conditions are met, and then
    calls Invoke-SystemStateAction from the SystemStateManager module.
    It now avoids unnecessary logging if no post-run action is configured.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.1 # Reduced logging noise when no action is configured.
    DateCreated:    27-May-2025
    LastModified:   27-May-2025
    Purpose:        To centralise post-run system action decision-making and invocation.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Modules\Managers\SystemStateManager.psm1 and Modules\Utils.psm1.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Core\
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\Managers\SystemStateManager.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "PostRunActionOrchestrator.psm1 FATAL: Could not import required dependent modules (Utils.psm1 or SystemStateManager.psm1). Error: $($_.Exception.Message)"
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
        [hashtable]$CliOverrideSettings, # Contains PostRunActionCli, Delay, Force, Trigger

        [Parameter(Mandatory = $false)]
        [hashtable]$SetSpecificPostRunAction,

        [Parameter(Mandatory = $false)]
        [hashtable]$JobSpecificPostRunActionForNonSet,

        [Parameter(Mandatory = $true)]
        [hashtable]$GlobalConfig, # For PostRunActionDefaults

        [Parameter(Mandatory = $true)]
        [bool]$IsSimulateMode,

        [Parameter(Mandatory = $true)]
        [bool]$TestConfigIsPresent, # To adjust effective status for trigger checks

        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance, # For Invoke-SystemStateAction

        [Parameter(Mandatory = $false)]
        [string]$CurrentSetNameForLog, # Optional, for logging context

        [Parameter(Mandatory = $false)]
        [string]$JobNameForLog # Optional, for logging context if single job
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
    $isAnyActionConfigured = $false

    # Determine if any action is configured at any level
    if ($null -ne $CliOverrideSettings.PostRunActionCli -and $CliOverrideSettings.PostRunActionCli.ToLowerInvariant() -ne "none") {
        $isAnyActionConfigured = $true
        $finalPostRunActionToConsider = @{
            Enabled         = $true # CLI override implies enabled if action is not "none"
            Action          = $CliOverrideSettings.PostRunActionCli
            DelaySeconds    = if ($null -ne $CliOverrideSettings.PostRunActionDelaySecondsCli) { $CliOverrideSettings.PostRunActionDelaySecondsCli } else { 0 }
            TriggerOnStatus = if ($null -ne $CliOverrideSettings.PostRunActionTriggerOnStatusCli) { @($CliOverrideSettings.PostRunActionTriggerOnStatusCli) } else { @("ANY") }
            ForceAction     = if ($null -ne $CliOverrideSettings.PostRunActionForceCli) { $CliOverrideSettings.PostRunActionForceCli } else { $false }
        }
        $actionSourceForLog = "CLI Override"
        if ($CurrentSetNameForLog -and -not $JobNameForLog) {
             $actionSourceForLog += " (No jobs run under set '$CurrentSetNameForLog')"
        } elseif (-not $CurrentSetNameForLog -and -not $JobNameForLog) {
             $actionSourceForLog += " (No jobs run)"
        }
    } elseif ($null -ne $SetSpecificPostRunAction -and $SetSpecificPostRunAction.Enabled -eq $true -and $SetSpecificPostRunAction.Action.ToLowerInvariant() -ne "none") {
        $isAnyActionConfigured = $true
        $finalPostRunActionToConsider = $SetSpecificPostRunAction
        $actionSourceForLog = "Backup Set '$CurrentSetNameForLog'"
    } elseif ($null -ne $JobSpecificPostRunActionForNonSet -and $JobSpecificPostRunActionForNonSet.Enabled -eq $true -and $JobSpecificPostRunActionForNonSet.Action.ToLowerInvariant() -ne "none") {
        $isAnyActionConfigured = $true
        $finalPostRunActionToConsider = $JobSpecificPostRunActionForNonSet
        $actionSourceForLog = "Job '$JobNameForLog'"
    } else {
        $globalDefaultsPRA = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'PostRunActionDefaults' -DefaultValue @{}
        if ($null -ne $globalDefaultsPRA -and $globalDefaultsPRA.ContainsKey('Enabled') -and $globalDefaultsPRA.Enabled -eq $true -and $globalDefaultsPRA.Action.ToLowerInvariant() -ne "none") {
            $isAnyActionConfigured = $true
            $finalPostRunActionToConsider = $globalDefaultsPRA
            $actionSourceForLog = "Global Defaults"
            if ($CurrentSetNameForLog -and -not $JobNameForLog) {
                 $actionSourceForLog += " (No jobs run under set '$CurrentSetNameForLog')"
            } elseif (-not $CurrentSetNameForLog -and -not $JobNameForLog) {
                 $actionSourceForLog += " (No jobs run)"
            }
        }
    }

    if (-not $isAnyActionConfigured) {
        # & $LocalWriteLog -Message "PostRunActionOrchestrator: No active post-run system action configured." -Level "DEBUG"
        return
    }

    # If we reach here, an action was configured. Now log initialization and proceed.
    # This next line will not appear if $isAnyActionConfigured is false due to the return above.    
    & $LocalWriteLog -Message "PostRunActionOrchestrator: Initializing post-run action handling. Overall Status: $OverallStatus" -Level "DEBUG"

    if ($null -ne $finalPostRunActionToConsider) { # This check is now implicitly true if $isAnyActionConfigured is true
        $triggerStatuses = @($finalPostRunActionToConsider.TriggerOnStatus | ForEach-Object { $_.ToUpperInvariant() })
        $effectiveOverallStatusForTrigger = $OverallStatus.ToUpperInvariant()
        if ($TestConfigIsPresent) { $effectiveOverallStatusForTrigger = "SIMULATED_COMPLETE" }

        if ($triggerStatuses -contains "ANY" -or $effectiveOverallStatusForTrigger -in $triggerStatuses) {
            if (-not [string]::IsNullOrWhiteSpace($actionSourceForLog) -and $actionSourceForLog -ne "None") {
                & $LocalWriteLog -Message "[INFO] PostRunActionOrchestrator: Post-Run Action determined. Using settings from: $($actionSourceForLog)." -Level "INFO"
            }
            & $LocalWriteLog -Message "[INFO] PostRunActionOrchestrator: Conditions met for action '$($finalPostRunActionToConsider.Action)' (Triggered by Status: $effectiveOverallStatusForTrigger)." -Level "INFO"

            $systemActionParams = @{
                Action           = $finalPostRunActionToConsider.Action
                DelaySeconds     = $finalPostRunActionToConsider.DelaySeconds
                ForceAction      = $finalPostRunActionToConsider.ForceAction
                IsSimulateMode   = ($IsSimulateMode -or $TestConfigIsPresent)
                Logger           = $Logger
                PSCmdletInstance = $PSCmdletInstance
            }
            Invoke-SystemStateAction @systemActionParams
        } else {
            & $LocalWriteLog -Message "[INFO] PostRunActionOrchestrator: Post-Run Action '$($finalPostRunActionToConsider.Action)' (from $actionSourceForLog) not triggered. Overall status '$effectiveOverallStatusForTrigger' does not match trigger statuses: $($triggerStatuses -join ', ')." -Level "INFO"
        }
    } else {
        # This else block should ideally not be reached if $isAnyActionConfigured was true.
        # Kept for safety, but the logic above should assign $finalPostRunActionToConsider if $isAnyActionConfigured.
        & $LocalWriteLog -Message "[INFO] PostRunActionOrchestrator: No Post-Run Action to perform (logic error or action was 'None' but still considered configured)." -Level "INFO"
    }
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupPostRunActionHandler
