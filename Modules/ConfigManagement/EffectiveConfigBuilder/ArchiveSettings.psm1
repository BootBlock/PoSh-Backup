# Modules\ConfigManagement\EffectiveConfigBuilder\ArchiveSettings.psm1
<#
.SYNOPSIS
    Resolves archive-specific configuration settings for a PoSh-Backup job.
.DESCRIPTION
    This sub-module for EffectiveConfigBuilder.psm1 determines the effective
    settings related to the archive file itself, including its type, naming convention
    (date format), Self-Extracting Archive (SFX) options, multi-volume (split) settings,
    checksum generation/verification parameters, and split archive manifest generation.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Added GenerateContentsManifest resolution.
    DateCreated:    30-May-2025
    LastModified:   12-Jun-2025
    Purpose:        Archive-specific settings resolution.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Utils.psm1 from the main Modules directory.
#>

# Explicitly import Utils.psm1 from the main Modules directory.
# $PSScriptRoot here is Modules\ConfigManagement\EffectiveConfigBuilder.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Utils.psm1") -Force -ErrorAction Stop
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
    $resolvedSettings.JobArchiveType = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchiveType' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultArchiveType' -DefaultValue "-t7z")
    $resolvedSettings.InternalArchiveExtension = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchiveExtension' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultArchiveExtension' -DefaultValue ".7z")
    $resolvedSettings.JobArchiveDateFormat = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchiveDateFormat' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultArchiveDateFormat' -DefaultValue "yyyy-MMM-dd")

    # SFX Settings
    $resolvedSettings.CreateSFX = Get-ConfigValue -ConfigObject $JobConfig -Key 'CreateSFX' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultCreateSFX' -DefaultValue $false)
    $resolvedSettings.SFXModule = Get-ConfigValue -ConfigObject $JobConfig -Key 'SFXModule' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultSFXModule' -DefaultValue "Console")

    # SplitVolumeSize Settings (CLI > Job > Global > Default empty)
    $_cliSplitVolumeSize = if ($CliOverrides.ContainsKey('SplitVolumeSizeCLI') -and ($null -ne $CliOverrides.SplitVolumeSizeCLI)) { $CliOverrides.SplitVolumeSizeCLI } else { $null }
    $_jobSplitVolumeSize = Get-ConfigValue -ConfigObject $JobConfig -Key 'SplitVolumeSize' -DefaultValue $null
    $_globalSplitVolumeSize = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultSplitVolumeSize' -DefaultValue ""

    if (-not [string]::IsNullOrWhiteSpace($_cliSplitVolumeSize)) {
        $resolvedSettings.SplitVolumeSize = $_cliSplitVolumeSize
        & $LocalWriteLog -Message "  - Resolve-ArchiveConfiguration: SplitVolumeSize set by CLI override: '$($_cliSplitVolumeSize)'." -Level "DEBUG"
    } elseif (-not [string]::IsNullOrWhiteSpace($_jobSplitVolumeSize)) {
        $resolvedSettings.SplitVolumeSize = $_jobSplitVolumeSize
        & $LocalWriteLog -Message "  - Resolve-ArchiveConfiguration: SplitVolumeSize set by Job config: '$($_jobSplitVolumeSize)'." -Level "DEBUG"
    } else {
        $resolvedSettings.SplitVolumeSize = $_globalSplitVolumeSize
        if (-not [string]::IsNullOrWhiteSpace($_globalSplitVolumeSize)) {
            & $LocalWriteLog -Message "  - Resolve-ArchiveConfiguration: SplitVolumeSize set by Global config: '$($_globalSplitVolumeSize)'." -Level "DEBUG"
        } else {
            & $LocalWriteLog -Message "  - Resolve-ArchiveConfiguration: SplitVolumeSize not configured (using default: empty string)." -Level "DEBUG"
        }
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
        & $LocalWriteLog -Message "  - Resolve-ArchiveConfiguration: CreateSFX is TRUE. Effective archive extension set to '.exe'. SFX Module: $($resolvedSettings.SFXModule)." -Level "DEBUG"
    } else {
        $resolvedSettings.JobArchiveExtension = $resolvedSettings.InternalArchiveExtension
    }

    # Checksum Settings
    $resolvedSettings.GenerateArchiveChecksum = Get-ConfigValue -ConfigObject $JobConfig -Key 'GenerateArchiveChecksum' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultGenerateArchiveChecksum' -DefaultValue $false)
    $resolvedSettings.ChecksumAlgorithm = Get-ConfigValue -ConfigObject $JobConfig -Key 'ChecksumAlgorithm' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultChecksumAlgorithm' -DefaultValue "SHA256")
    $resolvedSettings.VerifyArchiveChecksumOnTest = Get-ConfigValue -ConfigObject $JobConfig -Key 'VerifyArchiveChecksumOnTest' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultVerifyArchiveChecksumOnTest' -DefaultValue $false)

    $resolvedSettings.GenerateSplitArchiveManifest = Get-ConfigValue -ConfigObject $JobConfig -Key 'GenerateSplitArchiveManifest' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultGenerateSplitArchiveManifest' -DefaultValue $false)
    $resolvedSettings.GenerateContentsManifest = Get-ConfigValue -ConfigObject $JobConfig -Key 'GenerateContentsManifest' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultGenerateContentsManifest' -DefaultValue $false)

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
