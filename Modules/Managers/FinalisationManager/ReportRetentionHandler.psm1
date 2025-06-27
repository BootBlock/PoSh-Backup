# Modules\Managers\FinalisationManager\ReportRetentionHandler.psm1
<#
.SYNOPSIS
    A sub-module for FinalisationManager. Handles the retention policy for report files.
.DESCRIPTION
    This module provides the 'Invoke-PoShBackupReportRetention' function. It is responsible
    for finding and deleting or compressing old report files based on a specified retention
    count and job name pattern. This helps prevent the Reports directory from growing indefinitely.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    27-Jun-2025
    LastModified:   27-Jun-2025
    Purpose:        To isolate the report file retention logic.
    Prerequisites:  PowerShell 5.1+.
#>

function Invoke-PoShBackupReportRetention {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,
        [Parameter(Mandatory = $true)]
        [string[]]$ProcessedJobNames,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    & $Logger -Message "FinalisationManager/ReportRetentionHandler: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO")
        & $Logger -Message $Message -Level $Level
    }

    $retentionCount = $Configuration.DefaultReportRetentionCount
    $compressOld = $Configuration.CompressOldReports
    $compressFormat = $Configuration.OldReportCompressionFormat

    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: Report Retention Policy would be applied (Keep: $retentionCount, Compress: $compressOld)." -Level "SIMULATE"
        return
    }

    if ($retentionCount -eq 0) {
        & $LocalWriteLog -Message "[INFO] ReportRetentionHandler: ReportRetentionCount is 0. All report files will be kept." -Level "INFO"
        return
    }

    & $LocalWriteLog -Message "`n[INFO] ReportRetentionHandler: Applying Report Retention Policy..." -Level "INFO"
    & $LocalWriteLog -Message "   - Number of report sets to keep per job: $retentionCount"
    & $LocalWriteLog -Message "   - Compress Old Reports: $compressOld"

    $reportDirs = @(
        $Configuration.HtmlReportDirectory,
        $Configuration.CsvReportDirectory,
        $Configuration.JsonReportDirectory,
        $Configuration.XmlReportDirectory,
        $Configuration.TxtReportDirectory,
        $Configuration.MdReportDirectory
    ) | Select-Object -Unique | ForEach-Object {
        if ([System.IO.Path]::IsPathRooted($_)) { $_ }
        else { Join-Path -Path $Configuration._PoShBackup_PSScriptRoot -ChildPath $_ }
    } | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -Unique

    foreach ($jobName in $ProcessedJobNames) {
        $safeJobName = $jobName -replace '[^a-zA-Z0-9_-]', '_'
        $reportFilePattern = "$($safeJobName)_Report_*.???"
        $allReportFilesForJob = @()

        foreach ($dir in $reportDirs) {
            $allReportFilesForJob += Get-ChildItem -Path $dir -Filter $reportFilePattern -File -ErrorAction SilentlyContinue
        }

        if ($allReportFilesForJob.Count -eq 0) { continue }

        $reportInstances = $allReportFilesForJob | Group-Object {
            if ($_.Name -match "Report_(\d{8}_\d{6})\.") { $Matches[1] } else { $_.CreationTime.ToString("yyyyMMdd_HHmmss") }
        } | Sort-Object @{Expression = { [datetime]::ParseExact($_.Name, "yyyyMMdd_HHmmss", $null) }; Descending = $true }

        if ($reportInstances.Count -le $retentionCount) {
            continue
        }

        $instancesToProcess = $reportInstances | Select-Object -Skip $retentionCount
        & $LocalWriteLog -Message "   - Job '$jobName': Found $($reportInstances.Count) report instance(s). Will process $($instancesToProcess.Count) older instance(s)." -Level "INFO"

        foreach ($instance in $instancesToProcess) {
            $filesInInstance = $instance.Group
            if ($compressOld) {
                $archiveFileName = "ArchivedReports_$($safeJobName)_$($instance.Name).$($compressFormat.ToLower())"
                $archiveFullPath = Join-Path -Path $filesInInstance[0].DirectoryName -ChildPath $archiveFileName
                
                if (-not $PSCmdletInstance.ShouldProcess($archiveFullPath, "Compress and Remove Old Reports")) {
                    & $LocalWriteLog -Message "       - Report compression for instance '$($instance.Name)' skipped by user." -Level "WARNING"
                    continue
                }
                try {
                    Compress-Archive -Path $filesInInstance.FullName -DestinationPath $archiveFullPath -Update -ErrorAction Stop
                    Remove-Item -Path $filesInInstance.FullName -Force -ErrorAction Stop
                }
                catch { & $LocalWriteLog -Message "[ERROR] Failed to compress or remove original report files for instance '$($instance.Name)'. Error: $($_.Exception.Message)" -Level "ERROR" }
            }
            else {
                if (-not $PSCmdletInstance.ShouldProcess($filesInInstance[0].DirectoryName, "Permanently Delete $($filesInInstance.Count) report files for instance dated $($instance.Name)")) {
                    & $LocalWriteLog -Message "       - Deletion of report instance '$($instance.Name)' skipped by user." -Level "WARNING"
                    continue
                }
                try {
                    Remove-Item -Path $filesInInstance.FullName -Force -ErrorAction Stop
                    & $LocalWriteLog -Message "       - Deleting report instance dated $($instance.Name)... Status: DELETED PERMANENTLY" -Level "SUCCESS"
                }
                catch { & $LocalWriteLog -Message "       - FAILED to delete one or more files for instance '$($instance.Name)'! Error: $($_.Exception.Message)" -Level "ERROR" }
            }
        }
    }
}

Export-ModuleMember -Function Invoke-PoShBackupReportRetention
