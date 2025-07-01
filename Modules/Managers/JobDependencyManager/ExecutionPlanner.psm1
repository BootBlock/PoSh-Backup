# Modules\Managers\JobDependencyManager\ExecutionPlanner.psm1
<#
.SYNOPSIS
    A sub-module for the JobDependencyManager facade. Determines the correct job execution order.
.DESCRIPTION
    This module provides the 'Get-JobExecutionOrder' function. Its sole responsibility is to
    take a list of jobs the user wants to run, expand that list to include all necessary
    dependencies, and then perform a topological sort on the resulting job set. This produces
    a final, ordered list where every job is guaranteed to run after all of its prerequisites
    have completed. It relies on the pre-computed dependency map and assumes the graph has
    already been validated for cycles.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.2 # FIX: Removed unused AllBackupLocations param, used Logger param.
    DateCreated:    01-Jul-2025
    LastModified:   01-Jul-2025
    Purpose:        To isolate the job execution ordering logic (topological sort).
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers\JobDependencyManager
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "JobDependencyManager\ExecutionPlanner.psm1 FATAL: Could not import Utils.psm1. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- Exported Execution Order Function ---
function Get-JobExecutionOrder {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$InitialJobsToRun,
        [Parameter(Mandatory = $true)]
        [hashtable]$DependencyMap,
        [Parameter(Mandatory = $false)]
        [scriptblock]$Logger
    )

    & $Logger -Message "ExecutionPlanner/Get-JobExecutionOrder: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO")
        if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) { & $Logger -Message $Message -Level $Level }
    }

    # 1. Expand the initial list to include all dependencies recursively
    $relevantJobsSet = @{} # Use Hashtable as a set for efficient lookups
    $queueForExpansion = New-Object System.Collections.Queue
    
    foreach ($jobName in $InitialJobsToRun) {
        if (-not $relevantJobsSet.ContainsKey($jobName)) {
            $relevantJobsSet[$jobName] = $true
            $queueForExpansion.Enqueue($jobName)
        }
    }
    
    while ($queueForExpansion.Count -gt 0) {
        $currentJob = $queueForExpansion.Dequeue()
        if ($DependencyMap.ContainsKey($currentJob)) {
            foreach ($dependencyName in $DependencyMap[$currentJob]) {
                if (-not $relevantJobsSet.ContainsKey($dependencyName)) {
                    $relevantJobsSet[$dependencyName] = $true
                    $queueForExpansion.Enqueue($dependencyName)
                }
            }
        }
    }
    
    $jobsToOrder = @($relevantJobsSet.Keys)
    & $LocalWriteLog -Message "ExecutionPlanner: Full list of relevant jobs for ordering (including dependencies): $($jobsToOrder -join ', ')" -Level "DEBUG"

    # 2. Perform Topological Sort (Kahn's algorithm) on the relevant jobs
    $adj = @{}       # Adjacency list: Prerequisite -> [Dependents]
    $inDegree = @{}  # In-degree count for each job
    
    foreach ($jobName in $jobsToOrder) {
        $adj[$jobName] = @()
        $inDegree[$jobName] = 0
    }
    
    foreach ($jobName in $jobsToOrder) {
        if ($DependencyMap.ContainsKey($jobName)) {
            foreach ($prerequisite in $DependencyMap[$jobName]) {
                if ($jobsToOrder -contains $prerequisite) { # Ensure we only build the graph with relevant jobs
                    $adj[$prerequisite] += $jobName
                    $inDegree[$jobName]++
                }
            }
        }
    }
    
    $queueForSorting = New-Object System.Collections.Queue
    foreach ($jobName in $jobsToOrder) {
        if ($inDegree[$jobName] -eq 0) {
            $queueForSorting.Enqueue($jobName)
        }
    }
    
    $orderedJobsList = [System.Collections.Generic.List[string]]::new()
    while ($queueForSorting.Count -gt 0) {
        $u = $queueForSorting.Dequeue()
        $orderedJobsList.Add($u)
        
        if ($adj.ContainsKey($u)) {
            foreach ($v in $adj[$u]) {
                $inDegree[$v]--
                if ($inDegree[$v] -eq 0) {
                    $queueForSorting.Enqueue($v)
                }
            }
        }
    }

    if ($orderedJobsList.Count -ne $jobsToOrder.Count) {
        $errorMessage = "Could not build a valid execution order. This typically indicates a circular dependency exists in the graph, which should have been caught by the validator."
        $jobsInCycle = $jobsToOrder | Where-Object { $orderedJobsList -notcontains $_ }
        if ($jobsInCycle.Count -gt 0) {
            $errorMessage += " Potential jobs involved in cycle: $($jobsInCycle -join ', ')."
        }
        & $LocalWriteLog -Message "ExecutionPlanner: $errorMessage" -Level "ERROR"
        return @{ Success = $false; OrderedJobs = @(); ErrorMessage = $errorMessage }
    }
    
    & $LocalWriteLog -Message "ExecutionPlanner: Successfully built execution order with $($orderedJobsList.Count) job(s)." -Level "DEBUG"
    return @{ Success = $true; OrderedJobs = $orderedJobsList; ErrorMessage = $null }
}
#endregion

Export-ModuleMember -Function Get-JobExecutionOrder
