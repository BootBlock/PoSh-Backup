# Modules\Managers\ScheduleManager.psm1
<#
.SYNOPSIS
    Manages the creation, update, and deletion of Windows Scheduled Tasks for PoSh-Backup jobs.
.DESCRIPTION
    This module provides the functionality to synchronise the schedule configurations defined
    in the PoSh-Backup config file with the Windows Task Scheduler. It reads the 'Schedule'
    settings for each backup job and ensures a corresponding scheduled task exists and is
    correctly configured.

    The main exported function, 'Update-PoShBackupScheduledTasks', performs these actions:
    - Iterates through all defined backup jobs.
    - For jobs with an enabled schedule, it creates or updates a task in a dedicated
      "PoSh-Backup" folder within the Task Scheduler.
    - For jobs without an enabled schedule, it ensures any corresponding task is removed.
    - It translates the configuration settings (e.g., Type, Time, DaysOfWeek) into the
      appropriate trigger, action, and settings objects for the scheduled task.
    - After processing, it displays a summary of all tasks created, updated, or removed.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.8 # Definitive fix for RandomDelay bug and task removal logic.
    DateCreated:    08-Jun-2025
    LastModified:   08-Jun-2025
    Purpose:        To manage Windows Scheduled Tasks based on PoSh-Backup configuration.
    Prerequisites:  PowerShell 5.1+.
                    Requires Administrator privileges to create/modify scheduled tasks,
                    especially those running as SYSTEM or with highest privileges.
#>

#region --- Module Dependencies ---
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utilities\SystemUtils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "ScheduleManager.psm1 FATAL: Could not import dependent module SystemUtils.psm1. Error: $($_.Exception.Message)"
    throw # Critical dependency
}
#endregion

#region --- Exported Function ---

