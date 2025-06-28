# Modules\Targets\Replicate\Replicate.PathHandler.psm1
<#
.SYNOPSIS
    A sub-module for Replicate.Target.psm1. Handles destination path validation and creation.
.DESCRIPTION
    This module provides the 'Set-ReplicateDestinationPath' function. It is responsible for
    ensuring that a given destination path (which can be local or UNC) exists, creating
    the directory structure component by component if it does not.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    28-Jun-2025
    LastModified:   28-Jun-2025
    Purpose:        To isolate the path creation logic for the Replicate target.
    Prerequisites:  PowerShell 5.1+.
#>

function Set-ReplicateDestinationPath {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [scriptblock]$Logger,
        [Parameter(Mandatory)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )
    & $Logger -Message "Replicate.Target/PathHandler: Logger active for path '$Path'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    if (Test-Path -LiteralPath $Path -PathType Container) {
        & $LocalWriteLog -Message "  - PathHandler: Path '$Path' already exists." -Level "DEBUG"
        return @{ Success = $true }
    }
    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: PathHandler: Would ensure path '$Path' exists (creating if necessary)." -Level "SIMULATE"
        return @{ Success = $true }
    }

    $pathComponents = $Path.Split([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    if ($Path.StartsWith("\\")) {
        if ($pathComponents.Count -lt 2) {
            return @{ Success = $false; ErrorMessage = "Invalid UNC path structure: '$Path'. Needs at least server and share." }
        }
        $baseSharePath = "\\$($pathComponents[0])\$($pathComponents[1])"
        if (-not $PSCmdletInstance.ShouldProcess($baseSharePath, "Test UNC Share Accessibility")) {
            return @{ Success = $false; ErrorMessage = "UNC Share accessibility test for '$baseSharePath' skipped by user." }
        }
        if (-not (Test-Path -LiteralPath $baseSharePath -PathType Container)) {
            return @{ Success = $false; ErrorMessage = "Base UNC share '$baseSharePath' not found or inaccessible." }
        }
        $currentPathToBuild = $baseSharePath
        for ($i = 2; $i -lt $pathComponents.Count; $i++) {
            $currentPathToBuild = Join-Path -Path $currentPathToBuild -ChildPath $pathComponents[$i]
            if (-not (Test-Path -LiteralPath $currentPathToBuild -PathType Container)) {
                if (-not $PSCmdletInstance.ShouldProcess($currentPathToBuild, "Create Remote Directory Component")) {
                    return @{ Success = $false; ErrorMessage = "Directory component creation for '$currentPathToBuild' skipped by user." }
                }
                & $LocalWriteLog -Message "  - PathHandler: Creating directory component '$currentPathToBuild'." -Level "DEBUG"
                try { New-Item -Path $currentPathToBuild -ItemType Directory -Force -ErrorAction Stop | Out-Null }
                catch { return @{ Success = $false; ErrorMessage = "Failed to create directory component '$currentPathToBuild'. Error: $($_.Exception.Message)" } }
            }
        }
    }
    else { # Handle local paths
        $currentPathToBuild = ""
        if ($pathComponents[0] -match '^[a-zA-Z]:$') { $currentPathToBuild = $pathComponents[0] + [System.IO.Path]::DirectorySeparatorChar; $startIndex = 1 }
        else { $startIndex = 0 }
        for ($i = $startIndex; $i -lt $pathComponents.Count; $i++) {
            if ($currentPathToBuild -eq "" -and $i -eq 0) { $currentPathToBuild = $pathComponents[$i] }
            else { $currentPathToBuild = Join-Path -Path $currentPathToBuild -ChildPath $pathComponents[$i] }
            if (-not (Test-Path -LiteralPath $currentPathToBuild -PathType Container)) {
                if (-not $PSCmdletInstance.ShouldProcess($currentPathToBuild, "Create Local Directory Component")) {
                    return @{ Success = $false; ErrorMessage = "Directory component creation for '$currentPathToBuild' skipped by user." }
                }
                & $LocalWriteLog -Message "  - PathHandler: Creating directory component '$currentPathToBuild'." -Level "DEBUG"
                try { New-Item -Path $currentPathToBuild -ItemType Directory -Force -ErrorAction Stop | Out-Null }
                catch { return @{ Success = $false; ErrorMessage = "Failed to create directory component '$currentPathToBuild'. Error: $($_.Exception.Message)" } }
            }
        }
    }
    return @{ Success = $true }
}

Export-ModuleMember -Function Set-ReplicateDestinationPath
