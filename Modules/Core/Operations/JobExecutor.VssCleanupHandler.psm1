# Modules\Core\Operations\JobExecutor.VssCleanupHandler.psm1
<#
.SYNOPSIS
    Handles the cleanup of Volume Shadow Copies (VSS) for a PoSh-Backup job.
    This is a sub-module of JobExecutor.psm1.
.DESCRIPTION
    This module provides the 'Invoke-PoShBackupVssCleanup' function.
    It is responsible for calling 'Remove-VSSShadowCopy' from the VssManager module
    if VSS shadow copies were created and tracked during the job's execution.
    This function is typically called from the 'finally' block of the main job executor.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    30-May-2025
    LastModified:   30-May-2025
    Purpose:        To modularise VSS cleanup logic from JobExecutor.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Modules\Managers\VssManager.psm1.
#>

# Explicitly import VssManager.psm1 from the parent 'Modules\Managers' directory.
# $PSScriptRoot here is Modules\Core\Operations.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Managers\VssManager.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "JobExecutor.VssCleanupHandler.psm1 FATAL: Could not import VssManager.psm1. Error: $($_.Exception.Message)"
    throw
}

function Invoke-PoShBackupVssCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)] # VSSPathsToCleanUp might be $null if VSS wasn't used or failed early
        $VSSPathsToCleanUp, # This is the map of paths, but VssManager.Remove-VSSShadowCopy uses its internal tracking
        [Parameter(Mandatory = $true)]
        [string]$JobName, # For logging context
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        }
        else {
            & $Logger -Message $Message -Level $Level
        }
    }
    & $LocalWriteLog -Message "JobExecutor.VssCleanupHandler/Invoke-PoShBackupVssCleanup: Initializing for job '$JobName'." -Level "DEBUG"

    if ($null -ne $VSSPathsToCleanUp) { # Check if VSS was actually used and paths were tracked
        & $LocalWriteLog -Message "JobExecutor.VssCleanupHandler: Initiating VSS Cleanup via VssManager for job '$JobName'." -Level "DEBUG"
        Remove-VSSShadowCopy -IsSimulateMode:$IsSimulateMode.IsPresent -Logger $Logger
        # VssManager's Remove-VSSShadowCopy handles its own ShouldProcess logic if applicable
    }
    else {
        & $LocalWriteLog -Message "JobExecutor.VssCleanupHandler: No VSS paths were tracked for job '$JobName'. Skipping VSS cleanup." -Level "DEBUG"
    }
    & $LocalWriteLog -Message "JobExecutor.VssCleanupHandler/Invoke-PoShBackupVssCleanup: VSS cleanup phase complete for job '$JobName'." -Level "DEBUG"
}

Export-ModuleMember -Function Invoke-PoShBackupVssCleanup
