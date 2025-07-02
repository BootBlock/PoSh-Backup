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
    2.  If it should exist, it lazy-loads the builder sub-modules to construct the action, trigger,
        principal, and settings objects.
    3.  It assembles these components into a task definition.
    4.  It handles the XML manipulation required for the '-RandomDelay' workaround.
    5.  It calls 'Register-ScheduledTask' to create or update the task.
    6.  If the task should not exist, it calls 'Unregister-ScheduledTask' to remove it.
    7.  It respects -WhatIf/-Confirm and updates the result summary arrays.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Refactored to lazy-load builder sub-modules.
    DateCreated:    25-Jun-2025
    LastModified:   02-Jul-2025
    Purpose:        To orchestrate the building and registration of a single scheduled task.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers\ScheduleManager
try {
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
        [Parameter(Mandatory = $true)]
        [string]$ItemName,
        [Parameter(Mandatory = $true)]
        [hashtable]$ItemConfig,
        [Parameter(Mandatory = $true)]
        [string]$TaskName,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Job', 'Verification')]
        [string]$ItemType,
        [Parameter(Mandatory = $true)]
        [string]$MainScriptPath,
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

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    $taskExists = $null -ne $ExistingTask

    $isItemItselfEnabled = Get-ConfigValue -ConfigObject $ItemConfig -Key 'Enabled' -DefaultValue $true
    $scheduleConfig = Get-ConfigValue -ConfigObject $ItemConfig -Key 'Schedule' -DefaultValue $null
    $isScheduleBlockEnabled = ($null -ne $scheduleConfig) -and (Get-ConfigValue -ConfigObject $scheduleConfig -Key 'Enabled' -DefaultValue $false)

    if ($isItemItselfEnabled -and $isScheduleBlockEnabled) {
        & $LocalWriteLog -Message "Orchestrator: Processing enabled schedule for item '$ItemName'." -Level "DEBUG"

        try {
            # LAZY LOADING of builder modules
            $taskAction = try {
                Import-Module -Name (Join-Path $PSScriptRoot "ActionBuilder.psm1") -Force -ErrorAction Stop
                Get-PoShBackupTaskAction -ItemType $ItemType -ItemName $ItemName -MainScriptPath $MainScriptPath -Logger $Logger
            } catch { throw "Could not load or execute the ActionBuilder sub-module. Error: $($_.Exception.Message)" }

            $taskTrigger = try {
                Import-Module -Name (Join-Path $PSScriptRoot "TriggerBuilder.psm1") -Force -ErrorAction Stop
                Get-PoShBackupTaskTrigger -ScheduleConfig $scheduleConfig -Logger $Logger
            } catch { throw "Could not load or execute the TriggerBuilder sub-module. Error: $($_.Exception.Message)" }

            $taskPrincipal = try {
                Import-Module -Name (Join-Path $PSScriptRoot "PrincipalAndSettingsBuilder.psm1") -Force -ErrorAction Stop
                Get-PoShBackupTaskPrincipal -ScheduleConfig $scheduleConfig -Logger $Logger
            } catch { throw "Could not load or execute the PrincipalAndSettingsBuilder sub-module. Error: $($_.Exception.Message)" }

            $taskSettings = Get-PoShBackupTaskSettingSet -ScheduleConfig $scheduleConfig -Logger $Logger

            if (-not ($taskAction -and $taskTrigger -and $taskPrincipal -and $taskSettings)) {
                throw "Failed to build one or more necessary task components for '$ItemName'. Check previous logs."
            }
        }
        catch {
            $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Managers\ScheduleManager\' and its builder sub-modules exist and are not corrupted."
            & $LocalWriteLog -Message "[FATAL] TaskOrchestrator: $_.Exception.Message" -Level "ERROR"
            & $LocalWriteLog -Message $advice -Level "ADVICE"
            $SkippedTasks.Value.Add("$TaskName (Component Build Failure)")
            return
        }

        $taskDefinition = New-ScheduledTask -Action $taskAction -Principal $taskPrincipal -Trigger $taskTrigger -Settings $taskSettings -Description "Automatically runs the PoSh-Backup item '$ItemName' based on its configuration."

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
        if ($PSCmdlet.ShouldProcess($TaskName, "Unregister Scheduled Task (item or its schedule is disabled in config)")) {
            & $LocalWriteLog -Message "Orchestrator: Schedule for item '$ItemName' is disabled or not defined. Removing existing task." -Level "INFO"
            Unregister-ScheduledTask -InputObject $ExistingTask -Confirm:$false -ErrorAction Stop
            $RemovedTasks.Value.Add($TaskName)
        }
        else { & $LocalWriteLog -Message "Orchestrator: Task removal for '$TaskName' skipped by user." -Level "WARNING"; $SkippedTasks.Value.Add("$TaskName (Removal Skipped by User)") }
    }
}

Export-ModuleMember -Function Invoke-ScheduledItemSync
