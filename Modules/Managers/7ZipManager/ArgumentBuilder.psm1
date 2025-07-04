# Modules\Managers\7ZipManager\ArgumentBuilder.psm1
<#
.SYNOPSIS
    Sub-module for 7ZipManager. Handles the construction of 7-Zip command-line arguments.
.DESCRIPTION
    This module contains the 'Get-PoShBackup7ZipArgument' function, responsible for
    assembling the appropriate 7-Zip command-line switches and arguments for an
    archive creation operation based on the effective job configuration. It now strictly
    relies on Default.psd1 for all default values.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.3.4 # FIX: Removed redundant ValueFromPipeline attribute.
    DateCreated:    29-May-2025
    LastModified:   04-Jul-2025
    Purpose:        7-Zip argument construction logic for 7ZipManager.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers\7ZipManager.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "ArgumentBuilder.psm1 (7ZipManager submodule) FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- Internal Helper Function ---
function Get-RequiredConfigValueInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$JobConfig,
        [Parameter(Mandatory)]
        [hashtable]$GlobalConfig,
        [Parameter(Mandatory)]
        [string]$JobKey,
        [Parameter(Mandatory)]
        [string]$GlobalKey
    )

    $value = Get-ConfigValue -ConfigObject $JobConfig -Key $JobKey -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key $GlobalKey -DefaultValue $null)

    if ($null -eq $value) {
        throw "Configuration Error: A required setting is missing. The key '$JobKey' was not found in the job's configuration, and the corresponding default key '$GlobalKey' was not found in Default.psd1 or User.psd1. The script cannot proceed without this setting."
    }
    return $value
}
#endregion

