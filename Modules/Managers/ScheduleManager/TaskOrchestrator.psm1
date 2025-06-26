# Modules\Managers\ScheduleManager\TaskOrchestrator.psm1
<#
.SYNOPSIS
    A sub-module for ScheduleManager. Orchestrates the creation, update, and removal
    of a single scheduled task.
.DESCRIPTION
    This module provides the 'Invoke-ScheduledItemSync' function, which contains the
    core logic for synchronising a single configured PoSh-Backup schedule with the
    Windows Task Scheduler.

    It performs these steps:
    1.  Determines if the task should exist based on the item's and its schedule's 'Enabled' flags.
    2.  If it should exist, it calls the builder sub-modules to construct the action, trigger,
        principal, and settings objects.
    3.  It assembles these components into a task definition.
    4.  It handles the XML manipulation required for the '-RandomDelay' workaround.
    5.  It calls 'Register-ScheduledTask' to create or update the task.
    6.  If the task should not exist, it calls 'Unregister-ScheduledTask' to remove it.
    7.  It respects -WhatIf/-Confirm and updates the result summary arrays.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    25-Jun-2025
    LastModified:   25-Jun-2025
    Purpose:        To orchestrate the building and registration of a single scheduled task.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers\ScheduleManager
try {
    # Import the builder modules this orchestrator will use.
    Import-Module -Name (Join-Path $PSScriptRoot "ActionBuilder.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "TriggerBuilder.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "PrincipalAndSettingsBuilder.psm1") -Force -ErrorAction Stop
    # Import main Utils for Get-ConfigValue
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "ScheduleManager\TaskOrchestrator.psm1 FATAL: Could not import a dependent module. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Invoke-ScheduledItemSync {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        # The name of the backup job or verification job.
        [Parameter(Mandatory = $true)]
        [string]$ItemName,

        # The configuration hashtable for the specific job or verification job.
        [Parameter(Mandatory = $true)]
        [hashtable]$ItemConfig,

        # The full name of the task as it should appear in Task Scheduler.
        [Parameter(Mandatory = $true)]
        [string]$TaskName,

        # The type of item being scheduled ('Job' or 'Verification').
        [Parameter(Mandatory = $true)]
        [ValidateSet('Job', 'Verification')]
        [string]$ItemType,
        
        # The full path to the main PoSh-Backup.ps1 script.
        [Parameter(Mandatory = $true)]
        [string]$MainScriptPath,

        # The existing scheduled task object, if one was found.
        [Parameter(Mandatory = $false)]
        [object]$ExistingTask,

        # The Task Scheduler folder path (e.g., '\PoSh-Backup').
        [Parameter(Mandatory = $true)]
        [string]$TaskFolder,

        # Reference to a List[string] to track created tasks.
        [Parameter(Mandatory = $true)]
        [ref]$CreatedTasks,

        # Reference to a List[string] to track updated tasks.
        [Parameter(Mandatory = $true)]
        [ref]$UpdatedTasks,

        # Reference to a List[string] to track removed tasks.
        [Parameter(Mandatory = $true)]
        [ref]$RemovedTasks,

        # Reference to a List[string] to track skipped tasks.
        [Parameter(Mandatory = $true)]
        [ref]$SkippedTasks,

        # A scriptblock reference to the main Write-LogMessage function.
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,

        # A reference to the calling cmdlet's $PSCmdlet automatic variable.
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    
    $taskExists = $null -ne $ExistingTask
    
    # A task should only exist if both the job AND its schedule are enabled.
    $isItemItselfEnabled = Get-ConfigValue -ConfigObject $ItemConfig -Key 'Enabled' -DefaultValue $true
    $scheduleConfig = Get-ConfigValue -ConfigObject $ItemConfig -Key 'Schedule' -DefaultValue $null
    $isScheduleBlockEnabled = ($null -ne $scheduleConfig) -and (Get-ConfigValue -ConfigObject $scheduleConfig -Key 'Enabled' -DefaultValue $false)

    if ($isItemItselfEnabled -and $isScheduleBlockEnabled) {
        # Task should exist or be created/updated.
        & $LocalWriteLog -Message "Orchestrator: Processing enabled schedule for item '$ItemName'." -Level "DEBUG"
        
        $taskAction = Get-PoShBackupTaskAction -ItemType $ItemType -ItemName $ItemName -MainScriptPath $MainScriptPath -Logger $Logger
        $taskTrigger = Get-PoShBackupTaskTrigger -ScheduleConfig $scheduleConfig -Logger $Logger
        $taskPrincipal = Get-PoShBackupTaskPrincipal -ScheduleConfig $scheduleConfig -Logger $Logger
        $taskSettings = Get-PoShBackupTaskSettingSet -ScheduleConfig $scheduleConfig -Logger $Logger

        if (-not ($taskAction -and $taskTrigger -and $taskPrincipal -and $taskSettings)) {
            & $LocalWriteLog -Message "Orchestrator: Failed to build one or more necessary task components for '$ItemName'. Skipping task registration." -Level "ERROR"
            $SkippedTasks.Value.Add("$TaskName (Component Build Failure)")
            return
        }

        $taskDefinition = New-ScheduledTask -Action $taskAction -Principal $taskPrincipal -Trigger $taskTrigger -Settings $taskSettings -Description "Automatically runs the PoSh-Backup item '$ItemName' based on its configuration."

        # Manually inject RandomDelay into the XML as the cmdlet parameter is buggy
        $taskXmlString = $taskDefinition | Export-ScheduledTask
        if ($scheduleConfig.ContainsKey('RandomDelay') -and $scheduleConfig.RandomDelay -match '^(\d+)([smh])$') {
            $delayValue = $Matches[1]; $delayUnit = $Matches[2].ToUpper()
            $iso8601DelayString = "PT$($delayValue)$($delayUnit)"; & $LocalWriteLog -Message "  - Orchestrator: Manually setting RandomDelay in task XML to '$iso8601DelayString'." -Level "DEBUG"
            [xml]$taskXmlDoc = $taskXmlString; $nsmgr = New-Object System.Xml.XmlNamespaceManager $taskXmlDoc.NameTable; $nsmgr.AddNamespace("ts", "http://schemas.microsoft.com/windows/2004/02/mit/task")
            $triggerNodeXml = $taskXmlDoc.SelectSingleNode("//ts:Triggers/*[1]", $nsmgr)
            if ($null -ne $triggerNodeXml) {
                $delayNode = $taskXmlDoc.CreateElement("RandomDelay", $nsmgr.LookupNamespace("ts")); $delayNode.InnerText = $iso8601DelayString
                $triggerNodeXml.AppendChild($delayNode) | Out-Null; $taskXmlString = $taskXmlDoc.OuterXml
            }
            else { & $LocalWriteLog -Message "  - Orchestrator: Could not find trigger node in XML to append RandomDelay. Delay will not be set." -Level "WARNING" }
        }
        
        $actionToTake = if ($taskExists) { "Update Existing Scheduled Task" } else { "Register New Scheduled Task" }
        if ($PSCmdlet.ShouldProcess($TaskName, $actionToTake)) {
            & $LocalWriteLog -Message "Orchestrator: $($actionToTake.Split(' ')[0].TrimEnd('e'))ing task for item '$ItemName'." -Level "DEBUG"
            try {
                Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskFolder -Xml $taskXmlString -Force -ErrorAction Stop | Out-Null
                if ($actionToTake -eq "Update Existing Scheduled Task") { $UpdatedTasks.Value.Add($TaskName) } else { $CreatedTasks.Value.Add($TaskName) }
            } 
            catch {
                & $LocalWriteLog -Message "Orchestrator: FAILED to register/update task '$TaskName'. Error: $($_.Exception.Message)" -Level "ERROR" 
            }
        }
        else { & $LocalWriteLog -Message "Orchestrator: Task creation/update for '$TaskName' skipped by user." -Level "WARNING"; $SkippedTasks.Value.Add("$TaskName (User Skipped)") }
    }
    elseif ($taskExists) {
        # Task exists but should not. Remove it.
        if ($PSCmdlet.ShouldProcess($TaskName, "Unregister Scheduled Task (item or its schedule is disabled in config)")) {
            & $LocalWriteLog -Message "Orchestrator: Schedule for item '$ItemName' is disabled or not defined. Removing existing task." -Level "INFO"
            Unregister-ScheduledTask -InputObject $ExistingTask -Confirm:$false -ErrorAction Stop
            $RemovedTasks.Value.Add($TaskName)
        }
        else { & $LocalWriteLog -Message "Orchestrator: Task removal for '$TaskName' skipped by user." -Level "WARNING"; $SkippedTasks.Value.Add("$TaskName (Removal Skipped by User)") }
    }
}

Export-ModuleMember -Function Invoke-ScheduledItemSync
