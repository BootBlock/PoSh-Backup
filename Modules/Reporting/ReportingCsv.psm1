# PowerShell Module: ReportingCsv.psm1
# Description: Generates CSV reports for PoSh-Backup.
# Version: 1.0

function Invoke-CsvReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ReportDirectory,
        [Parameter(Mandatory=$true)]
        [string]$JobName,
        [Parameter(Mandatory=$true)]
        [hashtable]$ReportData,
        [Parameter(Mandatory=$true)]
        [hashtable]$GlobalConfig, # Not directly used in this simple CSV version, but passed for consistency
        [Parameter(Mandatory=$true)] 
        [hashtable]$JobConfig,    # Not directly used in this simple CSV version
        [Parameter(Mandatory=$false)]
        [scriptblock]$Logger = $null
    )
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour = $Global:ColourInfo)
        if ($null -ne $Logger) { & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour } 
        else { Write-Host "[$Level] (ReportingCsvDirect) $Message" }
    }

    & $LocalWriteLog -Message "[INFO] CSV Report generation started for job '$JobName'." -Level "INFO"
    
    $reportTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeJobNameForFile = $JobName -replace '[^a-zA-Z0-9_-]', '_' 
    
    # --- Summary CSV ---
    $summaryReportFileName = "$($safeJobNameForFile)_Summary_$($reportTimestamp).csv"
    $summaryReportFullPath = Join-Path -Path $ReportDirectory -ChildPath $summaryReportFileName
    
    try {
        $summaryObject = [PSCustomObject]@{}
        $ReportData.GetEnumerator() | Where-Object {$_.Name -notin @('LogEntries', 'JobConfiguration', 'HookScripts', 'IsSimulationReport')} | ForEach-Object {
            # For array values in summary (like SourcePath), join them into a single string for CSV
            $value = if ($_.Value -is [array]) { $_.Value -join '; ' } else { $_.Value }
            Add-Member -InputObject $summaryObject -MemberType NoteProperty -Name $_.Name -Value $value
        }
        
        $summaryObject | Export-Csv -Path $summaryReportFullPath -NoTypeInformation -Encoding UTF8 -Force
        & $LocalWriteLog -Message "  - Summary CSV report generated: $summaryReportFullPath" -ForegroundColour $Global:ColourSuccess
    } catch {
         & $LocalWriteLog -Message "[ERROR] Failed to generate Summary CSV report '$summaryReportFullPath'. Error: $($_.Exception.Message)" -Level "ERROR" -ForegroundColour $Global:ColourError
    }

    # --- Log Entries CSV (if exist) ---
    if ($ReportData.ContainsKey('LogEntries') -and $null -ne $ReportData.LogEntries -and $ReportData.LogEntries.Count -gt 0) {
        $logReportFileName = "$($safeJobNameForFile)_Logs_$($reportTimestamp).csv"
        $logReportFullPath = Join-Path -Path $ReportDirectory -ChildPath $logReportFileName
        try {
            $ReportData.LogEntries | Export-Csv -Path $logReportFullPath -NoTypeInformation -Encoding UTF8 -Force
            & $LocalWriteLog -Message "  - Log Entries CSV report generated: $logReportFullPath" -ForegroundColour $Global:ColourSuccess
        } catch {
            & $LocalWriteLog -Message "[ERROR] Failed to generate Log Entries CSV report '$logReportFullPath'. Error: $($_.Exception.Message)" -Level "ERROR" -ForegroundColour $Global:ColourError
        }
    }

    # --- Hook Scripts CSV (if exist) ---
    if ($ReportData.ContainsKey('HookScripts') -and $null -ne $ReportData.HookScripts -and $ReportData.HookScripts.Count -gt 0) {
        $hookReportFileName = "$($safeJobNameForFile)_Hooks_$($reportTimestamp).csv"
        $hookReportFullPath = Join-Path -Path $ReportDirectory -ChildPath $hookReportFileName
        try {
            $ReportData.HookScripts | Export-Csv -Path $hookReportFullPath -NoTypeInformation -Encoding UTF8 -Force
            & $LocalWriteLog -Message "  - Hook Scripts CSV report generated: $hookReportFullPath" -ForegroundColour $Global:ColourSuccess
        } catch {
            & $LocalWriteLog -Message "[ERROR] Failed to generate Hook Scripts CSV report '$hookReportFullPath'. Error: $($_.Exception.Message)" -Level "ERROR" -ForegroundColour $Global:ColourError
        }
    }
}

Export-ModuleMember -Function Invoke-CsvReport
