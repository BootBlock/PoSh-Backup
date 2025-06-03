<#
.SYNOPSIS
    Generates JSON (JavaScript Object Notation) reports for PoSh-Backup jobs.
    It serialises the complete report data structure for a backup job (including
    checksum information, multi-volume manifest details if applicable, and target
    transfer details for each file part), making it ideal for programmatic consumption.

.DESCRIPTION
    This module is responsible for creating a JSON representation of the backup job report data.
    It takes the entire '$ReportData' hashtable (which contains summary, logs, configuration,
    hook script details, checksum details, multi-volume manifest data, target transfer details, etc.)
    and converts it into a single JSON formatted file using PowerShell's 'ConvertTo-Json'
    cmdlet with a sufficient depth to capture all nested objects.

    The resulting JSON file provides a comprehensive, machine-readable snapshot of the backup
    job's execution and outcome.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.2.0 # Manifest/volume checksum data now implicitly included in ReportData.
    DateCreated:    14-May-2025
    LastModified:   01-Jun-2025
    Purpose:        JSON report generation sub-module for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Called by the main Reporting.psm1 orchestrator module.
#>

function Invoke-JsonReport {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Generates a single JSON file containing all report data for a PoSh-Backup job.
    .DESCRIPTION
        This function takes the consolidated report data for a backup job and serialises
        the entire data structure into a single JSON file. The 'ConvertTo-Json' cmdlet
        is used with a depth of 10 to ensure comprehensive serialisation of nested objects
        within the report data (including multi-volume manifest and checksum details if present,
        and per-file target transfer information). The output file is named using the job name
        and a timestamp.
    .PARAMETER ReportDirectory
        The target directory where the generated JSON report file for this job will be saved.
    .PARAMETER JobName
        The name of the backup job. Used in the filename of the generated JSON report.
    .PARAMETER ReportData
        A hashtable containing all data collected during the backup job's execution.
        This entire hashtable will be serialised to JSON.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function.
    .EXAMPLE
        # Invoke-JsonReport -ReportDirectory "C:\Reports\JSON" -JobName "MyJob" -ReportData $JobData -Logger ${function:Write-LogMessage}
    .OUTPUTS
        None. This function creates a file in the specified ReportDirectory.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$ReportDirectory,
        [Parameter(Mandatory=$true)]
        [string]$JobName,
        [Parameter(Mandatory=$true)]
        [hashtable]$ReportData,
        [Parameter(Mandatory=$true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "Invoke-JsonReport: Logger parameter active for job '$JobName'." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    & $LocalWriteLog -Message "[INFO] JSON Report generation process started for job '$JobName'." -Level "INFO"

    $reportTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeJobNameForFile = $JobName -replace '[^a-zA-Z0-9_-]', '_'
    $reportFileName = "$($safeJobNameForFile)_Report_$($reportTimestamp).json"
    $reportFullPath = Join-Path -Path $ReportDirectory -ChildPath $reportFileName

    try {
        $ReportData | ConvertTo-Json -Depth 10 | Set-Content -Path $reportFullPath -Encoding UTF8 -Force
        & $LocalWriteLog -Message "  - JSON report generated successfully: '$reportFullPath'" -Level "SUCCESS"
    } catch {
         & $LocalWriteLog -Message "[ERROR] Failed to generate JSON report '$reportFullPath' for job '$JobName'. Error: $($_.Exception.Message)" -Level "ERROR"
    }
    & $LocalWriteLog -Message "[INFO] JSON Report generation process finished for job '$JobName'." -Level "INFO"
}

Export-ModuleMember -Function Invoke-JsonReport
