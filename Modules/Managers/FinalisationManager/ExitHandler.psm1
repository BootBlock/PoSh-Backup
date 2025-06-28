# Modules\Managers\FinalisationManager\ExitHandler.psm1
<#
.SYNOPSIS
    A sub-module for FinalisationManager. Handles the script's pause and exit logic.
.DESCRIPTION
    This module provides the 'Invoke-PoShBackupExit' function. It is responsible for
    determining if the script should pause before exiting based on the final status and
    configuration ("Always", "Never", "OnFailure", etc.). It then terminates the script
    with the appropriate exit code corresponding to the overall status of the run.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    27-Jun-2025
    LastModified:   27-Jun-2025
    Purpose:        To isolate the pause and exit logic.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers\FinalisationManager
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "ExitHandler.psm1 FATAL: Could not import Utils.psm1. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Invoke-PoShBackupExit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$EffectiveOverallStatus,
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,
        [Parameter(Mandatory = $true)]
        [hashtable]$CliOverrideSettings,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [switch]$TestConfigIsPresent,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "" -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    # --- Pause Behaviour ---
    $_pauseDefaultFromScript = "OnFailureOrWarning"
    $_pauseSettingFromConfig = Get-ConfigValue -ConfigObject $Configuration -Key 'PauseBeforeExit' -DefaultValue $_pauseDefaultFromScript
    
    $normalizedPauseConfigValue = ""
    if ($_pauseSettingFromConfig -is [bool]) {
        $normalizedPauseConfigValue = if ($_pauseSettingFromConfig) { "always" } else { "never" }
    }
    elseif ($null -ne $_pauseSettingFromConfig -and $_pauseSettingFromConfig -is [string]) {
        $normalizedPauseConfigValue = $_pauseSettingFromConfig.ToLowerInvariant()
    }
    else {
        $normalizedPauseConfigValue = $_pauseDefaultFromScript.ToLowerInvariant()
    }

    $effectivePauseBehaviour = $normalizedPauseConfigValue
    if ($null -ne $CliOverrideSettings.PauseBehaviour) {
        $effectivePauseBehaviour = $CliOverrideSettings.PauseBehaviour.ToLowerInvariant()
        if ($effectivePauseBehaviour -eq "true") { $effectivePauseBehaviour = "always" }
        if ($effectivePauseBehaviour -eq "false") { $effectivePauseBehaviour = "never" }
        & $LocalWriteLog -Message "[INFO] ExitHandler: Pause behaviour explicitly set by CLI to: '$($CliOverrideSettings.PauseBehaviour)' (effective: '$effectivePauseBehaviour')." -Level "INFO"
    }

    $shouldPhysicallyPause = $false
    switch ($effectivePauseBehaviour) {
        "always"             { $shouldPhysicallyPause = $true }
        "never"              { $shouldPhysicallyPause = $false }
        "onfailure"          { if ($EffectiveOverallStatus -eq "FAILURE") { $shouldPhysicallyPause = $true } }
        "onwarning"          { if ($EffectiveOverallStatus -eq "WARNINGS") { $shouldPhysicallyPause = $true } }
        "onfailureorwarning" { if ($EffectiveOverallStatus -in @("FAILURE", "WARNINGS")) { $shouldPhysicallyPause = $true } }
        default {
            & $LocalWriteLog -Message "[WARNING] ExitHandler: Unknown PauseBeforeExit value '$effectivePauseBehaviour' was resolved. Defaulting to not pausing." -Level "WARNING"
            $shouldPhysicallyPause = $false
        }
    }
    if (($IsSimulateMode.IsPresent -or $TestConfigIsPresent.IsPresent) -and $effectivePauseBehaviour -ne "always") {
        $shouldPhysicallyPause = $false
    }

    if ($shouldPhysicallyPause) {
        & $LocalWriteLog -Message "`nPress any key to exit..." -Level "WARNING"
        if ($Host.Name -eq "ConsoleHost") {
            try { $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') | Out-Null }
            catch { & $LocalWriteLog -Message "[DEBUG] ExitHandler: Error during ReadKey: $($_.Exception.Message)" -Level "DEBUG" }
        }
        else {
            & $LocalWriteLog -Message "  (Pause configured for '$effectivePauseBehaviour' and current status '$EffectiveOverallStatus', but not running in ConsoleHost: $($Host.Name).)" -Level "INFO"
        }
    }

    # --- Exit Script ---
    $exitCode = $Global:PoShBackup_ExitCodes.OperationalFailure # Default to general failure

    switch ($EffectiveOverallStatus) {
        "SUCCESS"            { $exitCode = $Global:PoShBackup_ExitCodes.Success }
        "SIMULATED_COMPLETE" { $exitCode = $Global:PoShBackup_ExitCodes.Success }
        "WARNINGS"           { $exitCode = $Global:PoShBackup_ExitCodes.SuccessWithWarnings }
        "FAILURE"            { $exitCode = $Global:PoShBackup_ExitCodes.OperationalFailure }
    }

    exit $exitCode
}

Export-ModuleMember -Function Invoke-PoShBackupExit
