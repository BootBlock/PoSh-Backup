<#
.SYNOPSIS
    Generates Comma Separated Values (CSV) reports for PoSh-Backup jobs.
    It provides a summary of the backup job (including checksum details,
    multi-volume split size, and manifest status if applicable), detailed log entries,
    hook script execution details, remote target transfer details, and multi-volume
    manifest checksum details, each in separate, easily parsable CSV files.

.DESCRIPTION
    This module is responsible for creating structured data output in CSV format for a
    completed PoSh-Backup job. For each job, it generates:
    1. A main summary CSV file (e.g., 'JobName_Summary_Timestamp.csv') containing
       key-value pairs of the overall job statistics and outcomes.
    2. Optionally, a CSV file for detailed log entries.
    3. Optionally, a CSV file for hook script execution details.
    4. Optionally, a CSV file for remote target transfer details.
    5. Optionally, if a multi-volume manifest was generated/verified, a CSV file
       (e.g., 'JobName_ManifestDetails_Timestamp.csv') detailing each volume's checksum
       and verification status.

    These CSV files are ideal for data import into spreadsheets, databases, or for
    programmatic analysis and integration with other monitoring or auditing systems.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.3.0 # Added Manifest Details CSV report.
    DateCreated:    14-May-2025
    LastModified:   01-Jun-2025
    Purpose:        CSV report generation sub-module for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Called by the main Reporting.psm1 orchestrator module.
#>

