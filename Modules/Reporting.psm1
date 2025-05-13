# PowerShell Module: Reporting.psm1
# Version 1.0: Uses _PoShBackup_PSScriptRoot from GlobalConfig for theme pathing.
#              Adds conditional flashing cursor to H1 for "RetroTerminal" theme.
#              Log message text colour driven by CSS classes.

#region --- HTML Encode Helper Function Definition ---
Function ConvertTo-PoshBackupSafeHtmlInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, ValueFromPipeline)]
        [string]$Text
    )
    
    if ($null -eq $Text) { return '' }

    if ($Script:PoshBackup_Reporting_UseSystemWebHtmlEncode) { 
        try { return [System.Web.HttpUtility]::HtmlEncode($Text) }
        catch {
            Write-Warning "[Reporting.psm1] System.Web.HttpUtility.HtmlEncode failed. Falling back to manual."
            return $Text -replace '&', '&' -replace '<', '<' -replace '>', '>' -replace '"', '"' -replace "'", '&#39;'
        }
    } else {
        return $Text -replace '&', '&' -replace '<', '<' -replace '>', '>' -replace '"', '"' -replace "'", '&#39;'
    }
}
#endregion

#region --- Module Top-Level Script Block (for Add-Type and Alias Export) ---
$Script:PoshBackup_Reporting_UseSystemWebHtmlEncode = $false 
try {
    Add-Type -AssemblyName System.Web -ErrorAction Stop
    $Script:PoshBackup_Reporting_UseSystemWebHtmlEncode = $true 
    Write-Verbose "[Reporting.psm1] System.Web.HttpUtility::HtmlEncode will be available."
} catch {
    Write-Warning "[Reporting.psm1] System.Web.dll could not be loaded. Using basic manual HTML sanitisation."
}

