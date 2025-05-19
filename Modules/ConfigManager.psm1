<#
.SYNOPSIS
    Manages the loading, validation, and interpretation of PoSh-Backup configurations.
    This includes merging default and user configurations, handling 7-Zip path detection,
    validating configuration structure, determining which jobs/sets to process, and
    calculating the effective configuration for individual backup jobs, including new
    Backup Target settings.

.DESCRIPTION
    The ConfigManager module is a central component for handling all aspects of PoSh-Backup's
    configuration. It ensures that configurations are loaded correctly, optionally validated
    against a schema, and provides functions to interpret the loaded configuration for
    the main script and operations module.

    Key Functions:
    - Import-AppConfiguration: Loads base (Default.psd1) and user (User.psd1) configurations,
      merges them, handles 7-Zip path auto-detection (via 7ZipManager.psm1), loads and performs
      basic validation on the new 'BackupTargets' global configuration section, and can invoke
      advanced schema validation (via PoShBackupValidator.psm1).
    - Get-JobsToProcess: Determines the list of backup jobs to execute based on command-line
      parameters or default configuration rules.
    - Get-PoShBackupJobEffectiveConfiguration: Calculates the final, effective settings for a
      single backup job by merging global settings, job-specific settings, and command-line
      overrides. This now includes resolving 'LocalRetentionCount', 'TargetNames' (and their
      corresponding full target configurations from 'BackupTargets'), and 'DeleteLocalArchiveAfterSuccessfulTransfer'.

    This module relies on Utils.psm1 (for Write-LogMessage, Get-ConfigValue),
    7ZipManager.psm1 (for Find-SevenZipExecutable), and optionally PoShBackupValidator.psm1.
    Functions requiring logging accept a -Logger parameter.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Added support for BackupTargets, TargetNames, LocalRetentionCount, DeleteLocalArchiveAfterSuccessfulTransfer.
    DateCreated:    17-May-2025
    LastModified:   19-May-2025
    Purpose:        Centralised configuration management for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Core PoSh-Backup modules: Utils.psm1, 7ZipManager.psm1.
                    Optional: PoShBackupValidator.psm1.
#>

