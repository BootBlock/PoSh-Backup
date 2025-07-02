# Modules\Managers\FinalisationManager.psm1
<#
.SYNOPSIS
    Acts as a facade to manage the finalisation tasks for the PoSh-Backup script,
    including summary display, post-run actions, report retention, and exiting.
.DESCRIPTION
    This module provides a function to handle all tasks that occur after the main backup
    operations have completed. It orchestrates calls to specialised sub-modules for each
    distinct finalisation step:
    - ReportRetentionHandler.psm1: Applies retention policy to report files.
    - PostRunActionOrchestrator.psm1: Determines and invokes system state changes.
    - ReportingSetSummary.psm1: Generates the summary report for a backup set.
    - SummaryDisplayer.psm1: Displays the final completion banner and statistics.
    - ExitHandler.psm1: Manages the pause-on-exit behaviour and terminates the script.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.1.1 # FIX: Corrected parameter name for PostRunActionOrchestrator call.
    DateCreated:    01-Jun-2025
    LastModified:   02-Jul-2025
    Purpose:        To centralise script finalisation, summary, and exit logic.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers
$finalisationSubModulePath = Join-Path -Path $PSScriptRoot -ChildPath "FinalisationManager"
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Core\PostRunActionOrchestrator.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\Reporting.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $finalisationSubModulePath "ReportRetentionHandler.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $finalisationSubModulePath "SummaryDisplayer.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $finalisationSubModulePath "ExitHandler.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Warning "FinalisationManager.psm1 (Facade): Could not import one or more dependent modules. Some functionality might be affected. Error: $($_.Exception.Message)"
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
        [string[]]$JobsToProcess,
        [Parameter(Mandatory = $false)]
        [System.Collections.Generic.List[hashtable]]$AllJobResultsForSetReport
    )

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $LoggerScriptBlock -Message $Message -Level $Level }
    & $LocalWriteLog -Message "FinalisationManager (Facade): Beginning finalisation sequence." -Level "DEBUG"

    $effectiveOverallStatus = $OverallSetStatus
    if ($IsSimulateMode.IsPresent -and $effectiveOverallStatus -ne "FAILURE" -and $effectiveOverallStatus -ne "WARNINGS") {
        $effectiveOverallStatus = "SIMULATED_COMPLETE"
    }

    # --- 1. Apply Report Retention Policy ---
    if ($null -ne $JobsToProcess -and $JobsToProcess.Count -gt 0) {
        Invoke-PoShBackupReportRetention -Configuration $Configuration `
            -ProcessedJobNames $JobsToProcess `
            -Logger $LoggerScriptBlock `
            -IsSimulateMode:$IsSimulateMode `
            -PSCmdletInstance $PSCmdletInstance
    }

    # --- 2. Generate Backup Set Summary Report (if applicable) ---
    if (-not [string]::IsNullOrWhiteSpace($CurrentSetNameForLog) -and $null -ne $AllJobResultsForSetReport -and $AllJobResultsForSetReport.Count -gt 0) {
        & $LocalWriteLog -Message "FinalisationManager (Facade): Preparing to generate Backup Set summary report for '$CurrentSetNameForLog'." -Level "INFO"
        $setReportData = @{
            SetName       = $CurrentSetNameForLog; OverallStatus = $effectiveOverallStatus
            IsSimulated   = $IsSimulateMode.IsPresent; StartTime = $ScriptStartTime
            EndTime       = Get-Date; TotalDuration = (Get-Date) - $ScriptStartTime
            JobResults    = $AllJobResultsForSetReport
        }
        Invoke-SetSummaryReportGenerator -SetReportData $setReportData -GlobalConfig $Configuration -Logger $LoggerScriptBlock
    }

    # --- 3. Handle Post-Run System Actions ---
    $jobNameForLog = if ($JobsToProcess.Count -eq 1 -and (-not $CurrentSetNameForLog)) { $JobsToProcess[0] } else { $null }
    Invoke-PoShBackupPostRunActionHandler -OverallStatus $effectiveOverallStatus `
        -CliOverrideSettings $CliOverrideSettings `
        -SetSpecificPostRunAction $SetSpecificPostRunAction `
        -JobSpecificPostRunActionForNonSet $JobSpecificPostRunActionForNonSetRun `
        -GlobalConfig $Configuration `
        -IsSimulateMode:$IsSimulateMode `
        -TestConfigIsPresent:$TestConfigIsPresent `
        -Logger $LoggerScriptBlock `
        -PSCmdletInstance $PSCmdletInstance `
        -CurrentSetNameForLog $CurrentSetNameForLog `
        -JobNameForLog $jobNameForLog

    # --- 4. Display Final Summary to Console ---
    Show-PoShBackupFinalSummary -EffectiveOverallStatus $effectiveOverallStatus `
        -ScriptStartTime $ScriptStartTime `
        -IsSimulateMode:$IsSimulateMode

    # --- 5. Handle Pause Behaviour and Exit ---
    Invoke-PoShBackupExit -EffectiveOverallStatus $effectiveOverallStatus `
        -Configuration $Configuration `
        -CliOverrideSettings $CliOverrideSettings `
        -IsSimulateMode:$IsSimulateMode `
        -TestConfigIsPresent:$TestConfigIsPresent `
        -Logger $LoggerScriptBlock

    # The Invoke-PoShBackupExit function will call exit internally.
}

Export-ModuleMember -Function Invoke-PoShBackupFinalisation
