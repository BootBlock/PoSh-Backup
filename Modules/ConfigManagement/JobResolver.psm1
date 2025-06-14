# Modules\ConfigManagement\JobResolver.psm1
<#
.SYNOPSIS
    Determines the list of backup jobs and/or sets to process based on command-line parameters
    and the loaded PoSh-Backup configuration.
.DESCRIPTION
    This module is a sub-component of the main ConfigManager module for PoSh-Backup.
    Its primary function, Get-JobsToProcess, resolves which backup jobs should be run:
    - If -RunSet is specified, it attempts to find the set and returns its defined jobs.
    - If -BackupLocationName is specified (and -RunSet is not), it returns that single job.
    - If neither is specified:
        - If only one job is defined in the configuration, it returns that job.
        - Otherwise (zero or multiple jobs defined), it returns an error indicating the ambiguity.
    - It filters out any jobs that are disabled (`Enabled = $false`) or specified via the -SkipJob CLI parameter.
    It also determines the 'StopSetOnError' policy and 'PostRunAction' for the resolved set.

    It is designed to be called by the main PoSh-Backup script indirectly via the ConfigManager facade.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Added filtering for -SkipJob parameter and refactored logic.
    DateCreated:    24-May-2025
    LastModified:   14-Jun-2025
    Purpose:        To modularise job/set resolution logic from the main ConfigManager module.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Utils.psm1 from the parent 'Modules' directory for Get-ConfigValue.
#>