# Explicitly import Utils.psm1 to ensure its functions are available, especially Get-ConfigValue.
# $PSScriptRoot here refers to the directory of ConfigManager.psm1 (Modules).
try {
    Import-Module -Name (Join-Path $PSScriptRoot "Utils.psm1") -Force -ErrorAction Stop
} catch {
    # If this fails, the module cannot function. Write-Error is appropriate as Write-LogMessage might not be available.
    Write-Error "ConfigManager.psm1 FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw # Re-throw to stop further execution of this module loading.
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
        [Parameter(Mandatory=$true)]
        [scriptblock]$Logger
    )

    # Defensive PSSA appeasement line by directly calling the logger for this initial message
    & $Logger -Message "Import-AppConfiguration: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue

    # Internal helper to use the passed-in logger consistently for other messages
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if ($null -ne $ForegroundColour) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    
    $finalConfiguration = $null
    $userConfigLoadedSuccessfully = $false
    $primaryConfigPathForReturn = $null

    $defaultConfigDir = Join-Path -Path $MainScriptPSScriptRoot -ChildPath "Config"
    $defaultBaseConfigFileName = "Default.psd1"
    $defaultUserConfigFileName = "User.psd1"

    $defaultBaseConfigPath = Join-Path -Path $defaultConfigDir -ChildPath $defaultBaseConfigFileName
    $defaultUserConfigPath = Join-Path -Path $defaultConfigDir -ChildPath $defaultUserConfigFileName

    if (-not [string]::IsNullOrWhiteSpace($UserSpecifiedPath)) {
        & $LocalWriteLog -Message "`n[INFO] ConfigManager: Using user-specified configuration file: '$($UserSpecifiedPath)'" -Level "INFO"
        $primaryConfigPathForReturn = $UserSpecifiedPath
        if (-not (Test-Path -LiteralPath $UserSpecifiedPath -PathType Leaf)) {
            & $LocalWriteLog -Message "FATAL: ConfigManager: Specified configuration file '$UserSpecifiedPath' not found." -Level "ERROR"
            return @{ IsValid = $false; ErrorMessage = "Configuration file not found at '$UserSpecifiedPath'." }
        }
        try {
            $finalConfiguration = Import-PowerShellDataFile -LiteralPath $UserSpecifiedPath -ErrorAction Stop
            & $LocalWriteLog -Message "  - ConfigManager: Configuration loaded successfully from '$UserSpecifiedPath'." -Level "SUCCESS"
        } catch {
            & $LocalWriteLog -Message "FATAL: ConfigManager: Could not load or parse specified configuration file '$UserSpecifiedPath'. Error: $($_.Exception.Message)" -Level "ERROR"
            return @{ IsValid = $false; ErrorMessage = "Failed to parse configuration file '$UserSpecifiedPath': $($_.Exception.Message)" }
        }
    } else {
        $primaryConfigPathForReturn = $defaultBaseConfigPath
        & $LocalWriteLog -Message "`n[INFO] ConfigManager: No -ConfigFile specified by user. Loading base configuration from: '$($defaultBaseConfigPath)'" -Level "INFO"
        if (-not (Test-Path -LiteralPath $defaultBaseConfigPath -PathType Leaf)) {
            & $LocalWriteLog -Message "FATAL: ConfigManager: Base configuration file '$defaultBaseConfigPath' not found. This file is required for default operation." -Level "ERROR"
            return @{ IsValid = $false; ErrorMessage = "Base configuration file '$defaultBaseConfigPath' not found." }
        }
        try {
            $loadedBaseConfiguration = Import-PowerShellDataFile -LiteralPath $defaultBaseConfigPath -ErrorAction Stop
            & $LocalWriteLog -Message "  - ConfigManager: Base configuration loaded successfully from '$defaultBaseConfigPath'." -Level "SUCCESS"
            $finalConfiguration = $loadedBaseConfiguration
        } catch {
            & $LocalWriteLog -Message "FATAL: ConfigManager: Could not load or parse base configuration file '$defaultBaseConfigPath'. Error: $($_.Exception.Message)" -Level "ERROR"
            return @{ IsValid = $false; ErrorMessage = "Failed to parse base configuration file '$defaultBaseConfigPath': $($_.Exception.Message)" }
        }

        & $LocalWriteLog -Message "[INFO] ConfigManager: Checking for user override configuration at: '$($defaultUserConfigPath)'" -Level "INFO"
        if (Test-Path -LiteralPath $defaultUserConfigPath -PathType Leaf) {
            try {
                $loadedUserConfiguration = Import-PowerShellDataFile -LiteralPath $defaultUserConfigPath -ErrorAction Stop
                if ($null -ne $loadedUserConfiguration -and $loadedUserConfiguration -is [hashtable]) {
                    & $LocalWriteLog -Message "  - ConfigManager: User override configuration '$defaultUserConfigPath' found and loaded successfully." -Level "SUCCESS"
                    & $LocalWriteLog -Message "  - ConfigManager: Merging user configuration over base configuration..." -Level "DEBUG"
                    $finalConfiguration = Merge-DeepHashtable -Base $finalConfiguration -Override $loadedUserConfiguration
                    $userConfigLoadedSuccessfully = $true
                    & $LocalWriteLog -Message "  - ConfigManager: User configuration merged successfully." -Level "SUCCESS"
                } else {
                    & $LocalWriteLog -Message "[WARNING] ConfigManager: User override configuration file '$defaultUserConfigPath' was found but did not load as a valid hashtable (it might be empty or malformed). Skipping user overrides." -Level "WARNING"
                }
            } catch {
                & $LocalWriteLog -Message "[WARNING] ConfigManager: Could not load or parse user override configuration file '$defaultUserConfigPath'. Error: $($_.Exception.Message). Using base configuration only." -Level "WARNING"
            }
        } else {
            & $LocalWriteLog -Message "  - ConfigManager: User override configuration file '$defaultUserConfigPath' not found. Using base configuration only." -Level "INFO"
        }
    }

    if ($null -eq $finalConfiguration -or -not ($finalConfiguration -is [hashtable])) {
        & $LocalWriteLog -Message "FATAL: ConfigManager: Final configuration object is null or not a valid hashtable after loading/merging attempts." -Level "ERROR"
        return @{ IsValid = $false; ErrorMessage = "Final configuration is not a valid hashtable." }
    }

    $validationMessages = [System.Collections.Generic.List[string]]::new()

    $enableAdvancedValidation = Get-ConfigValue -ConfigObject $finalConfiguration -Key 'EnableAdvancedSchemaValidation' -DefaultValue $false
    if ($enableAdvancedValidation -eq $true) {
        & $LocalWriteLog -Message "[INFO] ConfigManager: Advanced Schema Validation enabled. Attempting PoShBackupValidator module..." -Level "INFO"
        try {
            Import-Module -Name (Join-Path -Path $MainScriptPSScriptRoot -ChildPath "Modules\PoShBackupValidator.psm1") -Force -ErrorAction Stop
            & $LocalWriteLog -Message "  - ConfigManager: PoShBackupValidator module loaded. Performing schema validation..." -Level "DEBUG"
            Invoke-PoShBackupConfigValidation -ConfigurationToValidate $finalConfiguration -ValidationMessagesListRef ([ref]$validationMessages)
            if ($IsTestConfigMode.IsPresent -and $validationMessages.Count -eq 0) {
                 & $LocalWriteLog -Message "[SUCCESS] ConfigManager: Advanced schema validation completed (no schema errors found)." -Level "CONFIG_TEST"
            } elseif ($validationMessages.Count -gt 0) {
                 & $LocalWriteLog -Message "[WARNING] ConfigManager: Advanced schema validation found issues (see detailed errors below)." -Level "WARNING"
            }
        } catch {
            & $LocalWriteLog -Message "[WARNING] ConfigManager: Could not load/execute PoShBackupValidator. Advanced schema validation skipped. Error: $($_.Exception.Message)" -Level "WARNING"
        }
    } else {
        if ($IsTestConfigMode.IsPresent) {
            & $LocalWriteLog -Message "[INFO] ConfigManager: Advanced Schema Validation disabled ('EnableAdvancedSchemaValidation' is `$false or missing)." -Level "INFO"
        }
    }

    $vssCachePath = Get-ConfigValue -ConfigObject $finalConfiguration -Key 'VSSMetadataCachePath' -DefaultValue "%TEMP%\diskshadow_cache_poshbackup.cab"
    try {
        $expandedVssCachePath = [System.Environment]::ExpandEnvironmentVariables($vssCachePath)
        $null = [System.IO.Path]::GetFullPath($expandedVssCachePath)
        $parentDir = Split-Path -Path $expandedVssCachePath
        if ( ($null -ne $parentDir) -and (-not ([string]::IsNullOrEmpty($parentDir))) -and (-not (Test-Path -Path $parentDir -PathType Container)) ) {
             if ($IsTestConfigMode.IsPresent) {
                 & $LocalWriteLog -Message "[INFO] ConfigManager: Note: Parent directory ('$parentDir') for 'VSSMetadataCachePath' ('$expandedVssCachePath') does not exist. Diskshadow may attempt creation." -Level "INFO"
            }
        }
    } catch {
        $validationMessages.Add("ConfigManager: Global 'VSSMetadataCachePath' ('$vssCachePath') is invalid. Error: $($_.Exception.Message)")
    }

    $sevenZipPathFromConfigOriginal = Get-ConfigValue -ConfigObject $finalConfiguration -Key 'SevenZipPath' -DefaultValue $null
    $sevenZipPathSource = "configuration"

    if (-not ([string]::IsNullOrWhiteSpace($finalConfiguration.SevenZipPath)) -and (Test-Path -LiteralPath $finalConfiguration.SevenZipPath -PathType Leaf)) {
        if ($IsTestConfigMode.IsPresent) {
             & $LocalWriteLog -Message "  - ConfigManager: Effective 7-Zip Path set to: '$($finalConfiguration.SevenZipPath)' (Source: $sevenZipPathSource)." -Level "CONFIG_TEST"
        }
    } else {
        $initialPathIsEmpty = [string]::IsNullOrWhiteSpace($sevenZipPathFromConfigOriginal)
        if (-not $initialPathIsEmpty) {
            & $LocalWriteLog -Message "[WARNING] ConfigManager: Configured 'SevenZipPath' ('$sevenZipPathFromConfigOriginal') invalid/not found. Attempting auto-detection..." -Level "WARNING"
        } else {
            & $LocalWriteLog -Message "[INFO] ConfigManager: 'SevenZipPath' empty/not set. Attempting auto-detection..." -Level "INFO"
        }

        if (-not (Get-Command Find-SevenZipExecutable -ErrorAction SilentlyContinue)) {
            try {
                 Import-Module -Name (Join-Path $PSScriptRoot "7ZipManager.psm1") -Force -ErrorAction Stop
                 & $LocalWriteLog -Message "  - ConfigManager: Dynamically imported 7ZipManager.psm1 to find Find-SevenZipExecutable." -Level "DEBUG"
            } catch {
                $criticalErrorMsg = "CRITICAL: ConfigManager: Function 'Find-SevenZipExecutable' not available and could not load 7ZipManager.psm1. Error: $($_.Exception.Message)"
                & $LocalWriteLog -Message $criticalErrorMsg -Level ERROR
                if (-not $validationMessages.Contains($criticalErrorMsg)) { $validationMessages.Add($criticalErrorMsg) }
            }
        }
        
        if (Get-Command Find-SevenZipExecutable -ErrorAction SilentlyContinue) {
            $foundPath = Find-SevenZipExecutable -Logger $Logger
            if ($null -ne $foundPath) {
                $finalConfiguration.SevenZipPath = $foundPath
                $sevenZipPathSource = if ($initialPathIsEmpty) { "auto-detected (config was empty)" } else { "auto-detected (configured path was invalid)" }
                & $LocalWriteLog -Message "[INFO] ConfigManager: Successfully auto-detected and using 7-Zip Path: '$foundPath'." -Level "INFO"
                if ($IsTestConfigMode.IsPresent) {
                    & $LocalWriteLog -Message "  - ConfigManager: Effective 7-Zip Path set to: '$foundPath' (Source: $sevenZipPathSource)." -Level "CONFIG_TEST"
                }
            } else {
                $errorMsg = if ($initialPathIsEmpty) {
                    "CRITICAL: ConfigManager: 'SevenZipPath' empty and auto-detection failed. PoSh-Backup cannot function."
                } else {
                    "CRITICAL: ConfigManager: Configured 'SevenZipPath' ('$sevenZipPathFromConfigOriginal') invalid, and auto-detection failed. PoSh-Backup cannot function."
                }
                if (-not $validationMessages.Contains($errorMsg)) { $validationMessages.Add($errorMsg) }
            }
        } else {
             $criticalErrorMsg = "CRITICAL: ConfigManager: Function 'Find-SevenZipExecutable' (from 7ZipManager.psm1) is definitively not available. Cannot auto-detect 7-Zip path."
            & $LocalWriteLog -Message $criticalErrorMsg -Level ERROR
            if (-not $validationMessages.Contains($criticalErrorMsg)) { $validationMessages.Add($criticalErrorMsg) }
        }
    }

    if ([string]::IsNullOrWhiteSpace($finalConfiguration.SevenZipPath) -or (-not (Test-Path -LiteralPath $finalConfiguration.SevenZipPath -PathType Leaf))) {
        $criticalErrorMsg = "CRITICAL: ConfigManager: Effective 'SevenZipPath' ('$($finalConfiguration.SevenZipPath)') is invalid or not found after all checks. PoSh-Backup requires a valid 7z.exe path."
        if (-not $validationMessages.Contains($criticalErrorMsg) -and `
            -not ($validationMessages | Where-Object {$_ -like "CRITICAL: ConfigManager: 'SevenZipPath' empty and auto-detection failed*"}) -and `
            -not ($validationMessages | Where-Object {$_ -like "CRITICAL: ConfigManager: Configured 'SevenZipPath' (*"})) {
             $validationMessages.Add($criticalErrorMsg)
        }
    }

    # --- Basic Validation for BackupTargets ---
    if ($finalConfiguration.ContainsKey('BackupTargets')) {
        if ($finalConfiguration.BackupTargets -isnot [hashtable]) {
            $validationMessages.Add("ConfigManager: Global 'BackupTargets' must be a Hashtable if defined.")
        } else {
            foreach ($targetName in $finalConfiguration.BackupTargets.Keys) {
                $targetInstance = $finalConfiguration.BackupTargets[$targetName]
                if ($targetInstance -isnot [hashtable]) {
                    $validationMessages.Add("ConfigManager: BackupTarget instance '$targetName' must be a Hashtable.")
                    continue
                }
                if (-not $targetInstance.ContainsKey('Type') -or [string]::IsNullOrWhiteSpace($targetInstance.Type)) {
                    $validationMessages.Add("ConfigManager: BackupTarget instance '$targetName' is missing a 'Type' or it is empty.")
                }
                if (-not $targetInstance.ContainsKey('TargetSpecificSettings') -or $targetInstance.TargetSpecificSettings -isnot [hashtable]) {
                    $validationMessages.Add("ConfigManager: BackupTarget instance '$targetName' is missing 'TargetSpecificSettings' or it is not a Hashtable.")
                }
                # Further validation of TargetSpecificSettings would be done by PoShBackupValidator.psm1 or by the target provider itself.
            }
        }
    } # No 'else' needed here; BackupTargets is optional.

    $defaultDateFormat = Get-ConfigValue -ConfigObject $finalConfiguration -Key 'DefaultArchiveDateFormat' -DefaultValue "yyyy-MMM-dd"
    if ($finalConfiguration.ContainsKey('DefaultArchiveDateFormat')) {
        if (-not ([string]$defaultDateFormat).Trim()) {
            $validationMessages.Add("ConfigManager: Global 'DefaultArchiveDateFormat' is empty. Provide valid .NET date format string or remove key.")
        } else {
            try { Get-Date -Format $defaultDateFormat -ErrorAction Stop | Out-Null }
            catch { $validationMessages.Add("ConfigManager: Global 'DefaultArchiveDateFormat' ('$defaultDateFormat') invalid. Error: $($_.Exception.Message)") }
        }
    }

    $pauseSetting = Get-ConfigValue -ConfigObject $finalConfiguration -Key 'PauseBeforeExit' -DefaultValue "OnFailureOrWarning"
    if ($finalConfiguration.ContainsKey('PauseBeforeExit')) {
        $validPauseOptions = @('true', 'false', 'always', 'never', 'onfailure', 'onwarning', 'onfailureorwarning')
        if (!($pauseSetting -is [bool] -or ($pauseSetting -is [string] -and $pauseSetting.ToString().ToLowerInvariant() -in $validPauseOptions))) {
            $validationMessages.Add("ConfigManager: Global 'PauseBeforeExit' ('$pauseSetting') invalid. Allowed: Boolean or String (`'Always'`, `'Never'`, etc.).")
        }
    }

    if (($null -eq $finalConfiguration.BackupLocations -or $finalConfiguration.BackupLocations.Count -eq 0) -and -not $IsTestConfigMode.IsPresent `
        -and -not ($PSBoundParameters.ContainsKey('ListBackupLocations') -and $ListBackupLocations.IsPresent) `
        -and -not ($PSBoundParameters.ContainsKey('ListBackupSets') -and $ListBackupSets.IsPresent) ) {
         & $LocalWriteLog -Message "[WARNING] ConfigManager: 'BackupLocations' empty. No jobs to run unless specified by -BackupLocationName." -Level "WARNING"
    } else {
        if ($null -ne $finalConfiguration.BackupLocations -and $finalConfiguration.BackupLocations -is [hashtable]) {
            foreach ($jobKey in $finalConfiguration.BackupLocations.Keys) {
                $jobConfig = $finalConfiguration.BackupLocations[$jobKey]
                if ($null -ne $jobConfig -and $jobConfig.ContainsKey('ArchiveExtension')) {
                    $userArchiveExt = $jobConfig['ArchiveExtension']
                     if (-not ($userArchiveExt -match "^\.[a-zA-Z0-9]+([a-zA-Z0-9\.]*[a-zA-Z0-9]+)?$")) {
                        $validationMessages.Add("ConfigManager: BackupLocation '$jobKey': 'ArchiveExtension' ('$userArchiveExt') invalid. Must start with '.' (e.g., '.zip').")
                    }
                }
                if ($null -ne $jobConfig -and $jobConfig.ContainsKey('ArchiveDateFormat')) {
                    $jobDateFormat = $jobConfig['ArchiveDateFormat']
                    if (-not ([string]$jobDateFormat).Trim()) {
                        $validationMessages.Add("ConfigManager: BackupLocation '$jobKey': 'ArchiveDateFormat' empty. Provide valid .NET date format string or remove key.")
                    } else {
                        try { Get-Date -Format $jobDateFormat -ErrorAction Stop | Out-Null }
                        catch { $validationMessages.Add("ConfigManager: BackupLocation '$jobKey': 'ArchiveDateFormat' ('$jobDateFormat') invalid. Error: $($_.Exception.Message)") }
                    }
                }
                # Validate TargetNames in each job
                if ($null -ne $jobConfig -and $jobConfig.ContainsKey('TargetNames')) {
                    if ($jobConfig.TargetNames -isnot [array] -and -not ($null -eq $jobConfig.TargetNames)) { # Allow null for optional, but if present must be array
                        $validationMessages.Add("ConfigManager: BackupLocation '$jobKey': 'TargetNames' must be an array of strings if defined.")
                    } elseif ($jobConfig.TargetNames -is [array]) {
                        foreach ($targetNameRef in $jobConfig.TargetNames) {
                            if (-not ($targetNameRef -is [string]) -or [string]::IsNullOrWhiteSpace($targetNameRef)) {
                                $validationMessages.Add("ConfigManager: BackupLocation '$jobKey': 'TargetNames' array contains an invalid (non-string or empty) target name reference.")
                                break # Stop checking this array further
                            }
                            # Check if the referenced target name actually exists in GlobalConfig.BackupTargets
                            if (-not $finalConfiguration.ContainsKey('BackupTargets') -or `
                                $finalConfiguration.BackupTargets -isnot [hashtable] -or `
                                -not $finalConfiguration.BackupTargets.ContainsKey($targetNameRef)) {
                                $validationMessages.Add("ConfigManager: BackupLocation '$jobKey': TargetName '$targetNameRef' referenced in 'TargetNames' is not defined in the global 'BackupTargets' section.")
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
            $validationMessages.Add("ConfigManager: Global 'DefaultArchiveExtension' ('$defaultArchiveExtGlobal') invalid. Must start with '.'.")
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
                            $validationMessages.Add("ConfigManager: BackupSet '$setKey': Contains empty job name in 'JobNames'.")
                            continue
                        }
                        $jobNameInSet = $jobNameInSetCandidate.Trim()
                        if ($finalConfiguration.ContainsKey('BackupLocations') -and $finalConfiguration.BackupLocations -is [hashtable] -and -not $finalConfiguration.BackupLocations.ContainsKey($jobNameInSet)) {
                            $validationMessages.Add("ConfigManager: BackupSet '$setKey': Job '$jobNameInSet' not defined in 'BackupLocations'.")
                        } elseif (-not ($finalConfiguration.ContainsKey('BackupLocations') -and $finalConfiguration.BackupLocations -is [hashtable])) {
                            $validationMessages.Add("ConfigManager: BackupSet '$setKey': Cannot validate Job '$jobNameInSet'; 'BackupLocations' missing/invalid.")
                        }
                    }
                }
            }
        }
    }

    if ($validationMessages.Count -gt 0) {
        & $LocalWriteLog -Message "ConfigManager: Configuration validation FAILED with errors/warnings:" -Level "ERROR"
        ($validationMessages | Select-Object -Unique) | ForEach-Object { & $LocalWriteLog -Message "  - $_" -Level "ERROR" }
        return @{ IsValid = $false; ErrorMessage = "Configuration validation failed. See logs for details." }
    }

    return @{
        IsValid = $true;
        Configuration = $finalConfiguration;
        ActualPath = $primaryConfigPathForReturn;
        UserConfigLoaded = $userConfigLoadedSuccessfully;
        UserConfigPath = if($userConfigLoadedSuccessfully -or (Test-Path -LiteralPath $defaultUserConfigPath -PathType Leaf)) {$defaultUserConfigPath} else {$null}
    }
}
#endregion

