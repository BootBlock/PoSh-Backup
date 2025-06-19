# Modules\Managers\FinalisationManager.psm1
<#
.SYNOPSIS
    Manages the finalisation tasks for the PoSh-Backup script, including summary display,
    post-run action invocation (via PostRunActionOrchestrator), report file retention,
    pause behaviour, and exit code.
.DESCRIPTION
    This module provides a function to handle all tasks that occur after the main backup
    operations (jobs/sets) have completed. This includes:
    - Displaying a completion banner.
    - Logging final script statistics (status, duration).
    - Orchestrating post-run system actions by calling the PostRunActionOrchestrator.
    - Applying retention policies to report files (deleting or compressing old ones).
    - Managing the configured pause behaviour before the script exits.
    - Terminating the script with an appropriate exit code based on the overall status.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.1 # Made report retention deletion more efficient and less verbose.
    DateCreated:    01-Jun-2025
    LastModified:   14-Jun-2025
    Purpose:        To centralise script finalisation, summary, and exit logic.
    Prerequisites:  PowerShell 5.1+.
                    Requires Modules\Utilities\ConsoleDisplayUtils.psm1 and
                    Modules\Core\PostRunActionOrchestrator.psm1 to be available.
                    Relies on global colour variables being set.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers
try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "..\Utilities\ConsoleDisplayUtils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "..\Core\PostRunActionOrchestrator.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Warning "FinalisationManager.psm1: Could not import one or more dependent modules. Some functionality might be affected. Error: $($_.Exception.Message)"
}
#endregion

