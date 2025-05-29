# Modules\Utilities\ConsoleDisplayUtils.psm1
<#
.SYNOPSIS
    Provides utility functions for creating visually distinct banners and other
    enhanced console display elements for PoSh-Backup.
.DESCRIPTION
    This module centralizes functions that help in presenting information to the
    PowerShell console in a more structured and visually appealing manner, such as
    drawing text banners with borders and custom colors.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.2 # Removed unused rightPaddingText variable.
    DateCreated:    29-May-2025
    LastModified:   29-May-2025
    Purpose:        Console display enhancement utilities for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Relies on global color variables (e.g., $Global:ColourHeading)
                    being available if default colors are used.
#>

#region --- Exported Functions ---

function Write-ConsoleBanner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$NameText,

        [Parameter(Mandatory = $false)]
        [string]$NameForegroundColor = '$Global:ColourInfo', # Default to global Info (Cyan)

        [Parameter(Mandatory = $false)]
        [string]$ValueText,

        [Parameter(Mandatory = $false)]
        [string]$ValueForegroundColor = '$Global:ColourValue', # Default to global Value (DarkYellow)

        [Parameter(Mandatory = $false)]
        [int]$BannerWidth = 50,

        [Parameter(Mandatory = $false)]
        [string]$BorderForegroundColor = '$Global:ColourBorder', # Default to global Border (DarkGray)

        [Parameter(Mandatory = $false)]
        [switch]$CenterText,

        [Parameter(Mandatory = $false)]
        [switch]$PrependNewLine,

        [Parameter(Mandatory = $false)]
        [switch]$AppendNewLine
    )

    if ($PrependNewLine) { Write-Host }

    $resolvedBorderFg = $BorderForegroundColor 
    if ($resolvedBorderFg -is [string] -and $resolvedBorderFg.StartsWith('$Global:')) {
        try { $resolvedBorderFg = Invoke-Expression $resolvedBorderFg } catch { $resolvedBorderFg = "White" } 
    }

    $resolvedNameFg = $NameForegroundColor 
    if ($resolvedNameFg -is [string] -and $resolvedNameFg.StartsWith('$Global:')) {
        try { $resolvedNameFg = Invoke-Expression $resolvedNameFg } catch { $resolvedNameFg = "Cyan" } 
    }

    $resolvedValueFg = $ValueForegroundColor 
    if ($resolvedValueFg -is [string] -and $resolvedValueFg.StartsWith('$Global:')) {
        try { $resolvedValueFg = Invoke-Expression $resolvedValueFg } catch { $resolvedValueFg = "DarkYellow" } 
    }

    # Top border
    Write-Host ("╔" + ("═" * ($BannerWidth - 2)) + "╗") -ForegroundColor $resolvedBorderFg

    $innerWidth = $BannerWidth - 4 # Space for "║ text ║"
    
    $combinedTextForLength = ""
    if (-not [string]::IsNullOrWhiteSpace($NameText)) {
        $combinedTextForLength += $NameText
    }
    if (-not [string]::IsNullOrWhiteSpace($NameText) -and -not [string]::IsNullOrWhiteSpace($ValueText)) {
        $combinedTextForLength += " " # Add a space if both name and value are present
    }
    if (-not [string]::IsNullOrWhiteSpace($ValueText)) {
        $combinedTextForLength += $ValueText
    }

    $actualDisplayTextLength = $combinedTextForLength.Length # The length of the text we intend to display
    $leftPaddingText = ""

    if ($CenterText.IsPresent) {
        $paddingLength = [math]::Max(0, ($innerWidth - $actualDisplayTextLength) / 2)
        $leftPaddingText = " " * [math]::Floor($paddingLength)
    }
    
    # Start building the line
    Write-Host "║ " -ForegroundColor $resolvedBorderFg -NoNewline
    Write-Host $leftPaddingText -NoNewline 

    $currentPrintedLength = $leftPaddingText.Length 
    $namePartToDisplay = ""
    $valuePartToDisplay = ""

    if (-not [string]::IsNullOrWhiteSpace($NameText)) {
        $namePartToDisplay = $NameText
        # Check if NameText itself will overflow available space (innerWidth - currentPrintedLength)
        if (($currentPrintedLength + $namePartToDisplay.Length) -gt $innerWidth) {
            $namePartToDisplay = $namePartToDisplay.Substring(0, [math]::Max(0, $innerWidth - $currentPrintedLength - 3)) + "..."
        }
        Write-Host $namePartToDisplay -ForegroundColor $resolvedNameFg -NoNewline
        $currentPrintedLength += $namePartToDisplay.Length
    }

    if (-not [string]::IsNullOrWhiteSpace($NameText) -and -not [string]::IsNullOrWhiteSpace($ValueText)) {
        # Add space only if there's room and NameText was actually printed
        if ($currentPrintedLength -lt $innerWidth -and $namePartToDisplay.Length -gt 0) {
            Write-Host " " -NoNewline 
            $currentPrintedLength += 1
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ValueText)) {
        $valuePartToDisplay = $ValueText
        # Check if ValueText will overflow remaining available space
        if (($currentPrintedLength + $valuePartToDisplay.Length) -gt $innerWidth) {
            $valuePartToDisplay = $valuePartToDisplay.Substring(0, [math]::Max(0, $innerWidth - $currentPrintedLength - 3)) + "..."
        }
         Write-Host $valuePartToDisplay -ForegroundColor $resolvedValueFg -NoNewline
         $currentPrintedLength += $valuePartToDisplay.Length
    }

    # Fill remaining space with actual right padding needed
    $actualRightPaddingLength = $innerWidth - $currentPrintedLength
    if ($actualRightPaddingLength -gt 0) {
        Write-Host (" " * $actualRightPaddingLength) -NoNewline
    }
    
    Write-Host " ║" -ForegroundColor $resolvedBorderFg

    # Bottom border
    Write-Host ("╚" + ("═" * ($BannerWidth - 2)) + "╝") -ForegroundColor $resolvedBorderFg

    if ($AppendNewLine) { Write-Host }
}

Export-ModuleMember -Function Write-ConsoleBanner

#endregion