#region --- 7-Zip Argument Builder ---
function Get-PoShBackup7ZipArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$EffectiveConfig,
        [Parameter(Mandatory)] [string]$FinalArchivePath,
        [Parameter(Mandatory)]
        [string[]]$CurrentJobSourcePathFor7Zip,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    # PSSA Appeasement: Directly use the Logger parameter once.
    & $Logger -Message "7ZipManager/ArgumentBuilder/Get-PoShBackup7ZipArgument: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if ($null -ne $ForegroundColour) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        }
        else {
            & $Logger -Message $Message -Level $Level
        }
    }

    $sevenZipArgs = [System.Collections.Generic.List[string]]::new()
    $sevenZipArgs.Add("a")

    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobArchiveType)) { $sevenZipArgs.Add($EffectiveConfig.JobArchiveType) }
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobCompressionLevel)) { $sevenZipArgs.Add($EffectiveConfig.JobCompressionLevel) }
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobCompressionMethod)) { $sevenZipArgs.Add($EffectiveConfig.JobCompressionMethod) }
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobDictionarySize)) { $sevenZipArgs.Add($EffectiveConfig.JobDictionarySize) }
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobWordSize)) { $sevenZipArgs.Add($EffectiveConfig.JobWordSize) }
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobSolidBlockSize)) { $sevenZipArgs.Add($EffectiveConfig.JobSolidBlockSize) }
    if ($EffectiveConfig.JobCompressOpenFiles) { $sevenZipArgs.Add("-ssw") }
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.ThreadsSetting)) { $sevenZipArgs.Add($EffectiveConfig.ThreadsSetting) }

    if ($EffectiveConfig.FollowSymbolicLinks -ne $true) {
        $sevenZipArgs.Add("-snl")
    }

    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobSevenZipTempDirectory)) {
        $tempDirPath = $EffectiveConfig.JobSevenZipTempDirectory
        if (Test-Path -LiteralPath $tempDirPath -PathType Container) {
            $sevenZipArgs.Add("-w`"$tempDirPath`"")
            & $LocalWriteLog -Message "  - 7ZipManager/ArgumentBuilder: Added custom temporary directory switch: '-w`"$tempDirPath`"'." -Level "DEBUG"
        }
        else {
            & $LocalWriteLog -Message "[WARNING] 7ZipManager/ArgumentBuilder: Configured 7-Zip temporary directory '$tempDirPath' not found or is not a directory. 7-Zip will use the system default. Please create this directory." -Level "WARNING"
        }
    }

    if ($EffectiveConfig.ContainsKey('CreateSFX') -and $EffectiveConfig.CreateSFX -eq $true) {
        $sfxModuleSwitch = "-sfx"
        if ($EffectiveConfig.ContainsKey('SFXModule')) {
            $sfxModuleType = $EffectiveConfig.SFXModule.ToString().ToUpperInvariant()
            switch ($sfxModuleType) {
                "GUI" { $sfxModuleSwitch = "-sfx7zS.sfx" }
                "INSTALLER" { $sfxModuleSwitch = "-sfx7zSD.sfx" }
            }
        }
        $sevenZipArgs.Add($sfxModuleSwitch)
        & $LocalWriteLog -Message "  - 7ZipManager/ArgumentBuilder: Added SFX switch '$sfxModuleSwitch' (SFXModule type: '$($EffectiveConfig.SFXModule)')." -Level "DEBUG"
    }

    if ($EffectiveConfig.ContainsKey('SplitVolumeSize') -and -not [string]::IsNullOrWhiteSpace($EffectiveConfig.SplitVolumeSize)) {
        $volumeSize = $EffectiveConfig.SplitVolumeSize
        if ($volumeSize -match "^\d+[kmg]$") {
            $sevenZipArgs.Add(("-v" + $volumeSize))
            & $LocalWriteLog -Message "  - 7ZipManager/ArgumentBuilder: Added multi-volume switch '-v$volumeSize'." -Level "DEBUG"
        }
    }

    $sevenZipArgs.Add((Get-RequiredConfigValueInternal -JobConfig @{} -GlobalConfig $EffectiveConfig.GlobalConfigRef -JobKey 'DefaultScriptExcludeRecycleBin' -GlobalKey 'DefaultScriptExcludeRecycleBin'))
    $sevenZipArgs.Add((Get-RequiredConfigValueInternal -JobConfig @{} -GlobalConfig $EffectiveConfig.GlobalConfigRef -JobKey 'DefaultScriptExcludeSysVolInfo' -GlobalKey 'DefaultScriptExcludeSysVolInfo'))

    $allAdditionalExclusions = @()
    $globalExclusions = Get-ConfigValue -ConfigObject $EffectiveConfig.GlobalConfigRef -Key 'DefaultAdditionalExclusions' -DefaultValue @()
    $jobExclusions = Get-ConfigValue -ConfigObject $EffectiveConfig -Key 'JobAdditionalExclusions' -DefaultValue @()

    if ($globalExclusions -is [array] -and $globalExclusions.Count -gt 0) {
        $allAdditionalExclusions += $globalExclusions
        & $LocalWriteLog -Message "  - 7ZipManager/ArgumentBuilder: Found $($globalExclusions.Count) global exclusion(s) from 'DefaultAdditionalExclusions'." -Level "DEBUG"
    }
    if ($jobExclusions -is [array] -and $jobExclusions.Count -gt 0) {
        $allAdditionalExclusions += $jobExclusions
        & $LocalWriteLog -Message "  - 7ZipManager/ArgumentBuilder: Found $($jobExclusions.Count) job-specific exclusion(s) from 'AdditionalExclusions'." -Level "DEBUG"
    }

    if ($allAdditionalExclusions.Count -gt 0) {
        foreach ($exclusion in $allAdditionalExclusions) {
            if (-not [string]::IsNullOrWhiteSpace($exclusion)) {
                $sevenZipArgs.Add($exclusion.Trim())
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobSevenZipIncludeListFile)) {
        if (Test-Path -LiteralPath $EffectiveConfig.JobSevenZipIncludeListFile -PathType Leaf) {
            $sevenZipArgs.Add("-i@`"$($EffectiveConfig.JobSevenZipIncludeListFile)`"")
            & $LocalWriteLog -Message "  - 7ZipManager/ArgumentBuilder: Added include list file: '$($EffectiveConfig.JobSevenZipIncludeListFile)'." -Level "DEBUG"
        }
        else {
            & $LocalWriteLog -Message "[WARNING] 7ZipManager/ArgumentBuilder: Specified 7-Zip Include List File '$($EffectiveConfig.JobSevenZipIncludeListFile)' not found. It will be ignored." -Level "WARNING"
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobSevenZipExcludeListFile)) {
        if (Test-Path -LiteralPath $EffectiveConfig.JobSevenZipExcludeListFile -PathType Leaf) {
            $sevenZipArgs.Add("-x@`"$($EffectiveConfig.JobSevenZipExcludeListFile)`"")
            & $LocalWriteLog -Message "  - 7ZipManager/ArgumentBuilder: Added exclude list file: '$($EffectiveConfig.JobSevenZipExcludeListFile)'." -Level "DEBUG"
        }
        else {
            & $LocalWriteLog -Message "[WARNING] 7ZipManager/ArgumentBuilder: Specified 7-Zip Exclude List File '$($EffectiveConfig.JobSevenZipExcludeListFile)' not found. It will be ignored." -Level "WARNING"
        }
    }

    if ([string]::IsNullOrWhiteSpace($FinalArchivePath)) {
        & $LocalWriteLog -Message "[CRITICAL] Final Archive Path is NULL or EMPTY in 7ZipManager/ArgumentBuilder/Get-PoShBackup7ZipArgument. 7-Zip command will likely fail or use an unexpected name." -Level ERROR
    }
    $sevenZipArgs.Add($FinalArchivePath)

    if ($null -ne $CurrentJobSourcePathFor7Zip -and $CurrentJobSourcePathFor7Zip.Count -gt 0) {
        foreach ($sourcePathItem in $CurrentJobSourcePathFor7Zip) {
            if (-not [string]::IsNullOrWhiteSpace($sourcePathItem)) {
                $sevenZipArgs.Add($sourcePathItem)
            }
        }
    }
    elseif ($null -eq $CurrentJobSourcePathFor7Zip) {
        & $LocalWriteLog -Message "[WARNING] 7ZipManager/ArgumentBuilder: CurrentJobSourcePathFor7Zip was null. No source files will be added by path." -Level "WARNING"
    }
    elseif ($CurrentJobSourcePathFor7Zip.Count -eq 0) {
        & $LocalWriteLog -Message "[INFO] 7ZipManager/ArgumentBuilder: CurrentJobSourcePathFor7Zip was an empty array. No source files will be added by path (this might be intended if using list files)." -Level "INFO"
    }

    return $sevenZipArgs.ToArray()
}
#endregion

Export-ModuleMember -Function Get-PoShBackup7ZipArgument
