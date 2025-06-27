# Modules\ConfigManagement\ConfigLoader\UserConfigHandler.psm1
<#
.SYNOPSIS
    Sub-module for ConfigLoader. Handles the creation and prompting for User.psd1.
.DESCRIPTION
    This module contains the 'Invoke-UserConfigCreationPromptInternal' function,
    responsible for checking if User.psd1 exists, and if not, prompting the user
    (in interactive console mode) to create it by copying and modifying the
    Default.psd1 content.

    The prompt now includes a configurable timeout for non-interactive (but visible)
    console sessions to prevent the script from hanging indefinitely.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.1 # Corrected non-interactive host detection.
    DateCreated:    29-May-2025
    LastModified:   21-Jun-2025
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
    & $LocalWriteLogInternal -Message "ConfigLoader/UserConfigHandler/Invoke-UserConfigCreationPromptInternal: Initialising." -Level "DEBUG"

    if (-not (Test-Path -LiteralPath $DefaultUserConfigPathInternal -PathType Leaf)) {
        if (Test-Path -LiteralPath $DefaultBaseConfigPathInternal -PathType Leaf) {
            & $LocalWriteLogInternal -Message "[DEBUG] ConfigLoader/UserConfigHandler: User configuration file ('$DefaultUserConfigPathInternal') not found." -Level "DEBUG"

            # Check if we should prompt at all.
            if (($Global:IsQuietMode -eq $true) -or `
                $IsTestConfigModeSwitchInternal -or `
                $IsSimulateModeSwitchInternal -or `
                $ListBackupLocationsSwitchInternal -or `
                $ListBackupSetsSwitchInternal -or `
                $SkipUserConfigCreationSwitchInternal) {
                # In these modes, never prompt. Just inform and continue.
                & $LocalWriteLogInternal -Message "[DEBUG] ConfigLoader/UserConfigHandler: Not prompting to create '$DefaultUserConfigFileNameInternal' (Quiet, TestConfig, Simulate, or List mode)." -Level "DEBUG"
                & $LocalWriteLogInternal -Message "       If you wish to have user-specific overrides, please manually copy '$DefaultBaseConfigPathInternal' to '$DefaultUserConfigPathInternal' and edit it." -Level "DEBUG"
                return
            }

            # If we are in a state to prompt, determine the timeout.
            $timeoutSeconds = 30 # Safe default
            try {
                $defaultConfigContent = Get-Content -LiteralPath $DefaultBaseConfigPathInternal -Raw -ErrorAction Stop
                if ($defaultConfigContent -match '(?im)^\s*UserPromptTimeoutSeconds\s*=\s*(\d+)') {
                    $timeoutSeconds = [int]$Matches[1]
                }
            } catch {
                & $LocalWriteLogInternal -Message "[WARNING] Could not pre-read UserPromptTimeoutSeconds from Default.psd1. Using default of $timeoutSeconds seconds. Error: $($_.Exception.Message)" -Level "WARNING"
            }

            $decision = 1 # Default to 'No'

            # Use `$Host.UI.RawUI` to reliably detect if the host can handle key presses.
            if ($null -ne $Host.UI.RawUI) {
                # This is an interactive session.
                $choiceMessage = "The user-specific configuration file '$($DefaultUserConfigFileNameInternal)' was not found in '$($DefaultConfigDirInternal)'.`nIt is recommended to create this file as it allows you to customise settings without modifying`nthe default file, ensuring your settings are not overwritten by script upgrades.`n`nWould you like to create '$($DefaultUserConfigFileNameInternal)' now by copying the contents of '$($DefaultBaseConfigFileNameInternal)'?"
                Write-Host "`n$choiceMessage" -ForegroundColor 'Yellow'
                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $userInput = $null
                while ($true) { # Loop indefinitely until a valid key is pressed or timeout occurs
                    Write-Host -NoNewline "`rCreate 'User.psd1'? " -ForegroundColor 'White'
                    Write-Host -NoNewline "[" -ForegroundColor 'White'
                    Write-Host -NoNewline "Y" -ForegroundColor 'Green'
                    Write-Host -NoNewline "]es / [" -ForegroundColor 'White'
                    Write-Host -NoNewline "N" -ForegroundColor 'Yellow'
                    Write-Host -NoNewline "]o" -ForegroundColor 'White'

                    if ($timeoutSeconds -gt 0) {
                        $remaining = [math]::Ceiling($timeoutSeconds - $stopwatch.Elapsed.TotalSeconds)
                        if ($remaining -le 0) {
                            $decision = 1; Write-Host "`nTimed out. Defaulting to 'No'." -ForegroundColor 'Yellow'; break;
                        }
                        Write-Host -NoNewline " (Default is '" -ForegroundColor 'White'
                        Write-Host -NoNewline "N" -ForegroundColor 'Yellow'
                        Write-Host -NoNewline "' in $remaining seconds): " -ForegroundColor 'White'
                    } else {
                        Write-Host -NoNewline ": " -ForegroundColor 'White'
                    }

                    if ($Host.UI.RawUI.KeyAvailable) {
                        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
                        $userInput = $key.Character
                        if ($userInput -eq 'y') { $decision = 0; Write-Host; break }
                        if ($userInput -eq 'n') { $decision = 1; Write-Host; break }
                    }
                    Start-Sleep -Milliseconds 100
                }
                $stopwatch.Stop()
            } else {
                # Non-interactive session, default to 'No' without prompting to prevent hanging.
                & $LocalWriteLogInternal -Message "[INFO] ConfigLoader/UserConfigHandler: Non-interactive host detected (RawUI not available). Defaulting to 'No' for User.psd1 creation." -Level "INFO"
                $decision = 1
            }

            if ($decision -eq 0) { # User chose 'Yes'
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
                       if ($null -ne $Host.UI.RawUI) {
                           Write-Host "Press any key to exit..." -ForegroundColor 'DarkGray'
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
            } else { # User chose 'No' or timed out
                & $LocalWriteLogInternal -Message "[DEBUG] ConfigLoader/UserConfigHandler: User chose not to create a user config. Using defaults from '$DefaultBaseConfigFileNameInternal'." -Level "DEBUG"
            }
        } else {
            & $LocalWriteLogInternal -Message "[WARNING] ConfigLoader/UserConfigHandler: Base configuration file ('$DefaultBaseConfigPathInternal') also not found. Cannot offer to create '$DefaultUserConfigPathInternal'." -Level "WARNING"
        }
    }
}
#endregion

Export-ModuleMember -Function Invoke-UserConfigCreationPromptInternal
