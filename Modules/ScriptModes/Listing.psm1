# Modules\ScriptModes\Listing.psm1
<#
.SYNOPSIS
    Handles informational listing modes for PoSh-Backup, such as listing defined
    backup jobs, backup sets, or displaying the script version.
.DESCRIPTION
    This module is a sub-component of ScriptModeHandler.psm1. It encapsulates the logic
    for the following command-line switches:
    - -ListBackupLocations
    - -ListBackupSets
    - -Version
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.2.0 # Added Description field to list outputs.
    DateCreated:    15-Jun-2025
    LastModified:   21-Jun-2025
    Purpose:        To handle informational listing script execution modes for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\ScriptModes\
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Modules\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Modules\Utilities\ConsoleDisplayUtils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Warning "ScriptModes\Listing.psm1: Could not import required modules. Error: $($_.Exception.Message)"
}
#endregion

function Invoke-PoShBackupListingMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$ListBackupLocationsSwitch,
        [Parameter(Mandatory = $true)]
        [bool]$ListBackupSetsSwitch,
        [Parameter(Mandatory = $true)]
        [bool]$VersionSwitch,
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,
        [Parameter(Mandatory = $true)]
        [string]$ActualConfigFile,
        [Parameter(Mandatory = $true)]
        [hashtable]$ConfigLoadResult,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    # PSSA Appeasement: Use the Logger parameter directly.
    & $Logger -Message "ScriptModes/Listing: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    if ($VersionSwitch) {
        $mainScriptPathForVersion = Join-Path -Path $Configuration['_PoShBackup_PSScriptRoot'] -ChildPath "PoSh-Backup.ps1"
        $scriptVersion = "N/A"
        if (Test-Path -LiteralPath $mainScriptPathForVersion -PathType Leaf) {
            $mainScriptContent = Get-Content -LiteralPath $mainScriptPathForVersion -Raw -ErrorAction SilentlyContinue
            $scriptVersion = Get-ScriptVersionFromContent -ScriptContent $mainScriptContent -ScriptNameForWarning "PoSh-Backup.ps1"
        }
        Write-Host "PoSh-Backup Version: $scriptVersion"
        return $true # Handled
    }

    if ($ListBackupLocationsSwitch) {
        Write-ConsoleBanner -NameText "Defined Backup Locations (Jobs)" -ValueText $ActualConfigFile -CenterText -PrependNewLine
        if ($ConfigLoadResult.UserConfigLoaded) {
            & $LocalWriteLog -Message "(Includes overrides from '$($ConfigLoadResult.UserConfigPath)')" -Level "INFO"
        }
        if ($Configuration.BackupLocations -is [hashtable] -and $Configuration.BackupLocations.Count -gt 0) {
            $Configuration.BackupLocations.GetEnumerator() | Sort-Object Name | ForEach-Object {
                $jobConf = $_.Value
                $jobName = $_.Name

                $isEnabled = Get-ConfigValue -ConfigObject $jobConf -Key 'Enabled' -DefaultValue $true
                $jobNameColor = if ($isEnabled) { $Global:ColourSuccess } else { $Global:ColourError }
                & $LocalWriteLog -Message ("`n  Job Name      : " + $jobName) -Level "NONE" -ForegroundColour $jobNameColor

                & $LocalWriteLog -Message ("  Enabled       : " + $isEnabled) -Level "NONE"

                $jobDescription = Get-ConfigValue -ConfigObject $jobConf -Key 'Description' -DefaultValue ''
                if (-not [string]::IsNullOrWhiteSpace($jobDescription)) {
                    & $LocalWriteLog -Message ("  Description   : " + $jobDescription) -Level "NONE"
                }

                if ($jobConf.Path -is [array]) {
                    if ($jobConf.Path.Count -gt 0) {
                        & $LocalWriteLog -Message ('  Source Path(s): "{0}"' -f $jobConf.Path[0]) -Level "NONE"
                        if ($jobConf.Path.Count -gt 1) {
                            $jobConf.Path | Select-Object -Skip 1 | ForEach-Object {
                                & $LocalWriteLog -Message ('                  "{0}"' -f $_) -Level "NONE"
                            }
                        }
                    } else {
                        & $LocalWriteLog -Message ("  Source Path(s): <none specified>") -Level "NONE"
                    }
                } else {
                    & $LocalWriteLog -Message ('  Source Path(s): "{0}"' -f $jobConf.Path) -Level "NONE"
                }

                $archiveNameDisplay = Get-ConfigValue -ConfigObject $jobConf -Key 'Name' -DefaultValue 'N/A (Uses Job Name)'
                & $LocalWriteLog -Message ("  Archive Name  : " + $archiveNameDisplay) -Level "NONE"

                $destDirDisplay = Get-ConfigValue -ConfigObject $jobConf -Key 'DestinationDir' -DefaultValue (Get-ConfigValue -ConfigObject $Configuration -Key 'DefaultDestinationDir' -DefaultValue 'N/A')
                & $LocalWriteLog -Message ("  Destination   : " + $destDirDisplay) -Level "NONE"

                $targetNames = @(Get-ConfigValue -ConfigObject $jobConf -Key 'TargetNames' -DefaultValue @())
                if ($targetNames.Count -gt 0) {
                    & $LocalWriteLog -Message ("  Remote Targets: " + ($targetNames -join ", ")) -Level "NONE"
                }

                $dependsOn = @(Get-ConfigValue -ConfigObject $jobConf -Key 'DependsOnJobs' -DefaultValue @())
                if ($dependsOn.Count -gt 0) {
                    & $LocalWriteLog -Message ("  Depends On    : " + ($dependsOn -join ", ")) -Level "NONE"
                }

                $scheduleConf = Get-ConfigValue -ConfigObject $jobConf -Key 'Schedule' -DefaultValue $null
                $scheduleDisplay = "Disabled"
                if ($null -ne $scheduleConf -and $scheduleConf -is [hashtable]) {
                    $scheduleEnabled = Get-ConfigValue -ConfigObject $scheduleConf -Key 'Enabled' -DefaultValue $false
                    if ($scheduleEnabled) {
                        $scheduleType = Get-ConfigValue -ConfigObject $scheduleConf -Key 'Type' -DefaultValue "N/A"
                        $scheduleTime = Get-ConfigValue -ConfigObject $scheduleConf -Key 'Time' -DefaultValue ""
                        $scheduleDisplay = "Enabled ($scheduleType"
                        if (-not [string]::IsNullOrWhiteSpace($scheduleTime)) {
                            $scheduleDisplay += " at $scheduleTime"
                        }
                        $scheduleDisplay += ")"
                    }
                }
                & $LocalWriteLog -Message ("  Schedule      : " + $scheduleDisplay) -Level "NONE"
            }
        } else {
            & $LocalWriteLog -Message "No Backup Locations are defined in the configuration." -Level "WARNING"
        }
        Write-ConsoleBanner -NameText "Listing Complete" -BorderForegroundColor "White" -CenterText -PrependNewLine -AppendNewLine
        return $true # Handled
    }

    if ($ListBackupSetsSwitch) {
        Write-ConsoleBanner -NameText "Defined Backup Sets" -ValueText $ActualConfigFile -CenterText -PrependNewLine
        if ($ConfigLoadResult.UserConfigLoaded) {
            & $LocalWriteLog -Message "(Includes overrides from '$($ConfigLoadResult.UserConfigPath)')" -Level "INFO"
        }
        if ($Configuration.BackupSets -is [hashtable] -and $Configuration.BackupSets.Count -gt 0) {
            $Configuration.BackupSets.GetEnumerator() | Sort-Object Name | ForEach-Object {
                $setConf = $_.Value
                $setName = $_.Name
                & $LocalWriteLog -Message ("`n  Set Name   : " + $setName) -Level "NONE" -ForegroundColor "Cyan"

                $setDescription = Get-ConfigValue -ConfigObject $setConf -Key 'Description' -DefaultValue ''
                if (-not [string]::IsNullOrWhiteSpace($setDescription)) {
                    & $LocalWriteLog -Message ("  Description: " + $setDescription) -Level "NONE"
                }

                $onErrorDisplay = Get-ConfigValue -ConfigObject $setConf -Key 'OnErrorInJob' -DefaultValue 'StopSet'
                & $LocalWriteLog -Message ("  On Error   : " + $onErrorDisplay) -Level "NONE"

                $jobsInSet = @(Get-ConfigValue -ConfigObject $setConf -Key 'JobNames' -DefaultValue @())
                if ($jobsInSet.Count -gt 0) {
                    & $LocalWriteLog -Message ("  Jobs in Set ($($jobsInSet.Count)): ") -Level "NONE" -NoNewline
                    
                    # Improved job listing with status
                    foreach ($jobNameInSet in $jobsInSet) {
                        $jobColor = $Global:ColourInfo # Default color
                        $jobDisplayName = $jobNameInSet
                        $statusText = ""

                        if ($Configuration.BackupLocations.ContainsKey($jobNameInSet)) {
                            $jobConfInSet = $Configuration.BackupLocations[$jobNameInSet]
                            $isJobEnabled = Get-ConfigValue -ConfigObject $jobConfInSet -Key 'Enabled' -DefaultValue $true
                            if ($isJobEnabled) {
                                $jobColor = $Global:ColourSuccess
                                $statusText = " (Enabled)"
                            } else {
                                $jobColor = $Global:ColourError
                                $statusText = " (DISABLED)"
                            }
                        } else {
                            $jobDisplayName += " <not found>"
                            $jobColor = $Global:ColourWarning
                        }
                        # Print each job on its own line for clarity
                        & $LocalWriteLog -Message ("               - " + $jobDisplayName + $statusText) -Level "NONE" -ForegroundColour $jobColor
                    }
                } else {
                    & $LocalWriteLog -Message ("  Jobs in Set  : <none listed>") -Level "NONE"
                }
            }
        } else {
            & $LocalWriteLog -Message "No Backup Sets are defined in the configuration." -Level "WARNING"
        }
        Write-ConsoleBanner -NameText "Listing Complete" -BorderForegroundColor "White" -CenterText -PrependNewLine -AppendNewLine
        return $true # Handled
    }

    return $false # No listing mode was handled
}

Export-ModuleMember -Function Invoke-PoShBackupListingMode
