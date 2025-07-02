# Modules\Operations\LocalArchiveProcessor\PostArchiveProcessor.psm1
<#
.SYNOPSIS
    A sub-module for LocalArchiveProcessor.psm1. Handles all post-archive-creation tasks.
.DESCRIPTION
    This module provides the 'Invoke-PoShBackupPostArchiveProcessing' function. It is responsible
    for orchestrating all tasks that occur after the physical archive file(s) have been created.
    This includes:
    - Generating a manifest of the archive's contents.
    - Generating a checksum file for the archive or a checksum manifest for multi-volume archives.
    - Testing the integrity of the newly created archive.
    - Verifying checksums against the generated manifest.
    - Executing the post-local-archive hook script.
    - Pinning the new archive if configured.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.1 # Suppressed PSSA false positive for $testResult.
    DateCreated:    26-Jun-2025
    LastModified:   02-Jul-2025
    Purpose:        To isolate post-archive-creation processing steps.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Operations\LocalArchiveProcessor
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "PostArchiveProcessor.psm1 FATAL: Could not import a dependent module. Error: $($_.Exception.Message)"
    throw
}
#endregion

<# PSScriptAnalyzer Suppress PSUseDeclaredVarsMoreThanAssignments - Justification: The variable '$testResult' is incorrectly flagged as unused. It is used on subsequent lines to access its properties (e.g., '$testResult.ExitCode', '$testResult.AttemptsMade'). This is a PSSA false positive. #>
function Invoke-PoShBackupPostArchiveProcessing {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $true)]
        [string]$InitialStatus,
        [Parameter(Mandatory = $true)]
        [string]$FinalArchivePathForReturn, # Path to first volume or single file
        [Parameter(Mandatory = $true)]
        [string]$FinalArchivePathFor7ZipCommand, # Path used as base name for manifests
        [Parameter(Mandatory = $true)]
        [string]$ArchiveFileNameOnly, # Filename of the final .exe or .7z
        [Parameter(Mandatory = $true)]
        [ref]$JobReportDataRef,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet,
        [Parameter(Mandatory = $true)]
        [string]$ActualConfigFile,
        [Parameter(Mandatory = $false)]
        [string]$ArchivePasswordPlainText
    )

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    & $LocalWriteLog -Message "PostArchiveProcessor: Initialising post-archive processing for job '$($EffectiveJobConfig.BaseFileName)'." -Level "DEBUG"

    $currentStatus = $InitialStatus
    $reportData = $JobReportDataRef.Value
    $sevenZipPathGlobal = $EffectiveJobConfig.GlobalConfigRef.SevenZipPath

    if ($currentStatus -eq "FAILURE") {
        & $LocalWriteLog -Message "PostArchiveProcessor: Skipping all post-processing steps due to initial FAILURE status." -Level "WARNING"
        return $currentStatus
    }

    # --- Generate a manifest of the archive's *contents* if configured (for verification) ---
    if ($EffectiveJobConfig.GenerateContentsManifest) {
        $archiveForManifestGeneration = $FinalArchivePathFor7ZipCommand
        & $LocalWriteLog -Message "`n[INFO] PostArchiveProcessor: Generating manifest of archive contents for '$archiveForManifestGeneration'..." -Level "INFO"

        $baseManifestName = Split-Path -Path $archiveForManifestGeneration -Leaf
        $manifestDir = Split-Path -Path $archiveForManifestGeneration -Parent
        $contentsManifestFileName = Join-Path -Path $manifestDir -ChildPath "$($baseManifestName).contents.manifest"

        $reportData.ContentsManifestStatus = "Not Generated"
        if ($IsSimulateMode.IsPresent) {
            & $LocalWriteLog -Message "SIMULATE: A detailed manifest of all files within the archive would be generated and saved to '$contentsManifestFileName'." -Level "SIMULATE"
            $reportData.ContentsManifestStatus = "Simulated"
        }
        elseif (Test-Path -LiteralPath $FinalArchivePathForReturn -PathType Leaf) {
            try {
                Import-Module -Name (Join-Path -Path $PSScriptRoot "..\..\Managers\7ZipManager.psm1") -Force -ErrorAction Stop
                $archiveContents = Get-7ZipArchiveListing -SevenZipPathExe $sevenZipPathGlobal -ArchivePath $FinalArchivePathForReturn -PlainTextPassword $ArchivePasswordPlainText -Logger $Logger
                if ($null -ne $archiveContents) {
                    $manifestContent = $archiveContents | ForEach-Object { "$($_.CRC),$($_.Size),$($_.Modified),$($_.Attributes),`"$($_.Path)`"" }
                    [System.IO.File]::WriteAllLines($contentsManifestFileName, @("# PoSh-Backup Contents Manifest. Fields: CRC,Size,Modified,Attributes,Path") + $manifestContent, [System.Text.Encoding]::UTF8)
                    & $LocalWriteLog -Message "  - Contents manifest created: '$contentsManifestFileName'" -Level "SUCCESS"
                    $reportData.ContentsManifestStatus = "Generated"
                } else { throw "Get-7ZipArchiveListing returned null." }
            } catch {
                & $LocalWriteLog -Message "[ERROR] Failed to list archive contents or write manifest file '$contentsManifestFileName'. Error: $($_.Exception.Message)" -Level "ERROR"
                $reportData.ContentsManifestStatus = "Error"
            }
        } else { & $LocalWriteLog -Message "[WARNING] Archive not found at '$FinalArchivePathForReturn'. Skipping contents manifest generation." -Level "WARNING"; $reportData.ContentsManifestStatus = "Skipped" }
    }

    # --- Generate checksum of the archive file(s) themselves ---
    if (-not [string]::IsNullOrWhiteSpace($EffectiveJobConfig.SplitVolumeSize) -and $EffectiveJobConfig.GenerateSplitArchiveManifest) {
        & $LocalWriteLog -Message "`n[INFO] PostArchiveProcessor: Generating checksum manifest for split archive '$FinalArchivePathFor7ZipCommand'..." -Level "INFO"
        $reportData.ArchiveChecksum = "Manifest Generation Attempted"
        $manifestFileName = "$($FinalArchivePathFor7ZipCommand).manifest.$($EffectiveJobConfig.ChecksumAlgorithm.ToLowerInvariant())"
        $manifestFilePath = Join-Path -Path (Split-Path -Path $FinalArchivePathFor7ZipCommand -Parent) -ChildPath $manifestFileName
        $reportData.ArchiveChecksumFile = $manifestFilePath
        $volumeChecksumsForReport = [System.Collections.Generic.List[object]]::new()

        if ($IsSimulateMode.IsPresent) {
            & $LocalWriteLog -Message "SIMULATE: Would find all volumes for '$FinalArchivePathFor7ZipCommand', calculate their checksums, and write to manifest '$manifestFilePath'." -Level "SIMULATE"
            $volumeChecksumsForReport.Add(@{VolumeName = "$($FinalArchivePathFor7ZipCommand).001"; Checksum = "SIMULATED_CHECKSUM_VOL1" })
            $reportData.ArchiveChecksum = "Manifest Simulated"
        }
        else {
            $volumeFiles = Get-ChildItem -Path (Split-Path -Path $FinalArchivePathFor7ZipCommand -Parent) -Filter ($FinalArchivePathFor7ZipCommand + ".*") |
            Where-Object { $_.Name -match ([regex]::Escape($FinalArchivePathFor7ZipCommand) + "\.\d{3,}") } |
            Sort-Object Name
            if ($volumeFiles.Count -gt 0) {
                $manifestContentBuilder = [System.Text.StringBuilder]::new()
                $allVolumeHashesSuccessful = $true
                foreach ($volumeFile in $volumeFiles) {
                    $volHash = Get-PoshBackupFileHash -FilePath $volumeFile.FullName -Algorithm $EffectiveJobConfig.ChecksumAlgorithm -Logger $Logger
                    if ($null -ne $volHash) {
                        $null = $manifestContentBuilder.AppendLine("$($volHash.ToUpperInvariant())  $($volumeFile.Name)")
                        $volumeChecksumsForReport.Add(@{VolumeName = $volumeFile.Name; Checksum = $volHash.ToUpperInvariant() })
                    }
                    else {
                        & $LocalWriteLog -Message "[ERROR] Failed to generate checksum for volume '$($volumeFile.FullName)'. Manifest will be incomplete." -Level "ERROR"
                        $null = $manifestContentBuilder.AppendLine("ERROR_GENERATING_CHECKSUM  $($volumeFile.Name)")
                        $volumeChecksumsForReport.Add(@{VolumeName = $volumeFile.Name; Checksum = "Error" })
                        $allVolumeHashesSuccessful = $false
                    }
                }
                try {
                    [System.IO.File]::WriteAllText($manifestFilePath, $manifestContentBuilder.ToString(), [System.Text.Encoding]::UTF8)
                    & $LocalWriteLog -Message "  - Checksum manifest file created: '$manifestFilePath'" -Level "SUCCESS"
                    $reportData.ArchiveChecksum = if ($allVolumeHashesSuccessful) { "Manifest Generated Successfully" } else { "Manifest Generated (With Errors)" }
                }
                catch {
                    & $LocalWriteLog -Message "[ERROR] Failed to write checksum manifest file '$manifestFilePath'. Error: $($_.Exception.Message)" -Level "ERROR"
                    $reportData.ArchiveChecksum = "Error (Failed to write manifest file)"
                    if ($currentStatus -ne "FAILURE") { $currentStatus = "WARNINGS" }
                }
            }
            else {
                & $LocalWriteLog -Message "[WARNING] No volume files found for '$FinalArchivePathFor7ZipCommand' after archive creation. Cannot generate manifest." -Level "WARNING"
                $reportData.ArchiveChecksum = "Skipped (No volumes found)"
            }
        }
        $reportData.VolumeChecksums = $volumeChecksumsForReport
    }
    elseif ($EffectiveJobConfig.GenerateArchiveChecksum) {
        & $LocalWriteLog -Message "`n[INFO] PostArchiveProcessor: Generating checksum for archive '$FinalArchivePathForReturn'..." -Level "INFO"
        $checksumFileExtension = $EffectiveJobConfig.ChecksumAlgorithm.ToLowerInvariant()
        $archiveNameForInChecksumFile = Split-Path -Path $FinalArchivePathForReturn -Leaf
        if ($IsSimulateMode.IsPresent) {
            $checksumFileNameWithExt = $ArchiveFileNameOnly + ".$checksumFileExtension"
            $checksumFileDir = Split-Path -Path $FinalArchivePathForReturn -Parent
            $checksumFilePath = Join-Path -Path $checksumFileDir -ChildPath $checksumFileNameWithExt
            $reportData.ArchiveChecksumFile = $checksumFilePath
            & $LocalWriteLog -Message "SIMULATE: Would generate a $($EffectiveJobConfig.ChecksumAlgorithm) checksum for the archive '$FinalArchivePathForReturn' and save it to '$checksumFilePath'." -Level "SIMULATE"
            $reportData.ArchiveChecksum = "SIMULATED_CHECKSUM_VALUE"
        }
        else {
            $archiveFileItem = Get-Item -LiteralPath $FinalArchivePathForReturn -ErrorAction SilentlyContinue
            if ($null -ne $archiveFileItem -and $archiveFileItem.Exists) {
                $checksumFilePath = "$($archiveFileItem.FullName).$checksumFileExtension"
                $reportData.ArchiveChecksumFile = $checksumFilePath
                $generatedHash = Get-PoshBackupFileHash -FilePath $FinalArchivePathForReturn -Algorithm $EffectiveJobConfig.ChecksumAlgorithm -Logger $Logger
                if ($null -ne $generatedHash) {
                    $reportData.ArchiveChecksum = $generatedHash
                    try {
                        [System.IO.File]::WriteAllText($checksumFilePath, "$($generatedHash.ToUpperInvariant())  $($archiveNameForInChecksumFile)", [System.Text.Encoding]::UTF8)
                        & $LocalWriteLog -Message "  - Checksum file created: '$checksumFilePath' with content: '$($generatedHash.ToUpperInvariant())  $($archiveNameForInChecksumFile)'" -Level "SUCCESS"
                    }
                    catch {
                        & $LocalWriteLog -Message "[ERROR] Failed to write checksum file '$checksumFilePath'. Error: $($_.Exception.Message)" -Level "ERROR"
                        $reportData.ArchiveChecksum = "Error (Failed to write file)"
                        if ($currentStatus -ne "FAILURE") { $currentStatus = "WARNINGS" }
                    }
                }
                else {
                    & $LocalWriteLog -Message "[ERROR] Checksum generation failed for '$FinalArchivePathForReturn'." -Level "ERROR"
                    $reportData.ArchiveChecksum = "Error (Generation failed)"
                    if ($currentStatus -ne "FAILURE") { $currentStatus = "WARNINGS" }
                }
            }
            else {
                & $LocalWriteLog -Message "[WARNING] Archive file '$FinalArchivePathForReturn' not found. Skipping checksum generation." -Level "WARNING"
                $reportData.ArchiveChecksum = "Skipped (Archive not found)"
            }
        }
    }

    # --- Archive Integrity Testing ---
    $shouldTestArchiveNow = $EffectiveJobConfig.JobTestArchiveAfterCreation -or $EffectiveJobConfig.VerifyLocalArchiveBeforeTransfer
    $reportData.ArchiveTested = $shouldTestArchiveNow
    if ($shouldTestArchiveNow) {
        if ([string]::IsNullOrWhiteSpace($sevenZipPathGlobal) -or -not (Test-Path -LiteralPath $sevenZipPathGlobal -PathType Leaf)) {
            $errorMessage = "Archive testing is enabled for job '$($EffectiveJobConfig.BaseFileName)', but the 7-Zip executable was not found."
            $adviceMessage = "ADVICE: Please ensure 7-Zip is installed and the 'SevenZipPath' is correctly set in your configuration."
            & $LocalWriteLog -Message "[ERROR] $errorMessage" -Level "ERROR"
            & $LocalWriteLog -Message $adviceMessage -Level "ADVICE"
            $reportData.ArchiveTestResult = "FAILED (7-Zip Not Found)"
            if ($EffectiveJobConfig.VerifyLocalArchiveBeforeTransfer) { $currentStatus = "FAILURE" }
            elseif ($currentStatus -ne "FAILURE") { $currentStatus = "WARNINGS" }
        }
        elseif ($IsSimulateMode.IsPresent) {
            & $LocalWriteLog -Message "SIMULATE: Would test the integrity of the newly created archive '$FinalArchivePathForReturn'." -Level "SIMULATE"
            $reportData.ArchiveTestResult = "Not Performed (Simulation Mode)"
            $reportData.ArchiveChecksumVerificationStatus = "Skipped (Simulation Mode)"
        }
        elseif (Test-Path -LiteralPath $FinalArchivePathForReturn -PathType Leaf) {
            try {
                Import-Module -Name (Join-Path -Path $PSScriptRoot "..\..\Managers\7ZipManager.psm1") -Force -ErrorAction Stop
                $testArchiveParams = @{
                    SevenZipPathExe           = $sevenZipPathGlobal
                    ArchivePath               = $FinalArchivePathForReturn
                    PlainTextPassword         = $ArchivePasswordPlainText
                    ProcessPriority           = $EffectiveJobConfig.JobSevenZipProcessPriority
                    SevenZipCpuAffinityString = $EffectiveJobConfig.JobSevenZipCpuAffinity
                    HideOutput                = $EffectiveJobConfig.HideOutput
                    VerifyCRC                 = $EffectiveJobConfig.VerifyArchiveChecksumOnTest
                    MaxRetries                = $EffectiveJobConfig.JobMaxRetryAttempts
                    RetryDelaySeconds         = $EffectiveJobConfig.JobRetryDelaySeconds
                    EnableRetries             = $EffectiveJobConfig.JobEnableRetries
                    TreatWarningsAsSuccess    = $EffectiveJobConfig.TreatSevenZipWarningsAsSuccess
                    Logger                    = $Logger
                    PSCmdlet                  = $PSCmdlet
                }
                $testResult = Test-7ZipArchive @testArchiveParams
                $reportData.TestRetryAttemptsMade = $testResult.AttemptsMade

                if ($testResult.ExitCode -eq 0) { $reportData.ArchiveTestResult = "PASSED (7z t)" }
                elseif ($testResult.ExitCode -eq 1 -and $EffectiveJobConfig.TreatSevenZipWarningsAsSuccess) { $reportData.ArchiveTestResult = "PASSED (7z t Warning, treated as success)" }
                else {
                    $reportData.ArchiveTestResult = "FAILED (7z t Exit Code: $($testResult.ExitCode))"
                    if ($EffectiveJobConfig.VerifyLocalArchiveBeforeTransfer) { $currentStatus = "FAILURE" }
                    elseif ($currentStatus -ne "FAILURE") { $currentStatus = "WARNINGS" }
                }
            }
            catch {
                $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Managers\7ZipManager.psm1' and its sub-modules exist and are not corrupted."
                & $LocalWriteLog -Message "[ERROR] PostArchiveProcessor: Could not load or execute the 7ZipManager. Archive testing skipped. Error: $($_.Exception.Message)" -Level "ERROR"
                & $LocalWriteLog -Message $advice -Level "ADVICE"
                $reportData.ArchiveTestResult = "FAILED (Module Load Error)"
                if ($currentStatus -ne "FAILURE") { $currentStatus = "WARNINGS" }
            }
        }
        else {
            $reportData.ArchiveTestResult = "Not Performed (Archive Missing)"
            $reportData.ArchiveChecksumVerificationStatus = "Skipped (Archive test not performed)"
        }
    }

    # --- Post Local Archive Hook ---
    if (-not [string]::IsNullOrWhiteSpace($EffectiveJobConfig.PostLocalArchiveScriptPath)) {
        & $LocalWriteLog -Message "`n[INFO] PostArchiveProcessor: Executing Post-Local-Archive Hook..." -Level "INFO"
        try {
            Import-Module -Name (Join-Path -Path $PSScriptRoot "..\..\Managers\HookManager.psm1") -Force -ErrorAction Stop
            $hookArgsForLocalArchive = @{
                JobName = $EffectiveJobConfig.BaseFileName; Status = $currentStatus
                ArchivePath = $FinalArchivePathForReturn; ConfigFile = $ActualConfigFile
                SimulateMode = $IsSimulateMode.IsPresent
            }
            if ($reportData.ContainsKey('ArchiveChecksum') -and $reportData.ArchiveChecksum -notlike "N/A*" -and $reportData.ArchiveChecksum -notlike "Error*") {
                $hookArgsForLocalArchive.ArchiveChecksum = $reportData.ArchiveChecksum
                $hookArgsForLocalArchive.ArchiveChecksumAlgorithm = $reportData.ArchiveChecksumAlgorithm
                $hookArgsForLocalArchive.ArchiveChecksumFile = $reportData.ArchiveChecksumFile
            }
            Invoke-PoShBackupHook -ScriptPath $EffectiveJobConfig.PostLocalArchiveScriptPath `
                -HookType "PostLocalArchive" `
                -HookParameters $hookArgsForLocalArchive `
                -IsSimulateMode:$IsSimulateMode `
                -Logger $Logger
        }
        catch {
            $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Managers\HookManager.psm1' exists and is not corrupted."
            & $LocalWriteLog -Message "[ERROR] PostArchiveProcessor: Could not load or execute the HookManager. Post-local-archive hook skipped. Error: $($_.Exception.Message)" -Level "ERROR"
            if ($currentStatus -ne "FAILURE") { $currentStatus = "WARNINGS" }
        }
    }

    # --- Pinning Logic ---
    if ($EffectiveJobConfig.PinOnCreation) {
        & $LocalWriteLog -Message "`n[INFO] PinOnCreation is enabled for this job. Pinning newly created archive..." -Level "INFO"
        $pathToPin = $FinalArchivePathFor7ZipCommand
        if ($IsSimulateMode.IsPresent) {
            & $LocalWriteLog -Message "SIMULATE: Would pin the new backup by creating a marker file for '$pathToPin'." -Level "SIMULATE"
            $reportData.ArchivePinned = "Simulated"
        }
        elseif (Test-Path -LiteralPath $FinalArchivePathForReturn -PathType Leaf) {
            if ($PSCmdlet.ShouldProcess($pathToPin, "Pin Archive")) {
                try {
                    Import-Module -Name (Join-Path -Path $PSScriptRoot "..\..\Managers\PinManager.psm1") -Force -ErrorAction Stop
                    Add-PoShBackupPin -Path $pathToPin -Reason $EffectiveJobConfig.PinReason -Logger $Logger
                    $reportData.ArchivePinned = "Yes"
                }
                catch {
                    $pinError = "Failed to load PinManager or pin archive '$pathToPin'. Error: $($_.Exception.Message)"
                    & $LocalWriteLog -Message "[ERROR] $pinError" -Level "ERROR"
                    $reportData.ArchivePinned = "Failed"; if ($currentStatus -ne "FAILURE") { $currentStatus = "WARNINGS" }
                }
            }
            else {
                & $LocalWriteLog -Message "[INFO] Pinning of archive '$pathToPin' skipped by user (ShouldProcess)." -Level "INFO"
                $reportData.ArchivePinned = "No (Skipped by user)"
            }
        }
        else {
            & $LocalWriteLog -Message "[WARNING] Cannot pin archive because the primary archive file was not found at '$FinalArchivePathForReturn'." -Level "WARNING"
            $reportData.ArchivePinned = "Skipped (Archive Not Found)"
        }
    }

    & $LocalWriteLog -Message "PostArchiveProcessor: Post-archive processing completed with status '$currentStatus'." -Level "DEBUG"
    return $currentStatus
}

Export-ModuleMember -Function Invoke-PoShBackupPostArchiveProcessing
