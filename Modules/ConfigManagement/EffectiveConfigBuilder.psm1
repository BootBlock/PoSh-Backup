# Modules\ConfigManagement\EffectiveConfigBuilder.psm1
<#
.SYNOPSIS
    Calculates the final, effective configuration settings for a single PoSh-Backup job
    by merging global settings, job-specific settings, and command-line overrides.
.DESCRIPTION
    This module is a sub-component of the main ConfigManager module for PoSh-Backup.
    Its primary function, Get-PoShBackupJobEffectiveConfiguration, takes a specific job's
    raw configuration, the global configuration, and any command-line overrides, then
    resolves the final settings that will be used for that job.

    It prioritises settings in the order:
    1. Command-Line Interface (CLI) overrides.
    2. Job-specific settings from the 'BackupLocations' section.
    3. Global default settings.

    This function resolves settings for local archive creation, local retention,
    remote target assignments (by looking up 'TargetNames' in the global 'BackupTargets'
    section), PostRunAction settings, Checksum settings, and SFX creation (including SFX module type).
    The resolved configuration is then used by the Operations module to execute the backup job.

    It is designed to be called by the main PoSh-Backup script indirectly via the ConfigManager facade.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.3 # Added SFXModule resolution.
    DateCreated:    24-May-2025
    LastModified:   25-May-2025
    Purpose:        To modularise the effective job configuration building logic from the main ConfigManager module.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Utils.psm1 from the parent 'Modules' directory for Get-ConfigValue.
#>

