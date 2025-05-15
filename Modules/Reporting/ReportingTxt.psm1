<#
.SYNOPSIS
    Generates plain text (.txt) summary reports for PoSh-Backup jobs, providing a simple,
    human-readable overview of the backup operation, including summary details,
    configuration used, hook script actions, and log entries.
.DESCRIPTION
    This module produces a straightforward plain text report, formatted for easy reading
    in any text editor or for inclusion in email bodies. It includes key summary information,
    a snapshot of the job configuration, details of any executed hook scripts, and the
    full sequence of log messages.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.4 (Removed PSSA attribute suppression; trailing whitespace removed)
    DateCreated:    14-May-2025
    LastModified:   15-May-2025
    Purpose:        Plain text report generation for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+. Called by Reporting.psm1 (orchestrator).
#>

function Invoke-TxtReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ReportDirectory,
        [Parameter(Mandatory=$true)]
        [string]$JobName,
        [Parameter(Mandatory=$true)]
        [hashtable]$ReportData,
        [Parameter(Mandatory=$true)]
        # PSUseDeclaredVarsMoreThanAssignments for Logger is now excluded globally via PSScriptAnalyzerSettings.psd1
        [scriptblock]$Logger
    )
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if ($null -ne $ForegroundColour) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    & $LocalWriteLog -Message "[INFO] TXT Report generation started for job '$JobName'." -Level "INFO"

    $reportTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeJobNameForFile = $JobName -replace '[^a-zA-Z0-9_-]', '_'
    $reportFileName = "$($safeJobNameForFile)_Report_$($reportTimestamp).txt"
    $reportFullPath = Join-Path -Path $ReportDirectory -ChildPath $reportFileName

    $reportContent = [System.Text.StringBuilder]::new()
    $null = $reportContent.AppendLine("PoSh Backup Report - Job: $JobName")
    $null = $reportContent.AppendLine("Generated: $(Get-Date)")
    $null = $reportContent.AppendLine(("-" * 70))

    # Summary Section
    $null = $reportContent.AppendLine("SUMMARY:")
    $ReportData.GetEnumerator() | Where-Object {$_.Name -notin @('LogEntries', 'JobConfiguration', 'HookScripts', 'IsSimulationReport')} | ForEach-Object {
        $value = if ($_.Value -is [array]) { $_.Value -join '; ' } else { $_.Value }
        $null = $reportContent.AppendLine("  $($_.Name.PadRight(30)): $value")
    }
    $null = $reportContent.AppendLine(("-" * 70))

    # Configuration Section
    if ($ReportData.ContainsKey('JobConfiguration') -and $null -ne $ReportData.JobConfiguration) {
        $null = $reportContent.AppendLine("CONFIGURATION USED:")
        $ReportData.JobConfiguration.GetEnumerator() | Sort-Object Name | ForEach-Object {
            $value = if ($_.Value -is [array]) { $_.Value -join '; ' } else { $_.Value }
            $null = $reportContent.AppendLine("  $($_.Name.PadRight(30)): $value")
        }
        $null = $reportContent.AppendLine(("-" * 70))
    }

    # Hook Scripts Section
    if ($ReportData.ContainsKey('HookScripts') -and $null -ne $ReportData.HookScripts -and $ReportData.HookScripts.Count -gt 0) {
        $null = $reportContent.AppendLine("HOOK SCRIPTS EXECUTED:")
        $ReportData.HookScripts | ForEach-Object {
            $null = $reportContent.AppendLine("  Hook Type : $($_.Name)")
            $null = $reportContent.AppendLine("  Path      : $($_.Path)")
            $null = $reportContent.AppendLine("  Status    : $($_.Status)")
            if (-not [string]::IsNullOrWhiteSpace($_.Output)) {
                $null = $reportContent.AppendLine("  Output    : $($_.Output -replace "`r`n","`n"+" "*12)")
            }
            $null = $reportContent.AppendLine()
        }
        $null = $reportContent.AppendLine(("-" * 70))
    }

    # Detailed Log Section
    if ($ReportData.ContainsKey('LogEntries') -and $null -ne $ReportData.LogEntries -and $ReportData.LogEntries.Count -gt 0) {
        $null = $reportContent.AppendLine("DETAILED LOG:")
        $ReportData.LogEntries | ForEach-Object {
            $null = $reportContent.AppendLine("$($_.Timestamp) [$($_.Level.PadRight(8))] $($_.Message)")
        }
        $null = $reportContent.AppendLine(("-" * 70))
    }

    try {
        Set-Content -Path $reportFullPath -Value $reportContent.ToString() -Encoding UTF8 -Force
        & $LocalWriteLog -Message "  - TXT report generated: $reportFullPath" -Level "SUCCESS"
    } catch {
         & $LocalWriteLog -Message "[ERROR] Failed to generate TXT report '$reportFullPath'. Error: $($_.Exception.Message)" -Level "ERROR"
    }
}

Export-ModuleMember -Function Invoke-TxtReport
