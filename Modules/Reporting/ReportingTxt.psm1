# Modules\Reporting\ReportingTxt.psm1
<#
.SYNOPSIS
    Generates plain text (.txt) summary reports for PoSh-Backup jobs.
    These reports provide a simple, human-readable overview of the backup operation,
    including summary details (checksum information, split volume size, manifest status),
    configuration settings, hook script actions, remote target transfers (detailing each
    file part if applicable), multi-volume manifest verification details, and log entries.

.DESCRIPTION
    This module produces a straightforward plain text report, formatted for easy reading.
    The report typically includes:
    - Header: Job name and generation timestamp.
    - Simulation Notice: If applicable.
    - SUMMARY: Key outcomes, including checksum/manifest status.
    - CONFIGURATION USED: Job-specific settings.
    - HOOK SCRIPTS EXECUTED: Details of custom scripts.
    - REMOTE TARGET TRANSFERS: Details for each file transferred to each target.
    - ARCHIVE MANIFEST & VOLUME VERIFICATION: (If applicable) Manifest path, overall status,
      and per-volume checksum verification details.
    - DETAILED LOG: Chronological log messages.

    Array values are typically joined with semicolons; multi-line outputs are indented.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.3.1 # Refactored to use StringBuilder and handle complex types gracefully.
    DateCreated:    14-May-2025
    LastModified:   29-Jun-2025
    Prerequisites:  PowerShell 5.1+.
                    Called by the main Reporting.psm1 orchestrator module.
#>

