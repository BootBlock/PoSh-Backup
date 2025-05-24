# Modules\ConfigManagement\ConfigLoader.psm1
<#
.SYNOPSIS
    Handles the loading and merging of PoSh-Backup configuration files (Default.psd1, User.psd1),
    7-Zip path auto-detection, and basic structural validation including BackupTargets.
.DESCRIPTION
    This module is a sub-component of the main ConfigManager module for PoSh-Backup.
    It is responsible for:
    - Loading the base configuration (Default.psd1).
    - Loading and merging the user-specific configuration (User.psd1) if it exists.
    - Handling a user-specified configuration file path.
    - Auto-detecting the 7-Zip executable path if not explicitly configured (delegates to 7ZipManager.psm1).
    - Performing basic validation of the loaded configuration structure, including 'BackupTargets'.
    - Optionally invoking advanced schema validation (delegates to PoShBackupValidator.psm1).

    It is designed to be called by the main PoSh-Backup script indirectly via the ConfigManager facade.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    24-May-2025
    LastModified:   24-May-2025
    Purpose:        To modularise configuration loading logic from the main ConfigManager module.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Utils.psm1 and 7ZipManager.psm1 from the parent 'Modules' directory.
                    Optionally uses PoShBackupValidator.psm1.
#>

# Explicitly import dependent modules from the parent 'Modules' directory.
# $PSScriptRoot here is Modules\ConfigManagement.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\7ZipManager.psm1") -Force -ErrorAction Stop
    # PoShBackupValidator.psm1 is imported conditionally within Import-AppConfiguration
} catch {
    Write-Error "ConfigLoader.psm1 FATAL: Could not import dependent modules (Utils.psm1 or 7ZipManager.psm1). Error: $($_.Exception.Message)"
    throw
}

#region --- Private Helper Function: Merge-DeepHashtable ---
# Merges two hashtables deeply. If a key exists in both and its values are hashtables,
# they are recursively merged. Otherwise, the override value takes precedence.
function Merge-DeepHashtable {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Base,
        [Parameter(Mandatory)]
        [hashtable]$Override
    )

    $merged = $Base.Clone() # Start with a clone of the base hashtable

    foreach ($key in $Override.Keys) {
        if ($merged.ContainsKey($key) -and $merged[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) {
            # If key exists in both and both values are hashtables, recurse
            $merged[$key] = Merge-DeepHashtable -Base $merged[$key] -Override $Override[$key]
        }
        else {
            # Otherwise, the override value replaces or adds the key
            $merged[$key] = $Override[$key]
        }
    }
    return $merged
}
#endregion