function Invoke-CsvReport {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Generates CSV formatted report files for a specific PoSh-Backup job.
    .DESCRIPTION
        This function takes the consolidated report data for a backup job and exports it
        into one or more CSV files. A primary CSV file provides a summary of the job.
        If log entries, hook script data, target transfer data, or multi-volume manifest
        details exist, they are exported into their own respective CSV files.
    .PARAMETER ReportDirectory
        The target directory where the generated CSV report files for this job will be saved.
    .PARAMETER JobName
        The name of the backup job, used in the filenames of the generated CSV reports.
    .PARAMETER ReportData
        A hashtable containing all data collected during the backup job's execution.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function.
    .EXAMPLE
        # Invoke-CsvReport -ReportDirectory "C:\Reports" -JobName "MyJob" -ReportData $JobData -Logger ${function:Write-LogMessage}
    .OUTPUTS
        None. This function creates files in the specified ReportDirectory.
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

    & $Logger -Message "Invoke-CsvReport: Logger parameter active for job '$JobName'." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    & $LocalWriteLog -Message "[INFO] CSV Report generation process started for job '$JobName'." -Level "INFO"

    $reportTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeJobNameForFile = $JobName -replace '[^a-zA-Z0-9_-]', '_'

    $summaryReportFileName = "$($safeJobNameForFile)_Summary_$($reportTimestamp).csv"
    $summaryReportFullPath = Join-Path -Path $ReportDirectory -ChildPath $summaryReportFileName

    try {
        $summaryObject = [PSCustomObject]@{}
        # Exclude complex nested objects from the main summary, they get their own files.
        $excludedFromSummary = @('LogEntries', 'JobConfiguration', 'HookScripts', 'IsSimulationReport', 
                                 '_PoShBackup_PSScriptRoot', 'TargetTransfers', 'VolumeChecksums', 
                                 'ManifestVerificationDetails', 'ManifestVerificationResults')
        
        $ReportData.GetEnumerator() | Where-Object {$_.Name -notin $excludedFromSummary} | ForEach-Object {
            $value = if ($_.Value -is [array]) { $_.Value -join '; ' } else { $_.Value }
            Add-Member -InputObject $summaryObject -MemberType NoteProperty -Name $_.Name -Value $value
        }

        $summaryObject | Export-Csv -Path $summaryReportFullPath -NoTypeInformation -Encoding UTF8 -Force
        & $LocalWriteLog -Message "  - Summary CSV report generated successfully: '$summaryReportFullPath'" -Level "SUCCESS"
    } catch {
         & $LocalWriteLog -Message "[ERROR] Failed to generate Summary CSV report '$summaryReportFullPath' for job '$JobName'. Error: $($_.Exception.Message)" -Level "ERROR"
    }

    if ($ReportData.ContainsKey('LogEntries') -and $null -ne $ReportData.LogEntries -and $ReportData.LogEntries.Count -gt 0) {
        $logReportFileName = "$($safeJobNameForFile)_Logs_$($reportTimestamp).csv"
        $logReportFullPath = Join-Path -Path $ReportDirectory -ChildPath $logReportFileName
        try {
            $ReportData.LogEntries | Export-Csv -Path $logReportFullPath -NoTypeInformation -Encoding UTF8 -Force
            & $LocalWriteLog -Message "  - Log Entries CSV report generated successfully: '$logReportFullPath'" -Level "SUCCESS"
        } catch {
            & $LocalWriteLog -Message "[ERROR] Failed to generate Log Entries CSV report '$logReportFullPath' for job '$JobName'. Error: $($_.Exception.Message)" -Level "ERROR"
        }
    } else { & $LocalWriteLog -Message "  - No log entries found. Log Entries CSV not generated." -Level "DEBUG" }

    if ($ReportData.ContainsKey('HookScripts') -and $null -ne $ReportData.HookScripts -and $ReportData.HookScripts.Count -gt 0) {
        $hookReportFileName = "$($safeJobNameForFile)_Hooks_$($reportTimestamp).csv"
        $hookReportFullPath = Join-Path -Path $ReportDirectory -ChildPath $hookReportFileName
        try {
            $ReportData.HookScripts | Export-Csv -Path $hookReportFullPath -NoTypeInformation -Encoding UTF8 -Force
            & $LocalWriteLog -Message "  - Hook Scripts CSV report generated successfully: '$hookReportFullPath'" -Level "SUCCESS"
        } catch {
            & $LocalWriteLog -Message "[ERROR] Failed to generate Hook Scripts CSV report '$hookReportFullPath' for job '$JobName'. Error: $($_.Exception.Message)" -Level "ERROR"
        }
    } else { & $LocalWriteLog -Message "  - No hook script data. Hook Scripts CSV not generated." -Level "DEBUG" }

    if ($ReportData.ContainsKey('TargetTransfers') -and $null -ne $ReportData.TargetTransfers -and $ReportData.TargetTransfers.Count -gt 0) {
        $targetTransfersReportFileName = "$($safeJobNameForFile)_TargetTransfers_$($reportTimestamp).csv"
        $targetTransfersReportFullPath = Join-Path -Path $ReportDirectory -ChildPath $targetTransfersReportFileName
        try {
            $targetTransfersForCsv = $ReportData.TargetTransfers | ForEach-Object {
                [PSCustomObject]@{
                    TargetName            = $_.TargetName
                    FileTransferred       = if ($_.PSObject.Properties.Name -contains 'FileTransferred') { $_.FileTransferred } else { 'N/A (Archive)' } # Handle older reports
                    TargetType            = $_.TargetType
                    Status                = $_.Status
                    RemotePath            = $_.RemotePath
                    TransferDuration      = $_.TransferDuration
                    TransferSize          = $_.TransferSize 
                    TransferSizeFormatted = $_.TransferSizeFormatted
                    ErrorMessage          = $_.ErrorMessage
                }
            }
            $targetTransfersForCsv | Export-Csv -Path $targetTransfersReportFullPath -NoTypeInformation -Encoding UTF8 -Force
            & $LocalWriteLog -Message "  - Target Transfers CSV report generated successfully: '$targetTransfersReportFullPath'" -Level "SUCCESS"
        } catch {
            & $LocalWriteLog -Message "[ERROR] Failed to generate Target Transfers CSV report '$targetTransfersReportFullPath' for job '$JobName'. Error: $($_.Exception.Message)" -Level "ERROR"
        }
    } else { & $LocalWriteLog -Message "  - No target transfer data. Target Transfers CSV not generated." -Level "DEBUG" }

    # --- NEW: Manifest Details CSV Report ---
    $generateManifest = $ReportData.GenerateSplitArchiveManifest -is [boolean] ? $ReportData.GenerateSplitArchiveManifest : ($ReportData.GenerateSplitArchiveManifest -eq $true)
    $hasManifestVerificationResults = $ReportData.ContainsKey('ManifestVerificationResults') -and $null -ne $ReportData.ManifestVerificationResults -and $ReportData.ManifestVerificationResults -is [array] -and $ReportData.ManifestVerificationResults.Count -gt 0
    $hasVolumeChecksums = $ReportData.ContainsKey('VolumeChecksums') -and $null -ne $ReportData.VolumeChecksums -and $ReportData.VolumeChecksums -is [array] -and $ReportData.VolumeChecksums.Count -gt 0

    if ($generateManifest -and ($hasManifestVerificationResults -or $hasVolumeChecksums)) {
        $manifestDetailsReportFileName = "$($safeJobNameForFile)_ManifestDetails_$($reportTimestamp).csv"
        $manifestDetailsReportFullPath = Join-Path -Path $ReportDirectory -ChildPath $manifestDetailsReportFileName
        try {
            $manifestDetailsForCsv = [System.Collections.Generic.List[object]]::new()
            if ($hasManifestVerificationResults) {
                $ReportData.ManifestVerificationResults | ForEach-Object {
                    $manifestDetailsForCsv.Add([PSCustomObject]@{
                        VolumeFileName   = $_.VolumeName
                        ExpectedChecksum = $_.ExpectedChecksum
                        ActualChecksum   = $_.ActualChecksum
                        Status           = $_.Status
                    })
                }
            } elseif ($hasVolumeChecksums) { # Fallback to showing generated checksums if verification didn't run/populate results
                $ReportData.VolumeChecksums | ForEach-Object {
                    $manifestDetailsForCsv.Add([PSCustomObject]@{
                        VolumeFileName   = $_.VolumeName
                        ExpectedChecksum = $_.Checksum
                        ActualChecksum   = "N/A (Not Verified)"
                        Status           = "Not Verified"
                    })
                }
            }

            if ($manifestDetailsForCsv.Count -gt 0) {
                $manifestDetailsForCsv | Export-Csv -Path $manifestDetailsReportFullPath -NoTypeInformation -Encoding UTF8 -Force
                & $LocalWriteLog -Message "  - Manifest Details CSV report generated successfully: '$manifestDetailsReportFullPath'" -Level "SUCCESS"
            } else {
                & $LocalWriteLog -Message "  - No detailed volume checksum data to write for Manifest Details CSV for job '$JobName'." -Level "DEBUG"
            }
        } catch {
            & $LocalWriteLog -Message "[ERROR] Failed to generate Manifest Details CSV report '$manifestDetailsReportFullPath' for job '$JobName'. Error: $($_.Exception.Message)" -Level "ERROR"
        }
    } else {
        if ($generateManifest) {
             & $LocalWriteLog -Message "  - Manifest generation was enabled, but no VolumeChecksums or ManifestVerificationResults data found. Manifest Details CSV not generated for job '$JobName'." -Level "DEBUG"
        } else {
             & $LocalWriteLog -Message "  - Manifest generation not enabled or no manifest data. Manifest Details CSV not generated for job '$JobName'." -Level "DEBUG"
        }
    }
    # --- END NEW: Manifest Details CSV Report ---

    & $LocalWriteLog -Message "[INFO] CSV Report generation process finished for job '$JobName'." -Level "INFO"
}

Export-ModuleMember -Function Invoke-CsvReport
