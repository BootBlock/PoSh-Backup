# Modules\Managers\JobDependencyManager.psm1
<#
.SYNOPSIS
    Manages job dependencies and determines the correct execution order for PoSh-Backup jobs.
    This module now acts as a facade, orchestrating calls to specialised sub-modules.
.DESCRIPTION
    This module is responsible for analyzing job dependencies defined in the PoSh-Backup
    configuration. It acts as a facade, calling upon several specialized sub-modules
    located in '.\JobDependencyManager\':
    - GraphBuilder.psm1: For creating a map of the dependency graph.
    - GraphValidator.psm1: For validating the integrity of the dependency graph.
    - ExecutionPlanner.psm1: For calculating the correct job execution order.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0 # Refactored into a facade with sub-modules.
    DateCreated:    28-May-2025
    LastModified:   01-Jul-2025
    Purpose:        To handle backup job dependency logic and scheduling.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers
$jobDependencySubModulePath = Join-Path -Path $PSScriptRoot -ChildPath "JobDependencyManager"
try {
    # Import the new sub-modules
    Import-Module -Name (Join-Path $jobDependencySubModulePath "GraphBuilder.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $jobDependencySubModulePath "GraphValidator.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $jobDependencySubModulePath "ExecutionPlanner.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "JobDependencyManager.psm1 (Facade) FATAL: Could not import a required sub-module. Error: $($_.Exception.Message)"
    throw
}
#endregion

# This remains a simple facade, directly re-exporting the functions from the sub-modules.
# If we needed to add orchestration logic (e.g., always building the map before validating),
# we would create wrapper functions here. For now, this is clean and sufficient.
Export-ModuleMember -Function Get-PoShBackupJobDependencyMap, Test-PoShBackupJobDependencyGraph, Get-JobExecutionOrder
