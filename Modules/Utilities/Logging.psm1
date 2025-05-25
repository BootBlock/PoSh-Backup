# Modules\Utilities\Logging.psm1
<#
.SYNOPSIS
    Provides the core logging functionality for the PoSh-Backup solution.
.DESCRIPTION
    This module contains the Write-LogMessage function, responsible for standardised
    console and file logging with colour-coding and timestamping. It relies on
    global variables (e.g., $Global:StatusToColourMap, $Global:GlobalLogFile)
    set by the main PoSh-Backup script for its operation.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    25-May-2025
    LastModified:   25-May-2025
    Purpose:        Centralised logging utility for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Global variables for logging configuration must be set by the calling environment.
#>

#region --- Logging Function ---
function Write-LogMessage {
    [CmdletBinding()]
    param (
        [string]$Message,
        [string]$ForegroundColour = $Global:ColourInfo, # Default colour if not determined by Level
        [switch]$NoNewLine,
        [string]$Level = "INFO", # Default log level
        [switch]$NoTimestampToLogFile = $false
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $consoleMessage = $Message
    $logMessage = if ($NoTimestampToLogFile) { $Message } else { "$timestamp [$Level] $Message" }

    $effectiveConsoleColour = $ForegroundColour

    # Attempt to map Level to a specific colour
    if ($Global:StatusToColourMap.ContainsKey($Level.ToUpperInvariant())) {
        $effectiveConsoleColour = $Global:StatusToColourMap[$Level.ToUpperInvariant()]
    } 
    elseif ($Level.ToUpperInvariant() -eq 'NONE') {
        # For 'NONE' level, use the host's current foreground colour (no change)
        $effectiveConsoleColour = $Host.UI.RawUI.ForegroundColor
    }

    # Safety check: If $effectiveConsoleColour somehow became an empty string or null (and is not 'NONE' level), default it.
    if (($effectiveConsoleColour -is [string] -and [string]::IsNullOrWhiteSpace($effectiveConsoleColour)) -or `
        ($null -eq $effectiveConsoleColour -and $Level.ToUpperInvariant() -ne 'NONE')) {
        
        # This block is for diagnostics if colour resolution fails unexpectedly.
        # In a production script, one might simplify this or ensure StatusToColourMap always has a fallback.
        Write-Warning "Write-LogMessage (SAFETY CHECK TRIGGERED): Colour resolution issue."
        Write-Warning "  -> Original Level: '$Level', ForegroundColour Param: '$ForegroundColour'"
        Write-Warning "  -> effectiveConsoleColour before safety default: '$effectiveConsoleColour'"
        Write-Warning "  -> Message: '$Message'. Defaulting to Host's current colour."
        $effectiveConsoleColour = $Host.UI.RawUI.ForegroundColor
    }

    # Output to console
    if ($NoNewLine) {
        Write-Host $consoleMessage -ForegroundColor $effectiveConsoleColour -NoNewline
    }
    else {
        Write-Host $consoleMessage -ForegroundColor $effectiveConsoleColour
    }

    # Add to in-memory log entries for reporting
    if ($Global:GlobalJobLogEntries -is [System.Collections.Generic.List[object]]) {
        $Global:GlobalJobLogEntries.Add([PSCustomObject]@{
                Timestamp = if ($NoTimestampToLogFile -and $Global:GlobalJobLogEntries.Count -gt 0) { "" } else { $timestamp } 
                Level     = $Level
                Message   = $Message
            })
    }

    # Write to global log file if enabled
    if ($Global:GlobalEnableFileLogging -and $Global:GlobalLogFile -and $Level -ne "NONE") {
        try {
            Add-Content -Path $Global:GlobalLogFile -Value $logMessage -ErrorAction Stop
        }
        catch {
            # Critical failure to log to file, output to console with high visibility
            Write-Host "CRITICAL: Failed to write to log file '$($Global:GlobalLogFile)'. Error: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}
#endregion

Export-ModuleMember -Function Write-LogMessage
