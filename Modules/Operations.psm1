# PowerShell Module: Operations.psm1
# Version 1.0: Implemented inclusive retention count. Added Invoke-VisualBasicDeleteFile wrapper.
#              Uses JobArchiveDateFormat for archive filenames.
#              Maintains DEBUG level logging of captured STDOUT when HideSevenZipOutput is true.
# Version 1.1: Added IsSimulationReport to report data for HTML report banner.
# Version 1.2: Added debug logging for simulation status.

#region --- Private Helper: Gather Job Configuration ---
# Not exported
function Get-PoShBackupJobEffectiveConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$JobConfig,
        [Parameter(Mandatory)] [hashtable]$GlobalConfig,
        [Parameter(Mandatory)] [hashtable]$CliOverrides,
        [Parameter(Mandatory)] [string]$PSScriptRootForPaths, 
        [Parameter(Mandatory)] [ref]$JobReportDataRef 
    )

    $effectiveConfig = @{}
    $reportData = $JobReportDataRef.Value 

    $effectiveConfig.OriginalSourcePath = $JobConfig.Path
    $effectiveConfig.BaseFileName       = $JobConfig.Name
    $reportData.JobConfiguration        = $JobConfig 

    $effectiveConfig.DestinationDir = Get-ConfigValue -ConfigObject $JobConfig -Key 'DestinationDir' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultDestinationDir' -DefaultValue $null)
    $effectiveConfig.RetentionCount = Get-ConfigValue -ConfigObject $JobConfig -Key 'RetentionCount' -DefaultValue 1
    if ($effectiveConfig.RetentionCount -lt 0) { $effectiveConfig.RetentionCount = 0 } 
    $effectiveConfig.DeleteToRecycleBin = Get-ConfigValue -ConfigObject $JobConfig -Key 'DeleteToRecycleBin' -DefaultValue $false
    
    $effectiveConfig.UsePassword = Get-ConfigValue -ConfigObject $JobConfig -Key 'UsePassword' -DefaultValue $false
    $effectiveConfig.CredentialUserNameHint = Get-ConfigValue -ConfigObject $JobConfig -Key 'CredentialUserNameHint' -DefaultValue "BackupUser"

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

    $scriptDefaultThreads = [System.Environment]::ProcessorCount
    $globalConfigThreads  = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultThreadCount' -DefaultValue 0
    $jobSpecificThreads   = Get-ConfigValue -ConfigObject $JobConfig -Key 'ThreadsToUse' -DefaultValue 0
    $threadsFor7Zip = if ($jobSpecificThreads -gt 0) { $jobSpecificThreads } elseif ($globalConfigThreads -gt 0) { $globalConfigThreads } else { $scriptDefaultThreads }
    if ($threadsFor7Zip -le 0) { $threadsFor7Zip = $scriptDefaultThreads } 
    $effectiveConfig.ThreadsSetting = "-mmt=$($threadsFor7Zip)"

    $effectiveConfig.JobEnableVSS = if ($CliOverrides.UseVSS) { $true } else { Get-ConfigValue -ConfigObject $JobConfig -Key 'EnableVSS' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'EnableVSS' -DefaultValue $false) }
    $effectiveConfig.JobVSSContextOption = Get-ConfigValue -ConfigObject $JobConfig -Key 'VSSContextOption' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'DefaultVSSContextOption' -DefaultValue "Persistent NoWriters")
    
    $vssCachePathFromConfig = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'VSSMetadataCachePath' -DefaultValue "%TEMP%\diskshadow_cache_poshbackup.cab"
    $effectiveConfig.VSSMetadataCachePath = [System.Environment]::ExpandEnvironmentVariables($vssCachePathFromConfig)
    
    $effectiveConfig.VSSPollingTimeoutSeconds = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'VSSPollingTimeoutSeconds' -DefaultValue 120
    $effectiveConfig.VSSPollingIntervalSeconds = Get-ConfigValue -ConfigObject $GlobalConfig -Key 'VSSPollingIntervalSeconds' -DefaultValue 5

    $effectiveConfig.JobEnableRetries = if ($CliOverrides.EnableRetries) { $true } else { Get-ConfigValue -ConfigObject $JobConfig -Key 'EnableRetries' -DefaultValue (Get-ConfigValue -ConfigObject $GlobalConfig -Key 'EnableRetries' -DefaultValue $false) }
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
function Get-PoShBackup7ZipArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$EffectiveConfig,
        [Parameter(Mandatory)] [string]$FinalArchivePath,
        [Parameter(Mandatory)] [object]$CurrentJobSourcePathFor7Zip, 
        [Parameter(Mandatory=$false)] [string]$TempPasswordFile = $null 
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
                if (-not ($exclusion.StartsWith("-x!") -or $exclusion.StartsWith("-xr!") -or $exclusion.StartsWith("-i!") -or $exclusion.StartsWith("-ir!"))) { $exclusion = "-x!$($exclusion)" } 
                $sevenZipArgs.Add($exclusion) 
            } 
        }
    }

    if ($EffectiveConfig.UsePassword) {
        $sevenZipArgs.Add("-mhe=on") 
        if (-not [string]::IsNullOrWhiteSpace($TempPasswordFile)) {
            $sevenZipArgs.Add("-spf$TempPasswordFile") 
        } else {
            Write-LogMessage "[WARNING] Password requested but no temp password file provided to 7-Zip; password will not be applied." -Level WARNING
        }
    }
    
    if ([string]::IsNullOrWhiteSpace($FinalArchivePath)) {
        Write-LogMessage "[CRITICAL] FinalArchivePath is NULL or EMPTY in Get-PoShBackup7ZipArguments. This can cause 7-Zip to use default output." -Level ERROR -ForegroundColour $Global:ColourError
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
        [Parameter(Mandatory)] [string]$JobName,
        [Parameter(Mandatory)] [hashtable]$JobConfig,
        [Parameter(Mandatory)] [hashtable]$GlobalConfig,
        [Parameter(Mandatory)] [hashtable]$CliOverrides,
        [Parameter(Mandatory)] [string]$PSScriptRootForPaths,
        [Parameter(Mandatory)] [string]$ActualConfigFile,
        [Parameter(Mandatory)] [ref]$JobReportDataRef,
        [Parameter(Mandatory=$false)] [switch]$IsSimulateMode 
    )

    $currentJobStatus = "SUCCESS" # Default operational status
    $JobPasswordPlainText = $null 
    $tempPasswordFilePath = $null 
    $FinalArchivePath = $null
    $VSSPathsInUse = $null      
    $reportData = $JobReportDataRef.Value 

    $reportData.IsSimulationReport = $IsSimulateMode.IsPresent # This will be $true or $false

    if (-not ($reportData.PSObject.Properties.Name -contains 'ScriptStartTime')) { 
        $reportData['ScriptStartTime'] = Get-Date 
    }

    try {
        $effectiveJobConfig = Get-PoShBackupJobEffectiveConfiguration -JobConfig $JobConfig -GlobalConfig $GlobalConfig -CliOverrides $CliOverrides -PSScriptRootForPaths $PSScriptRootForPaths -JobReportDataRef $JobReportDataRef
        
        Write-LogMessage " - Job Settings for '$JobName' (derived):"
        Write-LogMessage "   - Effective Source Path(s): $(if ($effectiveJobConfig.OriginalSourcePath -is [array]) {$effectiveJobConfig.OriginalSourcePath -join '; '} else {$effectiveJobConfig.OriginalSourcePath})" -ForegroundColour $Global:ColourValue
        Write-LogMessage "   - Destination Directory  : $($effectiveJobConfig.DestinationDir)" -ForegroundColour $Global:ColourValue
        Write-LogMessage "   - Archive Base Name      : $($effectiveJobConfig.BaseFileName)" -ForegroundColour $Global:ColourValue
        Write-LogMessage "   - Archive Extension      : $($effectiveJobConfig.JobArchiveExtension)" -ForegroundColour $Global:ColourValue
        Write-LogMessage "   - Archive Date Format    : $($effectiveJobConfig.JobArchiveDateFormat)" -ForegroundColour $Global:ColourValue
        Write-LogMessage "   - VSS Enabled            : $($effectiveJobConfig.JobEnableVSS)" -ForegroundColour $Global:ColourValue
        if ($effectiveJobConfig.JobEnableVSS) {
            Write-LogMessage "     - VSS Context Option   : $($effectiveJobConfig.JobVSSContextOption)" -ForegroundColour $Global:ColourValue
            Write-LogMessage "     - VSS Cache Path       : $($effectiveJobConfig.VSSMetadataCachePath)" -ForegroundColour $Global:ColourValue
        }
        Write-LogMessage "   - 7-Zip Priority         : $($effectiveJobConfig.JobSevenZipProcessPriority)" -ForegroundColour $Global:ColourValue
        Write-LogMessage "   - 7-Zip Threads          : $($effectiveJobConfig.ThreadsSetting)" -ForegroundColour $Global:ColourValue
        
        if ([string]::IsNullOrWhiteSpace($effectiveJobConfig.DestinationDir)) {
            Write-LogMessage "FATAL: Destination directory for job '$JobName' is not defined. Cannot proceed." -Level ERROR -ForegroundColour $Global:ColourError; throw "DestinationDir missing for job '$JobName'."
        }
        if (-not (Test-Path -LiteralPath $effectiveJobConfig.DestinationDir -PathType Container)) {
            Write-LogMessage "[INFO] Destination directory '$($effectiveJobConfig.DestinationDir)' for job '$JobName' does not exist. Attempting to create..."
            if (-not $IsSimulateMode.IsPresent) {
                try { New-Item -Path $effectiveJobConfig.DestinationDir -ItemType Directory -Force -ErrorAction Stop | Out-Null; Write-LogMessage "  - Destination directory created successfully." -ForegroundColour $Global:ColourSuccess }
                catch { Write-LogMessage "FATAL: Failed to create destination directory '$($effectiveJobConfig.DestinationDir)'. Error: $($_.Exception.Message)" -Level ERROR -ForegroundColour $Global:ColourError; throw "Failed to create destination directory for job '$JobName'." }
            } else {
                Write-LogMessage "SIMULATE: Would create destination directory '$($effectiveJobConfig.DestinationDir)'." -Level SIMULATE
            }
        }

        if ($effectiveJobConfig.UsePassword) {
            Write-LogMessage "`n[INFO] Password required for '$JobName'. Prompting..."
            # In simulation, we don't prompt for password but need to simulate having one for 7zip args
            if ($IsSimulateMode.IsPresent) {
                Write-LogMessage "SIMULATE: Would prompt for password for job '$JobName'." -Level SIMULATE
                $tempPasswordFilePath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "simulated_password.tmp") # Dummy path for simulation
            } else {
                $cred = Get-Credential -UserName $effectiveJobConfig.CredentialUserNameHint -Message "Enter password for 7-Zip backup: '$JobName'"
                if ($null -ne $cred) { 
                    $JobPasswordPlainText = $cred.GetNetworkCredential().Password
                    $tempPasswordFilePath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
                    Set-Content -Path $tempPasswordFilePath -Value $JobPasswordPlainText -Encoding UTF8 -Force -ErrorAction Stop
                    Write-LogMessage "   - Credentials obtained. Password written to temporary file for 7-Zip." -ForegroundColour $Global:ColourSuccess
                } else { 
                    Write-LogMessage "FATAL: Password entry cancelled for '$JobName'." -Level ERROR -ForegroundColour $Global:ColourError; throw "Password entry cancelled for job '$JobName'." 
                }
            }
        }

        Invoke-HookScript -ScriptPath $effectiveJobConfig.PreBackupScriptPath -HookType "PreBackup" `
                          -HookParameters @{ JobName = $JobName; Status = "PreBackup"; ConfigFile = $ActualConfigFile; SimulateMode = $IsSimulateMode.IsPresent } `
                          -IsSimulateMode:$IsSimulateMode

        $currentJobSourcePathFor7Zip = $effectiveJobConfig.OriginalSourcePath 
        if ($effectiveJobConfig.JobEnableVSS) {
            Write-LogMessage "`n[INFO] VSS enabled for job '$JobName'." -Level "VSS"
            if (-not (Test-AdminPrivileges)) { Write-LogMessage "FATAL: VSS requires Administrator privileges for job '$JobName'." -Level ERROR -ForegroundColour $Global:ColourError; throw "VSS requires Administrator privileges for job '$JobName'." }
            
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
                if (-not $IsSimulateMode.IsPresent) { # Actual failure
                    Write-LogMessage "[ERROR] VSS shadow copy creation failed or returned no paths for job '$JobName'. Using original source paths." -Level ERROR -ForegroundColour $Global:ColourError; $reportData.VSSStatus = "Failed to create/map shadows"
                } else { # Simulated failure or no paths
                     Write-LogMessage "SIMULATE: VSS shadow copy creation would have been attempted for job '$JobName'. Assuming original paths for simulation." -Level SIMULATE; $reportData.VSSStatus = "Simulated (No Shadows Created/Needed)"
                }
            } else { # $VSSPathsInUse has paths (real or simulated)
                Write-LogMessage "  - VSS shadow copies successfully created/mapped for job '$JobName'. Using shadow paths for backup." -ForegroundColour $Global:ColourSuccess -Level VSS
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
        Write-LogMessage "   - Using source(s) for 7-Zip: $(if ($currentJobSourcePathFor7Zip -is [array]) {($currentJobSourcePathFor7Zip | Where-Object {$_}) -join '; '} else {$currentJobSourcePathFor7Zip})" -ForegroundColour $Global:ColourValue
        
        if (-not (Test-DestinationFreeSpace -DestDir $effectiveJobConfig.DestinationDir -MinRequiredGB $effectiveJobConfig.JobMinimumRequiredFreeSpaceGB -ExitOnLow $effectiveJobConfig.JobExitOnLowSpace -IsSimulateMode:$IsSimulateMode)) {
            # Test-DestinationFreeSpace will log SIMULATE or actual error/warning
            # If it returns $false, it means an exit condition was met (if ExitOnLow was true and space was low)
            throw "Low disk space condition met for job '$JobName'." 
        }

        $DateString = Get-Date -Format $effectiveJobConfig.JobArchiveDateFormat 
        $ArchiveFileName = "$($effectiveJobConfig.BaseFileName) [$DateString]$($effectiveJobConfig.JobArchiveExtension)" 
        $FinalArchivePath = Join-Path -Path $effectiveJobConfig.DestinationDir -ChildPath $ArchiveFileName
        $reportData.FinalArchivePath = $FinalArchivePath
        Write-LogMessage "`n[INFO] Target Archive for job '$JobName': $FinalArchivePath" -ForegroundColour $Global:ColourValue

        $vbLoaded = $false
        if ($effectiveJobConfig.DeleteToRecycleBin) { try { Add-Type -AssemblyName Microsoft.VisualBasic -EA Stop; $vbLoaded = $true } catch {} }
        Invoke-BackupRetentionPolicy -DestinationDirectory $effectiveJobConfig.DestinationDir `
                                     -ArchiveBaseFileName $effectiveJobConfig.BaseFileName `
                                     -ArchiveExtension $effectiveJobConfig.JobArchiveExtension `
                                     -RetentionCountToKeep $effectiveJobConfig.RetentionCount `
                                     -SendToRecycleBin $effectiveJobConfig.DeleteToRecycleBin `
                                     -VBAssemblyLoaded $vbLoaded `
                                     -IsSimulateMode:$IsSimulateMode

        $sevenZipArgsArray = Get-PoShBackup7ZipArguments -EffectiveConfig $effectiveJobConfig `
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

        $archiveSize = "N/A (Simulated)" # Default for simulation
        if (-not $IsSimulateMode.IsPresent -and (Test-Path $FinalArchivePath -PathType Leaf)) {
             $archiveSize = Get-ArchiveSizeFormatted -PathToArchive $FinalArchivePath
        } elseif ($IsSimulateMode.IsPresent) {
            # In simulation, 7z doesn't create a file, so size is effectively 0 or placeholder
            $archiveSize = "0 Bytes (Simulated)" 
        }
        $reportData.ArchiveSizeFormatted = $archiveSize

        # Determine currentJobStatus based on 7zip operation
        # Invoke-7ZipOperation returns ExitCode 0 in simulation if it *would* have run
        if ($sevenZipResult.ExitCode -eq 0) { $currentJobStatus = "SUCCESS" }
        elseif ($sevenZipResult.ExitCode -eq 1) { $currentJobStatus = "WARNINGS" } # 7zip warning
        else { $currentJobStatus = "FAILURE" } # 7zip error or other failure

        $reportData.ArchiveTested = $effectiveJobConfig.JobTestArchiveAfterCreation
        # Only test if compression was successful (or simulated successfully) and not in simulation mode (actual test)
        if ($effectiveJobConfig.JobTestArchiveAfterCreation -and ($currentJobStatus -eq "SUCCESS") -and (-not $IsSimulateMode.IsPresent) -and (Test-Path $FinalArchivePath -PathType Leaf)) {
            $testArchiveParams = @{
                SevenZipPathExe = $sevenZipPathGlobal; ArchivePath = $FinalArchivePath
                TempPasswordFile = $tempPasswordFilePath
                ProcessPriority = $effectiveJobConfig.JobSevenZipProcessPriority; HideOutput = $effectiveJobConfig.HideSevenZipOutput
                MaxRetries = $effectiveJobConfig.JobMaxRetryAttempts; RetryDelaySeconds = $effectiveJobConfig.JobRetryDelaySeconds
                EnableRetries = $effectiveJobConfig.JobEnableRetries; IsSimulateMode = $IsSimulateMode.IsPresent # Will be $false here
            }
            $testResult = Test-7ZipArchive @testArchiveParams

            if ($testResult.ExitCode -eq 0) { 
                $reportData.ArchiveTestResult = "PASSED" 
            } else {
                $reportData.ArchiveTestResult = "FAILED (Code $($testResult.ExitCode))"
                if ($currentJobStatus -ne "FAILURE") {$currentJobStatus = "WARNINGS"} # Downgrade overall job status to WARNINGS if compression was OK but test failed
            }
            $reportData.TestRetryAttemptsMade = $testResult.AttemptsMade
        } elseif ($effectiveJobConfig.JobTestArchiveAfterCreation) { # Test was configured but not run
             $reportData.ArchiveTestResult = if($IsSimulateMode.IsPresent){"Not Performed (Simulated)"} else {"Not Performed (Archive Missing or Compression Error)"}
        } else { # Test not configured
            $reportData.ArchiveTestResult = "Not Configured"
        }

    } catch {
        Write-LogMessage "ERROR during processing of job '$JobName': $($_.Exception.ToString())" -Level ERROR -ForegroundColour $Global:ColourError
        $currentJobStatus = "FAILURE"
        $reportData.ErrorMessage = $_.Exception.ToString()
    } finally {
        if ($null -ne $VSSPathsInUse) {
            Remove-VSSShadowCopy -IsSimulateMode:$IsSimulateMode.IsPresent
        }

        # Clean up temp password file only if it was actually created (not just a dummy path in simulation)
        if (-not [string]::IsNullOrWhiteSpace($tempPasswordFilePath) -and (Test-Path -LiteralPath $tempPasswordFilePath -PathType Leaf) -and -not ($IsSimulateMode.IsPresent -and $tempPasswordFilePath.EndsWith("simulated_password.tmp")) ) {
            try { Remove-Item -LiteralPath $tempPasswordFilePath -Force -ErrorAction Stop }
            catch { Write-LogMessage "[WARNING] Failed to delete temporary password file '$tempPasswordFilePath'. Manual deletion may be required. Error: $($_.Exception.Message)" -Level "WARNING" -ForegroundColour $Global:ColourWarning }
        }
        if ($null -ne $JobPasswordPlainText) {
            try { $JobPasswordPlainText = $null; [System.GC]::Collect(); [System.GC]::WaitForPendingFinalizers() } catch {}
        }
        
        # Finalize OverallStatus for the report
        if ($IsSimulateMode.IsPresent -and $currentJobStatus -ne "FAILURE") {
            # If it was a simulation and didn't fail operationally, mark as SIMULATED_COMPLETE for reporting
            $reportData.OverallStatus = "SIMULATED_COMPLETE"
        } else {
            $reportData.OverallStatus = $currentJobStatus # Use the actual operational status
        }

        $reportData.ScriptEndTime = Get-Date 
        if (($reportData.PSObject.Properties.Name -contains 'ScriptStartTime') -and ($null -ne $reportData.ScriptStartTime)) {
            $reportData.TotalDuration = $reportData.ScriptEndTime - $reportData.ScriptStartTime
        } else {
            $reportData.TotalDuration = "N/A (Start time missing)"
        }

        $hookArgsForExternalScript = @{ 
            JobName = $JobName; Status = $reportData.OverallStatus; ArchivePath = $FinalArchivePath; # Use report's overall status for hooks
            ConfigFile = $ActualConfigFile; SimulateMode = $IsSimulateMode.IsPresent 
        }

        # Hooks are triggered based on the report's overall status, which includes SIMULATED_COMPLETE
        if ($reportData.OverallStatus -in @("SUCCESS", "WARNINGS", "SIMULATED_COMPLETE") ) { 
            Invoke-HookScript -ScriptPath $effectiveJobConfig.PostBackupScriptOnSuccessPath -HookType "PostBackupOnSuccess" -HookParameters $hookArgsForExternalScript -IsSimulateMode:$IsSimulateMode
        } else { # FAILURE
            Invoke-HookScript -ScriptPath $effectiveJobConfig.PostBackupScriptOnFailurePath -HookType "PostBackupOnFailure" -HookParameters $hookArgsForExternalScript -IsSimulateMode:$IsSimulateMode
        }
        Invoke-HookScript -ScriptPath $effectiveJobConfig.PostBackupScriptAlwaysPath -HookType "PostBackupAlways" -HookParameters $hookArgsForExternalScript -IsSimulateMode:$IsSimulateMode
    }
    
    # Return the *operational* status of the job (SUCCESS, WARNINGS, FAILURE)
    # This is used by the main script to determine overall script success/failure
    # and for the StopSetOnError logic.
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
        try { (Get-Item -LiteralPath $_ -ErrorAction Stop).PSDrive.Name + ":" } catch { Write-LogMessage "[WARNING] Could not determine volume for source path '$_'. Skipping for VSS." -Level WARNING -ForegroundColour $Global:ColourWarning; $null }
    } | Where-Object {$null -ne $_} | Select-Object -Unique

    if ($volumesToShadow.Count -eq 0) { Write-LogMessage "[WARNING] No valid volumes found to create shadow copies for." -Level WARNING -ForegroundColour $Global:ColourWarning; return $null }

    $diskshadowScriptContent = @"
SET CONTEXT $VSSContextOption
SET METADATA CACHE "$MetadataCachePath"
SET VERBOSE ON
$($volumesToShadow | ForEach-Object { "ADD VOLUME $_ ALIAS Vol_$($_ -replace ':','')" })
CREATE
"@
    $tempDiskshadowScriptFile = Join-Path -Path $env:TEMP -ChildPath "diskshadow_create_backup_$(Get-Random).txt"
    try { $diskshadowScriptContent | Set-Content -Path $tempDiskshadowScriptFile -Encoding UTF8 -ErrorAction Stop } 
    catch { Write-LogMessage "[ERROR] Failed to write diskshadow script to '$tempDiskshadowScriptFile'. Error: $($_.Exception.Message)" -Level ERROR -ForegroundColour $Global:ColourError; return $null }
    
    Write-LogMessage "  - Generated diskshadow script: $tempDiskshadowScriptFile (Context: $VSSContextOption, Cache: $MetadataCachePath)" -Level VSS

    if ($IsSimulateMode.IsPresent) {
        Write-LogMessage "SIMULATE: Would execute diskshadow with script '$tempDiskshadowScriptFile' to create shadow copies for volumes: $($volumesToShadow -join ', ')" -Level SIMULATE
        $SourcePathsToShadow | ForEach-Object {
            $currentSourcePath = $_ 
            try {
                $vol = (Get-Item -LiteralPath $currentSourcePath -ErrorAction Stop).PSDrive.Name + ":"
                $relativePathSimulated = $currentSourcePath -replace [regex]::Escape($vol), "" 
                $simulatedIndex = $SourcePathsToShadow.IndexOf($currentSourcePath) + 1 
                if ($simulatedIndex -le 0) { $simulatedIndex = Get-Random -Minimum 1 -Maximum 999 } 
                $mappedShadowPaths[$currentSourcePath] = "\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopySIMULATED$($simulatedIndex)$relativePathSimulated"
            } catch {
                 Write-LogMessage "SIMULATE: Could not get volume for '$currentSourcePath' to create simulated shadow path." -Level SIMULATE
                 $mappedShadowPaths[$currentSourcePath] = "$currentSourcePath (Simulated - Original Path)" # Fallback
            }
        }
        Remove-Item -LiteralPath $tempDiskshadowScriptFile -Force -ErrorAction SilentlyContinue
        return $mappedShadowPaths 
    }

    Write-LogMessage "  - Executing diskshadow to create shadow copies. This may take a moment..." -Level VSS
    $process = Start-Process -FilePath "diskshadow.exe" -ArgumentList "/s `"$tempDiskshadowScriptFile`"" -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$null" -RedirectStandardError "$null"
    Remove-Item -LiteralPath $tempDiskshadowScriptFile -Force -ErrorAction SilentlyContinue

    if ($process.ExitCode -ne 0) {
        Write-LogMessage "[ERROR] diskshadow.exe failed to create shadow copies. Exit Code: $($process.ExitCode)" -Level ERROR -ForegroundColour $Global:ColourError
        return $null 
    }

    Write-LogMessage "  - Shadow copy creation command completed. Polling WMI for shadow details (Timeout: ${PollingTimeoutSeconds}s)..." -Level VSS -ForegroundColour $Global:ColourSuccess
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $allVolumesShadowed = $false
    $foundShadowsForThisCall = @{} 

    while ($stopwatch.Elapsed.TotalSeconds -lt $PollingTimeoutSeconds) {
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
                        Write-LogMessage "  - Found shadow for '$volName': Device '$($candidateShadow.DeviceObject)' (ID: $($candidateShadow.ID))" -Level VSS -ForegroundColour $Global:ColourValue
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
        Write-LogMessage "[ERROR] Timed out or failed to find all required shadow copies via WMI after $PollingTimeoutSeconds seconds." -Level ERROR -ForegroundColour $Global:ColourError
        $foundShadowsForThisCall.Keys | ForEach-Object {
            $volNameToClean = $_
            if ($currentRunShadowIDsForThisVSScall.ContainsKey($volNameToClean)) {
                Remove-VSSShadowCopyById -ShadowID $currentRunShadowIDsForThisVSScall[$volNameToClean] -IsSimulateMode:$IsSimulateMode # Pass simulate mode
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
                Write-LogMessage "[WARNING] Could not map source path '$originalFullPath' as its volume shadow ('$volNameOfPath') was not definitively found or mapped." -Level WARNING -ForegroundColour $Global:ColourWarning
            }
        } catch {
            Write-LogMessage "[WARNING] Error processing source path '$originalFullPath' for VSS mapping: $($_.Exception.Message)" -Level WARNING -ForegroundColour $Global:ColourWarning
        }
    }
    
    if ($mappedShadowPaths.Count -eq 0 -and $SourcePathsToShadow.Count -gt 0) {
         Write-LogMessage "[ERROR] Failed to map ANY source paths to shadow paths, though shadow creation command succeeded." -Level ERROR -ForegroundColour $Global:ColourError
         return $null
    }
    if ($mappedShadowPaths.Count -lt $SourcePathsToShadow.Count) {
        Write-LogMessage "[WARNING] Not all source paths could be mapped to shadow paths. VSS may be incomplete for this job." -Level WARNING -ForegroundColour $Global:ColourWarning
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
        catch { Write-LogMessage "[ERROR] Failed to write single shadow delete script. Error: $($_.Exception.Message)" -Level ERROR -ForegroundColour $Global:ColourError; return}

        if (-not $IsSimulateMode.IsPresent) {
            $procDeleteSingle = Start-Process -FilePath "diskshadow.exe" -ArgumentList "/s `"$tempScriptPathSingle`"" -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$null" -RedirectStandardError "$null"
            if ($procDeleteSingle.ExitCode -ne 0) {
                Write-LogMessage "[WARNING] diskshadow.exe failed to delete specific shadow ID $ShadowID. Exit Code: $($procDeleteSingle.ExitCode)" -Level WARNING -ForegroundColour $Global:ColourWarning
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
        catch { Write-LogMessage "[ERROR] Failed to write diskshadow delete script. Error: $($_.Exception.Message)" -Level ERROR -ForegroundColour $Global:ColourError; return }
        
        Write-LogMessage "  - Generated diskshadow deletion script: $tempScriptPathAll" -Level VSS

        if (-not $IsSimulateMode.IsPresent) {
            Write-LogMessage "  - Executing diskshadow to delete shadow copies..." -Level VSS
            $processDeleteAll = Start-Process -FilePath "diskshadow.exe" -ArgumentList "/s `"$tempScriptPathAll`"" -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$null" -RedirectStandardError "$null"
            if ($processDeleteAll.ExitCode -ne 0) {
                Write-LogMessage "[ERROR] diskshadow.exe failed to delete one or more shadow copies. Exit Code: $($processDeleteAll.ExitCode)" -Level ERROR -ForegroundColour $Global:ColourError
                Write-LogMessage "  - Manual deletion may be needed for ID(s): $($shadowIdsToRemove -join ', ')" -Level ERROR -ForegroundColour $Global:ColourError
            } else {
                Write-LogMessage "  - Shadow copy deletion process completed successfully." -Level VSS -ForegroundColour $Global:ColourSuccess
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
    $actualDelaySeconds = if ($EnableRetries) { $RetryDelaySeconds } else { 0 }
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
            $operationExitCode = 0 # Simulate success for 7zip operation itself
            $operationElapsedTime = New-TimeSpan -Seconds 0 
            break 
        }

        Write-LogMessage "   - Attempting 7-Zip execution (Attempt $currentTry/$actualMaxTries)..."
        Write-LogMessage "     Command: `"$SevenZipPathExe`" $argumentStringForProcess" -Level DEBUG 
        
        $validPriorities = "Idle", "BelowNormal", "Normal", "AboveNormal", "High"
        if ([string]::IsNullOrWhiteSpace($ProcessPriority) -or $ProcessPriority -notin $validPriorities) {
            Write-LogMessage "[WARNING] Invalid/empty 7-Zip priority '$ProcessPriority'. Defaulting to 'Normal'." -Level WARNING -ForegroundColour $Global:ColourWarning; $ProcessPriority = "Normal"
        }
        
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew(); $process = $null
        try {
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $SevenZipPathExe
            $startInfo.Arguments = $argumentStringForProcess             
            $startInfo.UseShellExecute = $false 
            $startInfo.CreateNoWindow = $HideOutput 
            $startInfo.WindowStyle = if($HideOutput) { [System.Diagnostics.ProcessWindowStyle]::Hidden } else { [System.Diagnostics.ProcessWindowStyle]::Normal }
            
            if ($HideOutput) { 
                $startInfo.RedirectStandardOutput = $true
                $startInfo.RedirectStandardError = $true
            }

            Write-LogMessage "  - Starting 7-Zip process with priority: $ProcessPriority" -Level DEBUG
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $startInfo
            $process.Start() | Out-Null
            try { $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]$ProcessPriority } 
            catch { Write-LogMessage "[WARNING] Failed to set 7-Zip priority. Error: $($_.Exception.Message)" -Level WARNING -ForegroundColour $Global:ColourWarning }
            
            $stdOutput = ""
            $stdError = ""
            $outputTask = $null
            $errorTask = $null

            if ($HideOutput) { 
                $outputTask = $process.StandardOutput.ReadToEndAsync()
                $errorTask = $process.StandardError.ReadToEndAsync()
            }
            
            $process.WaitForExit() 

            if ($HideOutput) { 
                if ($null -ne $outputTask) {
                    try { $stdOutput = $outputTask.GetAwaiter().GetResult() } catch { try { $stdOutput = $process.StandardOutput.ReadToEnd() } catch {} } 
                }
                 if ($null -ne $errorTask) {
                    try { $stdError = $errorTask.GetAwaiter().GetResult() } catch { try { $stdError = $process.StandardError.ReadToEnd() } catch {} }
                 }

                if (-not [string]::IsNullOrWhiteSpace($stdOutput)) {
                    Write-LogMessage "  - 7-Zip STDOUT (captured as HideSevenZipOutput is true):" -Level DEBUG
                    $stdOutput.Split([Environment]::NewLine) | ForEach-Object { Write-LogMessage "    | $_" -Level DEBUG -NoTimestampToLogFile }
                }
                
                if (-not [string]::IsNullOrWhiteSpace($stdError)) {
                    Write-LogMessage "  - 7-Zip STDERR:" -Level ERROR -ForegroundColour $Global:ColourError
                    $stdError.Split([Environment]::NewLine) | ForEach-Object { Write-LogMessage "    | $_" -Level ERROR -ForegroundColour $Global:ColourError -NoTimestampToLogFile }
                }
            }
            $operationExitCode = $process.ExitCode
        } catch { 
            Write-LogMessage "[ERROR] Failed to start/manage 7-Zip. Error: $($_.Exception.ToString())" -Level ERROR -ForegroundColour $Global:ColourError 
            $operationExitCode = -999 
        } finally { 
            $stopwatch.Stop()
            $operationElapsedTime = $stopwatch.Elapsed
            if ($null -ne $process) { $process.Dispose() } 
        }
        
        Write-LogMessage "   - 7-Zip attempt $currentTry finished. Exit: $operationExitCode. Elapsed: $operationElapsedTime"
        if ($operationExitCode -in @(0,1)) { break } # 0 = Success, 1 = Warning (e.g. some files not found but archive created)
        elseif ($currentTry -lt $actualMaxTries) { Write-LogMessage "[WARNING] 7-Zip failed. Retrying in $actualDelaySeconds s..." -Level WARNING -ForegroundColour $Global:ColourWarning; Start-Sleep -Seconds $actualDelaySeconds } 
        else { Write-LogMessage "[ERROR] 7-Zip failed after $actualMaxTries attempts." -Level ERROR -ForegroundColour $Global:ColourError }
    }
    return @{ ExitCode = $operationExitCode; ElapsedTime = $operationElapsedTime; AttemptsMade = $attemptsMade }
}

function Test-7ZipArchive {
    [CmdletBinding()]
    param(
        [string]$SevenZipPathExe,
        [string]$ArchivePath,
        [string]$TempPasswordFile = $null, 
        [string]$ProcessPriority = "Normal",
        [switch]$HideOutput, 
        [switch]$IsSimulateMode, # This is the IsSimulateMode for the *overall job*
        [int]$MaxRetries = 1, [int]$RetryDelaySeconds = 60, [bool]$EnableRetries = $false
    )
    Write-LogMessage "`n[INFO] Performing archive integrity test for '$ArchivePath'..."
    $testArguments = [System.Collections.Generic.List[string]]::new()
    $testArguments.Add("t") 
    $testArguments.Add($ArchivePath) 
    
    if (-not [string]::IsNullOrWhiteSpace($TempPasswordFile) -and (Test-Path -LiteralPath $TempPasswordFile)) {
        $testArguments.Add("-spf$TempPasswordFile") 
    }
    Write-LogMessage "   - Test Command (raw args before Invoke-7ZipOperation quoting): `"$SevenZipPathExe`" $($testArguments -join ' ')" -Level DEBUG

    # The Test-7ZipArchive function itself doesn't "simulate" the test; it either runs it or doesn't based on job simulation.
    # The IsSimulateMode parameter passed to Invoke-7ZipOperation inside this function should be $false if we are actually testing.
    # However, this function (Test-7ZipArchive) should not be called if the overall job is a simulation.
    # The $IsSimulateMode here is more for the Invoke-7ZipOperation call's internal simulation handling if needed,
    # but for a test, simulation generally means "don't do the test".
    # The parent (Invoke-PoShBackupJob) decides IF Test-7ZipArchive is called based on $IsSimulateMode.

    $invokeParams = @{
        SevenZipPathExe = $SevenZipPathExe; SevenZipArguments = $testArguments.ToArray()
        ProcessPriority = $ProcessPriority; HideOutput = $HideOutput 
        MaxRetries = $MaxRetries; RetryDelaySeconds = $RetryDelaySeconds; EnableRetries = $EnableRetries
        IsSimulateMode = $false # We always want to run the test if this function is called; parent handles simulation logic
    }
    $result = Invoke-7ZipOperation @invokeParams
    
    $msg = if ($result.ExitCode -eq 0) { "PASSED" } else { "FAILED (Code: $($result.ExitCode))" }
    $colour = if ($result.ExitCode -eq 0) { $Global:ColourSuccess } else { $Global:ColourError }
    Write-LogMessage "  - Archive Test Result for '$ArchivePath': $msg" -ForegroundColour $colour
    return $result 
}
#endregion

#region --- Private Helper: Invoke-VisualBasicDeleteFile (for testability) ---
# Not Exported
function Invoke-VisualBasicDeleteFile {
    param(
        [string]$path,
        [Microsoft.VisualBasic.FileIO.UIOption]$uiOption = [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
        [Microsoft.VisualBasic.FileIO.RecycleOption]$recycleOption = [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
        [Microsoft.VisualBasic.FileIO.UICancelOption]$cancelOption = [Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException
    )
    try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue } catch {}
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($path, $uiOption, $recycleOption, $cancelOption)
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
    Write-LogMessage "   - Destination: $DestinationDirectory" -ForegroundColour $Global:ColourValue
    Write-LogMessage "   - Configured Total Retention Count (target after current backup): $RetentionCountToKeep" -ForegroundColour $Global:ColourValue
    $effectiveSendToRecycleBin = $SendToRecycleBin
    if ($SendToRecycleBin -and -not $VBAssemblyLoaded) {
        Write-LogMessage "[WARNING] Recycle Bin requested but VisualBasic assembly not loaded. Falling back to PERMANENT deletion." -Level WARNING -ForegroundColour $Global:ColourWarning
        $effectiveSendToRecycleBin = $false
    }
    Write-LogMessage "   - Effective Deletion Method: $(if ($effectiveSendToRecycleBin) {'Recycle Bin'} else {'Permanent'})" -ForegroundColour $Global:ColourValue

    $literalBaseName = $ArchiveBaseFileName -replace '\*', '`*' -replace '\?', '`?'
    $filePattern = "$($literalBaseName)*$($ArchiveExtension)" 
    
    try {
        if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
            Write-LogMessage "   - Retention SKIPPED: Destination directory '$DestinationDirectory' not found." -Level WARNING -ForegroundColour $Global:ColourWarning
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
                Write-LogMessage "       - Identifying for deletion: $($backupFile.FullName) (Created: $($backupFile.CreationTime))" -ForegroundColour $Global:ColourValue
                if ($IsSimulateMode) { Write-LogMessage "       - SIMULATE: Would delete '$($backupFile.FullName)'" -Level SIMULATE } 
                else {
                    Write-LogMessage "       - Deleting: $($backupFile.FullName)" -ForegroundColour $Global:ColourWarning
                    try {
                        if ($effectiveSendToRecycleBin) {
                            Invoke-VisualBasicDeleteFile -path $backupFile.FullName `
                                -uiOption ([Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs) `
                                -recycleOption ([Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin) `
                                -cancelOption ([Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException)
                            Write-LogMessage "         - Status: MOVED TO RECYCLE BIN" -ForegroundColour $Global:ColourSuccess
                        } else { 
                            Remove-Item -LiteralPath $backupFile.FullName -Force -EA Stop; Write-LogMessage "         - Status: DELETED PERMANENTLY" -ForegroundColour $Global:ColourSuccess 
                        }
                    } catch { Write-LogMessage "         - Status: FAILED! Error: $($_.Exception.Message)" -Level ERROR -ForegroundColour $Global:ColourError }
                }
            }
        } elseif ($null -ne $existingBackups) { 
            Write-LogMessage "   - Number of existing backups ($($existingBackups.Count)) is already at or below the target number of old backups to preserve ($numberOfOldBackupsToPreserve). No older backups to delete by count." -Level INFO
        } else { 
            Write-LogMessage "   - No existing backups found matching pattern '$filePattern' in '$DestinationDirectory'." -Level INFO
        } 
    } catch { Write-LogMessage "[WARNING] Error during retention check for '$ArchiveBaseFileName'. Error: $($_.Exception.Message)" -Level WARNING -ForegroundColour $Global:ColourWarning }
}
#endregion

