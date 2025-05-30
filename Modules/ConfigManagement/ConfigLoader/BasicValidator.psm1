# Modules\ConfigManagement\ConfigLoader\BasicValidator.psm1
<#
.SYNOPSIS
    Sub-module for ConfigLoader. Performs basic structural and value validations
    on the loaded configuration.
.DESCRIPTION
    This module contains the 'Invoke-BasicConfigValidation' function, which is
    responsible for performing a series of basic checks on the PoSh-Backup
    configuration after it has been loaded and merged. These checks include:
    - Validating 'BackupTargets' structure.
    - Checking 'VSSMetadataCachePath'.
    - Validating 'DefaultArchiveDateFormat' and job-specific 'ArchiveDateFormat'.
    - Validating 'PauseBeforeExit'.
    - Checking 'ArchiveExtension' in BackupLocations and 'DefaultArchiveExtension'.
    - Validating job names referenced in 'BackupSets'.
    Any validation failures are added to the provided validation messages list.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    29-May-2025
    LastModified:   29-May-2025
    Purpose:        Basic configuration validation logic for ConfigLoader.
    Prerequisites:  PowerShell 5.1+.
                    Relies on Utils.psm1 (for Get-ConfigValue).
#>

# Explicitly import Utils.psm1 from the main Modules directory.
# $PSScriptRoot here is Modules\ConfigManagement\ConfigLoader.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "BasicValidator.psm1 (ConfigLoader submodule) FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}

