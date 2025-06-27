# Modules\Managers\LogManager\RetentionHandler.psm1
<#
.SYNOPSIS
    A sub-module for LogManager.psm1. Handles the retention policy for log files.
.DESCRIPTION
    This module provides the 'Invoke-PoShBackupLogRetention' function. It is responsible
    for finding and deleting or compressing old log files based on a specified retention
    count and job name pattern. This helps prevent the log directory from growing indefinitely.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    27-Jun-2025
    LastModified:   27-Jun-2025
    Purpose:        To isolate the log file retention logic.
    Prerequisites:  PowerShell 5.1+.
#>

function Invoke-PoShBackupLogRetention {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogDirectory,
        [Parameter(Mandatory = $true)]
        [string]$JobNamePattern,
        [Parameter(Mandatory = $true)]
        [int]$RetentionCount,
        [Parameter(Mandatory = $true)]
        [bool]$CompressOldLogs,
        [Parameter(Mandatory = $true)]
        [string]$OldLogCompressionFormat,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    & $Logger -Message "LogManager/RetentionHandler: Logger parameter active for JobPattern '$JobNamePattern'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    if ($IsSimulateMode.IsPresent) {
        $safeJobNamePatternForFile = $JobNamePattern -replace '[^a-zA-Z0-9_-]', '_'
        $fileFilter = "$($safeJobNamePatternForFile)_*.log"
        $existingLogFileCount = 0
        if (Test-Path -LiteralPath $LogDirectory -PathType Container) {
            $existingLogFileCount = (Get-ChildItem -Path $LogDirectory -Filter $fileFilter -File -ErrorAction SilentlyContinue).Count
        }
        $logsToProcessCount = [math]::Max(0, $existingLogFileCount - $RetentionCount)
        
        if ($logsToProcessCount -gt 0) {
            $actionWord = if ($CompressOldLogs) { "compress" } else { "permanently delete" }
            & $LocalWriteLog -Message "SIMULATE: Would $actionWord $logsToProcessCount old log file(s) for job '$JobNamePattern' to meet retention count of $RetentionCount." -Level "SIMULATE"
        }
        return
    }

    if ($RetentionCount -eq 0) {
        & $LocalWriteLog -Message "[INFO] LogRetentionHandler: LogRetentionCount is 0 for job pattern '$JobNamePattern'. All log files will be kept." -Level "INFO"
        return
    }
    if ($RetentionCount -lt 0) {
        & $LocalWriteLog -Message "[WARNING] LogRetentionHandler: LogRetentionCount is negative ($RetentionCount). Interpreting as 0 (infinite retention)." -Level "WARNING"
        return
    }

    & $LocalWriteLog -Message "`n[INFO] LogRetentionHandler: Applying Log Retention Policy for job pattern '$JobNamePattern'..." -Level "INFO"

    if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
        & $LocalWriteLog -Message "   - LogRetentionHandler: Log directory '$LogDirectory' not found. Skipping log retention." -Level "WARNING"
        return
    }

    $safeJobNamePatternForFile = $JobNamePattern -replace '[^a-zA-Z0-9_-]', '_'
    $fileFilter = "$($safeJobNamePatternForFile)_*.log"

    try {
        $existingLogFiles = Get-ChildItem -Path $LogDirectory -Filter $fileFilter -File -ErrorAction SilentlyContinue | Sort-Object CreationTime -Descending
        if ($null -eq $existingLogFiles -or $existingLogFiles.Count -le $RetentionCount) { return }

        $logFilesToDelete = $existingLogFiles | Select-Object -Skip $RetentionCount
        & $LocalWriteLog -Message "[INFO] LogRetentionHandler: Found $($existingLogFiles.Count) log files. Will process $($logFilesToDelete.Count) older log(s)." -Level "INFO"

        if ($CompressOldLogs) {
            $archiveFileName = "PoSh-Backup_ArchivedLogs_$($safeJobNamePatternForFile).$($OldLogCompressionFormat.ToLower())"
            $archiveFullPath = Join-Path -Path $LogDirectory -ChildPath $archiveFileName
            if (-not $PSCmdletInstance.ShouldProcess($archiveFullPath, "Compress and Remove Old Logs")) {
                & $LocalWriteLog -Message "       - Log compression for job pattern '$JobNamePattern' skipped by user." -Level "WARNING"
                return
            }
            try {
                Compress-Archive -Path $logFilesToDelete.FullName -DestinationPath $archiveFullPath -Update -ErrorAction Stop
                Remove-Item -Path $logFilesToDelete.FullName -Force -ErrorAction Stop
            } catch { & $LocalWriteLog -Message "[ERROR] LogRetentionHandler: Failed to compress or remove original log files. Error: $($_.Exception.Message)" -Level "ERROR" }
        } else {
            foreach ($logFile in $logFilesToDelete) {
                if (-not $PSCmdletInstance.ShouldProcess($logFile.FullName, "Permanently Delete Log File")) { continue }
                & $LocalWriteLog -Message "       - Deleting log file: '$($logFile.FullName)' (Created: $($logFile.CreationTime))" -Level "WARNING"
                try { Remove-Item -LiteralPath $logFile.FullName -Force -ErrorAction Stop; & $LocalWriteLog "         - Status: DELETED PERMANENTLY" "SUCCESS" }
                catch { & $LocalWriteLog "         - Status: FAILED to delete log file! Error: $($_.Exception.Message)" "ERROR" }
            }
        }
    } catch { & $LocalWriteLog -Message "[WARNING] LogRetentionHandler: Error during log retention policy. Error: $($_.Exception.Message)" -Level "WARNING" }
}

Export-ModuleMember -Function Invoke-PoShBackupLogRetention
