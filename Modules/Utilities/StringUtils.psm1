# Modules\Utilities\StringUtils.psm1
<#
.SYNOPSIS
    Provides utility functions for string manipulation and extraction required by PoSh-Backup.
.DESCRIPTION
    This module contains functions for string-related operations, such as extracting
    version information from script or data file content.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.1 # Refined regex to strip comments from version string.
    DateCreated:    29-May-2025
    LastModified:   08-Jun-2025
    Purpose:        String manipulation utilities for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Get Script/File Version From Content ---
function Get-ScriptVersionFromContent {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$ScriptContent,
        [string]$ScriptNameForWarning = "script"
    )
    $versionString = "N/A"
    try {
        if ([string]::IsNullOrWhiteSpace($ScriptContent)) {
            Write-Warning "StringUtils/Get-ScriptVersionFromContent: Script content provided for '$ScriptNameForWarning' is empty."
            return "N/A (Empty Content)"
        }
        # Regexes in order of preference / commonness
        # Use word boundary \b to stop matching after the version number and avoid capturing comments.
        $regexV2 = '(?im)^\s*Version:\s*([0-9]+\.[0-9]+(?:\.[0-9]+)?(?:\.[0-9]+)?)\b'
        $regexV4 = '(?im)^\s*#\s*Version\s*:?\s*([0-9]+\.[0-9]+(?:\.[0-9]+){0,2}(?:\.[0-9]+)?)\b'
        $regexV1 = '(?s)\.NOTES(?:.|\s)*?Version:\s*([0-9]+\.[0-9]+(?:\.[0-9]+)?(?:\.[0-9]+)?)\b'
        $regexV3 = '(?im)Script Version:\s*v?([0-9]+\.[0-9]+(\.[0-9]+)?(\.[0-9]+)?)\b'


        $match = [regex]::Match($ScriptContent, $regexV2) # Try standard Version: first
        if ($match.Success) {
            $versionString = $match.Groups[1].Value.Trim()
        } else {
            $match = [regex]::Match($ScriptContent, $regexV4) # Try commented # Version:
            if ($match.Success) {
                $versionString = $match.Groups[1].Value.Trim()
            } else {
                $match = [regex]::Match($ScriptContent, $regexV1) # Try .NOTES
                if ($match.Success) {
                    $versionString = $match.Groups[1].Value.Trim()
                } else {
                    $match = [regex]::Match($ScriptContent, $regexV3) # Try Script Version:
                    if ($match.Success) {
                        $versionString = "v" + $match.Groups[1].Value.Trim()
                    } else {
                        Write-Warning "StringUtils/Get-ScriptVersionFromContent: Could not automatically determine version for '$ScriptNameForWarning' using any regex."
                    }
                }
            }
        }
    } catch {
        Write-Warning "StringUtils/Get-ScriptVersionFromContent: Error parsing version for '$ScriptNameForWarning': $($_.Exception.Message)"
    }
    return $versionString
}
#endregion

Export-ModuleMember -Function Get-ScriptVersionFromContent
