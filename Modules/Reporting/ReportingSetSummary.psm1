# Modules\Reporting\ReportingSetSummary.psm1
<#
.SYNOPSIS
    Generates an HTML summary report for a completed PoSh-Backup Backup Set run.
.DESCRIPTION
    This module creates a high-level HTML summary report that shows the overall status of a
    backup set and provides a breakdown of the status for each individual job within that set.
    It populates the 'SetSummary.template.html' file with aggregated data collected
    during the set's execution.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    24-Jun-2025
    LastModified:   24-Jun-2025
    Purpose:        HTML summary report generation for Backup Sets.
    Prerequisites:  PowerShell 5.1+.
                    Called by the Reporting.psm1 orchestrator module.
#>

#region --- HTML Encode Helper Function Definition & Setup ---
$Script:PoshBackup_SetSummary_UseSystemWebHtmlEncode = $false
try {
    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
    $httpUtilityType = try { [System.Type]::GetType("System.Web.HttpUtility, System.Web, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a", $false) } catch { $null }
    if ($null -ne $httpUtilityType) { $Script:PoshBackup_SetSummary_UseSystemWebHtmlEncode = $true }
} catch {
    Write-Warning "[ReportingSetSummary.psm1] Error loading System.Web.dll. Using basic manual HTML sanitisation. Error: $($_.Exception.Message)"
}

Function ConvertTo-PoshBackupSetSummarySafeHtmlInternal {
    [CmdletBinding()] param([Parameter(Mandatory = $false, ValueFromPipeline=$true)][string]$Text)
    process {
        if ($null -eq $Text) { return '' }
        if ($Script:PoshBackup_SetSummary_UseSystemWebHtmlEncode) { try { return [System.Web.HttpUtility]::HtmlEncode($Text) } catch { return $Text -replace '&', '&' -replace '<', '<' -replace '>', '>' -replace '"', '"' -replace "'", '&#39;' } }
        else { return $Text -replace '&', '&' -replace '<', '<' -replace '>', '>' -replace '"', '"' -replace "'", '&#39;' }
    }
}
Set-Alias -Name ConvertTo-SafeHtmlForSet -Value ConvertTo-PoshBackupSetSummarySafeHtmlInternal -Scope Script -ErrorAction SilentlyContinue -Force
if (-not (Get-Alias ConvertTo-SafeHtmlForSet -ErrorAction SilentlyContinue)) { Write-Warning "[ReportingSetSummary.psm1] Critical: Failed to set 'ConvertTo-SafeHtmlForSet' alias." }
#endregion

