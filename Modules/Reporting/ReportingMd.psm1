<#
.SYNOPSIS
    Generates Markdown (.md) formatted reports for PoSh-Backup jobs.
    These reports offer a human-readable plain text format that can also be rendered
    into richly structured HTML by various Markdown processors, making them suitable
    for documentation, version control, or quick reviews.

.DESCRIPTION
    This module is responsible for creating reports using Markdown syntax for a completed
    PoSh-Backup job. The generated .md file is structured with Markdown headings, tables,
    and code blocks for clear presentation when rendered.

    The report typically includes:
    - A main title with the job name and generation timestamp.
    - A prominent "SIMULATION MODE RUN" notice if applicable.
    - A "Summary" section presented as a Markdown table.
    - A "Configuration Used" section, also as a Markdown table.
    - A "Hook Scripts Executed" section, detailing hooks in a table, with their output
      often formatted within `<pre><code>` blocks for better readability in rendered Markdown.
    - A "Detailed Log" section where each log entry is presented within a Markdown code block
      for preservation of formatting and easy copying.

    Helper functions within the module handle basic escaping of characters that have special
    meaning in Markdown (like '|' in table content).

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.2.0 # Enhanced CBH for module and Invoke-MdReport.
    DateCreated:    14-May-2025
    LastModified:   16-May-2025
    Purpose:        Markdown (.md) report generation sub-module for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Called by the main Reporting.psm1 orchestrator module.
#>