# Explicitly import dependent Utils.psm1 from the parent 'Modules' directory.
# $PSScriptRoot here is Modules\ConfigManagement.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
} catch {
    Write-Error "JobResolver.psm1 FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}

#region --- Exported Job/Set Resolution Function ---
function Get-JobsToProcess {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Determines the list of backup jobs to process based on command-line parameters and configuration.
    .DESCRIPTION
        This function resolves which backup jobs should be run.
        - If -RunSet is specified, it attempts to find the set and returns its defined jobs.
        - If -BackupLocationName is specified (and -RunSet is not), it returns that single job.
        - If neither is specified:
            - If only one job is defined in the configuration, it returns that job.
            - Otherwise (zero or multiple jobs defined), it returns an error indicating the ambiguity.
        It also determines the 'StopSetOnError' policy and 'PostRunAction' for the resolved set.
    .PARAMETER Config
        The loaded PoSh-Backup configuration hashtable.
    .PARAMETER SpecifiedJobName
        The job name provided via the -BackupLocationName command-line parameter, if any.
    .PARAMETER SpecifiedSetName
        The set name provided via the -RunSet command-line parameter, if any.
    .PARAMETER JobsToSkip
        An array of job names provided via the -SkipJob command-line parameter.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function.
    .OUTPUTS
        System.Collections.Hashtable
        Returns a hashtable with keys: Success, JobsToRun, SetName, StopSetOnErrorPolicy, SetPostRunAction, ErrorMessage.
    #>
    param(
        [hashtable]$Config,
        [string]$SpecifiedJobName,
        [string]$SpecifiedSetName,
        [string[]]$JobsToSkip,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    # PSSA Appeasement: Directly use the Logger parameter once.
    & $Logger -Message "JobResolver/Get-JobsToProcess: Initializing job/set resolution." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        }
        else {
            & $Logger -Message $Message -Level $Level
        }
    }

    $initialJobsToConsider = [System.Collections.Generic.List[string]]::new()
    $setName = $null
    $stopSetOnErrorPolicy = $true # Default for StopSetOnError is "StopSet", hence $true
    $setPostRunAction = $null

    if (-not [string]::IsNullOrWhiteSpace($SpecifiedSetName)) {
        & $LocalWriteLog -Message "`n[INFO] JobResolver: Backup Set specified by user: '$SpecifiedSetName'" -Level "INFO"
        if ($Config.ContainsKey('BackupSets') -and $Config['BackupSets'] -is [hashtable] -and $Config['BackupSets'].ContainsKey($SpecifiedSetName)) {
            $setDefinition = $Config['BackupSets'][$SpecifiedSetName]
            $setName = $SpecifiedSetName
            $jobNamesInSet = @(Get-ConfigValue -ConfigObject $setDefinition -Key 'JobNames' -DefaultValue @())

            if ($jobNamesInSet.Count -gt 0) {
                $jobNamesInSet | ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_)) { $initialJobsToConsider.Add($_.Trim()) } }
                if ($initialJobsToConsider.Count -eq 0) {
                    return @{ Success = $false; ErrorMessage = "JobResolver: Backup Set '$setName' defined but 'JobNames' list is empty/invalid." }
                }
                $stopSetOnErrorPolicy = if (((Get-ConfigValue -ConfigObject $setDefinition -Key 'OnErrorInJob' -DefaultValue "StopSet") -as [string]).ToUpperInvariant() -eq "CONTINUESET") { $false } else { $true }
                if ($setDefinition.ContainsKey('PostRunAction') -and $setDefinition.PostRunAction -is [hashtable]) {
                    $setPostRunAction = $setDefinition.PostRunAction
                    & $LocalWriteLog -Message "  - JobResolver: Set '$setName' has specific PostRunAction settings." -Level "DEBUG"
                }
                & $LocalWriteLog -Message "  - JobResolver: Jobs in set '$setName': $($initialJobsToConsider -join ', ')" -Level "INFO"
                & $LocalWriteLog -Message "  - JobResolver: Policy for set on job failure: $(if($stopSetOnErrorPolicy){'StopSet'}else{'ContinueSet'})" -Level "INFO"
            }
            else {
                return @{ Success = $false; ErrorMessage = "JobResolver: Backup Set '$setName' defined but has no 'JobNames' listed." }
            }
        }
        else {
            $availableSetsMessage = "No Backup Sets defined."
            if ($Config.ContainsKey('BackupSets') -and $Config['BackupSets'] -is [hashtable] -and $Config['BackupSets'].Keys.Count -gt 0) {
                $setNameList = $Config['BackupSets'].Keys | Sort-Object | ForEach-Object { "`"$_`"" }
                $availableSetsMessage = "Available Backup Sets: $($setNameList -join ', ')."
            }
            return @{ Success = $false; ErrorMessage = "JobResolver: Specified Backup Set '$SpecifiedSetName' not found. $availableSetsMessage" }
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($SpecifiedJobName)) {
        if ($Config.ContainsKey('BackupLocations') -and $Config['BackupLocations'] -is [hashtable] -and $Config['BackupLocations'].ContainsKey($SpecifiedJobName)) {
            $initialJobsToConsider.Add($SpecifiedJobName)
            & $LocalWriteLog -Message "`n[INFO] JobResolver: Single Backup Location specified by user: '$SpecifiedJobName'" -Level "INFO"
        }
        else {
            $availableJobsMessage = "No Backup Locations defined."
            if ($Config.ContainsKey('BackupLocations') -and $Config['BackupLocations'] -is [hashtable] -and $Config['BackupLocations'].Keys.Count -gt 0) {
                $jobNameList = $Config['BackupLocations'].Keys | Sort-Object | ForEach-Object { "`"$_`"" }
                $availableJobsMessage = "Available Backup Locations: $($jobNameList -join ', ')."
            }
            return @{ Success = $false; ErrorMessage = "JobResolver: Specified BackupLocationName '$SpecifiedJobName' not found. $availableJobsMessage" }
        }
    }
    else {
        $allDefinedJobs = if ($Config.ContainsKey('BackupLocations') -and $Config['BackupLocations'] -is [hashtable]) { @($Config.BackupLocations.Keys) } else { @() }
        if ($allDefinedJobs.Count -eq 1) {
            $initialJobsToConsider.Add($allDefinedJobs[0])
            & $LocalWriteLog -Message "`n[INFO] JobResolver: No job/set specified. Auto-selected single defined Backup Location: '$($allDefinedJobs[0])'" -Level "INFO"
        }
        elseif ($allDefinedJobs.Count -eq 0) {
            return @{ Success = $false; ErrorMessage = "JobResolver: No job/set specified, and no Backup Locations defined. Nothing to back up." }
        }
        else {
            $errorMessageText = "JobResolver: No job/set specified. Multiple Backup Locations defined. Please choose one:"
            $availableJobsMessage = "`n  Available Backup Locations (-BackupLocationName ""Job Name""):"
            $Config['BackupLocations'].Keys | Sort-Object | ForEach-Object { $availableJobsMessage += "`n    - $_" }
            $availableSetsMessage = "`n  Available Backup Sets (-RunSet ""Set Name""):"
            if ($Config.ContainsKey('BackupSets') -and $Config['BackupSets'] -is [hashtable] -and $Config['BackupSets'].Keys.Count -gt 0) {
                $Config['BackupSets'].Keys | Sort-Object | ForEach-Object { $availableSetsMessage += "`n    - $_" }
            }
            else { $availableSetsMessage += "`n    (None defined)" }
            return @{ Success = $false; ErrorMessage = "$($errorMessageText)$($availableJobsMessage)$($availableSetsMessage)" }
        }
    }

    # --- Filter out disabled jobs ---
    $enabledJobs = [System.Collections.Generic.List[string]]::new()
    foreach ($jobNameCandidate in $initialJobsToConsider) {
        if ($Config.BackupLocations.ContainsKey($jobNameCandidate)) {
            $jobConfForEnableCheck = $Config.BackupLocations[$jobNameCandidate]
            $isJobEnabled = Get-ConfigValue -ConfigObject $jobConfForEnableCheck -Key 'Enabled' -DefaultValue $true
            if ($isJobEnabled) {
                $enabledJobs.Add($jobNameCandidate)
            } else {
                & $LocalWriteLog -Message "  - JobResolver: Job '$jobNameCandidate' is disabled (Enabled = `$false). It will be skipped." -Level "INFO"
            }
        } else {
            & $LocalWriteLog -Message "  - JobResolver: Job '$jobNameCandidate' listed in set '$setName' not found in BackupLocations. Skipping." -Level "WARNING"
        }
    }
    
    # --- Filter out jobs specified by -SkipJob ---
    $finalJobsToRun = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $JobsToSkip -and $JobsToSkip.Count -gt 0) {
        & $LocalWriteLog -Message "`n[INFO] JobResolver: Applying -SkipJob CLI parameter. Jobs to skip: $($JobsToSkip -join ', ')" -Level "INFO"
        $jobsToSkipCleaned = @($JobsToSkip | ForEach-Object { $_.Trim() })

        foreach ($jobToRunCandidate in $enabledJobs) {
            if ($jobToRunCandidate -in $jobsToSkipCleaned) {
                & $LocalWriteLog -Message "  - JobResolver: Job '$jobToRunCandidate' has been SKIPPED from the current run due to the -SkipJob parameter." -Level "WARNING"
            } else {
                $finalJobsToRun.Add($jobToRunCandidate)
            }
        }
    } else {
        $finalJobsToRun.AddRange($enabledJobs)
    }

    if ($finalJobsToRun.Count -eq 0) {
        return @{ Success = $false; ErrorMessage = "JobResolver: No valid, enabled backup jobs determined after parsing parameters/config and applying filters." }
    }

    return @{
        Success              = $true;
        JobsToRun            = $finalJobsToRun;
        SetName              = $setName;
        StopSetOnErrorPolicy = $stopSetOnErrorPolicy;
        SetPostRunAction     = $setPostRunAction
    }
}
#endregion

Export-ModuleMember -Function Get-JobsToProcess