Set-Alias -Name ConvertTo-SafeHtml -Value ConvertTo-PoshBackupSafeHtmlInternal -Scope Script -ErrorAction SilentlyContinue
if (-not (Get-Alias ConvertTo-SafeHtml -ErrorAction SilentlyContinue)) {
    Write-Warning "[Reporting.psm1] Failed to set alias 'ConvertTo-SafeHtml'."
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
        [hashtable]$JobConfig 
    )
    
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
    $globalCssVarOverrides = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'HtmlReportOverrideCssVariables' -DefaultValue @{}
    $jobCssVarOverrides = Get-ConfigValue -ConfigObject $JobConfig -Key 'HtmlReportOverrideCssVariables' -DefaultValue @{}
    
    $globalCssVarOverrides.GetEnumerator() | ForEach-Object { $cssVariableOverrides[$_.Name] = $_.Value }
    $jobCssVarOverrides.GetEnumerator() | ForEach-Object { $cssVariableOverrides[$_.Name] = $_.Value }

    $reportShowSummary       = $getReportSetting.Invoke('HtmlReportShowSummary', $true)
    $reportShowConfiguration = $getReportSetting.Invoke('HtmlReportShowConfiguration', $true)
    $reportShowHooks         = $getReportSetting.Invoke('HtmlReportShowHooks', $true)
    $reportShowLogEntries    = $getReportSetting.Invoke('HtmlReportShowLogEntries', $true)
    
    if (-not (Test-Path -Path $ReportDirectory -PathType Container)) {
        Write-LogMessage "[ERROR] HTML Report directory '$ReportDirectory' does not exist. Report cannot be generated for job '$JobName'." -Level "ERROR" -ForegroundColour $Global:ColourError
        return
    }

    $reportTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeJobNameForFile = $JobName -replace '[^a-zA-Z0-9_-]', '_' 
    $reportFileName = "$($safeJobNameForFile)_Report_$($reportTimestamp).html"
    $reportFullPath = Join-Path -Path $ReportDirectory -ChildPath $reportFileName

    Write-LogMessage "`n[INFO] Generating HTML report: $reportFullPath (Theme: $reportThemeName)"

    # --- Load CSS Content ---
    $mainScriptRoot = $GlobalConfig['_PoShBackup_PSScriptRoot'] # Get from GlobalConfig (set by PoSh-Backup.ps1)
    
    $baseCssContent = ""; $themeCssContent = ""; $overrideCssVariablesStyleBlock = ""; $customUserCssContentFromFile = ""
    $htmlMetaTags = "<meta charset=`"UTF-8`"><meta name=`"viewport`" content=`"width=device-width, initial-scale=1.0`">" # Standard meta tags

    if ([string]::IsNullOrWhiteSpace($mainScriptRoot) -or -not (Test-Path $mainScriptRoot -PathType Container)) {
        Write-LogMessage "[ERROR] Main script root path ('_PoShBackup_PSScriptRoot') not found or invalid in GlobalConfig. Cannot load theme CSS files from 'Config\Themes'. Report styling will be minimal." -Level ERROR -ForegroundColour $Global:ColourError
        $finalCssToInject = "<style>body{font-family:sans-serif;margin:1em;} table{border-collapse:collapse;margin-top:1em;} th,td{border:1px solid #ccc;padding:0.25em 0.5em;text-align:left;} h1,h2{color:#003366;}</style>"
    } else {
        $configThemesDir = Join-Path -Path $mainScriptRoot -ChildPath "Config\Themes" # CSS themes are in PoSh-Backup\Config\Themes
        
        # 1. Load Base.css
        $baseCssFilePath = Join-Path -Path $configThemesDir -ChildPath "Base.css"
        if (Test-Path -LiteralPath $baseCssFilePath -PathType Leaf) {
            try { $baseCssContent = Get-Content -LiteralPath $baseCssFilePath -Raw -ErrorAction Stop }
            catch { Write-LogMessage "[WARNING] Could not load Base.css from '$baseCssFilePath': $($_.Exception.Message)" -Level WARNING -ForegroundColour $Global:ColourWarning }
        } else { Write-LogMessage "[WARNING] Base.css not found at '$baseCssFilePath'. Report styling will heavily rely on theme or be minimal." -Level WARNING -ForegroundColour $Global:ColourWarning }

        # 2. Load Selected Theme CSS (e.g., Light.css, Dark.css)
        if (-not [string]::IsNullOrWhiteSpace($reportThemeName)) {
            $reportThemeNameString = [string]$reportThemeName 
            $safeThemeFileNameForFile = ($reportThemeNameString -replace '[^a-zA-Z0-9]', '') + ".css" 
            
            $themeCssFilePath = Join-Path -Path $configThemesDir -ChildPath $safeThemeFileNameForFile
            if (Test-Path -LiteralPath $themeCssFilePath -PathType Leaf) {
                try { $themeCssContent = Get-Content -LiteralPath $themeCssFilePath -Raw -ErrorAction Stop }
                catch { Write-LogMessage "[WARNING] Could not load theme CSS '$safeThemeFileNameForFile' from '$themeCssFilePath': $($_.Exception.Message)" -Level WARNING -ForegroundColour $Global:ColourWarning }
            } else { 
                Write-LogMessage "[WARNING] Theme CSS file '$safeThemeFileNameForFile' for theme '$reportThemeName' not found at '$themeCssFilePath'. Report will use Base.css defaults unless overridden by config variables or custom CSS." -Level WARNING -ForegroundColour $Global:ColourWarning
            }
        }
        
        # 3. Prepare CSS Variable Overrides from Configuration
        if ($cssVariableOverrides.Count -gt 0) {
            $overrideCssVariablesStyleBlock = "<style>:root {" 
            $cssVariableOverrides.GetEnumerator() | ForEach-Object {
                $varName = ($_.Name -replace '[^a-zA-Z0-9_-]', '') 
                $varValue = $_.Value # Assume value is safe as it comes from PSD1; could add ConvertTo-SafeHtml if concerned about injection here
                if (-not $varName.StartsWith("--")) { $varName = "--" + $varName } 
                $overrideCssVariablesStyleBlock += "$varName : $varValue ;"
            }
            $overrideCssVariablesStyleBlock += "}</style>"
            Write-LogMessage "  - Applied $($cssVariableOverrides.Count) CSS variable overrides from configuration." -Level DEBUG
        }
        
        # 4. Load User's Custom CSS File
        if (-not [string]::IsNullOrWhiteSpace($reportCustomCssPathUser) -and (Test-Path -LiteralPath $reportCustomCssPathUser -PathType Leaf)) {
            try {
                $customUserCssContentFromFile = Get-Content -LiteralPath $reportCustomCssPathUser -Raw -ErrorAction Stop
                Write-LogMessage "  - Loaded user custom CSS from '$reportCustomCssPathUser'." -Level "DEBUG"
            } catch { Write-LogMessage "[WARNING] Could not load user custom CSS from '$reportCustomCssPathUser'. Error: $($_.Exception.Message)" -Level WARNING -ForegroundColour $Global:ColourWarning }
        }
        # Combine all CSS content in order
        $finalCssToInject = "<style>" + $baseCssContent + $themeCssContent + "</style>" + $overrideCssVariablesStyleBlock + "<style>" + $customUserCssContentFromFile + "</style>"
    }
    
    $htmlHead = $htmlMetaTags + $finalCssToInject

    # --- Logo Processing ---
    $embeddedLogoHtml = ""
    if (-not [string]::IsNullOrWhiteSpace($reportLogoPath) -and (Test-Path -LiteralPath $reportLogoPath -PathType Leaf)) {
        try {
            $logoBytes = [System.IO.File]::ReadAllBytes($reportLogoPath); $logoBase64 = [System.Convert]::ToBase64String($logoBytes)
            $logoMimeType = switch ([System.IO.Path]::GetExtension($reportLogoPath).ToLowerInvariant()) {
                ".png" { "image/png" } ".jpg" { "image/jpeg" } ".jpeg" { "image/jpeg" } ".gif" { "image/gif" } ".svg" { "image/svg+xml"} default { "image/png" } 
            }
            $embeddedLogoHtml = "<img src='data:$($logoMimeType);base64,$($logoBase64)' alt='Logo' class='report-logo'>"
        } catch { Write-LogMessage "[WARNING] Could not embed logo from '$reportLogoPath': $($_.Exception.Message)" -Level WARNING -ForegroundColour $Global:ColourWarning}
    }
    
    # --- HTML Body Construction ---
    $safeJobName = ConvertTo-SafeHtml $ReportData.JobName 
    $htmlBody = "<div class='container'>"

    # Add blinking cursor span if theme is RetroTerminal
    $headerTitle = "$($reportTitlePrefix) - $safeJobName"
    if ($reportThemeName.ToLowerInvariant() -eq "retroterminal") {
        $headerTitle += "<span class='blinking-cursor'></span>"
    }
    $htmlBody += "<div class='report-header'><h1>$headerTitle</h1>$($embeddedLogoHtml)</div>"

    # Summary Section
    if ($reportShowSummary -and ($ReportData.Keys -contains 'OverallStatus') ) { 
        $htmlBody += "<div class='details-section summary-section'><h2>Summary</h2><table>"
        $ReportData.GetEnumerator() | Where-Object {$_.Name -notin @('LogEntries', 'JobConfiguration', 'HookScripts')} | ForEach-Object {
            $keyName = ConvertTo-SafeHtml $_.Name
            $value = $_.Value
            $displayValue = if ($value -is [array]) { ($value | ForEach-Object { ConvertTo-SafeHtml ([string]$_) }) -join '<br>' } else { ConvertTo-SafeHtml ([string]$value) } 
            $statusClass = ""
            if ($_.Name -in @("OverallStatus", "ArchiveTestResult", "VSSStatus")) { 
                 $sanitizedStatusValue = ([string]$_.Value -replace ' ','_') -replace '\(','_' -replace '\)','_' -replace ':','' -replace '/','_'
                 $statusClass = "status-$(ConvertTo-SafeHtml $sanitizedStatusValue)"
            }
            $htmlBody += "<tr><td data-label='Item'>$($keyName)</td><td data-label='Detail' class='$($statusClass)'>$($displayValue)</td></tr>"
        }
        $htmlBody += "</table></div>"
    }

    # Configuration Section
    if ($reportShowConfiguration -and ($ReportData.Keys -contains 'JobConfiguration') -and ($null -ne $ReportData.JobConfiguration)) {
        $htmlBody += "<div class='details-section config-section'><h2>Configuration Used for Job '$safeJobName'</h2><table>"
        # Add table headers for configuration section
        $htmlBody += "<thead><tr><th>Setting</th><th>Value</th></tr></thead><tbody>"
        foreach ($key in $ReportData.JobConfiguration.Keys | Sort-Object) { 
            $value = $ReportData.JobConfiguration[$key]
            $displayValue = if ($value -is [array]) { ($value | ForEach-Object { ConvertTo-SafeHtml ([string]$_) }) -join ", " } else { ConvertTo-SafeHtml ([string]$value) }
            $htmlBody += "<tr><td data-label='Setting'>$(ConvertTo-SafeHtml $key)</td><td data-label='Value'>$($displayValue)</td></tr>"
        }
        $htmlBody += "</tbody></table></div>"
    }

    # Hook Scripts Section
    if ($reportShowHooks -and ($ReportData.Keys -contains 'HookScripts') -and ($null -ne $ReportData.HookScripts) -and $ReportData.HookScripts.Count -gt 0) {
        $htmlBody += "<div class='details-section hooks-section'><h2>Hook Scripts Executed</h2><table>"
        $htmlBody += "<thead><tr><th>Type</th><th>Path</th><th>Status</th><th>Output/Error</th></tr></thead><tbody>" 
        $ReportData.HookScripts | ForEach-Object {
            $sanitizedStatusValue = ([string]$_.Status -replace ' ','_') -replace '\(','_' -replace '\)','_' -replace ':','' -replace '/','_'
            $statusClass = "status-$(ConvertTo-SafeHtml $sanitizedStatusValue)" 
            $htmlBody += "<tr><td data-label='Hook Type'>$(ConvertTo-SafeHtml $_.Name)</td><td data-label='Path'>$(ConvertTo-SafeHtml $_.Path)</td><td data-label='Status' class='$($statusClass)'>$(ConvertTo-SafeHtml $_.Status)</td><td data-label='Output/Error'><pre>$(ConvertTo-SafeHtml $_.Output)</pre></td></tr>"
        }
        $htmlBody += "</tbody></table></div>"
    }

    # Detailed Log Section
    if ($reportShowLogEntries -and ($ReportData.Keys -contains 'LogEntries') -and ($null -ne $ReportData.LogEntries) -and $ReportData.LogEntries.Count -gt 0) { 
        $htmlBody += "<div class='details-section log-section'><h2>Detailed Log</h2>"
        $ReportData.LogEntries | ForEach-Object {
            $entryClass = "log-$(ConvertTo-SafeHtml $_.Level)" 
            $htmlBody += "<div class='log-entry $entryClass'><strong>$(ConvertTo-SafeHtml $_.Timestamp) [$(ConvertTo-SafeHtml $_.Level)]</strong> <span>$(ConvertTo-SafeHtml $_.Message)</span></div>"
        }
        $htmlBody += "</div>"
    } elseif ($reportShowLogEntries) { 
         $htmlBody += "<div class='details-section log-section'><h2>Detailed Log</h2><p>No log entries were recorded or available for this HTML report.</p></div>"
    }
    
    # Footer
    $htmlBody += "<footer>"
    if (-not [string]::IsNullOrWhiteSpace($reportCompanyName)) { 
        $htmlBody += "$($reportCompanyName) - " 
    }
    $htmlBody += "PoSh Backup Script - Generated on $(ConvertTo-SafeHtml ([string](Get-Date)))</footer>"
    $htmlBody += "</div>" # Close .container

    # Generate the HTML file
    try {
        ConvertTo-Html -Head $htmlHead -Body $htmlBody -Title "$($reportTitlePrefix) - $safeJobName" |
        Set-Content -Path $reportFullPath -Encoding UTF8 -Force -ErrorAction Stop
        Write-LogMessage "  - HTML report generated successfully: $reportFullPath" -ForegroundColour $Global:ColourSuccess
    } catch {
        Write-LogMessage "[ERROR] Failed to generate HTML report '$reportFullPath'. Error: $($_.Exception.Message)" -Level "ERROR" -ForegroundColour $Global:ColourError
    }
}
#endregion

#region --- Exported Functions ---
Export-ModuleMember -Function Invoke-HtmlReport -Alias ConvertTo-SafeHtml
#endregion
