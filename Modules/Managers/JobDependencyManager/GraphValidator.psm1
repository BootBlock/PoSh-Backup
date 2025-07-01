# Modules\Managers\JobDependencyManager\GraphValidator.psm1
<#
.SYNOPSIS
    A sub-module for the JobDependencyManager facade. Validates the integrity of the job dependency graph.
.DESCRIPTION
    This module provides the 'Test-PoShBackupJobDependencyGraph' function, which is responsible for
    analysing the dependency relationships between all configured backup jobs. It checks for two
    primary types of errors:
    1.  Dependencies on non-existent jobs.
    2.  Circular dependencies (e.g., Job A depends on Job B, and Job B depends on Job A).

    When an error is detected, it provides a clear error message and actionable advice to the user
    on how to correct the configuration.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    01-Jul-2025
    LastModified:   01-Jul-2025
    Purpose:        To isolate the dependency graph validation logic.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers\JobDependencyManager
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "JobDependencyManager\GraphValidator.psm1 FATAL: Could not import Utils.psm1. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- Internal Helper: Recursive Cycle Detection ---
# This function is not exported; it's a helper for the main validator.
function Test-CycleInJobRecursiveInternal {
    param(
        [string]$currentJob,
        [string]$currentPathMessage,
        [hashtable]$dependencyMap,
        [hashtable]$visitingHashtable, # Tracks nodes in the current recursion stack
        [hashtable]$processedHashtable, # Tracks nodes that have been fully processed
        [ref]$ValidationMessagesListRef
    )
    $visitingHashtable[$currentJob] = $true
    $currentPathMessage += "$currentJob"

    if ($dependencyMap.ContainsKey($currentJob)) {
        foreach ($prerequisite in $dependencyMap[$currentJob]) {
            # Skip checking prerequisites that don't exist; that's handled by a different validation step.
            if (-not $dependencyMap.ContainsKey($prerequisite)) {
                continue
            }
            # If we encounter a node that's already in our current recursion path, we have a cycle.
            if ($visitingHashtable.ContainsKey($prerequisite)) {
                $errorMessage = "Circular Dependency Detected: $($currentPathMessage) -> $prerequisite (forms a cycle)."
                $adviceMessage = "ADVICE: To fix this, review the 'DependsOnJobs' setting for the listed jobs and remove the circular reference."
                if (-not ($ValidationMessagesListRef.Value -contains $errorMessage)) { $ValidationMessagesListRef.Value.Add($errorMessage) }
                if (-not ($ValidationMessagesListRef.Value -contains $adviceMessage)) { $ValidationMessagesListRef.Value.Add($adviceMessage) }
                return $true # Cycle found
            }
            # If the node hasn't been fully processed yet, recurse deeper.
            if (-not $processedHashtable.ContainsKey($prerequisite)) {
                if (Test-CycleInJobRecursiveInternal -currentJob $prerequisite -currentPathMessage "$($currentPathMessage) -> " -dependencyMap $dependencyMap -visitingHashtable $visitingHashtable -processedHashtable $processedHashtable -ValidationMessagesListRef $ValidationMessagesListRef) {
                    return $true # Cycle found deeper in the recursion
                }
            }
        }
    }
    # Once all dependencies of the current node are processed, remove it from the current recursion path
    # and add it to the list of fully processed nodes.
    $null = $visitingHashtable.Remove($currentJob)
    $processedHashtable[$currentJob] = $true
    return $false # No cycle found from this path
}
#endregion

#region --- Exported Graph Validation Function ---
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

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO")
        if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) { & $Logger -Message $Message -Level $Level }
    }
    & $LocalWriteLog -Message "JobDependencyManager/GraphValidator: Initialising validation." -Level "DEBUG"

    if ($null -eq $AllBackupLocations -or $AllBackupLocations.Count -eq 0) {
        & $LocalWriteLog -Message "GraphValidator: No backup locations defined. Skipping dependency validation." -Level "DEBUG"
        return
    }

    $allJobNames = @($AllBackupLocations.Keys)

    # 1. Check for dependencies on non-existent or disabled jobs
    foreach ($jobName in $allJobNames) {
        if ($DependencyMap.ContainsKey($jobName)) {
            foreach ($depJobName in $DependencyMap[$jobName]) {
                if ($allJobNames -notcontains $depJobName) {
                    $errorMessage = "Job Dependency Error: Job '$jobName' has a dependency on a non-existent job '$depJobName'."
                    $adviceMessage = "ADVICE: Check for a typo in the 'DependsOnJobs' array for '$jobName', or ensure the job '$depJobName' is defined in 'BackupLocations'."
                    if (-not ($ValidationMessagesListRef.Value -contains $errorMessage)) { $ValidationMessagesListRef.Value.Add($errorMessage) }
                    if (-not ($ValidationMessagesListRef.Value -contains $adviceMessage)) { $ValidationMessagesListRef.Value.Add($adviceMessage) }
                }
                elseif ($AllBackupLocations.ContainsKey($depJobName)) {
                    $depJobConf = $AllBackupLocations[$depJobName]
                    $isDepEnabled = Get-ConfigValue -ConfigObject $depJobConf -Key 'Enabled' -DefaultValue $true
                    if (-not $isDepEnabled) {
                        $warningMessage = "Job Dependency Warning: Job '$jobName' depends on job '$depJobName', which is currently disabled (Enabled = `$false)."
                        $adviceMessage = "ADVICE: This is not a critical error, but job '$jobName' will be skipped unless its dependency '$depJobName' is enabled."
                        if (-not ($ValidationMessagesListRef.Value -contains $warningMessage)) { $ValidationMessagesListRef.Value.Add($warningMessage) }
                        if (-not ($ValidationMessagesListRef.Value -contains $adviceMessage)) { $ValidationMessagesListRef.Value.Add($adviceMessage) }
                    }
                }
            }
        }
    }

    # 2. Check for circular dependencies
    $visiting = @{} # Use Hashtable as a set
    $processed = @{} # Use Hashtable as a set

    foreach ($jobNameKey in $allJobNames) {
        if (-not $processed.ContainsKey($jobNameKey)) {
            $null = Test-CycleInJobRecursiveInternal -currentJob $jobNameKey -currentPathMessage "" -dependencyMap $DependencyMap -visitingHashtable $visiting -processedHashtable $processed -ValidationMessagesListRef $ValidationMessagesListRef
        }
    }

    & $LocalWriteLog -Message "GraphValidator: Dependency validation complete." -Level "DEBUG"
}
#endregion

Export-ModuleMember -Function Test-PoShBackupJobDependencyGraph
