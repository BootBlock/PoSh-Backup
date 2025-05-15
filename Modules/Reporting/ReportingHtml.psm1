<#
.SYNOPSIS
    Generates detailed HTML reports for PoSh-Backup jobs, featuring customizable themes,
    CSS overrides, embedded logos, and client-side JavaScript for log filtering and searching.
    Includes a banner for simulation mode runs.
.DESCRIPTION
    This module is dedicated to creating rich, interactive HTML reports. It handles CSS loading
    for themes and user overrides, embeds images, structures the report into sections (Summary,
    Configuration, Hooks, Logs), and includes JavaScript for dynamic log filtering.
    It uses robust HTML encoding to prevent XSS vulnerabilities.
.NOTES
    Author:         PoSh-Backup Project
    Version:        1.2 
    DateCreated:    14-May-2025
    LastModified:   15-May-2025
    Purpose:        HTML report generation for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+. Called by Reporting.psm1 (orchestrator).
                    System.Web assembly (optional, for enhanced HtmlEncode).
                    Base.css and theme CSS files in Config\Themes\.
#>

#region --- HTML Encode Helper Function Definition ---
Function ConvertTo-PoshBackupSafeHtmlInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, ValueFromPipeline)]
        [string]$Text
    )
    
    if ($null -eq $Text) { return '' }

    if ($Script:PoshBackup_ReportingHtml_UseSystemWebHtmlEncode) { 
        try { return [System.Web.HttpUtility]::HtmlEncode($Text) }
        catch {
            Write-Warning "[ReportingHtml.psm1] System.Web.HttpUtility.HtmlEncode failed. Falling back to manual."
            return $Text -replace '&', '&' -replace '<', '<' -replace '>', '>' -replace '"', '"' -replace "'", '&#39;'
        }
    } else {
        return $Text -replace '&', '&' -replace '<', '<' -replace '>', '>' -replace '"', '"' -replace "'", '&#39;'
    }
}
#endregion

#region --- Module Top-Level Script Block (for Add-Type and Alias Export) ---
$Script:PoshBackup_ReportingHtml_UseSystemWebHtmlEncode = $false 
try {
    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue 
    
    # Test if the class exists to be more certain.
    # The condition for 'if' should be a complete expression.
    $httpUtilityType = try { [System.Type]::GetType("System.Web.HttpUtility, System.Web, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a", $false) } catch { $null }

    if ($null -ne $httpUtilityType) { # Check if the type was successfully retrieved
        $Script:PoshBackup_ReportingHtml_UseSystemWebHtmlEncode = $true 
        Write-Verbose "[ReportingHtml.psm1] System.Web.HttpUtility available for HTML encoding."
    } else { 
        Write-Warning "[ReportingHtml.psm1] System.Web.HttpUtility class not found after attempting to load System.Web.dll. Using basic manual HTML sanitisation."
    }
} # This is the closing brace for the TRY block
catch { # This catch now correctly pairs with the try
    Write-Warning "[ReportingHtml.psm1] An error occurred while trying to load System.Web.dll. Error: $($_.Exception.Message). Using basic manual HTML sanitisation."
}

Set-Alias -Name ConvertTo-SafeHtml -Value ConvertTo-PoshBackupSafeHtmlInternal -Scope Script -ErrorAction SilentlyContinue -Force
if (-not (Get-Alias ConvertTo-SafeHtml -ErrorAction SilentlyContinue)) {
    Write-Warning "[ReportingHtml.psm1] Failed to set alias 'ConvertTo-SafeHtml'."
}
#endregion


