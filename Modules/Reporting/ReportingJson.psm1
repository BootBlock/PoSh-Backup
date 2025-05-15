<#
.SYNOPSIS
    Generates JSON (JavaScript Object Notation) reports for PoSh-Backup jobs, serializing
    the complete report data structure for programmatic consumption and integration
    with other tools or systems.
.DESCRIPTION
    This module outputs the entire backup job report data as a single JSON file.
    This format is ideal for machine-to-machine communication, API integration,
    or for use with various data processing tools that understand JSON.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.4 (Removed PSSA attribute suppression; trailing whitespace removed)
    DateCreated:    14-May-2025
    LastModified:   15-May-2025
    Purpose:        JSON report generation for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+. Called by Reporting.psm1 (orchestrator).
#>

function Invoke-JsonReport {
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

    & $LocalWriteLog -Message "[INFO] JSON Report generation started for job '$JobName'." -Level "INFO"

    $reportTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeJobNameForFile = $JobName -replace '[^a-zA-Z0-9_-]', '_'
    $reportFileName = "$($safeJobNameForFile)_Report_$($reportTimestamp).json"
    $reportFullPath = Join-Path -Path $ReportDirectory -ChildPath $reportFileName

    try {
        $ReportData | ConvertTo-Json -Depth 10 | Set-Content -Path $reportFullPath -Encoding UTF8 -Force
        & $LocalWriteLog -Message "  - JSON report generated: $reportFullPath" -Level "SUCCESS"
    } catch {
         & $LocalWriteLog -Message "[ERROR] Failed to generate JSON report '$reportFullPath'. Error: $($_.Exception.Message)" -Level "ERROR"
    }
}

Export-ModuleMember -Function Invoke-JsonReport
