# Modules\Reporting\ReportingHtml.psm1
<#
.SYNOPSIS
    Generates detailed, interactive HTML reports for PoSh-Backup jobs by acting as a facade
    and orchestrating calls to specialised sub-modules.
.DESCRIPTION
    This module creates rich HTML reports by orchestrating calls to its sub-modules, which
    handle the details of asset loading, HTML fragment generation, and final assembly.

    This facade approach keeps this module clean and focused on the high-level process,
    while the complex logic is managed by the sub-modules in '.\ReportingHtml\'.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        3.0.0 # Major refactoring into a facade with sub-modules.
    DateCreated:    28-Jun-2025
    LastModified:   28-Jun-2025
    Purpose:        Facade for interactive HTML report generation.
    Prerequisites:  PowerShell 5.1+.
                    Sub-modules must exist in '.\Modules\Reporting\ReportingHtml\'.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Reporting\
$htmlSubModulePath = Join-Path -Path $PSScriptRoot -ChildPath "ReportingHtml"
try {
    Import-Module -Name (Join-Path -Path $htmlSubModulePath -ChildPath "AssetLoader.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $htmlSubModulePath -ChildPath "HtmlFragmentGenerator.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $htmlSubModulePath -ChildPath "ReportAssembler.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "ReportingHtml.psm1 (Facade) FATAL: Could not import a required sub-module. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Invoke-HtmlReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ReportDirectory,
        [Parameter(Mandatory=$true)][string]$JobName,
        [Parameter(Mandatory=$true)][hashtable]$ReportData,
        [Parameter(Mandatory=$true)][hashtable]$GlobalConfig,
        [Parameter(Mandatory=$true)][hashtable]$JobConfig,
        [Parameter(Mandatory=$true)][scriptblock]$Logger
    )

    $LocalWriteLog = { param([string]$Msg, [string]$Lvl = "INFO") & $Logger -Message $Msg -Level $Lvl }
    & $LocalWriteLog -Msg "ReportingHtml (Facade): Orchestrating HTML report generation for job '$JobName'." -Lvl "DEBUG"

    try {
        $getReportSetting = { param($Key, $Default) $val = $null; if ($null -ne $JobConfig -and $JobConfig.ContainsKey($Key)) { $val = $JobConfig[$Key] } elseif ($GlobalConfig.ContainsKey($Key)) { $val = $GlobalConfig[$Key] }; if ($null -eq $val) { $Default } else { $val } }
        
        $reportTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $safeJobNameForFile = $JobName -replace '[^a-zA-Z0-9_-]', '_'
        $reportFileName = "$($safeJobNameForFile)_Report_$($reportTimestamp).html"
        $reportFullPath = Join-Path -Path $ReportDirectory -ChildPath $reportFileName

        # 1. Load Assets
        $themeNameRaw = $getReportSetting.Invoke('HtmlReportTheme', "Light")
        $themeName = if ($themeNameRaw -is [array]) { $themeNameRaw[0] } else { $themeNameRaw }; if ([string]::IsNullOrWhiteSpace($themeName)) { $themeName = "Light" }
        
        $cssOverrides = @{}; ($GlobalConfig.HtmlReportOverrideCssVariables, $JobConfig.HtmlReportOverrideCssVariables | Where-Object {$null -ne $_ -and $_ -is [hashtable]}) | ForEach-Object { $_.GetEnumerator() | ForEach-Object { $cssOverrides[$_.Name] = $_.Value } }

        $assets = Get-HtmlReportAssets -PSScriptRoot $GlobalConfig['_PoShBackup_PSScriptRoot'] `
            -ThemeName $themeName `
            -LogoPath ($getReportSetting.Invoke('HtmlReportLogoPath', "")) `
            -FaviconPath ($getReportSetting.Invoke('HtmlReportFaviconPath', "")) `
            -CustomCssPath ($getReportSetting.Invoke('HtmlReportCustomCssPath', "")) `
            -Logger $Logger
        
        # 2. Generate HTML Fragments
        $fragments = @{
            SimulationBannerHtml               = if ($ReportData.IsSimulationReport) { "<div class='simulation-banner'><strong>*** SIMULATION MODE RUN ***</strong> This report reflects a simulated backup. No actual files were changed or archives created.</div>" } else { "" }
            SUMMARY_TABLE_ROWS_HTML            = Get-SummaryTableRowsHtml -ReportData $ReportData
            TARGET_TRANSFERS_TABLE_ROWS_HTML   = Get-TargetTransfersTableRowsHtml -TargetTransfers $ReportData.TargetTransfers
            CONFIG_TABLE_ROWS_HTML             = Get-ConfigTableRowsHtml -JobConfiguration $ReportData.JobConfiguration
            HOOKS_TABLE_ROWS_HTML              = Get-HooksTableRowsHtml -HookScripts $ReportData.HookScripts
        }
        $logFragments = Get-LogEntriesSectionHtml -LogEntries $ReportData.LogEntries
        $fragments.LOG_LEVEL_FILTERS_CONTROLS_HTML = $logFragments.FilterControlsHtml
        $fragments.LOG_ENTRIES_LIST_HTML = $logFragments.LogEntriesListHtml

        $manifestFragments = Get-ManifestDetailsSectionHtml -ReportData $ReportData
        $fragments.MANIFEST_FILE_PATH_HTML = $manifestFragments.FilePath
        $fragments.MANIFEST_OVERALL_STATUS_HTML = $manifestFragments.OverallStatus
        $fragments.MANIFEST_OVERALL_STATUS_CLASS = $manifestFragments.OverallStatusClass
        $fragments.MANIFEST_VOLUMES_TABLE_ROWS_HTML = $manifestFragments.VolumesTableRows
        $fragments.MANIFEST_RAW_DETAILS_HTML = $manifestFragments.RawDetails

        # 3. Prepare Metadata for Assembler
        $titlePrefix = [string]($getReportSetting.Invoke('HtmlReportTitlePrefix', "PoSh Backup Status Report"))
        $companyName = [string]($getReportSetting.Invoke('HtmlReportCompanyName', ""))

        $reportMetadata = @{
            Title                   = ("{0} - {1}" -f $titlePrefix, $JobName)
            JobName                 = $JobName
            InitialTheme            = $themeName.ToLowerInvariant()
            HeaderTitleText         = ("{0} - {1}" -f $titlePrefix, $JobName)
            FooterCompanyNameHtml   = if (-not [string]::IsNullOrWhiteSpace($companyName)) { $companyName + " - " } else { "" }
            CssVariableOverrides    = $cssOverrides
            ConditionalSections     = @{
                # CORRECTED: Keys are now the base name, matching the assembler's logic.
                SUMMARY           = [bool]($getReportSetting.Invoke('HtmlReportShowSummary', $true) -and $ReportData.ContainsKey('OverallStatus'))
                TARGET_TRANSFERS  = [bool]($ReportData.ContainsKey('TargetTransfers') -and $ReportData.TargetTransfers.Count -gt 0)
                CONFIG            = [bool]($getReportSetting.Invoke('HtmlReportShowConfiguration', $true) -and $ReportData.ContainsKey('JobConfiguration') -and $null -ne $ReportData.JobConfiguration)
                HOOKS             = [bool]($getReportSetting.Invoke('HtmlReportShowHooks', $true) -and $ReportData.ContainsKey('HookScripts') -and $ReportData.HookScripts.Count -gt 0)
                MANIFEST_DETAILS  = [bool]($manifestFragments.ShowSection)
                MANIFEST_VOLUMES_TABLE = [bool]($manifestFragments.ShowVolumesTable)
                MANIFEST_RAW_DETAILS   = [bool]($manifestFragments.ShowRawDetails)
                LOG_ENTRIES       = [bool]($getReportSetting.Invoke('HtmlReportShowLogEntries', $true) -and $ReportData.ContainsKey('LogEntries') -and $ReportData.LogEntries.Count -gt 0)
                NO_LOG_ENTRIES    = [bool]($getReportSetting.Invoke('HtmlReportShowLogEntries', $true) -and (-not ($ReportData.ContainsKey('LogEntries') -and $ReportData.LogEntries.Count -gt 0)))
            }
        }
        
        # 4. Assemble and Save
        Invoke-HtmlReportAssembly -ReportFullPath $reportFullPath -Assets $assets -Fragments $fragments -ReportMetadata $reportMetadata -Logger $Logger
    }
    catch {
        & $LocalWriteLog -Msg "[ERROR] ReportingHtml (Facade): A critical error occurred during report generation for job '$JobName'. Error: $($_.Exception.Message)" -Lvl "ERROR"
    }
}

Export-ModuleMember -Function Invoke-HtmlReport