# Explicitly import dependent Utils.psm1 from the parent 'Modules' directory.
# $PSScriptRoot here is Modules\ConfigManagement.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
} catch {
    Write-Error "EffectiveConfigBuilder.psm1 FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}

#region --- Exported Function: Get Effective Job Configuration ---
function Get-PoShBackupJobEffectiveConfiguration {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Gathers the effective configuration for a single backup job by merging global,
        job-specific, and command-line override settings, including Backup Target, PostRunAction,
        Checksum, and SFX (with module type) resolution.
    .DESCRIPTION
        This function takes a specific job's raw configuration, the global configuration,
        and any command-line overrides, then resolves the final settings that will be
        used for that job. It prioritises settings in the order: CLI overrides, then
        job-specific settings, then global settings.
        It now also resolves 'TargetNames' specified in the job configuration by looking up
        the full definitions of those targets in the global 'BackupTargets' section,
        resolves 'PostRunAction' settings, 'Checksum' settings, 'CreateSFX', and 'SFXModule' settings.
        If SFX is enabled, the effective archive extension becomes '.exe'.
    .PARAMETER JobConfig
        A hashtable containing the specific configuration settings for this backup job.
    .PARAMETER GlobalConfig
        A hashtable containing the global configuration settings for PoSh-Backup, including 'BackupTargets',
        'PostRunActionDefaults', 'Checksum' defaults, 'CreateSFX' defaults, and 'SFXModule' defaults.
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
        of 'ResolvedTargetInstances' if 'TargetNames' were specified, a 'PostRunAction' hashtable,
        checksum-related settings, and SFX-related settings (including SFXModule).
    #>
    param(
        [Parameter(Mandatory)] [hashtable]$JobConfig,
        [Parameter(Mandatory)] [hashtable]$GlobalConfig,
        [Parameter(Mandatory)] [hashtable]$CliOverrides,
        [Parameter(Mandatory)] [ref]$JobReportDataRef,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    # PSSA Appeasement: Directly use the Logger parameter once.
    & $Logger -Message "EffectiveConfigBuilder/Get-PoShBackupJobEffectiveConfiguration: Initializing effective configuration build." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    
    $effectiveConfig = @{}
    $reportData = $JobReportDataRef.Value

    $effectiveConfig.OriginalSourcePath = $JobConfig.Path
    $effectiveConfig.BaseFileName = $JobConfig.Name
    $reportData.JobConfiguration = $JobConfig 

    # Destination and Target settings
    $effectiveConfig.DestinationDir = Get-ConfigValue -ConfigObject $JobConfig -Key 'DestinationDir' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultDestinationDir' -DefaultValue $null)

    $effectiveConfig.TargetNames = @(Get-ConfigValue -ConfigObject $JobConfig -Key 'TargetNames' -DefaultValue @())
    $effectiveConfig.DeleteLocalArchiveAfterSuccessfulTransfer = Get-ConfigValue -ConfigObject $JobConfig -Key 'DeleteLocalArchiveAfterSuccessfulTransfer' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DeleteLocalArchiveAfterSuccessfulTransfer' -DefaultValue $true)
    $effectiveConfig.ResolvedTargetInstances = [System.Collections.Generic.List[hashtable]]::new()

    if ($effectiveConfig.TargetNames.Count -gt 0) {
        $globalBackupTargets = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'BackupTargets' -DefaultValue @{}
        if (-not ($globalBackupTargets -is [hashtable])) {
            & $LocalWriteLog -Message "[WARNING] EffectiveConfigBuilder: Global 'BackupTargets' configuration is missing or not a hashtable. Cannot resolve target names for job." -Level WARNING
        }
        else {
            foreach ($targetNameRef in $effectiveConfig.TargetNames) {
                if ($globalBackupTargets.ContainsKey($targetNameRef)) {
                    $targetInstanceConfig = $globalBackupTargets[$targetNameRef]
                    if ($targetInstanceConfig -is [hashtable]) {
                        $targetInstanceConfigWithName = $targetInstanceConfig.Clone()
                        $targetInstanceConfigWithName['_TargetInstanceName_'] = $targetNameRef
                        $effectiveConfig.ResolvedTargetInstances.Add($targetInstanceConfigWithName)
                        & $LocalWriteLog -Message "  - EffectiveConfigBuilder: Resolved Target Instance '$targetNameRef' (Type: $($targetInstanceConfig.Type)) for job." -Level DEBUG
                    }
                    else {
                        & $LocalWriteLog -Message "[WARNING] EffectiveConfigBuilder: Definition for TargetName '$targetNameRef' in 'BackupTargets' is not a valid hashtable. Skipping this target for job." -Level WARNING
                    }
                }
                else {
                    & $LocalWriteLog -Message "[WARNING] EffectiveConfigBuilder: TargetName '$targetNameRef' (specified in job's TargetNames) not found in global 'BackupTargets'. Skipping this target for job." -Level WARNING
                }
            }
        }
    }

    # Local Retention settings
    $effectiveConfig.LocalRetentionCount = Get-ConfigValue -ConfigObject $JobConfig -Key 'LocalRetentionCount' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultRetentionCount' -DefaultValue 3)
    if ($effectiveConfig.LocalRetentionCount -lt 0) { $effectiveConfig.LocalRetentionCount = 0 }
    $effectiveConfig.DeleteToRecycleBin = Get-ConfigValue -ConfigObject $JobConfig -Key 'DeleteToRecycleBin' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultDeleteToRecycleBin' -DefaultValue $false)
    $effectiveConfig.RetentionConfirmDelete = Get-ConfigValue -ConfigObject $JobConfig -Key 'RetentionConfirmDelete' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'RetentionConfirmDelete' -DefaultValue $true)

    # Password settings
    $effectiveConfig.ArchivePasswordMethod = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordMethod' -DefaultValue "None"
    $effectiveConfig.CredentialUserNameHint = Get-ConfigValue -ConfigObject $JobConfig -Key 'CredentialUserNameHint' -DefaultValue "BackupUser"
    $effectiveConfig.ArchivePasswordSecretName = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordSecretName' -DefaultValue $null
    $effectiveConfig.ArchivePasswordVaultName = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordVaultName' -DefaultValue $null
    $effectiveConfig.ArchivePasswordSecureStringPath = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordSecureStringPath' -DefaultValue $null
    $effectiveConfig.ArchivePasswordPlainText = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordPlainText' -DefaultValue $null
    $effectiveConfig.UsePassword = Get-ConfigValue -ConfigObject $JobConfig -Key 'UsePassword' -DefaultValue $false

    # 7-Zip Output
    $effectiveConfig.HideSevenZipOutput = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'HideSevenZipOutput' -DefaultValue $true

    # Archive Naming and Type
    $effectiveConfig.JobArchiveType = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchiveType' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultArchiveType' -DefaultValue "-t7z")
    
    # SFX Handling
    $effectiveConfig.CreateSFX = Get-ConfigValue -ConfigObject $JobConfig -Key 'CreateSFX' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultCreateSFX' -DefaultValue $false)
    $effectiveConfig.SFXModule = Get-ConfigValue -ConfigObject $JobConfig -Key 'SFXModule' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultSFXModule' -DefaultValue "Console") # NEW
    $effectiveConfig.InternalArchiveExtension = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchiveExtension' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultArchiveExtension' -DefaultValue ".7z") 
    
    if ($effectiveConfig.CreateSFX) {
        $effectiveConfig.JobArchiveExtension = ".exe"
        & $LocalWriteLog -Message "  - EffectiveConfigBuilder: CreateSFX is TRUE. Effective archive extension set to '.exe'. SFX Module: $($effectiveConfig.SFXModule)." -Level DEBUG
    } else {
        $effectiveConfig.JobArchiveExtension = $effectiveConfig.InternalArchiveExtension
    }
    # END SFX Handling

    $effectiveConfig.JobArchiveDateFormat = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchiveDateFormat' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultArchiveDateFormat' -DefaultValue "yyyy-MMM-dd")

    # 7-Zip Compression Parameters
    $effectiveConfig.JobCompressionLevel = Get-ConfigValue -ConfigObject $JobConfig -Key 'CompressionLevel' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultCompressionLevel' -DefaultValue "-mx=7")
    $effectiveConfig.JobCompressionMethod = Get-ConfigValue -ConfigObject $JobConfig -Key 'CompressionMethod' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultCompressionMethod' -DefaultValue "-m0=LZMA2")
    $effectiveConfig.JobDictionarySize = Get-ConfigValue -ConfigObject $JobConfig -Key 'DictionarySize' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultDictionarySize' -DefaultValue "-md=128m")
    $effectiveConfig.JobWordSize = Get-ConfigValue -ConfigObject $JobConfig -Key 'WordSize' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultWordSize' -DefaultValue "-mfb=64")
    $effectiveConfig.JobSolidBlockSize = Get-ConfigValue -ConfigObject $JobConfig -Key 'SolidBlockSize' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultSolidBlockSize' -DefaultValue "-ms=16g")
    $effectiveConfig.JobCompressOpenFiles = Get-ConfigValue -ConfigObject $JobConfig -Key 'CompressOpenFiles' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultCompressOpenFiles' -DefaultValue $true)
    $effectiveConfig.JobAdditionalExclusions = @(Get-ConfigValue -ConfigObject $JobConfig -Key 'AdditionalExclusions' -DefaultValue @())

    $_globalConfigThreads = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultThreadCount' -DefaultValue 0
    $_jobSpecificThreadsToUse = Get-ConfigValue -ConfigObject $JobConfig -Key 'ThreadsToUse' -DefaultValue 0
    $_threadsFor7Zip = if ($_jobSpecificThreadsToUse -gt 0) { $_jobSpecificThreadsToUse } elseif ($_globalConfigThreads -gt 0) { $_globalConfigThreads } else { 0 }
    $effectiveConfig.ThreadsSetting = if ($_threadsFor7Zip -gt 0) { "-mmt=$($_threadsFor7Zip)" } else { "-mmt" }

    # VSS Settings
    $effectiveConfig.JobEnableVSS = if ($CliOverrides.UseVSS) { $true } else { Get-ConfigValue -ConfigObject $JobConfig -Key 'EnableVSS' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'EnableVSS' -DefaultValue $false) }
    $effectiveConfig.JobVSSContextOption = Get-ConfigValue -ConfigObject $JobConfig -Key 'VSSContextOption' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultVSSContextOption' -DefaultValue "Persistent NoWriters")
    $_vssCachePathFromConfig = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'VSSMetadataCachePath' -DefaultValue "%TEMP%\diskshadow_cache_poshbackup.cab"
    $effectiveConfig.VSSMetadataCachePath = [System.Environment]::ExpandEnvironmentVariables($_vssCachePathFromConfig)
    $effectiveConfig.VSSPollingTimeoutSeconds = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'VSSPollingTimeoutSeconds' -DefaultValue 120
    $effectiveConfig.VSSPollingIntervalSeconds = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'VSSPollingIntervalSeconds' -DefaultValue 5

    # Retry Settings
    $effectiveConfig.JobEnableRetries = if ($CliOverrides.EnableRetries) { $true } else { Get-ConfigValue -ConfigObject $JobConfig -Key 'EnableRetries' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'EnableRetries' -DefaultValue $true) }
    $effectiveConfig.JobMaxRetryAttempts = Get-ConfigValue -ConfigObject $JobConfig -Key 'MaxRetryAttempts' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'MaxRetryAttempts' -DefaultValue 3)
    $effectiveConfig.JobRetryDelaySeconds = Get-ConfigValue -ConfigObject $JobConfig -Key 'RetryDelaySeconds' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'RetryDelaySeconds' -DefaultValue 60)

    if ($null -ne $CliOverrides.TreatSevenZipWarningsAsSuccess) {
        $effectiveConfig.TreatSevenZipWarningsAsSuccess = $CliOverrides.TreatSevenZipWarningsAsSuccess
    }
    else {
        $effectiveConfig.TreatSevenZipWarningsAsSuccess = Get-ConfigValue -ConfigObject $JobConfig -Key 'TreatSevenZipWarningsAsSuccess' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'TreatSevenZipWarningsAsSuccess' -DefaultValue $false)
    }
    $reportData.TreatSevenZipWarningsAsSuccess = $effectiveConfig.TreatSevenZipWarningsAsSuccess

    $effectiveConfig.JobSevenZipProcessPriority = if (-not [string]::IsNullOrWhiteSpace($CliOverrides.SevenZipPriority)) {
        $CliOverrides.SevenZipPriority
    }
    else {
        Get-ConfigValue -ConfigObject $JobConfig -Key 'SevenZipProcessPriority' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultSevenZipProcessPriority' -DefaultValue "Normal")
    }

    $effectiveConfig.JobTestArchiveAfterCreation = if ($CliOverrides.TestArchive) { $true } else { Get-ConfigValue -ConfigObject $JobConfig -Key 'TestArchiveAfterCreation' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultTestArchiveAfterCreation' -DefaultValue $false) }

    $effectiveConfig.JobMinimumRequiredFreeSpaceGB = Get-ConfigValue -ConfigObject $JobConfig -Key 'MinimumRequiredFreeSpaceGB' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'MinimumRequiredFreeSpaceGB' -DefaultValue 0)
    $effectiveConfig.JobExitOnLowSpace = Get-ConfigValue -ConfigObject $JobConfig -Key 'ExitOnLowSpaceIfBelowMinimum' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'ExitOnLowSpaceIfBelowMinimum' -DefaultValue $false)

    $effectiveConfig.PreBackupScriptPath = Get-ConfigValue -ConfigObject $JobConfig -Key 'PreBackupScriptPath' -DefaultValue $null
    $effectiveConfig.PostBackupScriptOnSuccessPath = Get-ConfigValue -ConfigObject $JobConfig -Key 'PostBackupScriptOnSuccessPath' -DefaultValue $null
    $effectiveConfig.PostBackupScriptOnFailurePath = Get-ConfigValue -ConfigObject $JobConfig -Key 'PostBackupScriptOnFailurePath' -DefaultValue $null
    $effectiveConfig.PostBackupScriptAlwaysPath = Get-ConfigValue -ConfigObject $JobConfig -Key 'PostBackupScriptAlwaysPath' -DefaultValue $null

    $jobPostRunActionConfig = Get-ConfigValue -ConfigObject $JobConfig -Key 'PostRunAction' -DefaultValue $null
    $globalPostRunActionDefaults = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'PostRunActionDefaults' -DefaultValue @{}
    $effectivePostRunAction = $globalPostRunActionDefaults.Clone()
    if ($null -ne $jobPostRunActionConfig -and $jobPostRunActionConfig -is [hashtable]) {
        if ($jobPostRunActionConfig.ContainsKey('Enabled') -and $jobPostRunActionConfig.Enabled -is [boolean]) { $effectivePostRunAction.Enabled = $jobPostRunActionConfig.Enabled }
        if ($jobPostRunActionConfig.ContainsKey('Action') -and $jobPostRunActionConfig.Action -is [string]) { $effectivePostRunAction.Action = $jobPostRunActionConfig.Action }
        if ($jobPostRunActionConfig.ContainsKey('DelaySeconds') -and $jobPostRunActionConfig.DelaySeconds -is [int]) { $effectivePostRunAction.DelaySeconds = $jobPostRunActionConfig.DelaySeconds }
        if ($jobPostRunActionConfig.ContainsKey('TriggerOnStatus') -and $jobPostRunActionConfig.TriggerOnStatus -is [array]) { $effectivePostRunAction.TriggerOnStatus = @($jobPostRunActionConfig.TriggerOnStatus) }
        if ($jobPostRunActionConfig.ContainsKey('ForceAction') -and $jobPostRunActionConfig.ForceAction -is [boolean]) { $effectivePostRunAction.ForceAction = $jobPostRunActionConfig.ForceAction }
    }
    $effectiveConfig.PostRunAction = $effectivePostRunAction

    $effectiveConfig.GenerateArchiveChecksum = Get-ConfigValue -ConfigObject $JobConfig -Key 'GenerateArchiveChecksum' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultGenerateArchiveChecksum' -DefaultValue $false)
    $effectiveConfig.ChecksumAlgorithm = Get-ConfigValue -ConfigObject $JobConfig -Key 'ChecksumAlgorithm' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultChecksumAlgorithm' -DefaultValue "SHA256")
    $effectiveConfig.VerifyArchiveChecksumOnTest = Get-ConfigValue -ConfigObject $JobConfig -Key 'VerifyArchiveChecksumOnTest' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultVerifyArchiveChecksumOnTest' -DefaultValue $false)

    $reportData.SourcePath = if ($effectiveConfig.OriginalSourcePath -is [array]) { $effectiveConfig.OriginalSourcePath } else { @($effectiveConfig.OriginalSourcePath) }
    $reportData.VSSUsed = $effectiveConfig.JobEnableVSS
    $reportData.RetriesEnabled = $effectiveConfig.JobEnableRetries
    $reportData.ArchiveTested = $effectiveConfig.JobTestArchiveAfterCreation
    $reportData.SevenZipPriority = $effectiveConfig.JobSevenZipProcessPriority
    $reportData.GenerateArchiveChecksum = $effectiveConfig.GenerateArchiveChecksum
    $reportData.ChecksumAlgorithm = $effectiveConfig.ChecksumAlgorithm
    $reportData.VerifyArchiveChecksumOnTest = $effectiveConfig.VerifyArchiveChecksumOnTest
    $reportData.CreateSFX = $effectiveConfig.CreateSFX 
    $reportData.SFXModule = $effectiveConfig.SFXModule # NEW: Add to report data

    $effectiveConfig.GlobalConfigRef = $GlobalConfig

    return $effectiveConfig
}
#endregion

Export-ModuleMember -Function Get-PoShBackupJobEffectiveConfiguration
