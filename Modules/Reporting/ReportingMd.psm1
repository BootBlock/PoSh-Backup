<#
.SYNOPSIS
    Generates Markdown (.md) formatted reports for PoSh-Backup jobs.
    These reports offer a human-readable plain text format that can also be rendered
    into richly structured HTML, suitable for documentation or quick reviews.
    Includes sections for Remote Target Transfers, archive checksum information, and
    details for multi-volume archive manifests if applicable.

.DESCRIPTION
    This module creates reports using Markdown syntax for a completed PoSh-Backup job.
    The generated .md file is structured with Markdown headings, tables, and code blocks.

    The report typically includes:
    - A main title with the job name and generation timestamp.
    - A "SIMULATION MODE RUN" notice if applicable.
    - A "Summary" section (Markdown table) with overall job statistics, including
      checksum/manifest status.
    - A "Configuration Used" section (Markdown table).
    - A "Hook Scripts Executed" section (Markdown table), with output in <pre><code> blocks.
    - A "Remote Target Transfers" section (Markdown table).
    - An "Archive Manifest & Volume Verification" section (if applicable), detailing
      the manifest file, overall verification status, and a table of per-volume
      checksums and their verification statuses.
    - A "Detailed Log" section with log entries in fenced code blocks.

    Helper functions handle basic Markdown escaping.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.4.0 # Added Multi-Volume Manifest details section.
    DateCreated:    14-May-2025
    LastModified:   01-Jun-2025
    Purpose:        Markdown (.md) report generation sub-module for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Called by the main Reporting.psm1 orchestrator module.
#>

