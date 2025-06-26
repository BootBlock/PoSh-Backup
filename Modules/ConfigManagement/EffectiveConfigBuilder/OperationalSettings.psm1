# Modules\ConfigManagement\EffectiveConfigBuilder\OperationalSettings.psm1
<#
.SYNOPSIS
    Resolves operational configuration settings for a PoSh-Backup job.
.DESCRIPTION
    This sub-module for EffectiveConfigBuilder.psm1 determines effective settings
    for VSS, infrastructure snapshots (via a provider), retries, password management,
    log retention, 7-Zip output visibility, free space checks, archive testing,
    pre/post backup script paths, post-run system actions, the PinOnCreation flag,
    and notification settings. It now strictly relies on Default.psd1 for all default
    values, throwing an error if required settings are missing.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.5.3 # Corrected key name for DeleteLocalArchiveAfterSuccessfulTransfer.
    DateCreated:    30-May-2025
    LastModified:   26-Jun-2025
    Purpose:        Operational settings resolution.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Utils.psm1 from the main Modules directory.
#>

# Explicitly import Utils.psm1 from the main Modules directory.
# $PSScriptRoot here is Modules\ConfigManagement\EffectiveConfigBuilder.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
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
        [Parameter(Mandatory)] [scriptblock]$Logger,
        [Parameter(Mandatory = $false)]
        [hashtable]$SetSpecificConfig = $null
    )

    # PSSA: Directly use Logger and CliOverrides for initial debug message
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

    # Snapshot Provider Settings (optional, can be null)
    $resolvedSettings.SnapshotProviderName = Get-ConfigValue -ConfigObject $JobConfig -Key 'SnapshotProviderName' -DefaultValue $null
    $resolvedSettings.SourceIsVMName = Get-ConfigValue -ConfigObject $JobConfig -Key 'SourceIsVMName' -DefaultValue $false

    # Required Operational Settings
    $resolvedSettings.OnSourcePathNotFound = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'OnSourcePathNotFound' -GlobalKey 'DefaultOnSourcePathNotFound'
    $resolvedSettings.LocalRetentionCount = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'LocalRetentionCount' -GlobalKey 'DefaultRetentionCount'
    if ($resolvedSettings.LocalRetentionCount -lt 0) { $resolvedSettings.LocalRetentionCount = 0 }
    $resolvedSettings.DeleteToRecycleBin = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'DeleteToRecycleBin' -GlobalKey 'DefaultDeleteToRecycleBin'
    $resolvedSettings.RetentionConfirmDelete = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'RetentionConfirmDelete' -GlobalKey 'RetentionConfirmDelete'
    $resolvedSettings.TestArchiveBeforeDeletion = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'TestArchiveBeforeDeletion' -GlobalKey 'DefaultTestArchiveBeforeDeletion'
    $resolvedSettings.DeleteLocalArchiveAfterSuccessfulTransfer = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'DeleteLocalArchiveAfterSuccessfulTransfer' -GlobalKey 'DeleteLocalArchiveAfterSuccessfulTransfer'

    # Password settings (defaults are defined, so Get-RequiredConfigValue is appropriate)
    $resolvedSettings.ArchivePasswordMethod = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'ArchivePasswordMethod' -GlobalKey 'DefaultArchivePasswordMethod'
    $resolvedSettings.CredentialUserNameHint = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'CredentialUserNameHint' -GlobalKey 'DefaultCredentialUserNameHint'
    $resolvedSettings.ArchivePasswordSecretName = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordSecretName' -DefaultValue $null
    $resolvedSettings.ArchivePasswordVaultName = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordVaultName' -DefaultValue $null
    $resolvedSettings.ArchivePasswordSecureStringPath = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordSecureStringPath' -DefaultValue $null
    $resolvedSettings.ArchivePasswordPlainText = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordPlainText' -DefaultValue $null
    $resolvedSettings.UsePassword = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'UsePassword' -GlobalKey 'DefaultUsePassword'

    # 7-Zip Output
    $resolvedSettings.HideSevenZipOutput = Get-RequiredConfigValue -JobConfig @{} -GlobalConfig $GlobalConfig -JobKey 'HideSevenZipOutput' -GlobalKey 'HideSevenZipOutput'

    # VSS Settings (Skip > Use > Config). This logic is now intertwined with Snapshot provider.
    if (-not [string]::IsNullOrWhiteSpace($resolvedSettings.SnapshotProviderName)) {
        $resolvedSettings.JobEnableVSS = $true
    }
    elseif ($CliOverrides.SkipVSS) {
        $resolvedSettings.JobEnableVSS = $false
    }
    elseif ($CliOverrides.UseVSS) {
        $resolvedSettings.JobEnableVSS = $true
    }
    else {
        $resolvedSettings.JobEnableVSS = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'EnableVSS' -GlobalKey 'EnableVSS'
    }
    $resolvedSettings.JobVSSContextOption = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'VSSContextOption' -GlobalKey 'DefaultVSSContextOption'
    $_vssCachePathFromConfig = Get-RequiredConfigValue -JobConfig @{} -GlobalConfig $GlobalConfig -JobKey 'VSSMetadataCachePath' -GlobalKey 'VSSMetadataCachePath'
    $resolvedSettings.VSSMetadataCachePath = [System.Environment]::ExpandEnvironmentVariables($_vssCachePathFromConfig)
    $resolvedSettings.VSSPollingTimeoutSeconds = Get-RequiredConfigValue -JobConfig @{} -GlobalConfig $GlobalConfig -JobKey 'VSSPollingTimeoutSeconds' -GlobalKey 'VSSPollingTimeoutSeconds'
    $resolvedSettings.VSSPollingIntervalSeconds = Get-RequiredConfigValue -JobConfig @{} -GlobalConfig $GlobalConfig -JobKey 'VSSPollingIntervalSeconds' -GlobalKey 'VSSPollingIntervalSeconds'

    # Retry Settings (Skip > Enable > Config)
    if ($CliOverrides.SkipRetries) {
        $resolvedSettings.JobEnableRetries = $false
    } elseif ($CliOverrides.EnableRetries) {
        $resolvedSettings.JobEnableRetries = $true
    } else {
        $resolvedSettings.JobEnableRetries = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'EnableRetries' -GlobalKey 'EnableRetries'
    }
    $resolvedSettings.JobMaxRetryAttempts = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'MaxRetryAttempts' -GlobalKey 'MaxRetryAttempts'
    $resolvedSettings.JobRetryDelaySeconds = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'RetryDelaySeconds' -GlobalKey 'RetryDelaySeconds'

    # Treat 7-Zip Warnings As Success
    $treatWarningsRawValue = if ($null -ne $CliOverrides.TreatSevenZipWarningsAsSuccess) {
        $CliOverrides.TreatSevenZipWarningsAsSuccess
    } else {
        Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'TreatSevenZipWarningsAsSuccess' -GlobalKey 'TreatSevenZipWarningsAsSuccess'
    }

    if ($treatWarningsRawValue -is [bool]) {
        $resolvedSettings.TreatSevenZipWarningsAsSuccess = $treatWarningsRawValue
    } elseif ($treatWarningsRawValue -is [string] -and $treatWarningsRawValue.ToLowerInvariant() -eq 'true') {
        $resolvedSettings.TreatSevenZipWarningsAsSuccess = $true
    } elseif ($treatWarningsRawValue -is [int] -and $treatWarningsRawValue -ne 0) {
        $resolvedSettings.TreatSevenZipWarningsAsSuccess = $true
    } else {
        $resolvedSettings.TreatSevenZipWarningsAsSuccess = $false
    }

    # 7-Zip Process Priority
    $resolvedSettings.JobSevenZipProcessPriority = if (-not [string]::IsNullOrWhiteSpace($CliOverrides.SevenZipPriority)) {
        $CliOverrides.SevenZipPriority
    } else {
        Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'SevenZipProcessPriority' -GlobalKey 'DefaultSevenZipProcessPriority'
    }

    # PinOnCreation (CLI > Job > Default false)
    if ($CliOverrides.PinOnCreationCLI) {
        $resolvedSettings.PinOnCreation = $true
    } else {
        $pinValueFromConfig = Get-ConfigValue -ConfigObject $JobConfig -Key 'PinOnCreation' -DefaultValue $false # Optional, can have a hardcoded default
        $isPinEnabled = $false
        if ($pinValueFromConfig -is [bool]) { $isPinEnabled = $pinValueFromConfig }
        elseif ($pinValueFromConfig -is [string] -and $pinValueFromConfig.ToLowerInvariant() -eq 'true') { $isPinEnabled = $true }
        elseif ($pinValueFromConfig -is [int] -and $pinValueFromConfig -ne 0) { $isPinEnabled = $true }
        $resolvedSettings.PinOnCreation = $isPinEnabled
    }

    $resolvedSettings.PinReason = if ($CliOverrides.ContainsKey('Reason')) { $CliOverrides.Reason } else { $null }

    # Archive Testing
    $resolvedSettings.JobTestArchiveAfterCreation = if ($CliOverrides.TestArchive) { $true } else { Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'TestArchiveAfterCreation' -GlobalKey 'DefaultTestArchiveAfterCreation' }

    # Verify Local Archive Before Transfer (CLI > Job > Global)
    if ($CliOverrides.ContainsKey('VerifyLocalArchiveBeforeTransferCLI') -and $null -ne $CliOverrides.VerifyLocalArchiveBeforeTransferCLI) {
        $resolvedSettings.VerifyLocalArchiveBeforeTransfer = $CliOverrides.VerifyLocalArchiveBeforeTransferCLI
    } else {
        $resolvedSettings.VerifyLocalArchiveBeforeTransfer = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'VerifyLocalArchiveBeforeTransfer' -GlobalKey 'DefaultVerifyLocalArchiveBeforeTransfer'
    }

    # LogRetentionCount (CLI > Set > Job > Global)
    if ($CliOverrides.ContainsKey('LogRetentionCountCLI') -and $null -ne $CliOverrides.LogRetentionCountCLI) {
        $resolvedSettings.LogRetentionCount = $CliOverrides.LogRetentionCountCLI
    } else {
        $setLogRetention = if ($null -ne $SetSpecificConfig) { Get-ConfigValue -ConfigObject $SetSpecificConfig -Key 'LogRetentionCount' -DefaultValue $null } else { $null }
        $jobLogRetention = Get-ConfigValue -ConfigObject $JobConfig -Key 'LogRetentionCount' -DefaultValue $null
        if ($null -ne $setLogRetention) {
            $resolvedSettings.LogRetentionCount = $setLogRetention
        }
        elseif ($null -ne $jobLogRetention) {
            $resolvedSettings.LogRetentionCount = $jobLogRetention
        }
        else {
            $resolvedSettings.LogRetentionCount = Get-RequiredConfigValue -JobConfig @{} -GlobalConfig $GlobalConfig -JobKey 'DefaultLogRetentionCount' -GlobalKey 'DefaultLogRetentionCount'
        }
    }

    # Log Compression Settings (Job > Global)
    $resolvedSettings.CompressOldLogs = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'CompressOldLogs' -GlobalKey 'CompressOldLogs'
    $resolvedSettings.OldLogCompressionFormat = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'OldLogCompressionFormat' -GlobalKey 'OldLogCompressionFormat'

    # Free Space Check
    $resolvedSettings.JobMinimumRequiredFreeSpaceGB = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'MinimumRequiredFreeSpaceGB' -GlobalKey 'MinimumRequiredFreeSpaceGB'
    $resolvedSettings.JobExitOnLowSpace = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'ExitOnLowSpaceIfBelowMinimum' -GlobalKey 'ExitOnLowSpaceIfBelowMinimum'

    # Hook Script Paths (optional, can be null)
    $resolvedSettings.PreBackupScriptPath = Get-ConfigValue -ConfigObject $JobConfig -Key 'PreBackupScriptPath' -DefaultValue $null
    $resolvedSettings.PostLocalArchiveScriptPath = Get-ConfigValue -ConfigObject $JobConfig -Key 'PostLocalArchiveScriptPath' -DefaultValue $null
    $resolvedSettings.PostBackupScriptOnSuccessPath = Get-ConfigValue -ConfigObject $JobConfig -Key 'PostBackupScriptOnSuccessPath' -DefaultValue $null
    $resolvedSettings.PostBackupScriptOnFailurePath = Get-ConfigValue -ConfigObject $JobConfig -Key 'PostBackupScriptOnFailurePath' -DefaultValue $null
    $resolvedSettings.PostBackupScriptAlwaysPath = Get-ConfigValue -ConfigObject $JobConfig -Key 'PostBackupScriptAlwaysPath' -DefaultValue $null

    # Post-Run Action
    $jobPostRunActionConfig = Get-ConfigValue -ConfigObject $JobConfig -Key 'PostRunAction' -DefaultValue $null
    $globalPostRunActionDefaults = Get-RequiredConfigValue -JobConfig @{} -GlobalConfig $GlobalConfig -JobKey 'PostRunActionDefaults' -GlobalKey 'PostRunActionDefaults'
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

    # --- Notification Settings (CLI > Job > Set > Global) ---
    $defaultNotificationSettings = Get-RequiredConfigValue -JobConfig @{} -GlobalConfig $GlobalConfig -JobKey 'DefaultNotificationSettings' -GlobalKey 'DefaultNotificationSettings'
    $jobNotificationSettings = Get-ConfigValue -ConfigObject $JobConfig -Key 'NotificationSettings' -DefaultValue @{}
    $setNotificationSettings = if ($null -ne $SetSpecificConfig) { Get-ConfigValue -ConfigObject $SetSpecificConfig -Key 'NotificationSettings' -DefaultValue @{} } else { @{} }

    $effectiveNotificationSettings = $defaultNotificationSettings.Clone()
    $setNotificationSettings.GetEnumerator() | ForEach-Object { $effectiveNotificationSettings[$_.Name] = $_.Value }
    $jobNotificationSettings.GetEnumerator() | ForEach-Object { $effectiveNotificationSettings[$_.Name] = $_.Value }

    if ($CliOverrides.ContainsKey('NotificationProfileNameCLI') -and -not [string]::IsNullOrWhiteSpace($CliOverrides.NotificationProfileNameCLI)) {
        $effectiveNotificationSettings.ProfileName = $CliOverrides.NotificationProfileNameCLI
        $effectiveNotificationSettings.Enabled = $true
    }
    $resolvedSettings.NotificationSettings = $effectiveNotificationSettings
    # --- END Notification Settings ---

    $resolvedSettings.GlobalConfigRef = $GlobalConfig

    return $resolvedSettings
}

Export-ModuleMember -Function Resolve-OperationalConfiguration