#region --- HTML Report Function ---
function Invoke-HtmlReport {
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
        if ($null -ne $Logger) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            Write-Host "[$Level] (ReportingHtmlDirect) $Message" 
        }
    }

    # ----- START OF Invoke-HtmlReport CONTENT -----
    $getReportSetting = {
        param($Key, $DefaultInFunction)
        $val = $null
        if ($null -ne $JobConfig -and $JobConfig.ContainsKey($Key)) { 
            $val = $JobConfig[$Key]
        } elseif ($GlobalConfig.ContainsKey($Key)) { 
            $val = $GlobalConfig[$Key]
        }
        if ($null -eq $val) { return $DefaultInFunction } else { return $val }
    }

    $reportTitlePrefix       = ConvertTo-SafeHtml ($getReportSetting.Invoke('HtmlReportTitlePrefix', "PoSh Backup Status Report"))
    $reportLogoPath          = $getReportSetting.Invoke('HtmlReportLogoPath', "") 
    $reportCustomCssPathUser = $getReportSetting.Invoke('HtmlReportCustomCssPath', "") 
    $reportCompanyName       = ConvertTo-SafeHtml ($getReportSetting.Invoke('HtmlReportCompanyName', "PoSh Backup"))
    
    $reportThemeNameRaw      = $getReportSetting.Invoke('HtmlReportTheme', "Light") 
    $reportThemeName         = if ($reportThemeNameRaw -is [array]) { $reportThemeNameRaw[0] } else { $reportThemeNameRaw }
    if ([string]::IsNullOrWhiteSpace($reportThemeName)) { $reportThemeName = "Light" } 

    $cssVariableOverrides = @{}
    $globalCssVarOverrides = $GlobalConfig.HtmlReportOverrideCssVariables 
    if ($null -eq $globalCssVarOverrides -or -not ($globalCssVarOverrides -is [hashtable])) { $globalCssVarOverrides = @{} }
    $jobCssVarOverrides = $JobConfig.HtmlReportOverrideCssVariables
    if ($null -eq $jobCssVarOverrides -or -not ($jobCssVarOverrides -is [hashtable])) { $jobCssVarOverrides = @{} }
    
    $globalCssVarOverrides.GetEnumerator() | ForEach-Object { $cssVariableOverrides[$_.Name] = $_.Value }
    $jobCssVarOverrides.GetEnumerator() | ForEach-Object { $cssVariableOverrides[$_.Name] = $_.Value } 

    $reportShowSummary       = $getReportSetting.Invoke('HtmlReportShowSummary', $true)
    $reportShowConfiguration = $getReportSetting.Invoke('HtmlReportShowConfiguration', $true)
    $reportShowHooks         = $getReportSetting.Invoke('HtmlReportShowHooks', $true)
    $reportShowLogEntries    = $getReportSetting.Invoke('HtmlReportShowLogEntries', $true)
    
    if (-not (Test-Path -Path $ReportDirectory -PathType Container)) {
        & $LocalWriteLog -Message "[ERROR] HTML Report directory '$ReportDirectory' does not exist. Report cannot be generated for job '$JobName'." -Level "ERROR" -ForegroundColour $Global:ColourError
        return
    }

    $reportTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeJobNameForFile = $JobName -replace '[^a-zA-Z0-9_-]', '_' 
    $reportFileName = "$($safeJobNameForFile)_Report_$($reportTimestamp).html"
    $reportFullPath = Join-Path -Path $ReportDirectory -ChildPath $reportFileName

    & $LocalWriteLog -Message "[INFO] Generating HTML report: $reportFullPath (Theme: $reportThemeName)" -Level "INFO"

    $mainScriptRoot = $GlobalConfig['_PoShBackup_PSScriptRoot'] 
    
    $baseCssContent = ""; $themeCssContent = ""; $overrideCssVariablesStyleBlock = ""; $customUserCssContentFromFile = ""
    $htmlMetaTags = "<meta charset=`"UTF-8`"><meta name=`"viewport`" content=`"width=device-width, initial-scale=1.0`">" 

    if ([string]::IsNullOrWhiteSpace($mainScriptRoot) -or -not (Test-Path $mainScriptRoot -PathType Container)) {
        & $LocalWriteLog -Message "[ERROR] Main script root path ('_PoShBackup_PSScriptRoot') not found or invalid in GlobalConfig. Cannot load theme CSS files from 'Config\Themes'. Report styling will be minimal." -Level "ERROR" -ForegroundColour $Global:ColourError
        $finalCssToInject = "<style>body{font-family:sans-serif;margin:1em;} table{border-collapse:collapse;margin-top:1em;} th,td{border:1px solid #ccc;padding:0.25em 0.5em;text-align:left;} h1,h2{color:#003366;}</style>"
    } else {
        $configThemesDir = Join-Path -Path $mainScriptRoot -ChildPath "Config\Themes" 
        $baseCssFilePath = Join-Path -Path $configThemesDir -ChildPath "Base.css"
        if (Test-Path -LiteralPath $baseCssFilePath -PathType Leaf) {
            try { $baseCssContent = Get-Content -LiteralPath $baseCssFilePath -Raw -ErrorAction Stop }
            catch { & $LocalWriteLog -Message "[WARNING] Could not load Base.css from '$baseCssFilePath': $($_.Exception.Message)" -Level "WARNING" -ForegroundColour $Global:ColourWarning }
        } else { & $LocalWriteLog -Message "[WARNING] Base.css not found at '$baseCssFilePath'. Report styling will heavily rely on theme or be minimal." -Level "WARNING" -ForegroundColour $Global:ColourWarning }

        if (-not [string]::IsNullOrWhiteSpace($reportThemeName)) {
            $reportThemeNameString = [string]$reportThemeName 
            $safeThemeFileNameForFile = ($reportThemeNameString -replace '[^a-zA-Z0-9]', '') + ".css" 
            $themeCssFilePath = Join-Path -Path $configThemesDir -ChildPath $safeThemeFileNameForFile
            if (Test-Path -LiteralPath $themeCssFilePath -PathType Leaf) {
                try { $themeCssContent = Get-Content -LiteralPath $themeCssFilePath -Raw -ErrorAction Stop }
                catch { & $LocalWriteLog -Message "[WARNING] Could not load theme CSS '$safeThemeFileNameForFile' from '$themeCssFilePath': $($_.Exception.Message)" -Level "WARNING" -ForegroundColour $Global:ColourWarning }
            } else { 
                & $LocalWriteLog -Message "[WARNING] Theme CSS file '$safeThemeFileNameForFile' for theme '$reportThemeName' not found at '$themeCssFilePath'." -Level "WARNING" -ForegroundColour $Global:ColourWarning
            }
        }
        
        if ($cssVariableOverrides.Count -gt 0) {
            $overrideCssVariablesStyleBlock = "<style>:root {" 
            $cssVariableOverrides.GetEnumerator() | ForEach-Object {
                $varName = ($_.Name -replace '[^a-zA-Z0-9_-]', '') 
                $varValue = $_.Value 
                if (-not $varName.StartsWith("--")) { $varName = "--" + $varName } 
                $overrideCssVariablesStyleBlock += "$varName : $varValue ;"
            }
            $overrideCssVariablesStyleBlock += "}</style>"
        }
        
        if (-not [string]::IsNullOrWhiteSpace($reportCustomCssPathUser) -and (Test-Path -LiteralPath $reportCustomCssPathUser -PathType Leaf)) {
            try {
                $customUserCssContentFromFile = Get-Content -LiteralPath $reportCustomCssPathUser -Raw -ErrorAction Stop
            } catch { & $LocalWriteLog -Message "[WARNING] Could not load user custom CSS from '$reportCustomCssPathUser'. Error: $($_.Exception.Message)" -Level "WARNING" -ForegroundColour $Global:ColourWarning }
        }
        $finalCssToInject = "<style>" + $baseCssContent + $themeCssContent + "</style>" + $overrideCssVariablesStyleBlock + "<style>" + $customUserCssContentFromFile + "</style>"
    }
    
    $logFilterJavaScript = @"
