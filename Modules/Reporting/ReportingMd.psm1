# PowerShell Module: ReportingMd.psm1
# Description: Generates Markdown reports for PoSh-Backup.
# Version: 1.1 (Corrected syntax in Hook Scripts section)

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
        [hashtable]$GlobalConfig,
        [Parameter(Mandatory=$true)] 
        [hashtable]$JobConfig,
        [Parameter(Mandatory=$false)]
        [scriptblock]$Logger = $null
    )
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour = $Global:ColourInfo)
        if ($null -ne $Logger) { & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour } 
        else { Write-Host "[$Level] (ReportingMdDirect) $Message" }
    }

    $EscapeMarkdownTableContent = {
        param($Content)
        if ($null -eq $Content) { return "" }
        return $Content.ToString() -replace '\|', '\|' -replace '\r?\n', '<br>' 
    }

    & $LocalWriteLog -Message "[INFO] Markdown Report generation started for job '$JobName'." -Level "INFO"
        
    $reportTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeJobNameForFile = $JobName -replace '[^a-zA-Z0-9_-]', '_' 
    $reportFileName = "$($safeJobNameForFile)_Report_$($reportTimestamp).md"
    $reportFullPath = Join-Path -Path $ReportDirectory -ChildPath $reportFileName

    $reportContent = [System.Text.StringBuilder]::new()
    
    $titlePrefix = Get-ConfigValue -ConfigObject $JobConfig -Key 'HtmlReportTitlePrefix' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'HtmlReportTitlePrefix' -DefaultValue "PoSh Backup Status Report")
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
        } # CORRECTED: Missing closing } was here in the image, but my generated code was okay. Adding it for safety if it was a copy-paste error from my side before.
        $null = $reportContent.AppendLine("")
    }

    # Hook Scripts Section
    if ($ReportData.ContainsKey('HookScripts') -and $null -ne $ReportData.HookScripts -and $ReportData.HookScripts.Count -gt 0) { # CORRECTED: Added closing parenthesis here
        $null = $reportContent.AppendLine("## Hook Scripts Executed")
        $null = $reportContent.AppendLine("")
        $null = $reportContent.AppendLine("| Type    | Path                | Status  | Output/Error |")
        $null = $reportContent.AppendLine("| :------ | :------------------ | :------ | :----------- |")
        $ReportData.HookScripts | ForEach-Object {
            # CORRECTED: $output logic and string interpolation for the table row
            $outputMd = if ([string]::IsNullOrWhiteSpace($_.Output)) { 
                            "*(No output)*" 
                        } else { 
                            # For multi-line output, ensure it's treated as a single cell content, then wrap in code block
                            $escapedOutput = ($_.Output.TrimEnd() -replace '\|', '\|' -replace '\r?\n', '<br/>')
                            "<pre><code>$($escapedOutput)</code></pre>" # Using pre/code for better block display
                        }
            $null = $reportContent.AppendLine("| $(& $EscapeMarkdownTableContent $_.Name) | `$(& $EscapeMarkdownTableContent $_.Path)` | **$(& $EscapeMarkdownTableContent $_.Status)** | $outputMd |")
        } # Closing ForEach-Object
        $null = $reportContent.AppendLine("")
    } # Closing if for HookScripts

    if ($ReportData.ContainsKey('LogEntries') -and $null -ne $ReportData.LogEntries -and $ReportData.LogEntries.Count -gt 0) {
        $null = $reportContent.AppendLine("## Detailed Log")
        $null = $reportContent.AppendLine("")
        $ReportData.LogEntries | ForEach-Object {
            $null = $reportContent.AppendLine("`$($_.Timestamp) [$($_.Level.ToUpper())] $($_.Message)") 
        }
        $null = $reportContent.AppendLine("")
    }
    
    try {
        Set-Content -Path $reportFullPath -Value $reportContent.ToString() -Encoding UTF8 -Force
        & $LocalWriteLog -Message "  - Markdown report generated: $reportFullPath" -ForegroundColour $Global:ColourSuccess
    } catch {
         & $LocalWriteLog -Message "[ERROR] Failed to generate Markdown report '$reportFullPath'. Error: $($_.Exception.Message)" -Level "ERROR" -ForegroundColour $Global:ColourError
    }
}

Export-ModuleMember -Function Invoke-MdReport