#region --- Private Helper: Report File Retention ---
function Invoke-ReportFileRetentionInternal {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,
        [Parameter(Mandatory = $true)]
        [string[]]$ProcessedJobNames,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    # PSSA appeasement... grr.
    & $Logger -Message "FinalisationManager/Invoke-ReportFileRetentionInternal: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO")
        & $Logger -Message $Message -Level $Level
    }

    $retentionCount = $Configuration.DefaultReportRetentionCount
    $compressOld = $Configuration.CompressOldReports
    $compressFormat = $Configuration.OldReportCompressionFormat

    if ($retentionCount -eq 0) {
        & $LocalWriteLog -Message "[INFO] FinalisationManager: ReportRetentionCount is 0. All report files will be kept." -Level "INFO"
        return
    }

    & $LocalWriteLog -Message "`n[INFO] FinalisationManager: Applying Report Retention Policy..." -Level "INFO"
    & $LocalWriteLog -Message "   - Number of report sets to keep per job: $retentionCount"
    & $LocalWriteLog -Message "   - Compress Old Reports: $compressOld"

    $reportDirs = @(
        $Configuration.HtmlReportDirectory,
        $Configuration.CsvReportDirectory,
        $Configuration.JsonReportDirectory,
        $Configuration.XmlReportDirectory,
        $Configuration.TxtReportDirectory,
        $Configuration.MdReportDirectory
    ) | Select-Object -Unique | ForEach-Object {
        if ([System.IO.Path]::IsPathRooted($_)) { $_ }
        else { Join-Path -Path $Configuration._PoShBackup_PSScriptRoot -ChildPath $_ }
    } | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -Unique

    foreach ($jobName in $ProcessedJobNames) {
        $safeJobName = $jobName -replace '[^a-zA-Z0-9_-]', '_'
        $reportFilePattern = "$($safeJobName)_Report_*.???"
        $allReportFilesForJob = @()

        foreach ($dir in $reportDirs) {
            $allReportFilesForJob += Get-ChildItem -Path $dir -Filter $reportFilePattern -File -ErrorAction SilentlyContinue
        }

        if ($allReportFilesForJob.Count -eq 0) { continue }

        $reportInstances = $allReportFilesForJob | Group-Object {
            if ($_.Name -match "Report_(\d{8}_\d{6})\.") { $Matches[1] } else { $_.CreationTime.ToString("yyyyMMdd_HHmmss") }
        } | Sort-Object @{Expression = {[datetime]::ParseExact($_.Name, "yyyyMMdd_HHmmss", $null)}; Descending = $true}

        if ($reportInstances.Count -le $retentionCount) {
            & $LocalWriteLog -Message "   - Job '$jobName': Found $($reportInstances.Count) report instance(s), which is at or below retention count ($retentionCount). No action needed." -Level "INFO"
            continue
        }

        $instancesToProcess = $reportInstances | Select-Object -Skip $retentionCount
        & $LocalWriteLog -Message "   - Job '$jobName': Found $($reportInstances.Count) report instance(s). Will process $($instancesToProcess.Count) older instance(s)." -Level "INFO"

        foreach ($instance in $instancesToProcess) {
            $filesInInstance = $instance.Group
            if ($compressOld) {
                $archiveFileName = "ArchivedReports_$($safeJobName)_$($instance.Name).$($compressFormat.ToLower())"
                $archiveFullPath = Join-Path -Path $filesInInstance[0].DirectoryName -ChildPath $archiveFileName
                $actionMessage = "Compress $($filesInInstance.Count) report file(s) for instance '$($instance.Name)' to '$archiveFullPath' and delete originals"

                if ($IsSimulateMode.IsPresent) {
                    & $LocalWriteLog -Message "SIMULATE: $actionMessage" -Level "SIMULATE"
                    continue
                }
                if (-not $PSCmdletInstance.ShouldProcess($archiveFullPath, "Compress and Remove Old Reports")) {
                    & $LocalWriteLog -Message "       - Report compression for instance '$($instance.Name)' skipped by user." -Level "WARNING"
                    continue
                }
                try {
                    Compress-Archive -Path $filesInInstance.FullName -DestinationPath $archiveFullPath -Update -ErrorAction Stop
                    & $LocalWriteLog -Message "       - Successfully compressed $($filesInInstance.Count) report files into '$archiveFullPath'." -Level "SUCCESS"
                    Remove-Item -Path $filesInInstance.FullName -Force -ErrorAction Stop
                } catch {
                    & $LocalWriteLog -Message "[ERROR] Failed to compress or remove original report files for instance '$($instance.Name)'. Error: $($_.Exception.Message)" -Level "ERROR"
                }
            } else { # Delete
                $filePathsInInstance = $filesInInstance.FullName
                $actionMessage = "Permanently Delete $($filesInInstance.Count) report files for instance dated $($instance.Name)"
                if (-not $PSCmdletInstance.ShouldProcess($filesInInstance[0].DirectoryName, $actionMessage)) {
                    & $LocalWriteLog -Message "       - Deletion of report instance '$($instance.Name)' skipped by user." -Level "WARNING"
                    continue
                }
                & $LocalWriteLog -Message "       - Deleting $($filesInInstance.Count) report files for instance dated $($instance.Name)..." -Level "WARNING"
                try {
                    Remove-Item -Path $filePathsInInstance -Force -ErrorAction Stop
                    & $LocalWriteLog -Message "         - Status: DELETED PERMANENTLY" -Level "SUCCESS"
                } catch {
                    & $LocalWriteLog -Message "         - Status: FAILED to delete one or more files for this instance! Error: $($_.Exception.Message)" -Level "ERROR"
                }
            }
        }
    }
}
#endregion