function Invoke-MdReport {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Generates a Markdown (.md) formatted report file for a specific PoSh-Backup job.
    .DESCRIPTION
        This function takes the consolidated report data for a backup job and formats it
        into a Markdown file. The report includes a summary, configuration, hook script details,
        target transfer data, multi-volume manifest verification details (if applicable),
        and log entries.
    .PARAMETER ReportDirectory
        The target directory where the generated .md report file will be saved.
    .PARAMETER JobName
        The name of the backup job.
    .PARAMETER ReportData
        A hashtable containing all data collected during the backup job's execution.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function.
    .EXAMPLE
        # Invoke-MdReport -ReportDirectory "C:\Reports\MD" -JobName "MyJob" -ReportData $JobData -Logger ${function:Write-LogMessage}
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

    & $Logger -Message "Invoke-MdReport: Logger parameter active for job '$JobName'." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    $EscapeMarkdownTableContent = {
        param($Content)
        if ($null -eq $Content) { return "" }
        return $Content.ToString() -replace '\|', '\|' -replace '\r?\n', '<br />'
    }
    $EscapeMarkdownCodeContent = {
        param($Content)
        if ($null -eq $Content) { return "" }
        return $Content.ToString() -replace '`', '\`' -replace '\*', '\*' -replace '_', '\_' -replace '\[', '\[' -replace '\]', '\]'
    }
    $LocalConvertToSafeHtml = { # For <pre> in table
        param([string]$TextToEncode)
        if ($null -eq $TextToEncode) { return '' }
        return $TextToEncode -replace '&', '&' -replace '<', '<' -replace '>', '>' -replace '"', '"' -replace "'", '&#39;'
    }

    & $LocalWriteLog -Message "[INFO] Markdown Report generation process started for job '$JobName'." -Level "INFO"

    $reportTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeJobNameForFile = $JobName -replace '[^a-zA-Z0-9_-]', '_'
    $reportFileName = "$($safeJobNameForFile)_Report_$($reportTimestamp).md"
    $reportFullPath = Join-Path -Path $ReportDirectory -ChildPath $reportFileName
    $reportContent = [System.Text.StringBuilder]::new()

    $titlePrefix = "PoSh Backup Status Report"
    $null = $reportContent.AppendLine("# $($titlePrefix) - $($JobName | ForEach-Object {$EscapeMarkdownCodeContent.Invoke($_)})")
    $null = $reportContent.AppendLine("")
    $null = $reportContent.AppendLine("**Generated:** $(Get-Date)")
    $null = $reportContent.AppendLine("")

    if ($ReportData.ContainsKey('IsSimulationReport') -and $ReportData.IsSimulationReport) {
        $null = $reportContent.AppendLine("> **\*\*\* SIMULATION MODE RUN \*\*\***")
        $null = $reportContent.AppendLine("> This report reflects a simulated backup. No actual files were changed or archives created.")
        $null = $reportContent.AppendLine("")
    }

    $null = $reportContent.AppendLine("## Summary")
    $null = $reportContent.AppendLine("")
    $null = $reportContent.AppendLine("| Item                                | Detail |") 
    $null = $reportContent.AppendLine("| :---------------------------------- | :----- |") 
    $excludedFromSummary = @('LogEntries', 'JobConfiguration', 'HookScripts', 'IsSimulationReport', 
                             '_PoShBackup_PSScriptRoot', 'TargetTransfers', 'VolumeChecksums', 
                             'ManifestVerificationDetails', 'ManifestVerificationResults')
    $ReportData.GetEnumerator() | Where-Object {$_.Name -notin $excludedFromSummary} | ForEach-Object {
        $value = if ($_.Value -is [array]) { ($_.Value | ForEach-Object { $EscapeMarkdownTableContent.Invoke($_) }) -join '; ' } else { $EscapeMarkdownTableContent.Invoke($_.Value) }
        $null = $reportContent.AppendLine("| $($EscapeMarkdownTableContent.Invoke($_.Name).PadRight(35)) | $value |") 
    }
    $null = $reportContent.AppendLine("")

    if ($ReportData.ContainsKey('JobConfiguration') -and $null -ne $ReportData.JobConfiguration) {
        $null = $reportContent.AppendLine("## Configuration Used for Job '$($JobName | ForEach-Object {$EscapeMarkdownCodeContent.Invoke($_)})'")
        $null = $reportContent.AppendLine("")
        $null = $reportContent.AppendLine("| Setting                             | Value |") 
        $null = $reportContent.AppendLine("| :---------------------------------- | :---- |") 
        $ReportData.JobConfiguration.GetEnumerator() | Sort-Object Name | ForEach-Object {
            $value = if ($_.Value -is [array]) { ($_.Value | ForEach-Object { $EscapeMarkdownTableContent.Invoke($_) }) -join '; ' } else { $EscapeMarkdownTableContent.Invoke($_.Value) }
            $null = $reportContent.AppendLine("| $($EscapeMarkdownTableContent.Invoke($_.Name).PadRight(35)) | $value |") 
        }
        $null = $reportContent.AppendLine("")
    }

    if ($ReportData.ContainsKey('HookScripts') -and $null -ne $ReportData.HookScripts -and $ReportData.HookScripts.Count -gt 0) {
        $null = $reportContent.AppendLine("## Hook Scripts Executed")
        $null = $reportContent.AppendLine("")
        $null = $reportContent.AppendLine("| Type    | Path                | Status  | Output/Error |")
        $null = $reportContent.AppendLine("| :------ | :------------------ | :------ | :----------- |")
        $ReportData.HookScripts | ForEach-Object {
            $hookPathEscaped = & $EscapeMarkdownTableContent $_.Path
            $hookOutputMd = if ([string]::IsNullOrWhiteSpace($_.Output)) { "*(No output recorded)*" }
                            else { $escapedHtmlOutput = & $LocalConvertToSafeHtml $_.Output.TrimEnd(); "<pre><code>$($escapedHtmlOutput)</code></pre>" }
            $null = $reportContent.AppendLine("| $(& $EscapeMarkdownTableContent $_.Name) | $hookPathEscaped | **$(& $EscapeMarkdownTableContent $_.Status)** | $hookOutputMd |")
        }
        $null = $reportContent.AppendLine("")
    }

    if ($ReportData.ContainsKey('TargetTransfers') -and $null -ne $ReportData.TargetTransfers -and $ReportData.TargetTransfers.Count -gt 0) {
        $null = $reportContent.AppendLine("## Remote Target Transfers")
        $null = $reportContent.AppendLine("")
        $null = $reportContent.AppendLine("| Target Name | File Transferred | Type    | Status  | Remote Path         | Duration | Size   | Error Message |") # Added File Transferred
        $null = $reportContent.AppendLine("| :---------- | :--------------- | :------ | :------ | :------------------ | :------- | :----- | :------------ |")
        foreach ($transferEntry in $ReportData.TargetTransfers) {
            $targetNameMd = & $EscapeMarkdownTableContent $transferEntry.TargetName
            $fileTransferredMd = & $EscapeMarkdownTableContent ($transferEntry.FileTransferred | Out-String).Trim()
            $targetTypeMd = & $EscapeMarkdownTableContent $transferEntry.TargetType
            $targetStatusMd = "**$(& $EscapeMarkdownTableContent $transferEntry.Status)**" 
            $remotePathMd = & $EscapeMarkdownTableContent $transferEntry.RemotePath
            $durationMd = & $EscapeMarkdownTableContent $transferEntry.TransferDuration
            $sizeFormattedMd = & $EscapeMarkdownTableContent $transferEntry.TransferSizeFormatted
            $errorMsgMd = if (-not [string]::IsNullOrWhiteSpace($transferEntry.ErrorMessage)) { & $EscapeMarkdownTableContent $transferEntry.ErrorMessage } else { "*(N/A)*" }
            $null = $reportContent.AppendLine("| $targetNameMd | $fileTransferredMd | $targetTypeMd | $targetStatusMd | $remotePathMd | $durationMd | $sizeFormattedMd | $errorMsgMd |")
        }
        $null = $reportContent.AppendLine("")
    }

    # --- NEW: Archive Manifest & Volume Verification Section ---
    $generateManifest = $ReportData.GenerateSplitArchiveManifest -is [boolean] ? $ReportData.GenerateSplitArchiveManifest : ($ReportData.GenerateSplitArchiveManifest -eq $true)
    $hasManifestFile = $ReportData.ContainsKey('ArchiveChecksumFile') -and -not [string]::IsNullOrWhiteSpace($ReportData.ArchiveChecksumFile) -and $ReportData.ArchiveChecksumFile -ne "N/A"
    $hasManifestVerificationResults = $ReportData.ContainsKey('ManifestVerificationResults') -and $null -ne $ReportData.ManifestVerificationResults -and $ReportData.ManifestVerificationResults -is [array] -and $ReportData.ManifestVerificationResults.Count -gt 0
    $hasVolumeChecksumsForDisplay = $ReportData.ContainsKey('VolumeChecksums') -and $null -ne $ReportData.VolumeChecksums -and $ReportData.VolumeChecksums -is [array] -and $ReportData.VolumeChecksums.Count -gt 0
    $hasManifestRawDetails = $ReportData.ContainsKey('ManifestVerificationDetails') -and -not [string]::IsNullOrWhiteSpace($ReportData.ManifestVerificationDetails)

    if ($generateManifest -and ($hasManifestFile -or $hasManifestVerificationResults -or $hasVolumeChecksumsForDisplay)) {
        $null = $reportContent.AppendLine("## Archive Manifest & Volume Verification")
        $null = $reportContent.AppendLine("")
        if ($hasManifestFile) {
            $escapedManifestPath = $ReportData.ArchiveChecksumFile | ForEach-Object {$EscapeMarkdownCodeContent.Invoke($_)}
            $null = $reportContent.AppendLine(('**Manifest File:** `' + $escapedManifestPath + '`'))
        }
        if ($ReportData.ContainsKey('ArchiveChecksumVerificationStatus')) {
            $null = $reportContent.AppendLine("**Overall Manifest Verification Status:** $($ReportData.ArchiveChecksumVerificationStatus | ForEach-Object {$EscapeMarkdownCodeContent.Invoke($_)})")
        }
        $null = $reportContent.AppendLine("")

        if ($hasManifestVerificationResults) {
            $null = $reportContent.AppendLine("| Volume Filename   | Expected Checksum                   | Actual Checksum                     | Status   |")
            $null = $reportContent.AppendLine("| :---------------- | :---------------------------------- | :---------------------------------- | :------- |")
            $ReportData.ManifestVerificationResults | ForEach-Object {
                $volName = $EscapeMarkdownTableContent.Invoke($_.VolumeName)
                $expHash = $EscapeMarkdownTableContent.Invoke($_.ExpectedChecksum)
                $actHash = $EscapeMarkdownTableContent.Invoke($_.ActualChecksum)
                $volStatus = "**$($EscapeMarkdownTableContent.Invoke($_.Status))**"
                $null = $reportContent.AppendLine("| $volName | $expHash | $actHash | $volStatus |")
            }
            $null = $reportContent.AppendLine("")
        } elseif ($hasVolumeChecksumsForDisplay) { # Fallback to generated checksums if no verification results
            $null = $reportContent.AppendLine("*The following checksums were generated for each volume (verification not performed or results unavailable):*")
            $null = $reportContent.AppendLine("")
            $null = $reportContent.AppendLine("| Volume Filename   | Generated Checksum                  |")
            $null = $reportContent.AppendLine("| :---------------- | :---------------------------------- |")
            $ReportData.VolumeChecksums | ForEach-Object {
                $volName = $EscapeMarkdownTableContent.Invoke($_.VolumeName)
                $genHash = $EscapeMarkdownTableContent.Invoke($_.Checksum)
                $null = $reportContent.AppendLine("| $volName | $genHash |")
            }
            $null = $reportContent.AppendLine("")
        }

        if ($hasManifestRawDetails) {
            $null = $reportContent.AppendLine("### Detailed Verification Log/Notes:")
            $null = $reportContent.AppendLine(('```text'))
            $null = $reportContent.AppendLine($ReportData.ManifestVerificationDetails) # Assuming this is already a simple string
            $null = $reportContent.AppendLine(('```'))
            $null = $reportContent.AppendLine("")
        }
    }
    # --- END NEW ---

    if ($ReportData.ContainsKey('LogEntries') -and $null -ne $ReportData.LogEntries -and $ReportData.LogEntries.Count -gt 0) {
        $null = $reportContent.AppendLine("## Detailed Log")
        $null = $reportContent.AppendLine("")
        $ReportData.LogEntries | ForEach-Object {
            $logLine = "$($_.Timestamp) [$($_.Level.ToUpper())] $($_.Message)"
            $null = $reportContent.AppendLine(('```text')) 
            $null = $reportContent.AppendLine(($EscapeMarkdownCodeContent.Invoke($logLine)))
            $null = $reportContent.AppendLine(('```'))
            $null = $reportContent.AppendLine("")
        }
    }

    try {
        Set-Content -Path $reportFullPath -Value $reportContent.ToString() -Encoding UTF8 -Force
        & $LocalWriteLog -Message "  - Markdown report generated successfully: '$reportFullPath'" -Level "SUCCESS"
    } catch {
         & $LocalWriteLog -Message "[ERROR] Failed to generate Markdown report '$reportFullPath' for job '$JobName'. Error: $($_.Exception.Message)" -Level "ERROR"
    }
    & $LocalWriteLog -Message "[INFO] Markdown Report generation process finished for job '$JobName'." -Level "INFO"
}

Export-ModuleMember -Function Invoke-MdReport
