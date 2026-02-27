# Modules\Managers\InitialisationManager.psm1
<#
.SYNOPSIS
    Manages the initial setup of global variables and console display for PoSh-Backup.
.DESCRIPTION
    This module provides a function to initialise global settings such as colour
    palettes, status maps, default logging variables, and standardised exit codes.
    It also displays the initial script banner (with version and commit hash),
    but respects the -Quiet flag to suppress it. This centralises the startup
    configuration and presentation logic.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.2.0 # Updated banner to display commit hash from Meta\Version.psd1.
    DateCreated:    01-Jun-2025
    LastModified:   25-Jun-2025
    Purpose:        To centralise initial script setup and banner display.
    Prerequisites:  PowerShell 5.1+.
                    Requires Modules\Utilities\ConsoleDisplayUtils.psm1 to be available.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers
try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "..\Utilities\ConsoleDisplayUtils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Warning "InitialisationManager.psm1: Could not import ConsoleDisplayUtils.psm1. Banner display will be affected. Error: $($_.Exception.Message)"
    # Continue without banner if ConsoleDisplayUtils is missing, but core global vars can still be set.
}
#endregion

function Invoke-PoShBackupInitialSetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MainScriptPath # The $PSCommandPath of PoSh-Backup.ps1
    )

    # --- Define Global Colour Variables ---
    $Global:ColourInfo                          = "Cyan"
    $Global:ColourSuccess                       = "Green"
    $Global:ColourWarning                       = "Yellow"
    $Global:ColourError                         = "Red"
    $Global:ColourDebug                         = "Gray"
    $Global:ColourBorder                        = "DarkGray"
    $Global:ColourValue                         = "DarkYellow"
    $Global:ColourHeading                       = "White"
    $Global:ColourSimulate                      = "Magenta"
    $Global:ColourAdmin                         = "DarkYellow"
    $Global:ColourAdvice                        = "DarkCyan"

    # --- Define Global Status-to-Colour Map ---
    $Global:StatusToColourMap = @{
        "ADVICE"            = $Global:ColourAdvice
        "SUCCESS"           = $Global:ColourSuccess
        "WARNINGS"          = $Global:ColourWarning
        "WARNING"           = $Global:ColourWarning
        "FAILURE"           = $Global:ColourError
        "ERROR"             = $Global:ColourError
        "SIMULATED_COMPLETE"= $Global:ColourSimulate
        "INFO"              = $Global:ColourInfo
        "DEBUG"             = $Global:ColourDebug
        "VSS"               = $Global:ColourAdmin
        "HOOK"              = $Global:ColourDebug
        "CONFIG_TEST"       = $Global:ColourSimulate
        "HEADING"           = $Global:ColourHeading
        "NONE"              = $Host.UI.RawUI.ForegroundColor
        "DEFAULT"           = $Global:ColourInfo
    }

    # --- Define Global Standardised Exit Codes ---
    $Global:PoShBackup_ExitCodes = @{
        # --- Success Codes (0-9) ---
        Success                   = 0                       # Job/Set completed successfully with no warnings.
        SuccessWithWarnings       = 1                       # Job/Set completed, but generated one or more warnings (e.g., skipped files).

        # --- Failure Codes (10-19) ---
        OperationalFailure        = 2                       # A general failure during the main backup operation (e.g., 7-Zip error, VSS failure).
        ConfigurationError        = 10                      # Script halted due to an invalid or missing configuration.
        DependencyError           = 11                      # Script halted because a required module (e.g., Posh-SSH) or dependency (e.g., 7z.exe) was not found.
        UserCancellation          = 12                      # Script was halted by the user (e.g., Ctrl+C, cancelling a prompt).
        UpdateCheckFailure        = 13                      # The -CheckForUpdate process failed.
        
        # --- Critical Script Error Codes (20+) ---
        CriticalError             = 20                      # An unexpected or unhandled exception occurred in the script's core logic.
    }

    # --- Initialise Global Logging Variables ---
    $Global:GlobalLogFile                       = $null
    $Global:GlobalEnableFileLogging             = $false
    $Global:GlobalLogDirectory                  = $null
    $Global:GlobalJobLogEntries                 = $null
    $Global:GlobalJobHookScriptData             = $null

    # --- Respect Quiet Mode ---
    # The $Global:IsQuietMode flag is set by the main PoSh-Backup.ps1 script immediately
    # after parameters are bound. This module should RESPECT that global variable and NOT reset it.

    # --- Display Starting Banner (only if not in Quiet mode) ---
    if ($Global:IsQuietMode -ne $true) {
        if (Get-Command Write-ConsoleBanner -ErrorAction SilentlyContinue) {
            $scriptVersionForBanner = "vN/A" # Default
            try {
                $scriptRootForVersion = Split-Path -Path $MainScriptPath -Parent
                $versionFilePath = Join-Path -Path $scriptRootForVersion -ChildPath "Meta\Version.psd1"

                if (Test-Path -LiteralPath $versionFilePath -PathType Leaf) {
                    $versionInfo = Import-PowerShellDataFile -LiteralPath $versionFilePath
                    $version = $versionInfo.InstalledVersion
                    $commit = if ($versionInfo.ContainsKey('CommitHash') -and -not [string]::IsNullOrWhiteSpace($versionInfo.CommitHash)) { $versionInfo.CommitHash } else { "N/A" }
                    if ($commit -ne "N/A") {
                        $scriptVersionForBanner = "v$version ($commit)"
                    } else {
                        $scriptVersionForBanner = "v$version"
                    }
                }
            }
            catch {
                Write-Host "[DEBUG] InitialisationManager.psm1: Error reading version/commit from Meta\Version.psd1 for banner: $($_.Exception.Message). Using fallback." -ForegroundColor $Global:ColourDebug
            }

            Write-ConsoleBanner -NameText "PoSh Backup" `
                                -NameForegroundColor '$Global:ColourInfo' `
                                -ValueText $scriptVersionForBanner `
                                -ValueForegroundColor '$Global:ColourValue' `
                                -BannerWidth 78 `
                                -BorderForegroundColor '$Global:ColourHeading' `
                                -CenterText `
                                -PrependNewLine

            # Author Information
            if ($Global:IsQuietMode -ne $true) {
                $authorName = "Joe Cox"
                $githubLink = "https://github.com/BootBlock/PoSh-Backup"
                $websiteLink = "https://bootblock.co.uk"
                $authorInfoColor = $Global:ColourDebug

                Write-Host # Blank line for spacing
                Write-Host "        $authorName" -ForegroundColor White -NoNewline
                Write-Host " : " -ForegroundColor $Global:ColourHeading -NoNewline
                Write-Host $githubLink -ForegroundColor $authorInfoColor

                Write-Host "    " -ForegroundColor $authorInfoColor -NoNewline
                Write-Host "            : " -ForegroundColor $Global:ColourHeading -NoNewline
                Write-Host $websiteLink -ForegroundColor $authorInfoColor
                Write-Host # Blank line after author info
            }
        }
        else {
            Write-Warning "InitialisationManager.psm1: Write-ConsoleBanner command not found. Skipping banner display."
        }
    }
}

Export-ModuleMember -Function Invoke-PoShBackupInitialSetup
