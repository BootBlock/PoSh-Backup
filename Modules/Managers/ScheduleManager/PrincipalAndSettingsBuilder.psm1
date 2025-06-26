# Modules\Managers\ScheduleManager\PrincipalAndSettingsBuilder.psm1
<#
.SYNOPSIS
    A sub-module for ScheduleManager. Handles the construction of the scheduled task
    principal and settings objects.
.DESCRIPTION
    This module provides functions to create the 'ScheduledTaskPrincipal' and
    'ScheduledTaskSettingsSet' objects required for a PoSh-Backup scheduled task.
    - 'New-PoShBackupTaskPrincipal' determines the user account the task should run as
      (SYSTEM or the current user) and its privilege level.
    - 'New-PoShBackupTaskSettings' configures the task's behaviour, such as power
      management options (wake to run, battery settings) and how to handle multiple
      running instances.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    25-Jun-2025
    LastModified:   25-Jun-2025
    Purpose:        To build the ScheduledTaskPrincipal and ScheduledTaskSettingsSet objects.
    Prerequisites:  PowerShell 5.1+.
#>

function Get-PoShBackupTaskPrincipal {
    [CmdletBinding()]
    [OutputType([Microsoft.Management.Infrastructure.CimInstance])]
    param(
        # A hashtable containing the specific schedule settings for a job.
        [Parameter(Mandatory = $true)]
        [hashtable]$ScheduleConfig,

        # A scriptblock reference to the main Write-LogMessage function.
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "ScheduleManager/PrincipalBuilder: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue

    try {
        $principalUser = if ($ScheduleConfig.RunAsUser -eq 'SYSTEM') { "NT AUTHORITY\SYSTEM" } else { ([System.Security.Principal.WindowsIdentity]::GetCurrent()).Name }
        $principalRunLevel = if ($ScheduleConfig.HighestPrivileges -eq $true) { 'Highest' } else { 'Limited' }

        & $Logger -Message "  - PrincipalBuilder: Creating principal to run as '$principalUser' with '$principalRunLevel' privileges." -Level "DEBUG"
        
        # S4U (Service For User) logon type allows tasks to run without storing the password,
        # which is ideal for the 'Author' (current user) setting.
        return New-ScheduledTaskPrincipal -UserId $principalUser -LogonType S4U -RunLevel $principalRunLevel -ErrorAction Stop
    }
    catch {
        & $Logger -Message "  - PrincipalBuilder: Failed to create ScheduledTaskPrincipal object. Error: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

function Get-PoShBackupTaskSettingSet {
    [CmdletBinding()]
    [OutputType([Microsoft.Management.Infrastructure.CimInstance])]
    param(
        # A hashtable containing the specific schedule settings for a job.
        [Parameter(Mandatory = $true)]
        [hashtable]$ScheduleConfig,

        # A scriptblock reference to the main Write-LogMessage function.
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "ScheduleManager/SettingsBuilder: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue

    try {
        # Build a hashtable of parameters to splat to New-ScheduledTaskSettingsSet
        $settingsParams = @{
            AllowStartIfOnBatteries = ($ScheduleConfig.AllowStartIfOnBatteries -eq $true)
            DontStopIfGoingOnBatteries  = ($ScheduleConfig.StopIfGoingOnBatteries -eq $false)
            WakeToRun                   = ($ScheduleConfig.WakeToRun -eq $true)
            ExecutionTimeLimit          = (New-TimeSpan -Hours 12) # A generous default timeout
            MultipleInstances           = 'IgnoreNew' # Don't start a new instance if one is already running
            StartWhenAvailable          = $true # Run the task as soon as possible after a scheduled start is missed
            ErrorAction                 = 'Stop'
        }

        & $Logger -Message "  - SettingsBuilder: Creating task settings object." -Level "DEBUG"

        return New-ScheduledTaskSettingsSet @settingsParams
    }
    catch {
        & $Logger -Message "  - SettingsBuilder: Failed to create ScheduledTaskSettingsSet object. Error: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

Export-ModuleMember -Function Get-PoShBackupTaskPrincipal, Get-PoShBackupTaskSettingSet
