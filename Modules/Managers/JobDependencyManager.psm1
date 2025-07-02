# Modules\Managers\JobDependencyManager.psm1
<#
.SYNOPSIS
    Manages job dependencies and determines the correct execution order for PoSh-Backup jobs.
    This module now acts as a facade, orchestrating calls to specialised sub-modules that
    are loaded on demand.
.DESCRIPTION
    This module is responsible for analyzing job dependencies defined in the PoSh-Backup
    configuration. It acts as a facade, lazy-loading and calling upon several specialized
    sub-modules located in '.\JobDependencyManager\':
    - GraphBuilder.psm1: For creating a map of the dependency graph.
    - GraphValidator.psm1: For validating the integrity of the dependency graph.
    - ExecutionPlanner.psm1: For calculating the correct job execution order.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Refactored to lazy-load sub-modules.
    DateCreated:    28-May-2025
    LastModified:   02-Jul-2025
    Purpose:        To handle backup job dependency logic and scheduling.
    Prerequisites:  PowerShell 5.1+.
#>

# No eager module imports are needed here. They will be lazy-loaded.

function Get-PoShBackupJobDependencyMap {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$AllBackupLocations
    )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "JobDependencyManager\GraphBuilder.psm1") -Force -ErrorAction Stop
        return Get-PoShBackupJobDependencyMap @PSBoundParameters
    }
    catch {
        $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Managers\JobDependencyManager\GraphBuilder.psm1' exists and is not corrupted."
        Write-Error "JobDependencyManager (Facade): Could not load the GraphBuilder sub-module. Error: $($_.Exception.Message)"
        Write-Host $advice -ForegroundColor DarkCyan
        throw
    }
}

function Test-PoShBackupJobDependencyGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$AllBackupLocations,
        [Parameter(Mandatory = $true)]
        [hashtable]$DependencyMap,
        [Parameter(Mandatory = $true)]
        [ref]$ValidationMessagesListRef,
        [Parameter(Mandatory = $false)]
        [scriptblock]$Logger
    )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "JobDependencyManager\GraphValidator.psm1") -Force -ErrorAction Stop
        Test-PoShBackupJobDependencyGraph @PSBoundParameters
    }
    catch {
        $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Managers\JobDependencyManager\GraphValidator.psm1' exists and is not corrupted."
        & $Logger -Message "[FATAL] JobDependencyManager (Facade): Could not load the GraphValidator sub-module. Error: $($_.Exception.Message)" -Level "ERROR"
        & $Logger -Message $advice -Level "ADVICE"
        throw
    }
}

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
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "JobDependencyManager\ExecutionPlanner.psm1") -Force -ErrorAction Stop
        return Get-JobExecutionOrder @PSBoundParameters
    }
    catch {
        $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Managers\JobDependencyManager\ExecutionPlanner.psm1' exists and is not corrupted."
        & $Logger -Message "[FATAL] JobDependencyManager (Facade): Could not load the ExecutionPlanner sub-module. Error: $($_.Exception.Message)" -Level "ERROR"
        & $Logger -Message $advice -Level "ADVICE"
        throw
    }
}

Export-ModuleMember -Function Get-PoShBackupJobDependencyMap, Test-PoShBackupJobDependencyGraph, Get-JobExecutionOrder
