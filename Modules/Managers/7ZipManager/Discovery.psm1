# Modules\Managers\7ZipManager\Discovery.psm1
<#
.SYNOPSIS
    Sub-module for 7ZipManager. Handles the discovery of the 7-Zip executable.
.DESCRIPTION
    This module contains the 'Find-SevenZipExecutable' function, responsible for
    locating the 7z.exe executable in common installation paths or the system PATH.
    It now returns a hashtable containing the found path and a list of all locations
    that were checked, to provide more detailed error messages.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Function now returns a hashtable with checked paths.
    DateCreated:    29-May-2025
    LastModified:   21-Jun-2025
    Purpose:        7-Zip executable discovery logic for 7ZipManager.
    Prerequisites:  PowerShell 5.1+.
                    Relies on Utils.psm1 (for logger functionality if used directly, though logger is passed).
#>

# Explicitly import Utils.psm1 from the main Modules directory.
# $PSScriptRoot here is Modules\Managers\7ZipManager.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "Discovery.psm1 (7ZipManager submodule) FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}

#region --- 7-Zip Executable Finder ---
function Find-SevenZipExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "7ZipManager/Discovery/Find-SevenZipExecutable: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        }
        else {
            & $Logger -Message $Message -Level $Level
        }
    }

    & $LocalWriteLog -Message "  - 7ZipManager/Discovery: Attempting to auto-detect 7z.exe..." -Level "DEBUG"
    
    $checkedLocations = [System.Collections.Generic.List[string]]::new()
    $commonPaths = @(
        (Join-Path -Path $env:ProgramFiles -ChildPath "7-Zip\7z.exe"),
        (Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath "7-Zip\7z.exe")
    )

    foreach ($pathAttempt in $commonPaths) {
        $checkedLocations.Add($pathAttempt)
        if ($null -ne $pathAttempt -and (Test-Path -LiteralPath $pathAttempt -PathType Leaf)) {
            & $LocalWriteLog -Message "    - 7ZipManager/Discovery: Auto-detected 7z.exe at '$pathAttempt' (common installation location)." -Level "INFO"
            return @{ FoundPath = $pathAttempt; CheckedPaths = $checkedLocations }
        }
    }

    try {
        $checkedLocations.Add("System PATH")
        $pathFromCommand = (Get-Command 7z.exe -ErrorAction SilentlyContinue).Source
        if (-not [string]::IsNullOrWhiteSpace($pathFromCommand) -and (Test-Path -LiteralPath $pathFromCommand -PathType Leaf)) {
            & $LocalWriteLog -Message "    - 7ZipManager/Discovery: Auto-detected 7z.exe at '$pathFromCommand' (found in system PATH)." -Level "INFO"
            return @{ FoundPath = $pathFromCommand; CheckedPaths = $checkedLocations }
        }
    }
    catch {
        & $LocalWriteLog -Message "    - 7ZipManager/Discovery: 7z.exe not found in system PATH (Get-Command error: $($_.Exception.Message))." -Level "DEBUG"
    }

    & $LocalWriteLog -Message "    - 7ZipManager/Discovery: Auto-detection failed to find 7z.exe in common locations or system PATH. Please ensure 'SevenZipPath' is set in the configuration." -Level "DEBUG"
    return @{ FoundPath = $null; CheckedPaths = $checkedLocations }
}
#endregion

Export-ModuleMember -Function Find-SevenZipExecutable
