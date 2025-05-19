<#
.SYNOPSIS
    Generates plain text (.txt) summary reports for PoSh-Backup jobs.
    These reports provide a simple, human-readable overview of the backup operation,
    including summary details, configuration settings used, hook script actions,
    details of remote target transfers (if any), and a chronological list of log entries.

.DESCRIPTION
    This module produces a straightforward plain text report, formatted for easy reading
    in any text editor or for straightforward inclusion in email bodies. It aims to present
    the most critical information from a backup job in a clean, uncluttered format.

    The report typically includes the following sections:
    - A header with the job name and generation timestamp.
    - A "SUMMARY" section with key operational outcomes and statistics.
    - A "CONFIGURATION USED" section listing the specific settings applied to the job.
    - A "HOOK SCRIPTS EXECUTED" section detailing any custom scripts that were run, their status, and their output.
    - A "REMOTE TARGET TRANSFERS" section (if applicable) detailing each attempted transfer to a remote target.
    - A "DETAILED LOG" section with all timestamped log messages generated during the job's execution.

    Array values in the summary and configuration are typically joined with semicolons, and multi-line
    hook script output is indented for readability.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.2.0 # Added Remote Target Transfers section.
    DateCreated:    14-May-2025
    LastModified:   19-May-2025
    Purpose:        Plain text summary report generation sub-module for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Called by the main Reporting.psm1 orchestrator module.
#>

