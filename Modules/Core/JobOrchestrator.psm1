# Modules\Core\JobOrchestrator.psm1
<#
.SYNOPSIS
    Orchestrates the processing of a list of PoSh-Backup jobs or a backup set,
    respecting job dependencies and their success status.
.DESCRIPTION
    This module contains the primary loop for iterating through backup jobs determined
    and ordered by the main PoSh-Backup script (considering dependencies via JobDependencyManager).
    For each job in the ordered list, it:
    - Checks if its prerequisite jobs (if any, defined in 'DependsOnJobs') completed successfully.
      A prerequisite is considered successful if its status was 'SUCCESS', 'SIMULATED_COMPLETE',
      or 'WARNINGS' if its 'TreatSevenZipWarningsAsSuccess' setting was true.
    - Skips the current job if any of its dependencies were not met, logging this action.
    - If dependencies are met (or there are none), it sets up per-job logging context.
    - Retrieves the effective job configuration.
    - Invokes the core backup operation for the job (via Operations.psm1).
    - Records the effective success status of the executed job for subsequent dependency checks.
    - Manages the overall status of a set if multiple jobs are run.
    - Triggers report generation for each job (including skipped jobs).
    - Implements the "stop set on error" policy, considering both operational failures
      and jobs skipped due to failed dependencies if the policy is to stop.
    - Applies log file retention policy for the completed job.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.8 # Significantly enriched log file header with detailed context.
    DateCreated:    25-May-2025
    LastModified:   08-Jun-2025
    Purpose:        To centralise the main job/set processing loop from PoSh-Backup.ps1.
    Prerequisites:  PowerShell 5.1+.
                    Depends on ConfigManager.psm1, Operations.psm1, Reporting.psm1, and Utils.psm1.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Core\
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "..\Managers\LogManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "ConfigManager.psm1") -Force -ErrorAction Stop # ADDED
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Operations.psm1") -Force -ErrorAction Stop # Already present but ensure it's here
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "..\Reporting.psm1") -Force -ErrorAction Stop # Already present but ensure it's here
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
    & $LocalWriteLog -Message "JobOrchestrator/Invoke-PoShBackupRun: Initializing run. Job order: $($JobsToProcess -join ', ')" -Level "DEBUG"

    $overallSetStatus = "SUCCESS"
    $jobSpecificPostRunActionForSingleJob = $null
    $jobEffectiveSuccessState = @{} # Stores effective success ($true/$false) of each job for dependency checks

    foreach ($currentJobName in $JobsToProcess) {

        $jobConfigForEnableCheck = $Configuration.BackupLocations[$currentJobName] # Assumes $currentJobName is valid and exists
        $isJobEnabledForExecution = Get-ConfigValue -ConfigObject $jobConfigForEnableCheck -Key 'Enabled' -DefaultValue $true

        if (-not $isJobEnabledForExecution) {
            & $LocalWriteLog -Message "[INFO] JobOrchestrator: Job '$currentJobName' is marked as disabled in its configuration. Skipping execution." -Level "INFO"
            $currentJobReportData = [ordered]@{ JobName = $currentJobName; ScriptStartTime = Get-Date } # Basic report data for skipped job
            $currentJobReportData.OverallStatus = "SKIPPED_DISABLED"
            $currentJobReportData.ErrorMessage = "Job is disabled (Enabled = `$false in configuration)."
            # Populate other essential report fields for consistency
            $currentJobReportData.LogEntries = if ($null -ne $Global:GlobalJobLogEntries) { $Global:GlobalJobLogEntries } else { [System.Collections.Generic.List[object]]::new() }
            $currentJobReportData.HookScripts = if ($null -ne $Global:GlobalJobHookScriptData) { $Global:GlobalJobHookScriptData } else { [System.Collections.Generic.List[object]]::new() }
            $currentJobReportData.ScriptEndTime = Get-Date
            $currentJobReportData.TotalDuration = $currentJobReportData.ScriptEndTime - $currentJobReportData.ScriptStartTime
            $currentJobReportData.TotalDurationSeconds = ($currentJobReportData.ScriptEndTime - $currentJobReportData.ScriptStartTime).TotalSeconds

            # Minimal report generation for disabled/skipped job
            $_jobSpecificReportTypesSettingSkipped = Get-ConfigValue -ConfigObject $jobConfigForEnableCheck -Key 'ReportGeneratorType' -DefaultValue (Get-ConfigValue -ConfigObject $Configuration -Key 'ReportGeneratorType' -DefaultValue "HTML")

            # Minimal report generation for disabled/skipped job
            # $_jobSpecificReportTypesSettingSkipped is already defined above this block
            $_jobReportGeneratorTypesListSkipped = [System.Collections.Generic.List[string]]::new()
            if ($_jobSpecificReportTypesSettingSkipped -is [array]) {
                $_jobSpecificReportTypesSettingSkipped | ForEach-Object { $_jobReportGeneratorTypesListSkipped.Add($_.ToString().ToUpperInvariant()) }
            }
            else {
                $_jobReportGeneratorTypesListSkipped.Add($_jobSpecificReportTypesSettingSkipped.ToString().ToUpperInvariant())
            }
            # Apply CLI override for HTML report if present
            if ($CliOverrideSettings.GenerateHtmlReport -eq $true) { # Assuming CliOverrideSettings is available in this scope
                if ("HTML" -notin $_jobReportGeneratorTypesListSkipped) { $_jobReportGeneratorTypesListSkipped.Add("HTML") }
                if ($_jobReportGeneratorTypesListSkipped.Contains("NONE") -and $_jobReportGeneratorTypesListSkipped.Count -gt 1) { $_jobReportGeneratorTypesListSkipped.Remove("NONE") }
                elseif ($_jobReportGeneratorTypesListSkipped.Count -eq 1 -and $_jobReportGeneratorTypesListSkipped[0] -eq "NONE") { $_jobReportGeneratorTypesListSkipped = [System.Collections.Generic.List[string]]@("HTML") }
            }
            $_finalJobReportTypesSkipped = $_jobReportGeneratorTypesListSkipped | Select-Object -Unique
            $_activeReportTypesForSkippedJob = $_finalJobReportTypesSkipped | Where-Object { $_ -ne "NONE" }

            if ($_activeReportTypesForSkippedJob.Count -gt 0) {
                $defaultJobReportsDirSkipped = Join-Path -Path $PSScriptRootForPaths -ChildPath "Reports"
                # Ensure directory exists (simplified check, assumes it might have been created by a previous job in the set)
                if (-not (Test-Path -LiteralPath $defaultJobReportsDirSkipped -PathType Container)) {
                    try {
                        New-Item -Path $defaultJobReportsDirSkipped -ItemType Directory -Force -ErrorAction Stop | Out-Null
                        & $LocalWriteLog -Message "[INFO] JobOrchestrator: Default reports directory '$defaultJobReportsDirSkipped' created for skipped job report." -Level "INFO"
                    } catch {
                        & $LocalWriteLog -Message "[WARNING] JobOrchestrator: Failed to create reports directory '$defaultJobReportsDirSkipped' for skipped job. Report generation may fail. Error: $($_.Exception.Message)" -Level "WARNING"
                    }
                }
                if (Test-Path -LiteralPath $defaultJobReportsDirSkipped -PathType Container) {
                    Invoke-ReportGenerator -ReportDirectory $defaultJobReportsDirSkipped `
                        -JobName $currentJobName `
                        -ReportData $currentJobReportData `
                        -GlobalConfig $Configuration `
                        -JobConfig $jobConfigForEnableCheck `
                        -Logger $Logger
                }
            }

            $jobEffectiveSuccessState[$currentJobName] = $false # A disabled job did not "succeed" for dependency purposes
            if ($CurrentSetName -and $StopSetOnErrorPolicy) {
                & $LocalWriteLog -Message "[WARNING] Job '$currentJobName' in set '$CurrentSetName' was disabled. Stopping set as 'OnErrorInJob' policy is 'StopSet' (treating disabled as a non-success)." -Level "WARNING"
                if ($overallSetStatus -ne "FAILURE") { $overallSetStatus = "WARNINGS" } # Or FAILURE depending on how strict you want to be
                break # Stop processing further jobs in the set
            }
            continue # Move to the next job in $JobsToProcess
        }

        Write-ConsoleBanner -NameText "Processing Job:" `
                            -ValueText $currentJobName `
                            -CenterText `
                            -PrependNewLine

        $Global:GlobalJobLogEntries = [System.Collections.Generic.List[object]]::new()
        $Global:GlobalJobHookScriptData = [System.Collections.Generic.List[object]]::new()

        $currentJobReportData = [ordered]@{ JobName = $currentJobName }
        $currentJobReportData['ScriptStartTime'] = Get-Date

        $jobConfigFromMainConfig = $Configuration.BackupLocations[$currentJobName]
        $effectiveJobConfigForThisJob = $null
        $currentJobIndividualStatus = "FAILURE" # Default to failure, will be updated if skipped or succeeds
        $skipJobDueToDependencyFailure = $false
        $dependencyFailureReason = ""

        try {
            # --- Get Effective Config FIRST ---
            $setSevenZipIncludeListFileForEffConfig = if (-not [string]::IsNullOrWhiteSpace($CurrentSetName) -and $Configuration.BackupSets.ContainsKey($CurrentSetName) -and $Configuration.BackupSets[$CurrentSetName].ContainsKey('SevenZipIncludeListFile')) { $Configuration.BackupSets[$CurrentSetName].SevenZipIncludeListFile } else { $null }
            $setSevenZipExcludeListFileForEffConfig = if (-not [string]::IsNullOrWhiteSpace($CurrentSetName) -and $Configuration.BackupSets.ContainsKey($CurrentSetName) -and $Configuration.BackupSets[$CurrentSetName].ContainsKey('SevenZipExcludeListFile')) { $Configuration.BackupSets[$CurrentSetName].SevenZipExcludeListFile } else { $null }

            $effectiveConfigParams = @{
                JobConfig                  = $jobConfigFromMainConfig
                GlobalConfig               = $Configuration
                CliOverrides               = $CliOverrideSettings
                JobReportDataRef           = ([ref]$currentJobReportData)
                Logger                     = $Logger
                SetSevenZipIncludeListFile = $setSevenZipIncludeListFileForEffConfig
                SetSevenZipExcludeListFile = $setSevenZipExcludeListFileForEffConfig
            }
            $effectiveJobConfigForThisJob = Get-PoShBackupJobEffectiveConfiguration @effectiveConfigParams

            # --- Initialize Log File with Enriched Header ---
            $Global:GlobalLogFile = $null
            if ($Global:GlobalEnableFileLogging) {
                $logDate = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
                $safeJobNameForFile = $currentJobName -replace '[^a-zA-Z0-9_-]', '_'
                if (-not [string]::IsNullOrWhiteSpace($Global:GlobalLogDirectory) -and (Test-Path -LiteralPath $Global:GlobalLogDirectory -PathType Container)) {
                    $Global:GlobalLogFile = Join-Path -Path $Global:GlobalLogDirectory -ChildPath "$($safeJobNameForFile)_$($logDate).log"
                    try {
                        $mainScriptPath = Join-Path -Path $PSScriptRootForPaths -ChildPath "PoSh-Backup.ps1"
                        $mainScriptContent = Get-Content -LiteralPath $mainScriptPath -Raw -ErrorAction SilentlyContinue
                        $scriptVersion = Get-ScriptVersionFromContent -ScriptContent $mainScriptContent -ScriptNameForWarning "PoSh-Backup.ps1"
                        $osInfo = (Get-CimInstance -ClassName Win32_OperatingSystem).Caption
                        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
                        $isAdmin = Test-AdminPrivilege -Logger $Logger

                        # TODO: Each iterated item needs to be proceeded by a # character.
                        $cliOverridesForLog = $CliOverrideSettings.GetEnumerator() | Where-Object { $null -ne $_.Value } | ForEach-Object { "    - $($_.Name) = $($_.Value)" }
                        if ($cliOverridesForLog.Count -eq 0) { $cliOverridesForLog = "#    (None)" }

                        $cliOverridesString = $cliOverridesForLog -join [Environment]::NewLine
                        $dependenciesForLog = if ($effectiveJobConfigForThisJob.DependsOnJobs.Count -gt 0) { $effectiveJobConfigForThisJob.DependsOnJobs -join ', ' } else { '(None)' }
                        $targetsForLog = if ($effectiveJobConfigForThisJob.TargetNames.Count -gt 0) { $effectiveJobConfigForThisJob.TargetNames -join ', ' } else { '(Local Only)' }

                        $logHeader = @"
#==============================================================================
# PoSh-Backup Log File
#
# -- Run Context --
#   Job Name     : $currentJobName
#   Run As Set   : $(if ([string]::IsNullOrWhiteSpace($CurrentSetName)) { '(Standalone Job)' } else { $CurrentSetName })
#   Started      : $(Get-Date -Format 'o')
#   Simulate Mode: $($IsSimulateMode.IsPresent)
#
# -- System Context --
#   Computer     : $($env:COMPUTERNAME)
#   User Context : $currentUser
#   Admin Rights : $isAdmin
#   OS Version   : $osInfo
#   PS Version   : $($PSVersionTable.PSVersion)
#   Process ID   : $PID
#
# -- Script Context --
#   Version      : $scriptVersion
#   Script Path  : $PSScriptRootForPaths
#   Config File  : $ActualConfigFile
#
# -- Key Job Settings --
#   Dependencies : $dependenciesForLog
#   VSS Enabled  : $($effectiveJobConfigForThisJob.JobEnableVSS)
#   Password Mode: $($effectiveJobConfigForThisJob.ArchivePasswordMethod)
#   Remote Targets: $targetsForLog
#
# -- Command-Line Overrides --
$cliOverridesString
#
#==============================================================================

"@
                        Set-Content -Path $Global:GlobalLogFile -Value $logHeader -Encoding UTF8 -Force
                    } catch { & $LocalWriteLog -Message "[WARNING] Failed to write header to log file '$($Global:GlobalLogFile)'. Error: $($_.Exception.Message)" -Level "WARNING" }
                    & $LocalWriteLog -Message "[INFO] Logging for job '$currentJobName' to file: $($Global:GlobalLogFile)" -Level "INFO"
                } else { & $LocalWriteLog -Message "[WARNING] Log directory is not valid. File logging for job '$currentJobName' will be skipped." -Level "WARNING" }
            }

            # --- Dependency Check ---
            if ($effectiveJobConfigForThisJob.ContainsKey('DependsOnJobs') -and $effectiveJobConfigForThisJob.DependsOnJobs -is [array] -and $effectiveJobConfigForThisJob.DependsOnJobs.Count -gt 0) {
                & $LocalWriteLog -Message "  - Job '$currentJobName' has dependencies: $($effectiveJobConfigForThisJob.DependsOnJobs -join ', ')" -Level "INFO"
                foreach ($dependencyName in $effectiveJobConfigForThisJob.DependsOnJobs) {
                    if (-not $jobEffectiveSuccessState.ContainsKey($dependencyName)) {
                        $dependencyFailureReason = "Prerequisite job '$dependencyName' was not processed or its status is unknown (potentially an issue with dependency order or it was not part of the initial job/set selection)."
                        & $LocalWriteLog -Message "[ERROR] Job '$currentJobName' SKIPPED. $dependencyFailureReason" -Level "ERROR"
                        $skipJobDueToDependencyFailure = $true
                        break
                    }
                    if ($jobEffectiveSuccessState[$dependencyName] -eq $false) {
                        $dependencyFailureReason = "Prerequisite job '$dependencyName' did not complete successfully (effective status: FAILED/SKIPPED)."
                        & $LocalWriteLog -Message "[WARNING] Job '$currentJobName' SKIPPED. $dependencyFailureReason" -Level "WARNING"
                        $skipJobDueToDependencyFailure = $true
                        break
                    }
                    & $LocalWriteLog -Message "    - Prerequisite job '$dependencyName' effectively succeeded. Continuing check..." -Level "DEBUG"
                }
            }

            if ($skipJobDueToDependencyFailure) {
                $currentJobIndividualStatus = "SKIPPED_DEPENDENCY"
                $currentJobReportData.ErrorMessage = "Job skipped due to unmet dependency: $dependencyFailureReason"
            }
            else {
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
            }

            $currentJobEffectiveSuccess = $false
            if ($currentJobIndividualStatus -eq "SUCCESS" -or $currentJobIndividualStatus -eq "SIMULATED_COMPLETE") {
                $currentJobEffectiveSuccess = $true
            }
            elseif ($currentJobIndividualStatus -eq "WARNINGS") {
                if ($effectiveJobConfigForThisJob.TreatSevenZipWarningsAsSuccess) {
                    $currentJobEffectiveSuccess = $true
                    & $LocalWriteLog -Message "  - Job '$currentJobName' completed with WARNINGS, but TreatSevenZipWarningsAsSuccess is TRUE. Considered effectively successful for dependencies." -Level "INFO"
                }
                else {
                    & $LocalWriteLog -Message "  - Job '$currentJobName' completed with WARNINGS, and TreatSevenZipWarningsAsSuccess is FALSE. Considered effectively FAILED for dependencies." -Level "INFO"
                }
            }
            elseif ($currentJobIndividualStatus -eq "SKIPPED_DEPENDENCY") {
                $currentJobEffectiveSuccess = $false
            }
            $jobEffectiveSuccessState[$currentJobName] = $currentJobEffectiveSuccess

            if (-not $CurrentSetName) {
                $jobSpecificPostRunActionForSingleJob = $effectiveJobConfigForThisJob.PostRunAction
            }

        }
        catch {
            $currentJobIndividualStatus = "FAILURE"
            & $LocalWriteLog -Message "[FATAL] JobOrchestrator: Unhandled exception during processing of job '$currentJobName': $($_.Exception.ToString())" -Level "ERROR"
            $currentJobReportData['ErrorMessage'] = $_.Exception.ToString()
            $jobEffectiveSuccessState[$currentJobName] = $false
        }

        $currentJobReportData['LogEntries'] = if ($null -ne $Global:GlobalJobLogEntries) { $Global:GlobalJobLogEntries } else { [System.Collections.Generic.List[object]]::new() }
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
        }
        else {
            $currentJobReportData['TotalDuration'] = "N/A (Timing data incomplete)"
            $currentJobReportData['TotalDurationSeconds'] = 0
        }
        if (($currentJobReportData.PSObject.Properties.Name -contains 'OverallStatus') -and $currentJobReportData.OverallStatus -eq "FAILURE" -and -not ($currentJobReportData.PSObject.Properties.Name -contains 'ErrorMessage')) {
            $currentJobReportData['ErrorMessage'] = "Job failed; specific error caught by main loop or not recorded by Invoke-PoShBackupJob."
        }

        if ($currentJobIndividualStatus -eq "FAILURE") {
            $overallSetStatus = "FAILURE"
        }
        elseif ($currentJobIndividualStatus -eq "WARNINGS" -and $overallSetStatus -ne "FAILURE") {
            $overallSetStatus = "WARNINGS"
        }
        elseif ($currentJobIndividualStatus -eq "SKIPPED_DEPENDENCY" -and $overallSetStatus -ne "FAILURE") {
            $overallSetStatus = "WARNINGS"
        }

        $displayStatusForLog = $currentJobReportData.OverallStatus
        & $LocalWriteLog -Message "Finished processing job '$currentJobName'. Status: $displayStatusForLog" -Level $displayStatusForLog

        $_jobSpecificReportTypesSetting = Get-ConfigValue -ConfigObject $jobConfigFromMainConfig -Key 'ReportGeneratorType' -DefaultValue (Get-ConfigValue -ConfigObject $Configuration -Key 'ReportGeneratorType' -DefaultValue "HTML")
        $_jobReportGeneratorTypesList = [System.Collections.Generic.List[string]]::new()
        if ($_jobSpecificReportTypesSetting -is [array]) {
            $_jobSpecificReportTypesSetting | ForEach-Object { $_jobReportGeneratorTypesList.Add($_.ToString().ToUpperInvariant()) }
        }
        else {
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
                }
                catch {
                    & $LocalWriteLog -Message "[WARNING] Failed to create default reports directory '$defaultJobReportsDir'. Report generation may fail. Error: $($_.Exception.Message)" -Level "WARNING"
                }
            }
            # This is the second call that was failing:
            Invoke-ReportGenerator -ReportDirectory $defaultJobReportsDir `
                -JobName $currentJobName `
                -ReportData $currentJobReportData `
                -GlobalConfig $Configuration `
                -JobConfig $jobConfigFromMainConfig `
                -Logger $Logger
        }

        if ($Global:GlobalEnableFileLogging -and (-not [string]::IsNullOrWhiteSpace($Global:GlobalLogDirectory))) {
            $finalLogRetentionCountForJob = $null
            if ($null -ne $CliOverrideSettings.LogRetentionCountCLI) {
                $finalLogRetentionCountForJob = $CliOverrideSettings.LogRetentionCountCLI
            }
            elseif ($CurrentSetName -and $Configuration.BackupSets.ContainsKey($CurrentSetName) -and $Configuration.BackupSets[$CurrentSetName].ContainsKey('LogRetentionCount')) {
                $finalLogRetentionCountForJob = $Configuration.BackupSets[$CurrentSetName].LogRetentionCount
            }
            elseif ($null -ne $effectiveJobConfigForThisJob -and $effectiveJobConfigForThisJob.ContainsKey('LogRetentionCount')) {
                $finalLogRetentionCountForJob = $effectiveJobConfigForThisJob.LogRetentionCount
            }
            if ($null -ne $finalLogRetentionCountForJob) {
                Invoke-LogFileRetention -LogDirectory $Global:GlobalLogDirectory `
                    -JobNamePattern $currentJobName `
                    -RetentionCount $finalLogRetentionCountForJob `
                    -Logger $Logger `
                    -IsSimulateMode:$IsSimulateMode `
                    -PSCmdletInstance $PSCmdlet
            }
            else {
                & $LocalWriteLog -Message "[WARNING] Log Retention for job '$currentJobName': Could not determine a final retention count. Skipping log retention." -Level "WARNING"
            }
        }

        if ($CurrentSetName -and $StopSetOnErrorPolicy) {
            if ($currentJobIndividualStatus -eq "FAILURE" -or $skipJobDueToDependencyFailure) {
                $stopReason = if ($currentJobIndividualStatus -eq "FAILURE") { "FAILED (Status: $currentJobIndividualStatus)" } else { "SKIPPED due to dependency failure" }
                & $LocalWriteLog -Message "[ERROR] Job '$currentJobName' in set '$CurrentSetName' $stopReason. Stopping set as 'OnErrorInJob' policy is 'StopSet'." -Level "ERROR"
                if ($overallSetStatus -ne "FAILURE") { $overallSetStatus = "FAILURE" }
                break
            }
        }
    }

    return @{
        OverallSetStatus                  = $overallSetStatus
        JobSpecificPostRunActionForNonSet = if (-not $CurrentSetName) { $jobSpecificPostRunActionForSingleJob } else { $null }
        SetSpecificPostRunAction          = if ($CurrentSetName) { $SetSpecificPostRunAction } else { $null }
    }
}

Export-ModuleMember -Function Invoke-PoShBackupRun
