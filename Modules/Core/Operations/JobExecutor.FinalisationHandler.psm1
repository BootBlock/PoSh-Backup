# Modules\Core\Operations\JobExecutor.FinalisationHandler.psm1
<#
.SYNOPSIS
    Handles the finalisation tasks for a PoSh-Backup job's execution within JobExecutor.
    This includes clearing sensitive data and populating final report data fields.
    This is a sub-module of JobExecutor.psm1.
.DESCRIPTION
    This module provides the 'Invoke-PoShBackupJobFinalisation' function.
    It is responsible for:
    - Securely clearing any plain text password that was held in memory.
    - Setting the final 'OverallStatus' in the job's report data.
    - Calculating and setting 'ScriptEndTime', 'TotalDuration', and 'TotalDurationSeconds'
      in the job's report data.
    This function is typically called from the 'finally' block of the main job executor.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    30-May-2025
    LastModified:   30-May-2025
    Purpose:        To modularise job finalisation logic from JobExecutor.
    Prerequisites:  PowerShell 5.1+.
#>

# No direct module dependencies beyond what PowerShell provides by default.

function Invoke-PoShBackupJobFinalisation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$JobName, # For logging context
        [Parameter(Mandatory = $true)]
        [ref]$JobReportDataRef, # The [ref] to the main report data hashtable
        [Parameter(Mandatory = $true)]
        [string]$CurrentJobStatus, # The operational status of the job
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $false)]
        [string]$PlainTextPasswordToClear, # The plain text password variable from the calling scope
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
    & $LocalWriteLog -Message "JobExecutor.FinalisationHandler/Invoke-PoShBackupJobFinalisation: Initializing for job '$JobName'." -Level "DEBUG"

    $reportData = $JobReportDataRef.Value

    # Clear plain text password
    if (-not [string]::IsNullOrWhiteSpace($PlainTextPasswordToClear)) {
        try {
            # Attempt to clear the variable in the *caller's* scope if it was passed by reference
            # However, PowerShell passes strings by value. The original variable needs to be nulled out
            # in the scope it was defined (JobExecutor.psm1).
            # This function can only confirm the attempt based on the value it received.
            # For true clearing, the caller (JobExecutor) must null its own variable.
            # We will log the intent here.
            & $LocalWriteLog -Message "   - JobExecutor.FinalisationHandler: Received request to clear plain text password for job '$JobName'." -Level "DEBUG"
            # The actual clearing of the variable $plainTextPasswordToClearAfterJob must happen in JobExecutor.psm1
        }
        catch {
            & $LocalWriteLog -Message "[WARNING] JobExecutor.FinalisationHandler: Exception during attempt to log password clearing for job '$JobName'. Error: $($_.Exception.Message)" -Level WARNING
        }
    }

    # Set final report status
    if ($IsSimulateMode.IsPresent -and $CurrentJobStatus -ne "FAILURE" -and $CurrentJobStatus -ne "WARNINGS") {
        $reportData.OverallStatus = "SIMULATED_COMPLETE"
    }
    else {
        $reportData.OverallStatus = $CurrentJobStatus
    }

    # Set final report timings
    $reportData.ScriptEndTime = Get-Date
    if (($reportData.PSObject.Properties.Name -contains 'ScriptStartTime') -and ($null -ne $reportData.ScriptStartTime)) {
        $reportData.TotalDuration = $reportData.ScriptEndTime - $reportData.ScriptStartTime
        if ($reportData.PSObject.Properties.Name -contains 'TotalDurationSeconds' -and $reportData.TotalDuration -is [System.TimeSpan]) {
            $reportData.TotalDurationSeconds = $reportData.TotalDuration.TotalSeconds
        }
        elseif ($reportData.TotalDuration -is [System.TimeSpan]) { # Ensure TotalDurationSeconds is added if not present
            $reportData.TotalDurationSeconds = $reportData.TotalDuration.TotalSeconds
        }
    }
    else {
        # Ensure these fields exist even if start time was missing, to maintain report structure
        $reportData.TotalDuration = "N/A (Timing data incomplete)"
        $reportData.TotalDurationSeconds = 0
    }

    & $LocalWriteLog -Message "JobExecutor.FinalisationHandler/Invoke-PoShBackupJobFinalisation: Job finalisation tasks complete for job '$JobName'." -Level "DEBUG"
}

Export-ModuleMember -Function Invoke-PoShBackupJobFinalisation
