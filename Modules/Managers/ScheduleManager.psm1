# Modules\Managers\ScheduleManager.psm1
<#
.SYNOPSIS
    Manages the creation, update, and deletion of Windows Scheduled Tasks for PoSh-Backup jobs.
    This module now acts as a facade, lazy-loading its sub-modules as needed.
.DESCRIPTION
    This module provides the functionality to synchronise the schedule configurations defined
    in the PoSh-Backup config file with the Windows Task Scheduler. It reads the 'Schedule'
    settings for each backup job and verification job, and ensures a corresponding scheduled
    task exists and is correctly configured.

    The main exported function, 'Sync-PoShBackupSchedule', orchestrates the process by:
    - Ensuring the main 'PoSh-Backup' task folder exists in Task Scheduler.
    - Getting a list of all existing tasks in that folder.
    - Iterating through all defined backup jobs and verification jobs from the configuration.
    - Lazy-loading and calling 'Invoke-ScheduledItemSync' from its 'TaskOrchestrator.psm1' sub-module for each item.
    - Cleaning up any orphaned tasks that no longer exist in the configuration.
    - Displaying a final summary of actions taken.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.1.4 # FIX: Use Resolve-Path for robust module importing.
    DateCreated:    08-Jun-2025
    LastModified:   02-Jul-2025
    Purpose:        To manage Windows Scheduled Tasks based on PoSh-Backup configuration.
    Prerequisites:  PowerShell 5.1+.
                    Requires Administrator privileges to create/modify scheduled tasks.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers
