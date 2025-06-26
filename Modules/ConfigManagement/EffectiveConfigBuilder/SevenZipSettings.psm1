# Modules\ConfigManagement\EffectiveConfigBuilder\SevenZipSettings.psm1
<#
.SYNOPSIS
    Resolves 7-Zip specific configuration settings for a PoSh-Backup job.
.DESCRIPTION
    This sub-module for EffectiveConfigBuilder.psm1 determines the effective
    7-Zip parameters, including compression level, method, dictionary size,
    word size, solid block size, thread count, CPU affinity, paths to
    include/exclude list files, and the temporary working directory. It now strictly
    relies on Default.psd1 for all default values, throwing an error if required
    settings are missing.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.2.1 # Corrected dependency on ConfigUtils.
    DateCreated:    30-May-2025
    LastModified:   26-Jun-2025
    Purpose:        7-Zip specific settings resolution.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Utils.psm1 from the main Modules directory.
#>

# Explicitly import Utils.psm1 from the main Modules directory.
# $PSScriptRoot here is Modules\ConfigManagement\EffectiveConfigBuilder.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
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
    $resolvedSettings.JobCompressionLevel = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'CompressionLevel' -GlobalKey 'DefaultCompressionLevel'
    $resolvedSettings.JobCompressionMethod = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'CompressionMethod' -GlobalKey 'DefaultCompressionMethod'
    $resolvedSettings.JobDictionarySize = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'DictionarySize' -GlobalKey 'DefaultDictionarySize'
    $resolvedSettings.JobWordSize = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'WordSize' -GlobalKey 'DefaultWordSize'
    $resolvedSettings.JobSolidBlockSize = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'SolidBlockSize' -GlobalKey 'DefaultSolidBlockSize'
    $resolvedSettings.JobCompressOpenFiles = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'CompressOpenFiles' -GlobalKey 'DefaultCompressOpenFiles'
    $resolvedSettings.JobAdditionalExclusions = @(Get-ConfigValue -ConfigObject $JobConfig -Key 'AdditionalExclusions' -DefaultValue @()) # This can be empty, so no Get-Required
    $resolvedSettings.FollowSymbolicLinks = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'FollowSymbolicLinks' -GlobalKey 'DefaultFollowSymbolicLinks'

    # Resolve Temp Directory (optional, can be empty string)
    $resolvedSettings.JobSevenZipTempDirectory = Get-ConfigValue -ConfigObject $JobConfig -Key 'SevenZipTempDirectory' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultSevenZipTempDirectory' -DefaultValue "")
    if (-not [string]::IsNullOrWhiteSpace($resolvedSettings.JobSevenZipTempDirectory)) {
        & $LocalWriteLog -Message "  - Resolve-SevenZipConfiguration: 7-Zip Temp Directory resolved to: '$($resolvedSettings.JobSevenZipTempDirectory)'." -Level "DEBUG"
    }

    $_globalConfigThreads = Get-RequiredConfigValue -JobConfig @{} -GlobalConfig $GlobalConfig -JobKey 'DefaultThreadCount' -GlobalKey 'DefaultThreadCount'
    $_jobSpecificThreadsToUse = Get-ConfigValue -ConfigObject $JobConfig -Key 'ThreadsToUse' -DefaultValue 0 # Optional, can be 0
    $_threadsFor7Zip = if ($_jobSpecificThreadsToUse -gt 0) { $_jobSpecificThreadsToUse } elseif ($_globalConfigThreads -gt 0) { $_globalConfigThreads } else { 0 }
    $resolvedSettings.ThreadsSetting = if ($_threadsFor7Zip -gt 0) { "-mmt=$($_threadsFor7Zip)" } else { "-mmt" } # 7ZipManager ArgumentBuilder expects "-mmt" for auto

    # 7-Zip CPU Affinity (optional, can be empty string)
    $_cliAffinity = if ($CliOverrides.ContainsKey('SevenZipCpuAffinity') -and -not [string]::IsNullOrWhiteSpace($CliOverrides.SevenZipCpuAffinity)) { $CliOverrides.SevenZipCpuAffinity } else { $null }
    $_jobAffinity = Get-ConfigValue -ConfigObject $JobConfig -Key 'SevenZipCpuAffinity' -DefaultValue $null
    $_globalAffinity = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultSevenZipCpuAffinity' -DefaultValue ""

    if (-not [string]::IsNullOrWhiteSpace($_cliAffinity)) {
        $resolvedSettings.JobSevenZipCpuAffinity = $_cliAffinity
    } elseif (-not [string]::IsNullOrWhiteSpace($_jobAffinity)) {
        $resolvedSettings.JobSevenZipCpuAffinity = $_jobAffinity
    } else {
        $resolvedSettings.JobSevenZipCpuAffinity = $_globalAffinity
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
    } elseif (-not [string]::IsNullOrWhiteSpace($SetSevenZipIncludeListFile)) {
        $resolvedSettings.JobSevenZipIncludeListFile = $SetSevenZipIncludeListFile
    } elseif (-not [string]::IsNullOrWhiteSpace($_jobIncludeListFile)) {
        $resolvedSettings.JobSevenZipIncludeListFile = $_jobIncludeListFile
    } else {
        $resolvedSettings.JobSevenZipIncludeListFile = $_globalIncludeListFile
    }
    
    # Resolve Exclude List File
    if (-not [string]::IsNullOrWhiteSpace($_cliExcludeListFile)) {
        $resolvedSettings.JobSevenZipExcludeListFile = $_cliExcludeListFile
    } elseif (-not [string]::IsNullOrWhiteSpace($SetSevenZipExcludeListFile)) {
        $resolvedSettings.JobSevenZipExcludeListFile = $SetSevenZipExcludeListFile
    } elseif (-not [string]::IsNullOrWhiteSpace($_jobExcludeListFile)) {
        $resolvedSettings.JobSevenZipExcludeListFile = $_jobExcludeListFile
    } else {
        $resolvedSettings.JobSevenZipExcludeListFile = $_globalExcludeListFile
    }

    return $resolvedSettings
}

Export-ModuleMember -Function Resolve-SevenZipConfiguration
