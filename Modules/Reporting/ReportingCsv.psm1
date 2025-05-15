<#
.SYNOPSIS
    Generates CSV (Comma Separated Values) reports for PoSh-Backup jobs, providing a summary,
    detailed log entries, and hook script execution details in separate CSV files for easy
    parsing or spreadsheet import.
.DESCRIPTION
    This module creates structured data output in CSV format. It generates a main summary CSV
    file for each job, and optionally separate CSV files for detailed log entries and
    executed hook scripts if such data is present in the report data.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.4 (Removed PSSA attribute suppression; trailing whitespace removed)
    DateCreated:    14-May-2025
    LastModified:   15-May-2025
    Purpose:        CSV report generation for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+. Called by Reporting.psm1 (orchestrator).
#>

function Invoke-CsvReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ReportDirectory,
        [Parameter(Mandatory=$true)]
        [string]$JobName,
        [Parameter(Mandatory=$true)]
        [hashtable]$ReportData,
        [Parameter(Mandatory=$true)]
        # PSUseDeclaredVarsMoreThanAssignments for Logger is now excluded globally via PSScriptAnalyzerSettings.psd1
        [scriptblock]$Logger
    )
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if ($null -ne $ForegroundColour) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    & $LocalWriteLog -Message "[INFO] CSV Report generation started for job '$JobName'." -Level "INFO"

    $reportTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeJobNameForFile = $JobName -replace '[^a-zA-Z0-9_-]', '_'

    $summaryReportFileName = "$($safeJobNameForFile)_Summary_$($reportTimestamp).csv"
    $summaryReportFullPath = Join-Path -Path $ReportDirectory -ChildPath $summaryReportFileName

    try {
        $summaryObject = [PSCustomObject]@{}
        $ReportData.GetEnumerator() | Where-Object {$_.Name -notin @('LogEntries', 'JobConfiguration', 'HookScripts', 'IsSimulationReport')} | ForEach-Object {
            $value = if ($_.Value -is [array]) { $_.Value -join '; ' } else { $_.Value }
            Add-Member -InputObject $summaryObject -MemberType NoteProperty -Name $_.Name -Value $value
        }

        $summaryObject | Export-Csv -Path $summaryReportFullPath -NoTypeInformation -Encoding UTF8 -Force
        & $LocalWriteLog -Message "  - Summary CSV report generated: $summaryReportFullPath" -Level "SUCCESS"
    } catch {
         & $LocalWriteLog -Message "[ERROR] Failed to generate Summary CSV report '$summaryReportFullPath'. Error: $($_.Exception.Message)" -Level "ERROR"
    }

    if ($ReportData.ContainsKey('LogEntries') -and $null -ne $ReportData.LogEntries -and $ReportData.LogEntries.Count -gt 0) {
        $logReportFileName = "$($safeJobNameForFile)_Logs_$($reportTimestamp).csv"
        $logReportFullPath = Join-Path -Path $ReportDirectory -ChildPath $logReportFileName
        try {
            $ReportData.LogEntries | Export-Csv -Path $logReportFullPath -NoTypeInformation -Encoding UTF8 -Force
            & $LocalWriteLog -Message "  - Log Entries CSV report generated: $logReportFullPath" -Level "SUCCESS"
        } catch {
            & $LocalWriteLog -Message "[ERROR] Failed to generate Log Entries CSV report '$logReportFullPath'. Error: $($_.Exception.Message)" -Level "ERROR"
        }
    }

    if ($ReportData.ContainsKey('HookScripts') -and $null -ne $ReportData.HookScripts -and $ReportData.HookScripts.Count -gt 0) {
        $hookReportFileName = "$($safeJobNameForFile)_Hooks_$($reportTimestamp).csv"
        $hookReportFullPath = Join-Path -Path $ReportDirectory -ChildPath $hookReportFileName
        try {
            $ReportData.HookScripts | Export-Csv -Path $hookReportFullPath -NoTypeInformation -Encoding UTF8 -Force
            & $LocalWriteLog -Message "  - Hook Scripts CSV report generated: $hookReportFullPath" -Level "SUCCESS"
        } catch {
            & $LocalWriteLog -Message "[ERROR] Failed to generate Hook Scripts CSV report '$hookReportFullPath'. Error: $($_.Exception.Message)" -Level "ERROR"
        }
    }
}

Export-ModuleMember -Function Invoke-CsvReport
