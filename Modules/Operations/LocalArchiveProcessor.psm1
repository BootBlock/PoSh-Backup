# Modules\Operations\LocalArchiveProcessor.psm1
<#
.SYNOPSIS
    Handles local backup archive creation, checksum generation (including multi-volume manifests),
    and integrity verification. Supports standard archives, Self-Extracting Archives (SFX),
    automatic pinning on creation, and mandatory local archive verification before remote
    transfers if configured. Now also supports generating a manifest of archive contents.
.DESCRIPTION
    This module is a sub-component of the main Operations module for PoSh-Backup.
    It encapsulates the specific steps involved in:
    - Checking destination free space for the local archive.
    - Generating the 7-Zip command arguments (including for SFX if configured).
    - Executing 7-Zip to create the local archive.
    - Optionally generating a checksum file for single archives or a manifest file for
      multi-volume split archives.
    - Optionally generating a manifest of the archive's contents for verification, including
      CRC checksums, size, and date metadata for each file.
    - Optionally testing the integrity of the local archive.
    - Optionally pinning the newly created archive by creating a '.pinned' marker file if
      the 'PinOnCreation' setting is active for the job.
    - Updating the job report data with outcomes of these local operations.

    It is designed to be called by the main Invoke-PoShBackupJob function in Operations.psm1.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.3.3 # Corrected manifest generation to exclude directories.
    DateCreated:    24-May-2025
    LastModified:   12-Jun-2025
    Purpose:        To modularise local archive processing logic from the main Operations module.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Utils.psm1, 7ZipManager.psm1, and PinManager.psm1.
#>

# Explicitly import dependent modules from the parent 'Modules' directory.
# $PSScriptRoot here is Modules\Operations.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "..\Managers\7ZipManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "..\Managers\PinManager.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "LocalArchiveProcessor.psm1 FATAL: Could not import dependent modules. Error: $($_.Exception.Message)"
    throw
}