#region --- Set Summary Report Function ---
function Invoke-SetSummaryReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ReportDirectory,
        [Parameter(Mandatory=$true)][hashtable]$SetReportData,
        [Parameter(Mandatory=$true)][hashtable]$GlobalConfig,
        [Parameter(Mandatory=$true)][scriptblock]$Logger
    )

    & $Logger -Message "ReportingSetSummary/Invoke-SetSummaryReport: Logger active for set '$($SetReportData.SetName)'." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$Msg, [string]$Lvl = "INFO") & $Logger -Message $Msg -Level $Lvl }

    $setName = $SetReportData.SetName
    & $LocalWriteLog -Msg "[INFO] Set Summary HTML Report generation process started for set '$setName'."

    $reportTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeSetNameForFile = $setName -replace '[^a-zA-Z0-9_-]', '_'
    $reportFileName = "SetSummary_$($safeSetNameForFile)_$($reportTimestamp).html"
    $reportFullPath = Join-Path -Path $ReportDirectory -ChildPath $reportFileName

    $mainScriptRoot = $GlobalConfig['_PoShBackup_PSScriptRoot']
    $moduleAssetsDir = Join-Path -Path $mainScriptRoot -ChildPath "Modules\Reporting\Assets"
    $htmlTemplateFilePath = Join-Path -Path $moduleAssetsDir -ChildPath "SetSummary.template.html"

    try {
        $htmlTemplateContent = Get-Content -LiteralPath $htmlTemplateFilePath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($htmlTemplateContent)) { throw "HTML template content is empty." }

        $getReportSetting = { param($Key, $Default) $val = if ($GlobalConfig.ContainsKey($Key)) { $GlobalConfig[$Key] }; if ($null -eq $val) { $Default } else { $val } }
        
        # --- Load Assets & Settings ---
        $cssContent = (Get-Content (Join-Path $mainScriptRoot "Config\Themes\Base.css") -Raw) + (Get-Content (Join-Path $mainScriptRoot "Config\Themes\Dark.css") -Raw)
        $jsContent = Get-Content (Join-Path $moduleAssetsDir "ReportingHtml.Client.js") -Raw
        $embeddedLogoHtml = ""
        if (-not [string]::IsNullOrWhiteSpace($getReportSetting.Invoke('HtmlReportLogoPath', ""))) {
            try {
                $logoBytes = [System.IO.File]::ReadAllBytes($getReportSetting.Invoke('HtmlReportLogoPath', ""))
                $logoB64 = [System.Convert]::ToBase64String($logoBytes)
                $logoMime = switch ([System.IO.Path]::GetExtension($getReportSetting.Invoke('HtmlReportLogoPath', "")).ToLowerInvariant()) { ".png"{"image/png"} ".jpg"{"image/jpeg"} ".svg"{"image/svg+xml"} default {""} }
                if ($logoMime) { $embeddedLogoHtml = "<img src='data:$($logoMime);base64,$($logoB64)' alt='Report Logo' class='report-logo'>" }
            } catch { & $LocalWriteLog "Error embedding logo: $($_.Exception.Message)" "WARNING" }
        }
        
        # --- Build HTML Fragments ---
        $sbJobRows = [System.Text.StringBuilder]::new()
        foreach ($jobResult in $SetReportData.JobResults) {
            $jobNameHtml = ConvertTo-SafeHtmlForSet $jobResult.JobName
            $statusHtml = ConvertTo-SafeHtmlForSet $jobResult.Status
            $statusClass = "status-$(($jobResult.Status -replace ' ','_')-replace '[\(\):\/]','_'-replace '\+','plus')"
            $durationHtml = ConvertTo-SafeHtmlForSet ($jobResult.Duration.ToString('g').Split('.')[0])
            $sizeHtml = ConvertTo-SafeHtmlForSet $jobResult.ArchiveSizeFormatted
            $errorHtml = if ([string]::IsNullOrWhiteSpace($jobResult.ErrorMessage)) { "<em>N/A</em>" } else { ConvertTo-SafeHtmlForSet $jobResult.ErrorMessage }
            
            $sizeSortAttr = "data-sort-value='$($jobResult.ArchiveSizeBytes)'"
            $durationSortAttr = "data-sort-value='$($jobResult.Duration.TotalSeconds)'"

            $null = $sbJobRows.Append("<tr><td data-label='Job Name'>$jobNameHtml</td><td data-label='Status' class='$statusClass'>$statusHtml</td><td data-label='Duration' $durationSortAttr>$durationHtml</td><td data-label='Archive Size' $sizeSortAttr>$sizeHtml</td><td data-label='Error Message'>$errorHtml</td></tr>")
        }

        # --- Populate Template ---
        $finalHtml = $htmlTemplateContent -replace '\{\{SET_NAME\}\}', (ConvertTo-SafeHtmlForSet $setName) `
                               -replace '\{\{REPORT_TITLE\}\}', (ConvertTo-SafeHtmlForSet "PoSh Backup Set Summary - $setName") `
                               -replace '\{\{HTML_META_TAGS\}\}', '<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">' `
                               -replace '\{\{FAVICON_LINK_TAG\}\}', '' `
                               -replace '\{\{CSS_CONTENT\}\}', "<style>$cssContent</style>" `
                               -replace '\{\{HTML_BODY_TAG\}\}', '<body data-initial-theme="dark">' `
                               -replace '\{\{JAVASCRIPT_CONTENT_BLOCK\}\}', "<script>$jsContent</script>" `
                               -replace '\{\{SIMULATION_BANNER_HTML\}\}', (if ($SetReportData.IsSimulated) { "<div class='simulation-banner'><strong>*** SIMULATION MODE RUN ***</strong></div>" } else { "" }) `
                               -replace '\{\{HEADER_TITLE_TEXT\}\}', (ConvertTo-SafeHtmlForSet "Backup Set Summary: $setName") `
                               -replace '\{\{EMBEDDED_LOGO_HTML\}\}', $embeddedLogoHtml `
                               -replace '\{\{OVERALL_SET_STATUS\}\}', (ConvertTo-SafeHtmlForSet $SetReportData.OverallStatus) `
                               -replace '\{\{OVERALL_SET_STATUS_CLASS\}\}', "status-$(($SetReportData.OverallStatus -replace ' ','_')-replace '[\(\):\/]','_'-replace '\+','plus')" `
                               -replace '\{\{TOTAL_SET_DURATION\}\}', ($SetReportData.TotalDuration.ToString('g').Split('.')[0]) `
                               -replace '\{\{START_TIME\}\}', ($SetReportData.StartTime | Get-Date -Format 'o') `
                               -replace '\{\{END_TIME\}\}', ($SetReportData.EndTime | Get-Date -Format 'o') `
                               -replace '\{\{JOB_SUMMARY_TABLE_ROWS_HTML\}\}', $sbJobRows.ToString() `
                               -replace '\{\{FOOTER_COMPANY_NAME_HTML\}\}', (ConvertTo-SafeHtmlForSet ($getReportSetting.Invoke('HtmlReportCompanyName', "PoSh Backup"))) `
                               -replace '\{\{REPORT_GENERATION_DATE_TEXT\}\}', (Get-Date)
        
        # --- Save Final HTML ---
        Set-Content -Path $reportFullPath -Value $finalHtml -Encoding UTF8 -Force -ErrorAction Stop
        & $LocalWriteLog -Message "  - Set Summary HTML report generated successfully: '$reportFullPath'" -Level "SUCCESS"

    } catch {
        & $LocalWriteLog -Message "[ERROR] Failed to generate Set Summary HTML report '$reportFullPath'. Error: $($_.Exception.Message)" -Level "ERROR"
    }
}
#endregion

Export-ModuleMember -Function Invoke-SetSummaryReport