function Invoke-TxtReport {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Generates a plain text (.txt) report file summarising a PoSh-Backup job.
    .DESCRIPTION
        This function takes the consolidated report data for a backup job and formats it
        into a human-readable plain text file. The report includes a summary, configuration,
        hook script details, target transfer data (including individual file parts),
        multi-volume manifest verification details (if applicable), and log messages.
    .PARAMETER ReportDirectory
        The target directory where the generated .txt report file will be saved.
    .PARAMETER JobName
        The name of the backup job.
    .PARAMETER ReportData
        A hashtable containing all data collected during the backup job's execution.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function.
    .EXAMPLE
        # Invoke-TxtReport -ReportDirectory "C:\Reports\TXT" -JobName "MyJob" -ReportData $JobData -Logger ${function:Write-LogMessage}
    .OUTPUTS
        None. This function creates a file in the specified ReportDirectory.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReportDirectory,
        [Parameter(Mandatory = $true)]
        [string]$JobName,
        [Parameter(Mandatory = $true)]
        [hashtable]$ReportData,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "Invoke-TxtReport: Logger parameter active for job '$JobName'." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        }
        else {
            & $Logger -Message $Message -Level $Level
        }
    }

    & $LocalWriteLog -Message "[INFO] TXT Report generation process started for job '$JobName'." -Level "INFO"

    $reportTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeJobNameForFile = $JobName -replace '[^a-zA-Z0-9_-]', '_'
    $reportFileName = "$($safeJobNameForFile)_Report_$($reportTimestamp).txt"
    $reportFullPath = Join-Path -Path $ReportDirectory -ChildPath $reportFileName

    $reportContent = [System.Text.StringBuilder]::new()
    $separatorLine = "-" * 70
    $subSeparatorLine = "    " + ("-" * 66)
    $keyPadWidth = 38
    $indent = "  "

    $null = $reportContent.AppendLine("PoSh Backup Report - Job: $JobName")
    $null = $reportContent.AppendLine("Generated: $(Get-Date)")
    if ($ReportData.ContainsKey('IsSimulationReport') -and $ReportData.IsSimulationReport) {
        $null = $reportContent.AppendLine(("*" * 70))
        $null = $reportContent.AppendLine("*** SIMULATION MODE RUN - NO ACTUAL CHANGES WERE MADE ***")
        $null = $reportContent.AppendLine(("*" * 70))
    }
    $null = $reportContent.AppendLine($separatorLine)

    $null = $reportContent.AppendLine($indent + "SUMMARY:")
    $excludedFromSummary = @('LogEntries', 'JobConfiguration', 'HookScripts', 'IsSimulationReport',
        '_PoShBackup_PSScriptRoot', 'TargetTransfers', 'VolumeChecksums',
        'ManifestVerificationDetails', 'ManifestVerificationResults')

    $ReportData.GetEnumerator() | Where-Object { $_.Name -notin $excludedFromSummary } | ForEach-Object {
        $value = ""
        if ($_.Value -is [System.TimeSpan]) {
            $ts = $_.Value
            $value = "{0}.{1:d2}:{2:d2}:{3:d2}" -f $ts.Days, $ts.Hours, $ts.Minutes, $ts.Seconds
        }
        elseif ($_.Value -is [array]) {
            $value = ($_.Value | ForEach-Object { $_ -replace "`r`n", " " -replace "`n", " " }) -join '; '
        }
        elseif ($_.Value -is [hashtable]) {
            $htStrings = $_.Value.GetEnumerator() | ForEach-Object { "$($_.Name)=$($_.Value)" }
            $value = "{ $($htStrings -join '; ') }"
        }
        else {
            $value = ($_.Value | Out-String).Trim() -replace "`r`n", " " -replace "`n", " "
        }
        $null = $reportContent.AppendLine($indent + "  $($_.Name.PadRight($keyPadWidth)): $value")
    }
    $null = $reportContent.AppendLine($separatorLine)

    if ($ReportData.ContainsKey('JobConfiguration') -and $null -ne $ReportData.JobConfiguration) {
        $null = $reportContent.AppendLine($indent + "CONFIGURATION USED FOR JOB '$JobName':")
        $ReportData.JobConfiguration.GetEnumerator() | Sort-Object Name | ForEach-Object {
            $value = if ($_.Value -is [array]) { ($_.Value | ForEach-Object { $_ -replace "`r`n", " " -replace "`n", " " }) -join '; ' } else { ($_.Value | Out-String).Trim() }
            if ($_.Value -is [hashtable]) {
                $htStrings = $_.Value.GetEnumerator() | ForEach-Object { "$($_.Name)=$($_.Value)" }
                $value = "{ $($htStrings -join '; ') }"
            }
            $null = $reportContent.AppendLine($indent + "  $($_.Name.PadRight($keyPadWidth)): $value")
        }
        $null = $reportContent.AppendLine($separatorLine)
    }

    if ($ReportData.ContainsKey('HookScripts') -and $null -ne $ReportData.HookScripts -and $ReportData.HookScripts.Count -gt 0) {
        $null = $reportContent.AppendLine($indent + "HOOK SCRIPTS EXECUTED:")
        $ReportData.HookScripts | ForEach-Object {
            $null = $reportContent.AppendLine($indent + "  Hook Type : $($_.Name)")
            $null = $reportContent.AppendLine($indent + "  Path      : $($_.Path)")
            $null = $reportContent.AppendLine($indent + "  Status    : $($_.Status)")
            if (-not [string]::IsNullOrWhiteSpace($_.Output)) {
                $indentedOutput = ($_.Output.TrimEnd() -split '\r?\n' | ForEach-Object { ($indent + "              $_") }) -join [Environment]::NewLine
                $null = $reportContent.AppendLine($indent + "  Output    : $($indentedOutput.TrimStart())")
            }
            $null = $reportContent.AppendLine()
        }
        $null = $reportContent.AppendLine($separatorLine)
    }

    if ($ReportData.ContainsKey('TargetTransfers') -and $null -ne $ReportData.TargetTransfers -and $ReportData.TargetTransfers.Count -gt 0) {
        $null = $reportContent.AppendLine($indent + "REMOTE TARGET TRANSFERS:")
        foreach ($transferEntry in $ReportData.TargetTransfers) {
            $null = $reportContent.AppendLine($indent + "  Target Name : $($transferEntry.TargetName)")
            $fileTransferredDisplay = if ($transferEntry.PSObject.Properties.Name -contains 'FileTransferred') { $transferEntry.FileTransferred } else { 'N/A (Archive)' }
            $null = $reportContent.AppendLine($indent + "  File Xferred: $fileTransferredDisplay")
            $null = $reportContent.AppendLine($indent + "  Target Type : $($transferEntry.TargetType)")
            $null = $reportContent.AppendLine($indent + "  Status      : $($transferEntry.Status)")
            $null = $reportContent.AppendLine($indent + "  Remote Path : $($transferEntry.RemotePath)")
            $null = $reportContent.AppendLine($indent + "  Duration    : $($transferEntry.TransferDuration)")
            $null = $reportContent.AppendLine($indent + "  Size        : $($transferEntry.TransferSizeFormatted)")
            if (-not [string]::IsNullOrWhiteSpace($transferEntry.ErrorMessage)) {
                $indentedError = ($transferEntry.ErrorMessage.TrimEnd() -split '\r?\n' | ForEach-Object { ($indent + "                $_") }) -join [Environment]::NewLine
                $null = $reportContent.AppendLine($indent + "  Error Msg   : $($indentedError.TrimStart())")
            }
            if ($ReportData.TargetTransfers.IndexOf($transferEntry) -lt ($ReportData.TargetTransfers.Count - 1)) {
                $null = $reportContent.AppendLine($subSeparatorLine)
            }
        }
        $null = $reportContent.AppendLine($separatorLine)
    }

    # --- Archive Manifest & Volume Verification Section ---
    $generateManifest = $ReportData.GenerateSplitArchiveManifest -is [boolean] ? $ReportData.GenerateSplitArchiveManifest : ($ReportData.GenerateSplitArchiveManifest -eq $true)
    $hasManifestFile = $ReportData.ContainsKey('ArchiveChecksumFile') -and -not [string]::IsNullOrWhiteSpace($ReportData.ArchiveChecksumFile) -and $ReportData.ArchiveChecksumFile -ne "N/A"
    $hasManifestVerificationResults = $ReportData.ContainsKey('ManifestVerificationResults') -and $null -ne $ReportData.ManifestVerificationResults -and $ReportData.ManifestVerificationResults -is [array] -and $ReportData.ManifestVerificationResults.Count -gt 0
    $hasVolumeChecksumsForDisplay = $ReportData.ContainsKey('VolumeChecksums') -and $null -ne $ReportData.VolumeChecksums -and $ReportData.VolumeChecksums -is [array] -and $ReportData.VolumeChecksums.Count -gt 0
    $hasManifestRawDetails = $ReportData.ContainsKey('ManifestVerificationDetails') -and -not [string]::IsNullOrWhiteSpace($ReportData.ManifestVerificationDetails)

    if ($generateManifest -and ($hasManifestFile -or $hasManifestVerificationResults -or $hasVolumeChecksumsForDisplay)) {
        $null = $reportContent.AppendLine($indent + "ARCHIVE MANIFEST & VOLUME VERIFICATION:")
        if ($hasManifestFile) {
            $null = $reportContent.AppendLine($indent + "  Manifest File: $($ReportData.ArchiveChecksumFile)")
        }
        if ($ReportData.ContainsKey('ArchiveChecksumVerificationStatus')) {
            $null = $reportContent.AppendLine($indent + "  Overall Manifest Verification Status: $($ReportData.ArchiveChecksumVerificationStatus)")
        }
        $null = $reportContent.AppendLine()

        if ($hasManifestVerificationResults) {
            $null = $reportContent.AppendLine($indent + "  Volume Verification Details:")
            $ReportData.ManifestVerificationResults | ForEach-Object {
                $null = $reportContent.AppendLine($indent + "    Volume            : $($_.VolumeName)")
                $null = $reportContent.AppendLine($indent + "    Expected Checksum : $($_.ExpectedChecksum)")
                $null = $reportContent.AppendLine($indent + "    Actual Checksum   : $($_.ActualChecksum)")
                $null = $reportContent.AppendLine($indent + "    Status            : $($_.Status)")
                $null = $reportContent.AppendLine($indent + "    ------------------------------------")
            }
        }
        elseif ($hasVolumeChecksumsForDisplay) {
            $null = $reportContent.AppendLine($indent + "  Generated Volume Checksums (Verification Not Performed):")
            $ReportData.VolumeChecksums | ForEach-Object {
                $null = $reportContent.AppendLine($indent + "    Volume            : $($_.VolumeName)")
                $null = $reportContent.AppendLine($indent + "    Generated Checksum: $($_.Checksum)")
                $null = $reportContent.AppendLine($indent + "    ------------------------------------")
            }
        }

        if ($hasManifestRawDetails) {
            $null = $reportContent.AppendLine()
            $null = $reportContent.AppendLine($indent + "  Detailed Verification Log/Notes:")
            $indentedDetails = ($ReportData.ManifestVerificationDetails.TrimEnd() -split '\r?\n' | ForEach-Object { ($indent + "    $_") }) -join [Environment]::NewLine
            $null = $reportContent.AppendLine($indentedDetails)
        }
        $null = $reportContent.AppendLine($separatorLine)
    }
    # --- END ---

    if ($ReportData.ContainsKey('LogEntries') -and $null -ne $ReportData.LogEntries -and $ReportData.LogEntries.Count -gt 0) {
        $null = $reportContent.AppendLine($indent + "DETAILED LOG:")
        $ReportData.LogEntries | ForEach-Object {
            $logLine = "$($_.Timestamp) [$($_.Level.ToUpper().PadRight(8))] $($_.Message.Trim())"
            $null = $reportContent.AppendLine($indent + "  $logLine")
        }
        $null = $reportContent.AppendLine($separatorLine)
    }

    try {
        Set-Content -Path $reportFullPath -Value $reportContent.ToString() -Encoding UTF8 -Force
        & $LocalWriteLog -Message "  - TXT report generated successfully: '$reportFullPath'" -Level "SUCCESS"
    }
    catch {
        & $LocalWriteLog -Message "[ERROR] Failed to generate TXT report '$reportFullPath' for job '$JobName'. Error: $($_.Exception.Message)" -Level "ERROR"
    }
    & $LocalWriteLog -Message "[INFO] TXT Report generation process finished for job '$JobName'." -Level "INFO"
}

Export-ModuleMember -Function Invoke-TxtReport
