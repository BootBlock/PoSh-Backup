# Modules\Reporting\ReportingHtml\ReportAssembler.psm1
<#
.SYNOPSIS
    A sub-module for ReportingHtml.psm1. Assembles the final HTML report from its components.
.DESCRIPTION
    This module provides the 'Invoke-HtmlReportAssembly' function. Its responsibility is to
    take the main HTML template, a collection of static assets (like CSS and JS content), and
    a hashtable of dynamically generated HTML fragments, and then perform all the string
    replacements necessary to construct the final, complete HTML document. It then saves
    this document to the specified output path.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.3
    DateCreated:    28-Jun-2025
    LastModified:   28-Jun-2025
    Purpose:        To assemble and save the final HTML report.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Reporting\ReportingHtml
try {
    Import-Module -Name (Join-Path $PSScriptRoot "HtmlUtils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "ReportAssembler.psm1 FATAL: Could not import a dependent module. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Invoke-HtmlReportAssembly {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReportFullPath,
        [Parameter(Mandatory = $true)]
        [hashtable]$Assets, # Contains HtmlTemplateContent, CSS, JS, etc.
        [Parameter(Mandatory = $true)]
        [hashtable]$Fragments, # Contains HTML fragments for summary, logs, etc.
        [Parameter(Mandatory = $true)]
        [hashtable]$ReportMetadata, # Contains Title, CompanyName, etc.
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "ReportAssembler: Assembling final HTML report for '$ReportFullPath'." -Level "DEBUG" -ErrorAction SilentlyContinue

    try {
        # Start with the main template
        $finalHtml = $Assets.HtmlTemplateContent
        
        # Inject static assets and metadata
        $cssVariableOverridesStyleBlock = ""
        if ($ReportMetadata.CssVariableOverrides.Count -gt 0) {
            $sbCssVar = [System.Text.StringBuilder]::new("<style>:root {")
            $ReportMetadata.CssVariableOverrides.GetEnumerator() | ForEach-Object {
                $varN = $_.Name; if (-not $varN.StartsWith("--")) { $varN = "--" + $varN }
                $null = $sbCssVar.Append("$varN : $($_.Value) ;")
            }
            $null = $sbCssVar.Append("}</style>")
            $cssVariableOverridesStyleBlock = $sbCssVar.ToString()
        }
        
        $finalCssToInject = "<style>" + $Assets.BaseCssContent + $Assets.ThemeCssContent + $Assets.DarkThemeCssContent + "</style>" + $cssVariableOverridesStyleBlock + "<style>" + $Assets.CustomCssContent + "</style>"
        $pageJavaScriptBlock = "<script>" + $Assets.JsContent + "</script>"

        # Sanitise metadata just before injection
        $safeReportTitle = ConvertTo-PoshBackupSafeHtmlInternal -Text $ReportMetadata.Title
        $safeHeaderTitleText = ConvertTo-PoshBackupSafeHtmlInternal -Text $ReportMetadata.HeaderTitleText
        if ($ReportMetadata.HeaderTitleText -match "retro") { $safeHeaderTitleText += "<span class='blinking-cursor'></span>" }
        $safeFooterCompanyName = ConvertTo-PoshBackupSafeHtmlInternal -Text $ReportMetadata.FooterCompanyNameHtml
        $safeJobName = ConvertTo-PoshBackupSafeHtmlInternal -Text $ReportMetadata.JobName
        
        # Use single-quoted strings for literal parts of the regex pattern
        $finalHtml = $finalHtml -replace '\{\{REPORT_TITLE\}\}', $safeReportTitle `
                               -replace '\{\{HTML_META_TAGS\}\}', '<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">' `
                               -replace '\{\{FAVICON_LINK_TAG\}\}', $Assets.FaviconLinkTag `
                               -replace '\{\{CSS_CONTENT\}\}', $finalCssToInject `
                               -replace '\{\{HTML_BODY_TAG\}\}', ('<body data-initial-theme="{0}">' -f $ReportMetadata.InitialTheme) `
                               -replace '\{\{SIMULATION_BANNER_HTML\}\}', $Fragments.SimulationBannerHtml `
                               -replace '\{\{HEADER_TITLE_TEXT\}\}', $safeHeaderTitleText `
                               -replace '\{\{EMBEDDED_LOGO_HTML\}\}', $Assets.EmbeddedLogoHtml `
                               -replace '\{\{JOB_NAME_FOR_HEADER\}\}', $safeJobName `
                               -replace '\{\{FOOTER_COMPANY_NAME_HTML\}\}', $safeFooterCompanyName `
                               -replace '\{\{REPORT_GENERATION_DATE_TEXT\}\}', (Get-Date) `
                               -replace '\{\{JAVASCRIPT_CONTENT_BLOCK\}\}', $pageJavaScriptBlock

        # Inject dynamic fragments
        foreach ($key in $Fragments.Keys) {
            # --- CORRECTED REGEX PATTERN CONSTRUCTION ---
            # Use single-quoted literals concatenated with the key to avoid parsing ambiguity.
            $placeholderRegex = '\{\{' + $key + '\}\}'
            $finalHtml = $finalHtml -replace $placeholderRegex, $Fragments[$key]
        }

        # Handle conditional sections (IF_..._START/END placeholders)
        foreach ($key in $ReportMetadata.ConditionalSections.Keys) {
            $showSection = $ReportMetadata.ConditionalSections[$key]
            
            # Use the same robust pattern construction here.
            $startPlaceholderRegex = '\{\{IF_SHOW_' + $key + '_START\}\}'
            $endPlaceholderRegex = '\{\{IF_SHOW_' + $key + '_END\}\}'
            
            if ($showSection) {
                # Just remove the placeholder tags, leaving the content between them.
                $finalHtml = $finalHtml -replace $startPlaceholderRegex, "" -replace $endPlaceholderRegex, ""
            } else {
                # Remove the entire block including the tags and all content (including newlines) between them.
                $regexToRemoveBlock = '(?s)' + $startPlaceholderRegex + '.*?' + $endPlaceholderRegex
                $finalHtml = $finalHtml -replace $regexToRemoveBlock, ""
            }
        }
        
        # Save the final file
        Set-Content -Path $ReportFullPath -Value $finalHtml -Encoding UTF8 -Force -ErrorAction Stop
        & $Logger -Message "  - ReportAssembler: Final HTML report saved successfully to '$ReportFullPath'." -Level "SUCCESS"

    } catch {
        & $Logger -Message "[ERROR] ReportAssembler: Failed to assemble and save HTML report '$ReportFullPath'. Error: $($_.Exception.Message)" -Level "ERROR"
    }
}

Export-ModuleMember -Function Invoke-HtmlReportAssembly
