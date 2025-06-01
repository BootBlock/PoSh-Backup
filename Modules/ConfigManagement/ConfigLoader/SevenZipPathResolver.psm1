# Modules\ConfigManagement\ConfigLoader\SevenZipPathResolver.psm1
<#
.SYNOPSIS
    Sub-module for ConfigLoader. Handles resolution and validation of the 7-Zip executable path.
.DESCRIPTION
    This module contains the 'Resolve-SevenZipPath' function, which is responsible for
    checking the 'SevenZipPath' in the provided configuration. If the path is not set
    or invalid, it attempts to auto-detect 7z.exe using 'Find-SevenZipExecutable'
    (from the main 7ZipManager module). It updates the configuration object with the
    resolved path and adds validation messages if a valid path cannot be determined.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    29-May-2025
    LastModified:   29-May-2025
    Purpose:        7-Zip path resolution and validation logic for ConfigLoader.
    Prerequisites:  PowerShell 5.1+.
                    Relies on Utils.psm1 (for Get-ConfigValue) and 7ZipManager.psm1 (for Find-SevenZipExecutable).
#>

# Explicitly import Utils.psm1 from the main Modules directory.
# $PSScriptRoot here is Modules\ConfigManagement\ConfigLoader.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "SevenZipPathResolver.psm1 (ConfigLoader submodule) FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}

# Explicitly import the 7ZipManager.psm1 facade to ensure Find-SevenZipExecutable is available.
# This module (SevenZipPathResolver) needs a function from 7ZipManager. Importing via ConfigLoader.psm1 doesn't seem to work any more.
try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "..\..\..\Modules\Managers\7ZipManager.psm1") -Force -ErrorAction Stop
}
catch {
    # Log an error, but don't throw immediately. Let Resolve-SevenZipPath report the missing command if it occurs.
    # This allows the logger (if passed to Resolve-SevenZipPath) to function.
    $errorMessage = "SevenZipPathResolver.psm1 (ConfigLoader submodule) WARNING: Could not import 7ZipManager.psm1. Find-SevenZipExecutable might not be available. Error: $($_.Exception.Message)"
    Write-Warning $errorMessage
    # If a logger is available to this top-level script block, use it too.
    # This is tricky as $Logger isn't passed to the module script block itself.
}

#region --- 7-Zip Path Resolver Function ---
function Resolve-SevenZipPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration, # The configuration object to potentially update
        [Parameter(Mandatory = $true)]
        [ref]$ValidationMessagesListRef, # To add error messages
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $false)]
        [bool]$IsTestConfigMode = $false
    )

    & $Logger -Message "ConfigLoader/SevenZipPathResolver/Resolve-SevenZipPath: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    $sevenZipPathFromConfigOriginal = Get-ConfigValue -ConfigObject $Configuration -Key 'SevenZipPath' -DefaultValue $null
    $sevenZipPathSource = "configuration" # Initial assumption

    if (-not ([string]::IsNullOrWhiteSpace($Configuration.SevenZipPath)) -and (Test-Path -LiteralPath $Configuration.SevenZipPath -PathType Leaf)) {
        if ($IsTestConfigMode) {
            & $LocalWriteLog -Message "  - ConfigLoader/SevenZipPathResolver: Effective 7-Zip Path set to: '$($Configuration.SevenZipPath)' (Source: $sevenZipPathSource)." -Level "CONFIG_TEST"
        }
    }
    else {
        $initialPathIsEmpty = [string]::IsNullOrWhiteSpace($sevenZipPathFromConfigOriginal)
        if (-not $initialPathIsEmpty) {
            & $LocalWriteLog -Message "[WARNING] ConfigLoader/SevenZipPathResolver: Configured 'SevenZipPath' ('$sevenZipPathFromConfigOriginal') invalid/not found. Attempting auto-detection..." -Level "WARNING"
        }
        else {
            & $LocalWriteLog -Message "[INFO] ConfigLoader/SevenZipPathResolver: 'SevenZipPath' empty/not set. Attempting auto-detection..." -Level "INFO"
        }

        # Find-SevenZipExecutable is expected to be available from the main 7ZipManager module
        if (-not (Get-Command Find-SevenZipExecutable -ErrorAction SilentlyContinue)) {
            $ValidationMessagesListRef.Value.Add("CRITICAL: ConfigLoader/SevenZipPathResolver: Find-SevenZipExecutable command not found. Ensure 7ZipManager module is loaded.")
            return # Cannot proceed without it
        }

        $foundPath = Find-SevenZipExecutable -Logger $Logger
        if ($null -ne $foundPath) {
            $Configuration.SevenZipPath = $foundPath # Update the configuration object directly
            $sevenZipPathSource = if ($initialPathIsEmpty) { "auto-detected (config was empty)" } else { "auto-detected (configured path was invalid)" }
            & $LocalWriteLog -Message "[INFO] ConfigLoader/SevenZipPathResolver: Successfully auto-detected and using 7-Zip Path: '$foundPath'." -Level "INFO"
            if ($IsTestConfigMode) {
                & $LocalWriteLog -Message "  - ConfigLoader/SevenZipPathResolver: Effective 7-Zip Path set to: '$foundPath' (Source: $sevenZipPathSource)." -Level "CONFIG_TEST"
            }
        }
        else {
            $errorMsg = if ($initialPathIsEmpty) {
                "CRITICAL: ConfigLoader/SevenZipPathResolver: 'SevenZipPath' empty and auto-detection failed. PoSh-Backup cannot function."
            } else {
                "CRITICAL: ConfigLoader/SevenZipPathResolver: Configured 'SevenZipPath' ('$sevenZipPathFromConfigOriginal') invalid, and auto-detection failed. PoSh-Backup cannot function."
            }
            if (-not $ValidationMessagesListRef.Value.Contains($errorMsg)) { $ValidationMessagesListRef.Value.Add($errorMsg) }
        }
    }

    # Final check on the effective path
    if ([string]::IsNullOrWhiteSpace($Configuration.SevenZipPath) -or (-not (Test-Path -LiteralPath $Configuration.SevenZipPath -PathType Leaf))) {
        $criticalErrorMsg = "CRITICAL: ConfigLoader/SevenZipPathResolver: Effective 'SevenZipPath' ('$($Configuration.SevenZipPath)') is invalid or not found after all checks. PoSh-Backup requires a valid 7z.exe path."
        if (-not $ValidationMessagesListRef.Value.Contains($criticalErrorMsg) -and `
                -not ($ValidationMessagesListRef.Value | Where-Object { $_ -like "*'SevenZipPath' empty and auto-detection failed*" }) -and `
                -not ($ValidationMessagesListRef.Value | Where-Object { $_ -like "*Configured 'SevenZipPath' (*" })) {
            $ValidationMessagesListRef.Value.Add($criticalErrorMsg)
        }
    }
}
#endregion

Export-ModuleMember -Function Resolve-SevenZipPath
