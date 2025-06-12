# Modules\Core\Operations\JobExecutor.SnapshotCleanupHandler.psm1
<#
.SYNOPSIS
    Handles the cleanup of infrastructure snapshots (e.g., Hyper-V) for a PoSh-Backup job.
    This is a sub-module of JobExecutor.psm1.
.DESCRIPTION
    This module provides the 'Invoke-PoShBackupSnapshotCleanup' function.
    It is responsible for calling 'Remove-PoShBackupSnapshot' from the SnapshotManager
    module if an infrastructure snapshot was created and tracked during the job's execution.
    This function is designed to be called from the 'finally' block of the main job executor
    to ensure snapshots are always removed.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    10-Jun-2025
    LastModified:   10-Jun-2025
    Purpose:        To modularise infrastructure snapshot cleanup logic for JobExecutor.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Modules\Managers\SnapshotManager.psm1.
#>

# Explicitly import SnapshotManager.psm1 from the 'Modules\Managers' directory.
# $PSScriptRoot here is Modules\Core\Operations.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Managers\SnapshotManager.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "JobExecutor.SnapshotCleanupHandler.psm1 FATAL: Could not import SnapshotManager.psm1. Error: $($_.Exception.Message)"
    throw
}

function Invoke-PoShBackupSnapshotCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)] # SnapshotSession might be $null if snapshotting wasn't used or failed early
        [hashtable]$SnapshotSession,
        [Parameter(Mandatory = $true)]
        [string]$JobName, # For logging context
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )

    & $Logger -Message "JobExecutor.SnapshotCleanupHandler/Invoke-PoShBackupSnapshotCleanup: Logger parameter active for job '$JobName'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO")
        & $Logger -Message $Message -Level $Level
    }
    & $LocalWriteLog -Message "JobExecutor.SnapshotCleanupHandler/Invoke-PoShBackupSnapshotCleanup: Initializing for job '$JobName'." -Level "DEBUG"

    if ($null -ne $SnapshotSession) {
        & $LocalWriteLog -Message "JobExecutor.SnapshotCleanupHandler: Initiating infrastructure snapshot cleanup via SnapshotManager for job '$JobName'." -Level "DEBUG"
        try {
            Remove-PoShBackupSnapshot -SnapshotSession $SnapshotSession -PSCmdlet $PSCmdlet
        }
        catch {
            # This catch block is a safeguard. The underlying functions should handle their own errors.
            & $LocalWriteLog -Message "[ERROR] JobExecutor.SnapshotCleanupHandler: An unexpected error occurred while calling Remove-PoShBackupSnapshot. Error: $($_.Exception.Message)" -Level "ERROR"
        }
    }
    else {
        & $LocalWriteLog -Message "JobExecutor.SnapshotCleanupHandler: No snapshot session was tracked for job '$JobName'. Skipping snapshot cleanup." -Level "DEBUG"
    }
    & $LocalWriteLog -Message "JobExecutor.SnapshotCleanupHandler/Invoke-PoShBackupSnapshotCleanup: Snapshot cleanup phase complete for job '$JobName'." -Level "DEBUG"
}

Export-ModuleMember -Function Invoke-PoShBackupSnapshotCleanup