#region --- Free Space Check ---
function Test-DestinationFreeSpace { 
    [CmdletBinding()]
    param( 
        [string]$DestDir, 
        [int]$MinRequiredGB, 
        [bool]$ExitOnLow,
        [switch]$IsSimulateMode # Added for logging simulation
    )
    if ($MinRequiredGB -le 0) { return $true } 
    Write-LogMessage "`n[INFO] Checking destination free space for '$DestDir'..."
    Write-LogMessage "   - Minimum required: $MinRequiredGB GB" -ForegroundColour $Global:ColourValue
    
    if ($IsSimulateMode.IsPresent) {
        Write-LogMessage "SIMULATE: Would check free space. Assuming OK for simulation purposes." -Level SIMULATE
        return $true
    }

    try {
        if (-not (Test-Path -LiteralPath $DestDir -PathType Container)) { 
            Write-LogMessage "[WARNING] Dest dir '$DestDir' for free space check not found. Skipping." -Level WARNING -ForegroundColour $Global:ColourWarning
            return $true # Don't fail the job if dest dir isn't there yet, it might be created later or be a job config issue
        }
        $driveLetter = (Get-Item -LiteralPath $DestDir).PSDrive.Name
        $destDrive = Get-PSDrive -Name $driveLetter -EA Stop
        $freeSpaceGB = [math]::Round($destDrive.Free / 1GB, 2)
        Write-LogMessage "   - Available on drive $($destDrive.Name): $freeSpaceGB GB" -ForegroundColour $Global:ColourValue
        if ($freeSpaceGB -lt $MinRequiredGB) {
            Write-LogMessage "[WARNING] Low disk space. Available: $freeSpaceGB GB, Required: $MinRequiredGB GB." -Level WARNING -ForegroundColour $Global:ColourWarning
            if ($ExitOnLow) { 
                Write-LogMessage "FATAL: Exiting due to low disk space (ExitOnLowSpaceIfBelowMinimum is true)." -Level ERROR -ForegroundColour $Global:ColourError
                return $false # Signal to abort
            }
        } else { Write-LogMessage "   - Free space check: OK" -ForegroundColour $Global:ColourSuccess }
    } catch { Write-LogMessage "[WARNING] Could not determine free space for '$DestDir'. Error: $($_.Exception.Message)" -Level WARNING -ForegroundColour $Global:ColourWarning }
    return $true # Return true if not exiting on low space, or if check errored (don't fail job for check error)
}
#endregion

#region --- Exported Functions ---
Export-ModuleMember -Function New-VSSShadowCopy, Remove-VSSShadowCopy, Invoke-7ZipOperation, Test-7ZipArchive, Invoke-BackupRetentionPolicy, Test-DestinationFreeSpace, Invoke-PoShBackupJob
#endregion
