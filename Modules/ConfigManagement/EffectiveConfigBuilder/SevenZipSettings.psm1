# Modules\ConfigManagement\EffectiveConfigBuilder\SevenZipSettings.psm1
<#
.SYNOPSIS
    Resolves 7-Zip specific configuration settings for a PoSh-Backup job.
.DESCRIPTION
    This sub-module for EffectiveConfigBuilder.psm1 determines the effective
    7-Zip parameters, including compression level, method, dictionary size,
    word size, solid block size, thread count, CPU affinity, paths to
    include/exclude list files, and the temporary working directory.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Added SevenZipTempDirectory resolution.
    DateCreated:    30-May-2025
    LastModified:   14-Jun-2025
    Purpose:        7-Zip specific settings resolution.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Utils.psm1 from the main Modules directory.
#>

# Explicitly import Utils.psm1 from the main Modules directory.
# $PSScriptRoot here is Modules\ConfigManagement\EffectiveConfigBuilder.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "SevenZipSettings.psm1 (EffectiveConfigBuilder submodule) FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}

function Resolve-SevenZipConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$JobConfig,
        [Parameter(Mandatory)] [hashtable]$GlobalConfig,
        [Parameter(Mandatory)] [hashtable]$CliOverrides,
        [Parameter(Mandatory)] [scriptblock]$Logger,
        [Parameter(Mandatory = $false)]
        [string]$SetSevenZipIncludeListFile = $null,
        [Parameter(Mandatory = $false)]
        [string]$SetSevenZipExcludeListFile = $null
    )

    # PSSA: Directly use Logger for initial debug message
    & $Logger -Message "EffectiveConfigBuilder/SevenZipSettings/Resolve-SevenZipConfiguration: Logger active. CLI Overrides count: $($CliOverrides.Count)." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    & $LocalWriteLog -Message "EffectiveConfigBuilder/SevenZipSettings/Resolve-SevenZipConfiguration: Resolving 7-Zip specific settings." -Level "DEBUG"

    $resolvedSettings = @{}

    # 7-Zip Compression Parameters
    $resolvedSettings.JobCompressionLevel = Get-ConfigValue -ConfigObject $JobConfig -Key 'CompressionLevel' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultCompressionLevel' -DefaultValue "-mx=7")
    $resolvedSettings.JobCompressionMethod = Get-ConfigValue -ConfigObject $JobConfig -Key 'CompressionMethod' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultCompressionMethod' -DefaultValue "-m0=LZMA2")
    $resolvedSettings.JobDictionarySize = Get-ConfigValue -ConfigObject $JobConfig -Key 'DictionarySize' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultDictionarySize' -DefaultValue "-md=128m")
    $resolvedSettings.JobWordSize = Get-ConfigValue -ConfigObject $JobConfig -Key 'WordSize' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultWordSize' -DefaultValue "-mfb=64")
    $resolvedSettings.JobSolidBlockSize = Get-ConfigValue -ConfigObject $JobConfig -Key 'SolidBlockSize' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultSolidBlockSize' -DefaultValue "-ms=16g")
    $resolvedSettings.JobCompressOpenFiles = Get-ConfigValue -ConfigObject $JobConfig -Key 'CompressOpenFiles' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultCompressOpenFiles' -DefaultValue $true)
    $resolvedSettings.JobAdditionalExclusions = @(Get-ConfigValue -ConfigObject $JobConfig -Key 'AdditionalExclusions' -DefaultValue @())
    $resolvedSettings.FollowSymbolicLinks = Get-ConfigValue -ConfigObject $JobConfig -Key 'FollowSymbolicLinks' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultFollowSymbolicLinks' -DefaultValue $false)

    # Resolve Temp Directory
    $resolvedSettings.JobSevenZipTempDirectory = Get-ConfigValue -ConfigObject $JobConfig -Key 'SevenZipTempDirectory' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultSevenZipTempDirectory' -DefaultValue "")
    if (-not [string]::IsNullOrWhiteSpace($resolvedSettings.JobSevenZipTempDirectory)) {
        & $LocalWriteLog -Message "  - Resolve-SevenZipConfiguration: 7-Zip Temp Directory resolved to: '$($resolvedSettings.JobSevenZipTempDirectory)'." -Level "DEBUG"
    }

    $_globalConfigThreads = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultThreadCount' -DefaultValue 0
    $_jobSpecificThreadsToUse = Get-ConfigValue -ConfigObject $JobConfig -Key 'ThreadsToUse' -DefaultValue 0
    $_threadsFor7Zip = if ($_jobSpecificThreadsToUse -gt 0) { $_jobSpecificThreadsToUse } elseif ($_globalConfigThreads -gt 0) { $_globalConfigThreads } else { 0 }
    $resolvedSettings.ThreadsSetting = if ($_threadsFor7Zip -gt 0) { "-mmt=$($_threadsFor7Zip)" } else { "-mmt" } # 7ZipManager ArgumentBuilder expects "-mmt" for auto

    # 7-Zip CPU Affinity (CLI > Job > Global > Default empty string)
    $_cliAffinity = if ($CliOverrides.ContainsKey('SevenZipCpuAffinity') -and -not [string]::IsNullOrWhiteSpace($CliOverrides.SevenZipCpuAffinity)) { $CliOverrides.SevenZipCpuAffinity } else { $null }
    $_jobAffinity = Get-ConfigValue -ConfigObject $JobConfig -Key 'SevenZipCpuAffinity' -DefaultValue $null
    $_globalAffinity = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultSevenZipCpuAffinity' -DefaultValue ""

    if (-not [string]::IsNullOrWhiteSpace($_cliAffinity)) {
        $resolvedSettings.JobSevenZipCpuAffinity = $_cliAffinity
        & $LocalWriteLog -Message "  - Resolve-SevenZipConfiguration: 7-Zip CPU Affinity set by CLI override: '$($_cliAffinity)'." -Level "DEBUG"
    } elseif (-not [string]::IsNullOrWhiteSpace($_jobAffinity)) {
        $resolvedSettings.JobSevenZipCpuAffinity = $_jobAffinity
        & $LocalWriteLog -Message "  - Resolve-SevenZipConfiguration: 7-Zip CPU Affinity set by Job config: '$($_jobAffinity)'." -Level "DEBUG"
    } elseif (-not [string]::IsNullOrWhiteSpace($_globalAffinity)) {
        $resolvedSettings.JobSevenZipCpuAffinity = $_globalAffinity
        & $LocalWriteLog -Message "  - Resolve-SevenZipConfiguration: 7-Zip CPU Affinity set by Global config: '$($_globalAffinity)'." -Level "DEBUG"
    } else {
        $resolvedSettings.JobSevenZipCpuAffinity = ""
        & $LocalWriteLog -Message "  - Resolve-SevenZipConfiguration: 7-Zip CPU Affinity not configured (using default: empty string)." -Level "DEBUG"
    }

    # 7-Zip Include/Exclude List Files (CLI > Set > Job > Global > Default empty string)
    $_cliIncludeListFile = if ($CliOverrides.ContainsKey('SevenZipIncludeListFile') -and -not [string]::IsNullOrWhiteSpace($CliOverrides.SevenZipIncludeListFile)) { $CliOverrides.SevenZipIncludeListFile } else { $null }
    $_cliExcludeListFile = if ($CliOverrides.ContainsKey('SevenZipExcludeListFile') -and -not [string]::IsNullOrWhiteSpace($CliOverrides.SevenZipExcludeListFile)) { $CliOverrides.SevenZipExcludeListFile } else { $null }

    $_jobIncludeListFile = Get-ConfigValue -ConfigObject $JobConfig -Key 'SevenZipIncludeListFile' -DefaultValue $null
    $_jobExcludeListFile = Get-ConfigValue -ConfigObject $JobConfig -Key 'SevenZipExcludeListFile' -DefaultValue $null

    $_globalIncludeListFile = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultSevenZipIncludeListFile' -DefaultValue ""
    $_globalExcludeListFile = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultSevenZipExcludeListFile' -DefaultValue ""

    # Resolve Include List File
    if (-not [string]::IsNullOrWhiteSpace($_cliIncludeListFile)) {
        $resolvedSettings.JobSevenZipIncludeListFile = $_cliIncludeListFile
        & $LocalWriteLog -Message "  - Resolve-SevenZipConfiguration: 7-Zip Include List File set by CLI override: '$($_cliIncludeListFile)'." -Level "DEBUG"
    } elseif (-not [string]::IsNullOrWhiteSpace($SetSevenZipIncludeListFile)) {
        $resolvedSettings.JobSevenZipIncludeListFile = $SetSevenZipIncludeListFile
        & $LocalWriteLog -Message "  - Resolve-SevenZipConfiguration: 7-Zip Include List File set by Set config: '$($SetSevenZipIncludeListFile)'." -Level "DEBUG"
    } elseif (-not [string]::IsNullOrWhiteSpace($_jobIncludeListFile)) {
        $resolvedSettings.JobSevenZipIncludeListFile = $_jobIncludeListFile
        & $LocalWriteLog -Message "  - Resolve-SevenZipConfiguration: 7-Zip Include List File set by Job config: '$($_jobIncludeListFile)'." -Level "DEBUG"
    } else {
        $resolvedSettings.JobSevenZipIncludeListFile = $_globalIncludeListFile
        if (-not [string]::IsNullOrWhiteSpace($_globalIncludeListFile)) {
            & $LocalWriteLog -Message "  - Resolve-SevenZipConfiguration: 7-Zip Include List File set by Global config: '$($_globalIncludeListFile)'." -Level "DEBUG"
        } else {
            & $LocalWriteLog -Message "  - Resolve-SevenZipConfiguration: 7-Zip Include List File not configured (using default: empty string)." -Level "DEBUG"
        }
    }
    # Resolve Exclude List File
    if (-not [string]::IsNullOrWhiteSpace($_cliExcludeListFile)) {
        $resolvedSettings.JobSevenZipExcludeListFile = $_cliExcludeListFile
        & $LocalWriteLog -Message "  - Resolve-SevenZipConfiguration: 7-Zip Exclude List File set by CLI override: '$($_cliExcludeListFile)'." -Level "DEBUG"
    } elseif (-not [string]::IsNullOrWhiteSpace($SetSevenZipExcludeListFile)) {
        $resolvedSettings.JobSevenZipExcludeListFile = $SetSevenZipExcludeListFile
        & $LocalWriteLog -Message "  - Resolve-SevenZipConfiguration: 7-Zip Exclude List File set by Set config: '$($SetSevenZipExcludeListFile)'." -Level "DEBUG"
    } elseif (-not [string]::IsNullOrWhiteSpace($_jobExcludeListFile)) {
        $resolvedSettings.JobSevenZipExcludeListFile = $_jobExcludeListFile
        & $LocalWriteLog -Message "  - Resolve-SevenZipConfiguration: 7-Zip Exclude List File set by Job config: '$($_jobExcludeListFile)'." -Level "DEBUG"
    } else {
        $resolvedSettings.JobSevenZipExcludeListFile = $_globalExcludeListFile
        if (-not [string]::IsNullOrWhiteSpace($_globalExcludeListFile)) {
            & $LocalWriteLog -Message "  - Resolve-SevenZipConfiguration: 7-Zip Exclude List File set by Global config: '$($_globalExcludeListFile)'." -Level "DEBUG"
        } else {
            & $LocalWriteLog -Message "  - Resolve-SevenZipConfiguration: 7-Zip Exclude List File not configured (using default: empty string)." -Level "DEBUG"
        }
    }

    return $resolvedSettings
}

Export-ModuleMember -Function Resolve-SevenZipConfiguration
