<#
.SYNOPSIS
    Generates detailed, interactive HTML reports for PoSh-Backup jobs. These reports feature
    customisable themes, CSS overrides, optional embedded logos, client-side JavaScript for
    dynamic log filtering and searching, and a prominent banner for simulation mode runs.

.DESCRIPTION
    This module is dedicated to creating rich, interactive HTML reports that provide a comprehensive
    overview of a PoSh-Backup job's execution. It handles the assembly of HTML content,
    incorporation of styling, and embedding of client-side interactivity.

    Key features of the generated HTML reports:
    - Structured Sections: Includes clear sections for Summary, Configuration Used,
      Hook Scripts Executed, and Detailed Logs.
    - Customisable Appearance:
        - Themes: Supports themes via external CSS files located in 'Config\Themes\'. A 'Base.css'
          provides foundational styles, and specific theme files (e.g., 'Dark.css', 'Light.css')
          override CSS variables for different looks.
        - CSS Variable Overrides: Allows fine-grained style adjustments by overriding specific CSS
          variables directly from the PoSh-Backup configuration file.
        - Custom User CSS: Supports linking an additional user-provided CSS file for complete
          styling control.
    - Embedded Logo: Optionally embeds a company or project logo into the report header.
    - Interactive Log Filtering: Includes client-side JavaScript to allow users to filter
      the detailed log entries by keyword and log level directly in their browser.
    - Simulation Banner: Clearly indicates if the report pertains to a simulation run.
    - Security: Employs robust HTML encoding for all dynamic data to prevent Cross-Site
      Scripting (XSS) vulnerabilities. It attempts to use 'System.Web.HttpUtility.HtmlEncode'
      for enhanced encoding and falls back to a manual replacement method if System.Web is unavailable.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.3.1 # Added defensive logger call for PSSA.
    DateCreated:    14-May-2025
    LastModified:   17-May-2025
    Purpose:        Interactive HTML report generation sub-module for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Called by the main Reporting.psm1 orchestrator module.
                    'Base.css' and theme CSS files should be present in '.\Config\Themes\'
                    relative to the main PoSh-Backup script for theming to work correctly.
                    The 'System.Web' assembly is beneficial for enhanced HTML encoding but not strictly
                    required (a fallback mechanism is in place).
#>

#region --- HTML Encode Helper Function Definition & Setup ---
# This region handles the setup for HTML encoding, attempting to use System.Web for robust encoding
# and falling back to a simpler manual method if System.Web is not available.

# Script-scoped variable to track if System.Web.HttpUtility.HtmlEncode can be used.
$Script:PoshBackup_ReportingHtml_UseSystemWebHtmlEncode = $false
try {
    # Attempt to load the System.Web assembly. This might not be available in all PowerShell environments (e.g., PS Core by default).
    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

    # Check if the HttpUtility class is now accessible.
    $httpUtilityType = try { [System.Type]::GetType("System.Web.HttpUtility, System.Web, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a", $false) } catch { $null }

    if ($null -ne $httpUtilityType) {
        $Script:PoshBackup_ReportingHtml_UseSystemWebHtmlEncode = $true
        Write-Verbose "[ReportingHtml.psm1] System.Web.HttpUtility is available and will be used for HTML encoding."
    } else {
        Write-Warning "[ReportingHtml.psm1] System.Web.HttpUtility class was not found after attempting to load System.Web.dll. HTML encoding will use a basic manual sanitisation method. For more robust XSS protection, ensure the System.Web assembly is available or consider alternative encoding libraries if running in an environment where it's restricted."
    }
}
catch {
    # Catch any errors during Add-Type (e.g., assembly not found).
    Write-Warning "[ReportingHtml.psm1] An error occurred while trying to load System.Web.dll for enhanced HTML encoding. Error: $($_.Exception.Message). HTML encoding will use a basic manual sanitisation method."
}

