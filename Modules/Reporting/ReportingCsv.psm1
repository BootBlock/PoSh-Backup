<#
.SYNOPSIS
    Generates Comma Separated Values (CSV) reports for PoSh-Backup jobs.
    It provides a summary of the backup job, detailed log entries, and hook script
    execution details, each in separate, easily parsable CSV files.

.DESCRIPTION
    This module is responsible for creating structured data output in CSV format for a
    completed PoSh-Backup job. For each job, it generates:
    1. A main summary CSV file (e.g., 'JobName_Summary_Timestamp.csv') containing
       key-value pairs of the overall job statistics and outcomes.
    2. Optionally, if detailed log entries are present in the report data, a separate CSV file
       (e.g., 'JobName_Logs_Timestamp.csv') with each log entry as a row.
    3. Optionally, if hook scripts were executed and data is available, a separate CSV file
       (e.g., 'JobName_Hooks_Timestamp.csv') detailing each hook script's execution.

    These CSV files are ideal for data import into spreadsheets, databases, or for
    programmatic analysis and integration with other monitoring or auditing systems.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.1 # Implemented logger usage.
    DateCreated:    14-May-2025
    LastModified:   16-May-2025
    Purpose:        CSV report generation sub-module for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Called by the main Reporting.psm1 orchestrator module.
#>

function Invoke-CsvReport {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Generates CSV formatted report files for a specific PoSh-Backup job.
    .DESCRIPTION
        This function takes the consolidated report data for a backup job and exports it
        into one or more CSV files. A primary CSV file provides a summary of the job.
        If log entries or hook script data exist, they are exported into their own
        respective CSV files. Files are named using the job name and a timestamp.
    .PARAMETER ReportDirectory
        The target directory where the generated CSV report files for this job will be saved.
        This path is typically resolved by the main Reporting.psm1 orchestrator.
    .PARAMETER JobName
        The name of the backup job. This is used in the filenames of the generated CSV reports
        to clearly associate them with the job.
    .PARAMETER ReportData
        A hashtable containing all data collected during the backup job's execution.
        This function will extract summary information, log entries, and hook script details
        from this hashtable to populate the CSV files.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function from Utils.psm1.
        Used for logging the CSV report generation process itself.
    .EXAMPLE
        # This function is typically called by Reporting.psm1 (orchestrator)
        # $csvParams = @{
        #     ReportDirectory = "C:\PoShBackup\Reports\CSV\MyJob"
        #     JobName         = "MyJob"
        #     ReportData      = $JobReportDataObject
        #     Logger          = ${function:Write-LogMessage}
        # }
        # Invoke-CsvReport @csvParams
    .OUTPUTS
        None. This function creates files in the specified ReportDirectory.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$ReportDirectory,
        [Parameter(Mandatory=$true)]
        [string]$JobName,
        [Parameter(Mandatory=$true)]
        [hashtable]$ReportData,
        [Parameter(Mandatory=$true)]
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

    & $LocalWriteLog -Message "[INFO] CSV Report generation process started for job '$JobName'." -Level "INFO"

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
        & $LocalWriteLog -Message "  - Summary CSV report generated successfully: '$summaryReportFullPath'" -Level "SUCCESS"
    } catch {
         & $LocalWriteLog -Message "[ERROR] Failed to generate Summary CSV report '$summaryReportFullPath' for job '$JobName'. Error: $($_.Exception.Message)" -Level "ERROR"
    }

    if ($ReportData.ContainsKey('LogEntries') -and $null -ne $ReportData.LogEntries -and $ReportData.LogEntries.Count -gt 0) {
        $logReportFileName = "$($safeJobNameForFile)_Logs_$($reportTimestamp).csv"
        $logReportFullPath = Join-Path -Path $ReportDirectory -ChildPath $logReportFileName
        try {
            $ReportData.LogEntries | Export-Csv -Path $logReportFullPath -NoTypeInformation -Encoding UTF8 -Force
            & $LocalWriteLog -Message "  - Log Entries CSV report generated successfully: '$logReportFullPath'" -Level "SUCCESS"
        } catch {
            & $LocalWriteLog -Message "[ERROR] Failed to generate Log Entries CSV report '$logReportFullPath' for job '$JobName'. Error: $($_.Exception.Message)" -Level "ERROR"
        }
    } else {
        & $LocalWriteLog -Message "  - No log entries found in report data for job '$JobName'. Log Entries CSV report will not be generated." -Level "DEBUG"
    }

    if ($ReportData.ContainsKey('HookScripts') -and $null -ne $ReportData.HookScripts -and $ReportData.HookScripts.Count -gt 0) {
        $hookReportFileName = "$($safeJobNameForFile)_Hooks_$($reportTimestamp).csv"
        $hookReportFullPath = Join-Path -Path $ReportDirectory -ChildPath $hookReportFileName
        try {
            $ReportData.HookScripts | Export-Csv -Path $hookReportFullPath -NoTypeInformation -Encoding UTF8 -Force
            & $LocalWriteLog -Message "  - Hook Scripts CSV report generated successfully: '$hookReportFullPath'" -Level "SUCCESS"
        } catch {
            & $LocalWriteLog -Message "[ERROR] Failed to generate Hook Scripts CSV report '$hookReportFullPath' for job '$JobName'. Error: $($_.Exception.Message)" -Level "ERROR"
        }
    } else {
        & $LocalWriteLog -Message "  - No hook script execution data found in report data for job '$JobName'. Hook Scripts CSV report will not be generated." -Level "DEBUG"
    }
    & $LocalWriteLog -Message "[INFO] CSV Report generation process finished for job '$JobName'." -Level "INFO"
}

Export-ModuleMember -Function Invoke-CsvReport
