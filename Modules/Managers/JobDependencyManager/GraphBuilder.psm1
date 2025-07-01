# Modules\Managers\JobDependencyManager\GraphBuilder.psm1
<#
.SYNOPSIS
    A sub-module for the JobDependencyManager facade. Handles creating a map of job dependencies.
.DESCRIPTION
    This module provides the 'Get-PoShBackupJobDependencyMap' function, which reads the
    'BackupLocations' from the configuration and constructs a hashtable representing the
    dependency graph, where each key is a job and its value is an array of its dependencies.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    01-Jul-2025
    LastModified:   01-Jul-2025
    Purpose:        To isolate the dependency graph creation logic.
    Prerequisites:  PowerShell 5.1+.
#>

# No direct module dependencies needed for this specific logic.

function Get-PoShBackupJobDependencyMap {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$AllBackupLocations
    )
    $dependencyMap = @{}
    if ($null -eq $AllBackupLocations) { return $dependencyMap }

    foreach ($jobName in ($AllBackupLocations.Keys | Sort-Object)) {
        $jobConf = $AllBackupLocations[$jobName]
        $dependencies = @()
        if ($jobConf.ContainsKey('DependsOnJobs') -and $null -ne $jobConf.DependsOnJobs -and $jobConf.DependsOnJobs -is [array]) {
            $dependencies = @($jobConf.DependsOnJobs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
        }
        $dependencyMap[$jobName] = $dependencies
    }
    return $dependencyMap
}

Export-ModuleMember -Function Get-PoShBackupJobDependencyMap