function Invoke-PoShBackupFinalisation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OverallSetStatus,
        [Parameter(Mandatory = $true)]
        [datetime]$ScriptStartTime,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [switch]$TestConfigIsPresent,
        [Parameter(Mandatory = $true)]
        [hashtable]$CliOverrideSettings,
        [Parameter(Mandatory = $false)]
        [hashtable]$SetSpecificPostRunAction,
        [Parameter(Mandatory = $false)]
        [hashtable]$JobSpecificPostRunActionForNonSetRun,
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,
        [Parameter(Mandatory = $true)]
        [scriptblock]$LoggerScriptBlock,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance,
        [Parameter(Mandatory = $false)]
        [string]$CurrentSetNameForLog,
        [Parameter(Mandatory = $true)]
        [string[]]$JobsToProcess
    )

    $effectiveOverallStatus = $OverallSetStatus

    if ($IsSimulateMode.IsPresent -and $effectiveOverallStatus -ne "FAILURE" -and $effectiveOverallStatus -ne "WARNINGS") {
        $effectiveOverallStatus = "SIMULATED_COMPLETE"
    }

    # --- Report Retention Handling ---
    if ($null -ne $JobsToProcess -and $JobsToProcess.Count -gt 0) {
        Invoke-ReportFileRetentionInternal -Configuration $Configuration `
            -ProcessedJobNames $JobsToProcess `
            -Logger $LoggerScriptBlock `
            -IsSimulateMode:$IsSimulateMode `
            -PSCmdletInstance $PSCmdletInstance
    }

    # --- Post-Run Action Handling ---
    if (Get-Command Invoke-PoShBackupPostRunActionHandler -ErrorAction SilentlyContinue) {
        $jobNameForLog = if ($JobsToProcess.Count -eq 1 -and (-not $CurrentSetNameForLog)) { $JobsToProcess[0] } else { $null }
        $postRunParams = @{
            OverallStatus                     = $effectiveOverallStatus
            CliOverrideSettings               = $CliOverrideSettings
            SetSpecificPostRunAction          = $SetSpecificPostRunAction
            JobSpecificPostRunActionForNonSet = $JobSpecificPostRunActionForNonSetRun
            GlobalConfig                      = $Configuration
            IsSimulateMode                    = $IsSimulateMode.IsPresent
            TestConfigIsPresent               = $TestConfigIsPresent.IsPresent
            Logger                            = $LoggerScriptBlock
            PSCmdletInstance                  = $PSCmdletInstance
            CurrentSetNameForLog              = $CurrentSetNameForLog
            JobNameForLog                     = $jobNameForLog
        }
        Invoke-PoShBackupPostRunActionHandler @postRunParams
    } else {
        & $LoggerScriptBlock -Message "[WARNING] FinalisationManager: Invoke-PoShBackupPostRunActionHandler command not found. Post-run actions will be skipped." -Level "WARNING"
    }

    # --- Completion Banner ---
    if (Get-Command Write-ConsoleBanner -ErrorAction SilentlyContinue) {
        $completionBorderColor = '$Global:ColourHeading'
        $completionNameFgColor = '$Global:ColourSuccess'
        if ($effectiveOverallStatus -eq "FAILURE") { $completionBorderColor = '$Global:ColourError'; $completionNameFgColor = '$Global:ColourError' }
        elseif ($effectiveOverallStatus -eq "WARNINGS") { $completionBorderColor = '$Global:ColourWarning'; $completionNameFgColor = '$Global:ColourWarning' }
        elseif ($IsSimulateMode.IsPresent -and $effectiveOverallStatus -ne "FAILURE" -and $effectiveOverallStatus -ne "WARNINGS") {
            $completionBorderColor = '$Global:ColourSimulate'; $completionNameFgColor = '$Global:ColourSimulate'
        }
        Write-ConsoleBanner -NameText "All PoSh Backup Operations Completed" `
                            -NameForegroundColor $completionNameFgColor `
                            -BannerWidth 78 `
                            -BorderForegroundColor $completionBorderColor `
                            -CenterText `
                            -PrependNewLine
    } else {
        & $LoggerScriptBlock -Message "--- All PoSh Backup Operations Completed ---" -Level "HEADING"
    }

    $finalScriptEndTime = Get-Date

    # TODO: Make this look nicer.
    & $LoggerScriptBlock -Message "  Overall Script Status: $effectiveOverallStatus" -Level $effectiveOverallStatus
    & $LoggerScriptBlock -Message "  Script started       : $ScriptStartTime" -Level "INFO"
    & $LoggerScriptBlock -Message "  Script ended         : $finalScriptEndTime" -Level "INFO"
    & $LoggerScriptBlock -Message "  Total duration       : $($finalScriptEndTime - $ScriptStartTime)" -Level "INFO"
    & $LoggerScriptBlock -Message "" -Level "INFO"

    # --- Pause Behaviour ---
    $_pauseDefaultFromScript = "OnFailureOrWarning"
    $_pauseSettingFromConfig = if ($Configuration.ContainsKey('PauseBeforeExit')) { $Configuration.PauseBeforeExit } else { $_pauseDefaultFromScript }
    $normalizedPauseConfigValue = ""
    if ($_pauseSettingFromConfig -is [bool]) {
        $normalizedPauseConfigValue = if ($_pauseSettingFromConfig) { "always" } else { "never" }
    } elseif ($null -ne $_pauseSettingFromConfig -and $_pauseSettingFromConfig -is [string]) {
        $normalizedPauseConfigValue = $_pauseSettingFromConfig.ToLowerInvariant()
    } else {
        $normalizedPauseConfigValue = $_pauseDefaultFromScript.ToLowerInvariant()
    }
    $effectivePauseBehaviour = $normalizedPauseConfigValue
    if ($null -ne $CliOverrideSettings.PauseBehaviour) {
        $effectivePauseBehaviour = $CliOverrideSettings.PauseBehaviour.ToLowerInvariant()
        if ($effectivePauseBehaviour -eq "true") { $effectivePauseBehaviour = "always" }
        if ($effectivePauseBehaviour -eq "false") { $effectivePauseBehaviour = "never" }
        & $LoggerScriptBlock -Message "[INFO] Pause behaviour explicitly set by CLI to: '$($CliOverrideSettings.PauseBehaviour)' (effective: '$effectivePauseBehaviour')." -Level "INFO"
    }

    $shouldPhysicallyPause = $false
    switch ($effectivePauseBehaviour) {
        "always"             { $shouldPhysicallyPause = $true }
        "never"              { $shouldPhysicallyPause = $false }
        "onfailure"          { if ($effectiveOverallStatus -eq "FAILURE") { $shouldPhysicallyPause = $true } }
        "onwarning"          { if ($effectiveOverallStatus -eq "WARNINGS") { $shouldPhysicallyPause = $true } }
        "onfailureorwarning" { if ($effectiveOverallStatus -in @("FAILURE", "WARNINGS")) { $shouldPhysicallyPause = $true } }
        default {
            & $LoggerScriptBlock -Message "[WARNING] Unknown PauseBeforeExit value '$effectivePauseBehaviour' was resolved. Defaulting to not pausing." -Level "WARNING"
            $shouldPhysicallyPause = $false
        }
    }
    if (($IsSimulateMode.IsPresent -or $TestConfigIsPresent.IsPresent) -and $effectivePauseBehaviour -ne "always") {
        $shouldPhysicallyPause = $false
    }

    if ($shouldPhysicallyPause) {
        & $LoggerScriptBlock -Message "`nPress any key to exit..." -Level "WARNING"
        if ($Host.Name -eq "ConsoleHost") {
            try { $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') | Out-Null }
            catch { & $LoggerScriptBlock -Message "[DEBUG] FinalisationManager: Error during ReadKey: $($_.Exception.Message)" -Level "DEBUG" }
        } else {
            & $LoggerScriptBlock -Message "  (Pause configured for '$effectivePauseBehaviour' and current status '$effectiveOverallStatus', but not running in ConsoleHost: $($Host.Name).)" -Level "INFO"
        }
    }

    # --- Exit Script ---
    $exitCode = $Global:PoShBackup_ExitCodes.OperationalFailure # Default to general failure

    switch ($effectiveOverallStatus) {
        "SUCCESS"            { $exitCode = $Global:PoShBackup_ExitCodes.Success }
        "SIMULATED_COMPLETE" { $exitCode = $Global:PoShBackup_ExitCodes.Success }
        "WARNINGS"           { $exitCode = $Global:PoShBackup_ExitCodes.SuccessWithWarnings }
        "FAILURE"            { $exitCode = $Global:PoShBackup_ExitCodes.OperationalFailure }
        # Any other status will use the default OperationalFailure code
    }

    exit $exitCode
}

Export-ModuleMember -Function Invoke-PoShBackupFinalisation
