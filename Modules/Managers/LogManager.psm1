# Modules\Managers\LogManager.psm1
<#
.SYNOPSIS
    Provides utility functions for managing PoSh-Backup log files and console/file logging.
    This includes applying retention policies to log files and handling the core
    Write-LogMessage functionality.
.DESCRIPTION
    This module contains:
    - Invoke-LogFileRetention: Responsible for finding and deleting old log files based
      on a specified retention count and job name pattern. This helps prevent the log
      directory from growing indefinitely.
    - Write-LogMessage: Responsible for standardised console and file logging with
      colour-coding and timestamping. It relies on global variables (e.g.,
      $Global:StatusToColourMap, $Global:GlobalLogFile) set by the main PoSh-Backup
      script for its operation.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Added Write-LogMessage function.
    DateCreated:    27-May-2025
    LastModified:   27-May-2025
    Purpose:        Log file retention management and core message logging utility for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Requires a logger function and PSCmdlet instance to be passed to Invoke-LogFileRetention.
                    Write-LogMessage relies on global variables for configuration.
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

#region --- Log File Retention Function ---
function Invoke-LogFileRetention {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    <#
    .SYNOPSIS
        Applies retention policy to log files for a specific job pattern.
    .DESCRIPTION
        This function finds log files in the specified directory that match a job name pattern
        (e.g., "MyJob_*.log"). It sorts these files by creation time and deletes the oldest
        ones, ensuring that no more than the specified RetentionCount remain.
        A RetentionCount of 0 means infinite retention (no logs are deleted).
    .PARAMETER LogDirectory
        The directory where the log files are stored.
    .PARAMETER JobNamePattern
        The base name of the job, used to construct the file pattern (e.g., "MyJob" becomes "MyJob_*.log").
    .PARAMETER RetentionCount
        The number of log files to keep for this job pattern. If 0, all logs are kept.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function.
    .PARAMETER IsSimulateMode
        A switch. If $true, deletion operations are simulated and logged, but no files are actually deleted.
    .PARAMETER PSCmdletInstance
        A mandatory reference to the calling cmdlet's $PSCmdlet automatic variable for ShouldProcess support.
    .EXAMPLE
        # Invoke-LogFileRetention -LogDirectory "C:\PoShBackup\Logs" -JobNamePattern "ServerBackup" `
        #   -RetentionCount 10 -Logger ${function:Write-LogMessage} -PSCmdletInstance $PSCmdlet
    .OUTPUTS
        None. This function performs file operations and logs its actions.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogDirectory,
        [Parameter(Mandatory = $true)]
        [string]$JobNamePattern,
        [Parameter(Mandatory = $true)]
        [int]$RetentionCount,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    # Defensive PSSA appeasement line by directly calling the logger for this initial message
    & $Logger -Message "LogManager/Invoke-LogFileRetention: Logger parameter active for JobPattern '$JobNamePattern', RetentionCount '$RetentionCount'." -Level "DEBUG" -ErrorAction SilentlyContinue

    # Internal helper to use the passed-in logger consistently for other messages
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    if ($RetentionCount -eq 0) {
        & $LocalWriteLog -Message "[INFO] LogManager: LogRetentionCount is 0 for job pattern '$JobNamePattern'. All log files will be kept." -Level "INFO"
        return
    }
    if ($RetentionCount -lt 0) { # Should be caught by ValidateRange in PoSh-Backup.ps1, but defensive check.
        & $LocalWriteLog -Message "[WARNING] LogManager: LogRetentionCount is negative ($RetentionCount) for job pattern '$JobNamePattern'. Interpreting as 0 (infinite retention)." -Level "WARNING"
        return
    }

    & $LocalWriteLog -Message "`n[INFO] LogManager: Applying Log Retention Policy for job pattern '$JobNamePattern'..." -Level "INFO"
    & $LocalWriteLog -Message "   - Log Directory: $LogDirectory"
    & $LocalWriteLog -Message "   - Number of log files to keep: $RetentionCount"

    if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
        & $LocalWriteLog -Message "   - LogManager: Log directory '$LogDirectory' not found. Skipping log retention." -Level "WARNING"
        return
    }

    $safeJobNamePatternForFile = $JobNamePattern -replace '[^a-zA-Z0-9_-]', '_'
    $fileFilter = "$($safeJobNamePatternForFile)_*.log"

    try {
        $existingLogFiles = Get-ChildItem -Path $LogDirectory -Filter $fileFilter -File -ErrorAction SilentlyContinue |
                            Sort-Object CreationTime -Descending # Sort newest first

        if ($null -eq $existingLogFiles -or $existingLogFiles.Count -eq 0) {
            & $LocalWriteLog -Message "   - LogManager: No log files found matching pattern '$fileFilter' in '$LogDirectory'. No retention actions needed." -Level "INFO"
            return
        }

        if ($existingLogFiles.Count -le $RetentionCount) {
            & $LocalWriteLog -Message "   - LogManager: Number of existing log files ($($existingLogFiles.Count)) is at or below retention count ($RetentionCount). No logs to delete." -Level "INFO"
            return
        }

        $logFilesToDelete = $existingLogFiles | Select-Object -Skip $RetentionCount
        & $LocalWriteLog -Message "[INFO] LogManager: Found $($existingLogFiles.Count) log files. Will attempt to delete $($logFilesToDelete.Count) older log(s) to meet retention count ($RetentionCount)." -Level "INFO"

        foreach ($logFile in $logFilesToDelete) {
            $deleteActionMessage = "Permanently Delete Log File"

            if ($IsSimulateMode.IsPresent) {
                & $LocalWriteLog -Message "       - SIMULATE: Would $deleteActionMessage '$($logFile.FullName)' (Created: $($logFile.CreationTime))" -Level "SIMULATE"
                continue
            }

            if (-not $PSCmdletInstance.ShouldProcess($logFile.FullName, $deleteActionMessage)) {
                & $LocalWriteLog -Message "       - LogManager: Deletion of log file '$($logFile.FullName)' skipped by user (ShouldProcess)." -Level "WARNING"
                continue
            }

            & $LocalWriteLog -Message "       - LogManager: Deleting log file: '$($logFile.FullName)' (Created: $($logFile.CreationTime))" -Level "WARNING"
            try {
                Remove-Item -LiteralPath $logFile.FullName -Force -ErrorAction Stop
                & $LocalWriteLog -Message "         - Status: DELETED PERMANENTLY" -Level "SUCCESS"
            } catch {
                & $LocalWriteLog -Message "         - Status: FAILED to delete log file! Error: $($_.Exception.Message)" -Level "ERROR"
            }
        }
    } catch {
        & $LocalWriteLog -Message "[WARNING] LogManager: Error during log retention policy for job pattern '$JobNamePattern'. Some old logs might not have been deleted. Error: $($_.Exception.Message)" -Level "WARNING"
    }
    & $LocalWriteLog -Message "[INFO] LogManager: Log retention policy application finished for job pattern '$JobNamePattern'." -Level "INFO"
}
#endregion

Export-ModuleMember -Function Write-LogMessage, Invoke-LogFileRetention