# Internal function to perform HTML encoding.
# It uses System.Web.HttpUtility.HtmlEncode if available, otherwise falls back to manual replacements.
Function ConvertTo-PoshBackupSafeHtmlInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, ValueFromPipeline=$true)]
        [string]$Text
    )
    process {
        if ($null -eq $Text) { return '' }

        if ($Script:PoshBackup_ReportingHtml_UseSystemWebHtmlEncode) {
            try {
                return [System.Web.HttpUtility]::HtmlEncode($Text)
            }
            catch {
                # This fallback should ideally not be hit if UseSystemWebHtmlEncode is true, but included for extreme robustness.
                Write-Warning "[ReportingHtml.psm1] System.Web.HttpUtility.HtmlEncode call failed unexpectedly. Falling back to manual encoding for this instance."
                return $Text -replace '&', '&' -replace '<', '<' -replace '>', '>' -replace '"', '"' -replace "'", '&#39;'
            }
        } else {
            # Manual, basic HTML encoding for critical characters.
            return $Text -replace '&', '&' -replace '<', '<' -replace '>', '>' -replace '"', '"' -replace "'", '&#39;'
        }
    }
}

# Create a script-scoped alias for easier use within this module.
Set-Alias -Name ConvertTo-SafeHtml -Value ConvertTo-PoshBackupSafeHtmlInternal -Scope Script -ErrorAction SilentlyContinue -Force
if (-not (Get-Alias ConvertTo-SafeHtml -ErrorAction SilentlyContinue)) {
    Write-Warning "[ReportingHtml.psm1] Critical: Failed to set internal alias 'ConvertTo-SafeHtml'. HTML encoding might not function correctly."
}
#endregion


