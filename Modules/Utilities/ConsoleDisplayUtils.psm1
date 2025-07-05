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
    Version:        1.2.0 # Added Start-CancellableCountdown
    DateCreated:    29-May-2025
    LastModified:   06-Jun-2025
    Purpose:        Console display enhancement utilities for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Relies on global color variables (e.g., $Global:ColourHeading)
                    being available if default colors are used.
#>

<# [
.SYNOPSIS
    Writes a stylized banner to the console with optional name and value, colors, and centering.
.DESCRIPTION
    Write-ConsoleBanner prints a banner with a border, name, and value, with options for color, width, and centering.
.PARAMETER NameText
    The main label or name to display in the banner.
.PARAMETER ValueText
    The value or secondary text to display in the banner.
.PARAMETER BannerWidth
    The width of the banner (default: 48).
.PARAMETER NameForegroundColor
    The color for the name text.
.PARAMETER ValueForegroundColor
    The color for the value text.
.PARAMETER BorderForegroundColor
    The color for the border.
.PARAMETER CenterText
    If set, centers the text in the banner.
.EXAMPLE
    Write-ConsoleBanner -NameText 'Backup' -ValueText 'Complete' -NameForegroundColor 'Green' -ValueForegroundColor 'White' -BorderForegroundColor 'Gray'
#>
function Write-ConsoleBanner {
    [CmdletBinding()]
    param(
        [string]$NameText,
        [string]$ValueText,
        [int]$BannerWidth = 48,
        [string]$NameForegroundColor,
        [string]$ValueForegroundColor,
        [string]$BorderForegroundColor,
        [switch]$CenterText,
        [switch]$PrependNewLine
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

    # Defensive fallback for colors
    $resolvedBorderFg = if ([string]::IsNullOrWhiteSpace($resolvedBorderFg)) { 'Gray' } else { $resolvedBorderFg }
    $resolvedNameFg = if ([string]::IsNullOrWhiteSpace($resolvedNameFg)) { 'White' } else { $resolvedNameFg }
    $resolvedValueFg = if ([string]::IsNullOrWhiteSpace($resolvedValueFg)) { 'Yellow' } else { $resolvedValueFg }

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
    Starts a cancellable countdown timer for user actions.
.DESCRIPTION
    Displays a countdown and allows cancellation, optionally using ShouldProcess for confirmation.
.PARAMETER DelaySeconds
    Number of seconds to delay.
.PARAMETER ActionDisplayName
    The name of the action being delayed.
.PARAMETER Logger
    Scriptblock for logging messages.
.PARAMETER PSCmdletInstance
    (Optional) The PSCmdlet instance for ShouldProcess support.
.OUTPUTS
    System.Boolean
.EXAMPLE
    Start-CancellableCountdown -DelaySeconds 5 -ActionDisplayName 'Backup' -Logger $logger
#>
function Start-CancellableCountdown {
    [CmdletBinding(SupportsShouldProcess=$true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [int]$DelaySeconds,
        [Parameter(Mandatory = $true)]
        [string]$ActionDisplayName,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance = $null
    )

    & $Logger -Message "ConsoleDisplayUtils/Start-CancellableCountdown: Logger parameter active for action '$ActionDisplayName'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    if ($DelaySeconds -le 0) {
        return $true # No delay, proceed with action
    }

    # Allow PSCmdletInstance to be $null for testability
    $shouldProcess = $true
    if ($null -ne $PSCmdletInstance) {
        $shouldProcess = $PSCmdletInstance.ShouldProcess("System (Action: $ActionDisplayName)", "Display $DelaySeconds-second Cancellable Countdown")
    }
    if (-not $shouldProcess) {
        & $LocalWriteLog -Message "ConsoleDisplayUtils: Cancellable countdown for action '$ActionDisplayName' skipped by user (ShouldProcess)." -Level "INFO"
        return $false
    }

    & $LocalWriteLog -Message "ConsoleDisplayUtils: Action '$ActionDisplayName' will occur in $DelaySeconds seconds. Press 'C' to cancel." -Level "WARNING"

    $cancelled = $false
    for ($i = $DelaySeconds; $i -gt 0; $i--) {
        Write-Host -NoNewline "`rAction '$ActionDisplayName' in $i seconds... (Press 'C' to cancel) "
        if ($Host.UI.RawUI.KeyAvailable) {
            $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            if ($key.Character -eq 'c' -or $key.Character -eq 'C') {
                $cancelled = $true
                break
            }
        }
        Start-Sleep -Seconds 1
    }
    Write-Host "`r" # Clear the countdown line

    if ($cancelled) {
        & $LocalWriteLog -Message "ConsoleDisplayUtils: Action '$ActionDisplayName' CANCELLED by user." -Level "INFO"
        return $false
    }
    return $true
}

function Write-NameValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$name,
        [Parameter(Mandatory)]
        $value,
        [int]$namePadding = 0,
        [string]$nameForegroundColor = 'White',
        [string]$valueForegroundColor = 'Gray'
    )
    $resolvedNameFg = if ([string]::IsNullOrWhiteSpace($nameForegroundColor)) { 'White' } else { $nameForegroundColor }
    $resolvedValueFg = if ([string]::IsNullOrWhiteSpace($valueForegroundColor)) { 'Gray' } else { $valueForegroundColor }
    $pad = if ($namePadding -gt 0) { $name.PadRight($namePadding) } else { $name }
    $displayValue = if ($null -eq $value -or $value -eq '') { '-' } else { $value }
    Write-Host ($pad + ": ") -ForegroundColor $resolvedNameFg -NoNewline
    Write-Host $displayValue -ForegroundColor $resolvedValueFg
}
#endregion

Export-ModuleMember -Function Write-ConsoleBanner, Write-NameValue, Start-CancellableCountdown
