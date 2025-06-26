# Modules\ScriptModes\Diagnostics\EffectiveConfigDisplayer.psm1
<#
.SYNOPSIS
    A sub-module for Diagnostics.psm1. Handles the `-GetEffectiveConfig` script mode.
.DESCRIPTION
    This module contains the logic for displaying the fully resolved, effective
    configuration for a single backup job. It resolves all global, set, and
    CLI overrides to show the final settings that would be used for a backup run.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    26-Jun-2025
    LastModified:   26-Jun-2025
    Purpose:        To handle the -GetEffectiveConfig diagnostic mode.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\ScriptModes\Diagnostics
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Utilities\ConsoleDisplayUtils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Core\ConfigManager.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Warning "ScriptModes\Diagnostics\EffectiveConfigDisplayer.psm1: Could not import required modules. Error: $($_.Exception.Message)"
}
#endregion

function Invoke-PoShBackupEffectiveConfigDisplay {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$JobName,
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,
        [Parameter(Mandatory = $true)]
        [hashtable]$CliOverrideSettingsInternal,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "Diagnostics/EffectiveConfigDisplayer: Logger active for job '$JobName'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    Write-ConsoleBanner -NameText "Effective Configuration For Job" -ValueText $JobName -CenterText -PrependNewLine
    Write-Host

    if (-not $Configuration.BackupLocations.ContainsKey($JobName)) {
        & $LocalWriteLog -Message "  - ERROR: The specified job name '$JobName' was not found in the configuration." -Level "ERROR"
        return
    }

    try {
        $jobConfigForReport = $Configuration.BackupLocations[$JobName]
        $dummyReportDataRef = [ref]@{ JobName = $JobName }

        $effectiveConfigParams = @{
            JobConfig        = $jobConfigForReport
            GlobalConfig     = $Configuration
            CliOverrides     = $CliOverrideSettingsInternal
            JobReportDataRef = $dummyReportDataRef
            Logger           = $Logger
        }
        $effectiveConfigResult = Get-PoShBackupJobEffectiveConfiguration @effectiveConfigParams
        Write-Host

        foreach ($key in ($effectiveConfigResult.Keys | Sort-Object)) {
            if ($key -eq 'GlobalConfigRef') { continue }
        
            $value = $effectiveConfigResult[$key]
            $valueDisplay = if ($value -is [array]) {
                "@($($value -join ', '))"
            }
            elseif ($value -is [hashtable]) {
                "(Hashtable with $($value.Count) keys)"
            }
            else {
                $value
            }
            Write-NameValue -name $key -value $valueDisplay -namePadding 42
        }

    }
    catch {
        & $LocalWriteLog -Message "[FATAL] ScriptModes/Diagnostics/EffectiveConfigDisplayer: An error occurred while resolving the effective configuration for job '$JobName'. Error: $($_.Exception.Message)" -Level "ERROR"
    }

    Write-ConsoleBanner -NameText "End of Effective Configuration" -BorderForegroundColor "White" -CenterText -PrependNewLine -AppendNewLine
}

Export-ModuleMember -Function Invoke-PoShBackupEffectiveConfigDisplay
