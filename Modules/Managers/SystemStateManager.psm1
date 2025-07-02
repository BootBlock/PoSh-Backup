# Modules\Managers\SystemStateManager.psm1
<#
.SYNOPSIS
    Manages system state changes like shutdown, restart, hibernate, logoff, sleep, or lock workstation,
    typically invoked after PoSh-Backup job/set completion.
.DESCRIPTION
    This module provides the functionality to perform various system power and session actions.
    It orchestrates the process by lazy-loading its dependencies:
    - It calls 'Test-HibernateEnabled' from SystemUtils.psm1 (loaded on-demand) to validate the hibernate action.
    - It calls 'Start-CancellableCountdown' from ConsoleDisplayUtils.psm1 (loaded on-demand) to manage the user-cancellable delay.
    - It executes the final system state change command (e.g., shutdown.exe, rundll32.exe).

    The main exported function, Invoke-SystemStateAction, is designed to be called by
    the PostRunActionOrchestrator.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.1.0 # Refactored to lazy-load utility modules.
    DateCreated:    22-May-2025
    LastModified:   02-Jul-2025
    Purpose:        To provide controlled system state change capabilities for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Administrator privileges may be required for actions like Shutdown, Restart, Hibernate.
#>

# No eager module imports are needed here. They will be lazy-loaded.

#region --- Exported Function: Invoke-SystemStateAction ---
function Invoke-SystemStateAction {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Shutdown", "Restart", "Hibernate", "LogOff", "Sleep", "Lock")]
        [string]$Action,

        [Parameter(Mandatory = $false)]
        [int]$DelaySeconds = 0,

        [Parameter(Mandatory = $false)]
        [switch]$ForceAction,

        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    $actionDisplayName = $Action
    if ($ForceAction.IsPresent -and ($Action -in "Shutdown", "Restart")) {
        $actionDisplayName = "Forced $Action"
    }

    & $LocalWriteLog -Message "SystemStateManager: Preparing to invoke system action: '$actionDisplayName'." -Level "INFO"

    if ($Action -eq "Hibernate") {
        try {
            Import-Module -Name (Join-Path $PSScriptRoot "..\Utilities\SystemUtils.psm1") -Force -ErrorAction Stop
            if (-not (Test-HibernateEnabled -Logger $Logger)) {
                & $LocalWriteLog -Message "[WARNING] SystemStateManager: Action 'Hibernate' requested, but hibernation is not enabled on this system. Skipping action." -Level "WARNING"
                return $false
            }
        } catch {
            & $LocalWriteLog -Message "[ERROR] SystemStateManager: Could not load SystemUtils to check hibernate status. Skipping action. Error: $($_.Exception.Message)" -Level "ERROR"
            return $false
        }
    }

    if ($IsSimulateMode.IsPresent) {
        if ($DelaySeconds -gt 0) {
            & $LocalWriteLog -Message "SIMULATE: SystemStateManager: Would start a $DelaySeconds-second cancellable countdown before performing the action." -Level "SIMULATE"
        }
        $simulatedActionDescription = "an unknown action"
        switch ($Action) {
            "Shutdown"  { $simulatedActionDescription = "a system SHUTDOWN" }
            "Restart"   { $simulatedActionDescription = "a system RESTART" }
            "Hibernate" { $simulatedActionDescription = "system HIBERNATION" }
            "LogOff"    { $simulatedActionDescription = "a user LOG OFF" }
            "Sleep"     { $simulatedActionDescription = "system SLEEP" }
            "Lock"      { $simulatedActionDescription = "a workstation LOCK" }
        }
        if ($ForceAction.IsPresent -and ($Action -in "Shutdown", "Restart")) {
            $simulatedActionDescription = "a FORCED " + $simulatedActionDescription
        }
        & $LocalWriteLog -Message "SIMULATE: SystemStateManager: Would initiate $simulatedActionDescription." -Level "SIMULATE"
        return $true
    }

    if ($DelaySeconds -gt 0) {
        try {
            Import-Module -Name (Join-Path $PSScriptRoot "..\Utilities\ConsoleDisplayUtils.psm1") -Force -ErrorAction Stop
            if (-not (Start-CancellableCountdown -DelaySeconds $DelaySeconds -ActionDisplayName $actionDisplayName -Logger $Logger -PSCmdletInstance $PSCmdletInstance)) {
                return $false # Action was cancelled or skipped
            }
        }
        catch {
            $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Utilities\ConsoleDisplayUtils.psm1' exists and is not corrupted."
            & $LocalWriteLog -Message "[ERROR] SystemStateManager: Could not load ConsoleDisplayUtils for countdown. Action will proceed immediately. Error: $($_.Exception.Message)" -Level "ERROR"
            & $LocalWriteLog -Message $advice -Level "ADVICE"
        }
    }

    if (-not $PSCmdletInstance.ShouldProcess("System", "Perform Action: $actionDisplayName")) {
        & $LocalWriteLog -Message "SystemStateManager: Action '$actionDisplayName' skipped by user (ShouldProcess)." -Level "INFO"
        return $false
    }

    & $LocalWriteLog -Message "SystemStateManager: EXECUTING system action: '$actionDisplayName' NOW." -Level "WARNING"
    try {
        switch ($Action) {
            "Shutdown" {
                if ($ForceAction.IsPresent) { Stop-Computer -Force -ErrorAction Stop }
                else { shutdown.exe /s /t 0 /c "PoSh-Backup: System shutdown initiated." | Out-Null }
            }
            "Restart" {
                if ($ForceAction.IsPresent) { Restart-Computer -Force -ErrorAction Stop }
                else { shutdown.exe /r /t 0 /c "PoSh-Backup: System restart initiated." | Out-Null }
            }
            "Hibernate" {
                rundll32.exe powrprof.dll,SetSuspendState Hibernate
            }
            "LogOff" {
                shutdown.exe /l | Out-Null
            }
            "Sleep" {
                rundll32.exe powrprof.dll,SetSuspendState Sleep
            }
            "Lock" {
                rundll32.exe user32.dll,LockWorkStation
            }
        }
        & $LocalWriteLog -Message "SystemStateManager: Action '$actionDisplayName' command issued successfully." -Level "SUCCESS"
        return $true
    }
    catch {
        & $LocalWriteLog -Message "[ERROR] SystemStateManager: Failed to execute action '$actionDisplayName'. Error: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}
#endregion

Export-ModuleMember -Function Invoke-SystemStateAction
