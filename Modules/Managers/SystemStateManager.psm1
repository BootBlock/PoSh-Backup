# Modules\SystemStateManager.psm1
<#
.SYNOPSIS
    Manages system state changes like shutdown, restart, hibernate, logoff, sleep, or lock workstation,
    typically invoked after PoSh-Backup job/set completion.

.DESCRIPTION
    This module provides the functionality to perform various system power and session actions.
    It includes features for a delayed action with a user-cancellable countdown, checking
    for hibernation support, and simulating actions for test runs.

    The primary exported function, Invoke-SystemStateAction, is designed to be called by
    the main PoSh-Backup script with parameters derived from job, set, or CLI configurations.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.2 # Added ShouldProcess support to Start-CancellableCountdownInternal.
    DateCreated:    22-May-2025
    LastModified:   22-May-2025
    Purpose:        To provide controlled system state change capabilities for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Administrator privileges may be required for actions like Shutdown, Restart, Hibernate.
#>

#region --- Internal Helper: Test Hibernate Enabled ---
function Test-HibernateEnabledInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    # Defensive PSSA appeasement
    & $Logger -Message "SystemStateManager/Test-HibernateEnabledInternal: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    try {
        # Check powercfg /a output for hibernation status
        $powerCfgOutput = powercfg /a
        if ($powerCfgOutput -join ' ' -match "Hibernation has not been enabled|The hiberfile is not reserved") {
            & $LocalWriteLog -Message "  - Hibernate Check: Hibernation is NOT currently enabled on this system (per powercfg /a)." -Level "INFO"
            return $false
        }
        # More robust check: Query registry if powercfg is ambiguous or for confirmation
        # HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Power -> HibernateEnabled (DWORD: 1 for enabled, 0 for disabled)
        $hibernateRegKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Power"
        if (Test-Path $hibernateRegKey) {
            $hibernateEnabledValue = Get-ItemProperty -Path $hibernateRegKey -Name "HibernateEnabled" -ErrorAction SilentlyContinue
            if ($null -ne $hibernateEnabledValue -and $hibernateEnabledValue.HibernateEnabled -eq 1) {
                & $LocalWriteLog -Message "  - Hibernate Check: Hibernation IS enabled on this system (Registry: HibernateEnabled=1)." -Level "DEBUG"
                return $true
            } elseif ($null -ne $hibernateEnabledValue) {
                & $LocalWriteLog -Message "  - Hibernate Check: Hibernation is NOT enabled on this system (Registry: HibernateEnabled=$($hibernateEnabledValue.HibernateEnabled))." -Level "INFO"
                return $false
            }
        }
        # Fallback if registry check fails but powercfg didn't explicitly say disabled
        # This path is less likely if powercfg /a is reliable.
        & $LocalWriteLog -Message "  - Hibernate Check: Hibernation status could not be definitively confirmed via registry, relying on powercfg output (if it didn't explicitly state disabled, assuming enabled)." -Level "DEBUG"
        # If powercfg didn't say "not enabled", we assume it might be.
        # This is a weaker confirmation but better than nothing if registry fails.
        return ($powerCfgOutput -join ' ' -notmatch "Hibernation has not been enabled|The hiberfile is not reserved")

    } catch {
        & $LocalWriteLog -Message "[WARNING] SystemStateManager/Test-HibernateEnabledInternal: Error checking hibernation status. Error: $($_.Exception.Message)" -Level "WARNING"
        return $false # Assume not enabled if check fails
    }
}
#endregion

