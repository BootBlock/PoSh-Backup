# Modules\Core\JobOrchestrator.psm1
<#
.SYNOPSIS
    Orchestrates the processing of a list of PoSh-Backup jobs or a backup set.
.DESCRIPTION
    This module contains the primary loop for iterating through backup jobs determined
    by the main PoSh-Backup script. For each job, it:
    - Sets up per-job logging context.
    - Retrieves the effective job configuration.
    - Invokes the core backup operation for the job (via Operations.psm1).
    - Manages the overall status of a set if multiple jobs are run.
    - Triggers report generation for each job.
    - Implements the "stop set on error" policy.
    - Applies log file retention policy for the completed job.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.2 # Added log retention logic.
    DateCreated:    25-May-2025
    LastModified:   27-May-2025
    Purpose:        To centralise the main job/set processing loop from PoSh-Backup.ps1.
    Prerequisites:  PowerShell 5.1+.
                    Depends on ConfigManager.psm1, Operations.psm1, Reporting.psm1, and Utils.psm1.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Core\
try {
    # Explicitly import the Utils.psm1 facade to ensure its functions are available
    # to this module and potentially to maintain its loaded state for the calling scope.
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop

    # Other direct dependencies could be listed here if JobOrchestrator called them directly.
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "..\Managers\LogManager.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "JobOrchestrator.psm1 FATAL: Could not import required Utils.psm1 module. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Invoke-PoShBackupRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$JobsToProcess,
        [Parameter(Mandatory = $false)]
        [string]$CurrentSetName, # Null if not running a set
        [Parameter(Mandatory = $true)]
        [bool]$StopSetOnErrorPolicy, # True if set should stop on job error
        [Parameter(Mandatory = $false)]
        [hashtable]$SetSpecificPostRunAction, # Null or hashtable
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,
        [Parameter(Mandatory = $true)]
        [string]$PSScriptRootForPaths,
        [Parameter(Mandatory = $true)]
        [string]$ActualConfigFile,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet,
        [Parameter(Mandatory = $true)]
        [hashtable]$CliOverrideSettings 
    )

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    & $LocalWriteLog -Message "JobOrchestrator/Invoke-PoShBackupRun: Initializing run." -Level "DEBUG"

    $overallSetStatus = "SUCCESS" 
    $jobSpecificPostRunActionForSingleJob = $null 

    foreach ($currentJobName in $JobsToProcess) {
        & $LocalWriteLog -Message "`n================================================================================" -Level "NONE"
        & $LocalWriteLog -Message "Processing Job: $currentJobName" -Level "HEADING"
        & $LocalWriteLog -Message "================================================================================" -Level "NONE"

        $Global:GlobalJobLogEntries = [System.Collections.Generic.List[object]]::new()
        $Global:GlobalJobHookScriptData = [System.Collections.Generic.List[object]]::new()

        $currentJobReportData = [ordered]@{ JobName = $currentJobName }
        $currentJobReportData['ScriptStartTime'] = Get-Date 

        $Global:GlobalLogFile = $null 
        if ($Global:GlobalEnableFileLogging) {
            $logDate = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
            $safeJobNameForFile = $currentJobName -replace '[^a-zA-Z0-9_-]', '_' 
            if (-not [string]::IsNullOrWhiteSpace($Global:GlobalLogDirectory) -and (Test-Path -LiteralPath $Global:GlobalLogDirectory -PathType Container)) {
                 $Global:GlobalLogFile = Join-Path -Path $Global:GlobalLogDirectory -ChildPath "$($safeJobNameForFile)_$($logDate).log"
                 & $LocalWriteLog -Message "[INFO] Logging for job '$currentJobName' to file: $($Global:GlobalLogFile)" -Level "INFO"
            } else {
                & $LocalWriteLog -Message "[WARNING] Log directory is not valid. File logging for job '$currentJobName' will be skipped." -Level "WARNING"
            }
        }

        $jobConfigFromMainConfig = $Configuration.BackupLocations[$currentJobName] 
        $jobSucceeded = $false 
        $effectiveJobConfigForThisJob = $null 
        $currentJobIndividualStatus = "FAILURE" 

        try {
            $effectiveConfigParams = @{
                JobConfig            = $jobConfigFromMainConfig 
                GlobalConfig         = $Configuration 
                CliOverrides         = $CliOverrideSettings 
                JobReportDataRef     = ([ref]$currentJobReportData) 
                Logger               = $Logger
            }
            $effectiveJobConfigForThisJob = Get-PoShBackupJobEffectiveConfiguration @effectiveConfigParams
            
            $invokePoShBackupJobParams = @{
                JobName              = $currentJobName
                JobConfig            = $effectiveJobConfigForThisJob 
                GlobalConfig         = $Configuration 
                PSScriptRootForPaths = $PSScriptRootForPaths 
                ActualConfigFile     = $ActualConfigFile
                JobReportDataRef     = ([ref]$currentJobReportData) 
                IsSimulateMode       = $IsSimulateMode 
                Logger               = $Logger 
                PSCmdlet             = $PSCmdlet 
            }
            $jobResult = Invoke-PoShBackupJob @invokePoShBackupJobParams
            $currentJobIndividualStatus = $jobResult.Status 
            $jobSucceeded = ($currentJobIndividualStatus -eq "SUCCESS" -or $currentJobIndividualStatus -eq "SIMULATED_COMPLETE")

            if (-not $CurrentSetName) { 
                $jobSpecificPostRunActionForSingleJob = $effectiveJobConfigForThisJob.PostRunAction
            }

        } catch {
            $currentJobIndividualStatus = "FAILURE" 
            & $LocalWriteLog -Message "[FATAL] JobOrchestrator: Unhandled exception during processing of job '$currentJobName': $($_.Exception.ToString())" -Level "ERROR"
            $currentJobReportData['ErrorMessage'] = $_.Exception.ToString()
        }

        $currentJobReportData['LogEntries']  = if ($null -ne $Global:GlobalJobLogEntries) { $Global:GlobalJobLogEntries } else { [System.Collections.Generic.List[object]]::new() }
        $currentJobReportData['HookScripts'] = if ($null -ne $Global:GlobalJobHookScriptData) { $Global:GlobalJobHookScriptData } else { [System.Collections.Generic.List[object]]::new() }

        if (-not ($currentJobReportData.PSObject.Properties.Name -contains 'OverallStatus')) {
            $currentJobReportData.OverallStatus = $currentJobIndividualStatus
        }
        $currentJobReportData['ScriptEndTime'] = Get-Date
        if (($currentJobReportData.PSObject.Properties.Name -contains 'ScriptStartTime') -and `
            ($null -ne $currentJobReportData.ScriptStartTime) -and `
            ($null -ne $currentJobReportData.ScriptEndTime)) {
            $currentJobReportData['TotalDuration'] = $currentJobReportData.ScriptEndTime - $currentJobReportData.ScriptStartTime
            $currentJobReportData['TotalDurationSeconds'] = ($currentJobReportData.ScriptEndTime - $currentJobReportData.ScriptStartTime).TotalSeconds
        } else {
            $currentJobReportData['TotalDuration'] = "N/A (Timing data incomplete)"
            $currentJobReportData['TotalDurationSeconds'] = 0
        }
        if (($currentJobReportData.PSObject.Properties.Name -contains 'OverallStatus') -and $currentJobReportData.OverallStatus -eq "FAILURE" -and -not ($currentJobReportData.PSObject.Properties.Name -contains 'ErrorMessage')) {
            $currentJobReportData['ErrorMessage'] = "Job failed; specific error caught by main loop or not recorded by Invoke-PoShBackupJob."
        }

        if ($currentJobIndividualStatus -eq "FAILURE") { $overallSetStatus = "FAILURE" }
        elseif ($currentJobIndividualStatus -eq "WARNINGS" -and $overallSetStatus -ne "FAILURE") { $overallSetStatus = "WARNINGS" }

        $displayStatusForLog = $currentJobReportData.OverallStatus
        & $LocalWriteLog -Message "Finished processing job '$currentJobName'. Status: $displayStatusForLog" -Level $displayStatusForLog

        $_jobSpecificReportTypesSetting = Get-ConfigValue -ConfigObject $jobConfigFromMainConfig -Key 'ReportGeneratorType' -DefaultValue (Get-ConfigValue -ConfigObject $Configuration -Key 'ReportGeneratorType' -DefaultValue "HTML")
        $_jobReportGeneratorTypesList = [System.Collections.Generic.List[string]]::new()
        if ($_jobSpecificReportTypesSetting -is [array]) {
            $_jobSpecificReportTypesSetting | ForEach-Object { $_jobReportGeneratorTypesList.Add($_.ToString().ToUpperInvariant()) }
        } else {
            $_jobReportGeneratorTypesList.Add($_jobSpecificReportTypesSetting.ToString().ToUpperInvariant())
        }
        if ($CliOverrideSettings.GenerateHtmlReport -eq $true) { 
            if ("HTML" -notin $_jobReportGeneratorTypesList) { $_jobReportGeneratorTypesList.Add("HTML") }
            if ($_jobReportGeneratorTypesList.Contains("NONE") -and $_jobReportGeneratorTypesList.Count -gt 1) { $_jobReportGeneratorTypesList.Remove("NONE") } 
            elseif ($_jobReportGeneratorTypesList.Count -eq 1 -and $_jobReportGeneratorTypesList[0] -eq "NONE") { $_jobReportGeneratorTypesList = [System.Collections.Generic.List[string]]@("HTML") }
        }
        $_finalJobReportTypes = $_jobReportGeneratorTypesList | Select-Object -Unique
        $_activeReportTypesForJob = $_finalJobReportTypes | Where-Object { $_ -ne "NONE" }

        if ($_activeReportTypesForJob.Count -gt 0) {
            $defaultJobReportsDir = Join-Path -Path $PSScriptRootForPaths -ChildPath "Reports" 
            if (-not (Test-Path -LiteralPath $defaultJobReportsDir -PathType Container)) {
                & $LocalWriteLog -Message "[INFO] Default reports directory '$defaultJobReportsDir' does not exist. Attempting to create..." -Level "INFO"
                try {
                    New-Item -Path $defaultJobReportsDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                    & $LocalWriteLog -Message "  - Default reports directory '$defaultJobReportsDir' created successfully." -Level "SUCCESS"
                } catch {
                    & $LocalWriteLog -Message "[WARNING] Failed to create default reports directory '$defaultJobReportsDir'. Report generation may fail. Error: $($_.Exception.Message)" -Level "WARNING"
                }
            }
            Invoke-ReportGenerator -ReportDirectory $defaultJobReportsDir `
                                   -JobName $currentJobName `
                                   -ReportData $currentJobReportData `
                                   -GlobalConfig $Configuration `
                                   -JobConfig $jobConfigFromMainConfig `
                                   -Logger $Logger 
        }

        # --- Apply Log Retention for this job ---
        if ($Global:GlobalEnableFileLogging -and (-not [string]::IsNullOrWhiteSpace($Global:GlobalLogDirectory))) {
            $finalLogRetentionCountForJob = $null
            
            # Hierarchy: CLI > Set > Job (from effective config)
            if ($null -ne $CliOverrideSettings.LogRetentionCountCLI) {
                $finalLogRetentionCountForJob = $CliOverrideSettings.LogRetentionCountCLI
                & $LocalWriteLog -Message "[INFO] Log Retention for job '$currentJobName': Using CLI override value: $finalLogRetentionCountForJob." -Level "INFO"
            } elseif ($CurrentSetName -and $Configuration.BackupSets.ContainsKey($CurrentSetName) -and $Configuration.BackupSets[$CurrentSetName].ContainsKey('LogRetentionCount')) {
                $finalLogRetentionCountForJob = $Configuration.BackupSets[$CurrentSetName].LogRetentionCount
                & $LocalWriteLog -Message "[INFO] Log Retention for job '$currentJobName': Using Set-level value ('$CurrentSetName'): $finalLogRetentionCountForJob." -Level "INFO"
            } elseif ($effectiveJobConfigForThisJob.ContainsKey('LogRetentionCount')) {
                $finalLogRetentionCountForJob = $effectiveJobConfigForThisJob.LogRetentionCount
                & $LocalWriteLog -Message "[INFO] Log Retention for job '$currentJobName': Using Job-level value: $finalLogRetentionCountForJob." -Level "INFO"
            }
            # If $finalLogRetentionCountForJob is still $null, Invoke-LogFileRetention will use its internal default or handle it.
            # (Actually, the effective config builder ensures LogRetentionCount is always set, defaulting to global if not job/CLI)

            if ($null -ne $finalLogRetentionCountForJob) {
                Invoke-LogFileRetention -LogDirectory $Global:GlobalLogDirectory `
                                        -JobNamePattern $currentJobName `
                                        -RetentionCount $finalLogRetentionCountForJob `
                                        -Logger $Logger `
                                        -IsSimulateMode:$IsSimulateMode `
                                        -PSCmdletInstance $PSCmdlet
            } else {
                 & $LocalWriteLog -Message "[WARNING] Log Retention for job '$currentJobName': Could not determine a final retention count. Skipping log retention for this job." -Level "WARNING"
            }
        }
        # --- End Log Retention ---

        if ($CurrentSetName -and (-not $jobSucceeded) -and $StopSetOnErrorPolicy) {
            & $LocalWriteLog -Message "[ERROR] Job '$currentJobName' in set '$CurrentSetName' failed (operational status: $currentJobIndividualStatus). Stopping set as 'OnErrorInJob' policy is 'StopSet'." -Level "ERROR"
            break 
        }
    } 

    return @{
        OverallSetStatus                   = $overallSetStatus
        JobSpecificPostRunActionForNonSet = if (-not $CurrentSetName) { $jobSpecificPostRunActionForSingleJob } else { $null }
        SetSpecificPostRunAction           = if ($CurrentSetName) { $SetSpecificPostRunAction } else { $null } 
    }
}

Export-ModuleMember -Function Invoke-PoShBackupRun
