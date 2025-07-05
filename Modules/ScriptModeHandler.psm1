# Modules\ScriptModeHandler.psm1
<#
.SYNOPSIS
    Acts as a facade to handle informational and utility script modes for PoSh-Backup.
    It determines which mode is requested and lazy-loads the appropriate sub-module for execution.
.DESCRIPTION
    This module is the primary entry point for handling any PoSh-Backup execution mode that
    is not a standard backup run. It checks for parameters like -TestConfig, -ListBackupLocations,
    -PinBackup, etc., and orchestrates the call to the correct specialized sub-module located
    in '.\Modules\ScriptModes\'. This on-demand loading improves script startup performance.

    The sub-modules it manages are:
    - Diagnostics.psm1: For -TestConfig, -GetEffectiveConfig, -ExportDiagnosticPackage, -TestBackupTarget, -PreFlightCheck.
    - Listing.psm1: For -ListBackupLocations, -ListBackupSets, -Version.
    - ArchiveManagement.psm1: For -ListArchiveContents, -ExtractFromArchive, -PinBackup, -UnpinBackup.
    - MaintenanceAndVerification.psm1: For -Maintenance, -RunVerificationJobs, and -VerificationJobName.

    If a sub-module successfully handles a mode, this script will exit with a code of 0.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.4.0 # Refactored to lazy-load sub-modules.
    DateCreated:    24-May-2025
    LastModified:   02-Jul-2025
    Purpose:        To orchestrate and delegate informational/utility script execution modes.
    Prerequisites:  PowerShell 5.1+.
#>

# No eager module imports are needed here. They will be lazy-loaded.

