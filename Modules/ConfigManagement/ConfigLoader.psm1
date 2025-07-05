# Modules\ConfigManagement\ConfigLoader.psm1
<#
.SYNOPSIS
    Handles the loading and merging of PoSh-Backup configuration files (Default.psd1, User.psd1),
    7-Zip path auto-detection, and various stages of configuration validation.
    It delegates specific tasks to sub-modules within its 'ConfigLoader' subdirectory.
.DESCRIPTION
    This module orchestrates the complex process of loading and validating PoSh-Backup configurations.
    It acts as a facade, calling upon several specialized sub-modules:
    - 'UserConfigHandler.psm1': Manages the creation and prompting for 'User.psd1'.
    - 'MergeUtil.psm1': Provides deep hashtable merging capabilities for overlaying user config.
    - 'SevenZipPathResolver.psm1': Resolves and validates the 7-Zip executable path.
    - 'BasicValidator.psm1': Performs fundamental structural and value checks on the configuration.
    - 'AdvancedSchemaValidatorInvoker.psm1': Conditionally invokes detailed schema validation via 'PoShBackupValidator.psm1'.

    The main 'Import-AppConfiguration' function sequences these operations to produce a validated,
    ready-to-use configuration object for PoSh-Backup.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.3.0 # Further modularized: 7Zip path, basic validation, and advanced validation invocation moved to sub-modules.
    DateCreated:    24-May-2025
    LastModified:   29-May-2025
    Purpose:        To modularise configuration loading logic from the main ConfigManager module.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Utils.psm1 and 7ZipManager.psm1 from the parent 'Modules' directory.
                    Depends on sub-modules in '.\ConfigLoader\'.
                    Optionally uses PoShBackupValidator.psm1.
#>

# Explicitly import dependent modules from the parent 'Modules' directory.
# $PSScriptRoot here is Modules\ConfigManagement.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\Managers\7ZipManager.psm1") -Force -ErrorAction Stop
} catch {
    Write-Error "ConfigLoader.psm1 FATAL: Could not import dependent modules (Utils.psm1 or Managers\7ZipManager.psm1). Error: $($_.Exception.Message)"
    throw
}

