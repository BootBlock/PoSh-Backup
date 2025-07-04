# Modules\Managers\LogManager.psm1
<#
.SYNOPSIS
    Acts as a facade to provide log file retention functions for PoSh-Backup.
.DESCRIPTION
    The LogManager module's primary responsibility is to manage the lifecycle of log files.
    It provides the 'Invoke-PoShBackupLogRetention' function by lazy-loading its
    'RetentionHandler.psm1' sub-module.

    The core 'Write-LogMessage' function has been moved to the core Utilities modules
    to improve architectural separation of concerns.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.3.0 # Removed Write-LogMessage facade; responsibility moved to Utils.psm1.
    DateCreated:    27-May-2025
    LastModified:   04-Jul-2025
    Purpose:        Facade for log retention management.
    Prerequisites:  PowerShell 5.1+.
#>

# No eager module imports are needed here. They will be lazy-loaded by the wrapper functions.

#region --- Log File Retention Function Facade ---
function Invoke-PoShBackupLogRetention {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogDirectory,
        [Parameter(Mandatory = $true)]
        [string]$JobNamePattern,
        [Parameter(Mandatory = $true)]
        [int]$RetentionCount,
        [Parameter(Mandatory = $true)]
        [bool]$CompressOldLogs,
        [Parameter(Mandatory = $true)]
        [string]$OldLogCompressionFormat,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    if (-not $PSCmdletInstance.ShouldProcess("Log Retention for pattern '$JobNamePattern'", "Apply Policy")) {
        & $Logger -Message "Log retention for pattern '$JobNamePattern' skipped by user (ShouldProcess)." -Level "WARNING"
        return
    }

    try {
        Import-Module -Name (Join-Path $PSScriptRoot "LogManager\RetentionHandler.psm1") -Force -ErrorAction Stop
        # Call the renamed internal function to prevent recursion.
        Invoke-LogFileRetentionPolicyInternal @PSBoundParameters
    }
    catch {
        $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Managers\LogManager\RetentionHandler.psm1' exists and is not corrupted."
        & $Logger -Message "[FATAL] LogManager (Facade): Could not load the RetentionHandler sub-module. Log retention will not be applied. Error: $($_.Exception.Message)" -Level "ERROR"
        & $Logger -Message $advice -Level "ADVICE"
        # Do not throw, as this is a non-critical post-job step.
    }
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupLogRetention
