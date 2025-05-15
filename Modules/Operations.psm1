<#
.SYNOPSIS
    Manages the core backup operations for a single backup job within the PoSh-Backup solution.
    This includes gathering effective job configurations, handling VSS (Volume Shadow Copy Service)
    creation and cleanup, executing 7-Zip for archiving and testing, applying retention policies,
    and checking destination free space.
.DESCRIPTION
    The Operations module encapsulates the entire lifecycle of processing a single backup job.
    It interfaces with VSS for snapshotting, 7-Zip for compression, PasswordManager for password
    retrieval, and utility functions for logging and configuration. It aims to make each backup
    job execution robust and report detailed status.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.6.4 (Removed in-line PSSA suppressions now handled by settings file; trailing whitespace removed)
    DateCreated:    10-May-2025
    LastModified:   15-May-2025
    Purpose:        Handles the execution logic for individual backup jobs.
    Prerequisites:  PowerShell 5.1+, 7-Zip, Utils.psm1, PasswordManager.psm1.
                    Administrator privileges required for VSS functionality.
#>

#region --- Private Helper: Gather Job Configuration ---
# Not exported
function Get-PoShBackupJobEffectiveConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$JobConfig,
        [Parameter(Mandatory)] [hashtable]$GlobalConfig,
        [Parameter(Mandatory)] [hashtable]$CliOverrides,
        [Parameter(Mandatory)] [ref]$JobReportDataRef
    )

    $effectiveConfig = @{}
    $reportData = $JobReportDataRef.Value

    $effectiveConfig.OriginalSourcePath = $JobConfig.Path
    $effectiveConfig.BaseFileName       = $JobConfig.Name
    $reportData.JobConfiguration        = $JobConfig

    $effectiveConfig.DestinationDir = Get-ConfigValue -ConfigObject $JobConfig -Key 'DestinationDir' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultDestinationDir' -DefaultValue $null)
    $effectiveConfig.RetentionCount = Get-ConfigValue -ConfigObject $JobConfig -Key 'RetentionCount' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultRetentionCount' -DefaultValue 3)
    if ($effectiveConfig.RetentionCount -lt 0) { $effectiveConfig.RetentionCount = 0 }
    $effectiveConfig.DeleteToRecycleBin = Get-ConfigValue -ConfigObject $JobConfig -Key 'DeleteToRecycleBin' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultDeleteToRecycleBin' -DefaultValue $false)

    $effectiveConfig.ArchivePasswordMethod = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordMethod' -DefaultValue "None"
    $effectiveConfig.CredentialUserNameHint = Get-ConfigValue -ConfigObject $JobConfig -Key 'CredentialUserNameHint' -DefaultValue "BackupUser"
    $effectiveConfig.ArchivePasswordSecretName = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordSecretName' -DefaultValue $null
    $effectiveConfig.ArchivePasswordVaultName = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordVaultName' -DefaultValue $null
    $effectiveConfig.ArchivePasswordSecureStringPath = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordSecureStringPath' -DefaultValue $null
    $effectiveConfig.ArchivePasswordPlainText = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchivePasswordPlainText' -DefaultValue $null
    $effectiveConfig.UsePassword = Get-ConfigValue -ConfigObject $JobConfig -Key 'UsePassword' -DefaultValue $false

    $effectiveConfig.HideSevenZipOutput = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'HideSevenZipOutput' -DefaultValue $true

    $effectiveConfig.JobArchiveType = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchiveType' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultArchiveType' -DefaultValue "-t7z")
    $effectiveConfig.JobArchiveExtension = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchiveExtension' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultArchiveExtension' -DefaultValue ".7z")
    $effectiveConfig.JobArchiveDateFormat = Get-ConfigValue -ConfigObject $JobConfig -Key 'ArchiveDateFormat' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultArchiveDateFormat' -DefaultValue "yyyy-MMM-dd")

    $effectiveConfig.JobCompressionLevel = Get-ConfigValue -ConfigObject $JobConfig -Key 'CompressionLevel' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultCompressionLevel' -DefaultValue "-mx=7")
    $effectiveConfig.JobCompressionMethod = Get-ConfigValue -ConfigObject $JobConfig -Key 'CompressionMethod' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultCompressionMethod' -DefaultValue "-m0=LZMA2")
    $effectiveConfig.JobDictionarySize = Get-ConfigValue -ConfigObject $JobConfig -Key 'DictionarySize' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultDictionarySize' -DefaultValue "-md=128m")
    $effectiveConfig.JobWordSize = Get-ConfigValue -ConfigObject $JobConfig -Key 'WordSize' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultWordSize' -DefaultValue "-mfb=64")
    $effectiveConfig.JobSolidBlockSize = Get-ConfigValue -ConfigObject $JobConfig -Key 'SolidBlockSize' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultSolidBlockSize' -DefaultValue "-ms=16g")
    $effectiveConfig.JobCompressOpenFiles = Get-ConfigValue -ConfigObject $JobConfig -Key 'CompressOpenFiles' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultCompressOpenFiles' -DefaultValue $true)
    $effectiveConfig.JobAdditionalExclusions = @(Get-ConfigValue -ConfigObject $JobConfig -Key 'AdditionalExclusions' -DefaultValue @())

    $_globalConfigThreads  = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultThreadCount' -DefaultValue 0
    $_jobSpecificThreadsToUse = Get-ConfigValue -ConfigObject $JobConfig -Key 'ThreadsToUse' -DefaultValue 0
    $_threadsFor7Zip = if ($_jobSpecificThreadsToUse -gt 0) { $_jobSpecificThreadsToUse } elseif ($_globalConfigThreads -gt 0) { $_globalConfigThreads } else { 0 }
    $effectiveConfig.ThreadsSetting = if ($_threadsFor7Zip -gt 0) { "-mmt=$($_threadsFor7Zip)"} else {"-mmt"}

    $effectiveConfig.JobEnableVSS = if ($CliOverrides.UseVSS) { $true } else { Get-ConfigValue -ConfigObject $JobConfig -Key 'EnableVSS' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'EnableVSS' -DefaultValue $false) }
    $effectiveConfig.JobVSSContextOption = Get-ConfigValue -ConfigObject $JobConfig -Key 'VSSContextOption' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultVSSContextOption' -DefaultValue "Persistent NoWriters")
    $_vssCachePathFromConfig = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'VSSMetadataCachePath' -DefaultValue "%TEMP%\diskshadow_cache_poshbackup.cab"
    $effectiveConfig.VSSMetadataCachePath = [System.Environment]::ExpandEnvironmentVariables($_vssCachePathFromConfig)
    $effectiveConfig.VSSPollingTimeoutSeconds = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'VSSPollingTimeoutSeconds' -DefaultValue 120
    $effectiveConfig.VSSPollingIntervalSeconds = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'VSSPollingIntervalSeconds' -DefaultValue 5

    $effectiveConfig.JobEnableRetries = if ($CliOverrides.EnableRetries) { $true } else { Get-ConfigValue -ConfigObject $JobConfig -Key 'EnableRetries' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'EnableRetries' -DefaultValue $true) }
    $effectiveConfig.JobMaxRetryAttempts = Get-ConfigValue -ConfigObject $JobConfig -Key 'MaxRetryAttempts' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'MaxRetryAttempts' -DefaultValue 3)
    $effectiveConfig.JobRetryDelaySeconds = Get-ConfigValue -ConfigObject $JobConfig -Key 'RetryDelaySeconds' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'RetryDelaySeconds' -DefaultValue 60)

    $effectiveConfig.JobSevenZipProcessPriority = if (-not [string]::IsNullOrWhiteSpace($CliOverrides.SevenZipPriority)) {
        $CliOverrides.SevenZipPriority
    } else {
        Get-ConfigValue -ConfigObject $JobConfig -Key 'SevenZipProcessPriority' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultSevenZipProcessPriority' -DefaultValue "Normal")
    }

    $effectiveConfig.JobTestArchiveAfterCreation = if ($CliOverrides.TestArchive) { $true } else { Get-ConfigValue -ConfigObject $JobConfig -Key 'TestArchiveAfterCreation' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultTestArchiveAfterCreation' -DefaultValue $false) }

    $effectiveConfig.JobMinimumRequiredFreeSpaceGB = Get-ConfigValue -ConfigObject $JobConfig -Key 'MinimumRequiredFreeSpaceGB' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'MinimumRequiredFreeSpaceGB' -DefaultValue 0)
    $effectiveConfig.JobExitOnLowSpace = Get-ConfigValue -ConfigObject $JobConfig -Key 'ExitOnLowSpaceIfBelowMinimum' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'ExitOnLowSpaceIfBelowMinimum' -DefaultValue $false)

    $effectiveConfig.PreBackupScriptPath = Get-ConfigValue -ConfigObject $JobConfig -Key 'PreBackupScriptPath' -DefaultValue $null
    $effectiveConfig.PostBackupScriptOnSuccessPath = Get-ConfigValue -ConfigObject $JobConfig -Key 'PostBackupScriptOnSuccessPath' -DefaultValue $null
    $effectiveConfig.PostBackupScriptOnFailurePath = Get-ConfigValue -ConfigObject $JobConfig -Key 'PostBackupScriptOnFailurePath' -DefaultValue $null
    $effectiveConfig.PostBackupScriptAlwaysPath = Get-ConfigValue -ConfigObject $JobConfig -Key 'PostBackupScriptAlwaysPath' -DefaultValue $null

    $reportData.SourcePath = if ($effectiveConfig.OriginalSourcePath -is [array]) {$effectiveConfig.OriginalSourcePath} else {@($effectiveConfig.OriginalSourcePath)}
    $reportData.VSSUsed = $effectiveConfig.JobEnableVSS
    $reportData.RetriesEnabled = $effectiveConfig.JobEnableRetries
    $reportData.ArchiveTested = $effectiveConfig.JobTestArchiveAfterCreation
    $reportData.SevenZipPriority = $effectiveConfig.JobSevenZipProcessPriority

    $effectiveConfig.GlobalConfigRef = $GlobalConfig

    return $effectiveConfig
}
#endregion

#region --- Private Helper: Construct 7-Zip Arguments ---
function Get-PoShBackup7ZipArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$EffectiveConfig,
        [Parameter(Mandatory)] [string]$FinalArchivePath,
        [Parameter(Mandatory)] [object]$CurrentJobSourcePathFor7Zip,
        [Parameter(Mandatory=$false)]
        [string]$TempPasswordFile = $null # PSAvoidUsingPlainTextForPassword rule excluded globally in PSScriptAnalyzerSettings.psd1
    )
    $sevenZipArgs = [System.Collections.Generic.List[string]]::new()
    $sevenZipArgs.Add("a")

    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobArchiveType)) { $sevenZipArgs.Add($EffectiveConfig.JobArchiveType) }
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobCompressionLevel)) { $sevenZipArgs.Add($EffectiveConfig.JobCompressionLevel) }
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobCompressionMethod)) { $sevenZipArgs.Add($EffectiveConfig.JobCompressionMethod) }
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobDictionarySize)) { $sevenZipArgs.Add($EffectiveConfig.JobDictionarySize) }
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobWordSize)) { $sevenZipArgs.Add($EffectiveConfig.JobWordSize) }
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobSolidBlockSize)) { $sevenZipArgs.Add($EffectiveConfig.JobSolidBlockSize) }
    if ($EffectiveConfig.JobCompressOpenFiles) { $sevenZipArgs.Add("-ssw") }
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.ThreadsSetting)) {$sevenZipArgs.Add($EffectiveConfig.ThreadsSetting) }

    $sevenZipArgs.Add((Get-ConfigValue -ConfigObject $EffectiveConfig.GlobalConfigRef -Key 'DefaultScriptExcludeRecycleBin' -DefaultValue '-x!$RECYCLE.BIN'))
    $sevenZipArgs.Add((Get-ConfigValue -ConfigObject $EffectiveConfig.GlobalConfigRef -Key 'DefaultScriptExcludeSysVolInfo' -DefaultValue '-x!System Volume Information'))

    if ($EffectiveConfig.JobAdditionalExclusions -is [array] -and $EffectiveConfig.JobAdditionalExclusions.Count -gt 0) {
        $EffectiveConfig.JobAdditionalExclusions | ForEach-Object {
            if (-not [string]::IsNullOrWhiteSpace($_)) {
                $exclusion = $_.Trim()
                if (-not ($exclusion.StartsWith("-x!") -or $exclusion.StartsWith("-xr!") -or $exclusion.StartsWith("-i!") -or $exclusion.StartsWith("-ir!"))) {
                    $exclusion = "-x!$($exclusion)"
                }
                $sevenZipArgs.Add($exclusion)
            }
        }
    }

    if ($EffectiveConfig.PasswordInUseFor7Zip) {
        $sevenZipArgs.Add("-mhe=on")
        if (-not [string]::IsNullOrWhiteSpace($TempPasswordFile)) {
            $sevenZipArgs.Add("-spf`"$TempPasswordFile`"")
        } else {
            Write-LogMessage "[WARNING] PasswordInUseFor7Zip is true but no temp password file provided to 7-Zip; password will not be applied." -Level WARNING
        }
    }

    if ([string]::IsNullOrWhiteSpace($FinalArchivePath)) {
        Write-LogMessage "[CRITICAL] FinalArchivePath is NULL or EMPTY in Get-PoShBackup7ZipArgument. 7-Zip may use a default name or fail." -Level ERROR
    }
    $sevenZipArgs.Add($FinalArchivePath)

    if ($CurrentJobSourcePathFor7Zip -is [array]) {
        $CurrentJobSourcePathFor7Zip | ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_)) {$sevenZipArgs.Add($_)} }
    } elseif (-not [string]::IsNullOrWhiteSpace($CurrentJobSourcePathFor7Zip)) {
        $sevenZipArgs.Add($CurrentJobSourcePathFor7Zip)
    }
    return $sevenZipArgs.ToArray()
}
#endregion

#region --- Main Job Processing Function ---
function Invoke-PoShBackupJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$JobName,

        [Parameter(Mandatory)]
        [hashtable]$JobConfig,

        [Parameter(Mandatory)]
        [hashtable]$GlobalConfig,

        [Parameter(Mandatory)]
        [hashtable]$CliOverrides,

        [Parameter(Mandatory)]
        [string]$PSScriptRootForPaths,

        [Parameter(Mandatory)]
        [string]$ActualConfigFile,

        [Parameter(Mandatory)]
        [ref]$JobReportDataRef,

        [Parameter(Mandatory=$false)]
        [switch]$IsSimulateMode
    )

    $currentJobStatus = "SUCCESS"
    $tempPasswordFilePath = $null
    $FinalArchivePath = $null
    $VSSPathsInUse = $null
    $reportData = $JobReportDataRef.Value
    $reportData.IsSimulationReport = $IsSimulateMode.IsPresent

    if (-not ($reportData.PSObject.Properties.Name -contains 'ScriptStartTime')) {
        $reportData['ScriptStartTime'] = Get-Date
    }

    $plainTextPasswordForJob = $null

    try {
        $effectiveJobConfig = Get-PoShBackupJobEffectiveConfiguration -JobConfig $JobConfig -GlobalConfig $GlobalConfig -CliOverrides $CliOverrides -JobReportDataRef $JobReportDataRef

        Write-LogMessage " - Job Settings for '$JobName' (derived):"
        Write-LogMessage "   - Effective Source Path(s): $(if ($effectiveJobConfig.OriginalSourcePath -is [array]) {$effectiveJobConfig.OriginalSourcePath -join '; '} else {$effectiveJobConfig.OriginalSourcePath})"
        Write-LogMessage "   - Destination Directory  : $($effectiveJobConfig.DestinationDir)"
        Write-LogMessage "   - Archive Base Name      : $($effectiveJobConfig.BaseFileName)"
        Write-LogMessage "   - ArchivePasswordMethod  : $($effectiveJobConfig.ArchivePasswordMethod)"


        if ([string]::IsNullOrWhiteSpace($effectiveJobConfig.DestinationDir)) {
            Write-LogMessage "FATAL: Destination directory for job '$JobName' is not defined. Cannot proceed." -Level ERROR; throw "DestinationDir missing for job '$JobName'."
        }
        if (-not (Test-Path -LiteralPath $effectiveJobConfig.DestinationDir -PathType Container)) {
            Write-LogMessage "[INFO] Destination directory '$($effectiveJobConfig.DestinationDir)' for job '$JobName' does not exist. Attempting to create..."
            if (-not $IsSimulateMode.IsPresent) {
                try { New-Item -Path $effectiveJobConfig.DestinationDir -ItemType Directory -Force -ErrorAction Stop | Out-Null; Write-LogMessage "  - Destination directory created successfully." -Level SUCCESS }
                catch { Write-LogMessage "FATAL: Failed to create destination directory '$($effectiveJobConfig.DestinationDir)'. Error: $($_.Exception.Message)" -Level ERROR; throw "Failed to create destination directory for job '$JobName'." }
            } else {
                Write-LogMessage "SIMULATE: Would create destination directory '$($effectiveJobConfig.DestinationDir)'." -Level SIMULATE
            }
        }

        $passwordResult = $null
        $isPasswordRequiredOrConfigured = ($effectiveJobConfig.ArchivePasswordMethod.ToString().ToUpperInvariant() -ne "NONE") -or $effectiveJobConfig.UsePassword
        $effectiveJobConfig.PasswordInUseFor7Zip = $false

        if ($isPasswordRequiredOrConfigured) {
            try {
                $passwordManagerModulePath = Join-Path -Path $PSScriptRootForPaths -ChildPath "Modules\PasswordManager.psm1"
                if (-not (Test-Path -LiteralPath $passwordManagerModulePath -PathType Leaf)) {
                    throw "PasswordManager.psm1 module not found at '$passwordManagerModulePath'. This module is required for password handling."
                }
                Import-Module -Name $passwordManagerModulePath -Force -ErrorAction Stop

                $passwordParams = @{
                    JobConfigForPassword = $effectiveJobConfig
                    JobName              = $JobName
                    IsSimulateMode       = $IsSimulateMode.IsPresent
                    Logger               = ${function:Write-LogMessage}
                }
                $passwordResult = Get-PoShBackupArchivePassword @passwordParams

                $reportData.PasswordSource = $passwordResult.PasswordSource

                if ($null -ne $passwordResult -and (-not [string]::IsNullOrWhiteSpace($passwordResult.PlainTextPassword))) {
                    $plainTextPasswordForJob = $passwordResult.PlainTextPassword
                    $effectiveJobConfig.PasswordInUseFor7Zip = $true

                    if ($IsSimulateMode.IsPresent) {
                        $tempPasswordFilePath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "simulated_poshbackup_pass.tmp")
                        Write-LogMessage "SIMULATE: Would write password (obtained via $($reportData.PasswordSource)) to temporary file '$tempPasswordFilePath'." -Level SIMULATE
                    } else {
                        $tempPasswordFilePath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
                        Set-Content -Path $tempPasswordFilePath -Value $plainTextPasswordForJob -Encoding UTF8 -Force -ErrorAction Stop
                        Write-LogMessage "   - Password (obtained via $($reportData.PasswordSource)) written to temporary file '$tempPasswordFilePath' for 7-Zip." -Level DEBUG
                    }
                } elseif ($isPasswordRequiredOrConfigured -and $effectiveJobConfig.ArchivePasswordMethod.ToString().ToUpperInvariant() -ne "NONE" -and (-not $IsSimulateMode.IsPresent)) {
                     Write-LogMessage "FATAL: Password was required for job '$JobName' via method '$($effectiveJobConfig.ArchivePasswordMethod)' but could not be obtained/is empty (after Get-PoShBackupArchivePassword)." -Level ERROR
                     throw "Password unavailable/empty for job '$JobName' using method '$($effectiveJobConfig.ArchivePasswordMethod)'."
                }
            } catch {
                Write-LogMessage "FATAL: Error during password retrieval process for job '$JobName'. Error: $($_.Exception.ToString())" -Level ERROR
                throw
            }
        } elseif ($effectiveJobConfig.ArchivePasswordMethod.ToString().ToUpperInvariant() -eq "NONE") {
            $reportData.PasswordSource = "None (Explicitly Configured)"
        }

        Invoke-HookScript -ScriptPath $effectiveJobConfig.PreBackupScriptPath -HookType "PreBackup" `
                          -HookParameters @{ JobName = $JobName; Status = "PreBackup"; ConfigFile = $ActualConfigFile; SimulateMode = $IsSimulateMode.IsPresent } `
                          -IsSimulateMode:$IsSimulateMode

        $currentJobSourcePathFor7Zip = $effectiveJobConfig.OriginalSourcePath
        if ($effectiveJobConfig.JobEnableVSS) {
            Write-LogMessage "`n[INFO] VSS enabled for job '$JobName'." -Level "VSS"
            if (-not (Test-AdminPrivilege)) { Write-LogMessage "FATAL: VSS requires Administrator privileges for job '$JobName'." -Level ERROR; throw "VSS requires Administrator privileges for job '$JobName'." }

            $vssParams = @{
                SourcePathsToShadow = if ($effectiveJobConfig.OriginalSourcePath -is [array]) {$effectiveJobConfig.OriginalSourcePath} else {@($effectiveJobConfig.OriginalSourcePath)}
                VSSContextOption = $effectiveJobConfig.JobVSSContextOption
                MetadataCachePath = $effectiveJobConfig.VSSMetadataCachePath
                PollingTimeoutSeconds = $effectiveJobConfig.VSSPollingTimeoutSeconds
                PollingIntervalSeconds = $effectiveJobConfig.VSSPollingIntervalSeconds
                IsSimulateMode = $IsSimulateMode.IsPresent
            }
            $VSSPathsInUse = New-VSSShadowCopy @vssParams

            if ($null -eq $VSSPathsInUse -or $VSSPathsInUse.Count -eq 0) {
                if (-not $IsSimulateMode.IsPresent) {
                    Write-LogMessage "[ERROR] VSS shadow copy creation failed or returned no paths for job '$JobName'. Using original source paths." -Level ERROR; $reportData.VSSStatus = "Failed to create/map shadows"
                } else {
                     Write-LogMessage "SIMULATE: VSS shadow copy creation would have been attempted for job '$JobName'. Assuming original paths for simulation." -Level SIMULATE; $reportData.VSSStatus = "Simulated (No Shadows Created/Needed)"
                }
            } else {
                Write-LogMessage "  - VSS shadow copies successfully created/mapped for job '$JobName'. Using shadow paths for backup." -Level VSS
                $currentJobSourcePathFor7Zip = if ($effectiveJobConfig.OriginalSourcePath -is [array]) {
                    $effectiveJobConfig.OriginalSourcePath | ForEach-Object {
                        if ($VSSPathsInUse.ContainsKey($_)) { $VSSPathsInUse[$_] } else { $_ }
                    }
                } else {
                    if ($VSSPathsInUse.ContainsKey($effectiveJobConfig.OriginalSourcePath)) { $VSSPathsInUse[$effectiveJobConfig.OriginalSourcePath] } else { $effectiveJobConfig.OriginalSourcePath }
                }
                $reportData.VSSStatus = if ($IsSimulateMode.IsPresent) { "Simulated (Used)" } else { "Used" }
                $reportData.VSSShadowPaths = $VSSPathsInUse
            }
        } else { $reportData.VSSStatus = "Not Enabled" }
        $reportData.EffectiveSourcePath = if ($currentJobSourcePathFor7Zip -is [array]) {$currentJobSourcePathFor7Zip} else {@($currentJobSourcePathFor7Zip)}

        Write-LogMessage "`n[INFO] Performing Pre-Backup Operations for job '$JobName'..."
        Write-LogMessage "   - Using source(s) for 7-Zip: $(if ($currentJobSourcePathFor7Zip -is [array]) {($currentJobSourcePathFor7Zip | Where-Object {$_}) -join '; '} else {$currentJobSourcePathFor7Zip})"

        if (-not (Test-DestinationFreeSpace -DestDir $effectiveJobConfig.DestinationDir -MinRequiredGB $effectiveJobConfig.JobMinimumRequiredFreeSpaceGB -ExitOnLow $effectiveJobConfig.JobExitOnLowSpace -IsSimulateMode:$IsSimulateMode)) {
            throw "Low disk space condition met for job '$JobName'."
        }

        $DateString = Get-Date -Format $effectiveJobConfig.JobArchiveDateFormat
        $ArchiveFileName = "$($effectiveJobConfig.BaseFileName) [$DateString]$($effectiveJobConfig.JobArchiveExtension)"
        $FinalArchivePath = Join-Path -Path $effectiveJobConfig.DestinationDir -ChildPath $ArchiveFileName
        $reportData.FinalArchivePath = $FinalArchivePath
        Write-LogMessage "`n[INFO] Target Archive for job '$JobName': $FinalArchivePath"

        $vbLoaded = $false
        if ($effectiveJobConfig.DeleteToRecycleBin) {
            try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop; $vbLoaded = $true }
            catch { Write-LogMessage "[WARNING] Failed to load Microsoft.VisualBasic assembly for Recycle Bin. Error: $($_.Exception.Message)" -Level WARNING }
        }
        Invoke-BackupRetentionPolicy -DestinationDirectory $effectiveJobConfig.DestinationDir `
                                     -ArchiveBaseFileName $effectiveJobConfig.BaseFileName `
                                     -ArchiveExtension $effectiveJobConfig.JobArchiveExtension `
                                     -RetentionCountToKeep $effectiveJobConfig.RetentionCount `
                                     -SendToRecycleBin $effectiveJobConfig.DeleteToRecycleBin `
                                     -VBAssemblyLoaded $vbLoaded `
                                     -IsSimulateMode:$IsSimulateMode

        $sevenZipArgsArray = Get-PoShBackup7ZipArgument -EffectiveConfig $effectiveJobConfig `
                                                        -FinalArchivePath $FinalArchivePath `
                                                        -CurrentJobSourcePathFor7Zip $currentJobSourcePathFor7Zip `
                                                        -TempPasswordFile $tempPasswordFilePath

        $sevenZipPathGlobal = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'SevenZipPath'
        $zipOpParams = @{
            SevenZipPathExe = $sevenZipPathGlobal; SevenZipArguments = $sevenZipArgsArray
            ProcessPriority = $effectiveJobConfig.JobSevenZipProcessPriority; HideOutput = $effectiveJobConfig.HideSevenZipOutput
            MaxRetries = $effectiveJobConfig.JobMaxRetryAttempts; RetryDelaySeconds = $effectiveJobConfig.JobRetryDelaySeconds
            EnableRetries = $effectiveJobConfig.JobEnableRetries; IsSimulateMode = $IsSimulateMode.IsPresent
        }
        $sevenZipResult = Invoke-7ZipOperation @zipOpParams

        $reportData.SevenZipExitCode = $sevenZipResult.ExitCode
        $reportData.CompressionTime = if ($null -ne $sevenZipResult.ElapsedTime) {$sevenZipResult.ElapsedTime.ToString()} else {"N/A"}
        $reportData.RetryAttemptsMade = $sevenZipResult.AttemptsMade

        $archiveSize = "N/A (Simulated)"
        if (-not $IsSimulateMode.IsPresent -and (Test-Path -LiteralPath $FinalArchivePath -PathType Leaf)) {
             $archiveSize = Get-ArchiveSizeFormatted -PathToArchive $FinalArchivePath
        } elseif ($IsSimulateMode.IsPresent) {
            $archiveSize = "0 Bytes (Simulated)"
        }
        $reportData.ArchiveSizeFormatted = $archiveSize

        if ($sevenZipResult.ExitCode -eq 0) { $currentJobStatus = "SUCCESS" }
        elseif ($sevenZipResult.ExitCode -eq 1) { $currentJobStatus = "WARNINGS" }
        else { $currentJobStatus = "FAILURE" }

        $reportData.ArchiveTested = $effectiveJobConfig.JobTestArchiveAfterCreation
        if ($effectiveJobConfig.JobTestArchiveAfterCreation -and ($currentJobStatus -eq "SUCCESS") -and (-not $IsSimulateMode.IsPresent) -and (Test-Path -LiteralPath $FinalArchivePath -PathType Leaf)) {
            $testArchiveParams = @{
                SevenZipPathExe = $sevenZipPathGlobal; ArchivePath = $FinalArchivePath
                TempPasswordFile = $tempPasswordFilePath
                ProcessPriority = $effectiveJobConfig.JobSevenZipProcessPriority; HideOutput = $effectiveJobConfig.HideSevenZipOutput
                MaxRetries = $effectiveJobConfig.JobMaxRetryAttempts; RetryDelaySeconds = $effectiveJobConfig.JobRetryDelaySeconds
                EnableRetries = $effectiveJobConfig.JobEnableRetries
            }
            $testResult = Test-7ZipArchive @testArchiveParams

            if ($testResult.ExitCode -eq 0) {
                $reportData.ArchiveTestResult = "PASSED"
            } else {
                $reportData.ArchiveTestResult = "FAILED (Code $($testResult.ExitCode))"
                if ($currentJobStatus -ne "FAILURE") {$currentJobStatus = "WARNINGS"}
            }
            $reportData.TestRetryAttemptsMade = $testResult.AttemptsMade
        } elseif ($effectiveJobConfig.JobTestArchiveAfterCreation) {
             $reportData.ArchiveTestResult = if($IsSimulateMode.IsPresent){"Not Performed (Simulated)"} else {"Not Performed (Archive Missing or Compression Error)"}
        } else {
            $reportData.ArchiveTestResult = "Not Configured"
        }

    } catch {
        Write-LogMessage "ERROR during processing of job '$JobName': $($_.Exception.ToString())" -Level ERROR
        $currentJobStatus = "FAILURE"
        $reportData.ErrorMessage = $_.Exception.ToString()
    } finally {
        if ($null -ne $VSSPathsInUse) {
            Remove-VSSShadowCopy -IsSimulateMode:$IsSimulateMode.IsPresent
        }

        if (-not [string]::IsNullOrWhiteSpace($plainTextPasswordForJob)) {
            try {
                $plainTextPasswordForJob = $null
                Clear-Variable plainTextPasswordForJob -Scope Script -ErrorAction SilentlyContinue
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
                Write-LogMessage "   - Plain text password for job cleared from Operations module memory." -Level DEBUG
            } catch { Write-LogMessage "[WARNING] Exception while clearing plain text password from Operations module memory. Error: $($_.Exception.Message)" -Level WARNING }
        }
        if (-not [string]::IsNullOrWhiteSpace($tempPasswordFilePath) -and (Test-Path -LiteralPath $tempPasswordFilePath -PathType Leaf) `
            -and -not ($IsSimulateMode.IsPresent -and $tempPasswordFilePath.EndsWith("simulated_poshbackup_pass.tmp")) ) {
            try {
                Remove-Item -LiteralPath $tempPasswordFilePath -Force -ErrorAction Stop
                Write-LogMessage "   - Temporary password file '$tempPasswordFilePath' deleted." -Level DEBUG
            }
            catch { Write-LogMessage "[WARNING] Failed to delete temporary password file '$tempPasswordFilePath'. Manual deletion may be required. Error: $($_.Exception.Message)" -Level "WARNING" }
        }

        if ($IsSimulateMode.IsPresent -and $currentJobStatus -ne "FAILURE") {
            $reportData.OverallStatus = "SIMULATED_COMPLETE"
        } else {
            $reportData.OverallStatus = $currentJobStatus
        }

        $reportData.ScriptEndTime = Get-Date
        if (($reportData.PSObject.Properties.Name -contains 'ScriptStartTime') -and ($null -ne $reportData.ScriptStartTime)) {
            $reportData.TotalDuration = $reportData.ScriptEndTime - $reportData.ScriptStartTime
        } else {
            $reportData.TotalDuration = "N/A (Start time missing)"
        }

        $hookArgsForExternalScript = @{
            JobName = $JobName; Status = $reportData.OverallStatus; ArchivePath = $FinalArchivePath;
            ConfigFile = $ActualConfigFile; SimulateMode = $IsSimulateMode.IsPresent
        }

        if ($reportData.OverallStatus -in @("SUCCESS", "WARNINGS", "SIMULATED_COMPLETE") ) {
            Invoke-HookScript -ScriptPath $effectiveJobConfig.PostBackupScriptOnSuccessPath -HookType "PostBackupOnSuccess" -HookParameters $hookArgsForExternalScript -IsSimulateMode:$IsSimulateMode.IsPresent
        } else {
            Invoke-HookScript -ScriptPath $effectiveJobConfig.PostBackupScriptOnFailurePath -HookType "PostBackupOnFailure" -HookParameters $hookArgsForExternalScript -IsSimulateMode:$IsSimulateMode.IsPresent
        }
        Invoke-HookScript -ScriptPath $effectiveJobConfig.PostBackupScriptAlwaysPath -HookType "PostBackupAlways" -HookParameters $hookArgsForExternalScript -IsSimulateMode:$IsSimulateMode.IsPresent
    }

    return @{ Status = $currentJobStatus }
}
#endregion

#region --- VSS Functions ---
$Script:ScriptRunVSSShadowIDs = @{}

function New-VSSShadowCopy {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory)] [string[]]$SourcePathsToShadow,
        [Parameter(Mandatory)] [string]$VSSContextOption,
        [Parameter(Mandatory)] [string]$MetadataCachePath,
        [Parameter(Mandatory)] [int]$PollingTimeoutSeconds,
        [Parameter(Mandatory)] [int]$PollingIntervalSeconds,
        [Parameter(Mandatory)] [switch]$IsSimulateMode
    )
    $runKey = $PID
    if (-not $Script:ScriptRunVSSShadowIDs.ContainsKey($runKey)) {
        $Script:ScriptRunVSSShadowIDs[$runKey] = @{}
    }
    $currentRunShadowIDsForThisVSScall = $Script:ScriptRunVSSShadowIDs[$runKey]

    Write-LogMessage "`n[INFO] Initialising Volume Shadow Copy Service (VSS)..." -Level "VSS"
    $mappedShadowPaths = @{}

    $volumesToShadow = $SourcePathsToShadow | ForEach-Object {
        try { (Get-Item -LiteralPath $_ -ErrorAction Stop).PSDrive.Name + ":" } catch { Write-LogMessage "[WARNING] Could not determine volume for source path '$_'. Skipping for VSS." -Level WARNING; $null }
    } | Where-Object {$null -ne $_} | Select-Object -Unique

    if ($volumesToShadow.Count -eq 0) { Write-LogMessage "[WARNING] No valid volumes found to create shadow copies for." -Level WARNING; return $null }

    $diskshadowScriptContent = @"
