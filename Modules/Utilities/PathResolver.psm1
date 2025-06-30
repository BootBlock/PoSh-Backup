# Modules\Utilities\PathResolver.psm1
<#
.SYNOPSIS
    Provides a centralised utility function for resolving paths within the PoSh-Backup project.
.DESCRIPTION
    This module contains the 'Resolve-PoShBackupPath' function, which provides a standardised
    way to convert a potentially relative path from the configuration into a full, absolute
    path based on the script's root directory. This ensures consistent path handling
    throughout the entire application.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    29-Jun-2025
    LastModified:   29-Jun-2025
    Purpose:        To centralise and standardise all path resolution logic.
    Prerequisites:  PowerShell 5.1+.
#>

function Resolve-PoShBackupPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # The path string to resolve, which could be relative or absolute.
        [Parameter(Mandatory = $true)]
        [string]$PathToResolve,

        # The absolute path to the PoSh-Backup script's root directory.
        [Parameter(Mandatory = $true)]
        [string]$ScriptRoot
    )

    if ([string]::IsNullOrWhiteSpace($PathToResolve)) {
        return $null
    }

    # If the path is already rooted (e.g., "C:\...", "\\server\share\..."), return it as is.
    if ([System.IO.Path]::IsPathRooted($PathToResolve)) {
        return $PathToResolve
    }

    # Otherwise, treat it as a relative path and join it with the script root.
    try {
        return (Join-Path -Path $ScriptRoot -ChildPath $PathToResolve -ErrorAction Stop)
    }
    catch {
        # This could happen if the relative path contains invalid characters.
        # We log this via Write-Warning as there is no logger passed to this low-level utility.
        Write-Warning "PathResolver: Failed to join path '$PathToResolve' with script root '$ScriptRoot'. Error: $($_.Exception.Message)"
        return $null
    }
}

Export-ModuleMember -Function Resolve-PoShBackupPath
