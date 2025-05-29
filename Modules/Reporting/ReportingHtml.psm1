<#
.SYNOPSIS
    Generates detailed, interactive HTML reports for PoSh-Backup jobs by populating an external HTML template.
    Features customisable themes, CSS overrides, embedded logos, client-side JavaScript for interactivity.
    Includes sections for Remote Target Transfers, archive checksum information, and split volume size if applicable.

.DESCRIPTION
    This module creates rich HTML reports by dynamically populating a comprehensive external HTML template
    ('Assets/ReportingHtml.template.html'). Client-side JavaScript is also loaded externally
    ('Assets/ReportingHtml.Client.js').

    The PowerShell script focuses on:
    - Loading the HTML template, CSS, and JavaScript.
    - Processing the backup job's $ReportData.
    - Generating only the dynamic HTML fragments (like table rows, list items) needed for each section.
    - Injecting these fragments, along with other dynamic values (title, CSS, JS), into placeholders
      within the HTML template.
    - Conditionally including or excluding entire report sections based on configuration and data availability
      by manipulating specific placeholders in the template.

    This approach makes the PowerShell module significantly leaner and allows for extensive
    customisation of the report's structure and appearance directly through the HTML template file.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.9.11 # Added SplitVolumeSize to Summary table.
    DateCreated:    14-May-2025
    LastModified:   29-May-2025
    Purpose:        Interactive HTML report generation by populating an external template.
    Prerequisites:  PowerShell 5.1+.
                    Called by the main Reporting.psm1 orchestrator module.
                    'Assets\ReportingHtml.template.html', 'Assets\ReportingHtml.Client.js',
                    'Base.css', and theme CSS files must be correctly located.
                    The 'System.Web' assembly is beneficial for enhanced HTML encoding.
#>

#region --- HTML Encode Helper Function Definition & Setup ---
$Script:PoshBackup_ReportingHtml_UseSystemWebHtmlEncode = $false
try {
    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
    $httpUtilityType = try { [System.Type]::GetType("System.Web.HttpUtility, System.Web, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a", $false) } catch { $null }
    if ($null -ne $httpUtilityType) { $Script:PoshBackup_ReportingHtml_UseSystemWebHtmlEncode = $true }
    else { Write-Warning "[ReportingHtml.psm1] System.Web.HttpUtility class not found. Using basic manual HTML sanitisation." }
} catch { Write-Warning "[ReportingHtml.psm1] Error loading System.Web.dll. Using basic manual HTML sanitisation. Error: $($_.Exception.Message)" }

Function ConvertTo-PoshBackupSafeHtmlInternal {
    [CmdletBinding()] param([Parameter(Mandatory = $false, ValueFromPipeline=$true)][string]$Text)
    process {
        if ($null -eq $Text) { return '' }
        if ($Script:PoshBackup_ReportingHtml_UseSystemWebHtmlEncode) { try { return [System.Web.HttpUtility]::HtmlEncode($Text) } catch { return $Text -replace '&', '&' -replace '<', '<' -replace '>', '>' -replace '"', '"' -replace "'", '&#39;' } }
        else { return $Text -replace '&', '&' -replace '<', '<' -replace '>', '>' -replace '"', '"' -replace "'", '&#39;' }
    }
}
Set-Alias -Name ConvertTo-SafeHtml -Value ConvertTo-PoshBackupSafeHtmlInternal -Scope Script -ErrorAction SilentlyContinue -Force
if (-not (Get-Alias ConvertTo-SafeHtml -ErrorAction SilentlyContinue)) { Write-Warning "[ReportingHtml.psm1] Critical: Failed to set 'ConvertTo-SafeHtml' alias." }
#endregion