function Invoke-MdReport {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Generates a Markdown (.md) formatted report file for a specific PoSh-Backup job.
    .DESCRIPTION
        This function takes the consolidated report data for a backup job and formats it
        into a Markdown file. The report uses Markdown headings for sections, tables for
        summary and configuration data, and code blocks for log entries. Hook script output
        is typically embedded in a way that preserves its formatting when the Markdown is rendered.
        The output file is named using the job name and a timestamp.
    .PARAMETER ReportDirectory
        The target directory where the generated .md report file for this job will be saved.
        This path is typically resolved by the main Reporting.psm1 orchestrator.
    .PARAMETER JobName
        The name of the backup job. This is used in the filename and as a main heading in the report.
    .PARAMETER ReportData
        A hashtable containing all data collected during the backup job's execution.
        The function extracts and formats information from this hashtable into Markdown structures.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function from Utils.psm1.
        Used for logging the .md report generation process itself.
    .EXAMPLE
        # This function is typically called by Reporting.psm1 (orchestrator)
        # $mdParams = @{
        #     ReportDirectory = "C:\PoShBackup\Reports\MD\MyJob"
        #     JobName         = "MyJob"
        #     ReportData      = $JobReportDataObject
        #     Logger          = ${function:Write-LogMessage}
        # }
        # Invoke-MdReport @mdParams
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
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if ($null -ne $ForegroundColour) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    # Helper scriptblock to escape characters problematic in Markdown table cells.
    # Primarily escapes pipe characters and converts newlines to <br> for HTML rendering.
    $EscapeMarkdownTableContent = {
        param($Content)
        if ($null -eq $Content) { return "" }
        return $Content.ToString() -replace '\|', '\|' -replace '\r?\n', '<br>'
    }

    # Helper scriptblock for content intended for Markdown code blocks (minimal escaping needed).
    $EscapeMarkdownCodeContent = {
        param($Content)
        if ($null -eq $Content) { return "" }
        return $Content.ToString() # Generally, content in triple-backtick blocks is literal.
    }

    & $LocalWriteLog -Message "[INFO] Markdown Report generation process started for job '$JobName'." -Level "INFO"

    $reportTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeJobNameForFile = $JobName -replace '[^a-zA-Z0-9_-]', '_' # Sanitize for filename
    $reportFileName = "$($safeJobNameForFile)_Report_$($reportTimestamp).md"
    $reportFullPath = Join-Path -Path $ReportDirectory -ChildPath $reportFileName

    $reportContent = [System.Text.StringBuilder]::new()

    # --- Report Header ---
    $titlePrefix = "PoSh Backup Status Report"
    $null = $reportContent.AppendLine("# $($titlePrefix) - $($JobName | ForEach-Object {$EscapeMarkdownCodeContent.Invoke($_)})") # Escape job name just in case
    $null = $reportContent.AppendLine("")
    $null = $reportContent.AppendLine("**Generated:** $(Get-Date)")
    $null = $reportContent.AppendLine("")

    if ($ReportData.ContainsKey('IsSimulationReport') -and $ReportData.IsSimulationReport) {
        $null = $reportContent.AppendLine("> **\*\*\* SIMULATION MODE RUN \*\*\***") # Blockquote for emphasis
        $null = $reportContent.AppendLine("> This report reflects a simulated backup. No actual files were changed or archives created.")
        $null = $reportContent.AppendLine("")
    }

    # --- Summary Section ---
    $null = $reportContent.AppendLine("## Summary")
    $null = $reportContent.AppendLine("")
    $null = $reportContent.AppendLine("| Item                      | Detail |")
    $null = $reportContent.AppendLine("| :------------------------ | :----- |") # Markdown table alignment
    $ReportData.GetEnumerator() | Where-Object {$_.Name -notin @('LogEntries', 'JobConfiguration', 'HookScripts', 'IsSimulationReport', '_PoShBackup_PSScriptRoot')} | ForEach-Object {
        $value = if ($_.Value -is [array]) { ($_.Value | ForEach-Object { $EscapeMarkdownTableContent.Invoke($_) }) -join '; ' } else { $EscapeMarkdownTableContent.Invoke($_.Value) }
        $null = $reportContent.AppendLine("| $($EscapeMarkdownTableContent.Invoke($_.Name).PadRight(25)) | $value |")
    }
    $null = $reportContent.AppendLine("")

    # --- Configuration Section ---
    if ($ReportData.ContainsKey('JobConfiguration') -and $null -ne $ReportData.JobConfiguration) {
        $null = $reportContent.AppendLine("## Configuration Used for Job '$($JobName | ForEach-Object {$EscapeMarkdownCodeContent.Invoke($_)})'")
        $null = $reportContent.AppendLine("")
        $null = $reportContent.AppendLine("| Setting                   | Value |")
        $null = $reportContent.AppendLine("| :------------------------ | :---- |")
        $ReportData.JobConfiguration.GetEnumerator() | Sort-Object Name | ForEach-Object {
            $value = if ($_.Value -is [array]) { ($_.Value | ForEach-Object { $EscapeMarkdownTableContent.Invoke($_) }) -join '; ' } else { $EscapeMarkdownTableContent.Invoke($_.Value) }
            $null = $reportContent.AppendLine("| $($EscapeMarkdownTableContent.Invoke($_.Name).PadRight(25)) | $value |")
        }
        $null = $reportContent.AppendLine("")
    }

    # --- Hook Scripts Section ---
    if ($ReportData.ContainsKey('HookScripts') -and $null -ne $ReportData.HookScripts -and $ReportData.HookScripts.Count -gt 0) {
        $null = $reportContent.AppendLine("## Hook Scripts Executed")
        $null = $reportContent.AppendLine("")
        $null = $reportContent.AppendLine("| Type    | Path                | Status  | Output/Error |")
        $null = $reportContent.AppendLine("| :------ | :------------------ | :------ | :----------- |")
        $ReportData.HookScripts | ForEach-Object {
            $hookPathEscaped = & $EscapeMarkdownTableContent $_.Path
            # For hook output in Markdown, embedding in <pre><code> for potentially multi-line content
            # is often better for rendered views than trying to fit it all in a raw table cell.
            $hookOutputMd = if ([string]::IsNullOrWhiteSpace($_.Output)) {
                                "*(No output recorded)*"
                            } else {
                                # Escape for HTML context within Markdown, then wrap in pre/code
                                $escapedHtmlOutput = ConvertTo-PoshBackupSafeHtmlInternal -Text $_.Output.TrimEnd()
                                "<pre><code>$($escapedHtmlOutput)</code></pre>"
                            }
            $null = $reportContent.AppendLine("| $(& $EscapeMarkdownTableContent $_.Name) | $hookPathEscaped | **$(& $EscapeMarkdownTableContent $_.Status)** | $hookOutputMd |")
        }
        $null = $reportContent.AppendLine("")
    }

    # --- Detailed Log Section ---
    if ($ReportData.ContainsKey('LogEntries') -and $null -ne $ReportData.LogEntries -and $ReportData.LogEntries.Count -gt 0) {
        $null = $reportContent.AppendLine("## Detailed Log")
        $null = $reportContent.AppendLine("")
        $ReportData.LogEntries | ForEach-Object {
            $logLine = "$($_.Timestamp) [$($_.Level.ToUpper())] $($_.Message)"
            $null = $reportContent.AppendLine('```text') # Using 'text' hint for plain log block
            $null = $reportContent.AppendLine(($EscapeMarkdownCodeContent.Invoke($logLine))) # Message content itself
            $null = $reportContent.AppendLine('```')
            $null = $reportContent.AppendLine("") # Adds a little space between log entries
        }
    }

    try {
        Set-Content -Path $reportFullPath -Value $reportContent.ToString() -Encoding UTF8 -Force
        & $LocalWriteLog -Message "  - Markdown report generated successfully: '$reportFullPath'" -Level "SUCCESS"
    } catch {
         & $LocalWriteLog -Message "[ERROR] Failed to generate Markdown report '$reportFullPath' for job '$JobName'. Error: $($_.Exception.Message)" -Level "ERROR"
    }
    & $LocalWriteLog -Message "[INFO] Markdown Report generation process finished for job '$JobName'." -Level "INFO"
}

# Ensure ConvertTo-PoshBackupSafeHtmlInternal is available if not already (e.g., if System.Web wasn't loaded)
if (-not (Get-Command ConvertTo-PoshBackupSafeHtmlInternal -ErrorAction SilentlyContinue)) {
    Function ConvertTo-PoshBackupSafeHtmlInternal { param([string]$Text) return $Text -replace '&', '&' -replace '<', '<' -replace '>', '>' -replace '"', '"' -replace "'", '&#39;' }
}

Export-ModuleMember -Function Invoke-MdReport
