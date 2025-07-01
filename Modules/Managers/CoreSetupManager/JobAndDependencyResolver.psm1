# Modules\Managers\CoreSetupManager\JobAndDependencyResolver.psm1
<#
.SYNOPSIS
    Handles job resolution and dependency ordering for a PoSh-Backup run.
.DESCRIPTION
    This sub-module of CoreSetupManager centralizes the logic for determining which
    jobs to run and in what order. It first calls 'Get-JobsToProcess' from
    JobResolver.psm1 to get the initial list of jobs based on user input. Then, it
    calls 'Get-JobExecutionOrder' from JobDependencyManager.psm1 to create the
    final, correctly ordered list that respects all dependencies. It now includes logic
    to bypass dependency resolution if the -SkipJobDependencies switch is used.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.1 # FIX: Pass correct parameters to Get-JobExecutionOrder.
    DateCreated:    17-Jun-2025
    LastModified:   01-Jul-2025
    Purpose:        To centralise job resolution and dependency ordering.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers\CoreSetupManager
try {
    # Import the modules that provide the functions this module calls.
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\ConfigManagement\JobResolver.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot "..\JobDependencyManager.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "JobAndDependencyResolver.psm1 FATAL: Could not import required dependent modules. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Resolve-PoShBackupJobExecutionPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,
        [Parameter(Mandatory = $false)]
        [string]$BackupLocationName,
        [Parameter(Mandatory = $false)]
        [string]$RunSet,
        [Parameter(Mandatory = $false)]
        [string[]]$JobsToSkip,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $false)]
        [switch]$SkipJobDependenciesSwitch
    )

    & $Logger -Message "CoreSetupManager/JobAndDependencyResolver/Resolve-PoShBackupJobExecutionPlan: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue

    # Step 1: Resolve the initial list of jobs based on user input.
    $jobResolutionParams = @{
        Config           = $Configuration
        SpecifiedJobName = $BackupLocationName
        SpecifiedSetName = $RunSet
        JobsToSkip       = $JobsToSkip
        Logger           = $Logger
    }
    $jobResolutionResult = Get-JobsToProcess @jobResolutionParams
    if (-not $jobResolutionResult.Success) {
        throw "Could not determine jobs to process: $($jobResolutionResult.ErrorMessage)"
    }

    # Step 2: Build the final execution order based on the initial list and dependencies.
    $executionOrderResult = @{ Success = $true; OrderedJobs = @() } # Default for case where no jobs are left
    if ($jobResolutionResult.JobsToRun.Count -gt 0) {
        # --- NEW LOGIC for -SkipJobDependencies ---
        if ($SkipJobDependenciesSwitch.IsPresent -and -not [string]::IsNullOrWhiteSpace($BackupLocationName)) {
            & $Logger -Message "CoreSetupManager/JobAndDependencyResolver: The -SkipJobDependencies switch is active. Bypassing dependency resolution and running only '$BackupLocationName'." -Level "WARNING"
            $executionOrderResult.OrderedJobs = [System.Collections.Generic.List[string]]::new()
            $executionOrderResult.OrderedJobs.Add($BackupLocationName)
        }
        else {
            & $Logger -Message "CoreSetupManager/JobAndDependencyResolver: Building job execution order considering dependencies..." -Level "INFO"

            # FIX: Build the dependency map first, then pass it with the correct parameter names.
            $dependencyMap = Get-PoShBackupJobDependencyMap -AllBackupLocations $Configuration.BackupLocations
            $executionOrderResult = Get-JobExecutionOrder -InitialJobsToRun $jobResolutionResult.JobsToRun `
                -AllBackupLocations $Configuration.BackupLocations `
                -DependencyMap $dependencyMap `
                -Logger $Logger

            if (-not $executionOrderResult.Success) {
                throw "Could not build job execution order: $($executionOrderResult.ErrorMessage)"
            }
            if ($executionOrderResult.OrderedJobs.Count -gt 0) {
                & $Logger -Message "CoreSetupManager/JobAndDependencyResolver: Final job execution order: $($executionOrderResult.OrderedJobs -join ', ')" -Level "INFO"
            }
        }
    }

    # Return a combined result object
    return @{
        Success                  = $true
        JobsToProcess            = $executionOrderResult.OrderedJobs
        CurrentSetName           = $jobResolutionResult.SetName
        StopSetOnErrorPolicy     = $jobResolutionResult.StopSetOnErrorPolicy
        SetSpecificPostRunAction = $jobResolutionResult.SetSpecificPostRunAction
    }
}

Export-ModuleMember -Function Resolve-PoShBackupJobExecutionPlan
