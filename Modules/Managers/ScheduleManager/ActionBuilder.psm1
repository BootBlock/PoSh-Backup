# Modules\Managers\ScheduleManager\ActionBuilder.psm1
<#
.SYNOPSIS
    A sub-module for ScheduleManager. Handles the construction of the scheduled task action.
.DESCRIPTION
    This module provides the 'New-PoShBackupTaskAction' function, which is responsible
    for creating a 'ScheduledTaskAction' object. It constructs the correct command-line
    arguments to execute PoSh-Backup.ps1 for a specific backup job or verification job,
    including the `-Quiet` switch to minimise console output from automated runs.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    25-Jun-2025
    LastModified:   25-Jun-2025
    Purpose:        To build the ScheduledTaskAction object for a PoSh-Backup task.
    Prerequisites:  PowerShell 5.1+.
#>

function Get-PoShBackupTaskAction {
    [CmdletBinding()]
    [OutputType([Microsoft.Management.Infrastructure.CimInstance])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Job', 'Verification')]
        [string]$ItemType,

        [Parameter(Mandatory = $true)]
        [string]$ItemName,

        [Parameter(Mandatory = $true)]
        [string]$MainScriptPath,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "ScheduleManager/ActionBuilder: Logger active for Item '$ItemName'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $taskParameter = switch ($ItemType) {
        'Job'          { "-BackupLocationName" }
        'Verification' { "-VerificationJobName" }
    }

    # Construct the arguments for powershell.exe
    # -NoProfile: Speeds up startup.
    # -ExecutionPolicy Bypass: Ensures the script runs without being blocked by execution policy.
    # -File: Specifies the script to run. Paths with spaces are quoted.
    # -<TaskParameter>: The specific job/verification job to run. Name is quoted.
    # -Quiet: Suppresses all non-essential console output for clean task history.
    $taskArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$MainScriptPath`" $taskParameter `"$ItemName`" -Quiet"

    & $Logger -Message "  - ActionBuilder: Built task arguments: $taskArguments" -Level "DEBUG"

    try {
        return New-ScheduledTaskAction -Execute "powershell.exe" -Argument $taskArguments -ErrorAction Stop
    }
    catch {
        & $Logger -Message "  - ActionBuilder: Failed to create ScheduledTaskAction object. Error: $($_.Exception.Message)" -Level "ERROR"
        throw
    }
}

Export-ModuleMember -Function Get-PoShBackupTaskAction
