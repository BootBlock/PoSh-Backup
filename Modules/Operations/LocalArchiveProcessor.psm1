# Modules\Operations\LocalArchiveProcessor.psm1
<#
.SYNOPSIS
    Handles local backup archive creation, checksum generation, and integrity verification.
    Supports creation of standard archives and Self-Extracting Archives (SFX).
    Now also supports mandatory local archive verification before remote transfers if configured.
.DESCRIPTION
    This module is a sub-component of the main Operations module for PoSh-Backup.
    It encapsulates the specific steps involved in:
    - Checking destination free space for the local archive.
    - Generating the 7-Zip command arguments (including for SFX if configured).
    - Executing 7-Zip to create the local archive (which might be an .exe if SFX is enabled),
      now supporting CPU affinity.
    - Optionally generating a checksum file for the created archive.
    - Optionally testing the integrity of the local archive (including checksum verification if enabled).
      This test is now also triggered if the 'VerifyLocalArchiveBeforeTransfer' setting is true,
      and its outcome will influence whether remote transfers proceed.
    - Updating the job report data with outcomes of these local operations, including SFX settings
      and whether pre-transfer verification was active.

    It is designed to be called by the main Invoke-PoShBackupJob function in Operations.psm1.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.10    # Gemini sucks
    DateCreated:    24-May-2025
    LastModified:   28-May-2025
    Purpose:        To modularise local archive processing logic from the main Operations module.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Utils.psm1 and 7ZipManager.psm1 from the parent 'Modules' directory.
#>

# Explicitly import dependent modules from the parent 'Modules' directory.
# $PSScriptRoot here is Modules\Operations.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "..\Managers\7ZipManager.psm1") -Force -ErrorAction Stop # UPDATED PATH
} catch {
    Write-Error "LocalArchiveProcessor.psm1 FATAL: Could not import dependent modules (Utils.psm1 or Managers\7ZipManager.psm1). Error: $($_.Exception.Message)" # Consider updating error message
    throw
}