#region --- Exported Configuration Loading and Validation Function ---
function Import-AppConfiguration {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Loads and validates the PoSh-Backup application configuration from .psd1 files.
    .DESCRIPTION
        This function is responsible for loading the PoSh-Backup configuration.
        It first attempts to load the base configuration from 'Config\Default.psd1'.
        Then, it checks for a 'Config\User.psd1' file and, if found, merges its settings over
        the base configuration (user settings take precedence).
        If a specific configuration file path is provided via -UserSpecifiedPath, only that file is loaded.

        After loading, it performs basic validation (e.g., 7-Zip path, 'BackupTargets' structure)
        and can optionally invoke advanced schema validation if 'EnableAdvancedSchemaValidation'
        is set to $true in the loaded configuration and the 'PoShBackupValidator.psm1' module is available.
        It also handles the auto-detection of the 7-Zip executable path if not explicitly set.
    .PARAMETER UserSpecifiedPath
        Optional. The full path to a specific .psd1 configuration file to load.
        If provided, the default 'Config\Default.psd1' and 'Config\User.psd1' loading/merging logic is bypassed.
    .PARAMETER IsTestConfigMode
        Switch. Indicates if the script is running in -TestConfig mode. This affects some logging messages
        and validation behaviours (e.g., more verbose feedback on schema validation status).
    .PARAMETER MainScriptPSScriptRoot
        The $PSScriptRoot of the main PoSh-Backup.ps1 script. Used to resolve relative paths
        for default configuration files and modules.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function.
        Used for all logging within this function and passed to other functions it calls if they require logging.
    .EXAMPLE
        # $configLoadResult = Import-AppConfiguration -MainScriptPSScriptRoot $PSScriptRoot -Logger ${function:Write-LogMessage}
        # if ($configLoadResult.IsValid) { $Configuration = $configLoadResult.Configuration }
    .OUTPUTS
        System.Collections.Hashtable
        Returns a hashtable with keys: IsValid, Configuration, ActualPath, ErrorMessage, UserConfigLoaded, UserConfigPath.
    #>
    param (
        [string]$UserSpecifiedPath,
        [switch]$IsTestConfigMode,
        [string]$MainScriptPSScriptRoot,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    # PSSA: Logger parameter used via $LocalWriteLog
    & $LocalWriteLog -Message "ConfigLoader/Import-AppConfiguration: Logger active." -Level "DEBUG"

    $finalConfiguration = $null
    $userConfigLoadedSuccessfully = $false
    $primaryConfigPathForReturn = $null

    $defaultConfigDir = Join-Path -Path $MainScriptPSScriptRoot -ChildPath "Config"
    $defaultBaseConfigFileName = "Default.psd1"
    $defaultUserConfigFileName = "User.psd1"

    $defaultBaseConfigPath = Join-Path -Path $defaultConfigDir -ChildPath $defaultBaseConfigFileName
    $defaultUserConfigPath = Join-Path -Path $defaultConfigDir -ChildPath $defaultUserConfigFileName

    if (-not [string]::IsNullOrWhiteSpace($UserSpecifiedPath)) {
        & $LocalWriteLog -Message "`n[INFO] ConfigLoader: Using user-specified configuration file: '$($UserSpecifiedPath)'" -Level "INFO"
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
        $primaryConfigPathForReturn = $defaultBaseConfigPath
        & $LocalWriteLog -Message "`n[INFO] ConfigLoader: No -ConfigFile specified by user. Loading base configuration from: '$($defaultBaseConfigPath)'" -Level "INFO"
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

        & $LocalWriteLog -Message "[INFO] ConfigLoader: Checking for user override configuration at: '$($defaultUserConfigPath)'" -Level "INFO"
        if (Test-Path -LiteralPath $defaultUserConfigPath -PathType Leaf) {
            try {
                $loadedUserConfiguration = Import-PowerShellDataFile -LiteralPath $defaultUserConfigPath -ErrorAction Stop
                if ($null -ne $loadedUserConfiguration -and $loadedUserConfiguration -is [hashtable]) {
                    & $LocalWriteLog -Message "  - ConfigLoader: User override configuration '$defaultUserConfigPath' found and loaded successfully." -Level "SUCCESS"
                    & $LocalWriteLog -Message "  - ConfigLoader: Merging user configuration over base configuration..." -Level "DEBUG"
                    $finalConfiguration = Merge-DeepHashtable -Base $finalConfiguration -Override $loadedUserConfiguration
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

    $validationMessages = [System.Collections.Generic.List[string]]::new()

    # --- Basic Validation for BackupTargets ---
    if ($finalConfiguration.ContainsKey('BackupTargets')) {
        if ($finalConfiguration.BackupTargets -isnot [hashtable]) {
            $validationMessages.Add("ConfigLoader: Global 'BackupTargets' must be a Hashtable if defined.")
        }
        else {
            foreach ($targetName in $finalConfiguration.BackupTargets.Keys) {
                $targetInstance = $finalConfiguration.BackupTargets[$targetName]
                if ($targetInstance -isnot [hashtable]) {
                    $validationMessages.Add("ConfigLoader: BackupTarget instance '$targetName' must be a Hashtable.")
                    continue
                }
                if (-not $targetInstance.ContainsKey('Type') -or [string]::IsNullOrWhiteSpace($targetInstance.Type)) {
                    $validationMessages.Add("ConfigLoader: BackupTarget instance '$targetName' is missing a 'Type' or it is empty.")
                }
                if (-not $targetInstance.ContainsKey('TargetSpecificSettings')) {
                    $validationMessages.Add("ConfigLoader: BackupTarget instance '$targetName' is missing 'TargetSpecificSettings'.")
                }
            }
        }
    }

    # Advanced Schema Validation
    if ($validationMessages.Count -eq 0) {
        $enableAdvancedValidation = Get-ConfigValue -ConfigObject $finalConfiguration -Key 'EnableAdvancedSchemaValidation' -DefaultValue $false
        if ($enableAdvancedValidation -eq $true) {
            & $LocalWriteLog -Message "[INFO] ConfigLoader: Advanced Schema Validation enabled. Attempting PoShBackupValidator module..." -Level "INFO"
            try {
                Import-Module -Name (Join-Path -Path $MainScriptPSScriptRoot -ChildPath "Modules\PoShBackupValidator.psm1") -Force -ErrorAction Stop
                & $LocalWriteLog -Message "  - ConfigLoader: PoShBackupValidator module loaded. Performing schema validation..." -Level "DEBUG"
                Invoke-PoShBackupConfigValidation -ConfigurationToValidate $finalConfiguration -ValidationMessagesListRef ([ref]$validationMessages)
                if ($IsTestConfigMode.IsPresent -and $validationMessages.Count -eq 0) {
                    & $LocalWriteLog -Message "[SUCCESS] ConfigLoader: Advanced schema validation completed (no schema errors found)." -Level "CONFIG_TEST"
                }
                elseif ($validationMessages.Count -gt 0) {
                    & $LocalWriteLog -Message "[WARNING] ConfigLoader: Advanced schema validation found issues (see detailed errors below)." -Level "WARNING"
                }
            }
            catch {
                & $LocalWriteLog -Message "[WARNING] ConfigLoader: Could not load/execute PoShBackupValidator. Advanced schema validation skipped. Error: $($_.Exception.Message)" -Level "WARNING"
            }
        }
        else {
            if ($IsTestConfigMode.IsPresent) {
                & $LocalWriteLog -Message "[INFO] ConfigLoader: Advanced Schema Validation disabled ('EnableAdvancedSchemaValidation' is `$false or missing)." -Level "INFO"
            }
        }
    }

    $vssCachePath = Get-ConfigValue -ConfigObject $finalConfiguration -Key 'VSSMetadataCachePath' -DefaultValue "%TEMP%\diskshadow_cache_poshbackup.cab"
    try {
        $expandedVssCachePath = [System.Environment]::ExpandEnvironmentVariables($vssCachePath)
        $null = [System.IO.Path]::GetFullPath($expandedVssCachePath)
        $parentDir = Split-Path -Path $expandedVssCachePath
        if (($null -ne $parentDir) -and (-not ([string]::IsNullOrEmpty($parentDir))) -and (-not (Test-Path -Path $parentDir -PathType Container))) {
            if ($IsTestConfigMode.IsPresent) {
                & $LocalWriteLog -Message "[INFO] ConfigLoader: Note: Parent directory ('$parentDir') for 'VSSMetadataCachePath' ('$expandedVssCachePath') does not exist. Diskshadow may attempt creation." -Level "INFO"
            }
        }
    }
    catch {
        $validationMessages.Add("ConfigLoader: Global 'VSSMetadataCachePath' ('$vssCachePath') is invalid. Error: $($_.Exception.Message)")
    }

    $sevenZipPathFromConfigOriginal = Get-ConfigValue -ConfigObject $finalConfiguration -Key 'SevenZipPath' -DefaultValue $null
    $sevenZipPathSource = "configuration"

    if (-not ([string]::IsNullOrWhiteSpace($finalConfiguration.SevenZipPath)) -and (Test-Path -LiteralPath $finalConfiguration.SevenZipPath -PathType Leaf)) {
        if ($IsTestConfigMode.IsPresent) {
            & $LocalWriteLog -Message "  - ConfigLoader: Effective 7-Zip Path set to: '$($finalConfiguration.SevenZipPath)' (Source: $sevenZipPathSource)." -Level "CONFIG_TEST"
        }
    }
    else {
        $initialPathIsEmpty = [string]::IsNullOrWhiteSpace($sevenZipPathFromConfigOriginal)
        if (-not $initialPathIsEmpty) {
            & $LocalWriteLog -Message "[WARNING] ConfigLoader: Configured 'SevenZipPath' ('$sevenZipPathFromConfigOriginal') invalid/not found. Attempting auto-detection..." -Level "WARNING"
        }
        else {
            & $LocalWriteLog -Message "[INFO] ConfigLoader: 'SevenZipPath' empty/not set. Attempting auto-detection..." -Level "INFO"
        }
        
        $foundPath = Find-SevenZipExecutable -Logger $Logger # Find-SevenZipExecutable is from 7ZipManager.psm1
        if ($null -ne $foundPath) {
            $finalConfiguration.SevenZipPath = $foundPath
            $sevenZipPathSource = if ($initialPathIsEmpty) { "auto-detected (config was empty)" } else { "auto-detected (configured path was invalid)" }
            & $LocalWriteLog -Message "[INFO] ConfigLoader: Successfully auto-detected and using 7-Zip Path: '$foundPath'." -Level "INFO"
            if ($IsTestConfigMode.IsPresent) {
                & $LocalWriteLog -Message "  - ConfigLoader: Effective 7-Zip Path set to: '$foundPath' (Source: $sevenZipPathSource)." -Level "CONFIG_TEST"
            }
        }
        else {
            $errorMsg = if ($initialPathIsEmpty) {
                "CRITICAL: ConfigLoader: 'SevenZipPath' empty and auto-detection failed. PoSh-Backup cannot function."
            } else {
                "CRITICAL: ConfigLoader: Configured 'SevenZipPath' ('$sevenZipPathFromConfigOriginal') invalid, and auto-detection failed. PoSh-Backup cannot function."
            }
            if (-not $validationMessages.Contains($errorMsg)) { $validationMessages.Add($errorMsg) }
        }
    }

    if ([string]::IsNullOrWhiteSpace($finalConfiguration.SevenZipPath) -or (-not (Test-Path -LiteralPath $finalConfiguration.SevenZipPath -PathType Leaf))) {
        $criticalErrorMsg = "CRITICAL: ConfigLoader: Effective 'SevenZipPath' ('$($finalConfiguration.SevenZipPath)') is invalid or not found after all checks. PoSh-Backup requires a valid 7z.exe path."
        if (-not $validationMessages.Contains($criticalErrorMsg) -and `
                -not ($validationMessages | Where-Object { $_ -like "CRITICAL: ConfigLoader: 'SevenZipPath' empty and auto-detection failed*" }) -and `
                -not ($validationMessages | Where-Object { $_ -like "CRITICAL: ConfigLoader: Configured 'SevenZipPath' (*" })) {
            $validationMessages.Add($criticalErrorMsg)
        }
    }

    $defaultDateFormat = Get-ConfigValue -ConfigObject $finalConfiguration -Key 'DefaultArchiveDateFormat' -DefaultValue "yyyy-MMM-dd"
    if ($finalConfiguration.ContainsKey('DefaultArchiveDateFormat')) {
        if (-not ([string]$defaultDateFormat).Trim()) {
            $validationMessages.Add("ConfigLoader: Global 'DefaultArchiveDateFormat' is empty. Provide valid .NET date format string or remove key.")
        }
        else {
            try { Get-Date -Format $defaultDateFormat -ErrorAction Stop | Out-Null }
            catch { $validationMessages.Add("ConfigLoader: Global 'DefaultArchiveDateFormat' ('$defaultDateFormat') invalid. Error: $($_.Exception.Message)") }
        }
    }

    $pauseSetting = Get-ConfigValue -ConfigObject $finalConfiguration -Key 'PauseBeforeExit' -DefaultValue "OnFailureOrWarning"
    if ($finalConfiguration.ContainsKey('PauseBeforeExit')) {
        $validPauseOptions = @('true', 'false', 'always', 'never', 'onfailure', 'onwarning', 'onfailureorwarning')
        if (!($pauseSetting -is [bool] -or ($pauseSetting -is [string] -and $pauseSetting.ToString().ToLowerInvariant() -in $validPauseOptions))) {
            $validationMessages.Add("ConfigLoader: Global 'PauseBeforeExit' ('$pauseSetting') invalid. Allowed: Boolean or String (`'Always'`, `'Never'`, etc.).")
        }
    }

    if (($null -eq $finalConfiguration.BackupLocations -or $finalConfiguration.BackupLocations.Count -eq 0) -and -not $IsTestConfigMode.IsPresent `
            -and -not ($PSBoundParameters.ContainsKey('ListBackupLocations') -and $ListBackupLocations.IsPresent) `
            -and -not ($PSBoundParameters.ContainsKey('ListBackupSets') -and $ListBackupSets.IsPresent) ) {
        & $LocalWriteLog -Message "[WARNING] ConfigLoader: 'BackupLocations' empty. No jobs to run unless specified by -BackupLocationName." -Level "WARNING"
    }
    else {
        if ($null -ne $finalConfiguration.BackupLocations -and $finalConfiguration.BackupLocations -is [hashtable]) {
            foreach ($jobKey in $finalConfiguration.BackupLocations.Keys) {
                $jobConfig = $finalConfiguration.BackupLocations[$jobKey]
                if ($null -ne $jobConfig -and $jobConfig.ContainsKey('ArchiveExtension')) {
                    $userArchiveExt = $jobConfig['ArchiveExtension']
                    if (-not ($userArchiveExt -match "^\.[a-zA-Z0-9]+([a-zA-Z0-9\.]*[a-zA-Z0-9]+)?$")) {
                        $validationMessages.Add("ConfigLoader: BackupLocation '$jobKey': 'ArchiveExtension' ('$userArchiveExt') invalid. Must start with '.' (e.g., '.zip').")
                    }
                }
                if ($null -ne $jobConfig -and $jobConfig.ContainsKey('ArchiveDateFormat')) {
                    $jobDateFormat = $jobConfig['ArchiveDateFormat']
                    if (-not ([string]$jobDateFormat).Trim()) {
                        $validationMessages.Add("ConfigLoader: BackupLocation '$jobKey': 'ArchiveDateFormat' empty. Provide valid .NET date format string or remove key.")
                    }
                    else {
                        try { Get-Date -Format $jobDateFormat -ErrorAction Stop | Out-Null }
                        catch { $validationMessages.Add("ConfigLoader: BackupLocation '$jobKey': 'ArchiveDateFormat' ('$jobDateFormat') invalid. Error: $($_.Exception.Message)") }
                    }
                }
                if ($null -ne $jobConfig -and $jobConfig.ContainsKey('TargetNames')) {
                    if ($jobConfig.TargetNames -isnot [array] -and -not ($null -eq $jobConfig.TargetNames)) {
                        $validationMessages.Add("ConfigLoader: BackupLocation '$jobKey': 'TargetNames' must be an array of strings if defined.")
                    }
                    elseif ($jobConfig.TargetNames -is [array]) {
                        foreach ($targetNameRef in $jobConfig.TargetNames) {
                            if (-not ($targetNameRef -is [string]) -or [string]::IsNullOrWhiteSpace($targetNameRef)) {
                                $validationMessages.Add("ConfigLoader: BackupLocation '$jobKey': 'TargetNames' array contains an invalid (non-string or empty) target name reference.")
                                break
                            }
                            if (-not $finalConfiguration.ContainsKey('BackupTargets') -or `
                                    $finalConfiguration.BackupTargets -isnot [hashtable] -or `
                                    -not $finalConfiguration.BackupTargets.ContainsKey($targetNameRef)) {
                                $validationMessages.Add("ConfigLoader: BackupLocation '$jobKey': TargetName '$targetNameRef' referenced in 'TargetNames' is not defined in the global 'BackupTargets' section.")
                            }
                        }
                    }
                }
            }
        }
    }

    if ($finalConfiguration.ContainsKey('DefaultArchiveExtension')) {
        $defaultArchiveExtGlobal = Get-ConfigValue -ConfigObject $finalConfiguration -Key 'DefaultArchiveExtension' -DefaultValue ".7z"
        if (-not ($defaultArchiveExtGlobal -match "^\.[a-zA-Z0-9]+([a-zA-Z0-9\.]*[a-zA-Z0-9]+)?$")) {
            $validationMessages.Add("ConfigLoader: Global 'DefaultArchiveExtension' ('$defaultArchiveExtGlobal') invalid. Must start with '.'.")
        }
    }

    if ($finalConfiguration.ContainsKey('BackupSets') -and $finalConfiguration.BackupSets -is [hashtable]) {
        foreach ($setKey in $finalConfiguration.BackupSets.Keys) {
            $setConfig = $finalConfiguration.BackupSets[$setKey]
            if ($setConfig -is [hashtable]) {
                $jobNamesInSetArray = @(Get-ConfigValue -ConfigObject $setConfig -Key 'JobNames' -DefaultValue @())
                if ($jobNamesInSetArray.Count -gt 0) {
                    foreach ($jobNameInSetCandidate in $jobNamesInSetArray) {
                        if ([string]::IsNullOrWhiteSpace($jobNameInSetCandidate)) {
                            $validationMessages.Add("ConfigLoader: BackupSet '$setKey': Contains empty job name in 'JobNames'.")
                            continue
                        }
                        $jobNameInSet = $jobNameInSetCandidate.Trim()
                        if ($finalConfiguration.ContainsKey('BackupLocations') -and $finalConfiguration.BackupLocations -is [hashtable] -and -not $finalConfiguration.BackupLocations.ContainsKey($jobNameInSet)) {
                            $validationMessages.Add("ConfigLoader: BackupSet '$setKey': Job '$jobNameInSet' not defined in 'BackupLocations'.")
                        }
                        elseif (-not ($finalConfiguration.ContainsKey('BackupLocations') -and $finalConfiguration.BackupLocations -is [hashtable])) {
                            $validationMessages.Add("ConfigLoader: BackupSet '$setKey': Cannot validate Job '$jobNameInSet'; 'BackupLocations' missing/invalid.")
                        }
                    }
                }
            }
        }
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

Export-ModuleMember -Function Import-AppConfiguration, Merge-DeepHashtable
# Merge-DeepHashtable is exported because it's a general utility, though primarily used internally here.
# If it were strictly internal, it wouldn't need to be exported.