function Invoke-LocalArchiveOperation {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $true)]
        [object]$CurrentJobSourcePathFor7Zip, 
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

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        }
        else {
            & $Logger -Message $Message -Level $Level
        }
    }
    
    & $LocalWriteLog -Message "LocalArchiveProcessor/Invoke-LocalArchiveOperation: Logger active. CPU Affinity String: '$SevenZipCpuAffinityString'" -Level "DEBUG"

    $currentLocalArchiveStatus = "SUCCESS" 
    $finalArchivePathForReturn = $null 
    $reportData = $JobReportDataRef.Value
    $archiveFileNameOnly = $null 

    $reportData.VerifyLocalArchiveBeforeTransfer = $EffectiveJobConfig.VerifyLocalArchiveBeforeTransfer
    $reportData.GenerateSplitArchiveManifest = $EffectiveJobConfig.GenerateSplitArchiveManifest
    $reportData.PinOnCreation = $EffectiveJobConfig.PinOnCreation
    $reportData.GenerateContentsManifest = $EffectiveJobConfig.GenerateContentsManifest

    try {
        $destinationDirTerm = if ($EffectiveJobConfig.ResolvedTargetInstances.Count -eq 0) { "Final Destination Directory" } else { "Local Staging Directory" }

        & $LocalWriteLog -Message "`n[INFO] LocalArchiveProcessor: Performing Pre-Archive Creation Operations..." -Level "INFO"
        & $LocalWriteLog -Message "   - Using source(s) for 7-Zip: $(if ($CurrentJobSourcePathFor7Zip -is [array]) {($CurrentJobSourcePathFor7Zip | Where-Object {$_}) -join '; '} else {$CurrentJobSourcePathFor7Zip})" -Level "DEBUG"

        if (-not (Test-DestinationFreeSpace -DestDir $EffectiveJobConfig.DestinationDir -MinRequiredGB $EffectiveJobConfig.JobMinimumRequiredFreeSpaceGB -ExitOnLow $EffectiveJobConfig.JobExitOnLowSpace -IsSimulateMode:$IsSimulateMode -Logger $Logger)) {
            throw "Low disk space on '${destinationDirTerm}' and configured to halt job '$($EffectiveJobConfig.JobName)'."
        }

        $DateString = Get-Date -Format $EffectiveJobConfig.JobArchiveDateFormat
        $archiveFileNameOnly = "$($EffectiveJobConfig.BaseFileName) [$DateString]$($EffectiveJobConfig.JobArchiveExtension)"
        
        $sevenZipTargetName = if (-not [string]::IsNullOrWhiteSpace($EffectiveJobConfig.SplitVolumeSize)) {
            "$($EffectiveJobConfig.BaseFileName) [$DateString]$($EffectiveJobConfig.InternalArchiveExtension)"
        }
        else {
            $archiveFileNameOnly
        }
        $finalArchivePathFor7ZipCommand = Join-Path -Path $EffectiveJobConfig.DestinationDir -ChildPath $sevenZipTargetName
        
        $finalArchivePathForReturn = if (-not [string]::IsNullOrWhiteSpace($EffectiveJobConfig.SplitVolumeSize)) {
            $finalArchivePathFor7ZipCommand + ".001" 
        }
        else {
            $finalArchivePathFor7ZipCommand 
        }

        $reportData.FinalArchivePath = $finalArchivePathForReturn 
        & $LocalWriteLog -Message "`n[INFO] LocalArchiveProcessor: Target Archive in ${destinationDirTerm}: $finalArchivePathFor7ZipCommand (First volume/file expected at: $finalArchivePathForReturn)" -Level "INFO"

        if (-not [string]::IsNullOrWhiteSpace($EffectiveJobConfig.SplitVolumeSize) -and $EffectiveJobConfig.SplitVolumeSize -match "^\d+[kmg]$") {
            $existingVolumePattern = [regex]::Escape($sevenZipTargetName) + ".[0-9][0-9]*"
            & $LocalWriteLog -Message "  - LocalArchiveProcessor: Split archive detected. Checking for existing volumes with pattern '$existingVolumePattern' in '$($EffectiveJobConfig.DestinationDir)'." -Level "DEBUG"
            
            $existingVolumes = Get-ChildItem -Path $EffectiveJobConfig.DestinationDir -Filter ($sevenZipTargetName + ".*") | Where-Object { $_.Name -match $existingVolumePattern }
            
            if ($existingVolumes.Count -gt 0) {
                & $LocalWriteLog -Message "[WARNING] LocalArchiveProcessor: Found $($existingVolumes.Count) existing volume(s) for '$sevenZipTargetName'. Attempting to delete them before creating new split set." -Level "WARNING"
                foreach ($volumeFile in $existingVolumes) {
                    $deleteActionMessage = "Delete existing archive volume part prior to new split archive creation"
                    if ($IsSimulateMode.IsPresent) {
                        & $LocalWriteLog -Message "SIMULATE: Would delete existing volume part '$($volumeFile.FullName)'." -Level "SIMULATE"
                    }
                    else {
                        if ($PSCmdlet.ShouldProcess($volumeFile.FullName, $deleteActionMessage)) {
                            try {
                                Remove-Item -LiteralPath $volumeFile.FullName -Force -ErrorAction Stop
                                & $LocalWriteLog -Message "  - Deleted existing volume part: '$($volumeFile.FullName)'." -Level "INFO"
                            }
                            catch {
                                $errMsg = "Failed to delete existing volume part '$($volumeFile.FullName)'. Error: $($_.Exception.Message). This may cause the new split archive creation to fail."
                                & $LocalWriteLog -Message "[ERROR] LocalArchiveProcessor: $errMsg" -Level "ERROR"
                                if ($currentLocalArchiveStatus -ne "FAILURE") { $currentLocalArchiveStatus = "WARNINGS" }
                                $reportData.ErrorMessage = if ([string]::IsNullOrWhiteSpace($reportData.ErrorMessage)) { $errMsg } else { "$($reportData.ErrorMessage); $errMsg" }
                            }
                        }
                        else {
                            & $LocalWriteLog -Message "[WARNING] LocalArchiveProcessor: Deletion of existing volume part '$($volumeFile.FullName)' skipped by user (ShouldProcess). New archive creation may fail." -Level "WARNING"
                        }
                    }
                }
            }
        }

        if ($EffectiveJobConfig.CreateSFX) {
            & $LocalWriteLog -Message "   - Note: This will be a Self-Extracting Archive (SFX) using module type: $($EffectiveJobConfig.SFXModule)." -Level "INFO"
        }
        $reportData.SFXModule = $EffectiveJobConfig.SFXModule
        
        $sourcePathsFor7ZipArg = if ($CurrentJobSourcePathFor7Zip -is [array]) {
            $CurrentJobSourcePathFor7Zip | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($CurrentJobSourcePathFor7Zip)) {
            @($CurrentJobSourcePathFor7Zip)
        }
        else {
            @() 
        }
        if ($null -eq $sourcePathsFor7ZipArg) { $sourcePathsFor7ZipArg = @() }

        $get7ZipArgsParams = @{
            EffectiveConfig             = $EffectiveJobConfig
            FinalArchivePath            = $finalArchivePathFor7ZipCommand
            CurrentJobSourcePathFor7Zip = $sourcePathsFor7ZipArg
            Logger                      = $Logger
        }
        $sevenZipArgsArray = Get-PoShBackup7ZipArgument @get7ZipArgsParams

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
            Logger                    = $Logger 
        }
        if ((Get-Command Invoke-7ZipOperation).Parameters.ContainsKey('PSCmdlet')) {
            $zipOpParams.PSCmdlet = $PSCmdlet
        }

        Write-ConsoleBanner -NameText "Creating Backup for" -ValueText $($EffectiveJobConfig.BaseFileName) -CenterText -PrependNewLine
        $sevenZipResult = Invoke-7ZipOperation @zipOpParams

        $reportData.SevenZipExitCode = $sevenZipResult.ExitCode
        $reportData.CompressionTime = if ($null -ne $sevenZipResult.ElapsedTime) { $sevenZipResult.ElapsedTime.ToString() } else { "N/A" }
        $reportData.RetryAttemptsMade = $sevenZipResult.AttemptsMade

        if (-not $IsSimulateMode.IsPresent -and (Test-Path -LiteralPath $finalArchivePathForReturn -PathType Leaf)) {
            $reportData.ArchiveSizeBytes = (Get-Item -LiteralPath $finalArchivePathForReturn).Length 
            $reportData.ArchiveSizeFormatted = Get-ArchiveSizeFormatted -PathToArchive $finalArchivePathForReturn -Logger $Logger 
        }
        elseif ($IsSimulateMode.IsPresent) {
            $reportData.ArchiveSizeBytes = 0
            $reportData.ArchiveSizeFormatted = "0 Bytes (Simulated)"
        }
        else {
            $reportData.ArchiveSizeBytes = 0
            $reportData.ArchiveSizeFormatted = "N/A (Archive not found after creation)"
        }

        if ($sevenZipResult.ExitCode -ne 0) {
            if ($sevenZipResult.ExitCode -eq 1 -and $EffectiveJobConfig.TreatSevenZipWarningsAsSuccess) {
                & $LocalWriteLog -Message "[INFO] LocalArchiveProcessor: 7-Zip returned warning (Exit Code 1) but 'TreatSevenZipWarningsAsSuccess' is true. Local archive status remains SUCCESS." -Level "INFO"
            }
            else {
                $currentLocalArchiveStatus = if ($sevenZipResult.ExitCode -eq 1) { "WARNINGS" } else { "FAILURE" }
                & $LocalWriteLog -Message "[$(if($currentLocalArchiveStatus -eq 'FAILURE') {'ERROR'} else {'WARNING'})] LocalArchiveProcessor: 7-Zip operation for local archive creation resulted in Exit Code $($sevenZipResult.ExitCode). This impacts local archive status." -Level $currentLocalArchiveStatus
            }
        }

        $reportData.ArchiveChecksumAlgorithm = $EffectiveJobConfig.ChecksumAlgorithm
        if ($currentLocalArchiveStatus -ne "FAILURE") {
            
            # --- Generate a manifest of the archive's *contents* if configured (for verification) ---
            if ($EffectiveJobConfig.GenerateContentsManifest) {
                $archiveForManifestGeneration = $finalArchivePathFor7ZipCommand
                & $LocalWriteLog -Message "`n[INFO] LocalArchiveProcessor: Generating manifest of archive contents for '$archiveForManifestGeneration'..." -Level "INFO"

                $baseManifestName = Split-Path -Path $archiveForManifestGeneration -Leaf
                $manifestDir = Split-Path -Path $archiveForManifestGeneration -Parent
                $contentsManifestFileName = Join-Path -Path $manifestDir -ChildPath "$($baseManifestName).contents.manifest"
                
                $reportData.ContentsManifestFile = $contentsManifestFileName
                if ($IsSimulateMode.IsPresent) {
                    & $LocalWriteLog -Message "SIMULATE: Would list contents of '$archiveForManifestGeneration' and save to '$contentsManifestFileName'." -Level "SIMULATE"
                    $reportData.ContentsManifestStatus = "Simulated"
                }
                elseif (Test-Path -LiteralPath $archiveForManifestGeneration -PathType Leaf) {
                    $archiveContents = Get-7ZipArchiveListing -SevenZipPathExe $sevenZipPathGlobal -ArchivePath $archiveForManifestGeneration -PlainTextPassword $ArchivePasswordPlainText -Logger $Logger
                    if ($null -ne $archiveContents) {
                        # Create a detailed, CSV-like manifest line for FILES ONLY
                        $manifestContent = $archiveContents | Where-Object { $_.Attributes -notlike "D*" } | ForEach-Object {
                            $crc = if ($_.'CRC') { $_.'CRC' } else { "00000000" }
                            $size = $_.'Size'
                            $modified = $_.'Modified'
                            $attributes = $_.'Attributes'
                            $path = $_.'Path'
                            "$crc,$size,$modified,$attributes,`"$path`""
                        }
                        try {
                            $manifestHeader = "# PoSh-Backup Contents Manifest. Fields: CRC,Size,Modified,Attributes,Path"
                            $finalManifestContent = @($manifestHeader) + $manifestContent

                            [System.IO.File]::WriteAllLines($contentsManifestFileName, $finalManifestContent, [System.Text.Encoding]::UTF8)

                            & $LocalWriteLog -Message "  - Contents manifest created: '$contentsManifestFileName'" -Level "SUCCESS"
                            $reportData.ContentsManifestStatus = "Generated"
                        }
                        catch {
                            & $LocalWriteLog -Message "[ERROR] Failed to write contents manifest file '$contentsManifestFileName'. Error: $($_.Exception.Message)" -Level "ERROR"
                            $reportData.ContentsManifestStatus = "Error (File Write Failed)"
                        }
                    }
                    else {
                        & $LocalWriteLog -Message "[ERROR] Failed to list archive contents to create manifest for '$archiveForManifestGeneration'." -Level "ERROR"
                        $reportData.ContentsManifestStatus = "Error (Could not list archive)"
                    }
                }
                else {
                    & $LocalWriteLog -Message "[WARNING] Archive not found at '$archiveForManifestGeneration'. Skipping contents manifest generation." -Level "WARNING"
                    $reportData.ContentsManifestStatus = "Skipped (Archive Not Found)"
                }
            }

            # --- Generate checksum of the archive file(s) themselves ---
            if (-not [string]::IsNullOrWhiteSpace($EffectiveJobConfig.SplitVolumeSize) -and $EffectiveJobConfig.GenerateSplitArchiveManifest) {
                & $LocalWriteLog -Message "`n[INFO] LocalArchiveProcessor: Generating checksum manifest for split archive '$sevenZipTargetName'..." -Level "INFO"
                $reportData.ArchiveChecksum = "Manifest Generation Attempted"
                $manifestFileName = "$($sevenZipTargetName).manifest.$($EffectiveJobConfig.ChecksumAlgorithm.ToLowerInvariant())"
                $manifestFilePath = Join-Path -Path $EffectiveJobConfig.DestinationDir -ChildPath $manifestFileName
                $reportData.ArchiveChecksumFile = $manifestFilePath
                $volumeChecksumsForReport = [System.Collections.Generic.List[object]]::new()

                if ($IsSimulateMode.IsPresent) {
                    & $LocalWriteLog -Message "SIMULATE: Would find all volumes for '$sevenZipTargetName', calculate their checksums, and write to manifest '$manifestFilePath'." -Level "SIMULATE"
                    $volumeChecksumsForReport.Add(@{VolumeName = "$sevenZipTargetName.001"; Checksum = "SIMULATED_CHECKSUM_VOL1" })
                    $volumeChecksumsForReport.Add(@{VolumeName = "$sevenZipTargetName.002"; Checksum = "SIMULATED_CHECKSUM_VOL2" })
                    $reportData.ArchiveChecksum = "Manifest Simulated"
                }
                else {
                    $volumeFiles = Get-ChildItem -Path $EffectiveJobConfig.DestinationDir -Filter ($sevenZipTargetName + ".*") | 
                    Where-Object { $_.Name -match ([regex]::Escape($sevenZipTargetName) + "\.\d{3,}") } | 
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
                            if ($currentLocalArchiveStatus -ne "FAILURE") { $currentLocalArchiveStatus = "WARNINGS" }
                        }
                    }
                    else {
                        & $LocalWriteLog -Message "[WARNING] No volume files found for '$sevenZipTargetName' after archive creation. Cannot generate manifest." -Level "WARNING"
                        $reportData.ArchiveChecksum = "Skipped (No volumes found)"
                    }
                }
                $reportData.VolumeChecksums = $volumeChecksumsForReport
            }
            elseif ($EffectiveJobConfig.GenerateArchiveChecksum) { 
                & $LocalWriteLog -Message "`n[INFO] Generating checksum for archive '$finalArchivePathForReturn'..." -Level "INFO"
                $checksumFileExtension = $EffectiveJobConfig.ChecksumAlgorithm.ToLowerInvariant()
                $fileToChecksumPath = $finalArchivePathForReturn 
                $archiveNameForInChecksumFile = Split-Path -Path $fileToChecksumPath -Leaf 

                $archiveFileItem = Get-Item -LiteralPath $fileToChecksumPath -ErrorAction SilentlyContinue
                
                if ($null -ne $archiveFileItem -and $archiveFileItem.Exists) {
                    $checksumFileNameWithExt = $archiveFileItem.Name + ".$checksumFileExtension" 
                    $checksumFileDir = $archiveFileItem.DirectoryName 
                    $checksumFilePath = Join-Path -Path $checksumFileDir -ChildPath $checksumFileNameWithExt
                    $reportData.ArchiveChecksumFile = $checksumFilePath
                }
                else {
                    & $LocalWriteLog -Message "[WARNING] Archive file '$fileToChecksumPath' not found. Cannot determine checksum file path details." -Level "WARNING"
                    $reportData.ArchiveChecksumFile = "N/A (Source archive not found for checksum)"
                }

                if ($IsSimulateMode.IsPresent) {
                    & $LocalWriteLog -Message "SIMULATE: Would generate $($EffectiveJobConfig.ChecksumAlgorithm) checksum for '$fileToChecksumPath' and save to '$checksumFilePath'." -Level "SIMULATE"
                    $reportData.ArchiveChecksum = "SIMULATED_CHECKSUM_VALUE"
                }
                elseif ($null -ne $archiveFileItem -and $archiveFileItem.Exists) {
                    $generatedHash = Get-PoshBackupFileHash -FilePath $fileToChecksumPath -Algorithm $EffectiveJobConfig.ChecksumAlgorithm -Logger $Logger 
                    if ($null -ne $generatedHash) {
                        $reportData.ArchiveChecksum = $generatedHash
                        try {
                            [System.IO.File]::WriteAllText($checksumFilePath, "$($generatedHash.ToUpperInvariant())  $($archiveNameForInChecksumFile)", [System.Text.Encoding]::UTF8)
                            & $LocalWriteLog -Message "  - Checksum file created: '$checksumFilePath' with content: '$($generatedHash.ToUpperInvariant())  $($archiveNameForInChecksumFile)'" -Level "SUCCESS"
                        }
                        catch {
                            & $LocalWriteLog -Message "[ERROR] Failed to write checksum file '$checksumFilePath'. Error: $($_.Exception.Message)" -Level "ERROR"
                            $reportData.ArchiveChecksum = "Error (Failed to write file)"
                            if ($currentLocalArchiveStatus -ne "FAILURE") { $currentLocalArchiveStatus = "WARNINGS" }
                        }
                    }
                    else {
                        & $LocalWriteLog -Message "[ERROR] Checksum generation failed for '$fileToChecksumPath'." -Level "ERROR"
                        $reportData.ArchiveChecksum = "Error (Generation failed)"
                        if ($currentLocalArchiveStatus -ne "FAILURE") { $currentLocalArchiveStatus = "WARNINGS" }
                    }
                }
                else {
                    & $LocalWriteLog -Message "[WARNING] Archive file '$fileToChecksumPath' not found. Skipping checksum generation." -Level "WARNING"
                    $reportData.ArchiveChecksum = "Skipped (Archive not found)"
                }
            }
        }
        elseif ($EffectiveJobConfig.GenerateArchiveChecksum -or $EffectiveJobConfig.GenerateSplitArchiveManifest) {
            & $LocalWriteLog -Message "[INFO] Checksum/Manifest generation skipped due to prior failure in archive creation." -Level "INFO"
            $reportData.ArchiveChecksum = "Skipped (Prior failure)"
        }

        $shouldTestArchiveNow = $EffectiveJobConfig.JobTestArchiveAfterCreation -or $EffectiveJobConfig.VerifyLocalArchiveBeforeTransfer
        $reportData.ArchiveTested = $shouldTestArchiveNow

        if ($shouldTestArchiveNow -and ($currentLocalArchiveStatus -ne "FAILURE") -and (-not $IsSimulateMode.IsPresent) -and (Test-Path -LiteralPath $finalArchivePathForReturn -PathType Leaf)) {
            $testArchiveParams = @{
                SevenZipPathExe           = $sevenZipPathGlobal
                ArchivePath               = $finalArchivePathForReturn 
                PlainTextPassword         = $ArchivePasswordPlainText
                ProcessPriority           = $EffectiveJobConfig.JobSevenZipProcessPriority
                SevenZipCpuAffinityString = $SevenZipCpuAffinityString
                HideOutput                = $EffectiveJobConfig.HideSevenZipOutput
                MaxRetries                = $EffectiveJobConfig.JobMaxRetryAttempts
                RetryDelaySeconds         = $EffectiveJobConfig.JobRetryDelaySeconds
                EnableRetries             = $EffectiveJobConfig.JobEnableRetries
                TreatWarningsAsSuccess    = $EffectiveJobConfig.TreatSevenZipWarningsAsSuccess
                Logger                    = $Logger 
            }
            if ((Get-Command Test-7ZipArchive).Parameters.ContainsKey('PSCmdlet')) {
                $testArchiveParams.PSCmdlet = $PSCmdlet
            }
            $testResult = Test-7ZipArchive @testArchiveParams
            $reportData.TestRetryAttemptsMade = $testResult.AttemptsMade

            if ($testResult.ExitCode -eq 0) {
                $reportData.ArchiveTestResult = "PASSED (7z t on first volume/archive)"
            }
            elseif ($testResult.ExitCode -eq 1 -and $EffectiveJobConfig.TreatSevenZipWarningsAsSuccess) {
                $reportData.ArchiveTestResult = "PASSED (7z t Warning on first volume/archive, treated as success)"
            }
            else {
                $reportData.ArchiveTestResult = "FAILED (7z t on first volume/archive Exit Code: $($testResult.ExitCode))"
                if ($EffectiveJobConfig.VerifyLocalArchiveBeforeTransfer) { $currentLocalArchiveStatus = "FAILURE" }
                elseif ($currentLocalArchiveStatus -ne "FAILURE") { $currentLocalArchiveStatus = "WARNINGS" }
            }

            if (-not [string]::IsNullOrWhiteSpace($EffectiveJobConfig.SplitVolumeSize) -and `
                    $EffectiveJobConfig.GenerateSplitArchiveManifest -and `
                    $EffectiveJobConfig.VerifyArchiveChecksumOnTest -and `
                ($testResult.ExitCode -eq 0 -or ($testResult.ExitCode -eq 1 -and $EffectiveJobConfig.TreatSevenZipWarningsAsSuccess))) {
                
                & $LocalWriteLog -Message "`n[INFO] Verifying archive volumes using manifest '$($reportData.ArchiveChecksumFile)'..." -Level "INFO"
                $reportData.ArchiveChecksumVerificationStatus = "Verification Attempted (Manifest)"
                $manifestFileForVerify = $reportData.ArchiveChecksumFile

                if (Test-Path -LiteralPath $manifestFileForVerify -PathType Leaf) {
                    $allVolumesInManifestVerified = $true
                    $manifestVerificationDetails = [System.Collections.Generic.List[string]]::new()
                    try {
                        $manifestEntries = Get-Content -LiteralPath $manifestFileForVerify -ErrorAction Stop
                        foreach ($entryLine in $manifestEntries) {
                            if ($entryLine -match "^\s*([a-fA-F0-9]+)\s\s+(.+)$") { 
                                $storedVolHash = $Matches[1].Trim().ToUpperInvariant()
                                $volFileNameInManifest = $Matches[2].Trim()
                                $fullVolPathToVerify = Join-Path -Path $EffectiveJobConfig.DestinationDir -ChildPath $volFileNameInManifest
                                
                                $manifestVerificationDetails.Add("Volume: $volFileNameInManifest, Expected Hash: $storedVolHash")

                                if (-not (Test-Path -LiteralPath $fullVolPathToVerify -PathType Leaf)) {
                                    & $LocalWriteLog -Message "[ERROR] Manifest Verification - Volume '$volFileNameInManifest' listed in manifest not found at '$fullVolPathToVerify'." -Level "ERROR"
                                    $manifestVerificationDetails.Add("  Status: MISSING")
                                    $allVolumesInManifestVerified = $false; continue
                                }
                                $recalculatedVolHash = Get-PoshBackupFileHash -FilePath $fullVolPathToVerify -Algorithm $EffectiveJobConfig.ChecksumAlgorithm -Logger $Logger 
                                if ($null -ne $recalculatedVolHash -and $recalculatedVolHash.Equals($storedVolHash, [System.StringComparison]::OrdinalIgnoreCase)) {
                                    & $LocalWriteLog -Message "  - Manifest Verification - Volume '$volFileNameInManifest': Checksum VERIFIED." -Level "SUCCESS"
                                    $manifestVerificationDetails.Add("  Status: VERIFIED")
                                }
                                elseif ($null -ne $recalculatedVolHash) {
                                    & $LocalWriteLog -Message "[ERROR] Manifest Verification - Volume '$volFileNameInManifest': Checksum MISMATCH. Stored: $storedVolHash, Calculated: $recalculatedVolHash." -Level "ERROR"
                                    $manifestVerificationDetails.Add("  Status: MISMATCH (Calculated: $recalculatedVolHash)")
                                    $allVolumesInManifestVerified = $false
                                }
                                else {
                                    & $LocalWriteLog -Message "[ERROR] Manifest Verification - Volume '$volFileNameInManifest': Failed to recalculate checksum." -Level "ERROR"
                                    $manifestVerificationDetails.Add("  Status: RECALC_FAILED")
                                    $allVolumesInManifestVerified = $false
                                }
                            }
                            elseif ($entryLine -match "ERROR_GENERATING_CHECKSUM\s\s+(.+)") {
                                $volFileNameInManifest = $Matches[1].Trim()
                                & $LocalWriteLog -Message "[WARNING] Manifest Verification - Volume '$volFileNameInManifest' had checksum generation error during manifest creation. Cannot verify." -Level "WARNING"
                                $manifestVerificationDetails.Add("Volume: $volFileNameInManifest, Status: SKIPPED (Original checksum error)")
                                $allVolumesInManifestVerified = $false 
                            }
                        }
                        $reportData.ArchiveChecksumVerificationStatus = if ($allVolumesInManifestVerified) { "Verified via Manifest (All Volumes OK)" } else { "Verification via Manifest FAILED (One or more volumes)" }
                        $reportData.ArchiveTestResult += if ($allVolumesInManifestVerified) { " (Manifest OK)" } else { " (MANIFEST VERIFICATION FAILED/PARTIAL)" }
                        if (-not $allVolumesInManifestVerified) {
                            if ($EffectiveJobConfig.VerifyLocalArchiveBeforeTransfer) { $currentLocalArchiveStatus = "FAILURE" }
                            elseif ($currentLocalArchiveStatus -ne "FAILURE") { $currentLocalArchiveStatus = "WARNINGS" }
                        }
                        $reportData.ManifestVerificationDetails = $manifestVerificationDetails -join [Environment]::NewLine
                    }
                    catch {
                        & $LocalWriteLog -Message "[ERROR] Failed to read or parse manifest file '$manifestFileForVerify' for verification. Error: $($_.Exception.Message)" -Level "ERROR"
                        $reportData.ArchiveChecksumVerificationStatus = "Error (Manifest file read/parse failed)"
                        $reportData.ArchiveTestResult += " (Manifest Read Failed)"
                        if ($EffectiveJobConfig.VerifyLocalArchiveBeforeTransfer) { $currentLocalArchiveStatus = "FAILURE" }
                        elseif ($currentLocalArchiveStatus -ne "FAILURE") { $currentLocalArchiveStatus = "WARNINGS" }
                    }
                }
                else {
                    & $LocalWriteLog -Message "[WARNING] Manifest file '$manifestFileForVerify' not found. Cannot verify volumes via manifest." -Level "WARNING"
                    $reportData.ArchiveChecksumVerificationStatus = "Skipped (Manifest file not found)"
                    $reportData.ArchiveTestResult += " (Manifest File Missing for Verification)"
                }
            }
            elseif ($EffectiveJobConfig.VerifyArchiveChecksumOnTest -and $EffectiveJobConfig.GenerateArchiveChecksum -and `
                ($testResult.ExitCode -eq 0 -or ($testResult.ExitCode -eq 1 -and $EffectiveJobConfig.TreatSevenZipWarningsAsSuccess))) {
                & $LocalWriteLog -Message "`n[INFO] Verifying single archive checksum for '$finalArchivePathForReturn'..." -Level "INFO"
                $checksumFileExtensionForVerify = $EffectiveJobConfig.ChecksumAlgorithm.ToLowerInvariant()
                $checksumFilePathForVerify = "$($finalArchivePathForReturn).$checksumFileExtensionForVerify" 
                $reportData.ArchiveChecksumVerificationStatus = "Verification Attempted (Single File/First Volume)"

                if (Test-Path -LiteralPath $checksumFilePathForVerify -PathType Leaf) {
                    try {
                        $checksumFileContent = Get-Content -LiteralPath $checksumFilePathForVerify -Raw -ErrorAction Stop
                        $storedHashFromFile = ($checksumFileContent -split '\s+')[0].Trim().ToUpperInvariant()
                        $recalculatedHash = Get-PoshBackupFileHash -FilePath $finalArchivePathForReturn -Algorithm $EffectiveJobConfig.ChecksumAlgorithm -Logger $Logger 
                        if ($null -ne $recalculatedHash -and $recalculatedHash.Equals($storedHashFromFile, [System.StringComparison]::OrdinalIgnoreCase)) {
                            & $LocalWriteLog -Message "  - Checksum VERIFIED for '$finalArchivePathForReturn'. Stored: $storedHashFromFile, Calculated: $recalculatedHash." -Level "SUCCESS"
                            $reportData.ArchiveChecksumVerificationStatus = "Verified Successfully"
                            $reportData.ArchiveTestResult += " (Checksum OK)"
                        }
                        elseif ($null -ne $recalculatedHash) {
                            & $LocalWriteLog -Message "[ERROR] Checksum MISMATCH for '$finalArchivePathForReturn'. Stored: $storedHashFromFile, Calculated: $recalculatedHash." -Level "ERROR"
                            $reportData.ArchiveChecksumVerificationStatus = "Mismatch (Stored: $storedHashFromFile, Calc: $recalculatedHash)"
                            $reportData.ArchiveTestResult += " (CHECKSUM MISMATCH)"
                            if ($EffectiveJobConfig.VerifyLocalArchiveBeforeTransfer) { $currentLocalArchiveStatus = "FAILURE" }
                            elseif ($currentLocalArchiveStatus -ne "FAILURE") { $currentLocalArchiveStatus = "WARNINGS" }
                        }
                        else {
                            & $LocalWriteLog -Message "[ERROR] Failed to recalculate checksum for verification of '$finalArchivePathForReturn'." -Level "ERROR"
                            $reportData.ArchiveChecksumVerificationStatus = "Error (Recalculation failed)"
                            $reportData.ArchiveTestResult += " (Checksum Recalc Failed)"
                            if ($EffectiveJobConfig.VerifyLocalArchiveBeforeTransfer) { $currentLocalArchiveStatus = "FAILURE" }
                            elseif ($currentLocalArchiveStatus -ne "FAILURE") { $currentLocalArchiveStatus = "WARNINGS" }
                        }
                    }
                    catch {
                        & $LocalWriteLog -Message "[ERROR] Failed to read checksum file '$checksumFilePathForVerify' for verification. Error: $($_.Exception.Message)" -Level "ERROR"
                        $reportData.ArchiveChecksumVerificationStatus = "Error (Checksum file read failed)"
                        $reportData.ArchiveTestResult += " (Checksum File Read Failed)"
                        if ($EffectiveJobConfig.VerifyLocalArchiveBeforeTransfer) { $currentLocalArchiveStatus = "FAILURE" }
                        elseif ($currentLocalArchiveStatus -ne "FAILURE") { $currentLocalArchiveStatus = "WARNINGS" }
                    }
                }
                else {
                    & $LocalWriteLog -Message "[WARNING] Checksum file '$checksumFilePathForVerify' not found. Cannot verify checksum." -Level "WARNING"
                    $reportData.ArchiveChecksumVerificationStatus = "Skipped (Checksum file not found)"
                    $reportData.ArchiveTestResult += " (Checksum File Missing)"
                }
            }
            elseif ($EffectiveJobConfig.VerifyArchiveChecksumOnTest -and ($EffectiveJobConfig.GenerateArchiveChecksum -or $EffectiveJobConfig.GenerateSplitArchiveManifest)) {
                & $LocalWriteLog -Message "[INFO] Checksum/Manifest verification skipped because 7z archive test failed or was treated as failure." -Level "INFO"
                $reportData.ArchiveChecksumVerificationStatus = "Skipped (7z test failed)"
            }
            elseif ($EffectiveJobConfig.VerifyArchiveChecksumOnTest -and (-not $EffectiveJobConfig.GenerateArchiveChecksum) -and (-not $EffectiveJobConfig.GenerateSplitArchiveManifest)) {
                & $LocalWriteLog -Message "[INFO] Checksum/Manifest verification skipped because checksum/manifest generation was disabled." -Level "INFO"
                $reportData.ArchiveChecksumVerificationStatus = "Skipped (Generation disabled)"
            }

        }
        elseif ($shouldTestArchiveNow) { 
            $reportData.ArchiveTestResult = if ($IsSimulateMode.IsPresent) { "Not Performed (Simulation Mode)" } else { "Not Performed (Archive Missing or Prior Compression Error)" }
            $reportData.ArchiveChecksumVerificationStatus = "Skipped (Archive test not performed)"
        }
        else { 
            $reportData.ArchiveTestResult = "Not Configured"
            $reportData.ArchiveChecksumVerificationStatus = "Skipped (Archive test not configured)"
        }

        # --- Pinning Logic ---
        if ($EffectiveJobConfig.PinOnCreation -and $currentLocalArchiveStatus -ne "FAILURE") {
            & $LocalWriteLog -Message "`n[INFO] PinOnCreation is enabled for this job. Pinning newly created archive..." -Level "INFO"
            
            $pathToPin = $finalArchivePathFor7ZipCommand # e.g., "D:\Backups\MyJob [Date].7z"

            if ($IsSimulateMode.IsPresent) {
                & $LocalWriteLog -Message "SIMULATE: Would pin archive by creating marker file for '$pathToPin'." -Level "SIMULATE"
                $reportData.ArchivePinned = "Simulated"
            }
            elseif (Test-Path -LiteralPath $finalArchivePathForReturn -PathType Leaf) {
                # Check that at least the first part exists
                if ($PSCmdlet.ShouldProcess($pathToPin, "Pin Archive")) {
                    try {
                        Add-PoShBackupPin -Path $pathToPin -Logger $Logger
                        $reportData.ArchivePinned = "Yes"
                    }
                    catch {
                        $pinError = "Failed to pin archive '$pathToPin'. Error: $($_.Exception.Message)"
                        & $LocalWriteLog -Message "[ERROR] $pinError" -Level "ERROR"
                        $reportData.ArchivePinned = "Failed"
                        if ($currentLocalArchiveStatus -ne "FAILURE") { $currentLocalArchiveStatus = "WARNINGS" }
                    }
                }
                else {
                    & $LocalWriteLog -Message "[INFO] Pinning of archive '$pathToPin' skipped by user (ShouldProcess)." -Level "INFO"
                    $reportData.ArchivePinned = "No (Skipped by user)"
                }
            }
            else {
                & $LocalWriteLog -Message "[WARNING] Cannot pin archive because the primary archive file was not found at '$finalArchivePathForReturn'." -Level "WARNING"
                $reportData.ArchivePinned = "Skipped (Archive Not Found)"
            }
        }
        else {
            $reportData.ArchivePinned = "No"
        }
        # --- END Pinning Logic ---

    }
    catch {
        & $LocalWriteLog -Message "[ERROR] Error during local archive operations for job '$($EffectiveJobConfig.JobName)': $($_.Exception.ToString())" -Level ERROR
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
