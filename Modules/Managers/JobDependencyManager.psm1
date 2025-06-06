# Modules\Managers\JobDependencyManager.psm1
<#
.SYNOPSIS
    Manages job dependencies and determines the correct execution order for PoSh-Backup jobs.
.DESCRIPTION
    This module is responsible for analyzing job dependencies defined in the PoSh-Backup
    configuration. It builds a valid execution order for a given list of jobs,
    detects circular dependencies, and validates that all specified dependencies exist.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        0.3.4 # Renamed Test-JobDependencies to Test-PoShBackupJobDependencyGraph.
    DateCreated:    28-May-2025
    LastModified:   28-May-2025
    Purpose:        To handle backup job dependency logic and scheduling.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "JobDependencyManager.psm1 FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw # Critical dependency
}
#endregion

#region --- Internal Helper Functions ---

function Test-CycleInJobRecursiveInternal ($currentJob, $currentPathMessage, $dependencyListForValidation, $visitingHashtable, $processedHashtable, $ValidationMessagesListRef) {
    $visitingHashtable[$currentJob] = $true
    $currentPathMessage += "$currentJob"

    if ($dependencyListForValidation.ContainsKey($currentJob)) {
        foreach ($prerequisite in $dependencyListForValidation[$currentJob]) {
            if (-not $dependencyListForValidation.ContainsKey($prerequisite)) {
                continue
            }
            if ($visitingHashtable.ContainsKey($prerequisite)) {
                $ValidationMessagesListRef.Value.Add("Circular Dependency Detected: $($currentPathMessage) -> $prerequisite (forms a cycle).")
                return $true # Cycle found
            }
            if (-not $processedHashtable.ContainsKey($prerequisite)) {
                if (Test-CycleInJobRecursiveInternal -currentJob $prerequisite -currentPathMessage "$($currentPathMessage) -> " -dependencyListForValidation $dependencyListForValidation -visitingHashtable $visitingHashtable -processedHashtable $processedHashtable -ValidationMessagesListRef $ValidationMessagesListRef) {
                    return $true # Cycle found deeper
                }
            }
        }
    }
    $null = $visitingHashtable.Remove($currentJob)
    $processedHashtable[$currentJob] = $true
    return $false # No cycle from this job
}

#endregion

#region --- Exported Functions ---

function Test-PoShBackupJobDependencyGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$AllBackupLocations, 
        [Parameter(Mandatory = $true)]
        [ref]$ValidationMessagesListRef, 
        [Parameter(Mandatory = $false)]
        [scriptblock]$Logger # PSScriptAnalyzer Suppress PSUseDeclaredVarsMoreThanAssignments - Logger is used via $LocalWriteLog helper.
    )

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO")
        if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) {
            & $Logger -Message $Message -Level $Level
        }
    }
    & $LocalWriteLog -Message "JobDependencyManager/Test-PoShBackupJobDependencyGraph: Initializing validation." -Level "DEBUG"

    if ($null -eq $AllBackupLocations -or $AllBackupLocations.Count -eq 0) {
        & $LocalWriteLog -Message "JobDependencyManager/Test-PoShBackupJobDependencyGraph: No backup locations defined. Skipping dependency validation." -Level "DEBUG"
        return
    }

    $jobNamesArray = @($AllBackupLocations.Keys) # Use PowerShell array
    $dependencyListForValidation = @{} 

    foreach ($jobName in $jobNamesArray) {
        $jobConf = $AllBackupLocations[$jobName]
        $dependencyListForValidation[$jobName] = @() # Use PowerShell array

        if ($jobConf.ContainsKey('DependsOnJobs') -and $null -ne $jobConf.DependsOnJobs -and $jobConf.DependsOnJobs -is [array]) {
            foreach ($depJobNameRaw in $jobConf.DependsOnJobs) {
                if (-not ([string]::IsNullOrWhiteSpace($depJobNameRaw))) {
                    $depJobName = $depJobNameRaw.Trim()
                    $dependencyListForValidation[$jobName] += $depJobName 

                    if ($jobNamesArray -notcontains $depJobName) {
                        # Check against PowerShell array
                        $ValidationMessagesListRef.Value.Add("Job Dependency Error: Job '$jobName' has a dependency on a non-existent job '$depJobName'.")
                    }
                    elseif ($AllBackupLocations.ContainsKey($depJobName)) {
                        $depJobConf = $AllBackupLocations[$depJobName]
                        $isDepEnabled = Get-ConfigValue -ConfigObject $depJobConf -Key 'Enabled' -DefaultValue $true
                        if (-not $isDepEnabled) {
                            $ValidationMessagesListRef.Value.Add("Job Dependency Error: Job '$jobName' has a dependency on job '$depJobName', which is disabled (Enabled = `$false).")
                        }
                    }
                }
                Else {
                    $ValidationMessagesListRef.Value.Add("Job Dependency Error: Job '$jobName' has an empty or whitespace dependency defined in 'DependsOnJobs'.")
                }
            }
        }
    }

    $visiting = @{} # Use Hashtable as a set
    $processed = @{} # Use Hashtable as a set

    foreach ($jobNameKey in $jobNamesArray) {
        if (-not $processed.ContainsKey($jobNameKey)) {
            if (Test-CycleInJobRecursiveInternal -currentJob $jobNameKey -currentPathMessage "" -dependencyListForValidation $dependencyListForValidation -visitingHashtable $visiting -processedHashtable $processed -ValidationMessagesListRef $ValidationMessagesListRef) {
                # Cycle was found
            }
        }
    }
    & $LocalWriteLog -Message "JobDependencyManager/Test-PoShBackupJobDependencyGraph: Dependency validation complete." -Level "DEBUG"

    if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) {
        if ($ValidationMessagesListRef.Value.Count -eq 0) {
            & $LocalWriteLog -Message "JobDependencyManager/Test-PoShBackupJobDependencyGraph: Validation passed with no errors found." -Level "DEBUG"
        }
        else {
            & $LocalWriteLog -Message "JobDependencyManager/Test-PoShBackupJobDependencyGraph: Validation finished with $($ValidationMessagesListRef.Value.Count) messages." -Level "DEBUG"
        }
    }
}

