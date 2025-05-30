# Modules\ConfigManagement\ConfigLoader\UserConfigHandler.psm1
<#
.SYNOPSIS
    Sub-module for ConfigLoader. Handles the creation and prompting for User.psd1.
.DESCRIPTION
    This module contains the 'Invoke-UserConfigCreationPromptInternal' function,
    responsible for checking if User.psd1 exists, and if not, prompting the user
    (in interactive console mode) to create it by copying and modifying the
    Default.psd1 content.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    29-May-2025
    LastModified:   29-May-2025
    Purpose:        User.psd1 creation and interaction logic for ConfigLoader.
    Prerequisites:  PowerShell 5.1+.
                    Relies on Utils.psm1 (specifically Get-ScriptVersionFromContent).
#>

# Explicitly import Utils.psm1 from the main Modules directory.
# $PSScriptRoot here is Modules\ConfigManagement\ConfigLoader.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "UserConfigHandler.psm1 (ConfigLoader submodule) FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}

#region --- User.psd1 Creation Prompt Function (Internal to ConfigLoader context) ---
# PSScriptAnalyzer Suppress PSUseApprovedVerbs[Invoke-UserConfigCreationPromptInternal] - Internal helper, 'Invoke' reflects orchestration.
function Invoke-UserConfigCreationPromptInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DefaultUserConfigPathInternal,
        [Parameter(Mandatory = $true)]
        [string]$DefaultBaseConfigPathInternal,
        [Parameter(Mandatory = $true)]
        [string]$DefaultConfigDirInternal,
        [Parameter(Mandatory = $true)]
        [string]$DefaultUserConfigFileNameInternal,
        [Parameter(Mandatory = $true)]
        [string]$DefaultBaseConfigFileNameInternal,
        [Parameter(Mandatory = $true)]
        [bool]$SkipUserConfigCreationSwitchInternal,
        [Parameter(Mandatory = $true)]
        [bool]$IsTestConfigModeSwitchInternal,
        [Parameter(Mandatory = $true)]
        [bool]$IsSimulateModeSwitchInternal,
        [Parameter(Mandatory = $true)]
        [bool]$ListBackupLocationsSwitchInternal,
        [Parameter(Mandatory = $true)]
        [bool]$ListBackupSetsSwitchInternal,
        [Parameter(Mandatory = $true)]
        [scriptblock]$LoggerInternal,
        [Parameter(Mandatory = $true)]
        [hashtable]$CliOverrideSettingsInternal
    )

    & $LoggerInternal -Message "ConfigLoader/UserConfigHandler/Invoke-UserConfigCreationPromptInternal: Logger parameter received." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLogInternal = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $LoggerInternal -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $LoggerInternal -Message $Message -Level $Level
        }
    }
    & $LocalWriteLogInternal -Message "ConfigLoader/UserConfigHandler/Invoke-UserConfigCreationPromptInternal: Initializing." -Level "DEBUG"

    if (-not (Test-Path -LiteralPath $DefaultUserConfigPathInternal -PathType Leaf)) {
        if (Test-Path -LiteralPath $DefaultBaseConfigPathInternal -PathType Leaf) {
            & $LocalWriteLogInternal -Message "[INFO] ConfigLoader/UserConfigHandler: User configuration file ('$DefaultUserConfigPathInternal') not found." -Level "INFO"
            if ($Host.Name -eq "ConsoleHost" -and `
                -not $IsTestConfigModeSwitchInternal -and `
                -not $IsSimulateModeSwitchInternal -and `
                -not $ListBackupLocationsSwitchInternal -and `
                -not $ListBackupSetsSwitchInternal -and `
                -not $SkipUserConfigCreationSwitchInternal) {
                $choiceTitle = "Create User Configuration?"
                $choiceMessage = "The user-specific configuration file '$($DefaultUserConfigFileNameInternal)' was not found in '$($DefaultConfigDirInternal)'.`nIt is recommended to create this file as it allows you to customise settings without modifying`nthe default file, ensuring your settings are not overwritten by script upgrades.`n`nWould you like to create '$($DefaultUserConfigFileNameInternal)' now by copying the contents of '$($DefaultBaseConfigFileNameInternal)'?"
                $yes = New-Object System.Management.Automation.Host.ChoiceDescription "&Yes", "Create '$($DefaultUserConfigFileNameInternal)' from '$($DefaultBaseConfigFileNameInternal)'."
                $no = New-Object System.Management.Automation.Host.ChoiceDescription "&No", "Do not create the file. The script will use '$($DefaultBaseConfigFileNameInternal)' only for this run."
                $options = [System.Management.Automation.Host.ChoiceDescription[]]($yes, $no)
                $decision = $Host.UI.PromptForChoice($choiceTitle, $choiceMessage, $options, 0)
                if ($decision -eq 0) {
                    try {
                        $defaultContent = Get-Content -LiteralPath $DefaultBaseConfigPathInternal -Raw -ErrorAction Stop
                        $defaultVersion = Get-ScriptVersionFromContent -ScriptContent $defaultContent -ScriptNameForWarning $DefaultBaseConfigFileNameInternal
                        if ($defaultVersion -eq "N/A" -or $defaultVersion -like "N/A (*") { $defaultVersion = "Unknown Version" }

                        $userNotice = @"
# --- USER CONFIGURATION FILE ---
# This is your personal PoSh-Backup configuration file ('$DefaultUserConfigFileNameInternal').
#
# How it works:
#     1. PoSh-Backup first loads '$DefaultBaseConfigFileNameInternal' (in '$DefaultConfigDirInternal') to get all base settings.
#     2. It then loads this file ('$DefaultUserConfigFileNameInternal').
#     3. Any settings you define in THIS file will OVERLAY and REPLACE the
#        corresponding settings from '$DefaultBaseConfigFileNameInternal'.
#     4. If a setting is NOT defined in this file, the value from '$DefaultBaseConfigFileNameInternal'
#        will be used automatically.
#
# Recommendation:
#     - Only include settings in this file that you want to *change* from their
#       default values in '$DefaultBaseConfigFileNameInternal'.
#     - You can safely remove any settings from this file that you want to revert
#       to their default behaviour.
#     - Refer to '$DefaultBaseConfigFileNameInternal' for a full list of available settings and
#       their detailed explanations.
#
# Copied from '$DefaultBaseConfigFileNameInternal' (Version: $defaultVersion)
# -----------------------------

"@
                        $userHeader = @"
# Config\\$DefaultUserConfigFileNameInternal
# PowerShell Data File for PoSh Backup Script Configuration (User).
# This is your user-specific configuration file. Settings defined here will OVERLAY
# (i.e., take precedence over) any corresponding settings in '$DefaultBaseConfigFileNameInternal'.
# If a setting is not present in this file, the value from '$DefaultBaseConfigFileNameInternal' will be used.
# It is recommended to only include settings here that you wish to change from their defaults.
#
# Copied from $DefaultBaseConfigFileNameInternal Version $defaultVersion
"@
                        $lines = $defaultContent -split '(\r?\n)'
                        $headerEndLineIndex = -1
                        for ($i = 0; $i -lt $lines.Count; $i++) {
                            if ($lines[$i] -match "^\s*#\s*Version\s*:?\s*([0-9]+\.[0-9]+)") {
                                $headerEndLineIndex = $i
                                break
                            }
                        }
                        
                        $contentWithoutOriginalHeader = ""
                        if ($headerEndLineIndex -ne -1 -and ($headerEndLineIndex + 1) -lt $lines.Count) {
                            $contentWithoutOriginalHeader = ($lines[($headerEndLineIndex + 1)..$($lines.Count -1)]) -join ""
                        } else {
                            if ($lines[0].TrimStart().StartsWith("# Config\Default.psd1")) {
                                $estimatedHeaderLines = 5 
                                if ($lines.Count -gt $estimatedHeaderLines) {
                                     $contentWithoutOriginalHeader = ($lines[$estimatedHeaderLines..($lines.Count -1)]) -join ""
                                } else {
                                    $contentWithoutOriginalHeader = $defaultContent 
                                }
                            } else {
                                 $contentWithoutOriginalHeader = $defaultContent 
                            }
                        }
                        
                        $finalUserContent = $userNotice + $userHeader + "`r`n" + $contentWithoutOriginalHeader.TrimStart()
                        Set-Content -Path $DefaultUserConfigPathInternal -Value $finalUserContent -Encoding UTF8 -Force -ErrorAction Stop
                        
                        & $LocalWriteLogInternal -Message "[SUCCESS] ConfigLoader/UserConfigHandler: '$DefaultUserConfigFileNameInternal' has been created with tailored content in '$DefaultConfigDirInternal'." -Level "SUCCESS"
                        & $LocalWriteLogInternal -Message "          Please edit '$DefaultUserConfigFileNameInternal' with your desired settings and then re-run PoSh-Backup." -Level "INFO"
                        & $LocalWriteLogInternal -Message "          Script will now exit." -Level "INFO"

                        $_pauseBehaviorFromCliForExit = if ($CliOverrideSettingsInternal.PauseBehaviour) { $CliOverrideSettingsInternal.PauseBehaviour } else { "Always" }
                        if ($_pauseBehaviorFromCliForExit -is [string] -and $_pauseBehaviorFromCliForExit.ToLowerInvariant() -ne "never" -and ($_pauseBehaviorFromCliForExit -isnot [bool] -or $_pauseBehaviorFromCliForExit -ne $false)) {
                           if ($Host.Name -eq "ConsoleHost") {
                               try { $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') | Out-Null }
                               catch {
                                   & $LocalWriteLogInternal -Message "ConfigLoader/UserConfigHandler: Non-critical error during ReadKey for exit pause. Error: $($_.Exception.Message)" -Level "DEBUG"
                               }
                           }
                        }
                        exit 0 
                    } catch {
                        & $LocalWriteLogInternal -Message "[ERROR] ConfigLoader/UserConfigHandler: Failed to create '$DefaultUserConfigFileNameInternal' from '$DefaultBaseConfigFileNameInternal'. Error: $($_.Exception.Message)" -Level "ERROR"
                        & $LocalWriteLogInternal -Message "          Please create '$DefaultUserConfigFileNameInternal' manually if desired. Script will continue with base configuration." -Level "WARNING"
                    }
                } else {
                    & $LocalWriteLogInternal -Message "[INFO] ConfigLoader/UserConfigHandler: User chose not to create '$DefaultUserConfigFileNameInternal'. '$DefaultBaseConfigFileNameInternal' will be used for this run." -Level "INFO"
                }
            } else {
                 if ($SkipUserConfigCreationSwitchInternal) {
                     & $LocalWriteLogInternal -Message "[INFO] ConfigLoader/UserConfigHandler: Skipping User.psd1 creation prompt as -SkipUserConfigCreation was specified. '$DefaultBaseConfigFileNameInternal' will be used if '$DefaultUserConfigFileNameInternal' is not found." -Level "INFO"
                 } elseif ($Host.Name -ne "ConsoleHost" -or $IsTestConfigModeSwitchInternal -or $IsSimulateModeSwitchInternal -or $ListBackupLocationsSwitchInternal -or $ListBackupSetsSwitchInternal) {
                     & $LocalWriteLogInternal -Message "[INFO] ConfigLoader/UserConfigHandler: Not prompting to create '$DefaultUserConfigFileNameInternal' (Non-interactive, TestConfig, Simulate, or List mode)." -Level "INFO"
                 }
                 & $LocalWriteLogInternal -Message "       If you wish to have user-specific overrides, please manually copy '$DefaultBaseConfigPathInternal' to '$DefaultUserConfigPathInternal' and edit it." -Level "INFO"
            }
        } else {
            & $LocalWriteLogInternal -Message "[WARNING] ConfigLoader/UserConfigHandler: Base configuration file ('$DefaultBaseConfigPathInternal') also not found. Cannot offer to create '$DefaultUserConfigPathInternal'." -Level "WARNING"
        }
    }
}
#endregion

Export-ModuleMember -Function Invoke-UserConfigCreationPromptInternal
