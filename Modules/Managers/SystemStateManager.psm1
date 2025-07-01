# Modules\Managers\SystemStateManager.psm1
<#
.SYNOPSIS
    Manages system state changes like shutdown, restart, hibernate, logoff, sleep, or lock workstation,
    typically invoked after PoSh-Backup job/set completion.
.DESCRIPTION
    This module provides the functionality to perform various system power and session actions.
    It orchestrates the process by:
    - Calling 'Test-HibernateEnabled' from SystemUtils.psm1 to validate the hibernate action.
    - Calling 'Start-CancellableCountdown' from ConsoleDisplayUtils.psm1 to manage the user-cancellable delay.
    - Executing the final system state change command (e.g., shutdown.exe, rundll32.exe).

    The main exported function, Invoke-SystemStateAction, is designed to be called by
    the main PoSh-Backup script with parameters derived from job, set, or CLI configurations.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.0.0 # Refactored to use utility modules for checks and countdown.
    DateCreated:    22-May-2025
    LastModified:   01-Jul-2025
    Purpose:        To provide controlled system state change capabilities for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Administrator privileges may be required for actions like Shutdown, Restart, Hibernate.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utilities\SystemUtils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utilities\ConsoleDisplayUtils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "SystemStateManager.psm1 FATAL: Could not import required utility modules. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- Exported Function: Invoke-SystemStateAction ---
function Invoke-SystemStateAction {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    <#
    .SYNOPSIS
        Performs a configured system state action (e.g., shutdown, restart) after a delay,
        with an option for the user to cancel during the countdown.
    .DESCRIPTION
        This function executes a specified system power or session action.
        It supports a delay before execution, during which the user can cancel the action
        by pressing 'C' in the console. It also handles simulation mode and checks for
        hibernation support if that action is requested.
    .PARAMETER Action
        The system state action to perform.
        Valid values: "Shutdown", "Restart", "Hibernate", "LogOff", "Sleep", "Lock".
    .PARAMETER DelaySeconds
        The number of seconds to wait before performing the action.
        During this delay, the user can cancel by pressing 'C'. Defaults to 0 (no delay).
    .PARAMETER ForceAction
        A switch. If specified, for actions like Shutdown or Restart, it attempts to force
        the operation (e.g., closing applications without saving).
    .PARAMETER IsSimulateMode
        A switch. If $true, the action is logged as if it would occur, but no actual
        system state change is performed.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function.
    .PARAMETER PSCmdletInstance
        A mandatory reference to the calling cmdlet's $PSCmdlet automatic variable.
        Used for `ShouldProcess` calls to respect -WhatIf and -Confirm.
    .EXAMPLE
        # Invoke-SystemStateAction -Action "Shutdown" -DelaySeconds 30 -Logger ${function:Write-LogMessage} -PSCmdletInstance $PSCmdlet
    .OUTPUTS
        System.Boolean
        $true if the action was successfully initiated (or simulated), $false if cancelled or skipped.
    #>
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
        if (-not (Test-HibernateEnabled -Logger $Logger)) {
            & $LocalWriteLog -Message "[WARNING] SystemStateManager: Action 'Hibernate' requested, but hibernation is not enabled on this system. Skipping action." -Level "WARNING"
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
        if (-not (Start-CancellableCountdown -DelaySeconds $DelaySeconds -ActionDisplayName $actionDisplayName -Logger $Logger -PSCmdletInstance $PSCmdletInstance)) {
            return $false # Action was cancelled or skipped
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