function Invoke-LocalArchiveOperation {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $true)]
        [string]$CurrentJobSourcePathFor7Zip,
        [Parameter(Mandatory = $true)]
        [ref]$JobReportDataRef,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger, 
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet,
        [Parameter(Mandatory = $true)]
        [hashtable]$GlobalConfig,
        [Parameter(Mandatory = $false)] 
        [string]$ArchivePasswordPlainText = $null,
        [Parameter(Mandatory = $false)]
        [string]$SevenZipCpuAffinityString = $null
    )

    $scriptBlockLogger = $Logger 

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $scriptBlockLogger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $scriptBlockLogger -Message $Message -Level $Level
        }
    }
    
    & $LocalWriteLog -Message "LocalArchiveProcessor/Invoke-LocalArchiveOperation: Logger active. CPU Affinity String: '$SevenZipCpuAffinityString'" -Level "DEBUG"

    $currentLocalArchiveStatus = "SUCCESS" 
    $finalArchivePathForReturn = $null
    $reportData = $JobReportDataRef.Value
    $archiveFileNameOnly = $null 

    # Add VerifyLocalArchiveBeforeTransfer to report data early
    $reportData.VerifyLocalArchiveBeforeTransfer = $EffectiveJobConfig.VerifyLocalArchiveBeforeTransfer

    try {
        $destinationDirTerm = if ($EffectiveJobConfig.ResolvedTargetInstances.Count -eq 0) { "Final Destination Directory" } else { "Local Staging Directory" }

        & $LocalWriteLog -Message "`n[INFO] LocalArchiveProcessor: Performing Pre-Archive Creation Operations..." -Level "INFO"
        & $LocalWriteLog -Message "   - Using source(s) for 7-Zip: $(if ($CurrentJobSourcePathFor7Zip -is [array]) {($CurrentJobSourcePathFor7Zip | Where-Object {$_}) -join '; '} else {$CurrentJobSourcePathFor7Zip})" -Level "DEBUG"

        if (-not (Test-DestinationFreeSpace -DestDir $EffectiveJobConfig.DestinationDir -MinRequiredGB $EffectiveJobConfig.JobMinimumRequiredFreeSpaceGB -ExitOnLow $EffectiveJobConfig.JobExitOnLowSpace -IsSimulateMode:$IsSimulateMode -Logger $scriptBlockLogger)) {
            throw "Low disk space on '${destinationDirTerm}' and configured to halt job '$($EffectiveJobConfig.JobName)'."
        }

        $DateString = Get-Date -Format $EffectiveJobConfig.JobArchiveDateFormat
        $archiveFileNameOnly = "$($EffectiveJobConfig.BaseFileName) [$DateString]$($EffectiveJobConfig.JobArchiveExtension)"
        $finalArchivePathForReturn = Join-Path -Path $EffectiveJobConfig.DestinationDir -ChildPath $archiveFileNameOnly
        $reportData.FinalArchivePath = $finalArchivePathForReturn
        & $LocalWriteLog -Message "`n[INFO] LocalArchiveProcessor: Target Archive in ${destinationDirTerm}: $finalArchivePathForReturn" -Level "INFO"
        if ($EffectiveJobConfig.CreateSFX) {
            & $LocalWriteLog -Message "   - Note: This will be a Self-Extracting Archive (SFX) using module type: $($EffectiveJobConfig.SFXModule)." -Level "INFO"
        }
        $reportData.SFXModule = $EffectiveJobConfig.SFXModule

        $sevenZipArgsArray = Get-PoShBackup7ZipArgument -EffectiveConfig $EffectiveJobConfig `
            -FinalArchivePath $finalArchivePathForReturn `
            -CurrentJobSourcePathFor7Zip $CurrentJobSourcePathFor7Zip `
            -Logger $scriptBlockLogger 

        $sevenZipPathGlobal = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'SevenZipPath'
        $zipOpParams = @{
            SevenZipPathExe           = $sevenZipPathGlobal
            SevenZipArguments         = $sevenZipArgsArray
            ProcessPriority           = $EffectiveJobConfig.JobSevenZipProcessPriority
            SevenZipCpuAffinityString = $SevenZipCpuAffinityString
            PlainTextPassword         = $ArchivePasswordPlainText 
            HideOutput                = $EffectiveJobConfig.HideSevenZipOutput
            MaxRetries                = $EffectiveJobConfig.JobMaxRetryAttempts
            RetryDelaySeconds         = $EffectiveJobConfig.JobRetryDelaySeconds
            EnableRetries             = $EffectiveJobConfig.JobEnableRetries
            TreatWarningsAsSuccess    = $EffectiveJobConfig.TreatSevenZipWarningsAsSuccess
            IsSimulateMode            = $IsSimulateMode.IsPresent
            Logger                    = $scriptBlockLogger 
        }
        if ((Get-Command Invoke-7ZipOperation).Parameters.ContainsKey('PSCmdlet')) {
            $zipOpParams.PSCmdlet = $PSCmdlet
        }

        $sevenZipResult = Invoke-7ZipOperation @zipOpParams

        $reportData.SevenZipExitCode = $sevenZipResult.ExitCode
        $reportData.CompressionTime = if ($null -ne $sevenZipResult.ElapsedTime) { $sevenZipResult.ElapsedTime.ToString() } else { "N/A" }
        $reportData.RetryAttemptsMade = $sevenZipResult.AttemptsMade

        if (-not $IsSimulateMode.IsPresent -and (Test-Path -LiteralPath $finalArchivePathForReturn -PathType Leaf)) {
            $reportData.ArchiveSizeBytes = (Get-Item -LiteralPath $finalArchivePathForReturn).Length
            $reportData.ArchiveSizeFormatted = Get-ArchiveSizeFormatted -PathToArchive $finalArchivePathForReturn -Logger $scriptBlockLogger
        } elseif ($IsSimulateMode.IsPresent) {
            $reportData.ArchiveSizeBytes = 0
            $reportData.ArchiveSizeFormatted = "0 Bytes (Simulated)"
        } else {
            $reportData.ArchiveSizeBytes = 0
            $reportData.ArchiveSizeFormatted = "N/A (Archive not found after creation)"
        }

        if ($sevenZipResult.ExitCode -ne 0) {
            if ($sevenZipResult.ExitCode -eq 1 -and $EffectiveJobConfig.TreatSevenZipWarningsAsSuccess) {
                & $LocalWriteLog -Message "[INFO] LocalArchiveProcessor: 7-Zip returned warning (Exit Code 1) but 'TreatSevenZipWarningsAsSuccess' is true. Local archive status remains SUCCESS." -Level "INFO"
            } else {
                $currentLocalArchiveStatus = if ($sevenZipResult.ExitCode -eq 1) { "WARNINGS" } else { "FAILURE" }
                & $LocalWriteLog -Message "[$(if($currentLocalArchiveStatus -eq 'FAILURE') {'ERROR'} else {'WARNING'})] LocalArchiveProcessor: 7-Zip operation for local archive creation resulted in Exit Code $($sevenZipResult.ExitCode). This impacts local archive status." -Level $currentLocalArchiveStatus
            }
        }

        if ($EffectiveJobConfig.GenerateArchiveChecksum -and ($currentLocalArchiveStatus -ne "FAILURE")) {
            & $LocalWriteLog -Message "`n[INFO] LocalArchiveProcessor: Generating checksum for archive '$finalArchivePathForReturn'..." -Level "INFO"
            $reportData.ArchiveChecksumAlgorithm = $EffectiveJobConfig.ChecksumAlgorithm
            $checksumFileExtension = $EffectiveJobConfig.ChecksumAlgorithm.ToLowerInvariant()
            $archiveFileItem = Get-Item -LiteralPath $finalArchivePathForReturn -ErrorAction SilentlyContinue
            $checksumFileNameWithExt = $archiveFileItem.Name + ".$checksumFileExtension"
            $checksumFileDir = $archiveFileItem.DirectoryName
            $checksumFilePath = Join-Path -Path $checksumFileDir -ChildPath $checksumFileNameWithExt
            $reportData.ArchiveChecksumFile = $checksumFilePath

            if ($IsSimulateMode.IsPresent) {
                & $LocalWriteLog -Message "SIMULATE: LocalArchiveProcessor: Would generate $($EffectiveJobConfig.ChecksumAlgorithm) checksum for '$finalArchivePathForReturn' and save to '$checksumFilePath'." -Level "SIMULATE"
                $reportData.ArchiveChecksum = "SIMULATED_CHECKSUM_VALUE"
            } elseif ($null -ne $archiveFileItem -and $archiveFileItem.Exists) {
                $generatedHash = Get-PoshBackupFileHash -FilePath $finalArchivePathForReturn -Algorithm $EffectiveJobConfig.ChecksumAlgorithm -Logger $scriptBlockLogger
                if ($null -ne $generatedHash) {
                    $reportData.ArchiveChecksum = $generatedHash
                    try {
                        if ([string]::IsNullOrWhiteSpace($archiveFileNameOnly)) {
                            throw "ArchiveFileNameOnly was not set before checksum file write."
                        }
                        [System.IO.File]::WriteAllText($checksumFilePath, "$($generatedHash.ToUpperInvariant())  $($archiveFileNameOnly)", [System.Text.Encoding]::UTF8)
                        & $LocalWriteLog -Message "  - Checksum file created: '$checksumFilePath' with content: '$($generatedHash.ToUpperInvariant())  $($archiveFileNameOnly)'" -Level "SUCCESS"
                    } catch {
                        & $LocalWriteLog -Message "[ERROR] LocalArchiveProcessor: Failed to write checksum file '$checksumFilePath'. Error: $($_.Exception.Message)" -Level "ERROR"
                        $reportData.ArchiveChecksum = "Error (Failed to write file)"
                        if ($currentLocalArchiveStatus -ne "FAILURE") { $currentLocalArchiveStatus = "WARNINGS" }
                    }
                } else {
                    & $LocalWriteLog -Message "[ERROR] LocalArchiveProcessor: Checksum generation failed for '$finalArchivePathForReturn'." -Level "ERROR"
                    $reportData.ArchiveChecksum = "Error (Generation failed)"
                    if ($currentLocalArchiveStatus -ne "FAILURE") { $currentLocalArchiveStatus = "WARNINGS" }
                }
            } else {
                & $LocalWriteLog -Message "[WARNING] LocalArchiveProcessor: Archive file '$finalArchivePathForReturn' not found. Skipping checksum generation." -Level "WARNING"
                $reportData.ArchiveChecksum = "Skipped (Archive not found)"
            }
        } elseif ($EffectiveJobConfig.GenerateArchiveChecksum) {
            & $LocalWriteLog -Message "[INFO] LocalArchiveProcessor: Checksum generation skipped due to prior failure in archive creation." -Level "INFO"
            $reportData.ArchiveChecksumAlgorithm = $EffectiveJobConfig.ChecksumAlgorithm
            $reportData.ArchiveChecksum = "Skipped (Prior failure)"
        }

        # Determine if archive testing should occur
        $shouldTestArchiveNow = $EffectiveJobConfig.JobTestArchiveAfterCreation -or $EffectiveJobConfig.VerifyLocalArchiveBeforeTransfer
        $reportData.ArchiveTested = $shouldTestArchiveNow # Update report data based on combined condition

        if ($shouldTestArchiveNow -and ($currentLocalArchiveStatus -ne "FAILURE") -and (-not $IsSimulateMode.IsPresent) -and (Test-Path -LiteralPath $finalArchivePathForReturn -PathType Leaf)) {
            $testArchiveParams = @{
                SevenZipPathExe        = $sevenZipPathGlobal
                ArchivePath            = $finalArchivePathForReturn
                PlainTextPassword      = $ArchivePasswordPlainText
                ProcessPriority        = $EffectiveJobConfig.JobSevenZipProcessPriority
                SevenZipCpuAffinityString = $SevenZipCpuAffinityString
                HideOutput             = $EffectiveJobConfig.HideSevenZipOutput
                MaxRetries             = $EffectiveJobConfig.JobMaxRetryAttempts
                RetryDelaySeconds      = $EffectiveJobConfig.JobRetryDelaySeconds
                EnableRetries          = $EffectiveJobConfig.JobEnableRetries
                TreatWarningsAsSuccess = $EffectiveJobConfig.TreatSevenZipWarningsAsSuccess
                Logger                 = $scriptBlockLogger 
            }
            if ((Get-Command Test-7ZipArchive).Parameters.ContainsKey('PSCmdlet')) {
                $testArchiveParams.PSCmdlet = $PSCmdlet
            }

            $testResult = Test-7ZipArchive @testArchiveParams

            if ($testResult.ExitCode -eq 0) {
                $reportData.ArchiveTestResult = "PASSED (7z t)"
            } elseif ($testResult.ExitCode -eq 1 -and $EffectiveJobConfig.TreatSevenZipWarningsAsSuccess) {
                $reportData.ArchiveTestResult = "PASSED (7z t Warning Exit Code: 1, treated as success)"
            } else {
                $reportData.ArchiveTestResult = "FAILED (7z t Exit Code: $($testResult.ExitCode))"
                # If VerifyLocalArchiveBeforeTransfer is true, a test failure is a job failure.
                # Otherwise, it's a warning (unless already a failure).
                if ($EffectiveJobConfig.VerifyLocalArchiveBeforeTransfer) {
                    $currentLocalArchiveStatus = "FAILURE"
                } elseif ($currentLocalArchiveStatus -ne "FAILURE") {
                    $currentLocalArchiveStatus = "WARNINGS"
                }
            }
            $reportData.TestRetryAttemptsMade = $testResult.AttemptsMade

            # Checksum verification logic (runs if checksum generation was enabled and 7z test passed)
            if ($EffectiveJobConfig.VerifyArchiveChecksumOnTest -and $EffectiveJobConfig.GenerateArchiveChecksum -and ($testResult.ExitCode -eq 0 -or ($testResult.ExitCode -eq 1 -and $EffectiveJobConfig.TreatSevenZipWarningsAsSuccess))) {
                & $LocalWriteLog -Message "`n[INFO] LocalArchiveProcessor: Verifying archive checksum for '$finalArchivePathForReturn'..." -Level "INFO"
                $checksumFileExtensionForVerify = $EffectiveJobConfig.ChecksumAlgorithm.ToLowerInvariant()
                $checksumFilePathForVerify = "$($finalArchivePathForReturn).$checksumFileExtensionForVerify"
                $reportData.ArchiveChecksumVerificationStatus = "Verification Attempted"

                if (Test-Path -LiteralPath $checksumFilePathForVerify -PathType Leaf) {
                    try {
                        $checksumFileContent = Get-Content -LiteralPath $checksumFilePathForVerify -Raw -ErrorAction Stop
                        $storedHashFromFile = ($checksumFileContent -split '\s+')[0].Trim().ToUpperInvariant()
                        $recalculatedHash = Get-PoshBackupFileHash -FilePath $finalArchivePathForReturn -Algorithm $EffectiveJobConfig.ChecksumAlgorithm -Logger $scriptBlockLogger
                        if ($null -ne $recalculatedHash -and $recalculatedHash.Equals($storedHashFromFile, [System.StringComparison]::OrdinalIgnoreCase)) {
                            & $LocalWriteLog -Message "  - Checksum VERIFIED for '$finalArchivePathForReturn'. Stored: $storedHashFromFile, Calculated: $recalculatedHash." -Level "SUCCESS"
                            $reportData.ArchiveChecksumVerificationStatus = "Verified Successfully"
                            $reportData.ArchiveTestResult += " (Checksum OK)"
                        } elseif ($null -ne $recalculatedHash) {
                            & $LocalWriteLog -Message "[ERROR] LocalArchiveProcessor: Checksum MISMATCH for '$finalArchivePathForReturn'. Stored: $storedHashFromFile, Calculated: $recalculatedHash." -Level "ERROR"
                            $reportData.ArchiveChecksumVerificationStatus = "Mismatch (Stored: $storedHashFromFile, Calc: $recalculatedHash)"
                            $reportData.ArchiveTestResult += " (CHECKSUM MISMATCH)"
                            if ($EffectiveJobConfig.VerifyLocalArchiveBeforeTransfer) {
                                $currentLocalArchiveStatus = "FAILURE"
                            } elseif ($currentLocalArchiveStatus -ne "FAILURE") {
                                $currentLocalArchiveStatus = "WARNINGS"
                            }
                        } else {
                            & $LocalWriteLog -Message "[ERROR] LocalArchiveProcessor: Failed to recalculate checksum for verification of '$finalArchivePathForReturn'." -Level "ERROR"
                            $reportData.ArchiveChecksumVerificationStatus = "Error (Recalculation failed)"
                            $reportData.ArchiveTestResult += " (Checksum Recalc Failed)"
                            if ($EffectiveJobConfig.VerifyLocalArchiveBeforeTransfer) {
                                $currentLocalArchiveStatus = "FAILURE"
                            } elseif ($currentLocalArchiveStatus -ne "FAILURE") {
                                $currentLocalArchiveStatus = "WARNINGS"
                            }
                        }
                    } catch {
                        & $LocalWriteLog -Message "[ERROR] LocalArchiveProcessor: Failed to read checksum file '$checksumFilePathForVerify' for verification. Error: $($_.Exception.Message)" -Level "ERROR"
                        $reportData.ArchiveChecksumVerificationStatus = "Error (Checksum file read failed)"
                        $reportData.ArchiveTestResult += " (Checksum File Read Failed)"
                        if ($EffectiveJobConfig.VerifyLocalArchiveBeforeTransfer) {
                            $currentLocalArchiveStatus = "FAILURE"
                        } elseif ($currentLocalArchiveStatus -ne "FAILURE") {
                            $currentLocalArchiveStatus = "WARNINGS"
                        }
                    }
                } else {
                    & $LocalWriteLog -Message "[WARNING] LocalArchiveProcessor: Checksum file '$checksumFilePathForVerify' not found. Cannot verify checksum." -Level "WARNING"
                    $reportData.ArchiveChecksumVerificationStatus = "Skipped (Checksum file not found)"
                    $reportData.ArchiveTestResult += " (Checksum File Missing)"
                }
            } elseif ($EffectiveJobConfig.VerifyArchiveChecksumOnTest -and $EffectiveJobConfig.GenerateArchiveChecksum) {
                & $LocalWriteLog -Message "[INFO] LocalArchiveProcessor: Checksum verification skipped because 7z archive test failed or was treated as failure." -Level "INFO"
                $reportData.ArchiveChecksumVerificationStatus = "Skipped (7z test failed)"
            } elseif ($EffectiveJobConfig.VerifyArchiveChecksumOnTest -and (-not $EffectiveJobConfig.GenerateArchiveChecksum)) {
                & $LocalWriteLog -Message "[INFO] LocalArchiveProcessor: Checksum verification skipped because GenerateArchiveChecksum was false." -Level "INFO"
                $reportData.ArchiveChecksumVerificationStatus = "Skipped (Generation disabled)"
            }

        } elseif ($shouldTestArchiveNow) { # Test was configured but not performed (e.g., simulation, archive missing, prior failure)
            $reportData.ArchiveTestResult = if ($IsSimulateMode.IsPresent) { "Not Performed (Simulation Mode)" } else { "Not Performed (Archive Missing or Prior Compression Error)" }
            $reportData.ArchiveChecksumVerificationStatus = "Skipped (Archive test not performed)"
        } else { # Test was not configured by either flag
            $reportData.ArchiveTestResult = "Not Configured"
            $reportData.ArchiveChecksumVerificationStatus = "Skipped (Archive test not configured)"
        }

    } catch {
        & $LocalWriteLog -Message "[ERROR] LocalArchiveProcessor: Error during local archive operations for job '$($EffectiveJobConfig.JobName)': $($_.Exception.ToString())" -Level ERROR
        $currentLocalArchiveStatus = "FAILURE"
        $reportData.ErrorMessage = if ([string]::IsNullOrWhiteSpace($reportData.ErrorMessage)) { $_.Exception.ToString() } else { "$($reportData.ErrorMessage); $($_.Exception.ToString())" }
    }

    return @{
        Status              = $currentLocalArchiveStatus
        FinalArchivePath    = $finalArchivePathForReturn
        ArchiveFileNameOnly = $archiveFileNameOnly
    }
}

Export-ModuleMember -Function Invoke-LocalArchiveOperation