function Invoke-TxtReport {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Generates a plain text (.txt) report file summarising a PoSh-Backup job.
    .DESCRIPTION
        This function takes the consolidated report data for a backup job and formats it
        into a human-readable plain text file. The report includes a summary of the job,
        the configuration that was used, details of any hook scripts executed, details of
        any remote target transfers, and the full sequence of log messages. The output file
        is named using the job name and a timestamp.
    .PARAMETER ReportDirectory
        The target directory where the generated .txt report file for this job will be saved.
        This path is typically resolved by the main Reporting.psm1 orchestrator.
    .PARAMETER JobName
        The name of the backup job. This is used in the filename and header of the generated report.
    .PARAMETER ReportData
        A hashtable containing all data collected during the backup job's execution.
        The function extracts and formats information from this hashtable.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function from Utils.psm1.
        Used for logging the .txt report generation process itself.
    .EXAMPLE
        # This function is typically called by Reporting.psm1 (orchestrator)
        # $txtParams = @{
        #     ReportDirectory = "C:\PoShBackup\Reports\TXT\MyJob"
        #     JobName         = "MyJob"
        #     ReportData      = $JobReportDataObject
        #     Logger          = ${function:Write-LogMessage}
        # }
        # Invoke-TxtReport @txtParams
    .OUTPUTS
        None. This function creates a file in the specified ReportDirectory.
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

    # Defensive PSSA appeasement line: Logger is functionally used via $LocalWriteLog,
    # but this direct call ensures PSSA sees it explicitly.
    & $Logger -Message "Invoke-TxtReport: Logger parameter active for job '$JobName'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if ($null -ne $ForegroundColour) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    & $LocalWriteLog -Message "[INFO] TXT Report generation process started for job '$JobName'." -Level "INFO"

    $reportTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeJobNameForFile = $JobName -replace '[^a-zA-Z0-9_-]', '_'
    $reportFileName = "$($safeJobNameForFile)_Report_$($reportTimestamp).txt"
    $reportFullPath = Join-Path -Path $ReportDirectory -ChildPath $reportFileName

    $reportContent = [System.Text.StringBuilder]::new()
    $separatorLine = "-" * 70
    $subSeparatorLine = "  " + ("-" * 66) # Indented separator

    $null = $reportContent.AppendLine("PoSh Backup Report - Job: $JobName")
    $null = $reportContent.AppendLine("Generated: $(Get-Date)")
    if ($ReportData.ContainsKey('IsSimulationReport') -and $ReportData.IsSimulationReport) {
        $null = $reportContent.AppendLine(("*" * 70))
        $null = $reportContent.AppendLine("*** SIMULATION MODE RUN - NO ACTUAL CHANGES WERE MADE ***")
        $null = $reportContent.AppendLine(("*" * 70))
    }
    $null = $reportContent.AppendLine($separatorLine)

    $null = $reportContent.AppendLine("SUMMARY:")
    # Exclude TargetTransfers from the main summary block as it will have its own section
    $ReportData.GetEnumerator() | Where-Object {$_.Name -notin @('LogEntries', 'JobConfiguration', 'HookScripts', 'IsSimulationReport', '_PoShBackup_PSScriptRoot', 'TargetTransfers')} | ForEach-Object {
        $value = if ($_.Value -is [array]) { ($_.Value | ForEach-Object { $_ -replace "`r`n", " " -replace "`n", " " }) -join '; ' } else { ($_.Value | Out-String).Trim() }
        $null = $reportContent.AppendLine("  $($_.Name.PadRight(30)): $value")
    }
    $null = $reportContent.AppendLine($separatorLine)

    if ($ReportData.ContainsKey('JobConfiguration') -and $null -ne $ReportData.JobConfiguration) {
        $null = $reportContent.AppendLine("CONFIGURATION USED FOR JOB '$JobName':")
        $ReportData.JobConfiguration.GetEnumerator() | Sort-Object Name | ForEach-Object {
            $value = if ($_.Value -is [array]) { ($_.Value | ForEach-Object { $_ -replace "`r`n", " " -replace "`n", " " }) -join '; ' } else { ($_.Value | Out-String).Trim() }
            $null = $reportContent.AppendLine("  $($_.Name.PadRight(30)): $value")
        }
        $null = $reportContent.AppendLine($separatorLine)
    }

    if ($ReportData.ContainsKey('HookScripts') -and $null -ne $ReportData.HookScripts -and $ReportData.HookScripts.Count -gt 0) {
        $null = $reportContent.AppendLine("HOOK SCRIPTS EXECUTED:")
        $ReportData.HookScripts | ForEach-Object {
            $null = $reportContent.AppendLine("  Hook Type : $($_.Name)")
            $null = $reportContent.AppendLine("  Path      : $($_.Path)")
            $null = $reportContent.AppendLine("  Status    : $($_.Status)")
            if (-not [string]::IsNullOrWhiteSpace($_.Output)) {
                $indentedOutput = ($_.Output.TrimEnd() -split '\r?\n' | ForEach-Object { "              $_" }) -join [Environment]::NewLine
                $null = $reportContent.AppendLine("  Output    : $($indentedOutput.TrimStart())")
            }
            $null = $reportContent.AppendLine() # Extra blank line for readability between hooks
        }
        $null = $reportContent.AppendLine($separatorLine)
    }

    # --- NEW: Remote Target Transfers Section ---
    if ($ReportData.ContainsKey('TargetTransfers') -and $null -ne $ReportData.TargetTransfers -and $ReportData.TargetTransfers.Count -gt 0) {
        $null = $reportContent.AppendLine("REMOTE TARGET TRANSFERS:")
        foreach ($transferEntry in $ReportData.TargetTransfers) {
            $null = $reportContent.AppendLine("  Target Name : $($transferEntry.TargetName)")
            $null = $reportContent.AppendLine("  Target Type : $($transferEntry.TargetType)")
            $null = $reportContent.AppendLine("  Status      : $($transferEntry.Status)")
            $null = $reportContent.AppendLine("  Remote Path : $($transferEntry.RemotePath)")
            $null = $reportContent.AppendLine("  Duration    : $($transferEntry.TransferDuration)")
            $null = $reportContent.AppendLine("  Size        : $($transferEntry.TransferSizeFormatted)")
            if (-not [string]::IsNullOrWhiteSpace($transferEntry.ErrorMessage)) {
                # Indent multi-line error messages for readability
                $indentedError = ($transferEntry.ErrorMessage.TrimEnd() -split '\r?\n' | ForEach-Object { "                $_" }) -join [Environment]::NewLine
                $null = $reportContent.AppendLine("  Error Msg   : $($indentedError.TrimStart())")
            }
            if ($ReportData.TargetTransfers.IndexOf($transferEntry) -lt ($ReportData.TargetTransfers.Count - 1)) {
                $null = $reportContent.AppendLine($subSeparatorLine) # Add separator if not the last transfer entry
            }
        }
        $null = $reportContent.AppendLine($separatorLine)
    }
    # --- END NEW: Remote Target Transfers Section ---

    if ($ReportData.ContainsKey('LogEntries') -and $null -ne $ReportData.LogEntries -and $ReportData.LogEntries.Count -gt 0) {
        $null = $reportContent.AppendLine("DETAILED LOG:")
        $ReportData.LogEntries | ForEach-Object {
            $null = $reportContent.AppendLine("$($_.Timestamp) [$($_.Level.ToUpper().PadRight(8))] $($_.Message)")
        }
        $null = $reportContent.AppendLine($separatorLine)
    }

    try {
        Set-Content -Path $reportFullPath -Value $reportContent.ToString() -Encoding UTF8 -Force
        & $LocalWriteLog -Message "  - TXT report generated successfully: '$reportFullPath'" -Level "SUCCESS"
    } catch {
         & $LocalWriteLog -Message "[ERROR] Failed to generate TXT report '$reportFullPath' for job '$JobName'. Error: $($_.Exception.Message)" -Level "ERROR"
    }
    & $LocalWriteLog -Message "[INFO] TXT Report generation process finished for job '$JobName'." -Level "INFO"
}

Export-ModuleMember -Function Invoke-TxtReport
