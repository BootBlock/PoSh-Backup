# Modules\Managers\FinalisationManager.psm1
<#
.SYNOPSIS
    Manages the finalisation tasks for the PoSh-Backup script, including summary display,
    post-run action invocation (via PostRunActionOrchestrator), pause behaviour, and exit code.
.DESCRIPTION
    This module provides a function to handle all tasks that occur after the main backup
    operations (jobs/sets) have completed. This includes:
    - Displaying a completion banner.
    - Logging final script statistics (status, duration).
    - Orchestrating post-run system actions by calling the PostRunActionOrchestrator.
    - Managing the configured pause behaviour before the script exits.
    - Terminating the script with an appropriate exit code based on the overall status.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    01-Jun-2025
    LastModified:   01-Jun-2025
    Purpose:        To centralise script finalisation, summary, and exit logic.
    Prerequisites:  PowerShell 5.1+.
                    Requires Modules\Utilities\ConsoleDisplayUtils.psm1 and
                    Modules\Core\PostRunActionOrchestrator.psm1 to be available.
                    Relies on global colour variables being set.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers
try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "..\Utilities\ConsoleDisplayUtils.psm1") -Force -ErrorAction Stop
    # PostRunActionOrchestrator.psm1 is imported by PoSh-Backup.ps1 and its function is passed if needed,
    # or this module could import it if it directly calls it.
    # For now, assuming PoSh-Backup.ps1 passes the necessary function reference or handles the call.
    # If Invoke-PoShBackupPostRunActionHandler is to be called from here, we need to import it.
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "..\Core\PostRunActionOrchestrator.psm1") -Force -ErrorAction Stop

}
catch {
    Write-Warning "FinalisationManager.psm1: Could not import one or more dependent modules. Some functionality might be affected. Error: $($_.Exception.Message)"
}
#endregion

