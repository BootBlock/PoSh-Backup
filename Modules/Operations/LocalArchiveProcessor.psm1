# Modules\Operations\LocalArchiveProcessor.psm1
<#
.SYNOPSIS
    Acts as a facade to orchestrate the local backup archive creation process.
    It calls specialized sub-modules to handle archive creation and post-creation processing.
.DESCRIPTION
    This module is a sub-component of the main Operations module for PoSh-Backup.
    It encapsulates the specific steps involved in creating a local archive by orchestrating
    calls to sub-modules located in '.\LocalArchiveProcessor\'.

    The main exported function, Invoke-LocalArchiveOperation, performs the following sequence:
    1.  Checks destination free space for the local archive.
    2.  Generates the final archive filename and path.
    3.  Pre-emptively deletes any old split-volume files that might conflict with the new run.
    4.  Calls 'Invoke-PoShBackupArchiveCreation' from 'ArchiveCreator.psm1' to execute 7-Zip.
    5.  If archive creation is successful, it calls 'Invoke-PoShBackupPostArchiveProcessing'
        from 'PostArchiveProcessor.psm1' to handle checksums, testing, hooks, and pinning.
    6.  Updates the job report data with the final outcomes.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.0.1 # Corrected logging variable in catch block.
    DateCreated:    26-Jun-2025
    LastModified:   26-Jun-2025
    Purpose:        To orchestrate local archive processing logic.
    Prerequisites:  PowerShell 5.1+.
                    Depends on sub-modules in '.\LocalArchiveProcessor\'.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Operations
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
    $subModulePath = Join-Path -Path $PSScriptRoot -ChildPath "LocalArchiveProcessor"
    Import-Module -Name (Join-Path -Path $subModulePath -ChildPath "ArchiveCreator.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $subModulePath -ChildPath "PostArchiveProcessor.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "LocalArchiveProcessor.psm1 (Facade) FATAL: Could not import required modules. Error: $($_.Exception.Message)"
    throw
}
#endregion

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
        [Parameter(Mandatory = $false)]
        [string]$ArchivePasswordPlainText = $null,
        [Parameter(Mandatory = $false)]
        [string]$SevenZipCpuAffinityString = $null,
        [Parameter(Mandatory = $true)]
        [string]$ActualConfigFile
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

    & $Logger -Message "LocalArchiveProcessor (Facade): Orchestrating local archive operation. CPU Affinity String: '$SevenZipCpuAffinityString'" -Level "DEBUG"

    $currentLocalArchiveStatus = "SUCCESS"
    $finalArchivePathForReturn = $null
    $reportData = $JobReportDataRef.Value
    $archiveFileNameOnly = $null

    # Populate initial report data that this module is responsible for setting.
    $reportData.VerifyLocalArchiveBeforeTransfer = $EffectiveJobConfig.VerifyLocalArchiveBeforeTransfer
    $reportData.GenerateSplitArchiveManifest = $EffectiveJobConfig.GenerateSplitArchiveManifest
    $reportData.PinOnCreation = $EffectiveJobConfig.PinOnCreation
    $reportData.GenerateContentsManifest = $EffectiveJobConfig.GenerateContentsManifest

    try {
        $destinationDirTerm = if ($EffectiveJobConfig.ResolvedTargetInstances.Count -eq 0) { "Final Destination Directory" } else { "Local Staging Directory" }

        & $LocalWriteLog -Message "`n[DEBUG] LocalArchiveProcessor: Performing Pre-Archive Creation Operations..." -Level "DEBUG"
        & $LocalWriteLog -Message "   - Using source(s) for 7-Zip: $(if ($CurrentJobSourcePathFor7Zip -is [array]) {($CurrentJobSourcePathFor7Zip | Where-Object {$_}) -join '; '} else {$CurrentJobSourcePathFor7Zip})" -Level "DEBUG"

        if (-not (Test-DestinationFreeSpace -DestDir $EffectiveJobConfig.DestinationDir -MinRequiredGB $EffectiveJobConfig.JobMinimumRequiredFreeSpaceGB -ExitOnLow $EffectiveJobConfig.JobExitOnLowSpace -IsSimulateMode:$IsSimulateMode -Logger $Logger)) {
            throw "Low disk space on '${destinationDirTerm}' and configured to halt job '$($EffectiveJobConfig.BaseFileName)'."
        }

        # --- 1. Generate Archive Filename and Paths ---
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
        & $LocalWriteLog -Message "`n[DEBUG] LocalArchiveProcessor: Target Archive in ${destinationDirTerm}: $finalArchivePathFor7ZipCommand (First volume/file expected at: $finalArchivePathForReturn)" -Level "DEBUG"

        # --- 2. Pre-emptively delete old conflicting volumes ---
        if (-not [string]::IsNullOrWhiteSpace($EffectiveJobConfig.SplitVolumeSize) -and $EffectiveJobConfig.SplitVolumeSize -match "^\d+[kmg]$") {
            $existingVolumePattern = [regex]::Escape($sevenZipTargetName) + ".[0-9][0-9]*"
            $existingVolumes = Get-ChildItem -Path $EffectiveJobConfig.DestinationDir -Filter ($sevenZipTargetName + ".*") | Where-Object { $_.Name -match $existingVolumePattern }
            if ($existingVolumes.Count -gt 0) {
                & $LocalWriteLog -Message "[WARNING] LocalArchiveProcessor: Found $($existingVolumes.Count) existing volume(s) for '$sevenZipTargetName'. Attempting to delete them before creating new split set." -Level "WARNING"
                foreach ($volumeFile in $existingVolumes) {
                    if ($IsSimulateMode.IsPresent) { & $LocalWriteLog -Message "SIMULATE: Would delete existing volume part '$($volumeFile.FullName)'." -Level "SIMULATE" }
                    elseif ($PSCmdlet.ShouldProcess($volumeFile.FullName, "Delete existing archive volume part")) {
                        try { Remove-Item -LiteralPath $volumeFile.FullName -Force -ErrorAction Stop; & $LocalWriteLog -Message "  - Deleted existing volume part: '$($volumeFile.FullName)'." -Level "INFO" }
                        catch { & $LocalWriteLog -Message "[ERROR] LocalArchiveProcessor: Failed to delete existing volume part '$($volumeFile.FullName)'. Error: $($_.Exception.Message)." -Level "ERROR"; $currentLocalArchiveStatus = "WARNINGS" }
                    }
                }
            }
        }
        
        # --- 3. Delegate Archive Creation ---
        $creatorParams = @{
            EffectiveJobConfig             = $EffectiveJobConfig
            CurrentJobSourcePathFor7Zip    = if ($CurrentJobSourcePathFor7Zip -is [array]) { @($CurrentJobSourcePathFor7Zip) } else { @($CurrentJobSourcePathFor7Zip) }
            FinalArchivePathFor7ZipCommand = $finalArchivePathFor7ZipCommand
            ArchivePasswordPlainText       = $ArchivePasswordPlainText
            IsSimulateMode                 = $IsSimulateMode.IsPresent
            Logger                         = $Logger
            PSCmdlet                       = $PSCmdlet
        }
        $sevenZipResult = Invoke-PoShBackupArchiveCreation @creatorParams

        # --- 4. Process Archive Creation Results ---
        $reportData.SevenZipExitCode = $sevenZipResult.ExitCode
        $reportData.CompressionTime = if ($null -ne $sevenZipResult.ElapsedTime) { $sevenZipResult.ElapsedTime.ToString() } else { "N/A" }
        $reportData.RetryAttemptsMade = $sevenZipResult.AttemptsMade

        if (-not $IsSimulateMode.IsPresent -and (Test-Path -LiteralPath $finalArchivePathForReturn -PathType Leaf)) {
            $reportData.ArchiveSizeBytes = (Get-Item -LiteralPath $finalArchivePathForReturn).Length
            $reportData.ArchiveSizeFormatted = Get-ArchiveSizeFormatted -PathToArchive $finalArchivePathForReturn -Logger $Logger
        } else {
            $reportData.ArchiveSizeBytes = 0; $reportData.ArchiveSizeFormatted = if ($IsSimulateMode.IsPresent) { "0 Bytes (Simulated)" } else { "N/A (Archive not found)" }
        }

        if ($sevenZipResult.ExitCode -ne 0) {
            if ($sevenZipResult.ExitCode -eq 1 -and $EffectiveJobConfig.TreatSevenZipWarningsAsSuccess) {
                & $LocalWriteLog -Message "[INFO] LocalArchiveProcessor: 7-Zip returned warning (Exit Code 1) but 'TreatSevenZipWarningsAsSuccess' is true. Local archive status remains SUCCESS." -Level "INFO"
            } else {
                $currentLocalArchiveStatus = if ($sevenZipResult.ExitCode -eq 1) { "WARNINGS" } else { "FAILURE" }
                & $LocalWriteLog -Message "[$(if($currentLocalArchiveStatus -eq 'FAILURE') {'ERROR'} else {'WARNING'})] LocalArchiveProcessor: 7-Zip operation for local archive creation resulted in Exit Code $($sevenZipResult.ExitCode). This impacts local archive status." -Level $currentLocalArchiveStatus
            }
        }

        # --- 5. Delegate Post-Archive Processing (Checksums, Test, Hooks, Pinning) ---
        $postProcessorParams = @{
            EffectiveJobConfig             = $EffectiveJobConfig
            InitialStatus                  = $currentLocalArchiveStatus
            FinalArchivePathForReturn      = $finalArchivePathForReturn
            FinalArchivePathFor7ZipCommand = $finalArchivePathFor7ZipCommand
            ArchiveFileNameOnly            = $archiveFileNameOnly
            JobReportDataRef               = $JobReportDataRef
            IsSimulateMode                 = $IsSimulateMode.IsPresent
            Logger                         = $Logger
            PSCmdlet                       = $PSCmdlet
            ActualConfigFile               = $ActualConfigFile
            ArchivePasswordPlainText       = $ArchivePasswordPlainText
        }
        $currentLocalArchiveStatus = Invoke-PoShBackupPostArchiveProcessing @postProcessorParams

    }
    catch {
        & $LocalWriteLog -Message "[ERROR] Error during local archive operations for job '$($EffectiveJobConfig.BaseFileName)': $($_.Exception.ToString())" -Level ERROR
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