SET CONTEXT $VSSContextOption
SET METADATA CACHE "$MetadataCachePath"
SET VERBOSE ON
$($volumesToShadow | ForEach-Object { "ADD VOLUME $_ ALIAS Vol_$($_ -replace ':','')" })
CREATE
"@
    $tempDiskshadowScriptFile = Join-Path -Path $env:TEMP -ChildPath "diskshadow_create_backup_$(Get-Random).txt"
    try { $diskshadowScriptContent | Set-Content -Path $tempDiskshadowScriptFile -Encoding UTF8 -ErrorAction Stop }
    catch { Write-LogMessage "[ERROR] Failed to write diskshadow script to '$tempDiskshadowScriptFile'. Error: $($_.Exception.Message)" -Level ERROR; return $null }

    Write-LogMessage "  - Generated diskshadow script: $tempDiskshadowScriptFile (Context: $VSSContextOption, Cache: $MetadataCachePath)" -Level VSS

    if ($IsSimulateMode.IsPresent) {
        Write-LogMessage "SIMULATE: Would execute diskshadow with script '$tempDiskshadowScriptFile' to create shadow copies for volumes: $($volumesToShadow -join ', ')" -Level SIMULATE
        $SourcePathsToShadow | ForEach-Object {
            $currentSourcePath = $_
            try {
                $vol = (Get-Item -LiteralPath $currentSourcePath -ErrorAction Stop).PSDrive.Name + ":"
                $relativePathSimulated = $currentSourcePath -replace [regex]::Escape($vol), ""
                $simulatedIndex = [array]::IndexOf($SourcePathsToShadow, $currentSourcePath) + 1
                if ($simulatedIndex -le 0) { $simulatedIndex = Get-Random -Minimum 1 -Maximum 999 }
                $mappedShadowPaths[$currentSourcePath] = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopySIMULATED$($simulatedIndex)$relativePathSimulated"
            } catch {
                 Write-LogMessage "SIMULATE: Could not get volume for '$currentSourcePath' to create simulated shadow path." -Level SIMULATE
                 $mappedShadowPaths[$currentSourcePath] = "$currentSourcePath (Simulated - Original Path)"
            }
        }
        Remove-Item -LiteralPath $tempDiskshadowScriptFile -Force -ErrorAction SilentlyContinue
        return $mappedShadowPaths
    }

    Write-LogMessage "  - Executing diskshadow to create shadow copies. This may take a moment..." -Level VSS
    $process = Start-Process -FilePath "diskshadow.exe" -ArgumentList "/s `"$tempDiskshadowScriptFile`"" -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$null" -RedirectStandardError "$null"
    Remove-Item -LiteralPath $tempDiskshadowScriptFile -Force -ErrorAction SilentlyContinue

    if ($process.ExitCode -ne 0) {
        Write-LogMessage "[ERROR] diskshadow.exe failed to create shadow copies. Exit Code: $($process.ExitCode)" -Level ERROR
        return $null
    }

    Write-LogMessage "  - Shadow copy creation command completed. Polling WMI for shadow details (Timeout: ${PollingTimeoutSeconds}s)..." -Level VSS

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $allVolumesShadowed = $false
    $foundShadowsForThisCall = @{}

    while ($stopwatch.Elapsed.TotalSeconds -lt $PollingTimeoutSeconds) {
        # PSUseCIMToolingForWin32Namespace rule excluded globally in PSScriptAnalyzerSettings.psd1
        $wmiShadowsThisPoll = Get-WmiObject Win32_ShadowCopy -ErrorAction SilentlyContinue |
                              Where-Object { $_.InstallDate -gt (Get-Date).AddMinutes(-5) }

        if ($null -ne $wmiShadowsThisPoll) {
            foreach ($volName in $volumesToShadow) {
                if (-not $foundShadowsForThisCall.ContainsKey($volName)) {
                    $candidateShadow = $wmiShadowsThisPoll |
                                       Where-Object { $_.VolumeName -eq $volName -and (-not $currentRunShadowIDsForThisVSScall.ContainsValue($_.ID)) } |
                                       Sort-Object InstallDate -Descending |
                                       Select-Object -First 1

                    if ($null -ne $candidateShadow) {
                        Write-LogMessage "  - Found shadow for '$volName': Device '$($candidateShadow.DeviceObject)' (ID: $($candidateShadow.ID))" -Level VSS
                        $currentRunShadowIDsForThisVSScall[$volName] = $candidateShadow.ID
                        $foundShadowsForThisCall[$volName] = $candidateShadow.DeviceObject
                    }
                }
            }
        }

        if ($foundShadowsForThisCall.Keys.Count -eq $volumesToShadow.Count) {
            $allVolumesShadowed = $true
            break
        }

        Start-Sleep -Seconds $PollingIntervalSeconds
        Write-LogMessage "  - Polling WMI for shadow copies... ($([math]::Round($stopwatch.Elapsed.TotalSeconds))s / ${PollingTimeoutSeconds}s)" -Level "VSS" -NoTimestampToLogFile ($stopwatch.Elapsed.TotalSeconds -ge $PollingIntervalSeconds)
    }
    $stopwatch.Stop()

    if (-not $allVolumesShadowed) {
        Write-LogMessage "[ERROR] Timed out or failed to find all required shadow copies via WMI after $PollingTimeoutSeconds seconds." -Level ERROR
        $foundShadowsForThisCall.Keys | ForEach-Object {
            $volNameToClean = $_
            if ($currentRunShadowIDsForThisVSScall.ContainsKey($volNameToClean)) {
                Remove-VSSShadowCopyById -ShadowID $currentRunShadowIDsForThisVSScall[$volNameToClean] -IsSimulateMode:$IsSimulateMode
                $currentRunShadowIDsForThisVSScall.Remove($volNameToClean)
            }
        }
        return $null
    }

    $SourcePathsToShadow | ForEach-Object {
        $originalFullPath = $_
        try {
            $volNameOfPath = (Get-Item -LiteralPath $originalFullPath -ErrorAction Stop).PSDrive.Name + ":"
            if ($foundShadowsForThisCall.ContainsKey($volNameOfPath)) {
                $shadowDevicePath = $foundShadowsForThisCall[$volNameOfPath]
                $relativePath = $originalFullPath -replace [regex]::Escape($volNameOfPath), ""
                $mappedShadowPaths[$originalFullPath] = Join-Path -Path $shadowDevicePath -ChildPath $relativePath.TrimStart('\')
                Write-LogMessage "    - Mapped '$originalFullPath' to '$($mappedShadowPaths[$originalFullPath])'" -Level VSS
            } else {
                Write-LogMessage "[WARNING] Could not map source path '$originalFullPath' as its volume shadow ('$volNameOfPath') was not definitively found or mapped." -Level WARNING
            }
        } catch {
            Write-LogMessage "[WARNING] Error processing source path '$originalFullPath' for VSS mapping: $($_.Exception.Message)" -Level WARNING
        }
    }

    if ($mappedShadowPaths.Count -eq 0 -and $SourcePathsToShadow.Count -gt 0) {
         Write-LogMessage "[ERROR] Failed to map ANY source paths to shadow paths, though shadow creation command succeeded." -Level ERROR
         return $null
    }
    if ($mappedShadowPaths.Count -lt $SourcePathsToShadow.Count) {
        Write-LogMessage "[WARNING] Not all source paths could be mapped to shadow paths. VSS may be incomplete for this job." -Level WARNING
    }
    return $mappedShadowPaths
}

function Remove-VSSShadowCopyById {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param (
        [Parameter(Mandatory)] [string]$ShadowID,
        [Parameter(Mandatory)] [switch]$IsSimulateMode
    )
    if ($PSCmdlet.ShouldProcess("Shadow ID $ShadowID", "Delete using diskshadow")) {
        Write-LogMessage "  - Attempting cleanup of specific shadow ID: $ShadowID" -Level VSS
        $diskshadowScriptContentSingle = "SET VERBOSE ON`nDELETE SHADOWS ID $ShadowID`n"
        $tempScriptPathSingle = Join-Path -Path $env:TEMP -ChildPath "diskshadow_delete_single_$(Get-Random).txt"
        try { $diskshadowScriptContentSingle | Set-Content -Path $tempScriptPathSingle -Encoding UTF8 -ErrorAction Stop }
        catch { Write-LogMessage "[ERROR] Failed to write single shadow delete script. Error: $($_.Exception.Message)" -Level ERROR; return}

        if (-not $IsSimulateMode.IsPresent) {
            $procDeleteSingle = Start-Process -FilePath "diskshadow.exe" -ArgumentList "/s `"$tempScriptPathSingle`"" -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$null" -RedirectStandardError "$null"
            if ($procDeleteSingle.ExitCode -ne 0) {
                Write-LogMessage "[WARNING] diskshadow.exe failed to delete specific shadow ID $ShadowID. Exit Code: $($procDeleteSingle.ExitCode)" -Level WARNING
            }
        } else {
             Write-LogMessage "SIMULATE: Would execute diskshadow to delete shadow ID $ShadowID." -Level SIMULATE
        }
        Remove-Item -LiteralPath $tempScriptPathSingle -Force -ErrorAction SilentlyContinue
    }
}

