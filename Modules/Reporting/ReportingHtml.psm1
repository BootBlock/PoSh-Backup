<#
.SYNOPSIS
    Generates detailed, interactive HTML reports for PoSh-Backup jobs. These reports feature
    customisable themes, CSS overrides, optional embedded logos, client-side JavaScript for
    dynamic log filtering and searching, persistent section states, table sorting, and more.
    Now includes a section for Remote Target Transfer details and archive checksum information.

.DESCRIPTION
    This module is dedicated to creating rich, interactive HTML reports that provide a comprehensive
    overview of a PoSh-Backup job's execution. It handles the assembly of HTML content,
    incorporation of styling, and embedding of client-side interactivity.

    Key features of the generated HTML reports:
    - Structured Sections: Includes clear sections for Summary (now with checksum details),
      Configuration Used, Hook Scripts Executed, Detailed Logs, and Remote Target Transfers.
      All main sections are collapsible and their state can be persisted via localStorage.
    - Customisable Appearance:
        - Themes: Supports themes via external CSS files.
        - CSS Variable Overrides: From PoSh-Backup configuration.
        - Custom User CSS: Link an additional user-provided CSS file.
    - Embedded Logo & Favicon: Optionally embeds a logo and a favicon.
    - Interactive Log Filtering: Client-side JavaScript for keyword and log level filtering,
      "Select All" / "Deselect All" buttons, and a visual cue when filters are active.
      Searched keywords are highlighted within log entries.
    - Dynamic Table Sorting: Summary, Configuration, Hooks, and Target Transfers tables can be
      sorted by clicking column headers.
    - Copy to Clipboard: For hook script output blocks.
    - Scroll to Top Button: Appears on long reports for easier navigation.
    - Simulation Banner: Clearly indicates if the report pertains to a simulation run.
    - Security: Employs HTML encoding to prevent XSS.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.9.2 # Added Checksum information to Summary table.
    DateCreated:    14-May-2025
    LastModified:   24-May-2025
    Purpose:        Interactive HTML report generation sub-module for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Called by the main Reporting.psm1 orchestrator module.
                    'Base.css' and theme CSS files should be present in '.\Config\Themes\'
                    relative to the main PoSh-Backup script for theming to work correctly.
                    The 'System.Web' assembly is beneficial for enhanced HTML encoding.
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
        The report includes sections for a job summary (now including checksum details), the configuration used,
        details of any executed hook scripts, a comprehensive list of log entries, and details of remote
        target transfers if applicable.

        Key features include:
        - Styling: Applies CSS from 'Base.css', a selected theme CSS file (e.g., 'Light.css', 'Dark.css'),
          CSS variable overrides from the configuration, and an optional user-specified custom CSS file.
        - Logo: Can embed a logo image into the report header.
        - Interactivity: Includes JavaScript for client-side filtering of log entries by keyword and log level,
          collapsible section state persistence, table sorting.
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
        summary statistics, log entries, hook script details, the configuration snapshot, target transfer
        details, checksum information, etc.
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

    # Internal helper to use the passed-in logger consistently for other messages
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
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
    $reportLogoPath          = $getReportSetting.Invoke('HtmlReportLogoPath', "") 
    $reportFaviconPathUser   = $getReportSetting.Invoke('HtmlReportFaviconPath', "") 
    $reportCustomCssPathUser = $getReportSetting.Invoke('HtmlReportCustomCssPath', "")
    $reportCompanyName       = ConvertTo-SafeHtml ($getReportSetting.Invoke('HtmlReportCompanyName', "PoSh Backup"))

    $reportThemeNameRaw      = $getReportSetting.Invoke('HtmlReportTheme', "Light") 
    $reportThemeName         = if ($reportThemeNameRaw -is [array]) { $reportThemeNameRaw[0] } else { $reportThemeNameRaw } 
    if ([string]::IsNullOrWhiteSpace($reportThemeName)) { $reportThemeName = "Light" } 

    # Consolidate CSS variable overrides
    $cssVariableOverrides = @{}
    $globalCssVarOverrides = $GlobalConfig.HtmlReportOverrideCssVariables
    if ($null -eq $globalCssVarOverrides -or -not ($globalCssVarOverrides -is [hashtable])) { $globalCssVarOverrides = @{} }
    $jobCssVarOverrides = $JobConfig.HtmlReportOverrideCssVariables
    if ($null -eq $jobCssVarOverrides -or -not ($jobCssVarOverrides -is [hashtable])) { $jobCssVarOverrides = @{} }

    $globalCssVarOverrides.GetEnumerator() | ForEach-Object { $cssVariableOverrides[$_.Name] = $_.Value } 
    $jobCssVarOverrides.GetEnumerator() | ForEach-Object { $cssVariableOverrides[$_.Name] = $_.Value }    

    # Determine which sections of the report to show
    $reportShowSummary         = $getReportSetting.Invoke('HtmlReportShowSummary', $true)
    $reportShowConfiguration   = $getReportSetting.Invoke('HtmlReportShowConfiguration', $true)
    $reportShowHooks           = $getReportSetting.Invoke('HtmlReportShowHooks', $true)
    $reportShowLogEntries      = $getReportSetting.Invoke('HtmlReportShowLogEntries', $true)
    $reportShowTargetTransfers = $true # Always attempt to show if data exists

    if (-not (Test-Path -Path $ReportDirectory -PathType Container)) {
        & $LocalWriteLog -Message "[ERROR] HTML Report output directory '$ReportDirectory' does not exist. Report cannot be generated for job '$JobName'." -Level "ERROR"
        return
    }

    $reportTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeJobNameForFile = $JobName -replace '[^a-zA-Z0-9_-]', '_' 
    $reportFileName = "$($safeJobNameForFile)_Report_$($reportTimestamp).html"
    $reportFullPath = Join-Path -Path $ReportDirectory -ChildPath $reportFileName

    & $LocalWriteLog -Message "[INFO] Generating HTML report for job '$JobName': '$reportFullPath' (Theme: $reportThemeName)" -Level "INFO"

    $mainScriptRoot = $GlobalConfig['_PoShBackup_PSScriptRoot'] 

    # --- Prepare CSS for injection ---
    $baseCssContent = ""; $themeCssContent = ""; $overrideCssVariablesStyleBlock = ""; $customUserCssContentFromFile = ""; $faviconLinkTag = ""
    $htmlMetaTags = "<meta charset=`"UTF-8`"><meta name=`"viewport`" content=`"width=device-width, initial-scale=1.0`">" 

    # Prepare Favicon Link Tag
    if (-not [string]::IsNullOrWhiteSpace($reportFaviconPathUser) -and (Test-Path -LiteralPath $reportFaviconPathUser -PathType Leaf)) {
        try {
            $faviconBytes = [System.IO.File]::ReadAllBytes($reportFaviconPathUser)
            $faviconBase64 = [System.Convert]::ToBase64String($faviconBytes)
            $faviconMimeType = switch ([System.IO.Path]::GetExtension($reportFaviconPathUser).ToLowerInvariant()) {
                ".png" { "image/png" } ".ico" { "image/x-icon" } ".svg" { "image/svg+xml" } default { "image/octet-stream" }
            }
            if ($faviconMimeType -ne "image/octet-stream") {
                $faviconLinkTag = "<link rel=`"icon`" type=`"$faviconMimeType`" href=`"data:$faviconMimeType;base64,$faviconBase64`">"
            } else {
                & $LocalWriteLog -Message "[WARNING] Favicon file '$reportFaviconPathUser' has an unrecognised extension for MIME type. Favicon might not display." -Level "WARNING"
            }
        } catch { & $LocalWriteLog -Message "[WARNING] Could not read or embed favicon from '$reportFaviconPathUser'. Error: $($_.Exception.Message)" -Level "WARNING" }
    }

    if ([string]::IsNullOrWhiteSpace($mainScriptRoot) -or -not (Test-Path $mainScriptRoot -PathType Container)) {
        & $LocalWriteLog -Message "[ERROR] Main script root path ('_PoShBackup_PSScriptRoot') not found or invalid in GlobalConfig. Cannot load theme CSS files from 'Config\Themes'. Report styling will be very minimal." -Level "ERROR"
        $finalCssToInject = "<style>body{font-family:sans-serif;margin:1em;} table,details{border-collapse:collapse;margin-top:1em;} th,td,summary{border:1px solid #ccc;padding:0.25em 0.5em;text-align:left;} h1,h2{color:#003366;}</style>"
    } else {
        $configThemesDir = Join-Path -Path $mainScriptRoot -ChildPath "Config\Themes"

        $baseCssFilePath = Join-Path -Path $configThemesDir -ChildPath "Base.css"
        if (Test-Path -LiteralPath $baseCssFilePath -PathType Leaf) {
            try { $baseCssContent = Get-Content -LiteralPath $baseCssFilePath -Raw -ErrorAction Stop }
            catch { & $LocalWriteLog -Message "[WARNING] Could not load 'Base.css' from '$baseCssFilePath'. Report may lack base styling. Error: $($_.Exception.Message)" -Level "WARNING" }
        } else { & $LocalWriteLog -Message "[WARNING] 'Base.css' not found at '$baseCssFilePath'. Report styling will heavily rely on theme CSS or be minimal." -Level "WARNING" }

        if (-not [string]::IsNullOrWhiteSpace($reportThemeName)) {
            $reportThemeNameString = [string]$reportThemeName 
            $safeThemeFileNameForFile = ($reportThemeNameString -replace '[^a-zA-Z0-9]', '') + ".css" 
            $themeCssFilePath = Join-Path -Path $configThemesDir -ChildPath $safeThemeFileNameForFile
            if (Test-Path -LiteralPath $themeCssFilePath -PathType Leaf) {
                try { $themeCssContent = Get-Content -LiteralPath $themeCssFilePath -Raw -ErrorAction Stop }
                catch { & $LocalWriteLog -Message "[WARNING] Could not load theme CSS file '$safeThemeFileNameForFile' from '$themeCssFilePath'. Error: $($_.Exception.Message)" -Level "WARNING" }
            } else {
                & $LocalWriteLog -Message "[WARNING] Theme CSS file '$safeThemeFileNameForFile' for selected theme '$reportThemeName' not found at '$themeCssFilePath'. Theme will not be applied." -Level "WARNING"
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
                & $LocalWriteLog -Message "  - Successfully loaded user custom CSS from '$reportCustomCssPathUser'." -Level "DEBUG"
            } catch { & $LocalWriteLog -Message "[WARNING] Could not load user custom CSS from '$reportCustomCssPathUser'. This CSS will not be applied. Error: $($_.Exception.Message)" -Level "WARNING" }
        }
        $finalCssToInject = "<style>" + $baseCssContent + $themeCssContent + "</style>" + $overrideCssVariablesStyleBlock + "<style>" + $customUserCssContentFromFile + "</style>"
    }

    # --- JavaScript ---
    $pageJavaScript = @"
