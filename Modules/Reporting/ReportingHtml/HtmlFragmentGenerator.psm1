# Modules\Reporting\ReportingHtml\HtmlFragmentGenerator.psm1
<#
.SYNOPSIS
    A sub-module for ReportingHtml.psm1. Generates discrete HTML fragments for the report.
.DESCRIPTION
    This module contains a collection of functions, each responsible for generating the
    HTML markup for a specific section of the report (e.g., Summary table, Hooks table).
    It takes the raw report data as input and returns strings of HTML, ready to be
    injected into the main report template. It imports the common HTML sanitisation utility.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.1
    DateCreated:    28-Jun-2025
    LastModified:   28-Jun-2025
    Purpose:        To isolate the generation of dynamic HTML report sections.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Reporting\ReportingHtml
try {
    Import-Module -Name (Join-Path $PSScriptRoot "HtmlUtils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "HtmlFragmentGenerator.psm1 FATAL: Could not import a dependent module. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- Fragment Generator Functions ---

function Get-SummaryTableRowsHtml {
    param([hashtable]$ReportData)
    $sb = [System.Text.StringBuilder]::new()
    $sumOrder = @('JobName','OverallStatus','ScriptStartTime','ScriptEndTime','TotalDuration','TotalDurationSeconds',
                  'SourcePath','EffectiveSourcePath','FinalArchivePath','ArchiveSizeFormatted','ArchiveSizeBytes',
                  'SplitVolumeSize', 'GenerateSplitArchiveManifest', 'SFXCreationOverriddenBySplit', 
                  'SevenZipExitCode','TreatSevenZipWarningsAsSuccess','RetryAttemptsMade',
                  'ArchiveTested','ArchiveTestResult','TestRetryAttemptsMade',
                  'ArchiveChecksum','ArchiveChecksumAlgorithm','ArchiveChecksumFile','ArchiveChecksumVerificationStatus',
                  'VSSAttempted','VSSStatus','VSSShadowPaths','PasswordSource','ErrorMessage')
    $sumDisp = [ordered]@{}; 
    foreach($k in $sumOrder){ if($ReportData.ContainsKey($k)){ $sumDisp[$k]=$ReportData[$k] } }
    $ReportData.GetEnumerator()|Where-Object {$_.Name -notin $sumOrder -and $_.Name -notin @('LogEntries','JobConfiguration','HookScripts','IsSimulationReport','_PoShBackup_PSScriptRoot','TargetTransfers', 'VolumeChecksums', 'ManifestVerificationDetails', 'ManifestVerificationResults')}|ForEach-Object {$sumDisp[$_.Name]=$_.Value}
    
    $sumDisp.GetEnumerator()|ForEach-Object {
        $kN=ConvertTo-SafeHtml $_.Name;$v=$_.Value;$dV="";$sC="";$sA=""
        if ($kN -eq 'GenerateSplitArchiveManifest' -and $v -is [boolean]) { $dV = if ($v) { "Yes" } else { "No" } }
        elseif ($v -is [array]){$dV=($v|ForEach-Object {ConvertTo-SafeHtml ([string]$_)}) -join '<br>'}
        else{$dV=ConvertTo-SafeHtml([string]$v)}
        if($kN -eq "OverallStatus" -or $kN -eq "ArchiveTestResult" -or $kN -eq "VSSStatus" -or $kN -eq "ArchiveChecksumVerificationStatus"){$sVal=([string]$_.Value -replace ' ','_') -replace '[\(\):\/]','_' -replace '\+','plus' -replace ',','';$sC="status-$(ConvertTo-SafeHtml $sVal)"}
        elseif($kN -eq "VSSAttempted" -or $kN -eq 'GenerateSplitArchiveManifest' ){$sC=if($v -eq $true){"status-INFO"}else{"status-DEFAULT"}}
        if($kN -eq "ArchiveSizeFormatted" -and $ReportData.ArchiveSizeBytes -is [long]){$sA="data-sort-value='$($ReportData.ArchiveSizeBytes)'"}
        elseif($kN -eq "TotalDuration" -and $ReportData.TotalDurationSeconds -is [double]){$sA="data-sort-value='$($ReportData.TotalDurationSeconds)'"}
        
        if ($kN -eq 'OverallStatus') { $dV = "<a href='#details-logs' title='Click to jump to the detailed log'>$dV</a>" }
    
        $null=$sb.Append("<tr><td data-label='Item'>$kN</td><td data-label='Detail' class='$sC' $sA>$dV</td></tr>")}
    return $sb.ToString()
}

function Get-TargetTransfersTableRowsHtml {
    param([array]$TargetTransfers)
    if ($null -eq $TargetTransfers -or $TargetTransfers.Count -eq 0) { return "" }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($tE in $TargetTransfers) {
        $tNS=ConvertTo-SafeHtml $tE.TargetName;$tTFS=ConvertTo-SafeHtml $tE.FileTransferred;$tTS=ConvertTo-SafeHtml $tE.TargetType
        $tSS=ConvertTo-SafeHtml $tE.Status;$tSC="status-$(($tE.Status -replace ' ','_')-replace '[\(\):\/]','_'-replace '\+','plus')"
        $rPS=ConvertTo-SafeHtml $tE.RemotePath;$dS=ConvertTo-SafeHtml $tE.TransferDuration
        $sFS=ConvertTo-SafeHtml $tE.TransferSizeFormatted;$sBSA=if($tE.PSObject.Properties.Name -contains "TransferSize" -and $tE.TransferSize -is [long]){"data-sort-value='$($tE.TransferSize)'"}else{""}
        $eMS=if(-not[string]::IsNullOrWhiteSpace($tE.ErrorMessage)){ConvertTo-SafeHtml $tE.ErrorMessage}else{"<em>N/A</em>"}
        $null=$sb.Append("<tr><td data-label='Target Name'>$tNS</td><td data-label='File'>$tTFS</td><td data-label='Type'>$tTS</td><td data-label='Status' class='$tSC'>$tSS</td><td data-label='Remote Path'>$rPS</td><td data-label='Duration'>$dS</td><td data-label='Size' $sBSA>$sFS</td><td data-label='Error Message'>$eMS</td></tr>")
    }
    return $sb.ToString()
}

function Get-ManifestDetailsSectionHtml {
    param([hashtable]$ReportData)
    $sectionData = @{
        ShowSection = $false; FilePath = ""; OverallStatus = ""; OverallStatusClass = "";
        ShowVolumesTable = $false; VolumesTableRows = "";
        ShowRawDetails = $false; RawDetails = "";
    }

    $generateManifest = $ReportData.GenerateSplitArchiveManifest -is [boolean] ? $ReportData.GenerateSplitArchiveManifest : ($ReportData.GenerateSplitArchiveManifest -eq $true)
    $hasManifestFile = $ReportData.ContainsKey('ArchiveChecksumFile') -and -not [string]::IsNullOrWhiteSpace($ReportData.ArchiveChecksumFile) -and $ReportData.ArchiveChecksumFile -ne "N/A"
    $hasVerificationResults = $ReportData.ContainsKey('ManifestVerificationResults') -and $ReportData.ManifestVerificationResults -is [array] -and $ReportData.ManifestVerificationResults.Count -gt 0
    $hasVolumeChecksums = $ReportData.ContainsKey('VolumeChecksums') -and $ReportData.VolumeChecksums -is [array] -and $ReportData.VolumeChecksums.Count -gt 0
    $hasRawDetails = $ReportData.ContainsKey('ManifestVerificationDetails') -and -not [string]::IsNullOrWhiteSpace($ReportData.ManifestVerificationDetails)

    if ($generateManifest -and ($hasManifestFile -or $hasVerificationResults -or $hasVolumeChecksums)) {
        $sectionData.ShowSection = $true
        $sectionData.FilePath = ConvertTo-SafeHtml ($ReportData.ArchiveChecksumFile | Out-String).Trim()
        $sectionData.OverallStatus = ConvertTo-SafeHtml ($ReportData.ArchiveChecksumVerificationStatus | Out-String).Trim()
        $sectionData.OverallStatusClass = "status-" + (ConvertTo-SafeHtml (($ReportData.ArchiveChecksumVerificationStatus | Out-String).Trim() -replace ' ','_' -replace '[\(\):\/]','_' -replace '\+','plus'))

        if ($hasVerificationResults) {
            $sbManifest = [System.Text.StringBuilder]::new()
            $ReportData.ManifestVerificationResults | ForEach-Object {
                $volName=ConvertTo-SafeHtml $_.VolumeName; $expHash=ConvertTo-SafeHtml $_.ExpectedChecksum; $actHash=ConvertTo-SafeHtml $_.ActualChecksum; $volStatus=ConvertTo-SafeHtml $_.Status; $volStatusClass="status-" + (ConvertTo-SafeHtml ($_.Status -replace ' ','_'))
                $null = $sbManifest.Append("<tr><td data-label='Volume Filename'>$volName</td><td data-label='Expected Checksum'>$expHash</td><td data-label='Actual Checksum'>$actHash</td><td data-label='Status' class='$volStatusClass'>$volStatus</td></tr>")
            }
            $sectionData.VolumesTableRows = $sbManifest.ToString(); $sectionData.ShowVolumesTable = $true
        } elseif ($hasVolumeChecksums) {
            $sbManifest = [System.Text.StringBuilder]::new()
            $ReportData.VolumeChecksums | ForEach-Object {
                $volName=ConvertTo-SafeHtml $_.VolumeName; $expHash=ConvertTo-SafeHtml $_.Checksum
                $null = $sbManifest.Append("<tr><td data-label='Volume Filename'>$volName</td><td data-label='Expected Checksum'>$expHash</td><td data-label='Actual Checksum'>N/A (Not Verified)</td><td data-label='Status' class='status-DEFAULT'>Not Verified</td></tr>")
            }
            $sectionData.VolumesTableRows = $sbManifest.ToString(); $sectionData.ShowVolumesTable = $true
            if ([string]::IsNullOrWhiteSpace($sectionData.OverallStatus) -or $sectionData.OverallStatus -eq "N/A") {
                $sectionData.OverallStatus = "Manifest Generated (Verification Not Performed)"; $sectionData.OverallStatusClass = "status-INFO"
            }
        }
        if ($hasRawDetails) {
            $sectionData.RawDetails = ConvertTo-SafeHtml $ReportData.ManifestVerificationDetails; $sectionData.ShowRawDetails = $true
        }
    }
    return $sectionData
}

function Get-ConfigTableRowsHtml {
    param([hashtable]$JobConfiguration)
    if ($null -eq $JobConfiguration) { return "" }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($key in $JobConfiguration.Keys | Sort-Object) {
        $value = $JobConfiguration[$key]
        $displayValue = if ($value -is [array]) { ($value | ForEach-Object { ConvertTo-SafeHtml ([string]$_) }) -join ", " } else { ConvertTo-SafeHtml ([string]$value) }
        $null=$sb.Append("<tr><td data-label='Setting'>$(ConvertTo-SafeHtml $key)</td><td data-label='Value'>$($displayValue)</td></tr>")
    }
    return $sb.ToString()
}

function Get-HooksTableRowsHtml {
    param([array]$HookScripts)
    if ($null -eq $HookScripts -or $HookScripts.Count -eq 0) { return "" }
    $sb = [System.Text.StringBuilder]::new()
    $HookScripts | ForEach-Object {
        $sSV=([string]$_.Status -replace ' ','_') -replace '[\(\):\/]','_' -replace '\+','plus'; $sC="status-$(ConvertTo-SafeHtml $sSV)"
        $hOH=if([string]::IsNullOrWhiteSpace($_.Output)){"<em><No output></em>"}else{"<div class='pre-container'><button type='button' class='copy-hook-output-btn' title='Copy Hook Output' aria-label='Copy hook output to clipboard'>Copy</button><pre>$(ConvertTo-SafeHtml $_.Output)</pre></div>"}
        $null=$sb.Append("<tr><td data-label='Hook Type'>$(ConvertTo-SafeHtml $_.Name)</td><td data-label='Path'>$(ConvertTo-SafeHtml $_.Path)</td><td data-label='Status' class='$sC'>$(ConvertTo-SafeHtml $_.Status)</td><td data-label='Output/Error'>$hOH</td></tr>")
    }
    return $sb.ToString()
}

function Get-LogEntriesSectionHtml {
    param([array]$LogEntries)
    $sectionData = @{ FilterControlsHtml = ""; LogEntriesListHtml = "" }
    if ($null -eq $LogEntries -or $LogEntries.Count -eq 0) { return $sectionData }

    $sbFilters = [System.Text.StringBuilder]::new("<div class='log-level-filters-container'><strong>Filter by Level:</strong>")
    ($LogEntries.Level | Select-Object -Unique | Sort-Object | Where-Object {-not [string]::IsNullOrWhiteSpace($_)}) | ForEach-Object { 
        $sL = ConvertTo-SafeHtml $_
        $null=$sbFilters.Append("<label><input type='checkbox' class='log-level-filter' value='$sL' checked> $sL</label>") 
    }
    $null=$sbFilters.Append("<div class='log-level-toggle-buttons'><button type='button' id='logFilterSelectAll'>Select All</button><button type='button' id='logFilterDeselectAll'>Deselect All</button><button type='button' id='copyFullLogBtn'>Copy Full Log</button></div></div>")
    $sectionData.FilterControlsHtml = $sbFilters.ToString()

    $sbLogs = [System.Text.StringBuilder]::new()
    $LogEntries | ForEach-Object { 
        $eC="log-$(ConvertTo-SafeHtml $_.Level)"
        $null=$sbLogs.Append("<div class='log-entry $eC' data-level='$(ConvertTo-SafeHtml $_.Level)'><strong>$(ConvertTo-SafeHtml $_.Timestamp) [$(ConvertTo-SafeHtml $_.Level)]</strong> <span>$(ConvertTo-SafeHtml $_.Message)</span></div>")
    }
    $sectionData.LogEntriesListHtml = $sbLogs.ToString()

    return $sectionData
}

#endregion

Export-ModuleMember -Function Get-SummaryTableRowsHtml, Get-TargetTransfersTableRowsHtml, Get-ManifestDetailsSectionHtml, Get-ConfigTableRowsHtml, Get-HooksTableRowsHtml, Get-LogEntriesSectionHtml
