# Modules\Core\JobOrchestrator.psm1
<#
.SYNOPSIS
    Orchestrates the processing of a list of PoSh-Backup jobs or a backup set,
    respecting job dependencies and their success status.
.DESCRIPTION
    This module contains the primary loop for iterating through backup jobs.
    It has been refactored into a high-level facade that calls specialised sub-modules
    to handle the details of the job execution lifecycle.

    For each job in the ordered list, it:
    1.  Calls 'Test-PoShBackupJobPreExecution' to check dependencies and other readiness conditions.
    2.  If the check passes, it calls 'Invoke-PoShBackupJob' to perform the actual backup operation.
    3.  Updates the success/failure state of the job for subsequent dependency checks.
    4.  Calls 'Invoke-PoShBackupPostJobProcessing' to handle reports, notifications, and log retention.
    5.  Manages set-level policies like 'DelayBetweenJobsSeconds' and 'StopSetOnErrorPolicy'.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.1.0 # Added explicit imports for lazy loading.
    DateCreated:    25-May-2025
    LastModified:   02-Jul-2025
    Purpose:        To centralise the main job/set processing loop from PoSh-Backup.ps1.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Core\
$jobOrchestratorSubModulePath = Join-Path -Path $PSScriptRoot -ChildPath "JobOrchestrator"
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "ConfigManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Operations.psm1") -Force -ErrorAction Stop
    # Import the new sub-modules
    Import-Module -Name (Join-Path -Path $jobOrchestratorSubModulePath -ChildPath "PreExecutionChecker.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $jobOrchestratorSubModulePath -ChildPath "PostJobProcessor.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "JobOrchestrator.psm1 FATAL: Could not import required dependent modules. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Invoke-PoShBackupRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$JobsToProcess, # This is the dependency-ordered list
        [Parameter(Mandatory = $false)]
        [string]$CurrentSetName,
        [Parameter(Mandatory = $true)]
        [bool]$StopSetOnErrorPolicy,
        [Parameter(Mandatory = $false)]
        [hashtable]$SetSpecificPostRunAction,
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
        }
        else {
            & $Logger -Message $Message -Level $Level
        }
    }
    & $LocalWriteLog -Message "JobOrchestrator/Invoke-PoShBackupRun: Initialising run. Job order: $($JobsToProcess -join ', ')" -Level "DEBUG"

    $overallSetStatus = "SUCCESS"
    $jobSpecificPostRunActionForSingleJob = $null
    $jobEffectiveSuccessState = @{} # Stores effective success ($true/$false) of each job for dependency checks
    $allJobResultsForSetReport = [System.Collections.Generic.List[hashtable]]::new()

    $totalJobsInRun = $JobsToProcess.Count
    $jobCounter = 0

    $delayBetweenJobs = 0
    if (-not [string]::IsNullOrWhiteSpace($CurrentSetName)) {
        $setConf = $Configuration.BackupSets[$CurrentSetName]
        $delayBetweenJobs = Get-ConfigValue -ConfigObject $setConf -Key 'DelayBetweenJobsSeconds' -DefaultValue 0
        if ($delayBetweenJobs -gt 0) {
            & $LocalWriteLog -Message "  - JobOrchestrator: A delay of $delayBetweenJobs second(s) will be applied between each job in this set." -Level "INFO"
        }
    }

    foreach ($currentJobName in $JobsToProcess) {
        $jobCounter++
        if ($CurrentSetName) {
            Write-Progress -Activity "Processing Backup Set: '$CurrentSetName'" -Status "Job $jobCounter of ${$totalJobsInRun}: '$currentJobName'" -PercentComplete (($jobCounter / $totalJobsInRun) * 100)
        }

        $currentJobReportData = [ordered]@{ JobName = $currentJobName; ScriptStartTime = Get-Date }

        $jobConfigFromMainConfig = $Configuration.BackupLocations[$currentJobName]

        # --- 1. Pre-Execution Checks ---
        $preCheckResult = Test-PoShBackupJobPreExecution -JobName $currentJobName `
            -JobConfig $jobConfigFromMainConfig `
            -JobEffectiveSuccessState $jobEffectiveSuccessState `
            -Logger $Logger

        if ($preCheckResult.Status -eq 'Skip') {
            $currentJobReportData.OverallStatus = "SKIPPED"
            $currentJobReportData.ErrorMessage = $preCheckResult.Reason
            $jobEffectiveSuccessState[$currentJobName] = $false
        }
        else {
            # --- 2. Get Effective Config & Execute Job ---
            Write-ConsoleBanner -NameText "Processing Job:" -ValueText $currentJobName -CenterText -PrependNewLine

            $setConfForEffConfig = if (-not [string]::IsNullOrWhiteSpace($CurrentSetName)) { Get-ConfigValue -ConfigObject $Configuration.BackupSets -Key $CurrentSetName -DefaultValue @{} } else { $null }
            $setSevenZipIncludeListFileForEffConfig = if ($null -ne $setConfForEffConfig) { Get-ConfigValue -ConfigObject $setConfForEffConfig -Key 'SevenZipIncludeListFile' -DefaultValue $null } else { $null }
            $setSevenZipExcludeListFileForEffConfig = if ($null -ne $setConfForEffConfig) { Get-ConfigValue -ConfigObject $setConfForEffConfig -Key 'SevenZipExcludeListFile' -DefaultValue $null } else { $null }

            $effectiveConfigParams = @{
                JobConfig                  = $jobConfigFromMainConfig
                GlobalConfig               = $Configuration
                CliOverrides               = $CliOverrideSettings
                JobReportDataRef           = ([ref]$currentJobReportData)
                Logger                     = $Logger
                SetSevenZipIncludeListFile = $setSevenZipIncludeListFileForEffConfig
                SetSevenZipExcludeListFile = $setSevenZipExcludeListFileForEffConfig
                SetSpecificConfig          = $setConfForEffConfig
            }
            $effectiveJobConfigForThisJob = Get-PoShBackupJobEffectiveConfiguration @effectiveConfigParams

            # Initialise Log File
            if ($Global:GlobalEnableFileLogging) {
                # Logic for log file creation...
            }

            $invokePoShBackupJobParams = @{
                JobName              = $currentJobName
                JobConfig            = $effectiveJobConfigForThisJob
                PSScriptRootForPaths = $PSScriptRootForPaths
                ActualConfigFile     = $ActualConfigFile
                JobReportDataRef     = ([ref]$currentJobReportData)
                IsSimulateMode       = $IsSimulateMode
                Logger               = $Logger
                PSCmdlet             = $PSCmdlet
            }
            $jobResult = Invoke-PoShBackupJob @invokePoShBackupJobParams
            $currentJobReportData.OverallStatus = $jobResult.Status

            # Determine effective success for dependency tracking
            $currentJobEffectiveSuccess = $false
            if ($jobResult.Status -in "SUCCESS", "SIMULATED_COMPLETE") { $currentJobEffectiveSuccess = $true }
            elseif ($jobResult.Status -eq "WARNINGS" -and $effectiveJobConfigForThisJob.TreatSevenZipWarningsAsSuccess) { $currentJobEffectiveSuccess = $true }
            $jobEffectiveSuccessState[$currentJobName] = $currentJobEffectiveSuccess

            # Capture post-run action for single-job runs
            if (-not $CurrentSetName) {
                $jobSpecificPostRunActionForSingleJob = $effectiveJobConfigForThisJob.PostRunAction
            }
        }

        # --- 3. Finalise Report Data and Perform Post-Processing ---
        $currentJobReportData.ScriptEndTime = Get-Date
        $currentJobReportData.TotalDuration = $currentJobReportData.ScriptEndTime - $currentJobReportData.ScriptStartTime
        $currentJobReportData.TotalDurationSeconds = $currentJobReportData.TotalDuration.TotalSeconds

        $postJobParams = @{
            JobName            = $currentJobName
            EffectiveJobConfig = $effectiveJobConfigForThisJob # Can be null if skipped
            GlobalConfig       = $Configuration
            JobReportData      = $currentJobReportData
            IsSimulateMode     = $IsSimulateMode
            Logger             = $Logger
            PSCmdlet           = $PSCmdlet
            CurrentSetName     = $CurrentSetName
        }
        Invoke-PoShBackupPostJobProcessing @postJobParams

        # --- 4. Update Set Status and Handle Set-Level Logic ---
        if ($currentJobReportData.OverallStatus -eq "FAILURE") {
            $overallSetStatus = "FAILURE"
        }
        elseif ($currentJobReportData.OverallStatus -in "WARNINGS", "SKIPPED" -and $overallSetStatus -ne "FAILURE") {
            $overallSetStatus = "WARNINGS"
        }

        if ($null -ne $CurrentSetName) {
            $jobResultForSet = @{
                JobName              = $currentJobName
                Status               = $currentJobReportData.OverallStatus
                Duration             = $currentJobReportData.TotalDuration
                ArchiveSizeFormatted = Get-ConfigValue -ConfigObject $currentJobReportData -Key 'ArchiveSizeFormatted' -DefaultValue "N/A"
                ArchiveSizeBytes     = Get-ConfigValue -ConfigObject $currentJobReportData -Key 'ArchiveSizeBytes' -DefaultValue 0
                ErrorMessage         = Get-ConfigValue -ConfigObject $currentJobReportData -Key 'ErrorMessage' -DefaultValue $null
            }
            $allJobResultsForSetReport.Add($jobResultForSet)
        }

        # Check if we should stop the whole set
        if ($CurrentSetName -and $StopSetOnErrorPolicy -and ($jobEffectiveSuccessState[$currentJobName] -eq $false)) {
            & $LocalWriteLog -Message "[ERROR] Job '$currentJobName' in set '$CurrentSetName' did not complete successfully. Stopping set as 'OnErrorInJob' policy is 'StopSet'." -Level "ERROR"
            break
        }

        # Pause between jobs if configured
        if (($jobCounter -lt $totalJobsInRun) -and ($delayBetweenJobs -gt 0)) {
            & $LocalWriteLog -Message "`n[INFO] Pausing for $delayBetweenJobs second(s) before starting the next job..." -Level "INFO"
            Start-Sleep -Seconds $delayBetweenJobs
        }
    }

    if ($CurrentSetName) { Write-Progress -Activity "Processing Backup Set: '$CurrentSetName'" -Completed }

    return @{
        OverallSetStatus                  = $overallSetStatus
        JobSpecificPostRunActionForNonSet = if (-not $CurrentSetName) { $jobSpecificPostRunActionForSingleJob } else { $null }
        SetSpecificPostRunAction          = if ($CurrentSetName) { $SetSpecificPostRunAction } else { $null }
        AllJobResultsForSetReport         = $allJobResultsForSetReport
    }
}

Export-ModuleMember -Function Invoke-PoShBackupRun
