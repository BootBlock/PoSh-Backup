# Modules\Managers\LogManager\Logger.psm1
<#
.SYNOPSIS
    A sub-module for LogManager.psm1. Provides the core real-time logging engine.
.DESCRIPTION
    This module contains the 'Write-LogMessage' function, which is responsible for
    standardised console and file logging with colour-coding and timestamping. It
    relies on global variables (e.g., $Global:StatusToColourMap, $Global:GlobalLogFile)
    set by the main PoSh-Backup script for its operation. It also respects a global
    $Global:IsQuietMode flag to suppress non-error console output.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    27-Jun-2025
    LastModified:   27-Jun-2025
    Purpose:        Core message logging utility for the LogManager facade.
    Prerequisites:  PowerShell 5.1+.
#>

function Write-LogMessage {
    [CmdletBinding()]
    param (
        [string]$Message,
        [string]$ForegroundColour, # Default value removed to allow checking if it was explicitly passed
        [switch]$NoNewLine,
        [string]$Level = "INFO", # Default log level
        [switch]$NoTimestampToLogFile = $false
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $consoleMessage = $Message
    $logMessage = if ($NoTimestampToLogFile) { $Message } else { "$timestamp [$Level] $Message" }

    # --- MORE ROBUST COLOUR LOGIC ---
    $effectiveConsoleColour = $null

    # Priority 1: An explicitly passed colour.
    if ($PSBoundParameters.ContainsKey('ForegroundColour')) {
        $effectiveConsoleColour = $ForegroundColour
    }
    # Priority 2: A colour mapped to the Level.
    elseif ($Global:StatusToColourMap.ContainsKey($Level.ToUpperInvariant())) {
        $effectiveConsoleColour = $Global:StatusToColourMap[$Level.ToUpperInvariant()]
    }

    # Priority 3: Fallback to the host's current colour if no other colour was determined.
    if ($null -eq $effectiveConsoleColour) {
        try {
            $effectiveConsoleColour = $Host.UI.RawUI.ForegroundColor
        }
        catch {
            # Fallback for non-interactive environments where RawUI might not exist
            $effectiveConsoleColour = "Gray"
        }
    }
    # --- END LOGIC ---

    # Safety check: If $effectiveConsoleColour somehow became an empty string, default it.
    if (($effectiveConsoleColour -is [string] -and [string]::IsNullOrWhiteSpace($effectiveConsoleColour))) {
        $effectiveConsoleColour = "Gray"
    }

    # Output to console only if not in quiet mode, or if the message is critical (ERROR level).
    if (($Global:IsQuietMode -ne $true) -or ($Level.ToUpperInvariant() -eq 'ERROR')) {
        if ($NoNewLine) {
            Write-Host $consoleMessage -ForegroundColor $effectiveConsoleColour -NoNewline
        }
        else {
            Write-Host $consoleMessage -ForegroundColor $effectiveConsoleColour
        }
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
            # Critical failure to log to file, output to console with high visibility, bypassing quiet mode.
            Write-Host "CRITICAL: Failed to write to log file '$($Global:GlobalLogFile)'. Error: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

Export-ModuleMember -Function Write-LogMessage