function Remove-VSSShadowCopy {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory)] [switch]$IsSimulateMode
    )
    $runKey = $PID
    if (-not $Script:ScriptRunVSSShadowIDs.ContainsKey($runKey) -or $Script:ScriptRunVSSShadowIDs[$runKey].Count -eq 0) {
        Write-LogMessage "`n[INFO] No VSS Shadow IDs for current run (PID $runKey) to remove or already cleared." -Level VSS
        return
    }
    $shadowIdMapForRun = $Script:ScriptRunVSSShadowIDs[$runKey]
    Write-LogMessage "`n[INFO] Removing VSS Shadow Copies for current run (PID $runKey)..." -Level VSS
    $shadowIdsToRemove = $shadowIdMapForRun.Values | Select-Object -Unique

    if ($shadowIdsToRemove.Count -eq 0) {
        Write-LogMessage "  - No unique shadow IDs found to remove for this run." -Level VSS
        $shadowIdMapForRun.Clear()
        return
    }

    if ($PSCmdlet.ShouldProcess("Shadow IDs: $($shadowIdsToRemove -join ', ')", "Delete All using diskshadow")) {
        $diskshadowScriptContentAll = "SET VERBOSE ON`n"
        $shadowIdsToRemove | ForEach-Object { $diskshadowScriptContentAll += "DELETE SHADOWS ID $_`n" }
        $tempScriptPathAll = Join-Path -Path $env:TEMP -ChildPath "diskshadow_delete_all_$(Get-Random).txt"
        try { $diskshadowScriptContentAll | Set-Content -Path $tempScriptPathAll -Encoding UTF8 -ErrorAction Stop }
        catch { Write-LogMessage "[ERROR] Failed to write diskshadow delete script. Error: $($_.Exception.Message)" -Level ERROR; return }

        Write-LogMessage "  - Generated diskshadow deletion script: $tempScriptPathAll" -Level VSS

        if (-not $IsSimulateMode.IsPresent) {
            Write-LogMessage "  - Executing diskshadow to delete shadow copies..." -Level VSS
            $processDeleteAll = Start-Process -FilePath "diskshadow.exe" -ArgumentList "/s `"$tempScriptPathAll`"" -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$null" -RedirectStandardError "$null"
            if ($processDeleteAll.ExitCode -ne 0) {
                Write-LogMessage "[ERROR] diskshadow.exe failed to delete one or more shadow copies. Exit Code: $($processDeleteAll.ExitCode)" -Level ERROR
                Write-LogMessage "  - Manual deletion may be needed for ID(s): $($shadowIdsToRemove -join ', ')" -Level ERROR
            } else {
                Write-LogMessage "  - Shadow copy deletion process completed successfully." -Level VSS
            }
        } else {
            Write-LogMessage "SIMULATE: Would execute diskshadow to delete shadow IDs: $($shadowIdsToRemove -join ', ')." -Level SIMULATE
        }
        Remove-Item -LiteralPath $tempScriptPathAll -Force -ErrorAction SilentlyContinue
    }
    $shadowIdMapForRun.Clear()
}
#endregion

#region --- 7-Zip Operations ---
function Invoke-7ZipOperation {
    [CmdletBinding()]
    param(
        [string]$SevenZipPathExe,
        [array]$SevenZipArguments,
        [string]$ProcessPriority = "Normal",
        [switch]$HideOutput,
        [switch]$IsSimulateMode,
        [int]$MaxRetries = 1,
        [int]$RetryDelaySeconds = 60,
        [bool]$EnableRetries = $false
    )

    $currentTry = 0
    $actualMaxTries = if ($EnableRetries) { [math]::Max(1, $MaxRetries) } else { 1 }
    $actualDelaySeconds = if ($EnableRetries -and $actualMaxTries -gt 1) { $RetryDelaySeconds } else { 0 }
    $operationExitCode = -1
    $operationElapsedTime = New-TimeSpan -Seconds 0
    $attemptsMade = 0

    $argumentStringForProcess = ""
    foreach ($argItem in $SevenZipArguments) {
        if ($argItem -match "\s" -and -not (($argItem.StartsWith('"') -and $argItem.EndsWith('"')) -or ($argItem.StartsWith("'") -and $argItem.EndsWith("'")))) {
            $argumentStringForProcess += """$argItem"" "
        } else {
            $argumentStringForProcess += "$argItem "
        }
    }
    $argumentStringForProcess = $argumentStringForProcess.TrimEnd()

    while ($currentTry -lt $actualMaxTries) {
        $currentTry++; $attemptsMade = $currentTry

        if ($IsSimulateMode.IsPresent) {
            Write-LogMessage "SIMULATE: 7-Zip (Attempt $currentTry/$actualMaxTries): `"$SevenZipPathExe`" $argumentStringForProcess" -Level SIMULATE
            $operationExitCode = 0
            $operationElapsedTime = New-TimeSpan -Seconds 0
            break
        }

        Write-LogMessage "   - Attempting 7-Zip execution (Attempt $currentTry/$actualMaxTries)..."
        Write-LogMessage "     Command: `"$SevenZipPathExe`" $argumentStringForProcess" -Level DEBUG

        $validPriorities = "Idle", "BelowNormal", "Normal", "AboveNormal", "High"
        if ([string]::IsNullOrWhiteSpace($ProcessPriority) -or $ProcessPriority -notin $validPriorities) {
            Write-LogMessage "[WARNING] Invalid/empty 7-Zip priority '$ProcessPriority'. Defaulting to 'Normal'." -Level WARNING; $ProcessPriority = "Normal"
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew(); $process = $null
        try {
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $SevenZipPathExe
            $startInfo.Arguments = $argumentStringForProcess
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $HideOutput.IsPresent
            $startInfo.WindowStyle = if($HideOutput.IsPresent) { [System.Diagnostics.ProcessWindowStyle]::Hidden } else { [System.Diagnostics.ProcessWindowStyle]::Normal }

            if ($HideOutput.IsPresent) {
                $startInfo.RedirectStandardOutput = $true
                $startInfo.RedirectStandardError = $true
            }

            Write-LogMessage "  - Starting 7-Zip process with priority: $ProcessPriority" -Level DEBUG
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $startInfo
            $process.Start() | Out-Null
            try { $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]$ProcessPriority }
            catch { Write-LogMessage "[WARNING] Failed to set 7-Zip priority. Error: $($_.Exception.Message)" -Level WARNING }

            $stdOutput = ""
            $stdError = ""
            $outputTask = $null
            $errorTask = $null

            if ($HideOutput.IsPresent) {
                $outputTask = $process.StandardOutput.ReadToEndAsync()
                $errorTask = $process.StandardError.ReadToEndAsync()
            }

            $process.WaitForExit()

            if ($HideOutput.IsPresent) {
                if ($null -ne $outputTask) {
                    try { $stdOutput = $outputTask.GetAwaiter().GetResult() } catch { try { $stdOutput = $process.StandardOutput.ReadToEnd() } catch { Write-LogMessage "    - DEBUG: Fallback ReadToEnd STDOUT failed: $($_.Exception.Message)" -Level DEBUG } }
                }
                 if ($null -ne $errorTask) {
                    try { $stdError = $errorTask.GetAwaiter().GetResult() } catch { try { $stdError = $process.StandardError.ReadToEnd() } catch { Write-LogMessage "    - DEBUG: Fallback ReadToEnd STDERR failed: $($_.Exception.Message)" -Level DEBUG } }
                 }

                if (-not [string]::IsNullOrWhiteSpace($stdOutput)) {
                    Write-LogMessage "  - 7-Zip STDOUT (captured as HideSevenZipOutput is true):" -Level DEBUG
                    $stdOutput.Split([Environment]::NewLine) | ForEach-Object { Write-LogMessage "    | $_" -Level DEBUG -NoTimestampToLogFile }
                }

                if (-not [string]::IsNullOrWhiteSpace($stdError)) {
                    Write-LogMessage "  - 7-Zip STDERR:" -Level ERROR
                    $stdError.Split([Environment]::NewLine) | ForEach-Object { Write-LogMessage "    | $_" -Level ERROR -NoTimestampToLogFile }
                }
            }
            $operationExitCode = $process.ExitCode
        } catch {
            Write-LogMessage "[ERROR] Failed to start/manage 7-Zip. Error: $($_.Exception.ToString())" -Level ERROR
            $operationExitCode = -999
        } finally {
            $stopwatch.Stop()
            $operationElapsedTime = $stopwatch.Elapsed
            if ($null -ne $process) { $process.Dispose() }
        }

        Write-LogMessage "   - 7-Zip attempt $currentTry finished. Exit: $operationExitCode. Elapsed: $operationElapsedTime"
        if ($operationExitCode -in @(0,1)) { break }
        elseif ($currentTry -lt $actualMaxTries) { Write-LogMessage "[WARNING] 7-Zip failed. Retrying in $actualDelaySeconds s..." -Level WARNING; Start-Sleep -Seconds $actualDelaySeconds }
        else { Write-LogMessage "[ERROR] 7-Zip failed after $actualMaxTries attempts." -Level ERROR }
    }
    return @{ ExitCode = $operationExitCode; ElapsedTime = $operationElapsedTime; AttemptsMade = $attemptsMade }
}

function Test-7ZipArchive {
    [CmdletBinding()]
    param(
        [string]$SevenZipPathExe,
        [string]$ArchivePath,
        [Parameter(Mandatory=$false)]
        [string]$TempPasswordFile = $null, # PSAvoidUsingPlainTextForPassword rule excluded globally in PSScriptAnalyzerSettings.psd1
        [string]$ProcessPriority = "Normal",
        [switch]$HideOutput,
        [int]$MaxRetries = 1,
        [int]$RetryDelaySeconds = 60,
        [bool]$EnableRetries = $false
    )
    Write-LogMessage "`n[INFO] Performing archive integrity test for '$ArchivePath'..."
    $testArguments = [System.Collections.Generic.List[string]]::new()
    $testArguments.Add("t")
    $testArguments.Add($ArchivePath)

    if (-not [string]::IsNullOrWhiteSpace($TempPasswordFile) -and (Test-Path -LiteralPath $TempPasswordFile)) {
        $testArguments.Add("-spf`"$TempPasswordFile`"")
    }
    Write-LogMessage "   - Test Command (raw args before Invoke-7ZipOperation quoting): `"$SevenZipPathExe`" $($testArguments -join ' ')" -Level DEBUG

    $invokeParams = @{
        SevenZipPathExe = $SevenZipPathExe; SevenZipArguments = $testArguments.ToArray()
        ProcessPriority = $ProcessPriority; HideOutput = $HideOutput.IsPresent
        MaxRetries = $MaxRetries; RetryDelaySeconds = $RetryDelaySeconds; EnableRetries = $EnableRetries
        IsSimulateMode = $false
    }
    $result = Invoke-7ZipOperation @invokeParams

    $msg = if ($result.ExitCode -eq 0) { "PASSED" } else { "FAILED (Code: $($result.ExitCode))" }
    $levelForResult = if ($result.ExitCode -eq 0) { "SUCCESS" } else { "ERROR" }
    Write-LogMessage "  - Archive Test Result for '$ArchivePath': $msg" -Level $levelForResult
    return $result
}
#endregion

#region --- Private Helper: Invoke-VisualBasicFileOperation ---
function Invoke-VisualBasicFileOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [ValidateSet('DeleteFile', 'DeleteDirectory')]
        [string]$Operation,
        [Microsoft.VisualBasic.FileIO.UIOption]$UIOption = [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
        [Microsoft.VisualBasic.FileIO.RecycleOption]$RecycleOption = [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
        [Microsoft.VisualBasic.FileIO.UICancelOption]$CancelOption = [Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException
    )
    try {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
    } catch {
        Write-LogMessage "[ERROR] Failed to load Microsoft.VisualBasic assembly for Recycle Bin operation. Error: $($_.Exception.Message)" -Level ERROR
        throw "Microsoft.VisualBasic assembly could not be loaded. Recycle Bin operations unavailable."
    }

    switch ($Operation) {
        "DeleteFile"      { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, $UIOption, $RecycleOption, $CancelOption) }
        "DeleteDirectory" { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, $UIOption, $RecycleOption, $CancelOption) }
    }
}
#endregion

#region --- Backup Retention Policy ---
function Invoke-BackupRetentionPolicy {
    [CmdletBinding()]
    param(
        [string]$DestinationDirectory,
        [string]$ArchiveBaseFileName,
        [string]$ArchiveExtension,
        [int]$RetentionCountToKeep,
        [bool]$SendToRecycleBin,
        [bool]$VBAssemblyLoaded,
        [switch]$IsSimulateMode
    )
    Write-LogMessage "`n[INFO] Applying Backup Retention Policy for '$ArchiveBaseFileName' (Extension: $ArchiveExtension)..."
    Write-LogMessage "   - Destination: $DestinationDirectory"
    Write-LogMessage "   - Configured Total Retention Count (target after current backup): $RetentionCountToKeep"
    $effectiveSendToRecycleBin = $SendToRecycleBin
    if ($SendToRecycleBin -and -not $VBAssemblyLoaded) {
        Write-LogMessage "[WARNING] Recycle Bin requested but VisualBasic assembly not loaded (or failed to load). Falling back to PERMANENT deletion for retention policy." -Level WARNING
        $effectiveSendToRecycleBin = $false
    }
    Write-LogMessage "   - Effective Deletion Method: $(if ($effectiveSendToRecycleBin) {'Recycle Bin'} else {'Permanent'})"

    $literalBaseName = $ArchiveBaseFileName -replace '\*', '`*' -replace '\?', '`?'
    $filePattern = "$($literalBaseName)*$($ArchiveExtension)"

    try {
        if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
            Write-LogMessage "   - Retention SKIPPED: Destination directory '$DestinationDirectory' not found." -Level WARNING
            return
        }

        $existingBackups = Get-ChildItem -Path $DestinationDirectory -Filter $filePattern -File -ErrorAction SilentlyContinue | Sort-Object CreationTime -Descending

        if ($RetentionCountToKeep -le 0) {
            Write-LogMessage "   - Retention count is $RetentionCountToKeep; all existing backups matching the pattern will be kept (unlimited by count)." -Level INFO
            return
        }

        $numberOfOldBackupsToPreserve = $RetentionCountToKeep - 1
        if ($numberOfOldBackupsToPreserve -lt 0) { $numberOfOldBackupsToPreserve = 0 }

        if (($null -ne $existingBackups) -and ($existingBackups.Count -gt $numberOfOldBackupsToPreserve)) {
            $backupsToDelete = $existingBackups | Select-Object -Skip $numberOfOldBackupsToPreserve
            Write-LogMessage "[INFO] Found $($existingBackups.Count) existing backups. Will attempt to delete $($backupsToDelete.Count) older backup(s) to ensure $RetentionCountToKeep total archives after the current backup completes." -Level INFO
            foreach ($backupFile in $backupsToDelete) {
                Write-LogMessage "       - Identifying for deletion: $($backupFile.FullName) (Created: $($backupFile.CreationTime))"
                if ($IsSimulateMode.IsPresent) { Write-LogMessage "       - SIMULATE: Would delete '$($backupFile.FullName)'" -Level SIMULATE }
                else {
                    Write-LogMessage "       - Deleting: $($backupFile.FullName)" -Level WARNING
                    try {
                        if ($effectiveSendToRecycleBin) {
                            Invoke-VisualBasicFileOperation -Path $backupFile.FullName -Operation "DeleteFile"
                            Write-LogMessage "         - Status: MOVED TO RECYCLE BIN" -Level SUCCESS
                        } else {
                            Remove-Item -LiteralPath $backupFile.FullName -Force -ErrorAction Stop; Write-LogMessage "         - Status: DELETED PERMANENTLY" -Level SUCCESS
                        }
                    } catch { Write-LogMessage "         - Status: FAILED! Error: $($_.Exception.Message)" -Level ERROR }
                }
            }
        } elseif ($null -ne $existingBackups) {
            Write-LogMessage "   - Number of existing backups ($($existingBackups.Count)) is already at or below the target number of old backups to preserve ($numberOfOldBackupsToPreserve). No older backups to delete by count." -Level INFO
        } else {
            Write-LogMessage "   - No existing backups found matching pattern '$filePattern' in '$DestinationDirectory'." -Level INFO
        }
    } catch { Write-LogMessage "[WARNING] Error during retention check for '$ArchiveBaseFileName'. Error: $($_.Exception.Message)" -Level WARNING }
}
#endregion

