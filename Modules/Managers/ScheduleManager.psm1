# Modules\Managers\ScheduleManager.psm1
<#
.SYNOPSIS
    Manages the creation, update, and deletion of Windows Scheduled Tasks for PoSh-Backup jobs.
.DESCRIPTION
    This module provides the functionality to synchronise the schedule configurations defined
    in the PoSh-Backup config file with the Windows Task Scheduler. It reads the 'Schedule'
    settings for each backup job and verification job, and ensures a corresponding scheduled
    task exists and is correctly configured.

    The main exported function, 'Sync-PoShBackupSchedule', performs these actions:
    - Iterates through all defined backup jobs and verification jobs.
    - For items with an enabled schedule, it creates or updates a task in a dedicated
      "PoSh-Backup" folder within the Task Scheduler.
    - For items without an enabled schedule, it ensures any corresponding task is removed.
    - It translates the configuration settings (e.g., Type, Time, DaysOfWeek) into the
      appropriate trigger, action, and settings objects for the scheduled task.
    - After processing, it displays a summary of all tasks created, updated, or removed.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.3 # Fixed logic to respect top-level 'Enabled' flag for jobs/vjobs.
    DateCreated:    08-Jun-2025
    LastModified:   20-Jun-2025
    Purpose:        To manage Windows Scheduled Tasks based on PoSh-Backup configuration.
    Prerequisites:  PowerShell 5.1+.
                    Requires Administrator privileges to create/modify scheduled tasks,
                    especially those running as SYSTEM or with highest privileges.
#>

#region --- Module Dependencies ---
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utilities\SystemUtils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utilities\ConsoleDisplayUtils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "ScheduleManager.psm1 FATAL: Could not import dependent module SystemUtils.psm1. Error: $($_.Exception.Message)"
    throw # Critical dependency
}
#endregion