try {
    Import-Module -Name (Resolve-Path (Join-Path $PSScriptRoot "..\Utilities\SystemUtils.psm1")).Path -Force -ErrorAction Stop
    Import-Module -Name (Resolve-Path (Join-Path $PSScriptRoot "..\Utilities\ConsoleDisplayUtils.psm1")).Path -Force -ErrorAction Stop
}
catch {
    Write-Error "ScheduleManager.psm1 (Facade) FATAL: Could not import required dependent modules. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- Exported Function ---
function Sync-PoShBackupSchedule {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,
        [Parameter(Mandatory = $true)]
        [string]$MainScriptRoot,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance,
        [Parameter(Mandatory = $false)]
        [switch]$IsWhatIfMode
    )

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO")
        & $Logger -Message $Message -Level $Level
    }

    & $LocalWriteLog -Message "ScheduleManager: Starting synchronisation of scheduled tasks." -Level "HEADING"

    if (-not (Test-AdminPrivilege -Logger $Logger)) {
        $errorMessage = "ScheduleManager: Synchronising schedules requires Administrator privileges."
        $adviceMessage = "Please re-launch your PowerShell session using the 'Run as Administrator' option and try again."
        & $LocalWriteLog -Message $errorMessage -Level "ERROR"
        & $LocalWriteLog -Message $adviceMessage -Level "ADVICE"

        throw "Insufficient privileges for scheduled task management."
    }

    $createdTasks = [System.Collections.Generic.List[string]]::new()
    $updatedTasks = [System.Collections.Generic.List[string]]::new()
    $removedTasks = [System.Collections.Generic.List[string]]::new()
    $skippedTasks = [System.Collections.Generic.List[string]]::new()

    $taskFolder = "\PoSh-Backup"
    $mainScriptPath = Join-Path -Path $MainScriptRoot -ChildPath "PoSh-Backup.ps1"

    try {
        $scheduler = New-Object -ComObject "Schedule.Service"; $scheduler.Connect()
        $rootFolder = $scheduler.GetFolder("\")
        try { $null = $rootFolder.GetFolder($taskFolder) } catch {
            if ($PSCmdletInstance.ShouldProcess("Task Scheduler Root", "Create Folder '$taskFolder'")) {
                & $LocalWriteLog -Message "ScheduleManager: Creating folder '$taskFolder' in Task Scheduler." -Level "INFO"
                $rootFolder.CreateFolder($taskFolder, $null) | Out-Null; & $LocalWriteLog -Message "ScheduleManager: Task Scheduler folder '$taskFolder' created successfully." -Level "SUCCESS"
            }
            else { & $LocalWriteLog -Message "ScheduleManager: Task folder creation skipped by user. Cannot proceed." -Level "WARNING"; return }
        }
    } catch {
        & $LocalWriteLog -Message "ScheduleManager: Failed to connect to the Task Scheduler service. Error: $($_.Exception.Message)" -Level "ERROR"; return
    }

    $allTasksInPoshBackupFolder = @(Get-ScheduledTask -TaskPath ($taskFolder + "\*") -ErrorAction SilentlyContinue)

    $allDefinedJobNames = if ($Configuration.BackupLocations -is [hashtable]) { @($Configuration.BackupLocations.Keys) } else { @() }
    $allDefinedVJobNames = if ($Configuration.ContainsKey('VerificationJobs')) { @($Configuration.VerificationJobs.Keys) } else { @() }
    $allManagedTaskNames = @($allDefinedJobNames | ForEach-Object { "PoSh-Backup - $_" }) + @($allDefinedVJobNames | ForEach-Object { "PoSh-Backup Verification - $_" })

    try {
        Import-Module -Name (Resolve-Path (Join-Path $PSScriptRoot "ScheduleManager\TaskOrchestrator.psm1")).Path -Force -ErrorAction Stop

        foreach ($jobName in $allDefinedJobNames) {
            $jobConfig = $Configuration.BackupLocations[$jobName]
            $taskName = "PoSh-Backup - $($jobName -replace '[\\/:*?"<>|]', '_')"
            Invoke-ScheduledItemSync -ItemName $jobName -ItemConfig $jobConfig -ItemType 'Job' -TaskName $taskName -MainScriptPath $mainScriptPath -ExistingTask ($allTasksInPoshBackupFolder | Where-Object { $_.TaskName -eq $taskName }) -TaskFolder $taskFolder -CreatedTasks ([ref]$createdTasks) -UpdatedTasks ([ref]$updatedTasks) -RemovedTasks ([ref]$removedTasks) -SkippedTasks ([ref]$skippedTasks) -Logger $Logger -PSCmdletInstance $PSCmdletInstance -IsWhatIfMode:$IsWhatIfMode
        }

        foreach ($vJobName in $allDefinedVJobNames) {
            $vJobConfig = $Configuration.VerificationJobs[$vJobName]
            $taskName = "PoSh-Backup Verification - $($vJobName -replace '[\\/:*?"<>|]', '_')"
            Invoke-ScheduledItemSync -ItemName $vJobName -ItemConfig $vJobConfig -ItemType 'Verification' -TaskName $taskName -MainScriptPath $mainScriptPath -ExistingTask ($allTasksInPoshBackupFolder | Where-Object { $_.TaskName -eq $taskName }) -TaskFolder $taskFolder -CreatedTasks ([ref]$createdTasks) -UpdatedTasks ([ref]$updatedTasks) -RemovedTasks ([ref]$removedTasks) -SkippedTasks ([ref]$skippedTasks) -Logger $Logger -PSCmdletInstance $PSCmdletInstance -IsWhatIfMode:$IsWhatIfMode
        }
    }
    catch {
        $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Managers\ScheduleManager\TaskOrchestrator.psm1' exists and is not corrupted."
        & $LocalWriteLog -Message "[FATAL] ScheduleManager: Could not load or execute the TaskOrchestrator module. Schedule sync aborted. Error: $($_.Exception.Message)" -Level "ERROR"
        & $LocalWriteLog -Message $advice -Level "ADVICE"
        return
    }

    if ($null -ne $allTasksInPoshBackupFolder) {
        foreach ($task in $allTasksInPoshBackupFolder) {
            if ($task.TaskName -notin $allManagedTaskNames) {
                if ($PSCmdletInstance.ShouldProcess($task.TaskName, "Unregister Orphaned Scheduled Task (job no longer defined)")) {
                    & $LocalWriteLog -Message "ScheduleManager: Removing orphaned scheduled task '$($task.TaskName)' as its job is no longer defined in the configuration." -Level "WARNING"
                    Unregister-ScheduledTask -InputObject $task -Confirm:$false -ErrorAction Stop
                    $removedTasks.Add($task.TaskName)
                }
            }
        }
    }

    Write-ConsoleBanner -NameText "Schedule Synchronisation Complete" -CenterText -PrependNewLine
    if ($createdTasks.Count -eq 0 -and $updatedTasks.Count -eq 0 -and $removedTasks.Count -eq 0 -and $skippedTasks.Count -eq 0) {
        & $LocalWriteLog -Message "  No changes were made to scheduled tasks." -Level "INFO"
    }
    else {
        if ($createdTasks.Count -gt 0) { & $LocalWriteLog "`n  Tasks Created: $($createdTasks.Count)" "SUCCESS"; $createdTasks | ForEach-Object { & $LocalWriteLog "    - $_" "SUCCESS" } }
        if ($updatedTasks.Count -gt 0) { & $LocalWriteLog "`n  Tasks Updated: $($updatedTasks.Count)" "INFO"; $updatedTasks | ForEach-Object { & $LocalWriteLog "    - $_" "INFO" } }
        if ($removedTasks.Count -gt 0) { & $LocalWriteLog "`n  Tasks Removed: $($removedTasks.Count)" "WARNING"; $removedTasks | ForEach-Object { & $LocalWriteLog "    - $_" "WARNING" } }
        if ($skippedTasks.Count -gt 0) { & $LocalWriteLog "`n  Tasks Skipped: $($skippedTasks.Count)" "DEBUG"; $skippedTasks | ForEach-Object { & $LocalWriteLog "    - $_" "DEBUG" } }
    }
}
#endregion

Export-ModuleMember -Function Sync-PoShBackupSchedule