#region --- Exported Job/Set Resolution Function ---
function Get-JobsToProcess {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Determines the list of backup jobs to process based on command-line parameters and configuration.
    .DESCRIPTION
        This function resolves which backup jobs should be run.
        - If -RunSet is specified, it attempts to find the set and returns its defined jobs.
        - If -BackupLocationName is specified (and -RunSet is not), it returns that single job.
        - If neither is specified:
            - If only one job is defined in the configuration, it returns that job.
            - Otherwise (zero or multiple jobs defined), it returns an error indicating the ambiguity.
        It also determines the 'StopSetOnError' policy for the resolved set.
    .PARAMETER Config
        The loaded PoSh-Backup configuration hashtable.
    .PARAMETER SpecifiedJobName
        The job name provided via the -BackupLocationName command-line parameter, if any.
    .PARAMETER SpecifiedSetName
        The set name provided via the -RunSet command-line parameter, if any.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function.
    .OUTPUTS
        System.Collections.Hashtable
        Returns a hashtable with keys: Success, JobsToRun, SetName, StopSetOnErrorPolicy, ErrorMessage.
    #>
    param(
        [hashtable]$Config,
        [string]$SpecifiedJobName,
        [string]$SpecifiedSetName,
        [Parameter(Mandatory=$true)] 
        [scriptblock]$Logger
    )

    # Defensive PSSA appeasement line by directly calling the logger for this initial message
    & $Logger -Message "Get-JobsToProcess: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue

    # Internal helper to use the passed-in logger consistently for other messages
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if ($null -ne $ForegroundColour) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    
    $jobsToRun = [System.Collections.Generic.List[string]]::new()
    $setName = $null
    $stopSetOnErrorPolicy = $true # Default for StopSetOnError is "StopSet", hence $true

    if (-not [string]::IsNullOrWhiteSpace($SpecifiedSetName)) {
        & $LocalWriteLog -Message "`n[INFO] ConfigManager: Backup Set specified by user: '$SpecifiedSetName'" -Level "INFO"
        if ($Config.ContainsKey('BackupSets') -and $Config['BackupSets'] -is [hashtable] -and $Config['BackupSets'].ContainsKey($SpecifiedSetName)) {
            $setDefinition = $Config['BackupSets'][$SpecifiedSetName]
            $setName = $SpecifiedSetName
            $jobNamesInSet = @(Get-ConfigValue -ConfigObject $setDefinition -Key 'JobNames' -DefaultValue @())

            if ($jobNamesInSet.Count -gt 0) {
                $jobNamesInSet | ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_)) {$jobsToRun.Add($_.Trim())} }
                if ($jobsToRun.Count -eq 0) {
                     return @{ Success = $false; ErrorMessage = "ConfigManager: Backup Set '$setName' defined but 'JobNames' list is empty/invalid." }
                }
                $stopSetOnErrorPolicy = if (((Get-ConfigValue -ConfigObject $setDefinition -Key 'OnErrorInJob' -DefaultValue "StopSet") -as [string]).ToUpperInvariant() -eq "CONTINUESET") { $false } else { $true }
                & $LocalWriteLog -Message "  - ConfigManager: Jobs in set '$setName': $($jobsToRun -join ', ')" -Level "INFO"
                & $LocalWriteLog -Message "  - ConfigManager: Policy for set on job failure: $(if($stopSetOnErrorPolicy){'StopSet'}else{'ContinueSet'})" -Level "INFO"
            } else {
                return @{ Success = $false; ErrorMessage = "ConfigManager: Backup Set '$setName' defined but has no 'JobNames' listed." }
            }
        } else {
            $availableSetsMessage = "No Backup Sets defined."
            if ($Config.ContainsKey('BackupSets') -and $Config['BackupSets'] -is [hashtable] -and $Config['BackupSets'].Keys.Count -gt 0) {
                $setNameList = $Config['BackupSets'].Keys | Sort-Object | ForEach-Object { "`"$_`"" }
                $availableSetsMessage = "Available Backup Sets: $($setNameList -join ', ')."
            }
            return @{ Success = $false; ErrorMessage = "ConfigManager: Specified Backup Set '$SpecifiedSetName' not found. $availableSetsMessage" }
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($SpecifiedJobName)) {
        if ($Config.ContainsKey('BackupLocations') -and $Config['BackupLocations'] -is [hashtable] -and $Config['BackupLocations'].ContainsKey($SpecifiedJobName)) {
            $jobsToRun.Add($SpecifiedJobName)
            & $LocalWriteLog -Message "`n[INFO] ConfigManager: Single Backup Location specified by user: '$SpecifiedJobName'" -Level "INFO"
        } else {
            $availableJobsMessage = "No Backup Locations defined."
            if ($Config.ContainsKey('BackupLocations') -and $Config['BackupLocations'] -is [hashtable] -and $Config['BackupLocations'].Keys.Count -gt 0) {
                $jobNameList = $Config['BackupLocations'].Keys | Sort-Object | ForEach-Object { "`"$_`"" }
                $availableJobsMessage = "Available Backup Locations: $($jobNameList -join ', ')."
            }
            return @{ Success = $false; ErrorMessage = "ConfigManager: Specified BackupLocationName '$SpecifiedJobName' not found. $availableJobsMessage" }
        }
    } else {
        $jobCount = 0
        if ($Config.ContainsKey('BackupLocations') -and $Config['BackupLocations'] -is [hashtable]) {
            $jobCount = $Config['BackupLocations'].Count
        }

        if ($jobCount -eq 1) {
            $singleJobKey = ($Config['BackupLocations'].Keys | Select-Object -First 1)
            $jobsToRun.Add($singleJobKey)
            & $LocalWriteLog -Message "`n[INFO] ConfigManager: No job/set specified. Auto-selected single defined Backup Location: '$singleJobKey'" -Level "INFO"
        } elseif ($jobCount -eq 0) {
            return @{ Success = $false; ErrorMessage = "ConfigManager: No job/set specified, and no Backup Locations defined. Nothing to back up." }
        } else {
            $errorMessage = "ConfigManager: No job/set specified. Multiple Backup Locations defined. Please choose one:"
            $availableJobsMessage = "`n  Available Backup Locations (-BackupLocationName ""Job Name""):"
            if ($Config.ContainsKey('BackupLocations') -and $Config['BackupLocations'] -is [hashtable] -and $Config['BackupLocations'].Keys.Count -gt 0) {
                $Config['BackupLocations'].Keys | Sort-Object | ForEach-Object { $availableJobsMessage += "`n    - $_" }
            } else { $availableJobsMessage += "`n    (Error: No jobs found despite jobCount > 1)"}
            $availableSetsMessage = "`n  Available Backup Sets (-RunSet ""Set Name""):"
            if ($Config.ContainsKey('BackupSets') -and $Config['BackupSets'] -is [hashtable] -and $Config['BackupSets'].Keys.Count -gt 0) {
                $Config['BackupSets'].Keys | Sort-Object | ForEach-Object { $availableSetsMessage += "`n    - $_" }
            } else { $availableSetsMessage += "`n    (None defined)"}
            return @{ Success = $false; ErrorMessage = "$($errorMessage)$($availableJobsMessage)$($availableSetsMessage)" }
        }
    }

    if ($jobsToRun.Count -eq 0) {
        return @{ Success = $false; ErrorMessage = "ConfigManager: No valid backup jobs determined after parsing parameters/config." }
    }

    return @{
        Success = $true;
        JobsToRun = $jobsToRun;
        SetName = $setName;
        StopSetOnErrorPolicy = $stopSetOnErrorPolicy
    }
}
#endregion

#region --- Exported Function: Get Effective Job Configuration ---
function Get-PoShBackupJobEffectiveConfiguration {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Gathers the effective configuration for a single backup job by merging global,
        job-specific, and command-line override settings, including Backup Target resolution.
    .DESCRIPTION
        This function takes a specific job's raw configuration, the global configuration,
        and any command-line overrides, then resolves the final settings that will be
        used for that job. It prioritizes settings in the order: CLI overrides, then
        job-specific settings, then global settings.
        It now also resolves 'TargetNames' specified in the job configuration by looking up
        the full definitions of those targets in the global 'BackupTargets' section.
    .PARAMETER JobConfig
        A hashtable containing the specific configuration settings for this backup job.
    .PARAMETER GlobalConfig
        A hashtable containing the global configuration settings for PoSh-Backup, including 'BackupTargets'.
    .PARAMETER CliOverrides
        A hashtable containing command-line parameter overrides.
    .PARAMETER JobReportDataRef
        A reference ([ref]) to an ordered hashtable. This function populates some initial
        report data based on the effective settings.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function.
    .OUTPUTS
        System.Collections.Hashtable
        A hashtable representing the effective configuration for the job, including an array
        of 'ResolvedTargetInstances' if 'TargetNames' were specified.
    #>
    param(
        [Parameter(Mandatory)] [hashtable]$JobConfig,
        [Parameter(Mandatory)] [hashtable]$GlobalConfig,
        [Parameter(Mandatory)] [hashtable]$CliOverrides,
        [Parameter(Mandatory)] [ref]$JobReportDataRef,
        [Parameter(Mandatory=$true)] 
        [scriptblock]$Logger
    )

    # Defensive PSSA appeasement line by directly calling the logger for this initial message
    & $Logger -Message "Get-PoShBackupJobEffectiveConfiguration: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue
    
    $effectiveConfig = @{}
    $reportData = $JobReportDataRef.Value 

    $effectiveConfig.OriginalSourcePath = $JobConfig.Path
    $effectiveConfig.BaseFileName       = $JobConfig.Name
    $reportData.JobConfiguration        = $JobConfig 

    $effectiveConfig.DestinationDir = Get-ConfigValue -ConfigObject $JobConfig -Key 'DestinationDir' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultDestinationDir' -DefaultValue $null)
    
    # --- New Target-related settings ---
    $effectiveConfig.TargetNames = @(Get-ConfigValue -ConfigObject $JobConfig -Key 'TargetNames' -DefaultValue @())
    $effectiveConfig.DeleteLocalArchiveAfterSuccessfulTransfer = Get-ConfigValue -ConfigObject $JobConfig -Key 'DeleteLocalArchiveAfterSuccessfulTransfer' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DeleteLocalArchiveAfterSuccessfulTransfer' -DefaultValue $true)
    $effectiveConfig.ResolvedTargetInstances = [System.Collections.Generic.List[hashtable]]::new()

    if ($effectiveConfig.TargetNames.Count -gt 0) {
        $globalBackupTargets = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'BackupTargets' -DefaultValue @{}
        if (-not ($globalBackupTargets -is [hashtable])) {
            & $Logger -Message "[WARNING] ConfigManager: Global 'BackupTargets' configuration is missing or not a hashtable. Cannot resolve target names for job." -Level WARNING
        } else {
            foreach ($targetNameRef in $effectiveConfig.TargetNames) {
                if ($globalBackupTargets.ContainsKey($targetNameRef)) {
                    $targetInstanceConfig = $globalBackupTargets[$targetNameRef]
                    if ($targetInstanceConfig -is [hashtable]) {
                        # Add the original reference name to the instance config for easier identification later
                        $targetInstanceConfigWithName = $targetInstanceConfig.Clone() # Clone to avoid modifying global config
                        $targetInstanceConfigWithName['_TargetInstanceName_'] = $targetNameRef 
                        $effectiveConfig.ResolvedTargetInstances.Add($targetInstanceConfigWithName)
                        & $Logger -Message "  - ConfigManager: Resolved Target Instance '$targetNameRef' (Type: $($targetInstanceConfig.Type)) for job." -Level DEBUG
                    } else {
                        & $Logger -Message "[WARNING] ConfigManager: Definition for TargetName '$targetNameRef' in 'BackupTargets' is not a valid hashtable. Skipping this target for job." -Level WARNING
                    }
                } else {
                    & $Logger -Message "[WARNING] ConfigManager: TargetName '$targetNameRef' (specified in job's TargetNames) not found in global 'BackupTargets'. Skipping this target for job." -Level WARNING
                }
            }
        }
    }
    # --- End New Target-related settings ---

    $effectiveConfig.LocalRetentionCount = Get-ConfigValue -ConfigObject $JobConfig -Key 'LocalRetentionCount' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultRetentionCount' -DefaultValue 3) # DefaultRetentionCount is legacy, should be LocalRetentionCount globally too eventually
    if ($effectiveConfig.LocalRetentionCount -lt 0) { $effectiveConfig.LocalRetentionCount = 0 } 
    $effectiveConfig.DeleteToRecycleBin = Get-ConfigValue -ConfigObject $JobConfig -Key 'DeleteToRecycleBin' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultDeleteToRecycleBin' -DefaultValue $false)
    $effectiveConfig.RetentionConfirmDelete = Get-ConfigValue -ConfigObject $JobConfig -Key 'RetentionConfirmDelete' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'RetentionConfirmDelete' -DefaultValue $true)

    $effectiveConfig.ArchivePasswordMethod = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordMethod' -DefaultValue "None"
    $effectiveConfig.CredentialUserNameHint = Get-ConfigValue -ConfigObject $JobConfig -Key 'CredentialUserNameHint' -DefaultValue "BackupUser"
    $effectiveConfig.ArchivePasswordSecretName = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordSecretName' -DefaultValue $null
    $effectiveConfig.ArchivePasswordVaultName = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordVaultName' -DefaultValue $null
    $effectiveConfig.ArchivePasswordSecureStringPath = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordSecureStringPath' -DefaultValue $null
    $effectiveConfig.ArchivePasswordPlainText = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordPlainText' -DefaultValue $null
    $effectiveConfig.UsePassword = Get-ConfigValue -ConfigObject $JobConfig -Key 'UsePassword' -DefaultValue $false

    $effectiveConfig.HideSevenZipOutput = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'HideSevenZipOutput' -DefaultValue $true

    $effectiveConfig.JobArchiveType = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchiveType' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultArchiveType' -DefaultValue "-t7z")
    $effectiveConfig.JobArchiveExtension = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchiveExtension' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultArchiveExtension' -DefaultValue ".7z")
    $effectiveConfig.JobArchiveDateFormat = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchiveDateFormat' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultArchiveDateFormat' -DefaultValue "yyyy-MMM-dd")

    $effectiveConfig.JobCompressionLevel = Get-ConfigValue -ConfigObject $JobConfig -Key 'CompressionLevel' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultCompressionLevel' -DefaultValue "-mx=7")
    $effectiveConfig.JobCompressionMethod = Get-ConfigValue -ConfigObject $JobConfig -Key 'CompressionMethod' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultCompressionMethod' -DefaultValue "-m0=LZMA2")
    $effectiveConfig.JobDictionarySize = Get-ConfigValue -ConfigObject $JobConfig -Key 'DictionarySize' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultDictionarySize' -DefaultValue "-md=128m")
    $effectiveConfig.JobWordSize = Get-ConfigValue -ConfigObject $JobConfig -Key 'WordSize' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultWordSize' -DefaultValue "-mfb=64")
    $effectiveConfig.JobSolidBlockSize = Get-ConfigValue -ConfigObject $JobConfig -Key 'SolidBlockSize' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultSolidBlockSize' -DefaultValue "-ms=16g")
    $effectiveConfig.JobCompressOpenFiles = Get-ConfigValue -ConfigObject $JobConfig -Key 'CompressOpenFiles' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultCompressOpenFiles' -DefaultValue $true)
    $effectiveConfig.JobAdditionalExclusions = @(Get-ConfigValue -ConfigObject $JobConfig -Key 'AdditionalExclusions' -DefaultValue @())

    $_globalConfigThreads  = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultThreadCount' -DefaultValue 0
    $_jobSpecificThreadsToUse = Get-ConfigValue -ConfigObject $JobConfig -Key 'ThreadsToUse' -DefaultValue 0
    $_threadsFor7Zip = if ($_jobSpecificThreadsToUse -gt 0) { $_jobSpecificThreadsToUse } elseif ($_globalConfigThreads -gt 0) { $_globalConfigThreads } else { 0 } 
    $effectiveConfig.ThreadsSetting = if ($_threadsFor7Zip -gt 0) { "-mmt=$($_threadsFor7Zip)"} else {"-mmt"} 

    $effectiveConfig.JobEnableVSS = if ($CliOverrides.UseVSS) { $true } else { Get-ConfigValue -ConfigObject $JobConfig -Key 'EnableVSS' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'EnableVSS' -DefaultValue $false) }
    $effectiveConfig.JobVSSContextOption = Get-ConfigValue -ConfigObject $JobConfig -Key 'VSSContextOption' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultVSSContextOption' -DefaultValue "Persistent NoWriters")
    $_vssCachePathFromConfig = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'VSSMetadataCachePath' -DefaultValue "%TEMP%\diskshadow_cache_poshbackup.cab"
    $effectiveConfig.VSSMetadataCachePath = [System.Environment]::ExpandEnvironmentVariables($_vssCachePathFromConfig)
    $effectiveConfig.VSSPollingTimeoutSeconds = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'VSSPollingTimeoutSeconds' -DefaultValue 120
    $effectiveConfig.VSSPollingIntervalSeconds = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'VSSPollingIntervalSeconds' -DefaultValue 5

    $effectiveConfig.JobEnableRetries = if ($CliOverrides.EnableRetries) { $true } else { Get-ConfigValue -ConfigObject $JobConfig -Key 'EnableRetries' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'EnableRetries' -DefaultValue $true) }
    $effectiveConfig.JobMaxRetryAttempts = Get-ConfigValue -ConfigObject $JobConfig -Key 'MaxRetryAttempts' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'MaxRetryAttempts' -DefaultValue 3)
    $effectiveConfig.JobRetryDelaySeconds = Get-ConfigValue -ConfigObject $JobConfig -Key 'RetryDelaySeconds' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'RetryDelaySeconds' -DefaultValue 60)

    if ($null -ne $CliOverrides.TreatSevenZipWarningsAsSuccess) {
        $effectiveConfig.TreatSevenZipWarningsAsSuccess = $CliOverrides.TreatSevenZipWarningsAsSuccess
    } else {
        $effectiveConfig.TreatSevenZipWarningsAsSuccess = Get-ConfigValue -ConfigObject $JobConfig -Key 'TreatSevenZipWarningsAsSuccess' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'TreatSevenZipWarningsAsSuccess' -DefaultValue $false)
    }
    $reportData.TreatSevenZipWarningsAsSuccess = $effectiveConfig.TreatSevenZipWarningsAsSuccess

    $effectiveConfig.JobSevenZipProcessPriority = if (-not [string]::IsNullOrWhiteSpace($CliOverrides.SevenZipPriority)) {
        $CliOverrides.SevenZipPriority
    } else {
        Get-ConfigValue -ConfigObject $JobConfig -Key 'SevenZipProcessPriority' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultSevenZipProcessPriority' -DefaultValue "Normal")
    }

    $effectiveConfig.JobTestArchiveAfterCreation = if ($CliOverrides.TestArchive) { $true } else { Get-ConfigValue -ConfigObject $JobConfig -Key 'TestArchiveAfterCreation' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultTestArchiveAfterCreation' -DefaultValue $false) }

    $effectiveConfig.JobMinimumRequiredFreeSpaceGB = Get-ConfigValue -ConfigObject $JobConfig -Key 'MinimumRequiredFreeSpaceGB' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'MinimumRequiredFreeSpaceGB' -DefaultValue 0)
    $effectiveConfig.JobExitOnLowSpace = Get-ConfigValue -ConfigObject $JobConfig -Key 'ExitOnLowSpaceIfBelowMinimum' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'ExitOnLowSpaceIfBelowMinimum' -DefaultValue $false)

    $effectiveConfig.PreBackupScriptPath = Get-ConfigValue -ConfigObject $JobConfig -Key 'PreBackupScriptPath' -DefaultValue $null
    $effectiveConfig.PostBackupScriptOnSuccessPath = Get-ConfigValue -ConfigObject $JobConfig -Key 'PostBackupScriptOnSuccessPath' -DefaultValue $null
    $effectiveConfig.PostBackupScriptOnFailurePath = Get-ConfigValue -ConfigObject $JobConfig -Key 'PostBackupScriptOnFailurePath' -DefaultValue $null
    $effectiveConfig.PostBackupScriptAlwaysPath = Get-ConfigValue -ConfigObject $JobConfig -Key 'PostBackupScriptAlwaysPath' -DefaultValue $null

    $reportData.SourcePath = if ($effectiveConfig.OriginalSourcePath -is [array]) {$effectiveConfig.OriginalSourcePath} else {@($effectiveConfig.OriginalSourcePath)}
    $reportData.VSSUsed = $effectiveConfig.JobEnableVSS 
    $reportData.RetriesEnabled = $effectiveConfig.JobEnableRetries
    $reportData.ArchiveTested = $effectiveConfig.JobTestArchiveAfterCreation 
    $reportData.SevenZipPriority = $effectiveConfig.JobSevenZipProcessPriority

    $effectiveConfig.GlobalConfigRef = $GlobalConfig 

    return $effectiveConfig
}
#endregion

Export-ModuleMember -Function Import-AppConfiguration, Get-JobsToProcess, Get-PoShBackupJobEffectiveConfiguration