#region --- Internal Helper Function ---
function Invoke-ScheduledItemSyncInternal {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ItemName,
        [Parameter(Mandatory = $true)]
        [hashtable]$ItemConfig,
        [Parameter(Mandatory = $true)]
        [string]$TaskName,
        [Parameter(Mandatory = $true)]
        [string]$TaskArguments,
        [Parameter(Mandatory = $false)]
        [object]$ExistingTask,
        [Parameter(Mandatory = $true)]
        [string]$TaskFolder,
        [Parameter(Mandatory = $true)]
        [ref]$CreatedTasks,
        [Parameter(Mandatory = $true)]
        [ref]$UpdatedTasks,
        [Parameter(Mandatory = $true)]
        [ref]$RemovedTasks,
        [Parameter(Mandatory = $true)]
        [ref]$SkippedTasks,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )
    & $Logger -Message "ScheduleManager/Invoke-ScheduledItemSyncInternal: Logger active for item '$ItemName'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    
    $taskExists = $null -ne $ExistingTask
    
    # Corrected Logic: Check both the job's Enabled flag AND the schedule's Enabled flag.
    $isItemItselfEnabled = if ($ItemConfig.ContainsKey('Enabled')) { $ItemConfig.Enabled } else { $true } # Default to true if key is missing
    $scheduleConfig = if ($ItemConfig.ContainsKey('Schedule')) { $ItemConfig.Schedule } else { $null }
    $isScheduleBlockEnabled = ($null -ne $scheduleConfig) -and ($scheduleConfig.ContainsKey('Enabled')) -and ($scheduleConfig.Enabled -eq $true)

    # A task should only exist if both the job AND its schedule are enabled.
    if ($isItemItselfEnabled -and $isScheduleBlockEnabled) {
        & $LocalWriteLog -Message "ScheduleManager: Processing enabled schedule for item '$ItemName'." -Level "INFO"
        $taskAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $TaskArguments
        $trigger = $null; $triggerType = $scheduleConfig.Type.ToLowerInvariant()
        $startTime = if ($scheduleConfig.ContainsKey('Time')) { [datetime]$scheduleConfig.Time } else { (Get-Date).Date.AddHours(23) }
        switch ($triggerType) {
            'daily' { $trigger = New-ScheduledTaskTrigger -Daily -At $startTime }
            'weekly' { $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $scheduleConfig.DaysOfWeek -At $startTime }
            'once' { $trigger = New-ScheduledTaskTrigger -Once -At $startTime }
            'onlogon' { $trigger = New-ScheduledTaskTrigger -AtLogOn }
            'onstartup' { $trigger = New-ScheduledTaskTrigger -AtStartup }
            default { & $LocalWriteLog -Message "ScheduleManager: Schedule Type '$($scheduleConfig.Type)' for item '$ItemName' is not yet fully supported. Skipping." -Level "WARNING"; $SkippedTasks.Value.Add("$TaskName (Unsupported Type)"); return }
        }
        $principalUser = if ($scheduleConfig.RunAsUser -eq 'SYSTEM') { "NT AUTHORITY\SYSTEM" } else { ([System.Security.Principal.WindowsIdentity]::GetCurrent()).Name }
        $principalRunLevel = if ($scheduleConfig.HighestPrivileges -eq $true) { 'Highest' } else { 'Limited' }
        $taskPrincipal = New-ScheduledTaskPrincipal -UserId $principalUser -LogonType S4U -RunLevel $principalRunLevel
        $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries:($scheduleConfig.AllowStartIfOnBatteries -eq $true) -DontStopIfGoingOnBatteries:($scheduleConfig.StopIfGoingOnBatteries -eq $false) -WakeToRun:($scheduleConfig.WakeToRun -eq $true) -ExecutionTimeLimit (New-TimeSpan -Hours 12) -MultipleInstances IgnoreNew -StartWhenAvailable
        $taskDefinition = New-ScheduledTask -Action $taskAction -Principal $taskPrincipal -Trigger $trigger -Settings $taskSettings -Description "Automatically runs the PoSh-Backup item '$ItemName' based on its configuration."

        $taskXmlString = $taskDefinition | Export-ScheduledTask
        if ($scheduleConfig.ContainsKey('RandomDelay') -and $scheduleConfig.RandomDelay -match '^(\d+)([smh])$') {
            $delayValue = $Matches[1]; $delayUnit = $Matches[2].ToUpper()
            $iso8601DelayString = "PT$($delayValue)$($delayUnit)"; & $LocalWriteLog -Message "  - ScheduleManager: Manually setting RandomDelay in task XML to '$iso8601DelayString'." -Level "DEBUG"
            [xml]$taskXmlDoc = $taskXmlString; $nsmgr = New-Object System.Xml.XmlNamespaceManager $taskXmlDoc.NameTable; $nsmgr.AddNamespace("ts", "http://schemas.microsoft.com/windows/2004/02/mit/task")
            $triggerNode = $taskXmlDoc.SelectSingleNode("//ts:Triggers/*[1]", $nsmgr)
            if ($null -ne $triggerNode) {
                $delayNode = $taskXmlDoc.CreateElement("RandomDelay", $nsmgr.LookupNamespace("ts")); $delayNode.InnerText = $iso8601DelayString
                $triggerNode.AppendChild($delayNode) | Out-Null; $taskXmlString = $taskXmlDoc.OuterXml
            }
            else { & $LocalWriteLog -Message "  - ScheduleManager: Could not find trigger node in XML to append RandomDelay. Delay will not be set." -Level "WARNING" }
        }
        
        $actionToTake = if ($taskExists) { "Update Existing Scheduled Task" } else { "Register New Scheduled Task" }
        & $LocalWriteLog -Message "  - ScheduleManager: Task Action will be: powershell.exe $TaskArguments" -Level "DEBUG"
        if ($PSCmdlet.ShouldProcess($TaskName, $actionToTake)) {
            & $LocalWriteLog -Message "ScheduleManager: $($actionToTake.Split(' ')[0].TrimEnd('e'))ing task for item '$ItemName'." -Level "INFO" # Fixed "Updateing"
            try {
Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskFolder -Xml $taskXmlString -Force -ErrorAction Stop | Out-Null
                if ($actionToTake -eq "Update Existing Scheduled Task") { $UpdatedTasks.Value.Add($TaskName) } else { $CreatedTasks.Value.Add($TaskName) }

                # Get the base task object using the reliable wildcard method.
                $registeredTaskObject = Get-ScheduledTask -TaskPath "$TaskFolder\*" -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -eq $TaskName }

                if ($null -ne $registeredTaskObject) {
                    $taskInfo = Get-ScheduledTaskInfo -InputObject $registeredTaskObject -ErrorAction SilentlyContinue
                    
                    # --- Display Detailed Task Information ---
                    Write-Host
                    Write-NameValue "Name" $registeredTaskObject.TaskName -namePadding 18
                    Write-NameValue "Path" $registeredTaskObject.TaskPath -namePadding 18
                    Write-NameValue "State" $registeredTaskObject.State -namePadding 18
                    Write-NameValue "Run As User" $registeredTaskObject.Principal.UserId -namePadding 18
                    Write-NameValue "Run with" "$($registeredTaskObject.Principal.RunLevel) Privileges" -namePadding 18
                    Write-NameValue "Next Run Time" $taskInfo.NextRunTime -namePadding 18
                    
                    # Display Trigger Details
                    if ($registeredTaskObject.Triggers) {
                        $firstTrigger = $true
                        foreach($trigger in $registeredTaskObject.Triggers) {
                            $triggerDetails = ""
                            switch ($trigger.CimClass.ClassName) {
                                'MSFT_TaskDailyTrigger'   { $triggerDetails = "Daily at $($trigger.StartBoundary.ToShortTimeString())" }
                                'MSFT_TaskWeeklyTrigger'  { $triggerDetails = "Weekly on $($trigger.DaysOfWeek -join ', ') at $($trigger.StartBoundary.ToShortTimeString())" }
                                'MSFT_TaskTimeTrigger'    { $triggerDetails = "Once at $($trigger.StartBoundary)" }
                                'MSFT_TaskLogonTrigger'   { $triggerDetails = "At Logon" }
                                'MSFT_TaskStartupTrigger' { $triggerDetails = "At Startup" }
                                default                   { $triggerDetails = $trigger.CimClass.ClassName }
                            }
                            if (-not $firstTrigger) { Write-Host (" " * 21) -NoNewline }
                            Write-NameValue "Triggers" $triggerDetails -namePadding 18
                            $firstTrigger = $false
                        }
                    }

                    if ($registeredTaskObject.Actions) {
                        Write-NameValue "Actions" "$($registeredTaskObject.Actions[0].Execute) $($registeredTaskObject.Actions[0].Argument)" -namePadding 18
                    }
                    Write-Host
                }
                else {
                    & $LocalWriteLog -Message "  - ScheduleManager: Could not retrieve task '$TaskName' immediately after registration to report details." -Level "WARNING"
                }

            } 
            catch {
                & $LocalWriteLog -Message "ScheduleManager: FAILED to register/update task '$TaskName'. Error: $($_.Exception.Message)" -Level "ERROR" 
            }
        }
        else { & $LocalWriteLog -Message "ScheduleManager: Task creation/update for '$TaskName' skipped by user." -Level "WARNING"; $SkippedTasks.Value.Add("$TaskName (User Skipped)") }
    }
    elseif ($taskExists) {
        # This block now correctly executes if the item or its schedule is disabled
        if ($PSCmdlet.ShouldProcess($TaskName, "Unregister Scheduled Task (item or its schedule is disabled in config)")) {
            & $LocalWriteLog -Message "ScheduleManager: Schedule for item '$ItemName' is disabled or not defined. Removing existing task." -Level "INFO"
            Unregister-ScheduledTask -InputObject $ExistingTask -Confirm:$false -ErrorAction Stop
            $RemovedTasks.Value.Add($TaskName)
        }
        else { & $LocalWriteLog -Message "ScheduleManager: Task removal for '$TaskName' skipped by user." -Level "WARNING"; $SkippedTasks.Value.Add("$TaskName (Removal Skipped by User)") }
    }
}
#endregion