function Sync-PoShBackupSchedule  {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,

        [Parameter(Mandatory = $true)]
        [string]$PSScriptRoot, # The root path of the PoSh-Backup.ps1 script

        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO")
        & $Logger -Message $Message -Level $Level
    }

    & $LocalWriteLog -Message "ScheduleManager: Starting synchronisation of scheduled tasks." -Level "HEADING"

    if (-not (Test-AdminPrivilege -Logger $Logger)) {
        & $LocalWriteLog -Message "ScheduleManager: This script must be run with Administrator privileges to manage scheduled tasks. Aborting." -Level "ERROR"
        return
    }

    # --- Initialise variables for summary report ---
    $createdTasks = [System.Collections.Generic.List[string]]::new()
    $updatedTasks = [System.Collections.Generic.List[string]]::new()
    $removedTasks = [System.Collections.Generic.List[string]]::new()
    $skippedTasks = [System.Collections.Generic.List[string]]::new()

    $taskFolder = "\PoSh-Backup"
    $mainScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "PoSh-Backup.ps1"

    # --- Ensure the task folder exists in Task Scheduler using COM Object ---
    $scheduler = New-Object -ComObject "Schedule.Service"
    $scheduler.Connect()
    $rootFolder = $scheduler.GetFolder("\")
    $folderExists = $false
    try {
        $null = $rootFolder.GetFolder($taskFolder)
        $folderExists = $true
    } catch {
        $folderExists = $false
    }

    if (-not $folderExists) {
        if ($PSCmdlet.ShouldProcess("Task Scheduler Root", "Create Folder '$taskFolder'")) {
            & $LocalWriteLog -Message "ScheduleManager: Creating folder '$taskFolder' in Task Scheduler." -Level "INFO"
            try {
                $rootFolder.CreateFolder($taskFolder, $null)
                & $LocalWriteLog -Message "ScheduleManager: Task Scheduler folder '$taskFolder' created successfully." -Level "SUCCESS"
            }
            catch {
                & $LocalWriteLog -Message "ScheduleManager: Failed to create Task Scheduler folder '$taskFolder'. Error: $($_.Exception.Message)" -Level "ERROR"
                return
            }
        }
        else {
            & $LocalWriteLog -Message "ScheduleManager: Task folder creation skipped by user. Cannot proceed." -Level "WARNING"
            return
        }
    }
    # --- End Folder Creation Logic ---

    $allDefinedJobNames = @($Configuration.BackupLocations.Keys)
    $allManagedTaskNames = $allDefinedJobNames | ForEach-Object { "PoSh-Backup - $_" }

    # --- Pre-fetch all tasks in our folder for efficiency ---
    $allTasksInPoshBackupFolder = @(Get-ScheduledTask -TaskPath ($taskFolder + "\*"))

    # --- Step 1: Process and synchronise jobs defined in the configuration ---
    foreach ($jobName in $allDefinedJobNames) {
        $jobConfig = $Configuration.BackupLocations[$jobName]
        $taskName = "PoSh-Backup - $jobName"

        $existingTask = $allTasksInPoshBackupFolder | Where-Object { $_.TaskName -eq $taskName }
        $taskExists = $null -ne $existingTask

        $scheduleConfig = if ($jobConfig.ContainsKey('Schedule')) { $jobConfig.Schedule } else { $null }
        $isScheduleEnabled = ($null -ne $scheduleConfig) -and ($scheduleConfig.ContainsKey('Enabled')) -and ($scheduleConfig.Enabled -eq $true)

        # --- Logic for Enabled Schedules (Create or Update) ---
        if ($isScheduleEnabled) {
            & $LocalWriteLog -Message "ScheduleManager: Processing enabled schedule for job '$jobName'." -Level "INFO"

            # Define Task Action
            $taskArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$mainScriptPath`" -BackupLocationName `"$jobName`" -Quiet"
            if (-not [string]::IsNullOrWhiteSpace($scheduleConfig.AdditionalArguments)) { $taskArguments += " $($scheduleConfig.AdditionalArguments)" }
            $taskAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $taskArguments

            # Define Task Trigger (without RandomDelay initially)
            $trigger = $null; $triggerType = $scheduleConfig.Type.ToLowerInvariant()
            $startTime = if ($scheduleConfig.ContainsKey('Time')) { [datetime]$scheduleConfig.Time } else { (Get-Date).Date.AddHours(23) }
            switch ($triggerType) {
                'daily'   { $trigger = New-ScheduledTaskTrigger -Daily -At $startTime }
                'weekly'  { $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $scheduleConfig.DaysOfWeek -At $startTime }
                'once'    { $trigger = New-ScheduledTaskTrigger -Once -At $startTime }
                'onlogon' { $trigger = New-ScheduledTaskTrigger -AtLogOn }
                'onstartup' { $trigger = New-ScheduledTaskTrigger -AtStartup }
                default { & $LocalWriteLog -Message "ScheduleManager: Schedule Type '$($scheduleConfig.Type)' for job '$jobName' is not yet fully supported. Skipping." -Level "WARNING"; $skippedTasks.Add("$taskName (Unsupported Type)"); continue }
            }

            # Define Task Principal
            $principalUser = if ($scheduleConfig.RunAsUser -eq 'SYSTEM') { "NT AUTHORITY\SYSTEM" } else { ([System.Security.Principal.WindowsIdentity]::GetCurrent()).Name }
            $principalRunLevel = if ($scheduleConfig.HighestPrivileges -eq $true) { 'Highest' } else { 'Limited' }
            $taskPrincipal = New-ScheduledTaskPrincipal -UserId $principalUser -LogonType S4U -RunLevel $principalRunLevel

            # Define Task Settings
            $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries:($scheduleConfig.AllowStartIfOnBatteries -eq $true) -DontStopIfGoingOnBatteries:($scheduleConfig.StopIfGoingOnBatteries -eq $false) -WakeToRun:($scheduleConfig.WakeToRun -eq $true) -ExecutionTimeLimit (New-TimeSpan -Hours 12) -MultipleInstances IgnoreNew -StartWhenAvailable

            # Create the in-memory task definition object
            $taskDefinition = New-ScheduledTask -Action $taskAction -Principal $taskPrincipal -Trigger $trigger -Settings $taskSettings -Description "Automatically runs the PoSh-Backup job '$jobName' based on its configuration in PoSh-Backup's .psd1 file."

            # --- WORKAROUND for RandomDelay Bug ---
            $taskXmlString = $taskDefinition | Export-ScheduledTask
            if ($scheduleConfig.ContainsKey('RandomDelay') -and $scheduleConfig.RandomDelay -match '^(\d+)([smh])$') {
                $delayValue = $Matches[1]; $delayUnit = $Matches[2].ToUpper()
                $iso8601DelayString = "PT$($delayValue)$($delayUnit)"
                & $LocalWriteLog -Message "  - ScheduleManager: Manually setting RandomDelay in task XML to '$iso8601DelayString'." -Level "DEBUG"
                [xml]$taskXmlDoc = $taskXmlString
                $nsmgr = New-Object System.Xml.XmlNamespaceManager $taskXmlDoc.NameTable
                $nsmgr.AddNamespace("ts", "http://schemas.microsoft.com/windows/2004/02/mit/task")
                $triggerNode = $taskXmlDoc.SelectSingleNode("//ts:Triggers/*[1]", $nsmgr)
                if ($null -ne $triggerNode) {
                    $delayNode = $taskXmlDoc.CreateElement("RandomDelay", $nsmgr.LookupNamespace("ts")); $delayNode.InnerText = $iso8601DelayString
                    $triggerNode.AppendChild($delayNode) | Out-Null
                    $taskXmlString = $taskXmlDoc.OuterXml
                } else { & $LocalWriteLog -Message "  - ScheduleManager: Could not find trigger node in XML to append RandomDelay. Delay will not be set." -Level "WARNING" }
            }

            # --- Register or Update the Task using the final XML ---
            $actionToTake = if ($taskExists) { "Update Existing Scheduled Task" } else { "Register New Scheduled Task" }
            if ($PSCmdlet.ShouldProcess($taskName, $actionToTake)) {
                & $LocalWriteLog -Message "ScheduleManager: $($actionToTake.Split(' ')[0])ing task for job '$jobName'." -Level "INFO"
                try {
                    Register-ScheduledTask -TaskName $taskName -TaskPath $taskFolder -Xml $taskXmlString -Force -ErrorAction Stop | Out-Null
                    if ($actionToTake -eq "Update Existing Scheduled Task") { $updatedTasks.Add($taskName) } else { $createdTasks.Add($taskName) }
                } catch {
                    & $LocalWriteLog -Message "ScheduleManager: FAILED to register/update task '$taskName'. Error: $($_.Exception.Message)" -Level "ERROR"
                }
            } else {
                & $LocalWriteLog -Message "ScheduleManager: Task creation/update for '$taskName' skipped by user." -Level "WARNING"
                $skippedTasks.Add("$taskName (User Skipped)")
            }
        }
        # Case 2: Schedule is NOT enabled (or block is missing), but a task for it exists.
        elseif ($taskExists) {
            if ($PSCmdlet.ShouldProcess($taskName, "Unregister Scheduled Task (schedule is disabled or not defined in config)")) {
                & $LocalWriteLog -Message "ScheduleManager: Schedule for job '$jobName' is disabled or not defined. Removing existing task." -Level "INFO"
                Unregister-ScheduledTask -InputObject $existingTask -Confirm:$false -ErrorAction Stop
                $removedTasks.Add($taskName)
            } else {
                & $LocalWriteLog -Message "ScheduleManager: Task removal for '$jobName' skipped by user." -Level "WARNING"
                $skippedTasks.Add("$taskName (Removal Skipped by User)")
            }
        }
    }

    # --- Step 2: Clean up orphaned tasks ---
    if ($null -ne $allTasksInPoshBackupFolder) {
        foreach ($task in $allTasksInPoshBackupFolder) {
            if ($task.TaskName -notin $allManagedTaskNames) {
                if ($PSCmdlet.ShouldProcess($task.TaskName, "Unregister Orphaned Scheduled Task (job no longer defined)")) {
                    & $LocalWriteLog -Message "ScheduleManager: Removing orphaned scheduled task '$($task.TaskName)' as its job is no longer defined in the configuration." -Level "WARNING"
                    Unregister-ScheduledTask -InputObject $task -Confirm:$false -ErrorAction Stop; $removedTasks.Add($task.TaskName)
                }
            }
        }
    }

    # --- Step 3: Display Summary Report ---
    & $LocalWriteLog -Message "ScheduleManager: Synchronisation of scheduled tasks complete." -Level "HEADING"
    if ($createdTasks.Count -eq 0 -and $updatedTasks.Count -eq 0 -and $removedTasks.Count -eq 0 -and $skippedTasks.Count -eq 0) {
        & $LocalWriteLog -Message "  No changes were made to scheduled tasks." -Level "INFO"
    } else {
        if ($createdTasks.Count -gt 0) {
            & $LocalWriteLog -Message "`n  Tasks Created: $($createdTasks.Count)" -Level "SUCCESS"
            $createdTasks | ForEach-Object { & $LocalWriteLog "    - $_" -Level "SUCCESS" }
        }
        if ($updatedTasks.Count -gt 0) {
            & $LocalWriteLog -Message "`n  Tasks Updated: $($updatedTasks.Count)" -Level "INFO"
            $updatedTasks | ForEach-Object { & $LocalWriteLog "    - $_" -Level "INFO" }
        }
        if ($removedTasks.Count -gt 0) {
            & $LocalWriteLog -Message "`n  Tasks Removed: $($removedTasks.Count)" -Level "WARNING"
            $removedTasks | ForEach-Object { & $LocalWriteLog "    - $_" -Level "WARNING" }
        }
        if ($skippedTasks.Count -gt 0) {
            & $LocalWriteLog -Message "`n  Tasks Skipped: $($skippedTasks.Count)" -Level "DEBUG"
            $skippedTasks | ForEach-Object { & $LocalWriteLog "    - $_" -Level "DEBUG" }
        }
    }
}

#endregion

Export-ModuleMember -Function Sync-PoShBackupSchedule