#region --- HTML Report Function ---
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

    # PSSA Appeasement: Directly use the Logger parameter once in the main function body.
    & $Logger -Message "Invoke-HtmlReport: Logger parameter active for job '$JobName'." -Level "DEBUG" -ErrorAction SilentlyContinue

    # Define the helper function
    function LocalWriteLogHelper {
        param([string]$Msg, [string]$Lvl = "INFO", [string]$FGColor)
        # $Logger is available from the parent Invoke-HtmlReport's scope
        if (-not [string]::IsNullOrWhiteSpace($FGColor)) {
            & $Logger -Message $Msg -Level $Lvl -ForegroundColour $FGColor
        } else {
            & $Logger -Message $Msg -Level $Lvl
        }
    }
    
    # Removed: LocalWriteLogHelper -Msg "Invoke-HtmlReport: Logger active for job '$JobName'." -Lvl "DEBUG" 
    # The direct call above now serves this purpose for PSSA and initial logging.
    LocalWriteLogHelper -Msg "Invoke-HtmlReport: Starting HTML report generation for job '$JobName'." -Lvl "DEBUG"

    $getReportSetting = { param($Key, $Default) $val = $null; if ($null -ne $JobConfig -and $JobConfig.ContainsKey($Key)) { $val = $JobConfig[$Key] } elseif ($GlobalConfig.ContainsKey($Key)) { $val = $GlobalConfig[$Key] }; if ($null -eq $val) { return $Default } else { return $val } }

    $reportTitlePrefix = ConvertTo-SafeHtml ($getReportSetting.Invoke('HtmlReportTitlePrefix', "PoSh Backup Status Report"))
    $reportLogoPath = $getReportSetting.Invoke('HtmlReportLogoPath', "")
    $reportFaviconPathUser = $getReportSetting.Invoke('HtmlReportFaviconPath', "")
    $reportCustomCssPathUser = $getReportSetting.Invoke('HtmlReportCustomCssPath', "")
    $reportCompanyName = ConvertTo-SafeHtml ($getReportSetting.Invoke('HtmlReportCompanyName', "PoSh Backup"))
    $reportThemeNameRaw = $getReportSetting.Invoke('HtmlReportTheme', "Light")
    $reportThemeName = if ($reportThemeNameRaw -is [array]) { $reportThemeNameRaw[0] } else { $reportThemeNameRaw }; if ([string]::IsNullOrWhiteSpace($reportThemeName)) { $reportThemeName = "Light" }
    
    $cssVariableOverrides = @{}; ($GlobalConfig.HtmlReportOverrideCssVariables, $JobConfig.HtmlReportOverrideCssVariables | Where-Object {$null -ne $_ -and $_ -is [hashtable]}) | ForEach-Object { $_.GetEnumerator() | ForEach-Object { $cssVariableOverrides[$_.Name] = $_.Value } }
    
    $reportShowSummary = $getReportSetting.Invoke('HtmlReportShowSummary', $true)
    $reportShowConfiguration = $getReportSetting.Invoke('HtmlReportShowConfiguration', $true)
    $reportShowHooks = $getReportSetting.Invoke('HtmlReportShowHooks', $true)
    $reportShowLogEntries = $getReportSetting.Invoke('HtmlReportShowLogEntries', $true)
    $reportShowTargetTransfers = $true

    if (-not (Test-Path -Path $ReportDirectory -PathType Container)) { LocalWriteLogHelper -Msg "[ERROR] HTML Report output directory '$ReportDirectory' does not exist for job '$JobName'. Aborting report." -Lvl "ERROR"; return }
    $reportTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"; $safeJobNameForFile = $JobName -replace '[^a-zA-Z0-9_-]', '_'; $reportFileName = "$($safeJobNameForFile)_Report_$($reportTimestamp).html"; $reportFullPath = Join-Path -Path $ReportDirectory -ChildPath $reportFileName
    LocalWriteLogHelper -Msg "[INFO] Generating HTML report for job '$JobName': '$reportFullPath' (Theme: $reportThemeName)" -Lvl "INFO"

    $mainScriptRoot = $GlobalConfig['_PoShBackup_PSScriptRoot']; $moduleAssetsDir = Join-Path -Path $PSScriptRoot -ChildPath "Assets"
    # Removed: LocalWriteLogHelper -Msg "Invoke-HtmlReport: Module assets directory resolved to '$moduleAssetsDir'." -Lvl "DEBUG"

    $htmlTemplateFilePath = Join-Path -Path $moduleAssetsDir -ChildPath "ReportingHtml.template.html"; $htmlTemplateContent = ""
    # Removed: LocalWriteLogHelper -Msg "Invoke-HtmlReport: Attempting to load HTML template from '$htmlTemplateFilePath'." -Lvl "DEBUG"
    if (Test-Path -LiteralPath $htmlTemplateFilePath -PathType Leaf) { 
        try { 
            $htmlTemplateContent = Get-Content -LiteralPath $htmlTemplateFilePath -Raw -ErrorAction Stop 
            # Removed: LocalWriteLogHelper -Msg "Invoke-HtmlReport: HTML template loaded. Length: $($htmlTemplateContent.Length)." -Lvl "DEBUG"
        } catch { 
            LocalWriteLogHelper -Msg "[ERROR] Failed to read HTML template '$htmlTemplateFilePath'. Error: $($_.Exception.Message). Aborting report." -Lvl "ERROR"; return
        } 
    }
    else { 
        LocalWriteLogHelper -Msg "[ERROR] HTML template '$htmlTemplateFilePath' not found. Aborting report." -Lvl "ERROR"; return
    }
    if ([string]::IsNullOrWhiteSpace($htmlTemplateContent)) {
        LocalWriteLogHelper -Msg "[CRITICAL] HTML template content is empty after attempting to load from '$htmlTemplateFilePath'. Report generation cannot proceed. Aborting report." -Lvl "ERROR"
        return 
    }

    $htmlMetaTags = "<meta charset=`"UTF-8`"><meta name=`"viewport`" content=`"width=device-width, initial-scale=1.0`">"; $faviconLinkTag = ""
    if (-not [string]::IsNullOrWhiteSpace($reportFaviconPathUser) -and (Test-Path -LiteralPath $reportFaviconPathUser -PathType Leaf)) { try { $favBytes = [System.IO.File]::ReadAllBytes($reportFaviconPathUser); $favB64 = [System.Convert]::ToBase64String($favBytes); $favMime = switch ([System.IO.Path]::GetExtension($reportFaviconPathUser).ToLowerInvariant()) { ".png"{"image/png"} ".ico"{"image/x-icon"} ".svg"{"image/svg+xml"} default {""} }; if ($favMime) { $faviconLinkTag = "<link rel=`"icon`" type=`"$favMime`" href=`"data:$favMime;base64,$favB64`">" } } catch { LocalWriteLogHelper -Msg "[WARNING] Error embedding favicon '$reportFaviconPathUser': $($_.Exception.Message)" -Lvl "WARNING" } }

    $baseCssContent = ""; $themeCssContent = ""; $overrideCssVariablesStyleBlock = ""; $customUserCssContentFromFile = ""
    if ([string]::IsNullOrWhiteSpace($mainScriptRoot) -or -not (Test-Path $mainScriptRoot -PathType Container)) { LocalWriteLogHelper -Msg "[ERROR] Main script root path invalid. Cannot load theme CSS." -Lvl "ERROR"; $finalCssToInject = "<style>body{font-family:sans-serif;}</style>" }
    else {
        $themesDir = Join-Path -Path $mainScriptRoot -ChildPath "Config\Themes"
        # Removed: LocalWriteLogHelper -Msg "Invoke-HtmlReport: Themes directory resolved to '$themesDir'." -Lvl "DEBUG"
        $baseCssFile = Join-Path -Path $themesDir -ChildPath "Base.css"; if (Test-Path -LiteralPath $baseCssFile -PathType Leaf) { try { $baseCssContent = Get-Content -LiteralPath $baseCssFile -Raw } catch { LocalWriteLogHelper -Msg "[WARNING] Error loading Base.css: $($_.Exception.Message)" -Lvl "WARNING" } } else { LocalWriteLogHelper -Msg "[WARNING] Base.css not found at '$baseCssFile'." -Lvl "WARNING" }
        $themeFile = Join-Path -Path $themesDir -ChildPath (($reportThemeName -replace '[^a-zA-Z0-9]', '') + ".css"); if (Test-Path -LiteralPath $themeFile -PathType Leaf) { try { $themeCssContent = Get-Content -LiteralPath $themeFile -Raw } catch { LocalWriteLogHelper -Msg "[WARNING] Error loading theme CSS '$($themeFile)': $($_.Exception.Message)" -Lvl "WARNING" } } else { LocalWriteLogHelper -Msg "[WARNING] Theme CSS '$($themeFile)' not found." -Lvl "WARNING" }
        if ($cssVariableOverrides.Count -gt 0) { $sbCssVar = [System.Text.StringBuilder]::new("<style>:root {"); $cssVariableOverrides.GetEnumerator() | ForEach-Object { $varN = $_.Name; if (-not $varN.StartsWith("--")) { $varN = "--" + $varN }; $null = $sbCssVar.Append("$varN : $($_.Value) ;") }; $null = $sbCssVar.Append("}</style>"); $overrideCssVariablesStyleBlock = $sbCssVar.ToString() }
        if (-not [string]::IsNullOrWhiteSpace($reportCustomCssPathUser) -and (Test-Path -LiteralPath $reportCustomCssPathUser -PathType Leaf)) { try { $customUserCssContentFromFile = Get-Content -LiteralPath $reportCustomCssPathUser -Raw } catch { LocalWriteLogHelper -Msg "[WARNING] Error loading custom CSS '$reportCustomCssPathUser': $($_.Exception.Message)" -Lvl "WARNING" } }
        $finalCssToInject = "<style>" + $baseCssContent + $themeCssContent + "</style>" + $overrideCssVariablesStyleBlock + "<style>" + $customUserCssContentFromFile + "</style>"
    }
    # Removed: LocalWriteLogHelper -Msg "Invoke-HtmlReport: CSS injection block prepared. Length: $($finalCssToInject.Length)." -Lvl "DEBUG"
    
    $jsFilePath = Join-Path -Path $moduleAssetsDir -ChildPath "ReportingHtml.Client.js"; $jsContent = ""; 
    # Removed: LocalWriteLogHelper -Msg "Invoke-HtmlReport: Attempting to load JS from '$jsFilePath'." -Lvl "DEBUG"
    if (Test-Path -LiteralPath $jsFilePath -PathType Leaf) { 
        try { 
            $jsContent = Get-Content -LiteralPath $jsFilePath -Raw -ErrorAction Stop
            # Removed: LocalWriteLogHelper -Msg "Invoke-HtmlReport: JS file loaded. Length: $($jsContent.Length)." -Lvl "DEBUG"
        } catch { 
            LocalWriteLogHelper -Msg "[ERROR] Error reading JS file '$jsFilePath': $($_.Exception.Message)" -Lvl "ERROR" 
        } 
    } else { 
        LocalWriteLogHelper -Msg "[ERROR] JS file '$jsFilePath' not found." -Lvl "ERROR" 
    }
    $pageJavaScriptBlock = "<script>" + $jsContent + "</script>"

    $embeddedLogoHtml = ""; if (-not [string]::IsNullOrWhiteSpace($reportLogoPath) -and (Test-Path -LiteralPath $reportLogoPath -PathType Leaf)) { try { $logoBytes = [System.IO.File]::ReadAllBytes($reportLogoPath); $logoB64 = [System.Convert]::ToBase64String($logoBytes); $logoMime = switch ([System.IO.Path]::GetExtension($reportLogoPath).ToLowerInvariant()) { ".png"{"image/png"} ".jpg"{"image/jpeg"} ".jpeg"{"image/jpeg"} ".gif"{"image/gif"} ".svg"{"image/svg+xml"} default {""} }; if ($logoMime) { $embeddedLogoHtml = "<img src='data:$($logoMime);base64,$($logoB64)' alt='Report Logo' class='report-logo'>" } } catch { LocalWriteLogHelper -Msg "[WARNING] Error embedding logo '$reportLogoPath': $($_.Exception.Message)" -Lvl "WARNING" } }
    
    $headerTitleText = "$($reportTitlePrefix) - $(ConvertTo-SafeHtml $JobName)"; if ($reportThemeName.ToLowerInvariant() -eq "retroterminal") { $headerTitleText += "<span class='blinking-cursor'></span>" }
    
    $simulationBannerHtml = ""; $isSim = $ReportData.IsSimulationReport -is [System.Management.Automation.SwitchParameter] ? $ReportData.IsSimulationReport.IsPresent : ($ReportData.IsSimulationReport -eq $true); if ($isSim) { $simulationBannerHtml = "<div class='simulation-banner'><strong>*** SIMULATION MODE RUN ***</strong> This report reflects a simulated backup. No actual files were changed or archives created.</div>" }

    # Build dynamic content for placeholders
    $summaryTableRowsHtml = ""; if ($reportShowSummary -and $ReportData.ContainsKey('OverallStatus')) { $sb = [System.Text.StringBuilder]::new(); $sumOrder = @('JobName','OverallStatus','ScriptStartTime','ScriptEndTime','TotalDuration','TotalDurationSeconds','SourcePath','EffectiveSourcePath','FinalArchivePath','ArchiveSizeFormatted','ArchiveSizeBytes','SplitVolumeSize','SFXCreationOverriddenBySplit','SevenZipExitCode','TreatSevenZipWarningsAsSuccess','RetryAttemptsMade','ArchiveTested','ArchiveTestResult','TestRetryAttemptsMade','ArchiveChecksum','ArchiveChecksumAlgorithm','ArchiveChecksumFile','ArchiveChecksumVerificationStatus','VSSAttempted','VSSStatus','VSSShadowPaths','PasswordSource','ErrorMessage'); $sumDisp = [ordered]@{}; foreach($k in $sumOrder){if($ReportData.ContainsKey($k)){$sumDisp[$k]=$ReportData[$k]}}; $ReportData.GetEnumerator()|Where-Object {$_.Name -notin $sumOrder -and $_.Name -notin @('LogEntries','JobConfiguration','HookScripts','IsSimulationReport','_PoShBackup_PSScriptRoot','TargetTransfers')}|ForEach-Object {$sumDisp[$_.Name]=$_.Value}; $sumDisp.GetEnumerator()|ForEach-Object {$kN=ConvertTo-SafeHtml $_.Name;$v=$_.Value;$dV="";$sC="";$sA="";if($v -is [array]){$dV=($v|ForEach-Object {ConvertTo-SafeHtml ([string]$_)}) -join '<br>'}else{$dV=ConvertTo-SafeHtml([string]$v)};if($kN -eq "OverallStatus" -or $kN -eq "ArchiveTestResult" -or $kN -eq "VSSStatus" -or $kN -eq "ArchiveChecksumVerificationStatus"){$sVal=([string]$_.Value -replace ' ','_') -replace '[\(\):\/]','_' -replace '\+','plus' -replace ',','';$sC="status-$(ConvertTo-SafeHtml $sVal)"}elseif($kN -eq "VSSAttempted"){$sC=if($v -eq $true){"status-INFO"}else{"status-DEFAULT"}};if($kN -eq "ArchiveSizeFormatted" -and $ReportData.ArchiveSizeBytes -is [long]){$sA="data-sort-value='$($ReportData.ArchiveSizeBytes)'"}elseif($kN -eq "TotalDuration" -and $ReportData.TotalDurationSeconds -is [double]){$sA="data-sort-value='$($ReportData.TotalDurationSeconds)'"};$null=$sb.Append("<tr><td data-label='Item'>$kN</td><td data-label='Detail' class='$sC' $sA>$dV</td></tr>")}; $summaryTableRowsHtml = $sb.ToString() }
    
    $targetTransfersTableRowsHtml = ""; if ($reportShowTargetTransfers -and $ReportData.ContainsKey('TargetTransfers') -and $ReportData.TargetTransfers.Count -gt 0) { $sb = [System.Text.StringBuilder]::new(); foreach ($tE in $ReportData.TargetTransfers) {$tNS=ConvertTo-SafeHtml $tE.TargetName;$tTS=ConvertTo-SafeHtml $tE.TargetType;$tSS=ConvertTo-SafeHtml $tE.Status;$tSC="status-$(($tE.Status -replace ' ','_')-replace '[\(\):\/]','_'-replace '\+','plus')";$rPS=ConvertTo-SafeHtml $tE.RemotePath;$dS=ConvertTo-SafeHtml $tE.TransferDuration;$sFS=ConvertTo-SafeHtml $tE.TransferSizeFormatted;$sBSA=if($tE.PSObject.Properties.Name -contains "TransferSize" -and $tE.TransferSize -is [long]){"data-sort-value='$($tE.TransferSize)'"}else{""};$eMS=if(-not[string]::IsNullOrWhiteSpace($tE.ErrorMessage)){ConvertTo-SafeHtml $tE.ErrorMessage}else{"<em>N/A</em>"};$null=$sb.Append("<tr><td data-label='Target Name'>$tNS</td><td data-label='Type'>$tTS</td><td data-label='Status' class='$tSC'>$tSS</td><td data-label='Remote Path'>$rPS</td><td data-label='Duration'>$dS</td><td data-label='Size' $sBSA>$sFS</td><td data-label='Error Message'>$eMS</td></tr>")}; $targetTransfersTableRowsHtml = $sb.ToString() }

    $configTableRowsHtml = ""; if ($reportShowConfiguration -and $ReportData.ContainsKey('JobConfiguration') -and $null -ne $ReportData.JobConfiguration) { $sb = [System.Text.StringBuilder]::new(); foreach ($key in $ReportData.JobConfiguration.Keys | Sort-Object) {$value = $ReportData.JobConfiguration[$key]; $displayValue = if ($value -is [array]) { ($value | ForEach-Object { ConvertTo-SafeHtml ([string]$_) }) -join ", " } else { ConvertTo-SafeHtml ([string]$value) }; $null=$sb.Append("<tr><td data-label='Setting'>$(ConvertTo-SafeHtml $key)</td><td data-label='Value'>$($displayValue)</td></tr>")}; $configTableRowsHtml = $sb.ToString() }

    $hooksTableRowsHtml = ""; if ($reportShowHooks -and $ReportData.ContainsKey('HookScripts') -and $ReportData.HookScripts.Count -gt 0) { $sb = [System.Text.StringBuilder]::new(); $ReportData.HookScripts | ForEach-Object {$sSV=([string]$_.Status -replace ' ','_') -replace '[\(\):\/]','_' -replace '\+','plus'; $sC="status-$(ConvertTo-SafeHtml $sSV)"; $hOH=if([string]::IsNullOrWhiteSpace($_.Output)){"<em><No output></em>"}else{"<div class='pre-container'><button type='button' class='copy-hook-output-btn' title='Copy Hook Output' aria-label='Copy hook output to clipboard'>Copy</button><pre>$(ConvertTo-SafeHtml $_.Output)</pre></div>"}; $null=$sb.Append("<tr><td data-label='Hook Type'>$(ConvertTo-SafeHtml $_.Name)</td><td data-label='Path'>$(ConvertTo-SafeHtml $_.Path)</td><td data-label='Status' class='$sC'>$(ConvertTo-SafeHtml $_.Status)</td><td data-label='Output/Error'>$hOH</td></tr>")}; $hooksTableRowsHtml = $sb.ToString() }

    $logLevelFiltersControlsHtml = ""; $logEntriesListHtml = "";
    if ($reportShowLogEntries -and $ReportData.ContainsKey('LogEntries') -and $ReportData.LogEntries.Count -gt 0) {
        $sbFilters = [System.Text.StringBuilder]::new("<div class='log-level-filters-container'><strong>Filter by Level:</strong>"); 
        ($ReportData.LogEntries.Level | Select-Object -Unique | Sort-Object | Where-Object {-not [string]::IsNullOrWhiteSpace($_)}) | ForEach-Object { $sL = ConvertTo-SafeHtml $_; $null=$sbFilters.Append("<label><input type='checkbox' class='log-level-filter' value='$sL' checked> $sL</label>") }; 
        $null=$sbFilters.Append("<div class='log-level-toggle-buttons'><button type='button' id='logFilterSelectAll'>Select All</button><button type='button' id='logFilterDeselectAll'>Deselect All</button></div></div>"); 
        $logLevelFiltersControlsHtml = $sbFilters.ToString();
        $sbLogs = [System.Text.StringBuilder]::new(); 
        $ReportData.LogEntries | ForEach-Object { $eC="log-$(ConvertTo-SafeHtml $_.Level)"; $null=$sbLogs.Append("<div class='log-entry $eC' data-level='$(ConvertTo-SafeHtml $_.Level)'><strong>$(ConvertTo-SafeHtml $_.Timestamp) [$(ConvertTo-SafeHtml $_.Level)]</strong> <span>$(ConvertTo-SafeHtml $_.Message)</span></div>") }; 
        $logEntriesListHtml = $sbLogs.ToString()
    }
    
    $footerCompanyNameHtml = if (-not [string]::IsNullOrWhiteSpace($reportCompanyName)) { "$(ConvertTo-SafeHtml $reportCompanyName) - " } else { "" }
    $reportGenerationDateText = ConvertTo-SafeHtml ([string](Get-Date))

    # Populate the template
    # Removed: LocalWriteLogHelper -Msg "Invoke-HtmlReport: Preparing to populate HTML template." -Lvl "DEBUG"
    $finalHtml = $htmlTemplateContent
    $finalHtml = $finalHtml -replace '\{\{REPORT_TITLE\}\}', (ConvertTo-SafeHtml "$($reportTitlePrefix) - $JobName") `
                           -replace '\{\{HTML_META_TAGS\}\}', $htmlMetaTags `
                           -replace '\{\{FAVICON_LINK_TAG\}\}', $faviconLinkTag `
                           -replace '\{\{CSS_CONTENT\}\}', $finalCssToInject `
                           -replace '\{\{SIMULATION_BANNER_HTML\}\}', $simulationBannerHtml `
                           -replace '\{\{HEADER_TITLE_TEXT\}\}', $headerTitleText `
                           -replace '\{\{EMBEDDED_LOGO_HTML\}\}', $embeddedLogoHtml `
                           -replace '\{\{JOB_NAME_FOR_HEADER\}\}', (ConvertTo-SafeHtml $JobName) `
                           -replace '\{\{FOOTER_COMPANY_NAME_HTML\}\}', $footerCompanyNameHtml `
                           -replace '\{\{REPORT_GENERATION_DATE_TEXT\}\}', $reportGenerationDateText `
                           -replace '\{\{JAVASCRIPT_CONTENT_BLOCK\}\}', $pageJavaScriptBlock

    # Conditional Section Replacement
    $sectionsMap = @{
        SUMMARY           = @{ Show = $reportShowSummary; HasData = $ReportData.ContainsKey('OverallStatus'); Rows = $summaryTableRowsHtml }
        TARGET_TRANSFERS  = @{ Show = $reportShowTargetTransfers; HasData = ($ReportData.ContainsKey('TargetTransfers') -and $ReportData.TargetTransfers.Count -gt 0); Rows = $targetTransfersTableRowsHtml }
        CONFIGURATION     = @{ Show = $reportShowConfiguration; HasData = ($ReportData.ContainsKey('JobConfiguration') -and $null -ne $ReportData.JobConfiguration); Rows = $configTableRowsHtml }
        HOOKS             = @{ Show = $reportShowHooks; HasData = ($ReportData.ContainsKey('HookScripts') -and $ReportData.HookScripts.Count -gt 0); Rows = $hooksTableRowsHtml }
    }

    foreach ($sectionKey in $sectionsMap.Keys) {
        $sectionData = $sectionsMap[$sectionKey]
        $showThisSection = $sectionData.Show -and $sectionData.HasData
        
        # Removed: LocalWriteLogHelper -Msg "Invoke-HtmlReport: Processing section '$sectionKey'. Show: $showThisSection. HasData: $($sectionData.HasData)." -Lvl "DEBUG"

        if ($showThisSection) {
            $finalHtml = $finalHtml -replace "\{\{IF_SHOW_$($sectionKey)_START\}\}", "" `
                                   -replace "\{\{IF_SHOW_$($sectionKey)_END\}\}", ""
            $finalHtml = $finalHtml -replace "\{\{$($sectionKey)_TABLE_ROWS_HTML\}\}", $sectionData.Rows
        } else {
            $finalHtml = $finalHtml -replace "(?s)\{\{IF_SHOW_$($sectionKey)_START\}\}.*?\{\{IF_SHOW_$($sectionKey)_END\}\}", ""
        }
    }

    # Special handling for logs section (IF_SHOW_LOG_ENTRIES_START/END and IF_NO_LOG_ENTRIES_START/END)
    $showLogsSection = $reportShowLogEntries
    $hasLogData = ($ReportData.ContainsKey('LogEntries') -and $ReportData.LogEntries.Count -gt 0)
    # Removed: LocalWriteLogHelper -Msg "Invoke-HtmlReport: Processing Logs section. ShowLogsSection: $showLogsSection. HasLogData: $hasLogData." -Lvl "DEBUG"

    if ($showLogsSection -and $hasLogData) {
        $finalHtml = $finalHtml -replace "(?s)\{\{IF_SHOW_LOG_ENTRIES_START\}\}(.*?)\{\{IF_SHOW_LOG_ENTRIES_END\}\}", '$1' 
        $finalHtml = $finalHtml -replace '\{\{LOG_LEVEL_FILTERS_CONTROLS_HTML\}\}', $logLevelFiltersControlsHtml `
                               -replace '\{\{LOG_ENTRIES_LIST_HTML\}\}', $logEntriesListHtml
        $finalHtml = $finalHtml -replace "(?s)\{\{IF_NO_LOG_ENTRIES_START\}\}(.*?)\{\{IF_NO_LOG_ENTRIES_END\}\}", "" 
    } elseif ($showLogsSection -and -not $hasLogData) { 
        $finalHtml = $finalHtml -replace "(?s)\{\{IF_SHOW_LOG_ENTRIES_START\}\}(.*?)\{\{IF_SHOW_LOG_ENTRIES_END\}\}", "" 
        $finalHtml = $finalHtml -replace "(?s)\{\{IF_NO_LOG_ENTRIES_START\}\}(.*?)\{\{IF_NO_LOG_ENTRIES_END\}\}", '$1' 
    } else { 
        $finalHtml = $finalHtml -replace "(?s)\{\{IF_SHOW_LOG_ENTRIES_START\}\}(.*?)\{\{IF_SHOW_LOG_ENTRIES_END\}\}", "" 
        $finalHtml = $finalHtml -replace "(?s)\{\{IF_NO_LOG_ENTRIES_START\}\}(.*?)\{\{IF_NO_LOG_ENTRIES_END\}\}", "" 
    }
    # Removed: LocalWriteLogHelper -Msg "Invoke-HtmlReport: HTML template populated. Final HTML length: $($finalHtml.Length)." -Lvl "DEBUG"

    try {
        Set-Content -Path $reportFullPath -Value $finalHtml -Encoding UTF8 -Force -ErrorAction Stop
        LocalWriteLogHelper -Msg "  - HTML report generated successfully: '$reportFullPath'" -Lvl "SUCCESS" 
    } catch { 
        LocalWriteLogHelper -Msg "[ERROR] Failed to generate HTML report '$reportFullPath' for job '$JobName'. Error: $($_.Exception.Message)" -Lvl "ERROR" 
    }
    LocalWriteLogHelper -Msg "[INFO] HTML Report generation process finished for job '$JobName'." -Lvl "INFO"
}
#endregion

Export-ModuleMember -Function Invoke-HtmlReport
