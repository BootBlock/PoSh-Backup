<#
.SYNOPSIS
    Generates XML (Extensible Markup Language) reports for PoSh-Backup jobs using PowerShell's
    Export-Clixml format, which serializes PowerShell objects including type information,
    suitable for re-importing into PowerShell.
.DESCRIPTION
    This module creates an XML representation of the backup job report data. It uses
    PowerShell's native `Export-Clixml` cmdlet, which produces a detailed XML structure
    that accurately represents PowerShell objects and can be easily re-hydrated using
    `Import-Clixml`.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.4 (Removed PSSA attribute suppression; trailing whitespace removed)
    DateCreated:    14-May-2025
    LastModified:   15-May-2025
    Purpose:        XML (Clixml) report generation for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+. Called by Reporting.psm1 (orchestrator).
#>

function Invoke-XmlReport {
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

    & $LocalWriteLog -Message "[INFO] XML Report (Clixml) generation started for job '$JobName'." -Level "INFO"

    $reportTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeJobNameForFile = $JobName -replace '[^a-zA-Z0-9_-]', '_'
    $reportFileName = "$($safeJobNameForFile)_Report_$($reportTimestamp).xml"
    $reportFullPath = Join-Path -Path $ReportDirectory -ChildPath $reportFileName

    try {
        [PSCustomObject]$ReportData | Export-Clixml -Path $reportFullPath -Encoding UTF8 -Force
        & $LocalWriteLog -Message "  - XML report (Export-Clixml format) generated: $reportFullPath" -Level "SUCCESS"
    } catch {
         & $LocalWriteLog -Message "[ERROR] Failed to generate XML report '$reportFullPath'. Error: $($_.Exception.Message)" -Level "ERROR"
    }
}

Export-ModuleMember -Function Invoke-XmlReport
