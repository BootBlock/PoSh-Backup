# Modules\Managers\ScheduleManager.psm1
<#
.SYNOPSIS
    Manages the creation, update, and deletion of Windows Scheduled Tasks for PoSh-Backup jobs.
    This module now acts as a facade for its sub-modules.
.DESCRIPTION
    This module provides the functionality to synchronise the schedule configurations defined
    in the PoSh-Backup config file with the Windows Task Scheduler. It reads the 'Schedule'
    settings for each backup job and verification job, and ensures a corresponding scheduled
    task exists and is correctly configured.

    The main exported function, 'Sync-PoShBackupSchedule', orchestrates the process by:
    - Ensuring the main 'PoSh-Backup' task folder exists in Task Scheduler.
    - Getting a list of all existing tasks in that folder.
    - Iterating through all defined backup jobs and verification jobs from the configuration.
    - Calling 'Invoke-ScheduledItemSync' from its 'TaskOrchestrator.psm1' sub-module for each item.
    - Cleaning up any orphaned tasks that no longer exist in the configuration.
    - Displaying a final summary of actions taken.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.0.0 # Refactored into a facade with sub-modules.
    DateCreated:    08-Jun-2025
    LastModified:   25-Jun-2025
    Purpose:        To manage Windows Scheduled Tasks based on PoSh-Backup configuration.
    Prerequisites:  PowerShell 5.1+.
                    Requires Administrator privileges to create/modify scheduled tasks.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utilities\SystemUtils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utilities\ConsoleDisplayUtils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "ScheduleManager\TaskOrchestrator.psm1") -Force -ErrorAction Stop
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
        # The fully loaded and merged PoSh-Backup configuration hashtable.
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,

        # The root path of the main PoSh-Backup.ps1 script, used to build task actions.
        [Parameter(Mandatory = $true)]
        [string]$PSScriptRoot,

        # A scriptblock reference to the main Write-LogMessage function.
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,

        # A reference to the calling cmdlet's $PSCmdlet automatic variable for ShouldProcess support.
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
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
    $mainScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "PoSh-Backup.ps1"

    # Ensure the task folder exists
    try {
        $scheduler = New-Object -ComObject "Schedule.Service"; $scheduler.Connect()
        $rootFolder = $scheduler.GetFolder("\")
        try { $null = $rootFolder.GetFolder($taskFolder) } catch {
            if ($PSCmdlet.ShouldProcess("Task Scheduler Root", "Create Folder '$taskFolder'")) {
                & $LocalWriteLog -Message "ScheduleManager: Creating folder '$taskFolder' in Task Scheduler." -Level "INFO"
                $rootFolder.CreateFolder($taskFolder, $null) | Out-Null; & $LocalWriteLog -Message "ScheduleManager: Task Scheduler folder '$taskFolder' created successfully." -Level "SUCCESS"
            }
            else { & $LocalWriteLog -Message "ScheduleManager: Task folder creation skipped by user. Cannot proceed." -Level "WARNING"; return }
        }
    } catch {
        & $LocalWriteLog -Message "ScheduleManager: Failed to connect to the Task Scheduler service. Error: $($_.Exception.Message)" -Level "ERROR"; return
    }

    # Get all tasks once to avoid repeated calls
    $allTasksInPoshBackupFolder = @(Get-ScheduledTask -TaskPath ($taskFolder + "\*") -ErrorAction SilentlyContinue)

    $allDefinedJobNames = if ($Configuration.BackupLocations -is [hashtable]) { @($Configuration.BackupLocations.Keys) } else { @() }
    $allDefinedVJobNames = if ($Configuration.ContainsKey('VerificationJobs')) { @($Configuration.VerificationJobs.Keys) } else { @() }
    $allManagedTaskNames = @($allDefinedJobNames | ForEach-Object { "PoSh-Backup - $_" }) + @($allDefinedVJobNames | ForEach-Object { "PoSh-Backup Verification - $_" })

    # --- Step 1: Process and synchronise backup jobs defined in the configuration ---
    foreach ($jobName in $allDefinedJobNames) {
        $jobConfig = $Configuration.BackupLocations[$jobName]
        $taskName = "PoSh-Backup - $($jobName -replace '[\\/:*?"<>|]', '_')"
        Invoke-ScheduledItemSync -ItemName $jobName -ItemConfig $jobConfig -ItemType 'Job' -TaskName $taskName -MainScriptPath $mainScriptPath -ExistingTask ($allTasksInPoshBackupFolder | Where-Object { $_.TaskName -eq $taskName }) -TaskFolder $taskFolder -CreatedTasks ([ref]$createdTasks) -UpdatedTasks ([ref]$updatedTasks) -RemovedTasks ([ref]$removedTasks) -SkippedTasks ([ref]$skippedTasks) -Logger $Logger -PSCmdlet $PSCmdlet
    }

    # --- Step 2: Process and synchronise verification jobs defined in the configuration ---
    foreach ($vJobName in $allDefinedVJobNames) {
        $vJobConfig = $Configuration.VerificationJobs[$vJobName]
        $taskName = "PoSh-Backup Verification - $($vJobName -replace '[\\/:*?"<>|]', '_')"
        Invoke-ScheduledItemSync -ItemName $vJobName -ItemConfig $vJobConfig -ItemType 'Verification' -TaskName $taskName -MainScriptPath $mainScriptPath -ExistingTask ($allTasksInPoshBackupFolder | Where-Object { $_.TaskName -eq $taskName }) -TaskFolder $taskFolder -CreatedTasks ([ref]$createdTasks) -UpdatedTasks ([ref]$updatedTasks) -RemovedTasks ([ref]$removedTasks) -SkippedTasks ([ref]$skippedTasks) -Logger $Logger -PSCmdlet $PSCmdlet
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
    Write-ConsoleBanner -NameText "Schedule Synchronisation Complete" -CenterText -PrependNewLine
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