#region --- Exported Function: Invoke-PoShBackupScriptMode ---
function Invoke-PoShBackupScriptMode {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$ListBackupLocationsSwitch,
        [Parameter(Mandatory = $true)]
        [bool]$ListBackupSetsSwitch,
        [Parameter(Mandatory = $true)]
        [bool]$TestConfigSwitch,
        [Parameter(Mandatory = $true)]
        [bool]$PreFlightCheckSwitch,
        [Parameter(Mandatory = $true)]
        [bool]$RunVerificationJobsSwitch,
        [Parameter(Mandatory = $false)]
        [string]$VerificationJobName,
        [Parameter(Mandatory = $true)]
        [bool]$CheckForUpdateSwitch,
        [Parameter(Mandatory = $true)]
        [bool]$VersionSwitch,
        [Parameter(Mandatory = $false)]
        [string]$GetEffectiveConfigJobName,
        [Parameter(Mandatory = $false)]
        [string]$TestBackupTarget,
        [Parameter(Mandatory = $true)]
        [hashtable]$CliOverrideSettingsInternal,
        [Parameter(Mandatory = $false)]
        [string]$ExportDiagnosticPackagePath,
        [Parameter(Mandatory = $false)]
        [Nullable[bool]]$MaintenanceSwitchValue,
        [Parameter(Mandatory = $false)]
        [string]$PinBackupPath,
        [Parameter(Mandatory = $false)]
        [string]$PinReason,
        [Parameter(Mandatory = $false)]
        [string]$UnpinBackupPath,
        [Parameter(Mandatory = $false)]
        [string]$ListArchiveContentsPath,
        [Parameter(Mandatory = $false)]
        [string]$ArchivePasswordSecretName,
        [Parameter(Mandatory = $false)]
        [string]$ExtractFromArchivePath,
        [Parameter(Mandatory = $false)]
        [string]$ExtractToDirectoryPath,
        [Parameter(Mandatory = $false)]
        [string[]]$ItemsToExtract,
        [Parameter(Mandatory = $false)]
        [bool]$ForceExtract,
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,
        [Parameter(Mandatory = $true)]
        [string]$ActualConfigFile,
        [Parameter(Mandatory = $true)]
        [hashtable]$ConfigLoadResult,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance,
        [Parameter(Mandatory = $false)]
        [string]$BackupLocationNameForScope,
        [Parameter(Mandatory = $false)]
        [string]$RunSetForScope
    )

    $isDiagnosticMode = $TestConfigSwitch -or $PreFlightCheckSwitch -or (-not [string]::IsNullOrWhiteSpace($GetEffectiveConfigJobName)) -or (-not [string]::IsNullOrWhiteSpace($ExportDiagnosticPackagePath)) -or (-not [string]::IsNullOrWhiteSpace($TestBackupTarget))
    $isArchiveMgmtMode = (-not [string]::IsNullOrWhiteSpace($PinBackupPath)) -or (-not [string]::IsNullOrWhiteSpace($UnpinBackupPath)) -or (-not [string]::IsNullOrWhiteSpace($ListArchiveContentsPath)) -or (-not [string]::IsNullOrWhiteSpace($ExtractFromArchivePath))
    $isListingMode = $ListBackupLocationsSwitch -or $ListBackupSetsSwitch -or $VersionSwitch
    $isMaintVerifyMode = $RunVerificationJobsSwitch -or (-not [string]::IsNullOrWhiteSpace($VerificationJobName)) -or ($PSBoundParameters.ContainsKey('MaintenanceSwitchValue'))

    if ($isDiagnosticMode) {
        try {
            Import-Module -Name (Join-Path $PSScriptRoot "ScriptModes\Diagnostics.psm1") -Force -ErrorAction Stop
            $diagParams = @{ TestConfigSwitch = $TestConfigSwitch; PreFlightCheckSwitch = $PreFlightCheckSwitch; GetEffectiveConfigJobName = $GetEffectiveConfigJobName; ExportDiagnosticPackagePath = $ExportDiagnosticPackagePath; TestBackupTarget = $TestBackupTarget; CliOverrideSettingsInternal = $CliOverrideSettingsInternal; Configuration = $Configuration; ActualConfigFile = $ActualConfigFile; ConfigLoadResult = $ConfigLoadResult; Logger = $Logger; PSCmdletInstance = $PSCmdletInstance; BackupLocationNameForScope = $BackupLocationNameForScope; RunSetForScope = $RunSetForScope }
            if (Invoke-PoShBackupDiagnosticMode @diagParams) { return $true }
        } catch { & $Logger "[FATAL] ScriptModeHandler: Failed to load Diagnostics sub-module. Error: $($_.Exception.Message)" "ERROR"; throw }
    }

    if ($isArchiveMgmtMode) {
        try {
            Import-Module -Name (Join-Path $PSScriptRoot "ScriptModes\ArchiveManagement.psm1") -Force -ErrorAction Stop
            $archiveMgmtParams = @{ PinBackupPath = $PinBackupPath; PinReason = $PinReason; UnpinBackupPath = $UnpinBackupPath; ListArchiveContentsPath = $ListArchiveContentsPath; ExtractFromArchivePath = $ExtractFromArchivePath; ExtractToDirectoryPath = $ExtractToDirectoryPath; ItemsToExtract = $ItemsToExtract; ForceExtract = $ForceExtract; ArchivePasswordSecretName = $ArchivePasswordSecretName; Configuration = $Configuration; Logger = $Logger; PSCmdletInstance = $PSCmdletInstance }
            if (Invoke-PoShBackupArchiveManagementMode @archiveMgmtParams) { return $true }
        } catch { & $Logger "[FATAL] ScriptModeHandler: Failed to load ArchiveManagement sub-module. Error: $($_.Exception.Message)" "ERROR"; throw }
    }

    if ($isListingMode) {
        try {
            Import-Module -Name (Join-Path $PSScriptRoot "ScriptModes\Listing.psm1") -Force -ErrorAction Stop
            $listingParams = @{ ListBackupLocationsSwitch = $ListBackupLocationsSwitch; ListBackupSetsSwitch = $ListBackupSetsSwitch; VersionSwitch = $VersionSwitch; Configuration = $Configuration; ActualConfigFile = $ActualConfigFile; ConfigLoadResult = $ConfigLoadResult; Logger = $Logger; PSCmdletInstance = $PSCmdletInstance }
            if (Invoke-PoShBackupListingMode @listingParams) { return $true }
        } catch { & $Logger "[FATAL] ScriptModeHandler: Failed to load Listing sub-module. Error: $($_.Exception.Message)" "ERROR"; throw }
    }

    if ($isMaintVerifyMode) {
        try {
            Import-Module -Name (Join-Path $PSScriptRoot "ScriptModes\MaintenanceAndVerification.psm1") -Force -ErrorAction Stop
            $maintAndVerifyParams = @{ RunVerificationJobsSwitch = $RunVerificationJobsSwitch; VerificationJobName = $VerificationJobName; Configuration = $Configuration; Logger = $Logger; PSCmdletInstance = $PSCmdletInstance }
            if ($PSBoundParameters.ContainsKey('MaintenanceSwitchValue')) { $maintAndVerifyParams.MaintenanceSwitchValue = $MaintenanceSwitchValue }
            if (Invoke-PoShBackupMaintenanceAndVerificationMode @maintAndVerifyParams) { return $true }
        } catch { & $Logger "[FATAL] ScriptModeHandler: Failed to load MaintenanceAndVerification sub-module. Error: $($_.Exception.Message)" "ERROR"; throw }
    }

    return $false
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupScriptMode
