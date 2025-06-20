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
    Version:        1.1.4 # Write-ConsoleBanner now respects $Global:IsQuietMode.
    DateCreated:    29-May-2025
    LastModified:   06-Jun-2025
    Purpose:        Console display enhancement utilities for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Relies on global color variables (e.g., $Global:ColourHeading)
                    being available if default colors are used.
#>

function Write-ConsoleBanner {
    [CmdletBinding()]
    param(
        [string]$NameText,
        [string]$NameForegroundColor = '$Global:ColourInfo', # Default to global Info (Cyan)
        [string]$ValueText,
        [string]$ValueForegroundColor = '$Global:ColourValue', # Default to global Value (DarkYellow)
        [int]$BannerWidth = 50,
        [string]$BorderForegroundColor = '$Global:ColourBorder', # Default to global Border (DarkGray)
        [switch]$CenterText,
        [switch]$PrependNewLine,
        [switch]$AppendNewLine
    )

    # If in quiet mode, suppress the banner entirely.
    if ($Global:IsQuietMode -eq $true) {
        return
    }

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

<#
.SYNOPSIS
    Writes a formatted name-value pair to the console.
.DESCRIPTION
    A helper function for console output that displays a name and its corresponding value in a
    consistent 'Name: Value' format with customisable colours. It supports optional padding
    for the name part to allow for aligned, table-like output and provides a default for
    empty values.
.PARAMETER name
    The name (or label) for the key-value pair to be displayed.
.PARAMETER value
    The value to be displayed for the corresponding name.
.PARAMETER namePadding
    An optional integer that specifies the total character width to which the 'name' string
    should be right-padded with spaces. This is useful for aligning columns of name-value pairs.
.PARAMETER defaultValue
    An optional string to display if the provided 'value' is null or empty. Defaults to '-'.
.EXAMPLE
    Write-NameValue -name "Status" -value "Success"
    # Output:   Status: Success

    Write-NameValue -name "Longer Name" -value "Some Value" -namePadding 20
    # Output:   Longer Name         : Some Value
    
    Write-NameValue -name "Empty Value" -value $null -namePadding 20
    # Output:   Empty Value         : -
#>
function Write-NameValue {
    param(
        [Parameter(Mandatory)][string]$name,
        [Parameter(Mandatory=$false)][string]$value,
        [Int16]$namePadding = 0,
        [string]$defaultValue = '-',
        [string]$nameForegroundColor = "DarkGray",
        [string]$valueForegroundColor = "Gray"
    )

    $nameText = $name
    $valueToDisplay = if ([string]::IsNullOrWhiteSpace($value)) { $defaultValue } else { $value }

    if ($namePadding -gt 0) {
        $nameText = $name.PadRight($namePadding, " ")
    }

    Write-Host "  $($nameText): " -NoNewline -ForegroundColor $nameForegroundColor
    Write-Host $valueToDisplay -ForegroundColor $valueForegroundColor
}

Export-ModuleMember -Function Write-ConsoleBanner, Write-NameValue
