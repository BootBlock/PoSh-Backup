# Modules\ScriptModes\MaintenanceAndVerification.psm1
<#
.SYNOPSIS
    Handles maintenance mode and backup verification script modes for PoSh-Backup.
.DESCRIPTION
    This module is a sub-component of ScriptModeHandler.psm1. It encapsulates the logic
    for the following command-line switches:
    - -Maintenance
    - -RunVerificationJobs
    - -VerificationJobName
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Added logic for -VerificationJobName.
    DateCreated:    15-Jun-2025
    LastModified:   20-Jun-2025
    Purpose:        To handle maintenance and verification script execution modes for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\ScriptModes\
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Modules\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Warning "ScriptModes\MaintenanceAndVerification.psm1: Could not import Utils.psm1. Error: $($_.Exception.Message)"
}
#endregion

function Invoke-PoShBackupMaintenanceAndVerificationMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$RunVerificationJobsSwitch,
        [Parameter(Mandatory = $false)]
        [string]$VerificationJobName,
        [Parameter(Mandatory = $false)]
        [Nullable[bool]]$MaintenanceSwitchValue,
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    if ($RunVerificationJobsSwitch -or (-not [string]::IsNullOrWhiteSpace($VerificationJobName))) {
        & $LocalWriteLog -Message "`n--- Automated Backup Verification Mode ---" -Level "HEADING"
        $verificationManagerPath = Join-Path -Path $PSScriptRoot -ChildPath "..\Managers\VerificationManager.psm1"
        try {
            if (-not (Test-Path -LiteralPath $verificationManagerPath -PathType Leaf)) {
                throw "VerificationManager.psm1 not found at '$verificationManagerPath'."
            }
            Import-Module -Name $verificationManagerPath -Force -ErrorAction Stop
            if (-not (Get-Command Invoke-PoShBackupVerification -ErrorAction SilentlyContinue)) {
                throw "Could not find the Invoke-PoShBackupVerification command after importing the module."
            }

            $verificationParams = @{
                Configuration = $Configuration
                Logger        = $Logger
                PSCmdlet      = $PSCmdletInstance
            }

            if (-not [string]::IsNullOrWhiteSpace($VerificationJobName)) {
                # Add the specific job name to the parameters if it was provided
                $verificationParams.Add('SpecificVerificationJobName', $VerificationJobName)
            }

            Invoke-PoShBackupVerification @verificationParams

        } catch {
            & $LocalWriteLog -Message "[FATAL] ScriptModes/MaintenanceAndVerification: Error during verification job mode. Error: $($_.Exception.Message)" -Level "ERROR"
        }
        & $LocalWriteLog -Message "`n--- Verification Run Finished ---" -Level "HEADING"
        return $true # Handled
    }

    if ($PSBoundParameters.ContainsKey('MaintenanceSwitchValue')) {
        & $LocalWriteLog -Message "`n--- Maintenance Mode Management ---" -Level "HEADING"
        $maintenanceFilePathFromConfig = Get-ConfigValue -ConfigObject $Configuration -Key 'MaintenanceModeFilePath' -DefaultValue '.\.maintenance'
        $maintenanceFileFullPath = $maintenanceFilePathFromConfig
        $scriptRootPath = $Configuration['_PoShBackup_PSScriptRoot']

        if (-not [System.IO.Path]::IsPathRooted($maintenanceFilePathFromConfig)) {
            if ([string]::IsNullOrWhiteSpace($scriptRootPath)) {
                & $LocalWriteLog -Message "  - FAILED to resolve maintenance file path. Script root path is unknown." -Level "ERROR"
                return $true # Handled
            }
            $maintenanceFileFullPath = Join-Path -Path $scriptRootPath -ChildPath $maintenanceFilePathFromConfig
        }

        if ($MaintenanceSwitchValue -eq $true) {
            & $LocalWriteLog -Message "ScriptModes/MaintenanceAndVerification: Enabling maintenance mode by creating flag file: '$maintenanceFileFullPath'" -Level "INFO"
            if (Test-Path -LiteralPath $maintenanceFileFullPath -PathType Leaf) {
                & $LocalWriteLog -Message "  - Maintenance mode is already enabled (flag file exists)." -Level "INFO"
            } else {
                try {
                    $maintenanceFileContent = @"
#
# PoSh-Backup Maintenance Mode Flag File
#
# This file's existence  places  PoSh-Backup into maintenance mode.
# While this file exists, no new backup jobs will be started unless
# forced to via the '-ForceRunInMaintenanceMode' switch.
#
# To disable maintenance mode,  either  delete  this  file manually,
# or run:
#          .\\PoSh-Backup.ps1 -Maintenance `$false
#
# Enabled On: $(Get-Date -Format 'o')
# Enabled By: $($env:USERDOMAIN)\$($env:USERNAME) on $($env:COMPUTERNAME)
#
"@
                    Set-Content -Path $maintenanceFileFullPath -Value $maintenanceFileContent -Encoding UTF8 -Force -ErrorAction Stop
                    & $LocalWriteLog -Message "  - Maintenance mode has been ENABLED." -Level "SUCCESS"
                } catch {
                    & $LocalWriteLog -Message "  - FAILED to create maintenance flag file. Error: $($_.Exception.Message)" -Level "ERROR"
                }
            }
        } else { # -Maintenance $false
            & $LocalWriteLog -Message "ScriptModes/MaintenanceAndVerification: Disabling maintenance mode by removing flag file: '$maintenanceFileFullPath'" -Level "INFO"
            if (Test-Path -LiteralPath $maintenanceFileFullPath -PathType Leaf) {
                try {
                    Remove-Item -LiteralPath $maintenanceFileFullPath -Force -ErrorAction Stop
                    & $LocalWriteLog -Message "  - Maintenance mode has been DISABLED." -Level "SUCCESS"
                } catch {
                    & $LocalWriteLog -Message "  - FAILED to remove maintenance flag file. Error: $($_.Exception.Message)" -Level "ERROR"
                }
            } else {
                & $LocalWriteLog -Message "  - Maintenance mode is already disabled (flag file does not exist)." -Level "INFO"
            }
        }
        return $true # Handled
    }

    return $false # No mode handled by this module
}

Export-ModuleMember -Function Invoke-PoShBackupMaintenanceAndVerificationMode