#region --- HTML Report Function ---
function Invoke-HtmlReport {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Generates a detailed and interactive HTML report for a specific PoSh-Backup job.
    .DESCRIPTION
        This function constructs an HTML report based on the provided job data and configuration settings.
        The report includes sections for a job summary, the configuration used, details of any executed
        hook scripts, and a comprehensive list of log entries.

        Key features include:
        - Styling: Applies CSS from 'Base.css', a selected theme CSS file (e.g., 'Light.css', 'Dark.css'),
          CSS variable overrides from the configuration, and an optional user-specified custom CSS file.
        - Logo: Can embed a logo image into the report header.
        - Interactivity: Includes JavaScript for client-side filtering of log entries by keyword and log level.
        - Simulation Indication: Displays a prominent banner if the report is for a simulated backup run.
        - Security: All dynamic data written to the HTML is encoded to prevent XSS.

        The function determines report customisation options (like title, theme, logo path, CSS overrides,
        and which sections to show) by looking up settings first in the job-specific configuration ($JobConfig)
        and then falling back to global configuration ($GlobalConfig).
    .PARAMETER ReportDirectory
        The target directory where the generated HTML report file for this job will be saved.
        This path is typically resolved by the main Reporting.psm1 orchestrator.
    .PARAMETER JobName
        The name of the backup job. Used in the HTML report title and for naming the output file.
    .PARAMETER ReportData
        A hashtable containing all data collected during the backup job's execution. This includes
        summary statistics, log entries, hook script details, the configuration snapshot, etc.
    .PARAMETER GlobalConfig
        The global configuration hashtable for PoSh-Backup. Used to retrieve global report settings
        (like default theme, company name) and the essential '_PoShBackup_PSScriptRoot' path for
        locating CSS theme files.
    .PARAMETER JobConfig
        The specific configuration hashtable for the job being reported on. Used to retrieve
        job-specific report overrides (e.g., a different theme or title prefix for this job's report).
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function from Utils.psm1.
        Used for logging the HTML report generation process.
    .EXAMPLE
        # This function is typically called by Reporting.psm1 (orchestrator)
        # $htmlParams = @{
        #     ReportDirectory = "C:\PoShBackup\Reports\HTML\MyServer"
        #     JobName         = "MyServerBackup"
        #     ReportData      = $JobReportDataObject
        #     GlobalConfig    = $Configuration
        #     JobConfig       = $Configuration.BackupLocations.MyServerBackup
        #     Logger          = ${function:Write-LogMessage}
        # }
        # Invoke-HtmlReport @htmlParams
    .OUTPUTS
        None. This function creates an HTML file in the specified ReportDirectory.
    #>
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

        [Parameter(Mandatory=$true)]
        [scriptblock]$Logger
    )

    # Defensive PSSA appeasement line: Logger is functionally used via $LocalWriteLog,
    # but this direct call ensures PSSA sees it explicitly.
    & $Logger -Message "Invoke-HtmlReport: Logger parameter active for job '$JobName'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if ($null -ne $ForegroundColour) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    # Helper to get report-specific settings, checking JobConfig then GlobalConfig
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

    # Retrieve HTML report customisation settings
    $reportTitlePrefix       = ConvertTo-SafeHtml ($getReportSetting.Invoke('HtmlReportTitlePrefix', "PoSh Backup Status Report"))
    $reportLogoPath          = $getReportSetting.Invoke('HtmlReportLogoPath', "") # Path is not HTML encoded here; content will be if embedded
    $reportCustomCssPathUser = $getReportSetting.Invoke('HtmlReportCustomCssPath', "") # Path to user's custom CSS
    $reportCompanyName       = ConvertTo-SafeHtml ($getReportSetting.Invoke('HtmlReportCompanyName', "PoSh Backup"))

    $reportThemeNameRaw      = $getReportSetting.Invoke('HtmlReportTheme', "Light") # Default to "Light" theme
    $reportThemeName         = if ($reportThemeNameRaw -is [array]) { $reportThemeNameRaw[0] } else { $reportThemeNameRaw } # Handle if accidentally an array
    if ([string]::IsNullOrWhiteSpace($reportThemeName)) { $reportThemeName = "Light" } # Ensure a theme name

    # Consolidate CSS variable overrides from global and job-specific configurations
    $cssVariableOverrides = @{}
    $globalCssVarOverrides = $GlobalConfig.HtmlReportOverrideCssVariables
    if ($null -eq $globalCssVarOverrides -or -not ($globalCssVarOverrides -is [hashtable])) { $globalCssVarOverrides = @{} }
    $jobCssVarOverrides = $JobConfig.HtmlReportOverrideCssVariables
    if ($null -eq $jobCssVarOverrides -or -not ($jobCssVarOverrides -is [hashtable])) { $jobCssVarOverrides = @{} }

    $globalCssVarOverrides.GetEnumerator() | ForEach-Object { $cssVariableOverrides[$_.Name] = $_.Value } # Global first
    $jobCssVarOverrides.GetEnumerator() | ForEach-Object { $cssVariableOverrides[$_.Name] = $_.Value }    # Job overrides global

    # Determine which sections of the report to show
    $reportShowSummary       = $getReportSetting.Invoke('HtmlReportShowSummary', $true)
    $reportShowConfiguration = $getReportSetting.Invoke('HtmlReportShowConfiguration', $true)
    $reportShowHooks         = $getReportSetting.Invoke('HtmlReportShowHooks', $true)
    $reportShowLogEntries    = $getReportSetting.Invoke('HtmlReportShowLogEntries', $true)

    if (-not (Test-Path -Path $ReportDirectory -PathType Container)) {
        & $LocalWriteLog -Message "[ERROR] HTML Report output directory '$ReportDirectory' does not exist. Report cannot be generated for job '$JobName'." -Level "ERROR"
        return
    }

    $reportTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeJobNameForFile = $JobName -replace '[^a-zA-Z0-9_-]', '_' # Sanitize for filename
    $reportFileName = "$($safeJobNameForFile)_Report_$($reportTimestamp).html"
    $reportFullPath = Join-Path -Path $ReportDirectory -ChildPath $reportFileName

    & $LocalWriteLog -Message "[INFO] Generating HTML report for job '$JobName': '$reportFullPath' (Theme: $reportThemeName)" -Level "INFO"

    $mainScriptRoot = $GlobalConfig['_PoShBackup_PSScriptRoot'] # Essential for finding themes

    # --- Prepare CSS for injection ---
    $baseCssContent = ""; $themeCssContent = ""; $overrideCssVariablesStyleBlock = ""; $customUserCssContentFromFile = ""
    $htmlMetaTags = "<meta charset=`"UTF-8`"><meta name=`"viewport`" content=`"width=device-width, initial-scale=1.0`">" # Basic meta tags

    if ([string]::IsNullOrWhiteSpace($mainScriptRoot) -or -not (Test-Path $mainScriptRoot -PathType Container)) {
        & $LocalWriteLog -Message "[ERROR] Main script root path ('_PoShBackup_PSScriptRoot') not found or invalid in GlobalConfig. Cannot load theme CSS files from 'Config\Themes'. Report styling will be very minimal." -Level "ERROR"
        # Fallback minimal CSS if themes cannot be loaded
        $finalCssToInject = "<style>body{font-family:sans-serif;margin:1em;} table{border-collapse:collapse;margin-top:1em;} th,td{border:1px solid #ccc;padding:0.25em 0.5em;text-align:left;} h1,h2{color:#003366;}</style>"
    } else {
        $configThemesDir = Join-Path -Path $mainScriptRoot -ChildPath "Config\Themes"

        # Load Base.css (foundational styles)
        $baseCssFilePath = Join-Path -Path $configThemesDir -ChildPath "Base.css"
        if (Test-Path -LiteralPath $baseCssFilePath -PathType Leaf) {
            try { $baseCssContent = Get-Content -LiteralPath $baseCssFilePath -Raw -ErrorAction Stop }
            catch { & $LocalWriteLog -Message "[WARNING] Could not load 'Base.css' from '$baseCssFilePath'. Report may lack base styling. Error: $($_.Exception.Message)" -Level "WARNING" }
        } else { & $LocalWriteLog -Message "[WARNING] 'Base.css' not found at '$baseCssFilePath'. Report styling will heavily rely on theme CSS or be minimal." -Level "WARNING" }

        # Load selected theme CSS
        if (-not [string]::IsNullOrWhiteSpace($reportThemeName)) {
            $reportThemeNameString = [string]$reportThemeName # Ensure it's a string
            $safeThemeFileNameForFile = ($reportThemeNameString -replace '[^a-zA-Z0-9]', '') + ".css" # Sanitize theme name for filename
            $themeCssFilePath = Join-Path -Path $configThemesDir -ChildPath $safeThemeFileNameForFile
            if (Test-Path -LiteralPath $themeCssFilePath -PathType Leaf) {
                try { $themeCssContent = Get-Content -LiteralPath $themeCssFilePath -Raw -ErrorAction Stop }
                catch { & $LocalWriteLog -Message "[WARNING] Could not load theme CSS file '$safeThemeFileNameForFile' from '$themeCssFilePath'. Error: $($_.Exception.Message)" -Level "WARNING" }
            } else {
                & $LocalWriteLog -Message "[WARNING] Theme CSS file '$safeThemeFileNameForFile' for selected theme '$reportThemeName' not found at '$themeCssFilePath'. Theme will not be applied." -Level "WARNING"
            }
        }

        # Generate style block for CSS variable overrides from configuration
        if ($cssVariableOverrides.Count -gt 0) {
            $overrideCssVariablesStyleBlock = "<style>:root {"
            $cssVariableOverrides.GetEnumerator() | ForEach-Object {
                $varName = ($_.Name -replace '[^a-zA-Z0-9_-]', '') # Basic sanitization for CSS variable name
                $varValue = $_.Value # Value is used as-is, should be valid CSS
                if (-not $varName.StartsWith("--")) { $varName = "--" + $varName } # Ensure it's a CSS variable
                $overrideCssVariablesStyleBlock += "$varName : $varValue ;"
            }
            $overrideCssVariablesStyleBlock += "}</style>"
        }

        # Load user's custom CSS file if specified
        if (-not [string]::IsNullOrWhiteSpace($reportCustomCssPathUser) -and (Test-Path -LiteralPath $reportCustomCssPathUser -PathType Leaf)) {
            try {
                $customUserCssContentFromFile = Get-Content -LiteralPath $reportCustomCssPathUser -Raw -ErrorAction Stop
                & $LocalWriteLog -Message "  - Successfully loaded user custom CSS from '$reportCustomCssPathUser'." -Level "DEBUG"
            } catch { & $LocalWriteLog -Message "[WARNING] Could not load user custom CSS from '$reportCustomCssPathUser'. This CSS will not be applied. Error: $($_.Exception.Message)" -Level "WARNING" }
        }
        # Combine all CSS components for injection into the HTML head
        $finalCssToInject = "<style>" + $baseCssContent + $themeCssContent + "</style>" + $overrideCssVariablesStyleBlock + "<style>" + $customUserCssContentFromFile + "</style>"
    }

    # --- JavaScript for Log Filtering ---
    $logFilterJavaScript = @"
<script>
document.addEventListener('DOMContentLoaded', function () {
    const keywordSearchInput = document.getElementById('logKeywordSearch');
    const levelFilterCheckboxes = document.querySelectorAll('.log-level-filter');
    const logEntriesContainer = document.getElementById('detailedLogEntries');

    if (!logEntriesContainer) {
        console.warn('Log entries container "detailedLogEntries" not found. Log filtering disabled.');
        return;
    }
    const logEntries = Array.from(logEntriesContainer.getElementsByClassName('log-entry'));
    if (logEntries.length === 0 && (keywordSearchInput || levelFilterCheckboxes.length > 0)) {
        // If there are no log entries but filter controls exist, hide the filter controls area.
        const filterControlsArea = document.querySelector('.log-filters');
        if(filterControlsArea) filterControlsArea.style.display = 'none';
        return;
    }


    function filterLogs() {
        const keyword = keywordSearchInput ? keywordSearchInput.value.toLowerCase().trim() : '';
        const activeLevelFilters = new Set();
        let allLevelsUnchecked = true; // Assume all unchecked initially

        if (levelFilterCheckboxes.length > 0) {
            levelFilterCheckboxes.forEach(checkbox => {
                if (checkbox.checked) {
                    activeLevelFilters.add(checkbox.value.toUpperCase());
                    allLevelsUnchecked = false; // At least one is checked
                }
            });
        } else {
            allLevelsUnchecked = false; // No checkboxes means effectively no level filtering by checkbox
        }


        logEntries.forEach(entry => {
            const entryText = entry.textContent ? entry.textContent.toLowerCase() : '';
            // data-level attribute is preferred for robustness over parsing from text
            const entryLevel = entry.dataset.level ? entry.dataset.level.toUpperCase() : '';

            const keywordMatch = (keyword === '') || entryText.includes(keyword);
            // If all level checkboxes are unchecked, or if no level checkboxes exist, treat as "show all levels" for this part of the filter.
            // If some are checked, then the entry's level must be in the active set.
            const levelMatch = allLevelsUnchecked || activeLevelFilters.size === 0 || activeLevelFilters.has(entryLevel);

            if (keywordMatch && levelMatch) {
                entry.style.display = 'flex'; // Assuming 'flex' is the default display style from CSS
            } else {
                entry.style.display = 'none';
            }
        });
    }

    if (keywordSearchInput) {
        keywordSearchInput.addEventListener('input', filterLogs); // 'input' for more responsive filtering
    }
    if (levelFilterCheckboxes.length > 0) {
        levelFilterCheckboxes.forEach(checkbox => {
            checkbox.addEventListener('change', filterLogs);
        });
        // Initial filter call in case some checkboxes start unchecked or keyword field has a default (though unlikely here)
        filterLogs();
    }
});
</script>
"@

    $htmlHead = $htmlMetaTags + $finalCssToInject # Combine meta tags and all CSS

    # --- Prepare Embedded Logo (if configured) ---
    $embeddedLogoHtml = ""
    if (-not [string]::IsNullOrWhiteSpace($reportLogoPath) -and (Test-Path -LiteralPath $reportLogoPath -PathType Leaf)) {
        try {
            $logoBytes = [System.IO.File]::ReadAllBytes($reportLogoPath)
            $logoBase64 = [System.Convert]::ToBase64String($logoBytes)
            # Determine MIME type from extension for better browser compatibility
            $logoMimeType = switch ([System.IO.Path]::GetExtension($reportLogoPath).ToLowerInvariant()) {
                ".png"  { "image/png" }
                ".jpg"  { "image/jpeg" }
                ".jpeg" { "image/jpeg" }
                ".gif"  { "image/gif" }
                ".svg"  { "image/svg+xml"} # SVG needs svg+xml
                default { "image/octet-stream" } # Fallback, browser might not render
            }
            if ($logoMimeType -ne "image/octet-stream") {
                $embeddedLogoHtml = "<img src='data:$($logoMimeType);base64,$($logoBase64)' alt='Report Logo' class='report-logo'>"
                & $LocalWriteLog -Message "  - Logo successfully prepared for embedding from '$reportLogoPath'." -Level "DEBUG"
            } else {
                 & $LocalWriteLog -Message "[WARNING] Logo file '$reportLogoPath' has an unrecognised extension for MIME type determination. Logo might not display correctly." -Level "WARNING"
            }
        } catch { & $LocalWriteLog -Message "[WARNING] Could not read or embed logo from '$reportLogoPath'. Error: $($_.Exception.Message)" -Level "WARNING"}
    }

    # --- Build HTML Body ---
    $htmlBodyLocal = "<div class='container'>" # Start main content container

    # Add Simulation Banner if applicable
    $isSimulation = $false
    if ($ReportData.ContainsKey('IsSimulationReport')) { # Check modern flag first
        if ($ReportData.IsSimulationReport -is [System.Management.Automation.SwitchParameter]) {
             $isSimulation = $ReportData.IsSimulationReport.IsPresent
        } elseif ($ReportData.IsSimulationReport -is [bool]) {
            $isSimulation = $ReportData.IsSimulationReport
        }
    } elseif ($ReportData.ContainsKey('OverallStatus') -and ($ReportData.OverallStatus -is [string]) -and $ReportData.OverallStatus.ToUpperInvariant().Contains("SIMULAT")) {
        # Fallback check based on status string for older data structures if IsSimulationReport isn't present
        $isSimulation = $true
    }

    if ($isSimulation) {
        $htmlBodyLocal += "<div class='simulation-banner'><strong>*** SIMULATION MODE RUN ***</strong> This report reflects a simulated backup. No actual files were changed or archives created.</div>"
    }

    # Report Header (Title and Logo)
    $headerTitle = "$($reportTitlePrefix) - $(ConvertTo-SafeHtml $JobName)"
    if ($reportThemeName.ToLowerInvariant() -eq "retroterminal") { # Add blinking cursor for retro theme
        $headerTitle += "<span class='blinking-cursor'></span>"
    }
    $htmlBodyLocal += "<div class='report-header'><h1>$headerTitle</h1>$($embeddedLogoHtml)</div>"

    # Summary Section
    if ($reportShowSummary -and ($ReportData.Keys -contains 'OverallStatus') ) {
        $htmlBodyLocal += "<div class='details-section summary-section'><h2>Summary</h2><table>"
        $ReportData.GetEnumerator() | Where-Object {$_.Name -notin @('LogEntries', 'JobConfiguration', 'HookScripts', 'IsSimulationReport', '_PoShBackup_PSScriptRoot')} | ForEach-Object {
            $keyName = ConvertTo-SafeHtml $_.Name
            $value = $_.Value
            # Format array values as multi-line in HTML using <br>
            $displayValue = if ($value -is [array]) { ($value | ForEach-Object { ConvertTo-SafeHtml ([string]$_) }) -join '<br>' } else { ConvertTo-SafeHtml ([string]$value) }
            # Apply status-specific CSS classes for key summary items
            $statusClass = ""
            if ($_.Name -in @("OverallStatus", "ArchiveTestResult", "VSSStatus")) {
                 $sanitizedStatusValue = ([string]$_.Value -replace ' ','_') -replace '\(','_' -replace '\)','_' -replace ':','' -replace '/','_' -replace '\+','plus' # Ensure valid CSS class
                 $statusClass = "status-$(ConvertTo-SafeHtml $sanitizedStatusValue)"
            }
            $htmlBodyLocal += "<tr><td data-label='Item'>$($keyName)</td><td data-label='Detail' class='$($statusClass)'>$($displayValue)</td></tr>"
        }
        $htmlBodyLocal += "</table></div>"
    }

    # Configuration Section
    if ($reportShowConfiguration -and ($ReportData.Keys -contains 'JobConfiguration') -and ($null -ne $ReportData.JobConfiguration)) {
        $htmlBodyLocal += "<div class='details-section config-section'><h2>Configuration Used for Job '$(ConvertTo-SafeHtml $JobName)'</h2><table>"
        $htmlBodyLocal += "<thead><tr><th>Setting</th><th>Value</th></tr></thead><tbody>"
        # Sort configuration keys for consistent order
        foreach ($key in $ReportData.JobConfiguration.Keys | Sort-Object) {
            $value = $ReportData.JobConfiguration[$key]
            $displayValue = if ($value -is [array]) { ($value | ForEach-Object { ConvertTo-SafeHtml ([string]$_) }) -join ", " } else { ConvertTo-SafeHtml ([string]$value) }
            $htmlBodyLocal += "<tr><td data-label='Setting'>$(ConvertTo-SafeHtml $key)</td><td data-label='Value'>$($displayValue)</td></tr>"
        }
        $htmlBodyLocal += "</tbody></table></div>"
    }

    # Hook Scripts Section
    if ($reportShowHooks -and ($ReportData.Keys -contains 'HookScripts') -and ($null -ne $ReportData.HookScripts) -and $ReportData.HookScripts.Count -gt 0) {
        $htmlBodyLocal += "<div class='details-section hooks-section'><h2>Hook Scripts Executed</h2><table>"
        $htmlBodyLocal += "<thead><tr><th>Type</th><th>Path</th><th>Status</th><th>Output/Error</th></tr></thead><tbody>"
        $ReportData.HookScripts | ForEach-Object {
            $sanitizedStatusValue = ([string]$_.Status -replace ' ','_') -replace '\(','_' -replace '\)','_' -replace ':','' -replace '/','_' -replace '\+','plus'
            $statusClass = "status-$(ConvertTo-SafeHtml $sanitizedStatusValue)"
            # Hook output is wrapped in <pre> for preserving formatting
            $hookOutputHtml = if ([string]::IsNullOrWhiteSpace($_.Output)) { "<No output>" } else { "<pre>$(ConvertTo-SafeHtml $_.Output)</pre>" }
            $htmlBodyLocal += "<tr><td data-label='Hook Type'>$(ConvertTo-SafeHtml $_.Name)</td><td data-label='Path'>$(ConvertTo-SafeHtml $_.Path)</td><td data-label='Status' class='$($statusClass)'>$(ConvertTo-SafeHtml $_.Status)</td><td data-label='Output/Error'>$($hookOutputHtml)</td></tr>"
        }
        $htmlBodyLocal += "</tbody></table></div>"
    }

    # Detailed Log Entries Section (with filter controls)
    if ($reportShowLogEntries -and ($ReportData.Keys -contains 'LogEntries') -and ($null -ne $ReportData.LogEntries) -and $ReportData.LogEntries.Count -gt 0) {
        $htmlBodyLocal += "<div class='details-section log-section'><h2>Detailed Log</h2>"
        # Filter controls HTML structure
        $htmlBodyLocal += "<div class='log-filters'>" # Style this container via CSS
        $htmlBodyLocal += "<div><label for='logKeywordSearch'>Search Logs:</label><input type='text' id='logKeywordSearch' placeholder='Enter keyword...'></div>"

        $logLevelsInReport = ($ReportData.LogEntries.Level | Select-Object -Unique | Sort-Object | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($logLevelsInReport.Count -gt 0) {
            $htmlBodyLocal += "<div class='log-level-filters-container'><strong>Filter by Level:</strong>"
            foreach ($level in $logLevelsInReport) {
                $safeLevel = ConvertTo-SafeHtml $level
                $htmlBodyLocal += "<label><input type='checkbox' class='log-level-filter' value='$safeLevel' checked> $safeLevel</label>"
            }
            $htmlBodyLocal += "</div>" # Close log-level-filters-container
        }
        $htmlBodyLocal += "</div>" # Close log-filters

        # Log entries container
        $htmlBodyLocal += "<div id='detailedLogEntries'>"
        $ReportData.LogEntries | ForEach-Object {
            $entryClass = "log-$(ConvertTo-SafeHtml $_.Level)" # CSS class based on log level
            # Store level in data-attribute for easier JS filtering
            $htmlBodyLocal += "<div class='log-entry $entryClass' data-level='$(ConvertTo-SafeHtml $_.Level)'><strong>$(ConvertTo-SafeHtml $_.Timestamp) [$(ConvertTo-SafeHtml $_.Level)]</strong> <span>$(ConvertTo-SafeHtml $_.Message)</span></div>"
        }
        $htmlBodyLocal += "</div>" # Close detailedLogEntries
        $htmlBodyLocal += "</div>" # Close log-section

    } elseif ($reportShowLogEntries) { # Log section enabled but no logs
         $htmlBodyLocal += "<div class='details-section log-section'><h2>Detailed Log</h2><p>No log entries were recorded or available for this HTML report.</p></div>"
    }

    # Report Footer
    $htmlBodyLocal += "<footer>"
    if (-not [string]::IsNullOrWhiteSpace($reportCompanyName)) {
        $htmlBodyLocal += "$(ConvertTo-SafeHtml $reportCompanyName) - "
    }
    $htmlBodyLocal += "PoSh Backup Script - Report Generated on $(ConvertTo-SafeHtml ([string](Get-Date)))</footer>"
    $htmlBodyLocal += $logFilterJavaScript # Add the JavaScript block at the end of the body
    $htmlBodyLocal += "</div>" # Close main container

    # --- Generate and Write HTML File ---
    try {
        ConvertTo-Html -Head $htmlHead -Body $htmlBodyLocal -Title "$($reportTitlePrefix) - $(ConvertTo-SafeHtml $JobName)" |
        Set-Content -Path $reportFullPath -Encoding UTF8 -Force -ErrorAction Stop
        & $LocalWriteLog -Message "  - HTML report generated successfully: '$reportFullPath'" -Level "SUCCESS"
    } catch {
        & $LocalWriteLog -Message "[ERROR] Failed to generate HTML report '$reportFullPath' for job '$JobName'. Error: $($_.Exception.Message)" -Level "ERROR"
    }
    & $LocalWriteLog -Message "[INFO] HTML Report generation process finished for job '$JobName'." -Level "INFO"
}
#endregion

#region --- Exported Functions ---
Export-ModuleMember -Function Invoke-HtmlReport
#endregion