<script>
document.addEventListener('DOMContentLoaded', function () {
    const keywordSearchInput = document.getElementById('logKeywordSearch');
    const levelFilterCheckboxes = document.querySelectorAll('.log-level-filter');
    const logEntriesContainer = document.getElementById('detailedLogEntries');
    
    if (!logEntriesContainer) return; 
    const logEntries = Array.from(logEntriesContainer.getElementsByClassName('log-entry'));

    function filterLogs() {
        const keyword = keywordSearchInput ? keywordSearchInput.value.toLowerCase() : '';
        const activeLevelFilters = new Set();
        let allLevelsUnchecked = true;
        if (levelFilterCheckboxes.length > 0) {
            levelFilterCheckboxes.forEach(checkbox => {
                if (checkbox.checked) {
                    activeLevelFilters.add(checkbox.value.toUpperCase());
                    allLevelsUnchecked = false;
                }
            });
        } else { 
            allLevelsUnchecked = false; 
        }

        logEntries.forEach(entry => {
            const entryText = entry.textContent.toLowerCase();
            const entryLevelElement = entry.querySelector('strong'); 
            let entryLevel = '';
            if (entryLevelElement) {
                const match = entryLevelElement.textContent.match(/\[(.*?)\]/);
                if (match && match[1]) {
                    entryLevel = match[1].toUpperCase();
                }
            }

            const keywordMatch = keyword === '' || entryText.includes(keyword);
            const levelMatch = allLevelsUnchecked || activeLevelFilters.size === 0 || activeLevelFilters.has(entryLevel);

            if (keywordMatch && levelMatch) {
                entry.style.display = 'flex'; 
            } else {
                entry.style.display = 'none';
            }
        });
    }

    if (keywordSearchInput) {
        keywordSearchInput.addEventListener('keyup', filterLogs);
    }
    if (levelFilterCheckboxes.length > 0) {
        levelFilterCheckboxes.forEach(checkbox => {
            checkbox.addEventListener('change', filterLogs);
        });
    }
});
</script>
"@

    $htmlHead = $htmlMetaTags + $finalCssToInject 

    $embeddedLogoHtml = ""
    if (-not [string]::IsNullOrWhiteSpace($reportLogoPath) -and (Test-Path -LiteralPath $reportLogoPath -PathType Leaf)) {
        try {
            $logoBytes = [System.IO.File]::ReadAllBytes($reportLogoPath); $logoBase64 = [System.Convert]::ToBase64String($logoBytes)
            $logoMimeType = switch ([System.IO.Path]::GetExtension($reportLogoPath).ToLowerInvariant()) {
                ".png" { "image/png" } ".jpg" { "image/jpeg" } ".jpeg" { "image/jpeg" } ".gif" { "image/gif" } ".svg" { "image/svg+xml"} default { "image/png" } 
            }
            $embeddedLogoHtml = "<img src='data:$($logoMimeType);base64,$($logoBase64)' alt='Logo' class='report-logo'>"
        } catch { & $LocalWriteLog -Message "[WARNING] Could not embed logo from '$reportLogoPath': $($_.Exception.Message)" -Level "WARNING" -ForegroundColour $Global:ColourWarning}
    }
    
    $htmlBodyLocal = "<div class='container'>" 

    $isSimulation = $false
    if ($ReportData.ContainsKey('IsSimulationReport')) {
        if ($ReportData.IsSimulationReport -is [System.Management.Automation.SwitchParameter]) {
             $isSimulation = $ReportData.IsSimulationReport.IsPresent
        } elseif ($ReportData.IsSimulationReport -is [bool]) {
            $isSimulation = $ReportData.IsSimulationReport
        }
    } elseif ($ReportData.ContainsKey('OverallStatus') -and ($ReportData.OverallStatus -is [string]) -and $ReportData.OverallStatus.ToUpperInvariant().Contains("SIMULAT")) {
        $isSimulation = $true
    }

    if ($isSimulation) {
        $htmlBodyLocal += "<div class='simulation-banner'><strong>*** SIMULATION MODE RUN ***</strong> This report reflects a simulated backup. No actual files were changed or archives created.</div>"
    }

    $headerTitle = "$($reportTitlePrefix) - $(ConvertTo-SafeHtml $JobName)"
    if ($reportThemeName.ToLowerInvariant() -eq "retroterminal") {
        $headerTitle += "<span class='blinking-cursor'></span>"
    }
    $htmlBodyLocal += "<div class='report-header'><h1>$headerTitle</h1>$($embeddedLogoHtml)</div>"

    if ($reportShowSummary -and ($ReportData.Keys -contains 'OverallStatus') ) { 
        $htmlBodyLocal += "<div class='details-section summary-section'><h2>Summary</h2><table>"
        $ReportData.GetEnumerator() | Where-Object {$_.Name -notin @('LogEntries', 'JobConfiguration', 'HookScripts', 'IsSimulationReport')} | ForEach-Object { 
            $keyName = ConvertTo-SafeHtml $_.Name
            $value = $_.Value
            $displayValue = if ($value -is [array]) { ($value | ForEach-Object { ConvertTo-SafeHtml ([string]$_) }) -join '<br>' } else { ConvertTo-SafeHtml ([string]$value) } 
            $statusClass = ""
            if ($_.Name -in @("OverallStatus", "ArchiveTestResult", "VSSStatus")) { 
                 $sanitizedStatusValue = ([string]$_.Value -replace ' ','_') -replace '\(','_' -replace '\)','_' -replace ':','' -replace '/','_'
                 $statusClass = "status-$(ConvertTo-SafeHtml $sanitizedStatusValue)"
            }
            $htmlBodyLocal += "<tr><td data-label='Item'>$($keyName)</td><td data-label='Detail' class='$($statusClass)'>$($displayValue)</td></tr>"
        }
        $htmlBodyLocal += "</table></div>"
    }

    if ($reportShowConfiguration -and ($ReportData.Keys -contains 'JobConfiguration') -and ($null -ne $ReportData.JobConfiguration)) {
        $htmlBodyLocal += "<div class='details-section config-section'><h2>Configuration Used for Job '$(ConvertTo-SafeHtml $JobName)'</h2><table>"
        $htmlBodyLocal += "<thead><tr><th>Setting</th><th>Value</th></tr></thead><tbody>"
        foreach ($key in $ReportData.JobConfiguration.Keys | Sort-Object) { 
            $value = $ReportData.JobConfiguration[$key]
            $displayValue = if ($value -is [array]) { ($value | ForEach-Object { ConvertTo-SafeHtml ([string]$_) }) -join ", " } else { ConvertTo-SafeHtml ([string]$value) }
            $htmlBodyLocal += "<tr><td data-label='Setting'>$(ConvertTo-SafeHtml $key)</td><td data-label='Value'>$($displayValue)</td></tr>"
        }
        $htmlBodyLocal += "</tbody></table></div>"
    }

    if ($reportShowHooks -and ($ReportData.Keys -contains 'HookScripts') -and ($null -ne $ReportData.HookScripts) -and $ReportData.HookScripts.Count -gt 0) {
        $htmlBodyLocal += "<div class='details-section hooks-section'><h2>Hook Scripts Executed</h2><table>"
        $htmlBodyLocal += "<thead><tr><th>Type</th><th>Path</th><th>Status</th><th>Output/Error</th></tr></thead><tbody>" 
        $ReportData.HookScripts | ForEach-Object {
            $sanitizedStatusValue = ([string]$_.Status -replace ' ','_') -replace '\(','_' -replace '\)','_' -replace ':','' -replace '/','_'
            $statusClass = "status-$(ConvertTo-SafeHtml $sanitizedStatusValue)" 
            $htmlBodyLocal += "<tr><td data-label='Hook Type'>$(ConvertTo-SafeHtml $_.Name)</td><td data-label='Path'>$(ConvertTo-SafeHtml $_.Path)</td><td data-label='Status' class='$($statusClass)'>$(ConvertTo-SafeHtml $_.Status)</td><td data-label='Output/Error'><pre>$(ConvertTo-SafeHtml $_.Output)</pre></td></tr>"
        }
        $htmlBodyLocal += "</tbody></table></div>"
    }

    if ($reportShowLogEntries -and ($ReportData.Keys -contains 'LogEntries') -and ($null -ne $ReportData.LogEntries) -and $ReportData.LogEntries.Count -gt 0) { 
        $htmlBodyLocal += "<div class='details-section log-section'><h2>Detailed Log</h2>"
        $htmlBodyLocal += "<div class='log-filters' style='margin-bottom: 1em; padding: 0.5em; border: 1px solid var(--border-color-light); border-radius: var(--border-radius-sm); background-color: var(--table-row-even-bg); display: flex; flex-wrap: wrap; gap: 1em; align-items: center;'>"
        $htmlBodyLocal += "<div style='flex-grow: 1;'><label for='logKeywordSearch' style='margin-right: 0.5em; font-weight: bold;'>Search Logs:</label><input type='text' id='logKeywordSearch' placeholder='Enter keyword...' style='padding: 0.3em; border: 1px solid var(--border-color-medium); border-radius: var(--border-radius-sm); width: 90%; min-width: 200px;'></div>"
        
        $logLevelsInReport = ($ReportData.LogEntries.Level | Select-Object -Unique | Sort-Object)
        if ($logLevelsInReport.Count -gt 0) {
            $htmlBodyLocal += "<div class='log-level-filters-container' style='display: flex; flex-wrap: wrap; gap: 0.5em 1em; align-items: center;'><strong style='margin-right:0.5em;'>Filter by Level:</strong>"
            foreach ($level in $logLevelsInReport) {
                if ([string]::IsNullOrWhiteSpace($level)) { continue } 
                $safeLevel = ConvertTo-SafeHtml $level
                $htmlBodyLocal += "<label style='white-space: nowrap;'><input type='checkbox' class='log-level-filter' value='$safeLevel' checked> $safeLevel</label>"
            }
            $htmlBodyLocal += "</div>" 
        }
        $htmlBodyLocal += "</div>" 

        $htmlBodyLocal += "<div id='detailedLogEntries'>" 
        $ReportData.LogEntries | ForEach-Object {
            $entryClass = "log-$(ConvertTo-SafeHtml $_.Level)" 
            $htmlBodyLocal += "<div class='log-entry $entryClass' data-level='$(ConvertTo-SafeHtml $_.Level)'><strong>$(ConvertTo-SafeHtml $_.Timestamp) [$(ConvertTo-SafeHtml $_.Level)]</strong> <span>$(ConvertTo-SafeHtml $_.Message)</span></div>"
        }
        $htmlBodyLocal += "</div>" 
        $htmlBodyLocal += "</div>" 

    } elseif ($reportShowLogEntries) { 
         $htmlBodyLocal += "<div class='details-section log-section'><h2>Detailed Log</h2><p>No log entries were recorded or available for this HTML report.</p></div>"
    }
    
    $htmlBodyLocal += "<footer>"
    if (-not [string]::IsNullOrWhiteSpace($reportCompanyName)) { 
        $htmlBodyLocal += "$($reportCompanyName) - " 
    }
    $htmlBodyLocal += "PoSh Backup Script - Generated on $(ConvertTo-SafeHtml ([string](Get-Date)))</footer>"
    $htmlBodyLocal += $logFilterJavaScript
    $htmlBodyLocal += "</div>" 
    # ----- END OF Invoke-HtmlReport CONTENT -----

    try {
        ConvertTo-Html -Head $htmlHead -Body $htmlBodyLocal -Title "$($reportTitlePrefix) - $(ConvertTo-SafeHtml $JobName)" |
        Set-Content -Path $reportFullPath -Encoding UTF8 -Force -ErrorAction Stop
        & $LocalWriteLog -Message "  - HTML report generated successfully: $reportFullPath" -ForegroundColour $Global:ColourSuccess
    } catch {
        & $LocalWriteLog -Message "[ERROR] Failed to generate HTML report '$reportFullPath'. Error: $($_.Exception.Message)" -Level "ERROR" -ForegroundColour $Global:ColourError
    }
}
#endregion

#region --- Exported Functions ---
Export-ModuleMember -Function Invoke-HtmlReport 
# The alias ConvertTo-SafeHtml is script-scoped and primarily for internal use in this module.
# If other modules need it, they should define their own or Utils.psm1 should provide a shared version.
#endregion
