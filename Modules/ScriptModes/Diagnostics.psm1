# Modules\ScriptModes\Diagnostics.psm1
<#
.SYNOPSIS
    Handles diagnostic script modes for PoSh-Backup, such as testing the configuration,
    getting a job's effective configuration, and exporting a diagnostic package. This module
    now acts as a facade.
.DESCRIPTION
    This module is a sub-component of ScriptModeHandler.psm1. It acts as a facade,
    delegating the logic for various diagnostic modes to specialised sub-modules:
    - -TestConfig -> Diagnostics\ConfigTester.psm1
    - -GetEffectiveConfig -> Diagnostics\EffectiveConfigDisplayer.psm1
    - -ExportDiagnosticPackage -> Diagnostics\PackageExporter.psm1
    - -TestBackupTarget -> Diagnostics\TargetTester.psm1
    - -PreFlightCheck -> Diagnostics\PreFlight.psm1
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.0.0 # Refactored into a facade with sub-modules.
    DateCreated:    15-Jun-2025
    LastModified:   26-Jun-2025
    Purpose:        To handle diagnostic script execution modes for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\ScriptModes\
$diagnosticsSubModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Diagnostics"
try {
    Import-Module -Name (Join-Path $diagnosticsSubModulePath "ConfigTester.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $diagnosticsSubModulePath "EffectiveConfigDisplayer.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $diagnosticsSubModulePath "PackageExporter.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $diagnosticsSubModulePath "TargetTester.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $diagnosticsSubModulePath "PreFlight.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "Diagnostics.psm1 (Facade) FATAL: Could not import a required sub-module from '$diagnosticsSubModulePath'. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Invoke-PoShBackupDiagnosticMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$TestConfigSwitch,
        [Parameter(Mandatory = $true)]
        [bool]$PreFlightCheckSwitch,
        [Parameter(Mandatory = $false)]
        [string]$GetEffectiveConfigJobName,
        [Parameter(Mandatory = $false)]
        [string]$ExportDiagnosticPackagePath,
        [Parameter(Mandatory = $false)]
        [string]$TestBackupTarget,
        [Parameter(Mandatory = $true)]
        [hashtable]$CliOverrideSettingsInternal,
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,
        [Parameter(Mandatory = $true)]
        [string]$ActualConfigFile,
        [Parameter(Mandatory = $true)]
        [hashtable]$ConfigLoadResult,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance,
        [Parameter(Mandatory = $false)]
        [string]$BackupLocationNameForScope,
        [Parameter(Mandatory = $false)]
        [string]$RunSetForScope
    )

    & $Logger -Message "Diagnostics (Facade): Logger active. Checking for diagnostic mode to handle." -Level "DEBUG" -ErrorAction SilentlyContinue

    if ($TestConfigSwitch) {
        Invoke-PoShBackupConfigTest -Configuration $Configuration `
            -ActualConfigFile $ActualConfigFile `
            -ConfigLoadResult $ConfigLoadResult `
            -CliOverrideSettingsInternal $CliOverrideSettingsInternal `
            -Logger $Logger
        return $true
    }

    if ($PreFlightCheckSwitch) {
        $jobsToRun = @()
        if (-not [string]::IsNullOrWhiteSpace($BackupLocationNameForScope)) {
            $jobsToRun = @($BackupLocationNameForScope)
        }
        elseif (-not [string]::IsNullOrWhiteSpace($RunSetForScope)) {
            if ($Configuration.BackupSets.ContainsKey($RunSetForScope)) {
                $jobsToRun = @($Configuration.BackupSets[$RunSetForScope].JobNames)
            }
            else {
                & $Logger -Message "  - ERROR: Specified set '$RunSetForScope' not found in configuration." -Level "ERROR"
            }
        }
        else {
            & $Logger -Message "  - Checking all enabled backup jobs defined in the configuration..." -Level "INFO"
            $jobsToRun = @($Configuration.BackupLocations.Keys)
        }
        
        if ($jobsToRun.Count -gt 0) {
            Invoke-PoShBackupPreFlightCheck -JobsToCheck $jobsToRun `
                -Configuration $Configuration `
                -CliOverrideSettings $CliOverrideSettingsInternal `
                -Logger $Logger `
                -PSCmdletInstance $PSCmdletInstance
        }
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($TestBackupTarget)) {
        Invoke-PoShBackupTargetTest -TargetName $TestBackupTarget `
            -Configuration $Configuration `
            -Logger $Logger `
            -PSCmdletInstance $PSCmdletInstance
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($ExportDiagnosticPackagePath)) {
        Invoke-ExportDiagnosticPackage -OutputPath $ExportDiagnosticPackagePath `
            -PSScriptRoot $Configuration['_PoShBackup_PSScriptRoot'] `
            -Logger $Logger `
            -PSCmdletInstance $PSCmdletInstance
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($GetEffectiveConfigJobName)) {
        Invoke-PoShBackupEffectiveConfigDisplay -JobName $GetEffectiveConfigJobName `
            -Configuration $Configuration `
            -CliOverrideSettingsInternal $CliOverrideSettingsInternal `
            -Logger $Logger
        return $true
    }

    return $false
}

Export-ModuleMember -Function Invoke-PoShBackupDiagnosticMode
