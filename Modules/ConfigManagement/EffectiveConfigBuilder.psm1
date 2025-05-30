# Modules\ConfigManagement\EffectiveConfigBuilder.psm1
<#
.SYNOPSIS
    Acts as a facade to calculate the final, effective configuration settings for a
    single PoSh-Backup job by delegating to specialized sub-modules.
.DESCRIPTION
    This module orchestrates the calculation of a job's effective configuration.
    It imports and calls functions from sub-modules located in the
    'Modules\ConfigManagement\EffectiveConfigBuilder\' directory:
    - DestinationSettings.psm1: Resolves destination and remote target settings.
    - ArchiveSettings.psm1: Resolves archive type, naming, SFX, split, and checksum settings.
    - SevenZipSettings.psm1: Resolves 7-Zip specific parameters like compression, affinity, and list files.
    - OperationalSettings.psm1: Resolves VSS, retries, password, logging, and post-run action settings.

    The main function, Get-PoShBackupJobEffectiveConfiguration, calls these sub-modules
    in sequence, aggregates their results, and populates the job report data with
    key effective settings.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Refactored into a facade with sub-modules.
    DateCreated:    24-May-2025
    LastModified:   30-May-2025
    Purpose:        Facade for effective job configuration building.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Utils.psm1 from the main Modules directory.
                    Sub-modules must exist in '.\EffectiveConfigBuilder\'.
#>

# Explicitly import Utils.psm1 from the main Modules directory.
# $PSScriptRoot here is Modules\ConfigManagement.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "EffectiveConfigBuilder.psm1 (Facade) FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}

# Import sub-modules
# $PSScriptRoot here is Modules\ConfigManagement.
$subModulesPath = Join-Path -Path $PSScriptRoot -ChildPath "EffectiveConfigBuilder"
try {
    Import-Module -Name (Join-Path -Path $subModulesPath -ChildPath "DestinationSettings.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $subModulesPath -ChildPath "ArchiveSettings.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $subModulesPath -ChildPath "SevenZipSettings.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $subModulesPath -ChildPath "OperationalSettings.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "EffectiveConfigBuilder.psm1 (Facade) FATAL: Could not import one or more required sub-modules from '$subModulesPath'. Error: $($_.Exception.Message)"
    throw
}


#region --- Exported Function: Get Effective Job Configuration ---
function Get-PoShBackupJobEffectiveConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$JobConfig,
        [Parameter(Mandatory)] [hashtable]$GlobalConfig,
        [Parameter(Mandatory)] [hashtable]$CliOverrides,
        [Parameter(Mandatory)] [ref]$JobReportDataRef,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $false)]
        [string]$SetSevenZipIncludeListFile = $null,
        [Parameter(Mandatory = $false)]
        [string]$SetSevenZipExcludeListFile = $null
    )

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    & $LocalWriteLog -Message "EffectiveConfigBuilder (Facade)/Get-PoShBackupJobEffectiveConfiguration: Orchestrating effective configuration build." -Level "DEBUG"

    $effectiveConfig = @{}
    $reportData = $JobReportDataRef.Value # Get the actual hashtable from the reference

    # Call sub-modules to resolve parts of the configuration
    $destinationSettings = Resolve-DestinationConfiguration -JobConfig $JobConfig -GlobalConfig $GlobalConfig -CliOverrides $CliOverrides -Logger $Logger
    $archiveSettings = Resolve-ArchiveConfiguration -JobConfig $JobConfig -GlobalConfig $GlobalConfig -CliOverrides $CliOverrides -Logger $Logger -JobReportDataRef $JobReportDataRef
    $sevenZipSettings = Resolve-SevenZipConfiguration -JobConfig $JobConfig -GlobalConfig $GlobalConfig -CliOverrides $CliOverrides -Logger $Logger -SetSevenZipIncludeListFile $SetSevenZipIncludeListFile -SetSevenZipExcludeListFile $SetSevenZipExcludeListFile
    $operationalSettings = Resolve-OperationalConfiguration -JobConfig $JobConfig -GlobalConfig $GlobalConfig -CliOverrides $CliOverrides -Logger $Logger

    # Merge results from sub-modules into the main effectiveConfig hashtable
    # Order of merging doesn't strictly matter here as sub-modules handle distinct setting groups.
    $destinationSettings.GetEnumerator() | ForEach-Object { $effectiveConfig[$_.Name] = $_.Value }
    $archiveSettings.GetEnumerator() | ForEach-Object { $effectiveConfig[$_.Name] = $_.Value }
    $sevenZipSettings.GetEnumerator() | ForEach-Object { $effectiveConfig[$_.Name] = $_.Value }
    $operationalSettings.GetEnumerator() | ForEach-Object { $effectiveConfig[$_.Name] = $_.Value }


    # Populate initial report data based on the now fully resolved effective settings
    # This part remains in the facade as it uses the combined effectiveConfig.
    $reportData.JobConfiguration = $JobConfig # Store the original job-specific config for reference
    $reportData.SourcePath = if ($effectiveConfig.OriginalSourcePath -is [array]) { $effectiveConfig.OriginalSourcePath } else { @($effectiveConfig.OriginalSourcePath) }
    $reportData.VSSUsed = $effectiveConfig.JobEnableVSS
    $reportData.RetriesEnabled = $effectiveConfig.JobEnableRetries
    $reportData.ArchiveTested = $effectiveConfig.JobTestArchiveAfterCreation # This is the config setting, actual test result is set later
    $reportData.SevenZipPriority = $effectiveConfig.JobSevenZipProcessPriority
    $reportData.SevenZipCpuAffinity = $effectiveConfig.JobSevenZipCpuAffinity
    $reportData.SevenZipIncludeListFile = $effectiveConfig.JobSevenZipIncludeListFile
    $reportData.SevenZipExcludeListFile = $effectiveConfig.JobSevenZipExcludeListFile
    $reportData.GenerateArchiveChecksum = $effectiveConfig.GenerateArchiveChecksum
    $reportData.ChecksumAlgorithm = $effectiveConfig.ChecksumAlgorithm
    $reportData.VerifyArchiveChecksumOnTest = $effectiveConfig.VerifyArchiveChecksumOnTest
    $reportData.CreateSFX = $effectiveConfig.CreateSFX # This reflects the potentially overridden value
    $reportData.SFXModule = $effectiveConfig.SFXModule
    $reportData.SplitVolumeSize = $effectiveConfig.SplitVolumeSize
    $reportData.TreatSevenZipWarningsAsSuccess = $effectiveConfig.TreatSevenZipWarningsAsSuccess
    $reportData.VerifyLocalArchiveBeforeTransfer = $effectiveConfig.VerifyLocalArchiveBeforeTransfer
    $reportData.EffectiveJobLogRetentionCount = $effectiveConfig.LogRetentionCount
    # SFXCreationOverriddenBySplit is already set in $reportData by Resolve-ArchiveConfiguration via $JobReportDataRef

    & $LocalWriteLog -Message "EffectiveConfigBuilder (Facade): Effective configuration build complete." -Level "DEBUG"

    return $effectiveConfig
}
#endregion

Export-ModuleMember -Function Get-PoShBackupJobEffectiveConfiguration