#region --- Basic Configuration Validation Function ---
function Invoke-BasicConfigValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,
        [Parameter(Mandatory = $true)]
        [ref]$ValidationMessagesListRef, # To add error/warning messages
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $false)]
        [bool]$IsTestConfigMode = $false, # For context-specific logging
        [Parameter(Mandatory = $false)]
        [bool]$ListBackupLocationsSwitch = $false,
        [Parameter(Mandatory = $false)]
        [bool]$ListBackupSetsSwitch = $false
    )

    & $Logger -Message "ConfigLoader/BasicValidator/Invoke-BasicConfigValidation: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    # Validate BackupTargets structure
    if ($Configuration.ContainsKey('BackupTargets')) {
        if ($Configuration.BackupTargets -isnot [hashtable]) {
            $ValidationMessagesListRef.Value.Add("ConfigLoader/BasicValidator: Global 'BackupTargets' must be a Hashtable if defined.")
        }
        else {
            foreach ($targetName in $Configuration.BackupTargets.Keys) {
                $targetInstance = $Configuration.BackupTargets[$targetName]
                if ($targetInstance -isnot [hashtable]) {
                    $ValidationMessagesListRef.Value.Add("ConfigLoader/BasicValidator: BackupTarget instance '$targetName' must be a Hashtable.")
                    continue
                }
                if (-not $targetInstance.ContainsKey('Type') -or [string]::IsNullOrWhiteSpace($targetInstance.Type)) {
                    $ValidationMessagesListRef.Value.Add("ConfigLoader/BasicValidator: BackupTarget instance '$targetName' is missing a 'Type' or it is empty.")
                }
                # Further type-specific validation for TargetSpecificSettings is handled by PoShBackupValidator.psm1
            }
        }
    }

    # Validate VSSMetadataCachePath
    $vssCachePath = Get-ConfigValue -ConfigObject $Configuration -Key 'VSSMetadataCachePath' -DefaultValue "%TEMP%\diskshadow_cache_poshbackup.cab"
    try {
        $expandedVssCachePath = [System.Environment]::ExpandEnvironmentVariables($vssCachePath)
        $null = [System.IO.Path]::GetFullPath($expandedVssCachePath) # Check if path is validly formed
        $parentDir = Split-Path -Path $expandedVssCachePath
        if (($null -ne $parentDir) -and (-not ([string]::IsNullOrEmpty($parentDir))) -and (-not (Test-Path -Path $parentDir -PathType Container))) {
            if ($IsTestConfigMode) { # Only log this as INFO in TestConfig mode, otherwise it's just a debug detail
                & $LocalWriteLog -Message "[INFO] ConfigLoader/BasicValidator: Note: Parent directory ('$parentDir') for 'VSSMetadataCachePath' ('$expandedVssCachePath') does not exist. Diskshadow may attempt creation." -Level "INFO"
            }
        }
    }
    catch {
        $ValidationMessagesListRef.Value.Add("ConfigLoader/BasicValidator: Global 'VSSMetadataCachePath' ('$vssCachePath') is invalid. Error: $($_.Exception.Message)")
    }

    # Validate DefaultArchiveDateFormat
    $defaultDateFormat = Get-ConfigValue -ConfigObject $Configuration -Key 'DefaultArchiveDateFormat' -DefaultValue "yyyy-MMM-dd"
    if ($Configuration.ContainsKey('DefaultArchiveDateFormat')) { # Check if the key actually exists to validate its value
        if (-not ([string]$defaultDateFormat).Trim()) {
            $ValidationMessagesListRef.Value.Add("ConfigLoader/BasicValidator: Global 'DefaultArchiveDateFormat' is empty. Provide valid .NET date format string or remove key.")
        }
        else {
            try { Get-Date -Format $defaultDateFormat -ErrorAction Stop | Out-Null }
            catch { $ValidationMessagesListRef.Value.Add("ConfigLoader/BasicValidator: Global 'DefaultArchiveDateFormat' ('$defaultDateFormat') invalid. Error: $($_.Exception.Message)") }
        }
    }

    # Validate PauseBeforeExit
    $pauseSetting = Get-ConfigValue -ConfigObject $Configuration -Key 'PauseBeforeExit' -DefaultValue "OnFailureOrWarning"
    if ($Configuration.ContainsKey('PauseBeforeExit')) {
        $validPauseOptions = @('true', 'false', 'always', 'never', 'onfailure', 'onwarning', 'onfailureorwarning')
        if (!($pauseSetting -is [bool] -or ($pauseSetting -is [string] -and $pauseSetting.ToString().ToLowerInvariant() -in $validPauseOptions))) {
            $ValidationMessagesListRef.Value.Add("ConfigLoader/BasicValidator: Global 'PauseBeforeExit' ('$pauseSetting') invalid. Allowed: Boolean or String (`'Always'`, `'Never'`, etc.).")
        }
    }

    # Validate BackupLocations structure and contents
    if (($null -eq $Configuration.BackupLocations -or $Configuration.BackupLocations.Count -eq 0) -and -not $IsTestConfigMode `
            -and -not $ListBackupLocationsSwitch `
            -and -not $ListBackupSetsSwitch ) {
        & $LocalWriteLog -Message "[WARNING] ConfigLoader/BasicValidator: 'BackupLocations' empty. No jobs to run unless specified by -BackupLocationName." -Level "WARNING"
    }
    else {
        if ($null -ne $Configuration.BackupLocations -and $Configuration.BackupLocations -is [hashtable]) {
            foreach ($jobKey in $Configuration.BackupLocations.Keys) {
                $jobConfig = $Configuration.BackupLocations[$jobKey]
                if ($null -ne $jobConfig -and $jobConfig.ContainsKey('ArchiveExtension')) {
                    $userArchiveExt = $jobConfig['ArchiveExtension']
                    if (-not ($userArchiveExt -match "^\.[a-zA-Z0-9]+([a-zA-Z0-9\.]*[a-zA-Z0-9]+)?$")) {
                        $ValidationMessagesListRef.Value.Add("ConfigLoader/BasicValidator: BackupLocation '$jobKey': 'ArchiveExtension' ('$userArchiveExt') invalid. Must start with '.' (e.g., '.zip').")
                    }
                }
                if ($null -ne $jobConfig -and $jobConfig.ContainsKey('ArchiveDateFormat')) {
                    $jobDateFormat = $jobConfig['ArchiveDateFormat']
                    if (-not ([string]$jobDateFormat).Trim()) {
                        $ValidationMessagesListRef.Value.Add("ConfigLoader/BasicValidator: BackupLocation '$jobKey': 'ArchiveDateFormat' empty. Provide valid .NET date format string or remove key.")
                    }
                    else {
                        try { Get-Date -Format $jobDateFormat -ErrorAction Stop | Out-Null }
                        catch { $ValidationMessagesListRef.Value.Add("ConfigLoader/BasicValidator: BackupLocation '$jobKey': 'ArchiveDateFormat' ('$jobDateFormat') invalid. Error: $($_.Exception.Message)") }
                    }
                }
                if ($null -ne $jobConfig -and $jobConfig.ContainsKey('TargetNames')) {
                    if ($jobConfig.TargetNames -isnot [array] -and -not ($null -eq $jobConfig.TargetNames)) {
                        $ValidationMessagesListRef.Value.Add("ConfigLoader/BasicValidator: BackupLocation '$jobKey': 'TargetNames' must be an array of strings if defined.")
                    }
                    elseif ($jobConfig.TargetNames -is [array]) {
                        foreach ($targetNameRef in $jobConfig.TargetNames) {
                            if (-not ($targetNameRef -is [string]) -or [string]::IsNullOrWhiteSpace($targetNameRef)) {
                                $ValidationMessagesListRef.Value.Add("ConfigLoader/BasicValidator: BackupLocation '$jobKey': 'TargetNames' array contains an invalid (non-string or empty) target name reference.")
                                break
                            }
                            if (-not $Configuration.ContainsKey('BackupTargets') -or `
                                    $Configuration.BackupTargets -isnot [hashtable] -or `
                                    -not $Configuration.BackupTargets.ContainsKey($targetNameRef)) {
                                $ValidationMessagesListRef.Value.Add("ConfigLoader/BasicValidator: BackupLocation '$jobKey': TargetName '$targetNameRef' referenced in 'TargetNames' is not defined in the global 'BackupTargets' section.")
                            }
                        }
                    }
                }
            }
        }
    }

    # Validate DefaultArchiveExtension
    if ($Configuration.ContainsKey('DefaultArchiveExtension')) {
        $defaultArchiveExtGlobal = Get-ConfigValue -ConfigObject $Configuration -Key 'DefaultArchiveExtension' -DefaultValue ".7z"
        if (-not ($defaultArchiveExtGlobal -match "^\.[a-zA-Z0-9]+([a-zA-Z0-9\.]*[a-zA-Z0-9]+)?$")) {
            $ValidationMessagesListRef.Value.Add("ConfigLoader/BasicValidator: Global 'DefaultArchiveExtension' ('$defaultArchiveExtGlobal') invalid. Must start with '.'.")
        }
    }

    # Validate BackupSets job name references
    if ($Configuration.ContainsKey('BackupSets') -and $Configuration.BackupSets -is [hashtable]) {
        foreach ($setKey in $Configuration.BackupSets.Keys) {
            $setConfig = $Configuration.BackupSets[$setKey]
            if ($setConfig -is [hashtable]) {
                $jobNamesInSetArray = @(Get-ConfigValue -ConfigObject $setConfig -Key 'JobNames' -DefaultValue @())
                if ($jobNamesInSetArray.Count -gt 0) {
                    foreach ($jobNameInSetCandidate in $jobNamesInSetArray) {
                        if ([string]::IsNullOrWhiteSpace($jobNameInSetCandidate)) {
                            $ValidationMessagesListRef.Value.Add("ConfigLoader/BasicValidator: BackupSet '$setKey': Contains empty job name in 'JobNames'.")
                            continue
                        }
                        $jobNameInSet = $jobNameInSetCandidate.Trim()
                        if ($Configuration.ContainsKey('BackupLocations') -and $Configuration.BackupLocations -is [hashtable] -and -not $Configuration.BackupLocations.ContainsKey($jobNameInSet)) {
                            $ValidationMessagesListRef.Value.Add("ConfigLoader/BasicValidator: BackupSet '$setKey': Job '$jobNameInSet' not defined in 'BackupLocations'.")
                        }
                        elseif (-not ($Configuration.ContainsKey('BackupLocations') -and $Configuration.BackupLocations -is [hashtable])) {
                            # This case implies BackupLocations itself is missing or invalid, which should ideally be caught by schema validation.
                            $ValidationMessagesListRef.Value.Add("ConfigLoader/BasicValidator: BackupSet '$setKey': Cannot validate Job '$jobNameInSet'; 'BackupLocations' section is missing or not a hashtable in the configuration.")
                        }
                    }
                }
            }
        }
    }
}
#endregion

Export-ModuleMember -Function Invoke-BasicConfigValidation