<script>
document.addEventListener('DOMContentLoaded', function () {
    // Persistent Collapsible Sections Logic
    const DETAILS_LS_PREFIX = 'poshBackupReport_detailsState_';
    const collapsibleDetailsElements = document.querySelectorAll('details[id^="details-"]');

    collapsibleDetailsElements.forEach(details => {
        const storedState = localStorage.getItem(DETAILS_LS_PREFIX + details.id);
        if (storedState === 'closed' && details.open) { 
            details.removeAttribute('open');
        } else if (storedState === 'open' && !details.open) { 
            details.setAttribute('open', '');
        }
        details.addEventListener('toggle', function() {
            localStorage.setItem(DETAILS_LS_PREFIX + this.id, this.open ? 'open' : 'closed');
        });
    });

    const keywordSearchInput = document.getElementById('logKeywordSearch');
    const levelFilterCheckboxes = document.querySelectorAll('.log-level-filter');
    const logEntriesContainer = document.getElementById('detailedLogEntries');
    const selectAllButton = document.getElementById('logFilterSelectAll');
    const deselectAllButton = document.getElementById('logFilterDeselectAll');
    const filterIndicator = document.getElementById('logFilterActiveIndicator');
    let originalLogMessages = new Map(); 

    if (logEntriesContainer) {
        const logEntries = Array.from(logEntriesContainer.getElementsByClassName('log-entry'));
        logEntries.forEach((entry, index) => { 
            const messageSpan = entry.querySelector('span');
            if (messageSpan) originalLogMessages.set(index, messageSpan.innerHTML);
        });

        if (logEntries.length === 0 && (keywordSearchInput || levelFilterCheckboxes.length > 0)) {
            const filterControlsArea = document.querySelector('.log-filters');
            if(filterControlsArea) filterControlsArea.style.display = 'none';
            if(filterIndicator) filterIndicator.style.display = 'none';
        }

        function highlightText(text, keyword) {
            if (!keyword || !text) return text;
            const specialCharsPattern = '[.*+?^' + '$' + '{' + '}()|[\]\\\\]'; 
            const specialCharsRegex = new RegExp(specialCharsPattern, 'g');
            const escapedKeyword = keyword.replace(specialCharsRegex, '\\$&');
            
            const highlightRegex = new RegExp('(' + escapedKeyword + ')', 'gi');
            return text.replace(highlightRegex, '<span class="search-highlight">$1</span>');
        }

        function filterLogs() {
            const keyword = keywordSearchInput ? keywordSearchInput.value.toLowerCase().trim() : '';
            const activeLevelFilters = new Set();
            let allLevelsUnchecked = true; 
            let defaultLevelsAreChecked = true; 

            if (levelFilterCheckboxes.length > 0) {
                levelFilterCheckboxes.forEach(checkbox => {
                    if (checkbox.checked) {
                        activeLevelFilters.add(checkbox.value.toUpperCase());
                        allLevelsUnchecked = false; 
                    } else {
                        defaultLevelsAreChecked = false; 
                    }
                });
            } else { 
                allLevelsUnchecked = false; 
                defaultLevelsAreChecked = false;
            }

            logEntries.forEach((entry, index) => {
                const messageSpan = entry.querySelector('span');
                let entryTextContent = '';

                if (messageSpan && originalLogMessages.has(index)) { 
                     messageSpan.innerHTML = originalLogMessages.get(index); 
                     entryTextContent = messageSpan.textContent ? messageSpan.textContent.toLowerCase() : '';
                } else if (messageSpan) { 
                     entryTextContent = messageSpan.textContent ? messageSpan.textContent.toLowerCase() : '';
                }
                
                const entryLevel = entry.dataset.level ? entry.dataset.level.toUpperCase() : '';
                const keywordMatch = (keyword === '') || entryTextContent.includes(keyword);
                const levelMatch = allLevelsUnchecked || activeLevelFilters.size === 0 || activeLevelFilters.has(entryLevel);

                if (keywordMatch && levelMatch) {
                    entry.style.display = 'flex'; 
                    if (keyword !== '' && messageSpan) { 
                        messageSpan.innerHTML = highlightText(messageSpan.innerHTML, keyword);
                    }
                } else {
                    entry.style.display = 'none';
                }
            });

            let keywordFilterActive = (keywordSearchInput && keywordSearchInput.value.trim() !== '');
            let levelFilterActive = (levelFilterCheckboxes.length > 0 && !defaultLevelsAreChecked); 
            if (levelFilterCheckboxes.length > 0 && allLevelsUnchecked) { 
                levelFilterActive = true;
            }
            if (levelFilterCheckboxes.length > 0 && defaultLevelsAreChecked && !allLevelsUnchecked && activeLevelFilters.size === levelFilterCheckboxes.length) {
                 levelFilterActive = false;
            }

            const filtersInUse = keywordFilterActive || levelFilterActive;
            if (filterIndicator) {
                filterIndicator.style.display = filtersInUse ? 'inline-block' : 'none';
            }
        }

        if (keywordSearchInput) keywordSearchInput.addEventListener('input', filterLogs);
        if (levelFilterCheckboxes.length > 0) {
            levelFilterCheckboxes.forEach(checkbox => checkbox.addEventListener('change', filterLogs));
            filterLogs(); 
        }
        if (selectAllButton) selectAllButton.addEventListener('click', () => { levelFilterCheckboxes.forEach(cb => cb.checked = true); filterLogs(); });
        if (deselectAllButton) deselectAllButton.addEventListener('click', () => { levelFilterCheckboxes.forEach(cb => cb.checked = false); filterLogs(); });

    } else { 
        if (filterIndicator) filterIndicator.style.display = 'none';
        console.warn('Log entries container "detailedLogEntries" not found.');
    }

    const scrollTopButton = document.getElementById('scrollToTopBtn');
    if (scrollTopButton) {
        window.onscroll = () => { scrollTopButton.style.display = (document.body.scrollTop > 100 || document.documentElement.scrollTop > 100) ? "block" : "none"; };
        scrollTopButton.addEventListener('click', () => { document.body.scrollTop = 0; document.documentElement.scrollTop = 0; });
    }

    document.querySelectorAll('.copy-hook-output-btn').forEach(button => {
        button.addEventListener('click', function() {
            const preElement = this.nextElementSibling; 
            if (preElement && preElement.tagName === 'PRE') {
                navigator.clipboard.writeText(preElement.textContent || preElement.innerText).then(() => {
                    const originalText = this.textContent;
                    this.textContent = 'Copied!';
                    this.disabled = true;
                    setTimeout(() => { this.textContent = originalText; this.disabled = false; }, 2000);
                }).catch(err => console.error('Failed to copy hook output: ', err));
            }
        });
    });

    document.querySelectorAll('table[data-sortable-table]').forEach(makeTableSortable);

    function makeTableSortable(table) {
        const headers = table.querySelectorAll('thead th[data-sortable-column]');
        let currentSort = { columnIndex: -1, order: 'asc' }; 

        headers.forEach((header, colIndex) => {
            header.style.cursor = 'pointer';
            let arrowSpan = header.querySelector('.sort-arrow');
            if (!arrowSpan) { 
                arrowSpan = document.createElement('span');
                arrowSpan.className = 'sort-arrow';
                header.appendChild(arrowSpan);
            }
            header.setAttribute('aria-sort', 'none'); 

            header.addEventListener('click', () => {
                const tbody = table.querySelector('tbody');
                if (!tbody) return;
                const rowsArray = Array.from(tbody.querySelectorAll('tr'));
                
                const sortOrder = (currentSort.columnIndex === colIndex && currentSort.order === 'asc') ? 'desc' : 'asc';
                
                rowsArray.sort((rowA, rowB) => {
                    const cellA_element = rowA.cells[colIndex];
                    const cellB_element = rowB.cells[colIndex];
                    if (!cellA_element || !cellB_element) return 0;

                    const valA = (cellA_element.dataset.sortValue || cellA_element.textContent || '').trim().toLowerCase();
                    const valB = (cellB_element.dataset.sortValue || cellB_element.textContent || '').trim().toLowerCase();
                    
                    const numA = parseFloat(valA.replace(/,/g, '')); 
                    const numB = parseFloat(valB.replace(/,/g, ''));

                    let comparison = 0;
                    if (!isNaN(numA) && !isNaN(numB)) { 
                        comparison = numA - numB;
                    } else { 
                        comparison = valA.localeCompare(valB, undefined, {numeric: true, sensitivity: 'base'});
                    }
                    return sortOrder === 'asc' ? comparison : -comparison;
                });

                rowsArray.forEach(row => tbody.appendChild(row)); 

                headers.forEach(th => {
                    const thArrow = th.querySelector('.sort-arrow');
                    if (th === header) {
                        thArrow.textContent = sortOrder === 'asc' ? ' ▲' : ' ▼';
                        th.setAttribute('aria-sort', sortOrder === 'asc' ? 'ascending' : 'descending');
                    } else {
                        thArrow.textContent = '';
                        th.setAttribute('aria-sort', 'none');
                    }
                });
                
                currentSort = { columnIndex: colIndex, order: sortOrder };
            });
        });
    }
});
</script>
"@

    $htmlHead = $htmlMetaTags + $faviconLinkTag + $finalCssToInject 

    # --- Prepare Embedded Logo ---
    $embeddedLogoHtml = ""
    if (-not [string]::IsNullOrWhiteSpace($reportLogoPath) -and (Test-Path -LiteralPath $reportLogoPath -PathType Leaf)) {
        try {
            $logoBytes = [System.IO.File]::ReadAllBytes($reportLogoPath); $logoBase64 = [System.Convert]::ToBase64String($logoBytes)
            $logoMimeType = switch ([System.IO.Path]::GetExtension($reportLogoPath).ToLowerInvariant()) { ".png"{"image/png"} ".jpg"{"image/jpeg"} ".jpeg"{"image/jpeg"} ".gif"{"image/gif"} ".svg"{"image/svg+xml"} default {"image/octet-stream"} }
            if ($logoMimeType -ne "image/octet-stream") { $embeddedLogoHtml = "<img src='data:$($logoMimeType);base64,$($logoBase64)' alt='Report Logo' class='report-logo'>" }
        } catch { & $LocalWriteLog -Message "[WARNING] Could not embed logo from '$reportLogoPath'. Error: $($_.Exception.Message)" -Level "WARNING" }
    }

    # --- Build HTML Body ---
    $htmlBodyLocal = "<div class='container'>" 
    $isSimulation = $ReportData.IsSimulationReport -is [System.Management.Automation.SwitchParameter] ? $ReportData.IsSimulationReport.IsPresent : ($ReportData.IsSimulationReport -eq $true)
    if ($isSimulation) { $htmlBodyLocal += "<div class='simulation-banner'><strong>*** SIMULATION MODE RUN ***</strong> This report reflects a simulated backup. No actual files were changed or archives created.</div>" }
    $headerTitle = "$($reportTitlePrefix) - $(ConvertTo-SafeHtml $JobName)"
    if ($reportThemeName.ToLowerInvariant() -eq "retroterminal") { $headerTitle += "<span class='blinking-cursor'></span>" }
    $htmlBodyLocal += "<div class='report-header'><h1>$headerTitle</h1>$($embeddedLogoHtml)</div>"

    # Summary Section
    if ($reportShowSummary -and ($ReportData.Keys -contains 'OverallStatus') ) {
        $htmlBodyLocal += "<div class='details-section summary-section'><details id='details-summary' open><summary><h2>Summary</h2></summary>"
        $htmlBodyLocal += "<table data-sortable-table='true'><thead><tr><th data-sortable-column='true' aria-label='Sort by Item'>Item</th><th data-sortable-column='true' aria-label='Sort by Detail'>Detail</th></tr></thead><tbody>"
        
        # Define the desired order of summary items
        $summaryOrder = @(
            'JobName', 'OverallStatus', 'ScriptStartTime', 'ScriptEndTime', 'TotalDuration', 'TotalDurationSeconds', 
            'SourcePath', 'EffectiveSourcePath', 'FinalArchivePath', 'ArchiveSizeFormatted', 'ArchiveSizeBytes', 
            'SevenZipExitCode', 'TreatSevenZipWarningsAsSuccess', 'RetryAttemptsMade', 
            'ArchiveTested', 'ArchiveTestResult', 'TestRetryAttemptsMade',
            'ArchiveChecksum', 'ArchiveChecksumAlgorithm', 'ArchiveChecksumFile', 'ArchiveChecksumVerificationStatus', # NEW Checksum fields
            'VSSAttempted', 'VSSStatus', 'VSSShadowPaths', 
            'PasswordSource', 'ErrorMessage'
        )

        # Create a temporary ordered dictionary for sorted display
        $summaryDisplayItems = [ordered]@{}
        foreach($key in $summaryOrder) {
            if ($ReportData.ContainsKey($key)) {
                $summaryDisplayItems[$key] = $ReportData[$key]
            }
        }
        # Add any remaining items from ReportData not in summaryOrder (maintains them if new ones are added)
        # Exclude 'TargetTransfers' here as it will have its own section
        $ReportData.GetEnumerator() | Where-Object {$_.Name -notin $summaryOrder -and $_.Name -notin @('LogEntries', 'JobConfiguration', 'HookScripts', 'IsSimulationReport', '_PoShBackup_PSScriptRoot', 'TargetTransfers')} | ForEach-Object {
            $summaryDisplayItems[$_.Name] = $_.Value
        }

        $summaryDisplayItems.GetEnumerator() | ForEach-Object {
            $keyName = ConvertTo-SafeHtml $_.Name
            $value = $_.Value
            $displayValue = ""
            $statusClass = ""
            $sortAttr = ""

            if ($value -is [array]) { 
                $displayValue = ($value | ForEach-Object { ConvertTo-SafeHtml ([string]$_) }) -join '<br>' 
            } else { 
                $displayValue = ConvertTo-SafeHtml ([string]$value) 
            }

            if ($keyName -eq "OverallStatus" -or $keyName -eq "ArchiveTestResult" -or $keyName -eq "VSSStatus" -or $keyName -eq "ArchiveChecksumVerificationStatus") {
                $sanitizedVal = ([string]$_.Value -replace ' ','_') -replace '[\(\):\/]','_' -replace '\+','plus' -replace ',',''
                $statusClass = "status-$(ConvertTo-SafeHtml $sanitizedVal)"
            } elseif ($keyName -eq "VSSAttempted") {
                $statusClass = if ($value -eq $true) { "status-INFO" } else { "status-DEFAULT" } 
            }

            if ($keyName -eq "ArchiveSizeFormatted" -and $ReportData.ContainsKey("ArchiveSizeBytes") -and $ReportData.ArchiveSizeBytes -is [long]) {
                $sortAttr = "data-sort-value='$($ReportData.ArchiveSizeBytes)'"
            } elseif ($keyName -eq "TotalDuration" -and $ReportData.ContainsKey("TotalDurationSeconds") -and $ReportData.TotalDurationSeconds -is [double]) {
                $sortAttr = "data-sort-value='$($ReportData.TotalDurationSeconds)'"
            }
            
            $htmlBodyLocal += "<tr><td data-label='Item'>$($keyName)</td><td data-label='Detail' class='$($statusClass)' $sortAttr>$($displayValue)</td></tr>"
        }
        $htmlBodyLocal += "</tbody></table></details></div>"
    }

    # --- NEW: Remote Target Transfers Section ---
    if ($reportShowTargetTransfers -and $ReportData.ContainsKey('TargetTransfers') -and ($null -ne $ReportData.TargetTransfers) -and $ReportData.TargetTransfers.Count -gt 0) {
        $htmlBodyLocal += "<div class='details-section target-transfers-section'><details id='details-target-transfers' open><summary><h2>Remote Target Transfers</h2></summary>"
        $htmlBodyLocal += "<table data-sortable-table='true'><thead><tr>"
        $htmlBodyLocal += "<th data-sortable-column='true' aria-label='Sort by Target Name'>Target Name</th>"
        $htmlBodyLocal += "<th data-sortable-column='true' aria-label='Sort by Type'>Type</th>"
        $htmlBodyLocal += "<th data-sortable-column='true' aria-label='Sort by Status'>Status</th>"
        $htmlBodyLocal += "<th data-sortable-column='true' aria-label='Sort by Remote Path'>Remote Path</th>"
        $htmlBodyLocal += "<th data-sortable-column='true' aria-label='Sort by Duration'>Duration</th>"
        $htmlBodyLocal += "<th data-sortable-column='true' aria-label='Sort by Size'>Size</th>"
        $htmlBodyLocal += "<th>Error Message</th>" # Error messages usually not good for sorting
        $htmlBodyLocal += "</tr></thead><tbody>"
        
        foreach ($transferEntry in $ReportData.TargetTransfers) {
            $targetNameSafe = ConvertTo-SafeHtml $transferEntry.TargetName
            $targetTypeSafe = ConvertTo-SafeHtml $transferEntry.TargetType
            $targetStatusSafe = ConvertTo-SafeHtml $transferEntry.Status
            $targetStatusClass = "status-$(($transferEntry.Status -replace ' ','_') -replace '[\(\):\/]','_' -replace '\+','plus')"
            $remotePathSafe = ConvertTo-SafeHtml $transferEntry.RemotePath
            $durationSafe = ConvertTo-SafeHtml $transferEntry.TransferDuration
            $sizeFormattedSafe = ConvertTo-SafeHtml $transferEntry.TransferSizeFormatted
            # Ensure TransferSize is present and a long before using for sort-value
            $sizeBytesSortAttr = if ($transferEntry.PSObject.Properties.Name -contains "TransferSize" -and $transferEntry.TransferSize -is [long]) { "data-sort-value='$($transferEntry.TransferSize)'" } else { "" }
            $errorMsgSafe = if (-not [string]::IsNullOrWhiteSpace($transferEntry.ErrorMessage)) { ConvertTo-SafeHtml $transferEntry.ErrorMessage } else { "<em>N/A</em>" }

            $htmlBodyLocal += "<tr>"
            $htmlBodyLocal += "<td data-label='Target Name'>$targetNameSafe</td>"
            $htmlBodyLocal += "<td data-label='Type'>$targetTypeSafe</td>"
            $htmlBodyLocal += "<td data-label='Status' class='$targetStatusClass'>$targetStatusSafe</td>"
            $htmlBodyLocal += "<td data-label='Remote Path'>$remotePathSafe</td>"
            $htmlBodyLocal += "<td data-label='Duration'>$durationSafe</td>"
            $htmlBodyLocal += "<td data-label='Size' $sizeBytesSortAttr>$sizeFormattedSafe</td>"
            $htmlBodyLocal += "<td data-label='Error Message'>$errorMsgSafe</td>"
            $htmlBodyLocal += "</tr>"
        }
        $htmlBodyLocal += "</tbody></table></details></div>"
    }
    # --- END NEW: Remote Target Transfers Section ---

    # Configuration Section
    if ($reportShowConfiguration -and ($ReportData.Keys -contains 'JobConfiguration') -and ($null -ne $ReportData.JobConfiguration)) {
        $htmlBodyLocal += "<div class='details-section config-section'><details id='details-config'><summary><h2>Configuration Used for Job '$(ConvertTo-SafeHtml $JobName)'</h2></summary>"
        $htmlBodyLocal += "<table data-sortable-table='true'><thead><tr><th data-sortable-column='true' aria-label='Sort by Setting'>Setting</th><th data-sortable-column='true' aria-label='Sort by Value'>Value</th></tr></thead><tbody>"
        foreach ($key in $ReportData.JobConfiguration.Keys | Sort-Object) {
            $value = $ReportData.JobConfiguration[$key]
            $displayValue = if ($value -is [array]) { ($value | ForEach-Object { ConvertTo-SafeHtml ([string]$_) }) -join ", " } else { ConvertTo-SafeHtml ([string]$value) }
            $htmlBodyLocal += "<tr><td data-label='Setting'>$(ConvertTo-SafeHtml $key)</td><td data-label='Value'>$($displayValue)</td></tr>"
        }
        $htmlBodyLocal += "</tbody></table></details></div>"
    }

    # Hook Scripts Section
    if ($reportShowHooks -and ($ReportData.Keys -contains 'HookScripts') -and ($null -ne $ReportData.HookScripts) -and $ReportData.HookScripts.Count -gt 0) {
        $htmlBodyLocal += "<div class='details-section hooks-section'><details id='details-hooks'><summary><h2>Hook Scripts Executed</h2></summary>"
        $htmlBodyLocal += "<table data-sortable-table='true'><thead><tr><th data-sortable-column='true' aria-label='Sort by Type'>Type</th><th data-sortable-column='true' aria-label='Sort by Path'>Path</th><th data-sortable-column='true' aria-label='Sort by Status'>Status</th><th>Output/Error</th></tr></thead><tbody>"
        $ReportData.HookScripts | ForEach-Object {
            $sanitizedStatusVal = ([string]$_.Status -replace ' ','_') -replace '[\(\):\/]','_' -replace '\+','plus'; $statusClass = "status-$(ConvertTo-SafeHtml $sanitizedStatusVal)"
            $hookOutputHtml = ""
            if ([string]::IsNullOrWhiteSpace($_.Output)) { $hookOutputHtml = "<em><No output></em>" } 
            else { 
                $hookOutputHtml = "<div class='pre-container'><button type='button' class='copy-hook-output-btn' title='Copy Hook Output' aria-label='Copy hook output to clipboard'>Copy</button><pre>$(ConvertTo-SafeHtml $_.Output)</pre></div>"
            }
            $htmlBodyLocal += "<tr><td data-label='Hook Type'>$(ConvertTo-SafeHtml $_.Name)</td><td data-label='Path'>$(ConvertTo-SafeHtml $_.Path)</td><td data-label='Status' class='$($statusClass)'>$(ConvertTo-SafeHtml $_.Status)</td><td data-label='Output/Error'>$($hookOutputHtml)</td></tr>"
        }
        $htmlBodyLocal += "</tbody></table></details></div>"
    }

    # Detailed Log Entries Section
    if ($reportShowLogEntries -and ($ReportData.Keys -contains 'LogEntries') -and ($null -ne $ReportData.LogEntries) -and $ReportData.LogEntries.Count -gt 0) {
        $htmlBodyLocal += "<div class='details-section log-section'><details id='details-logs' open><summary><h2>Detailed Log <span id='logFilterActiveIndicator' class='filter-active-indicator' style='display:none;'>(Filters Active)</span></h2></summary>"
        $htmlBodyLocal += "<div class='log-filters'>" 
        $htmlBodyLocal += "<div><label for='logKeywordSearch'>Search Logs:</label><input type='text' id='logKeywordSearch' placeholder='Enter keyword...'></div>"
        $logLevelsInReport = ($ReportData.LogEntries.Level | Select-Object -Unique | Sort-Object | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($logLevelsInReport.Count -gt 0) {
            $htmlBodyLocal += "<div class='log-level-filters-container'><strong>Filter by Level:</strong>"
            foreach ($level in $logLevelsInReport) { $safeLevel = ConvertTo-SafeHtml $level; $htmlBodyLocal += "<label><input type='checkbox' class='log-level-filter' value='$safeLevel' checked> $safeLevel</label>" }
            $htmlBodyLocal += "<div class='log-level-toggle-buttons'><button type='button' id='logFilterSelectAll'>Select All</button><button type='button' id='logFilterDeselectAll'>Deselect All</button></div></div>" 
        }
        $htmlBodyLocal += "</div>" 
        $htmlBodyLocal += "<div id='detailedLogEntries'>"
        $ReportData.LogEntries | ForEach-Object { $entryClass = "log-$(ConvertTo-SafeHtml $_.Level)"; $htmlBodyLocal += "<div class='log-entry $entryClass' data-level='$(ConvertTo-SafeHtml $_.Level)'><strong>$(ConvertTo-SafeHtml $_.Timestamp) [$(ConvertTo-SafeHtml $_.Level)]</strong> <span>$(ConvertTo-SafeHtml $_.Message)</span></div>" }
        $htmlBodyLocal += "</div></details></div>" 
    } elseif ($reportShowLogEntries) { 
         $htmlBodyLocal += "<div class='details-section log-section'><details id='details-logs' open><summary><h2>Detailed Log</h2></summary><p>No log entries were recorded or available for this HTML report.</p></details></div>"
    }

    # Report Footer
    $htmlBodyLocal += "<footer>"
    if (-not [string]::IsNullOrWhiteSpace($reportCompanyName)) { $htmlBodyLocal += "$(ConvertTo-SafeHtml $reportCompanyName) - " }
    $htmlBodyLocal += "PoSh Backup Script - Report Generated on $(ConvertTo-SafeHtml ([string](Get-Date)))</footer>"
    $htmlBodyLocal += $pageJavaScript 
    $htmlBodyLocal += "</div>" # Close main .container div
    $htmlBodyLocal += "<button type='button' id='scrollToTopBtn' title='Go to top' aria-label='Scroll to top of page'>▲</button>" 

    # --- Generate and Write HTML File ---
    try {
        ConvertTo-Html -Head $htmlHead -Body $htmlBodyLocal -Title "$($reportTitlePrefix) - $(ConvertTo-SafeHtml $JobName)" |
        Set-Content -Path $reportFullPath -Encoding UTF8 -Force -ErrorAction Stop # Ensure BOM with UTF8 for broad compatibility
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
