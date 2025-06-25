# Modules\ConfigManagement\EffectiveConfigBuilder\DestinationSettings.psm1
<#
.SYNOPSIS
    Resolves destination and remote target configuration settings for a PoSh-Backup job.
.DESCRIPTION
    This sub-module for EffectiveConfigBuilder.psm1 determines the effective
    DestinationDir, TargetNames, resolved target instances, and the
    DeleteLocalArchiveAfterSuccessfulTransfer setting for a job. It now strictly
    relies on Default.psd1 for default values, throwing an error if required
    settings are missing.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Refactored to remove hardcoded defaults.
    DateCreated:    30-May-2025
    LastModified:   25-Jun-2025
    Purpose:        Destination and target settings resolution.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Utils.psm1 from the main Modules directory.
#>

# Explicitly import Utils.psm1 from the main Modules directory.
# $PSScriptRoot here is Modules\ConfigManagement\EffectiveConfigBuilder.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "DestinationSettings.psm1 (EffectiveConfigBuilder submodule) FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}

#region --- Private Helper Function ---
function Get-RequiredConfigValue {
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

function Resolve-DestinationConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$JobConfig,
        [Parameter(Mandatory)] [hashtable]$GlobalConfig,
        [Parameter(Mandatory)] [hashtable]$CliOverrides, # Though not directly used for these specific settings yet
        [Parameter(Mandatory)] [scriptblock]$Logger
    )

    # PSSA: Directly use Logger and CliOverrides for initial debug message
    & $Logger -Message "EffectiveConfigBuilder/DestinationSettings/Resolve-DestinationConfiguration: Logger active. CLI Overrides count: $($CliOverrides.Count)." -Level "DEBUG" -ErrorAction SilentlyContinue
    
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    & $LocalWriteLog -Message "EffectiveConfigBuilder/DestinationSettings/Resolve-DestinationConfiguration: Resolving destination and target settings." -Level "DEBUG"

    $resolvedSettings = @{}

    # Use the new required value helper for mandatory settings.
    $resolvedSettings.DestinationDir = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'DestinationDir' -GlobalKey 'DefaultDestinationDir'
    $resolvedSettings.DeleteLocalArchiveAfterSuccessfulTransfer = Get-RequiredConfigValue -JobConfig $JobConfig -GlobalConfig $GlobalConfig -JobKey 'DeleteLocalArchiveAfterSuccessfulTransfer' -GlobalKey 'DefaultDeleteLocalArchiveAfterSuccessfulTransfer'

    # TargetNames is optional; a job can be local-only. So a hardcoded default is acceptable here.
    $resolvedSettings.TargetNames = @(Get-ConfigValue -ConfigObject $JobConfig -Key 'TargetNames' -DefaultValue @())
    
    $resolvedSettings.ResolvedTargetInstances = [System.Collections.Generic.List[hashtable]]::new()

    if ($resolvedSettings.TargetNames.Count -gt 0) {
        # BackupTargets is an optional section. If it's missing, no targets can be resolved.
        $globalBackupTargets = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'BackupTargets' -DefaultValue @{}
        if (-not ($globalBackupTargets -is [hashtable])) {
            & $LocalWriteLog -Message "[WARNING] Resolve-DestinationConfiguration: Global 'BackupTargets' configuration is missing or not a hashtable. Cannot resolve target names for job." -Level "WARNING"
        }
        else {
            foreach ($targetNameRef in $resolvedSettings.TargetNames) {
                if ($globalBackupTargets.ContainsKey($targetNameRef)) {
                    $targetInstanceConfig = $globalBackupTargets[$targetNameRef]
                    if ($targetInstanceConfig -is [hashtable]) {
                        $targetInstanceConfigWithName = $targetInstanceConfig.Clone()
                        $targetInstanceConfigWithName['_TargetInstanceName_'] = $targetNameRef
                        $resolvedSettings.ResolvedTargetInstances.Add($targetInstanceConfigWithName)
                        & $LocalWriteLog -Message "  - Resolve-DestinationConfiguration: Resolved Target Instance '$targetNameRef' (Type: $($targetInstanceConfig.Type)) for job." -Level "DEBUG"
                    }
                    else {
                        & $LocalWriteLog -Message "[WARNING] Resolve-DestinationConfiguration: Definition for TargetName '$targetNameRef' in 'BackupTargets' is not a valid hashtable. Skipping this target for job." -Level "WARNING"
                    }
                }
                else {
                    & $LocalWriteLog -Message "[WARNING] Resolve-DestinationConfiguration: TargetName '$targetNameRef' (specified in job's TargetNames) not found in global 'BackupTargets'. Skipping this target for job." -Level "WARNING"
                }
            }
        }
    }

    return $resolvedSettings
}

Export-ModuleMember -Function Resolve-DestinationConfiguration