# Import new sub-modules
# $PSScriptRoot here is Modules\ConfigManagement.
$configLoaderSubModulesPath = Join-Path -Path $PSScriptRoot -ChildPath "ConfigLoader"
try {
    Import-Module -Name (Join-Path -Path $configLoaderSubModulesPath -ChildPath "MergeUtil.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $configLoaderSubModulesPath -ChildPath "UserConfigHandler.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $configLoaderSubModulesPath -ChildPath "SevenZipPathResolver.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $configLoaderSubModulesPath -ChildPath "BasicValidator.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $configLoaderSubModulesPath -ChildPath "AdvancedSchemaValidatorInvoker.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "ConfigLoader.psm1 FATAL: Could not import one or more required sub-modules from '$configLoaderSubModulesPath'. Error: $($_.Exception.Message)"
    throw
}


#region --- Exported Configuration Loading and Validation Function ---
function Import-AppConfiguration {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [string]$UserSpecifiedPath,
        [switch]$IsTestConfigMode,
        [string]$MainScriptPSScriptRoot,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $false)]
        [bool]$SkipUserConfigCreationSwitch = $false,
        [Parameter(Mandatory = $false)]
        [bool]$IsSimulateModeSwitch = $false,
        [Parameter(Mandatory = $false)]
        [bool]$ListBackupLocationsSwitch = $false,
        [Parameter(Mandatory = $false)]
        [bool]$ListBackupSetsSwitch = $false,
        [Parameter(Mandatory = $true)]
        [hashtable]$CliOverrideSettings
    )

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    & $LocalWriteLog -Message "ConfigLoader/Import-AppConfiguration: Logger active. Orchestrating configuration load and validation." -Level "DEBUG"

    $finalConfiguration = $null
    $userConfigLoadedSuccessfully = $false
    $primaryConfigPathForReturn = $null
    $validationMessages = [System.Collections.Generic.List[string]]::new()

    $defaultConfigDir = Join-Path -Path $MainScriptPSScriptRoot -ChildPath "Config"
    $defaultBaseConfigFileName = "Default.psd1"
    $defaultUserConfigFileName = "User.psd1"
    $defaultBaseConfigPath = Join-Path -Path $defaultConfigDir -ChildPath $defaultBaseConfigFileName
    $defaultUserConfigPath = Join-Path -Path $defaultConfigDir -ChildPath $defaultUserConfigFileName

    if (-not [string]::IsNullOrWhiteSpace($UserSpecifiedPath)) {
        & $LocalWriteLog -Message "`n[DEBUG] ConfigLoader: Using user-specified configuration file: '$($UserSpecifiedPath)'" -Level "DEBUG"
        $primaryConfigPathForReturn = $UserSpecifiedPath
        if (-not (Test-Path -LiteralPath $UserSpecifiedPath -PathType Leaf)) {
            & $LocalWriteLog -Message "FATAL: ConfigLoader: Specified configuration file '$UserSpecifiedPath' not found." -Level "ERROR"
            return @{ IsValid = $false; ErrorMessage = "Configuration file not found at '$UserSpecifiedPath'." }
        }
        try {
            $finalConfiguration = Import-PowerShellDataFile -LiteralPath $UserSpecifiedPath -ErrorAction Stop
            & $LocalWriteLog -Message "  - ConfigLoader: Configuration loaded successfully from '$UserSpecifiedPath'." -Level "SUCCESS"
        }
        catch {
            & $LocalWriteLog -Message "FATAL: ConfigLoader: Could not load or parse specified configuration file '$UserSpecifiedPath'. Error: $($_.Exception.Message)" -Level "ERROR"
            return @{ IsValid = $false; ErrorMessage = "Failed to parse configuration file '$UserSpecifiedPath': $($_.Exception.Message)" }
        }
    }
    else {
        # Delegate User.psd1 creation prompt
        Invoke-UserConfigCreationPromptInternal -DefaultUserConfigPathInternal $defaultUserConfigPath `
                                                -DefaultBaseConfigPathInternal $defaultBaseConfigPath `
                                                -DefaultConfigDirInternal $defaultConfigDir `
                                                -DefaultUserConfigFileNameInternal $defaultUserConfigFileName `
                                                -DefaultBaseConfigFileNameInternal $defaultBaseConfigFileName `
                                                -SkipUserConfigCreationSwitchInternal $SkipUserConfigCreationSwitch `
                                                -IsTestConfigModeSwitchInternal $IsTestConfigMode.IsPresent `
                                                -IsSimulateModeSwitchInternal $IsSimulateModeSwitch `
                                                -ListBackupLocationsSwitchInternal $ListBackupLocationsSwitch `
                                                -ListBackupSetsSwitchInternal $ListBackupSetsSwitch `
                                                -LoggerInternal $Logger `
                                                -CliOverrideSettingsInternal $CliOverrideSettings

        $primaryConfigPathForReturn = $defaultBaseConfigPath
        & $LocalWriteLog -Message "`n[DEBUG] ConfigLoader: No -ConfigFile specified by user. Loading base configuration from: '$($defaultBaseConfigPath)'" -Level "DEBUG"
        if (-not (Test-Path -LiteralPath $defaultBaseConfigPath -PathType Leaf)) {
            & $LocalWriteLog -Message "FATAL: ConfigLoader: Base configuration file '$defaultBaseConfigPath' not found. This file is required for default operation." -Level "ERROR"
            return @{ IsValid = $false; ErrorMessage = "Base configuration file '$defaultBaseConfigPath' not found." }
        }
        try {
            $loadedBaseConfiguration = Import-PowerShellDataFile -LiteralPath $defaultBaseConfigPath -ErrorAction Stop
            & $LocalWriteLog -Message "  - ConfigLoader: Base configuration loaded successfully from '$defaultBaseConfigPath'." -Level "SUCCESS"
            $finalConfiguration = $loadedBaseConfiguration
        }
        catch {
            & $LocalWriteLog -Message "FATAL: ConfigLoader: Could not load or parse base configuration file '$defaultBaseConfigPath'. Error: $($_.Exception.Message)" -Level "ERROR"
            return @{ IsValid = $false; ErrorMessage = "Failed to parse base configuration file '$defaultBaseConfigPath': $($_.Exception.Message)" }
        }

        & $LocalWriteLog -Message "[DEBUG] ConfigLoader: Checking for user override configuration at: '$($defaultUserConfigPath)'" -Level "DEBUG"
        if (Test-Path -LiteralPath $defaultUserConfigPath -PathType Leaf) {
            try {
                $loadedUserConfiguration = Import-PowerShellDataFile -LiteralPath $defaultUserConfigPath -ErrorAction Stop
                if ($null -ne $loadedUserConfiguration -and $loadedUserConfiguration -is [hashtable]) {
                    & $LocalWriteLog -Message "  - ConfigLoader: User override configuration '$defaultUserConfigPath' found and loaded successfully." -Level "SUCCESS"
                    & $LocalWriteLog -Message "  - ConfigLoader: Merging user configuration over base configuration..." -Level "DEBUG"
                    $finalConfiguration = Merge-DeepHashtable -Base $finalConfiguration -Override $loadedUserConfiguration # From MergeUtil.psm1
                    $userConfigLoadedSuccessfully = $true
                    & $LocalWriteLog -Message "  - ConfigLoader: User configuration merged successfully." -Level "SUCCESS"
                }
                else {
                    & $LocalWriteLog -Message "[WARNING] ConfigLoader: User override configuration file '$defaultUserConfigPath' was found but did not load as a valid hashtable (it might be empty or malformed). Skipping user overrides." -Level "WARNING"
                }
            }
            catch {
                & $LocalWriteLog -Message "[WARNING] ConfigLoader: Could not load or parse user override configuration file '$defaultUserConfigPath'. Error: $($_.Exception.Message). Using base configuration only." -Level "WARNING"
            }
        }
        else {
            & $LocalWriteLog -Message "  - ConfigLoader: User override configuration file '$defaultUserConfigPath' not found. Using base configuration only." -Level "INFO"
        }
    }

    if ($null -eq $finalConfiguration -or -not ($finalConfiguration -is [hashtable])) {
        & $LocalWriteLog -Message "FATAL: ConfigLoader: Final configuration object is null or not a valid hashtable after loading/merging attempts." -Level "ERROR"
        return @{ IsValid = $false; ErrorMessage = "Final configuration is not a valid hashtable." }
    }

    if ($null -ne $MainScriptPSScriptRoot) {
        $finalConfiguration['_PoShBackup_PSScriptRoot'] = $MainScriptPSScriptRoot
    } else {
        & $LocalWriteLog -Message "[CRITICAL] ConfigLoader: MainScriptPSScriptRoot was not provided to Import-AppConfiguration. _PoShBackup_PSScriptRoot cannot be set. Target provider validation will likely fail." -Level "ERROR"
    }

    # Delegate 7-Zip Path Resolution
    Resolve-SevenZipPath -Configuration $finalConfiguration `
                         -ValidationMessagesListRef ([ref]$validationMessages) `
                         -Logger $Logger `
                         -IsTestConfigMode $IsTestConfigMode.IsPresent

    # Delegate Basic Validations
    Invoke-BasicConfigValidation -Configuration $finalConfiguration `
                                 -ValidationMessagesListRef ([ref]$validationMessages) `
                                 -Logger $Logger `
                                 -IsTestConfigMode $IsTestConfigMode.IsPresent `
                                 -ListBackupLocationsSwitch $ListBackupLocationsSwitch `
                                 -ListBackupSetsSwitch $ListBackupSetsSwitch

    # Delegate Advanced Schema Validation Invocation (only if no prior critical errors like missing 7zip path)
    if ($validationMessages.Count -eq 0 -or ($validationMessages | Where-Object {$_ -notlike "CRITICAL*"})) {
        Invoke-AdvancedSchemaValidationIfEnabled -Configuration $finalConfiguration `
                                                 -ValidationMessagesListRef ([ref]$validationMessages) `
                                                 -Logger $Logger `
                                                 -MainScriptPSScriptRoot $MainScriptPSScriptRoot `
                                                 -IsTestConfigMode $IsTestConfigMode.IsPresent
    }

    if ($validationMessages.Count -gt 0) {
        & $LocalWriteLog -Message "ConfigLoader: Configuration validation FAILED with errors/warnings:" -Level "ERROR"
        ($validationMessages | Select-Object -Unique) | ForEach-Object { & $LocalWriteLog -Message "  - $_" -Level "ERROR" }
        return @{ IsValid = $false; ErrorMessage = "Configuration validation failed. See logs for details." }
    }

    return @{
        IsValid          = $true;
        Configuration    = $finalConfiguration;
        ActualPath       = $primaryConfigPathForReturn;
        UserConfigLoaded = $userConfigLoadedSuccessfully;
        UserConfigPath   = if ($userConfigLoadedSuccessfully -or (Test-Path -LiteralPath $defaultUserConfigPath -PathType Leaf)) { $defaultUserConfigPath } else { $null }
    }
}
#endregion

Export-ModuleMember -Function Import-AppConfiguration
