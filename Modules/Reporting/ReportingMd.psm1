<#
.SYNOPSIS
    Generates Markdown (.md) formatted reports for PoSh-Backup jobs, offering a human-readable
    plain text format that can also be rendered into rich HTML by Markdown processors,
    suitable for documentation or version control.
.DESCRIPTION
    This module creates reports using Markdown syntax. The output includes structured sections
    for summary, configuration, hook scripts, and detailed logs, utilizing Markdown tables,
    code blocks, and headings for clear presentation when rendered.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.6 (Removed PSSA attribute suppression; trailing whitespace removed)
    DateCreated:    14-May-2025
    LastModified:   15-May-2025
    Purpose:        Markdown report generation for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+. Called by Reporting.psm1 (orchestrator).
#>

function Invoke-MdReport {
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

    $EscapeMarkdownTableContent = {
        param($Content)
        if ($null -eq $Content) { return "" }
        return $Content.ToString() -replace '\|', '\|' -replace '\r?\n', '<br>'
    }

    $EscapeMarkdownCodeContent = {
        param($Content)
        if ($null -eq $Content) { return "" }
        return $Content.ToString()
    }

    & $LocalWriteLog -Message "[INFO] Markdown Report generation started for job '$JobName'." -Level "INFO"

    $reportTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeJobNameForFile = $JobName -replace '[^a-zA-Z0-9_-]', '_'
    $reportFileName = "$($safeJobNameForFile)_Report_$($reportTimestamp).md"
    $reportFullPath = Join-Path -Path $ReportDirectory -ChildPath $reportFileName

    $reportContent = [System.Text.StringBuilder]::new()

    $titlePrefix = "PoSh Backup Status Report"
    $null = $reportContent.AppendLine("# $($titlePrefix) - $JobName")
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
    $ReportData.GetEnumerator() | Where-Object {$_.Name -notin @('LogEntries', 'JobConfiguration', 'HookScripts', 'IsSimulationReport')} | ForEach-Object {
        $value = if ($_.Value -is [array]) { ($_.Value | ForEach-Object { $EscapeMarkdownTableContent.Invoke($_) }) -join '; ' } else { $EscapeMarkdownTableContent.Invoke($_.Value) }
        $null = $reportContent.AppendLine("| $($_.Name.PadRight(25)) | $value |")
    }
    $null = $reportContent.AppendLine("")

    if ($ReportData.ContainsKey('JobConfiguration') -and $null -ne $ReportData.JobConfiguration) {
        $null = $reportContent.AppendLine("## Configuration Used for Job '$JobName'")
        $null = $reportContent.AppendLine("")
        $null = $reportContent.AppendLine("| Setting                   | Value |")
        $null = $reportContent.AppendLine("| :------------------------ | :---- |")
        $ReportData.JobConfiguration.GetEnumerator() | Sort-Object Name | ForEach-Object {
            $value = if ($_.Value -is [array]) { ($_.Value | ForEach-Object { $EscapeMarkdownTableContent.Invoke($_) }) -join '; ' } else { $EscapeMarkdownTableContent.Invoke($_.Value) }
            $null = $reportContent.AppendLine("| $($_.Name.PadRight(25)) | $value |")
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
                                "*(No output)*"
                            } else {
                                $escapedOutputForTable = ($_.Output.TrimEnd() -replace '\|', '\|' -replace '\r?\n', '<br/>')
                                "<pre><code>$($escapedOutputForTable)</code></pre>"
                            }
            $null = $reportContent.AppendLine("| $(& $EscapeMarkdownTableContent $_.Name) | $hookPathEscaped | **$(& $EscapeMarkdownTableContent $_.Status)** | $hookOutputMd |")
        }
        $null = $reportContent.AppendLine("")
    }

    if ($ReportData.ContainsKey('LogEntries') -and $null -ne $ReportData.LogEntries -and $ReportData.LogEntries.Count -gt 0) {
        $null = $reportContent.AppendLine("## Detailed Log")
        $null = $reportContent.AppendLine("")
        $ReportData.LogEntries | ForEach-Object {
            $logLine = "$($_.Timestamp) [$($_.Level.ToUpper())] $($_.Message)"
            $null = $reportContent.AppendLine('```')
            $null = $reportContent.AppendLine(($EscapeMarkdownCodeContent.Invoke($logLine)))
            $null = $reportContent.AppendLine('```')
            $null = $reportContent.AppendLine("")
        }
    }

    try {
        Set-Content -Path $reportFullPath -Value $reportContent.ToString() -Encoding UTF8 -Force
        & $LocalWriteLog -Message "  - Markdown report generated: $reportFullPath" -Level "SUCCESS"
    } catch {
         & $LocalWriteLog -Message "[ERROR] Failed to generate Markdown report '$reportFullPath'. Error: $($_.Exception.Message)" -Level "ERROR"
    }
}

Export-ModuleMember -Function Invoke-MdReport
