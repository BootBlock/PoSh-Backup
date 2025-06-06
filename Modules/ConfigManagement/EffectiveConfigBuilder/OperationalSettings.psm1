# Modules\ConfigManagement\EffectiveConfigBuilder\OperationalSettings.psm1
<#
.SYNOPSIS
    Resolves operational configuration settings for a PoSh-Backup job.
.DESCRIPTION
    This sub-module for EffectiveConfigBuilder.psm1 determines effective settings
    for VSS, retries, password management, log retention, 7-Zip output visibility,
    free space checks, archive testing, pre/post backup script paths, post-run
    system actions, and the PinOnCreation flag.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Added PinOnCreation setting resolution.
    DateCreated:    30-May-2025
    LastModified:   06-Jun-2025
    Purpose:        Operational settings resolution.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Utils.psm1 from the main Modules directory.
#>

# Explicitly import Utils.psm1 from the main Modules directory.
# $PSScriptRoot here is Modules\ConfigManagement\EffectiveConfigBuilder.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "OperationalSettings.psm1 (EffectiveConfigBuilder submodule) FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}

function Resolve-OperationalConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$JobConfig,
        [Parameter(Mandatory)] [hashtable]$GlobalConfig,
        [Parameter(Mandatory)] [hashtable]$CliOverrides,
        [Parameter(Mandatory)] [scriptblock]$Logger
    )

    # PSSA: Directly use Logger for initial debug message
    & $Logger -Message "EffectiveConfigBuilder/OperationalSettings/Resolve-OperationalConfiguration: Logger active. CLI Overrides count: $($CliOverrides.Count)." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    & $LocalWriteLog -Message "EffectiveConfigBuilder/OperationalSettings/Resolve-OperationalConfiguration: Resolving operational settings." -Level "DEBUG"

    $resolvedSettings = @{}

    # Original Source Path and Base File Name (core identifiers)
    $resolvedSettings.OriginalSourcePath = $JobConfig.Path
    $resolvedSettings.BaseFileName = $JobConfig.Name

    # Local Retention settings
    $resolvedSettings.LocalRetentionCount = Get-ConfigValue -ConfigObject $JobConfig -Key 'LocalRetentionCount' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultRetentionCount' -DefaultValue 3)
    if ($resolvedSettings.LocalRetentionCount -lt 0) { $resolvedSettings.LocalRetentionCount = 0 }
    $resolvedSettings.DeleteToRecycleBin = Get-ConfigValue -ConfigObject $JobConfig -Key 'DeleteToRecycleBin' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultDeleteToRecycleBin' -DefaultValue $false)
    $resolvedSettings.RetentionConfirmDelete = Get-ConfigValue -ConfigObject $JobConfig -Key 'RetentionConfirmDelete' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'RetentionConfirmDelete' -DefaultValue $true)

    # Password settings
    $resolvedSettings.ArchivePasswordMethod = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordMethod' -DefaultValue "None"
    $resolvedSettings.CredentialUserNameHint = Get-ConfigValue -ConfigObject $JobConfig -Key 'CredentialUserNameHint' -DefaultValue "BackupUser"
    $resolvedSettings.ArchivePasswordSecretName = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordSecretName' -DefaultValue $null
    $resolvedSettings.ArchivePasswordVaultName = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordVaultName' -DefaultValue $null
    $resolvedSettings.ArchivePasswordSecureStringPath = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordSecureStringPath' -DefaultValue $null
    $resolvedSettings.ArchivePasswordPlainText = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordPlainText' -DefaultValue $null
    $resolvedSettings.UsePassword = Get-ConfigValue -ConfigObject $JobConfig -Key 'UsePassword' -DefaultValue $false # Legacy

    # 7-Zip Output
    $resolvedSettings.HideSevenZipOutput = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'HideSevenZipOutput' -DefaultValue $true

    # VSS Settings (Skip > Use > Config)
    if ($CliOverrides.SkipVSS) {
        $resolvedSettings.JobEnableVSS = $false
    } elseif ($CliOverrides.UseVSS) {
        $resolvedSettings.JobEnableVSS = $true
    } else {
        $resolvedSettings.JobEnableVSS = Get-ConfigValue -ConfigObject $JobConfig -Key 'EnableVSS' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'EnableVSS' -DefaultValue $false)
    }
    $resolvedSettings.JobVSSContextOption = Get-ConfigValue -ConfigObject $JobConfig -Key 'VSSContextOption' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultVSSContextOption' -DefaultValue "Persistent NoWriters")
    $_vssCachePathFromConfig = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'VSSMetadataCachePath' -DefaultValue "%TEMP%\diskshadow_cache_poshbackup.cab"
    $resolvedSettings.VSSMetadataCachePath = [System.Environment]::ExpandEnvironmentVariables($_vssCachePathFromConfig)
    $resolvedSettings.VSSPollingTimeoutSeconds = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'VSSPollingTimeoutSeconds' -DefaultValue 120
    $resolvedSettings.VSSPollingIntervalSeconds = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'VSSPollingIntervalSeconds' -DefaultValue 5

    # Retry Settings (Skip > Enable > Config)
    if ($CliOverrides.SkipRetries) {
        $resolvedSettings.JobEnableRetries = $false
    } elseif ($CliOverrides.EnableRetries) {
        $resolvedSettings.JobEnableRetries = $true
    } else {
        $resolvedSettings.JobEnableRetries = Get-ConfigValue -ConfigObject $JobConfig -Key 'EnableRetries' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'EnableRetries' -DefaultValue $true)
    }
    $resolvedSettings.JobMaxRetryAttempts = Get-ConfigValue -ConfigObject $JobConfig -Key 'MaxRetryAttempts' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'MaxRetryAttempts' -DefaultValue 3)
    $resolvedSettings.JobRetryDelaySeconds = Get-ConfigValue -ConfigObject $JobConfig -Key 'RetryDelaySeconds' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'RetryDelaySeconds' -DefaultValue 60)

    # Treat 7-Zip Warnings As Success
    if ($null -ne $CliOverrides.TreatSevenZipWarningsAsSuccess) {
        $resolvedSettings.TreatSevenZipWarningsAsSuccess = $CliOverrides.TreatSevenZipWarningsAsSuccess
    } else {
        $resolvedSettings.TreatSevenZipWarningsAsSuccess = Get-ConfigValue -ConfigObject $JobConfig -Key 'TreatSevenZipWarningsAsSuccess' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'TreatSevenZipWarningsAsSuccess' -DefaultValue $false)
    }

    # 7-Zip Process Priority
    $resolvedSettings.JobSevenZipProcessPriority = if (-not [string]::IsNullOrWhiteSpace($CliOverrides.SevenZipPriority)) {
        $CliOverrides.SevenZipPriority
    } else {
        Get-ConfigValue -ConfigObject $JobConfig -Key 'SevenZipProcessPriority' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultSevenZipProcessPriority' -DefaultValue "Normal")
    }

    # PinOnCreation (CLI > Job > Default false)
    if ($CliOverrides.PinOnCreationCLI) {
        $resolvedSettings.PinOnCreation = $true
        & $LocalWriteLog -Message "  - Resolve-OperationalConfiguration: PinOnCreation set to TRUE by -Pin CLI switch." -Level "DEBUG"
    } else {
        $resolvedSettings.PinOnCreation = Get-ConfigValue -ConfigObject $JobConfig -Key 'PinOnCreation' -DefaultValue $false
        if ($resolvedSettings.PinOnCreation) {
            & $LocalWriteLog -Message "  - Resolve-OperationalConfiguration: PinOnCreation set to TRUE by job configuration." -Level "DEBUG"
        }
    }

    # Archive Testing
    $resolvedSettings.JobTestArchiveAfterCreation = if ($CliOverrides.TestArchive) { $true } else { Get-ConfigValue -ConfigObject $JobConfig -Key 'TestArchiveAfterCreation' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultTestArchiveAfterCreation' -DefaultValue $false) }

    # Verify Local Archive Before Transfer (CLI > Job > Global)
    if ($CliOverrides.ContainsKey('VerifyLocalArchiveBeforeTransferCLI') -and $null -ne $CliOverrides.VerifyLocalArchiveBeforeTransferCLI) {
        $resolvedSettings.VerifyLocalArchiveBeforeTransfer = $CliOverrides.VerifyLocalArchiveBeforeTransferCLI
    } else {
        $resolvedSettings.VerifyLocalArchiveBeforeTransfer = Get-ConfigValue -ConfigObject $JobConfig -Key 'VerifyLocalArchiveBeforeTransfer' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultVerifyLocalArchiveBeforeTransfer' -DefaultValue $false)
    }

    # LogRetentionCount (CLI > Job > Global)
    if ($CliOverrides.ContainsKey('LogRetentionCountCLI') -and $null -ne $CliOverrides.LogRetentionCountCLI) {
        $resolvedSettings.LogRetentionCount = $CliOverrides.LogRetentionCountCLI
        & $LocalWriteLog -Message "  - Resolve-OperationalConfiguration: Log Retention Count set by CLI override: $($CliOverrides.LogRetentionCountCLI)." -Level "DEBUG"
    } else {
        $jobLogRetention = Get-ConfigValue -ConfigObject $JobConfig -Key 'LogRetentionCount' -DefaultValue $null
        if ($null -ne $jobLogRetention) {
            $resolvedSettings.LogRetentionCount = $jobLogRetention
            & $LocalWriteLog -Message "  - Resolve-OperationalConfiguration: Log Retention Count set by Job config: $jobLogRetention." -Level "DEBUG"
        } else {
            $resolvedSettings.LogRetentionCount = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultLogRetentionCount' -DefaultValue 30
            & $LocalWriteLog -Message "  - Resolve-OperationalConfiguration: Log Retention Count set by Global config: $($resolvedSettings.LogRetentionCount)." -Level "DEBUG"
        }
    }

    # Free Space Check
    $resolvedSettings.JobMinimumRequiredFreeSpaceGB = Get-ConfigValue -ConfigObject $JobConfig -Key 'MinimumRequiredFreeSpaceGB' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'MinimumRequiredFreeSpaceGB' -DefaultValue 0)
    $resolvedSettings.JobExitOnLowSpace = Get-ConfigValue -ConfigObject $JobConfig -Key 'ExitOnLowSpaceIfBelowMinimum' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'ExitOnLowSpaceIfBelowMinimum' -DefaultValue $false)

    # Hook Script Paths
    $resolvedSettings.PreBackupScriptPath = Get-ConfigValue -ConfigObject $JobConfig -Key 'PreBackupScriptPath' -DefaultValue $null
    $resolvedSettings.PostBackupScriptOnSuccessPath = Get-ConfigValue -ConfigObject $JobConfig -Key 'PostBackupScriptOnSuccessPath' -DefaultValue $null
    $resolvedSettings.PostBackupScriptOnFailurePath = Get-ConfigValue -ConfigObject $JobConfig -Key 'PostBackupScriptOnFailurePath' -DefaultValue $null
    $resolvedSettings.PostBackupScriptAlwaysPath = Get-ConfigValue -ConfigObject $JobConfig -Key 'PostBackupScriptAlwaysPath' -DefaultValue $null

    # Post-Run Action
    $jobPostRunActionConfig = Get-ConfigValue -ConfigObject $JobConfig -Key 'PostRunAction' -DefaultValue $null
    $globalPostRunActionDefaults = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'PostRunActionDefaults' -DefaultValue @{}
    $effectivePostRunAction = $globalPostRunActionDefaults.Clone() # Start with a copy of defaults
    if ($null -ne $jobPostRunActionConfig -and $jobPostRunActionConfig -is [hashtable]) {
        # Overlay job-specific settings if they exist
        if ($jobPostRunActionConfig.ContainsKey('Enabled') -and $jobPostRunActionConfig.Enabled -is [boolean]) { $effectivePostRunAction.Enabled = $jobPostRunActionConfig.Enabled }
        if ($jobPostRunActionConfig.ContainsKey('Action') -and $jobPostRunActionConfig.Action -is [string]) { $effectivePostRunAction.Action = $jobPostRunActionConfig.Action }
        if ($jobPostRunActionConfig.ContainsKey('DelaySeconds') -and $jobPostRunActionConfig.DelaySeconds -is [int]) { $effectivePostRunAction.DelaySeconds = $jobPostRunActionConfig.DelaySeconds }
        if ($jobPostRunActionConfig.ContainsKey('TriggerOnStatus') -and $jobPostRunActionConfig.TriggerOnStatus -is [array]) { $effectivePostRunAction.TriggerOnStatus = @($jobPostRunActionConfig.TriggerOnStatus) }
        if ($jobPostRunActionConfig.ContainsKey('ForceAction') -and $jobPostRunActionConfig.ForceAction -is [boolean]) { $effectivePostRunAction.ForceAction = $jobPostRunActionConfig.ForceAction }
    }
    $resolvedSettings.PostRunAction = $effectivePostRunAction

    # Store a reference to the global config for any direct lookups needed later (e.g., DefaultScriptExcludeRecycleBin)
    $resolvedSettings.GlobalConfigRef = $GlobalConfig

    return $resolvedSettings
}

Export-ModuleMember -Function Resolve-OperationalConfiguration