#region --- Free Space Check ---
function Test-DestinationFreeSpace {
    [CmdletBinding()]
    param(
        [string]$DestDir,
        [int]$MinRequiredGB,
        [bool]$ExitOnLow,
        [switch]$IsSimulateMode
    )
    if ($MinRequiredGB -le 0) { return $true }
    Write-LogMessage "`n[INFO] Checking destination free space for '$DestDir'..."
    Write-LogMessage "   - Minimum required: $MinRequiredGB GB"

    if ($IsSimulateMode.IsPresent) {
        Write-LogMessage "SIMULATE: Would check free space. Assuming OK for simulation purposes." -Level SIMULATE
        return $true
    }

    try {
        if (-not (Test-Path -LiteralPath $DestDir -PathType Container)) {
            Write-LogMessage "[WARNING] Dest dir '$DestDir' for free space check not found. Skipping." -Level WARNING
            return $true
        }
        $driveLetter = (Get-Item -LiteralPath $DestDir).PSDrive.Name
        $destDrive = Get-PSDrive -Name $driveLetter -ErrorAction Stop
        $freeSpaceGB = [math]::Round($destDrive.Free / 1GB, 2)
        Write-LogMessage "   - Available on drive $($destDrive.Name): $freeSpaceGB GB"
        if ($freeSpaceGB -lt $MinRequiredGB) {
            Write-LogMessage "[WARNING] Low disk space. Available: $freeSpaceGB GB, Required: $MinRequiredGB GB." -Level WARNING
            if ($ExitOnLow) {
                Write-LogMessage "FATAL: Exiting due to low disk space (ExitOnLowSpaceIfBelowMinimum is true)." -Level ERROR
                return $false
            }
        } else { Write-LogMessage "   - Free space check: OK" -Level SUCCESS }
    } catch { Write-LogMessage "[WARNING] Could not determine free space for '$DestDir'. Error: $($_.Exception.Message)" -Level WARNING }
    return $true
}
#endregion

#region --- Exported Functions ---
Export-ModuleMember -Function New-VSSShadowCopy, Remove-VSSShadowCopy, Invoke-7ZipOperation, Test-7ZipArchive, Invoke-BackupRetentionPolicy, Test-DestinationFreeSpace, Invoke-PoShBackupJob
#endregion
