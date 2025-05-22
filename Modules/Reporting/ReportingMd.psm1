<#
.SYNOPSIS
    Generates Markdown (.md) formatted reports for PoSh-Backup jobs.
    These reports offer a human-readable plain text format that can also be rendered
    into richly structured HTML by various Markdown processors, making them suitable
    for documentation, version control, or quick reviews.
    Now includes a section for Remote Target Transfer details.

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
      often formatted within HTML <pre><code> blocks for better readability in rendered Markdown.
    - A "Remote Target Transfers" section (if applicable), presented as a Markdown table.
    - A "Detailed Log" section where each log entry is presented within a Markdown code block
      for preservation of formatting and easy copying.

    Helper functions within the module handle basic escaping of characters that have special
    meaning in Markdown (like '|' in table content).

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.3.1
    DateCreated:    14-May-2025
    LastModified:   19-May-2025
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
        summary, configuration, and target transfer data, and code blocks for log entries.
        Hook script output is typically embedded in a way that preserves its formatting when
        the Markdown is rendered. The output file is named using the job name and a timestamp.
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

    # Defensive PSSA appeasement line: Logger is functionally used via $LocalWriteLog,
    # but this direct call ensures PSSA sees it explicitly.
    & $Logger -Message "Invoke-MdReport: Logger parameter active for job '$JobName'." -Level "DEBUG" -ErrorAction SilentlyContinue

    # Internal helper to use the passed-in logger consistently for other messages
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    # Helper function to escape characters special to Markdown tables
    $EscapeMarkdownTableContent = {
        param($Content)
        if ($null -eq $Content) { return "" }
        # Escape pipe characters. Replace newlines with <br> for multi-line content within a cell.
        return $Content.ToString() -replace '\|', '\|' -replace '\r?\n', '<br />'
    }

    # Helper function to escape characters for general Markdown code/text blocks (less aggressive than table content)
    $EscapeMarkdownCodeContent = {
        param($Content)
        if ($null -eq $Content) { return "" }
        # For general text or code blocks, primarily backticks and backslashes might need escaping if intended literally.
        # However, within fenced code blocks (```), most characters are literal.
        # For simple text in headings or paragraphs, ensure no unintended Markdown formatting occurs.
        # This is a basic escape; more complex content might need more robust handling.
        return $Content.ToString() -replace '`', '\`' -replace '\*', '\*' -replace '_', '\_' -replace '\[', '\[' -replace '\]', '\]'
    }
    
    # HTML Encode Helper (re-defined locally if System.Web is not guaranteed for the module)
    # This is primarily for hook output that might contain HTML-like structures when we embed it raw.
    $LocalConvertToSafeHtml = {
        param([string]$TextToEncode)
        if ($null -eq $TextToEncode) { return '' }
        # Basic manual HTML encoding
        return $TextToEncode -replace '&', '&' -replace '<', '<' -replace '>', '>' -replace '"', '"' -replace "'", '&#39;'
    }


    & $LocalWriteLog -Message "[INFO] Markdown Report generation process started for job '$JobName'." -Level "INFO"

    $reportTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeJobNameForFile = $JobName -replace '[^a-zA-Z0-9_-]', '_'
    $reportFileName = "$($safeJobNameForFile)_Report_$($reportTimestamp).md"
    $reportFullPath = Join-Path -Path $ReportDirectory -ChildPath $reportFileName

    $reportContent = [System.Text.StringBuilder]::new()

    $titlePrefix = "PoSh Backup Status Report"
    $null = $reportContent.AppendLine("# $($titlePrefix) - $($JobName | ForEach-Object {$EscapeMarkdownCodeContent.Invoke($_)})")
    $null = $reportContent.AppendLine("")
    $null = $reportContent.AppendLine("**Generated:** $(Get-Date)")
    $null = $reportContent.AppendLine("")

    if ($ReportData.ContainsKey('IsSimulationReport') -and $ReportData.IsSimulationReport) {
        $null = $reportContent.AppendLine("> **\*\*\* SIMULATION MODE RUN \*\*\***")
        $null = $reportContent.AppendLine("> This report reflects a simulated backup. No actual files were changed or archives created.")
        $null = $reportContent.AppendLine("")
    }

    $null = $reportContent.AppendLine("## Summary")
    $null = $reportContent.AppendLine("")
    $null = $reportContent.AppendLine("| Item                      | Detail |")
    $null = $reportContent.AppendLine("| :------------------------ | :----- |")
    # Exclude TargetTransfers from main summary table
    $ReportData.GetEnumerator() | Where-Object {$_.Name -notin @('LogEntries', 'JobConfiguration', 'HookScripts', 'IsSimulationReport', '_PoShBackup_PSScriptRoot', 'TargetTransfers')} | ForEach-Object {
        $value = if ($_.Value -is [array]) { ($_.Value | ForEach-Object { $EscapeMarkdownTableContent.Invoke($_) }) -join '; ' } else { $EscapeMarkdownTableContent.Invoke($_.Value) }
        $null = $reportContent.AppendLine("| $($EscapeMarkdownTableContent.Invoke($_.Name).PadRight(25)) | $value |")
    }
    $null = $reportContent.AppendLine("")

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

    if ($ReportData.ContainsKey('HookScripts') -and $null -ne $ReportData.HookScripts -and $ReportData.HookScripts.Count -gt 0) {
        $null = $reportContent.AppendLine("## Hook Scripts Executed")
        $null = $reportContent.AppendLine("")
        $null = $reportContent.AppendLine("| Type    | Path                | Status  | Output/Error |")
        $null = $reportContent.AppendLine("| :------ | :------------------ | :------ | :----------- |")
        $ReportData.HookScripts | ForEach-Object {
            $hookPathEscaped = & $EscapeMarkdownTableContent $_.Path
            $hookOutputMd = if ([string]::IsNullOrWhiteSpace($_.Output)) {
                                "*(No output recorded)*"
                            } else {
                                # For Markdown, embed raw output in a fenced code block for pre-formatted text.
                                # Using HTML pre/code for potentially better rendering control by some Markdown viewers.
                                $escapedHtmlOutput = & $LocalConvertToSafeHtml $_.Output.TrimEnd()
                                $hookOutputMd = "<pre><code>$($escapedHtmlOutput)</code></pre>"
                            }
            $null = $reportContent.AppendLine("| $(& $EscapeMarkdownTableContent $_.Name) | $hookPathEscaped | **$(& $EscapeMarkdownTableContent $_.Status)** | $hookOutputMd |")
        }
        $null = $reportContent.AppendLine("")
    }

    # --- NEW: Remote Target Transfers Section ---
    if ($ReportData.ContainsKey('TargetTransfers') -and $null -ne $ReportData.TargetTransfers -and $ReportData.TargetTransfers.Count -gt 0) {
        $null = $reportContent.AppendLine("## Remote Target Transfers")
        $null = $reportContent.AppendLine("")
        $null = $reportContent.AppendLine("| Target Name | Type    | Status  | Remote Path         | Duration | Size   | Error Message |")
        $null = $reportContent.AppendLine("| :---------- | :------ | :------ | :------------------ | :------- | :----- | :------------ |")
        
        foreach ($transferEntry in $ReportData.TargetTransfers) {
            $targetNameMd = & $EscapeMarkdownTableContent $transferEntry.TargetName
            $targetTypeMd = & $EscapeMarkdownTableContent $transferEntry.TargetType
            $targetStatusMd = "**$(& $EscapeMarkdownTableContent $transferEntry.Status)**" # Bold status
            $remotePathMd = & $EscapeMarkdownTableContent $transferEntry.RemotePath
            $durationMd = & $EscapeMarkdownTableContent $transferEntry.TransferDuration
            $sizeFormattedMd = & $EscapeMarkdownTableContent $transferEntry.TransferSizeFormatted
            $errorMsgMd = if (-not [string]::IsNullOrWhiteSpace($transferEntry.ErrorMessage)) {
                              # For error messages in tables, replace newlines with <br> and escape pipes.
                              & $EscapeMarkdownTableContent $transferEntry.ErrorMessage
                          } else {
                              "*(N/A)*"
                          }
            
            $null = $reportContent.AppendLine("| $targetNameMd | $targetTypeMd | $targetStatusMd | $remotePathMd | $durationMd | $sizeFormattedMd | $errorMsgMd |")
        }
        $null = $reportContent.AppendLine("")
    }
    # --- END NEW: Remote Target Transfers Section ---

    if ($ReportData.ContainsKey('LogEntries') -and $null -ne $ReportData.LogEntries -and $ReportData.LogEntries.Count -gt 0) {
        $null = $reportContent.AppendLine("## Detailed Log")
        $null = $reportContent.AppendLine("")
        $ReportData.LogEntries | ForEach-Object {
            $logLine = "$($_.Timestamp) [$($_.Level.ToUpper())] $($_.Message)"
            # Using single quotes for the '`' character to ensure it's literal for PowerShell.
            $null = $reportContent.AppendLine(('```text')) # PowerShell syntax for literal triple backticks
            $null = $reportContent.AppendLine(($EscapeMarkdownCodeContent.Invoke($logLine)))
            $null = $reportContent.AppendLine(('```'))
            $null = $reportContent.AppendLine("")
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

# Remove the fallback ConvertTo-PoshBackupSafeHtmlInternal; $LocalConvertToSafeHtml is defined above.
# if (-not (Get-Command ConvertTo-PoshBackupSafeHtmlInternal -ErrorAction SilentlyContinue)) {
#    Function ConvertTo-PoshBackupSafeHtmlInternal { param([string]$Text) return $Text -replace '&', '&' -replace '<', '<' -replace '>', '>' -replace '"', '"' -replace "'", ''' }
# }

Export-ModuleMember -Function Invoke-MdReport
