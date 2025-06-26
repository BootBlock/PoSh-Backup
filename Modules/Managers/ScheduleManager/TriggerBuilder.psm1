# Modules\Managers\ScheduleManager\TriggerBuilder.psm1
<#
.SYNOPSIS
    A sub-module for ScheduleManager. Handles the construction of the scheduled task trigger.
.DESCRIPTION
    This module provides the 'New-PoShBackupTaskTrigger' function, which is responsible
    for creating a 'ScheduledTaskTrigger' object based on the schedule settings defined
    in the PoSh-Backup configuration. It can create daily, weekly, logon, and startup
    triggers.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    25-Jun-2025
    LastModified:   25-Jun-2025
    Purpose:        To build the ScheduledTaskTrigger object for a PoSh-Backup task.
    Prerequisites:  PowerShell 5.1+.
#>

function Get-PoShBackupTaskTrigger {
    [CmdletBinding()]
    [OutputType([Microsoft.Management.Infrastructure.CimInstance])]
    param(
        # A hashtable containing the specific schedule settings for a job,
        # e.g., (Type = 'Daily'; Time = '20:30').
        [Parameter(Mandatory = $true)]
        [hashtable]$ScheduleConfig,

        # A scriptblock reference to the main Write-LogMessage function.
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "ScheduleManager/TriggerBuilder: Logger active. Building trigger of type '$($ScheduleConfig.Type)'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO")
        & $Logger -Message $Message -Level $Level
    }

    $trigger = $null
    $triggerType = $ScheduleConfig.Type.ToLowerInvariant()
    
    # Time is required for most trigger types. Default to a safe value if missing, but log a warning.
    $startTime = if ($ScheduleConfig.ContainsKey('Time')) {
        try { [datetime]$ScheduleConfig.Time } catch { & $LocalWriteLog -Message "  - TriggerBuilder: Invalid time format '$($ScheduleConfig.Time)'. Using 23:00 as a fallback." -Level "WARNING"; (Get-Date).Date.AddHours(23) }
    } else {
        (Get-Date).Date.AddHours(23)
    }

    try {
        switch ($triggerType) {
            'daily' {
                & $LocalWriteLog -Message "  - TriggerBuilder: Creating Daily trigger for $startTime." -Level "DEBUG"
                $trigger = New-ScheduledTaskTrigger -Daily -At $startTime -ErrorAction Stop
            }
            'weekly' {
                if (-not $ScheduleConfig.ContainsKey('DaysOfWeek') -or -not ($ScheduleConfig.DaysOfWeek -is [array]) -or $ScheduleConfig.DaysOfWeek.Count -eq 0) {
                    throw "Schedule type is 'Weekly' but 'DaysOfWeek' array is missing or empty."
                }
                & $LocalWriteLog -Message "  - TriggerBuilder: Creating Weekly trigger for $($ScheduleConfig.DaysOfWeek -join ', ') at $startTime." -Level "DEBUG"
                $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $ScheduleConfig.DaysOfWeek -At $startTime -ErrorAction Stop
            }
            'once' {
                & $LocalWriteLog -Message "  - TriggerBuilder: Creating Once trigger for $startTime." -Level "DEBUG"
                $trigger = New-ScheduledTaskTrigger -Once -At $startTime -ErrorAction Stop
            }
            'onlogon' {
                & $LocalWriteLog -Message "  - TriggerBuilder: Creating AtLogOn trigger." -Level "DEBUG"
                $trigger = New-ScheduledTaskTrigger -AtLogOn -ErrorAction Stop
            }
            'onstartup' {
                & $LocalWriteLog -Message "  - TriggerBuilder: Creating AtStartup trigger." -Level "DEBUG"
                $trigger = New-ScheduledTaskTrigger -AtStartup -ErrorAction Stop
            }
            default {
                throw "Schedule Type '$($ScheduleConfig.Type)' is not currently supported by the TriggerBuilder."
            }
        }
        return $trigger
    }
    catch {
        & $LocalWriteLog -Message "  - TriggerBuilder: Failed to create ScheduledTaskTrigger object. Error: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

Export-ModuleMember -Function Get-PoShBackupTaskTrigger
