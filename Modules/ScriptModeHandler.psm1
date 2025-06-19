# Modules\ScriptModeHandler.psm1
<#
.SYNOPSIS
    Acts as a facade to handle informational and utility script modes for PoSh-Backup.
    It determines which mode is requested and delegates execution to the appropriate sub-module.
.DESCRIPTION
    This module is the primary entry point for handling any PoSh-Backup execution mode that
    is not a standard backup run. It checks for parameters like -TestConfig, -ListBackupLocations,
    -PinBackup, -TestBackupTarget, etc., and orchestrates the call to the correct specialized
    sub-module located in '.\Modules\ScriptModes\'.

    The sub-modules it manages are:
    - Diagnostics.psm1: For -TestConfig, -GetEffectiveConfig, -ExportDiagnosticPackage, -TestBackupTarget.
    - Listing.psm1: For -ListBackupLocations, -ListBackupSets, -Version.
    - ArchiveManagement.psm1: For -ListArchiveContents, -ExtractFromArchive, -PinBackup, -UnpinBackup.
    - MaintenanceAndVerification.psm1: For -Maintenance, -RunVerificationJobs.

    If a sub-module successfully handles a mode, this script will exit with a code of 0.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.1.0 # Added TestBackupTarget parameter.
    DateCreated:    24-May-2025
    LastModified:   18-Jun-2025
    Purpose:        To orchestrate and delegate informational/utility script execution modes.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\
try {
    Import-Module -Name (Join-Path $PSScriptRoot "ScriptModes\Diagnostics.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "ScriptModes\Listing.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "ScriptModes\ArchiveManagement.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "ScriptModes\MaintenanceAndVerification.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "ScriptModeHandler.psm1 FATAL: Could not import required sub-modules from 'Modules\ScriptModes\'. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- Exported Function: Invoke-PoShBackupScriptMode ---
function Invoke-PoShBackupScriptMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$ListBackupLocationsSwitch,
        [Parameter(Mandatory = $true)]
        [bool]$ListBackupSetsSwitch,
        [Parameter(Mandatory = $true)]
        [bool]$TestConfigSwitch,
        [Parameter(Mandatory = $true)]
        [bool]$RunVerificationJobsSwitch,
        [Parameter(Mandatory = $true)]
        [bool]$CheckForUpdateSwitch, # Note: This is handled before this module is called, but passed for completeness.
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
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    # PSSA Appeasement: Directly use the Logger parameter once.
    & $Logger -Message "ScriptModeHandler (Facade): Initializing. Delegating to sub-modules." -Level "DEBUG" -ErrorAction SilentlyContinue

    # --- Delegate to Diagnostic Modes Handler ---
    $diagParams = @{
        TestConfigSwitch            = $TestConfigSwitch
        GetEffectiveConfigJobName   = $GetEffectiveConfigJobName
        ExportDiagnosticPackagePath = $ExportDiagnosticPackagePath
        TestBackupTarget            = $TestBackupTarget
        CliOverrideSettingsInternal = $CliOverrideSettingsInternal
        Configuration               = $Configuration
        ActualConfigFile            = $ActualConfigFile
        ConfigLoadResult            = $ConfigLoadResult
        Logger                      = $Logger
        PSCmdletInstance            = $PSCmdletInstance
    }

    if (Invoke-PoShBackupDiagnosticMode @diagParams) {
        return $true
    }

    # --- Delegate to Archive Management Modes Handler ---
    $archiveMgmtParams = @{
        PinBackupPath             = $PinBackupPath
        UnpinBackupPath           = $UnpinBackupPath
        ListArchiveContentsPath   = $ListArchiveContentsPath
        ExtractFromArchivePath    = $ExtractFromArchivePath
        ExtractToDirectoryPath    = $ExtractToDirectoryPath
        ItemsToExtract            = $ItemsToExtract
        ForceExtract              = $ForceExtract
        ArchivePasswordSecretName = $ArchivePasswordSecretName
        Configuration             = $Configuration
        Logger                    = $Logger
        PSCmdletInstance          = $PSCmdletInstance
    }

    if (Invoke-PoShBackupArchiveManagementMode @archiveMgmtParams) {
        return $true
    }

    # --- Delegate to Listing Modes Handler ---
    $listingParams = @{
        ListBackupLocationsSwitch = $ListBackupLocationsSwitch
        ListBackupSetsSwitch      = $ListBackupSetsSwitch
        VersionSwitch             = $VersionSwitch
        Configuration             = $Configuration
        ActualConfigFile          = $ActualConfigFile
        ConfigLoadResult          = $ConfigLoadResult
        Logger                    = $Logger
    }

    if (Invoke-PoShBackupListingMode @listingParams) {
        return $true
    }

    # --- Delegate to Maintenance and Verification Modes Handler ---
    $maintAndVerifyParams = @{
        RunVerificationJobsSwitch = $RunVerificationJobsSwitch
        Configuration             = $Configuration
        Logger                    = $Logger
        PSCmdletInstance          = $PSCmdletInstance
    }
    
    if ($PSBoundParameters.ContainsKey('MaintenanceSwitchValue')) {
        $maintAndVerifyParams.MaintenanceSwitchValue = $MaintenanceSwitchValue
    }
    
    if (Invoke-PoShBackupMaintenanceAndVerificationMode @maintAndVerifyParams) {
        return $true
    }

    # If no utility mode was handled by any sub-module, return false to let the main script continue.
    return $false
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupScriptMode
