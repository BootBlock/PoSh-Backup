# Modules\ScriptModes\PreFlightChecker\SourcePathChecker.psm1
<#
.SYNOPSIS
    A sub-module for PreFlightChecker.psm1. Handles validation of source paths.
.DESCRIPTION
    This module provides the 'Test-PreFlightSourcePath' function, which verifies that
    all configured source paths for a backup job exist and are accessible. It also
    handles the specific check for a Hyper-V VM source.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.1 # Added ADVICE logging for missing paths.
    DateCreated:    01-Jul-2025
    LastModified:   01-Jul-2025
    Purpose:        To isolate the source path pre-flight check logic.
    Prerequisites:  PowerShell 5.1+.
#>

function Test-PreFlightSourcePath {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveConfig,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "SourcePathChecker: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour) & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour }
    $checkSuccess = $true

    & $LocalWriteLog -Message "`n  1. Checking Source Paths..." -Level "HEADING"
    if ($EffectiveConfig.SourceIsVMName -eq $true) {
        # Special handling for Hyper-V VM backups
        $vmName = ($EffectiveConfig.OriginalSourcePath | Select-Object -First 1)
        & $LocalWriteLog -Message "    - This is a VM backup job. Checking for VM existence..." -Level "DEBUG"
        if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
            & $LocalWriteLog -Message "    - [PASS] Source VM is accessible: '$vmName'" -Level "SUCCESS"
        }
        else {
            & $LocalWriteLog -Message "    - [FAIL] Source VM not found or Hyper-V module unavailable: '$vmName'" -Level "ERROR"
            $checkSuccess = $false
        }
        $subPaths = @($EffectiveConfig.OriginalSourcePath | Select-Object -Skip 1)
        if ($subPaths.Count -gt 0) {
            & $LocalWriteLog -Message "    - [INFO] Sub-paths within the VM will not be checked during pre-flight." -Level "INFO"
        }
    }
    else {
        # Standard file/folder path checking
        $sourcePaths = if ($EffectiveConfig.OriginalSourcePath -is [array]) { $EffectiveConfig.OriginalSourcePath } else { @($EffectiveConfig.OriginalSourcePath) }
        foreach ($path in $sourcePaths) {
            if (Test-Path -Path $path) {
                & $LocalWriteLog -Message "    - [PASS] Source path is accessible: '$path'" -Level "SUCCESS"
            }
            else {
                & $LocalWriteLog -Message "    - [FAIL] Source path not found or inaccessible: '$path'" -Level "ERROR"
                $adviceMessage = "ADVICE: Please check for typos in your configuration. If it's a network path, ensure the share is online and accessible by the user running the script."
                & $LocalWriteLog -Message "      $adviceMessage" -Level "ADVICE"
                $checkSuccess = $false
            }
        }
    }
    return $checkSuccess
}

Export-ModuleMember -Function Test-PreFlightSourcePath