#region --- Exported Function ---
function Sync-PoShBackupSchedule {
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

    $createdTasks = [System.Collections.Generic.List[string]]::new()
    $updatedTasks = [System.Collections.Generic.List[string]]::new()
    $removedTasks = [System.Collections.Generic.List[string]]::new()
    $skippedTasks = [System.Collections.Generic.List[string]]::new()

    $taskFolder = "\PoSh-Backup"
    $mainScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "PoSh-Backup.ps1"

    # Ensure the task folder exists
    $scheduler = New-Object -ComObject "Schedule.Service"; $scheduler.Connect()
    $rootFolder = $scheduler.GetFolder("\")
    try { $null = $rootFolder.GetFolder($taskFolder) } catch {
        if ($PSCmdlet.ShouldProcess("Task Scheduler Root", "Create Folder '$taskFolder'")) {
            & $LocalWriteLog -Message "ScheduleManager: Creating folder '$taskFolder' in Task Scheduler." -Level "INFO"
            try { $rootFolder.CreateFolder($taskFolder, $null); & $LocalWriteLog -Message "ScheduleManager: Task Scheduler folder '$taskFolder' created successfully." -Level "SUCCESS" }
            catch { & $LocalWriteLog -Message "ScheduleManager: Failed to create Task Scheduler folder '$taskFolder'. Error: $($_.Exception.Message)" -Level "ERROR"; return }
        }
        else { & $LocalWriteLog -Message "ScheduleManager: Task folder creation skipped by user. Cannot proceed." -Level "WARNING"; return }
    }

    $allDefinedJobNames = @($Configuration.BackupLocations.Keys)
    $allDefinedVJobNames = if ($Configuration.ContainsKey('VerificationJobs')) { @($Configuration.VerificationJobs.Keys) } else { @() }
    $allManagedTaskNames = @($allDefinedJobNames | ForEach-Object { "PoSh-Backup - $_" }) + @($allDefinedVJobNames | ForEach-Object { "PoSh-Backup Verification - $_" })

    $allTasksInPoshBackupFolder = @(Get-ScheduledTask -TaskPath ($taskFolder + "\*"))

    # --- Step 1: Process and synchronise backup jobs defined in the configuration ---
    foreach ($jobName in $allDefinedJobNames) {
        $jobConfig = $Configuration.BackupLocations[$jobName]
        $taskName = "PoSh-Backup - $($jobName -replace '[\\/:*?"<>|]', '_')"
        $taskArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$mainScriptPath`" -BackupLocationName `"$jobName`" -Quiet"
        Invoke-ScheduledItemSyncInternal -ItemName $jobName -ItemConfig $jobConfig -TaskName $taskName -TaskArguments $taskArguments -ExistingTask ($allTasksInPoshBackupFolder | Where-Object { $_.TaskName -eq $taskName }) -TaskFolder $taskFolder -CreatedTasks ([ref]$createdTasks) -UpdatedTasks ([ref]$updatedTasks) -RemovedTasks ([ref]$removedTasks) -SkippedTasks ([ref]$skippedTasks) -Logger $Logger -PSCmdlet $PSCmdlet
    }

    # --- Step 2: Process and synchronise verification jobs defined in the configuration ---
    foreach ($vJobName in $allDefinedVJobNames) {
        $vJobConfig = $Configuration.VerificationJobs[$vJobName]
        $taskName = "PoSh-Backup Verification - $($vJobName -replace '[\\/:*?"<>|]', '_')"
        $taskArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$mainScriptPath`" -VerificationJobName `"$vJobName`" -Quiet"
        Invoke-ScheduledItemSyncInternal -ItemName $vJobName -ItemConfig $vJobConfig -TaskName $taskName -TaskArguments $taskArguments -ExistingTask ($allTasksInPoshBackupFolder | Where-Object { $_.TaskName -eq $taskName }) -TaskFolder $taskFolder -CreatedTasks ([ref]$createdTasks) -UpdatedTasks ([ref]$updatedTasks) -RemovedTasks ([ref]$removedTasks) -SkippedTasks ([ref]$skippedTasks) -Logger $Logger -PSCmdlet $PSCmdlet
    }

    # --- Step 3: Clean up orphaned tasks ---
    if ($null -ne $allTasksInPoshBackupFolder) {
        foreach ($task in $allTasksInPoshBackupFolder) {
            if ($task.TaskName -notin $allManagedTaskNames) {
                if ($PSCmdlet.ShouldProcess($task.TaskName, "Unregister Orphaned Scheduled Task (job no longer defined)")) {
                    & $LocalWriteLog -Message "ScheduleManager: Removing orphaned scheduled task '$($task.TaskName)' as its job is no longer defined in the configuration." -Level "WARNING"
                    Unregister-ScheduledTask -InputObject $task -Confirm:$false -ErrorAction Stop
                    $removedTasks.Add($task.TaskName)
                }
            }
        }
    }

    # --- Step 4: Display Summary Report ---
    & $LocalWriteLog -Message "ScheduleManager: Synchronisation of scheduled tasks complete." -Level "HEADING"
    if ($createdTasks.Count -eq 0 -and $updatedTasks.Count -eq 0 -and $removedTasks.Count -eq 0 -and $skippedTasks.Count -eq 0) {
        & $LocalWriteLog -Message "  No changes were made to scheduled tasks." -Level "INFO"
    }
    else {
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
