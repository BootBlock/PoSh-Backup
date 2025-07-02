# Modules\ScriptModes\Diagnostics.psm1
<#
.SYNOPSIS
    Handles diagnostic script modes for PoSh-Backup, such as testing the configuration,
    getting a job's effective configuration, and exporting a diagnostic package. This module
    now acts as a facade, lazy-loading its sub-modules.
.DESCRIPTION
    This module is a sub-component of ScriptModeHandler.psm1. It acts as a facade,
    delegating the logic for various diagnostic modes to specialised sub-modules by
    loading them on demand:
    - -TestConfig -> Diagnostics\ConfigTester.psm1
    - -GetEffectiveConfig -> Diagnostics\EffectiveConfigDisplayer.psm1
    - -ExportDiagnosticPackage -> Diagnostics\PackageExporter.psm1
    - -TestBackupTarget -> Diagnostics\TargetTester.psm1
    - -PreFlightCheck -> Diagnostics\PreFlight.psm1
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.1.0 # Refactored to lazy-load sub-modules.
    DateCreated:    15-Jun-2025
    LastModified:   02-Jul-2025
    Purpose:        To handle diagnostic script execution modes for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
#>

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
    $subModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Diagnostics"

    if ($TestConfigSwitch) {
        try {
            Import-Module -Name (Join-Path $subModulePath "ConfigTester.psm1") -Force -ErrorAction Stop
            Invoke-PoShBackupConfigTest -Configuration $Configuration `
                -ActualConfigFile $ActualConfigFile `
                -ConfigLoadResult $ConfigLoadResult `
                -CliOverrideSettingsInternal $CliOverrideSettingsInternal `
                -Logger $Logger
            return $true
        } catch { & $Logger "[FATAL] Diagnostics (Facade): Failed to load ConfigTester sub-module. Error: $($_.Exception.Message)" "ERROR"; throw }
    }

    if ($PreFlightCheckSwitch) {
        try {
            Import-Module -Name (Join-Path $subModulePath "PreFlight.psm1") -Force -ErrorAction Stop
            $jobsToRun = @()
            if (-not [string]::IsNullOrWhiteSpace($BackupLocationNameForScope)) {
                $jobsToRun = @($BackupLocationNameForScope)
            }
            elseif (-not [string]::IsNullOrWhiteSpace($RunSetForScope)) {
                if ($Configuration.BackupSets.ContainsKey($RunSetForScope)) {
                    $jobsToRun = @($Configuration.BackupSets[$RunSetForScope].JobNames)
                }
                else { & $Logger -Message "  - ERROR: Specified set '$RunSetForScope' not found in configuration." -Level "ERROR" }
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
        } catch { & $Logger "[FATAL] Diagnostics (Facade): Failed to load PreFlight sub-module. Error: $($_.Exception.Message)" "ERROR"; throw }
    }

    if (-not [string]::IsNullOrWhiteSpace($TestBackupTarget)) {
        try {
            Import-Module -Name (Join-Path $subModulePath "TargetTester.psm1") -Force -ErrorAction Stop
            Invoke-PoShBackupTargetTest -TargetName $TestBackupTarget `
                -Configuration $Configuration `
                -Logger $Logger `
                -PSCmdletInstance $PSCmdletInstance
            return $true
        } catch { & $Logger "[FATAL] Diagnostics (Facade): Failed to load TargetTester sub-module. Error: $($_.Exception.Message)" "ERROR"; throw }
    }

    if (-not [string]::IsNullOrWhiteSpace($ExportDiagnosticPackagePath)) {
        try {
            Import-Module -Name (Join-Path $subModulePath "PackageExporter.psm1") -Force -ErrorAction Stop
            Invoke-ExportDiagnosticPackage -OutputPath $ExportDiagnosticPackagePath `
                -PSScriptRoot $Configuration['_PoShBackup_PSScriptRoot'] `
                -Logger $Logger `
                -PSCmdletInstance $PSCmdletInstance
            return $true
        } catch { & $Logger "[FATAL] Diagnostics (Facade): Failed to load PackageExporter sub-module. Error: $($_.Exception.Message)" "ERROR"; throw }
    }

    if (-not [string]::IsNullOrWhiteSpace($GetEffectiveConfigJobName)) {
        try {
            Import-Module -Name (Join-Path $subModulePath "EffectiveConfigDisplayer.psm1") -Force -ErrorAction Stop
            Invoke-PoShBackupEffectiveConfigDisplay -JobName $GetEffectiveConfigJobName `
                -Configuration $Configuration `
                -CliOverrideSettingsInternal $CliOverrideSettingsInternal `
                -Logger $Logger
            return $true
        } catch { & $Logger "[FATAL] Diagnostics (Facade): Failed to load EffectiveConfigDisplayer sub-module. Error: $($_.Exception.Message)" "ERROR"; throw }
    }

    return $false
}

Export-ModuleMember -Function Invoke-PoShBackupDiagnosticMode
