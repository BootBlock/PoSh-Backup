# Modules\ConfigManagement\EffectiveConfigBuilder\ArchiveSettings.psm1
<#
.SYNOPSIS
    Resolves archive-specific configuration settings for a PoSh-Backup job.
.DESCRIPTION
    This sub-module for EffectiveConfigBuilder.psm1 determines the effective
    settings related to the archive file itself, including its type, naming convention
    (date format), Self-Extracting Archive (SFX) options, multi-volume (split) settings,
    checksum generation/verification parameters, and split archive manifest generation.
    It now strictly relies on Default.psd1 for all default values, throwing an error
    if required settings are missing.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.2.1 # Corrected dependency on ConfigUtils.
    DateCreated:    30-May-2025
    LastModified:   26-Jun-2025
    Purpose:        Archive-specific settings resolution.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Utils.psm1 from the main Modules directory.
#>

# Explicitly import Utils.psm1 from the main Modules directory.
# $PSScriptRoot here is Modules\ConfigManagement\EffectiveConfigBuilder.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "ArchiveSettings.psm1 (EffectiveConfigBuilder submodule) FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}

function Resolve-ArchiveConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$JobConfig,
        [Parameter(Mandatory)] [hashtable]$GlobalConfig,
        [Parameter(Mandatory)] [hashtable]$CliOverrides,
        [Parameter(Mandatory)] [scriptblock]$Logger,
        [Parameter(Mandatory)] [ref]$JobReportDataRef # To update SFXCreationOverriddenBySplit
    )

    # PSSA: Directly use Logger and CliOverrides for initial debug message
    & $Logger -Message "EffectiveConfigBuilder/ArchiveSettings/Resolve-ArchiveConfiguration: Logger active. CLI Overrides count: $($CliOverrides.Count)." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    & $LocalWriteLog -Message "EffectiveConfigBuilder/ArchiveSettings/Resolve-ArchiveConfiguration: Resolving archive specific settings." -Level "DEBUG"

    $resolvedSettings = @{}
    $reportData = $JobReportDataRef.Value

    # Archive Naming and Type
    $resolvedSettings.JobArchiveType = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'ArchiveType' -GlobalKey 'DefaultArchiveType'
    $resolvedSettings.InternalArchiveExtension = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'ArchiveExtension' -GlobalKey 'DefaultArchiveExtension'
    $resolvedSettings.JobArchiveDateFormat = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'ArchiveDateFormat' -GlobalKey 'DefaultArchiveDateFormat'

    # SFX Settings
    $resolvedSettings.CreateSFX = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'CreateSFX' -GlobalKey 'DefaultCreateSFX'
    $resolvedSettings.SFXModule = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'SFXModule' -GlobalKey 'DefaultSFXModule'

    # SplitVolumeSize Settings (CLI > Job > Global > Default empty)
    $_cliSplitVolumeSize = if ($CliOverrides.ContainsKey('SplitVolumeSizeCLI') -and ($null -ne $CliOverrides.SplitVolumeSizeCLI)) { $CliOverrides.SplitVolumeSizeCLI } else { $null }
    $_jobSplitVolumeSize = Get-ConfigValue -ConfigObject $JobConfig -Key 'SplitVolumeSize' -DefaultValue $null
    $_globalSplitVolumeSize = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultSplitVolumeSize' -DefaultValue ""

    if (-not [string]::IsNullOrWhiteSpace($_cliSplitVolumeSize)) {
        $resolvedSettings.SplitVolumeSize = $_cliSplitVolumeSize
    } elseif (-not [string]::IsNullOrWhiteSpace($_jobSplitVolumeSize)) {
        $resolvedSettings.SplitVolumeSize = $_jobSplitVolumeSize
    } else {
        $resolvedSettings.SplitVolumeSize = $_globalSplitVolumeSize
    }
    
    # Validate the resolved SplitVolumeSize format
    if (-not [string]::IsNullOrWhiteSpace($resolvedSettings.SplitVolumeSize) -and $resolvedSettings.SplitVolumeSize -notmatch "^\d+[kmg]$") {
        & $LocalWriteLog -Message "[WARNING] Resolve-ArchiveConfiguration: Invalid SplitVolumeSize format '$($resolvedSettings.SplitVolumeSize)'. Expected number followed by 'k', 'm', or 'g'. Splitting will be disabled." -Level "WARNING"
        $resolvedSettings.SplitVolumeSize = "" # Disable if invalid
    }

    # Conflict: SplitVolumeSize takes precedence over CreateSFX
    if (-not [string]::IsNullOrWhiteSpace($resolvedSettings.SplitVolumeSize) -and $resolvedSettings.CreateSFX) {
        $jobNameForLog = if ($JobConfig.ContainsKey('Name')) { $JobConfig.Name } else { "Current Job" }
        & $LocalWriteLog -Message "[WARNING] Resolve-ArchiveConfiguration: Both SplitVolumeSize ('$($resolvedSettings.SplitVolumeSize)') and CreateSFX (`$true`) are configured for job '$jobNameForLog'. SplitVolumeSize takes precedence; SFX creation will be disabled for this job." -Level "WARNING"
        $resolvedSettings.CreateSFX = $false # Disable SFX
        $reportData.SFXCreationOverriddenBySplit = $true
    } else {
        $reportData.SFXCreationOverriddenBySplit = $false
    }

    # Determine final JobArchiveExtension
    if ($resolvedSettings.CreateSFX) {
        $resolvedSettings.JobArchiveExtension = ".exe"
    } else {
        $resolvedSettings.JobArchiveExtension = $resolvedSettings.InternalArchiveExtension
    }

    # Checksum Settings
    $resolvedSettings.GenerateArchiveChecksum = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'GenerateArchiveChecksum' -GlobalKey 'DefaultGenerateArchiveChecksum'
    $resolvedSettings.ChecksumAlgorithm = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'ChecksumAlgorithm' -GlobalKey 'DefaultChecksumAlgorithm'
    $resolvedSettings.VerifyArchiveChecksumOnTest = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'VerifyArchiveChecksumOnTest' -GlobalKey 'DefaultVerifyArchiveChecksumOnTest'
    $resolvedSettings.GenerateSplitArchiveManifest = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'GenerateSplitArchiveManifest' -GlobalKey 'DefaultGenerateSplitArchiveManifest'
    $resolvedSettings.GenerateContentsManifest = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'GenerateContentsManifest' -GlobalKey 'DefaultGenerateContentsManifest'

    # If splitting and manifest generation is enabled, GenerateArchiveChecksum (for single file) is effectively false.
    if (-not [string]::IsNullOrWhiteSpace($resolvedSettings.SplitVolumeSize) -and $resolvedSettings.GenerateSplitArchiveManifest) {
        if ($resolvedSettings.GenerateArchiveChecksum) {
            & $LocalWriteLog -Message "  - Resolve-ArchiveConfiguration: SplitVolumeSize is active and GenerateSplitArchiveManifest is true. The 'GenerateArchiveChecksum' setting (for single/first volume) will be ignored in favor of the manifest." -Level "INFO"
            $resolvedSettings.GenerateArchiveChecksum = $false # Manifest takes precedence
        }
    }
    
    return $resolvedSettings
}

Export-ModuleMember -Function Resolve-ArchiveConfiguration
