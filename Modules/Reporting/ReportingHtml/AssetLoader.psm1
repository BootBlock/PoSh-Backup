# Modules\Reporting\ReportingHtml\AssetLoader.psm1
<#
.SYNOPSIS
    A sub-module for ReportingHtml.psm1. Handles loading all static assets for the report.
.DESCRIPTION
    This module provides the 'Get-HtmlReportAssets' function, which is responsible for
    reading the main HTML template, the base and theme-specific CSS files, the client-side
    JavaScript, and any user-provided custom CSS. It also handles the loading and
    Base64 encoding of logo and favicon images.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    28-Jun-2025
    LastModified:   28-Jun-2025
    Purpose:        To isolate the loading of all static report assets.
    Prerequisites:  PowerShell 5.1+.
#>

function Get-HtmlReportAssets {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PSScriptRoot, # The main PoSh-Backup project root
        [Parameter(Mandatory = $true)]
        [string]$ThemeName,
        [Parameter(Mandatory = $false)]
        [string]$LogoPath,
        [Parameter(Mandatory = $false)]
        [string]$FaviconPath,
        [Parameter(Mandatory = $false)]
        [string]$CustomCssPath,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "AssetLoader: Loading all HTML report assets." -Level "DEBUG" -ErrorAction SilentlyContinue

    $assets = @{
        HtmlTemplateContent = ""
        BaseCssContent      = ""
        ThemeCssContent     = ""
        DarkThemeCssContent = ""
        CustomCssContent    = ""
        JsContent           = ""
        EmbeddedLogoHtml    = ""
        FaviconLinkTag      = ""
    }

    # Load HTML Template
    $moduleAssetsDir = Join-Path -Path $PSScriptRoot -ChildPath "Modules\Reporting\Assets"
    $htmlTemplateFilePath = Join-Path -Path $moduleAssetsDir -ChildPath "ReportingHtml.template.html"
    if (Test-Path -LiteralPath $htmlTemplateFilePath -PathType Leaf) {
        try { $assets.HtmlTemplateContent = Get-Content -LiteralPath $htmlTemplateFilePath -Raw -ErrorAction Stop }
        catch { throw "Failed to read HTML template '$htmlTemplateFilePath'. Error: $($_.Exception.Message)." }
    }
    else { throw "HTML template '$htmlTemplateFilePath' not found." }

    # Load CSS
    $themesDir = Join-Path -Path $PSScriptRoot -ChildPath "Config\Themes"
    $baseCssFile = Join-Path -Path $themesDir -ChildPath "Base.css"
    if (Test-Path -LiteralPath $baseCssFile -PathType Leaf) { try { $assets.BaseCssContent = Get-Content -LiteralPath $baseCssFile -Raw } catch { & $Logger "Error loading Base.css: $($_.Exception.Message)" "WARNING" } }
    
    $themeFile = Join-Path -Path $themesDir -ChildPath (($ThemeName -replace '[^a-zA-Z0-9]', '') + ".css")
    if (Test-Path -LiteralPath $themeFile -PathType Leaf) { try { $assets.ThemeCssContent = Get-Content -LiteralPath $themeFile -Raw } catch { & $Logger "Error loading theme CSS '$($themeFile)': $($_.Exception.Message)" "WARNING" } }

    $darkThemeFile = Join-Path -Path $themesDir -ChildPath "Dark.css"
    if (Test-Path -LiteralPath $darkThemeFile -PathType Leaf) { try { $assets.DarkThemeCssContent = Get-Content -LiteralPath $darkThemeFile -Raw } catch { & $Logger "Error loading Dark.css: $($_.Exception.Message)" "WARNING" } }

    if (-not [string]::IsNullOrWhiteSpace($CustomCssPath) -and (Test-Path -LiteralPath $CustomCssPath -PathType Leaf)) { try { $assets.CustomCssContent = Get-Content -LiteralPath $CustomCssPath -Raw } catch { & $Logger "Error loading custom CSS '$CustomCssPath': $($_.Exception.Message)" "WARNING" } }

    # Load JavaScript
    $jsFilePath = Join-Path -Path $moduleAssetsDir -ChildPath "ReportingHtml.Client.js"
    if (Test-Path -LiteralPath $jsFilePath -PathType Leaf) { try { $assets.JsContent = Get-Content -LiteralPath $jsFilePath -Raw -ErrorAction Stop } catch { & $Logger "Error reading JS file '$jsFilePath': $($_.Exception.Message)" "ERROR" } }

    # Embed Logo
    if (-not [string]::IsNullOrWhiteSpace($LogoPath) -and (Test-Path -LiteralPath $LogoPath -PathType Leaf)) {
        try {
            $logoBytes = [System.IO.File]::ReadAllBytes($LogoPath)
            $logoB64 = [System.Convert]::ToBase64String($logoBytes)
            $logoMime = switch ([System.IO.Path]::GetExtension($LogoPath).ToLowerInvariant()) { ".png"{"image/png"} ".jpg"{"image/jpeg"} ".jpeg"{"image/jpeg"} ".gif"{"image/gif"} ".svg"{"image/svg+xml"} default {""} }
            if ($logoMime) { $assets.EmbeddedLogoHtml = "<img src='data:$($logoMime);base64,$($logoB64)' alt='Report Logo' class='report-logo'>" }
        } catch { & $Logger "Error embedding logo '$LogoPath': $($_.Exception.Message)" "WARNING" }
    }

    # Embed Favicon
    if (-not [string]::IsNullOrWhiteSpace($FaviconPath) -and (Test-Path -LiteralPath $FaviconPath -PathType Leaf)) {
        try {
            $favBytes = [System.IO.File]::ReadAllBytes($FaviconPath)
            $favB64 = [System.Convert]::ToBase64String($favBytes)
            $favMime = switch ([System.IO.Path]::GetExtension($FaviconPath).ToLowerInvariant()) { ".png"{"image/png"} ".ico"{"image/x-icon"} ".svg"{"image/svg+xml"} default {""} }
            if ($favMime) { $assets.FaviconLinkTag = "<link rel=`"icon`" type=`"$favMime`" href=`"data:$favMime;base64,$favB64`">" }
        } catch { & $Logger "Error embedding favicon '$FaviconPath': $($_.Exception.Message)" "WARNING" }
    }

    return $assets
}

Export-ModuleMember -Function Get-HtmlReportAssets