function Build-JobExecutionOrder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$InitialJobsToConsider, # Keep input type for compatibility
        [Parameter(Mandatory = $true)]
        [hashtable]$AllBackupLocations, 
        [Parameter(Mandatory = $false)]
        [scriptblock]$Logger # PSScriptAnalyzer Suppress PSUseDeclaredVarsMoreThanAssignments - Logger is used via $LocalWriteLog helper.
    )

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO")
        if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) {
            & $Logger -Message $Message -Level $Level
        }
    }
    & $LocalWriteLog -Message "JobDependencyManager/Build-JobExecutionOrder: Initializing." -Level "DEBUG"

    $orderedJobsArray = @() # Use PowerShell array
    $processingError = $null
    
    if ($null -eq $AllBackupLocations -or $AllBackupLocations.Count -eq 0) {
        & $LocalWriteLog -Message "JobDependencyManager/Build-JobExecutionOrder: No backup locations defined. Returning empty order." -Level "DEBUG"
        return @{ OrderedJobs = @(); ErrorMessage = "No backup locations defined in configuration."; Success = $false }
    }
    if ($InitialJobsToConsider.Count -eq 0) {
        & $LocalWriteLog -Message "JobDependencyManager/Build-JobExecutionOrder: Initial list of jobs to consider is empty. Returning empty order." -Level "DEBUG"
        return @{ OrderedJobs = @(); ErrorMessage = $null; Success = $true } 
    }

    $relevantJobsSet = @{} # Use Hashtable as a set for keys
    $queueForDependencyExpansion = New-Object System.Collections.Queue # Standard Queue

    $InitialJobsToConsider | ForEach-Object {
        $jobToConsider = $_
        if (-not [string]::IsNullOrWhiteSpace($jobToConsider) -and $AllBackupLocations.ContainsKey($jobToConsider)) {
            # --- Start of filtering logic
            $jobConfForEnableCheck = $AllBackupLocations[$jobToConsider]
            $isJobEnabled = Get-ConfigValue -ConfigObject $jobConfForEnableCheck -Key 'Enabled' -DefaultValue $true
            if (-not $isJobEnabled) {
                & $LocalWriteLog -Message "JobDependencyManager/Build-JobExecutionOrder: Initial job '$jobToConsider' is disabled. Skipping it and its dependencies for ordering." -Level "INFO"
                return # Skips this job in ForEach-Object
            }
            # --- End of filtering logic

            if (-not $relevantJobsSet.ContainsKey($jobToConsider)) {
                $relevantJobsSet[$jobToConsider] = $true
                $queueForDependencyExpansion.Enqueue($jobToConsider) 
            }
        }
        else {
            & $LocalWriteLog -Message "JobDependencyManager/Build-JobExecutionOrder: Initial job '$jobToConsider' not found in AllBackupLocations or is invalid. Skipping." -Level "WARNING"
        }
    }

    while ($queueForDependencyExpansion.Count -gt 0) {
        $currentJob = $queueForDependencyExpansion.Dequeue()
        $jobConf = $AllBackupLocations[$currentJob]
        if ($jobConf.ContainsKey('DependsOnJobs') -and $null -ne $jobConf.DependsOnJobs -and $jobConf.DependsOnJobs -is [array]) {
            foreach ($dependencyNameRaw in $jobConf.DependsOnJobs) {
                if (-not [string]::IsNullOrWhiteSpace($dependencyNameRaw)) {
                    $dependencyName = $dependencyNameRaw.Trim()
                    if ($AllBackupLocations.ContainsKey($dependencyName)) {
                        if (-not $relevantJobsSet.ContainsKey($dependencyName)) {
                            $relevantJobsSet[$dependencyName] = $true
                            $queueForDependencyExpansion.Enqueue($dependencyName)
                        }
                    }
                    else {
                        $processingError = "Job '$currentJob' depends on non-existent job '$dependencyName'."
                        & $LocalWriteLog -Message "JobDependencyManager/Build-JobExecutionOrder: $processingError" -Level "ERROR"
                        return @{ OrderedJobs = @(); ErrorMessage = $processingError; Success = $false } 
                    }
                }
            }
        }
    }
    
    $relevantJobNamesArray = @($relevantJobsSet.Keys)
    & $LocalWriteLog -Message "JobDependencyManager/Build-JobExecutionOrder: Relevant jobs for ordering: $($relevantJobNamesArray -join ', ')" -Level "DEBUG"

    $adj = @{} 
    $inDegree = @{} 

    foreach ($jobName in $relevantJobNamesArray) { 
        $adj[$jobName] = @()
        $inDegree[$jobName] = 0
    }

    foreach ($jobName_item_degree in $relevantJobNamesArray) { 
        $jobConf = $AllBackupLocations[$jobName_item_degree]
        if ($jobConf.ContainsKey('DependsOnJobs') -and $null -ne $jobConf.DependsOnJobs -and $jobConf.DependsOnJobs -is [array]) {
            foreach ($prerequisiteNameRaw in $jobConf.DependsOnJobs) {
                if (-not [string]::IsNullOrWhiteSpace($prerequisiteNameRaw)) {
                    $prerequisiteName = $prerequisiteNameRaw.Trim()
                    if ($relevantJobsSet.ContainsKey($prerequisiteName)) { 
                        $adj[$prerequisiteName] += $jobName_item_degree
                        $inDegree[$jobName_item_degree]++
                    }
                }
            }
        }
    }

    $queue = New-Object System.Collections.Queue
    foreach ($jobName_item_queue in $relevantJobNamesArray) { 
        if ($inDegree[$jobName_item_queue] -eq 0) {
            $queue.Enqueue($jobName_item_queue)
        }
    }

    while ($queue.Count -gt 0) {
        $u = $queue.Dequeue()
        $orderedJobsArray += $u

        if ($adj.ContainsKey($u)) {
            foreach ($v in $adj[$u]) {
                if ($relevantJobsSet.ContainsKey($v)) { 
                    $inDegree[$v]--
                    if ($inDegree[$v] -eq 0) {
                        $queue.Enqueue($v)
                    }
                }
            }
        }
    }

    if ($orderedJobsArray.Count -ne $relevantJobNamesArray.Count) {
        $processingError = "Circular dependency detected among relevant jobs. Test-PoShBackupJobDependencyGraph should have caught this. Ordered: $($orderedJobsArray.Count), Relevant: $($relevantJobNamesArray.Count)."
        $jobsInCycle = $relevantJobNamesArray | Where-Object { $orderedJobsArray -notcontains $_ }
        if ($jobsInCycle.Count -gt 0) {
            $processingError += " Potential jobs involved in cycle: $($jobsInCycle -join ', ')."
        }
        & $LocalWriteLog -Message "JobDependencyManager/Build-JobExecutionOrder: $processingError" -Level "ERROR"
        return @{ OrderedJobs = @(); ErrorMessage = $processingError; Success = $false } 
    }
    
    # Convert back to List[string] for the return type if needed by the caller, or change caller to expect array
    $finalOrderedJobsList = New-Object System.Collections.Generic.List[string]
    $orderedJobsArray | ForEach-Object { $finalOrderedJobsList.Add($_) }

    & $LocalWriteLog -Message "JobDependencyManager/Build-JobExecutionOrder: Successfully built execution order." -Level "DEBUG"

    if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger -and $null -eq $processingError) {
        & $LocalWriteLog -Message "JobDependencyManager/Build-JobExecutionOrder: Successfully built execution order with $($orderedJobsArray.Count) jobs." -Level "DEBUG"
    }

    return @{
        OrderedJobs  = $finalOrderedJobsList # Returning List[string] as originally intended for output
        ErrorMessage = $null 
        Success      = $true
    }
}

#endregion

Export-ModuleMember -Function Test-PoShBackupJobDependencyGraph, Build-JobExecutionOrder
