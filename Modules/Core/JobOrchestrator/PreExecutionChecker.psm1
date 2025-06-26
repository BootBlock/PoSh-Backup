# Modules\Core\JobOrchestrator\PreExecutionChecker.psm1
<#
.SYNOPSIS
    A sub-module for JobOrchestrator. Performs pre-execution checks for a backup job.
.DESCRIPTION
    This module provides the 'Test-PoShBackupJobPreExecution' function. It is responsible
    for determining if a specific job in the run queue is ready to be executed.

    It performs the following critical checks:
    - Verifies that the job is marked as 'Enabled' in the configuration.
    - If 'RunOnlyIfPathExists' is configured, it verifies the primary source path exists.
    - It checks the status of all prerequisite jobs (dependencies) to ensure they completed
      successfully before allowing the current job to proceed.

    The function returns a status object indicating whether to 'Proceed', 'Skip', or 'Fail'.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    26-Jun-2025
    LastModified:   26-Jun-2025
    Purpose:        To centralise all pre-job execution checks and validations.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Core\JobOrchestrator
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "JobOrchestrator\PreExecutionChecker.psm1 FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Test-PoShBackupJobPreExecution {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        # The name of the job being checked.
        [Parameter(Mandatory = $true)]
        [string]$JobName,

        # The configuration hashtable for the specific job.
        [Parameter(Mandatory = $true)]
        [hashtable]$JobConfig,
        
        # The hashtable tracking the success state of all previously run jobs in this set.
        [Parameter(Mandatory = $true)]
        [hashtable]$JobEffectiveSuccessState,

        # A scriptblock reference to the main Write-LogMessage function.
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "JobOrchestrator/PreExecutionChecker: Logger parameter active for job '$JobName'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    # 1. Check if job is enabled
    if ((Get-ConfigValue -ConfigObject $JobConfig -Key 'Enabled' -DefaultValue $true) -ne $true) {
        $reason = "Job '$JobName' is disabled (Enabled = `$false)."
        & $LocalWriteLog -Message $reason -Level "INFO"
        return @{ Status = 'Skip'; Reason = $reason }
    }

    # 2. Check if the job should only run if its primary path exists
    if ((Get-ConfigValue -ConfigObject $JobConfig -Key 'RunOnlyIfPathExists' -DefaultValue $false) -eq $true) {
        $primarySourcePath = if ($JobConfig.Path -is [array]) { $JobConfig.Path[0] } else { $JobConfig.Path }
        if ([string]::IsNullOrWhiteSpace($primarySourcePath) -or -not (Test-Path -Path $primarySourcePath)) {
            $reason = "Job '$JobName' skipped because 'RunOnlyIfPathExists' is true and primary source path '$primarySourcePath' was not found."
            & $LocalWriteLog -Message $reason -Level "WARNING"
            return @{ Status = 'Skip'; Reason = $reason }
        }
    }

    # 3. Check dependencies
    $dependencies = @(Get-ConfigValue -ConfigObject $JobConfig -Key 'DependsOnJobs' -DefaultValue @())
    if ($dependencies.Count -gt 0) {
        & $LocalWriteLog -Message "  - Pre-Check: Job '$JobName' has dependencies: $($dependencies -join ', ')" -Level "DEBUG"
        foreach ($dependencyName in $dependencies) {
            if (-not $JobEffectiveSuccessState.ContainsKey($dependencyName)) {
                $reason = "Prerequisite job '$dependencyName' was not processed or its status is unknown."
                & $LocalWriteLog -Message "[ERROR] Job '$JobName' SKIPPED. $reason" -Level "ERROR"
                return @{ Status = 'Skip'; Reason = $reason }
            }
            if ($JobEffectiveSuccessState[$dependencyName] -eq $false) {
                $reason = "Prerequisite job '$dependencyName' did not complete successfully."
                & $LocalWriteLog -Message "[WARNING] Job '$JobName' SKIPPED. $reason" -Level "WARNING"
                return @{ Status = 'Skip'; Reason = $reason }
            }
            & $LocalWriteLog -Message "    - Prerequisite '$dependencyName' check: PASSED." -Level "DEBUG"
        }
    }

    # If all checks pass, we can proceed.
    return @{ Status = 'Proceed'; Reason = 'All pre-execution checks passed.' }
}

Export-ModuleMember -Function Test-PoShBackupJobPreExecution