function Invoke-PoShBackupFinalisation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OverallSetStatus,
        [Parameter(Mandatory = $true)]
        [datetime]$ScriptStartTime,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [switch]$TestConfigIsPresent, # To adjust effective status for trigger checks
        [Parameter(Mandatory = $true)]
        [hashtable]$CliOverrideSettings,
        [Parameter(Mandatory = $false)]
        [hashtable]$SetSpecificPostRunAction,
        [Parameter(Mandatory = $false)]
        [hashtable]$JobSpecificPostRunActionForNonSetRun,
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration, # For PauseBeforeExit and PostRunActionDefaults
        [Parameter(Mandatory = $true)]
        [scriptblock]$LoggerScriptBlock,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance,
        [Parameter(Mandatory = $false)]
        [string]$CurrentSetNameForLog,
        [Parameter(Mandatory = $false)]
        [string]$JobNameForLog, # For single job run context in PostRunActionOrchestrator
        [Parameter(Mandatory = $true)]
        [int]$JobsToProcessCount # To determine if any jobs actually ran for PostRunAction context
    )

    $finalScriptEndTime = Get-Date
    $effectiveOverallStatus = $OverallSetStatus

    # --- Completion Banner ---
    if (Get-Command Write-ConsoleBanner -ErrorAction SilentlyContinue) {
        $completionBorderColor = '$Global:ColourHeading'
        $completionNameFgColor = '$Global:ColourSuccess'
        if ($effectiveOverallStatus -eq "FAILURE") { $completionBorderColor = '$Global:ColourError'; $completionNameFgColor = '$Global:ColourError' }
        elseif ($effectiveOverallStatus -eq "WARNINGS") { $completionBorderColor = '$Global:ColourWarning'; $completionNameFgColor = '$Global:ColourWarning' }
        elseif ($IsSimulateMode.IsPresent -and $effectiveOverallStatus -ne "FAILURE" -and $effectiveOverallStatus -ne "WARNINGS") {
            # If simulating and no errors/warnings, banner should reflect simulation success
            $completionBorderColor = '$Global:ColourSimulate'; $completionNameFgColor = '$Global:ColourSimulate'
        }
        Write-ConsoleBanner -NameText "All PoSh Backup Operations Completed" `
                            -NameForegroundColor $completionNameFgColor `
                            -BannerWidth 78 `
                            -BorderForegroundColor $completionBorderColor `
                            -CenterText `
                            -PrependNewLine
    } else {
        & $LoggerScriptBlock -Message "--- All PoSh Backup Operations Completed ---" -Level "HEADING"
    }

    if ($IsSimulateMode.IsPresent -and $effectiveOverallStatus -ne "FAILURE" -and $effectiveOverallStatus -ne "WARNINGS") {
        $effectiveOverallStatus = "SIMULATED_COMPLETE"
    }

    & $LoggerScriptBlock -Message "Overall Script Status: $effectiveOverallStatus" -Level $effectiveOverallStatus
    & $LoggerScriptBlock -Message "Script started : $ScriptStartTime" -Level "INFO"
    & $LoggerScriptBlock -Message "Script ended   : $finalScriptEndTime" -Level "INFO"
    & $LoggerScriptBlock -Message "Total duration : $($finalScriptEndTime - $ScriptStartTime)" -Level "INFO"

    # --- Post-Run Action Handling ---
    if (Get-Command Invoke-PoShBackupPostRunActionHandler -ErrorAction SilentlyContinue) {
        $postRunParams = @{
            OverallStatus                     = $effectiveOverallStatus
            CliOverrideSettings               = $CliOverrideSettings
            SetSpecificPostRunAction          = $SetSpecificPostRunAction
            JobSpecificPostRunActionForNonSet = $JobSpecificPostRunActionForNonSetRun
            GlobalConfig                      = $Configuration
            IsSimulateMode                    = $IsSimulateMode.IsPresent
            TestConfigIsPresent               = $TestConfigIsPresent.IsPresent
            Logger                            = $LoggerScriptBlock
            PSCmdletInstance                  = $PSCmdletInstance
            CurrentSetNameForLog              = $CurrentSetNameForLog
            JobNameForLog                     = if ($JobsToProcessCount -eq 1 -and (-not $CurrentSetNameForLog)) { $JobNameForLog } else { $null }
        }
        Invoke-PoShBackupPostRunActionHandler @postRunParams
    } else {
        & $LoggerScriptBlock -Message "[WARNING] FinalisationManager: Invoke-PoShBackupPostRunActionHandler command not found. Post-run actions will be skipped." -Level "WARNING"
    }

    # --- Pause Behaviour ---
    $_pauseDefaultFromScript = "OnFailureOrWarning"
    $_pauseSettingFromConfig = if ($Configuration.ContainsKey('PauseBeforeExit')) { $Configuration.PauseBeforeExit } else { $_pauseDefaultFromScript }
    $normalizedPauseConfigValue = ""
    if ($_pauseSettingFromConfig -is [bool]) {
        $normalizedPauseConfigValue = if ($_pauseSettingFromConfig) { "always" } else { "never" }
    } elseif ($null -ne $_pauseSettingFromConfig -and $_pauseSettingFromConfig -is [string]) {
        $normalizedPauseConfigValue = $_pauseSettingFromConfig.ToLowerInvariant()
    } else {
        $normalizedPauseConfigValue = $_pauseDefaultFromScript.ToLowerInvariant()
    }
    $effectivePauseBehaviour = $normalizedPauseConfigValue
    if ($null -ne $CliOverrideSettings.PauseBehaviour) {
        $effectivePauseBehaviour = $CliOverrideSettings.PauseBehaviour.ToLowerInvariant()
        if ($effectivePauseBehaviour -eq "true") { $effectivePauseBehaviour = "always" }
        if ($effectivePauseBehaviour -eq "false") { $effectivePauseBehaviour = "never" }
        & $LoggerScriptBlock -Message "[INFO] Pause behaviour explicitly set by CLI to: '$($CliOverrideSettings.PauseBehaviour)' (effective: '$effectivePauseBehaviour')." -Level "INFO"
    }

    $shouldPhysicallyPause = $false
    switch ($effectivePauseBehaviour) {
        "always"             { $shouldPhysicallyPause = $true }
        "never"              { $shouldPhysicallyPause = $false }
        "onfailure"          { if ($effectiveOverallStatus -eq "FAILURE") { $shouldPhysicallyPause = $true } }
        "onwarning"          { if ($effectiveOverallStatus -eq "WARNINGS") { $shouldPhysicallyPause = $true } }
        "onfailureorwarning" { if ($effectiveOverallStatus -in @("FAILURE", "WARNINGS")) { $shouldPhysicallyPause = $true } }
        default {
            & $LoggerScriptBlock -Message "[WARNING] Unknown PauseBeforeExit value '$effectivePauseBehaviour' was resolved. Defaulting to not pausing." -Level "WARNING"
            $shouldPhysicallyPause = $false
        }
    }
    if (($IsSimulateMode.IsPresent -or $TestConfigIsPresent.IsPresent) -and $effectivePauseBehaviour -ne "always") {
        $shouldPhysicallyPause = $false
    }

    if ($shouldPhysicallyPause) {
        & $LoggerScriptBlock -Message "`nPress any key to exit..." -Level "WARNING"
        if ($Host.Name -eq "ConsoleHost") {
            try { $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') | Out-Null }
            catch { & $LoggerScriptBlock -Message "[DEBUG] FinalisationManager: Error during ReadKey: $($_.Exception.Message)" -Level "DEBUG" }
        } else {
            & $LoggerScriptBlock -Message "  (Pause configured for '$effectivePauseBehaviour' and current status '$effectiveOverallStatus', but not running in ConsoleHost: $($Host.Name).)" -Level "INFO"
        }
    }

    # --- Exit Script ---
    if ($effectiveOverallStatus -in @("SUCCESS", "SIMULATED_COMPLETE")) { exit 0 }
    elseif ($effectiveOverallStatus -eq "WARNINGS") { exit 1 }
    else { exit 2 }
}

Export-ModuleMember -Function Invoke-PoShBackupFinalisation