#region --- Internal Helper: Start Cancellable Countdown ---
# PSScriptAnalyzer Suppress PSUseApprovedVerbs[Start-CancellableCountdownInternal] - 'Start' is descriptive for this internal helper that manages a countdown process, not directly a state-changing verb for end-user.
function Start-CancellableCountdownInternal {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')] # Added SupportsShouldProcess
    param(
        [Parameter(Mandatory = $true)]
        [int]$DelaySeconds,
        [Parameter(Mandatory = $true)]
        [string]$ActionDisplayName,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)] # Added PSCmdletInstance
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )
    # Defensive PSSA appeasement
    & $Logger -Message "SystemStateManager/Start-CancellableCountdownInternal: Logger parameter active for action '$ActionDisplayName'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    if ($DelaySeconds -le 0) {
        return $true # No delay, proceed with action
    }

    # Respect -WhatIf and -Confirm before starting the countdown
    if (-not $PSCmdletInstance.ShouldProcess("System (Action: $ActionDisplayName)", "Display $DelaySeconds-second Cancellable Countdown")) {
        & $LocalWriteLog -Message "SystemStateManager: Cancellable countdown for action '$ActionDisplayName' skipped by user (ShouldProcess)." -Level "INFO"
        return $false # Indicate that the countdown (and thus the action) should not proceed
    }

    & $LocalWriteLog -Message "SystemStateManager: Action '$ActionDisplayName' will occur in $DelaySeconds seconds. Press 'C' to cancel." -Level "WARNING"

    $cancelled = $false
    for ($i = $DelaySeconds; $i -gt 0; $i--) {
        Write-Host -NoNewline "`rAction '$ActionDisplayName' in $i seconds... (Press 'C' to cancel) " # Extra space to clear previous longer numbers
        if ($Host.UI.RawUI.KeyAvailable) {
            $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            if ($key.Character -eq 'c' -or $key.Character -eq 'C') {
                $cancelled = $true
                break
            }
        }
        Start-Sleep -Seconds 1
    }
    Write-Host "`r" # Clear the countdown line

    if ($cancelled) {
        & $LocalWriteLog -Message "SystemStateManager: Action '$ActionDisplayName' CANCELLED by user." -Level "INFO"
        return $false # Action cancelled
    }
    return $true # Proceed with action
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

    # Defensive PSSA appeasement
    & $Logger -Message "SystemStateManager/Invoke-SystemStateAction: Logger parameter active for action '$Action'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    $actionDisplayName = $Action
    if ($ForceAction.IsPresent -and ($Action -in "Shutdown", "Restart")) {
        $actionDisplayName = "Forced $Action"
    }

    & $LocalWriteLog -Message "SystemStateManager: Preparing to invoke system action: '$actionDisplayName'." -Level "INFO"

    if ($Action -eq "Hibernate") {
        if (-not (Test-HibernateEnabledInternal -Logger $Logger)) {
            & $LocalWriteLog -Message "[WARNING] SystemStateManager: Action 'Hibernate' requested, but hibernation is not enabled on this system. Skipping action." -Level "WARNING"
            return $false
        }
    }

    if ($IsSimulateMode.IsPresent) {
        if ($DelaySeconds -gt 0) {
            & $LocalWriteLog -Message "SIMULATE: SystemStateManager: Would start $DelaySeconds second cancellable countdown for action '$actionDisplayName'." -Level "SIMULATE"
        }
        & $LocalWriteLog -Message "SIMULATE: SystemStateManager: Would perform system action: '$actionDisplayName'." -Level "SIMULATE"
        return $true
    }

    # Proceed with countdown if delay is configured
    if ($DelaySeconds -gt 0) {
        # Pass PSCmdletInstance to the countdown function
        if (-not (Start-CancellableCountdownInternal -DelaySeconds $DelaySeconds -ActionDisplayName $actionDisplayName -Logger $Logger -PSCmdletInstance $PSCmdletInstance)) {
            return $false # Action was cancelled or skipped by ShouldProcess in countdown
        }
    }

    # Confirm actual execution with ShouldProcess
    if (-not $PSCmdletInstance.ShouldProcess("System", "Perform Action: $actionDisplayName")) {
        & $LocalWriteLog -Message "SystemStateManager: Action '$actionDisplayName' skipped by user (ShouldProcess)." -Level "INFO"
        return $false
    }

    & $LocalWriteLog -Message "SystemStateManager: EXECUTING system action: '$actionDisplayName' NOW." -Level "WARNING" # Warning level for visibility
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
                shutdown.exe /l | Out-Null # /l forces logoff, no /f needed typically
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
