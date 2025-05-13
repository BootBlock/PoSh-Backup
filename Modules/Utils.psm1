# PowerShell Module: Utils.psm1
# Version 1.0: Updated PauseBeforeExit validation to include new string options (Always, Never, OnFailure, etc.).

#region --- Logging Function ---
function Write-LogMessage {
    [CmdletBinding()]
    param (
        [string]$Message,
        [string]$ForegroundColour = $Global:ColourInfo,
        [switch]$NoNewLine,
        [string]$Level = "INFO",
        [switch]$NoTimestampToLogFile = $false
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $consoleMessage = $Message
    $logMessage = if ($NoTimestampToLogFile) { $Message } else { "$timestamp [$Level] $Message" }

    # Determine CONSOLE ForegroundColour based on Level
    $effectiveConsoleColour = $ForegroundColour 
    switch -Wildcard ($Level.ToUpperInvariant()) {
        "SIMULATE"       { $effectiveConsoleColour = $Global:ColourSimulate }
        "CONFIG_TEST"    { $effectiveConsoleColour = $Global:ColourSimulate }
        "VSS"            { $effectiveConsoleColour = $Global:ColourAdmin }
        "HOOK"           { $effectiveConsoleColour = $Global:ColourDebug }
        "ERROR"          { $effectiveConsoleColour = $Global:ColourError }
        "WARNING"        { $effectiveConsoleColour = $Global:ColourWarning }
        "SUCCESS"        { $effectiveConsoleColour = $Global:ColourSuccess }
        "DEBUG"          { $effectiveConsoleColour = $Global:ColourDebug }
    }

    if ($NoNewLine) {
        Write-Host $consoleMessage -ForegroundColor $effectiveConsoleColour -NoNewline
    } else {
        Write-Host $consoleMessage -ForegroundColor $effectiveConsoleColour
    }

    if ($Global:GlobalJobLogEntries -is [System.Collections.Generic.List[object]]) {
        $Global:GlobalJobLogEntries.Add([PSCustomObject]@{
            Timestamp = if($NoTimestampToLogFile -and $Global:GlobalJobLogEntries.Count -gt 0) { "" } else { $timestamp }
            Level     = $Level
            Message   = $Message 
        })
    }

    if ($Global:GlobalEnableFileLogging -and $Global:GlobalLogFile -and $Level -ne "NONE") {
        try {
            Add-Content -Path $Global:GlobalLogFile -Value $logMessage -ErrorAction Stop
        } catch {
            Write-Host "CRITICAL: Failed to write to log file '$($Global:GlobalLogFile)'. Error: $($_.Exception.Message)" -ForegroundColor $Global:ColourError
        }
    }
}
#endregion

#region --- Helper Function Get-ConfigValue ---
function Get-ConfigValue {
    [CmdletBinding()]
    param (
        [object]$ConfigObject,
        [string]$Key,
        [object]$DefaultValue,
        [string]$JobNameForError = "Global" 
    )
    if ($null -ne $ConfigObject -and $ConfigObject -is [hashtable] -and $ConfigObject.ContainsKey($Key)) {
        return $ConfigObject[$Key]
    }
    elseif ($null -ne $ConfigObject -and -not ($ConfigObject -is [hashtable]) -and ($null -ne $ConfigObject.PSObject) -and ($null -ne $ConfigObject.PSObject.Properties.Name) -and $ConfigObject.PSObject.Properties.Name -contains $Key) {
        return $ConfigObject.$Key
    }
    return $DefaultValue
}
#endregion

#region --- Helper Function Test-AdminPrivileges ---
function Test-AdminPrivileges {
    [CmdletBinding()]
    param()
    Write-LogMessage "[INFO] Checking for Administrator privileges..." -Level "DEBUG"
    $currentUser = New-Object Security.Principal.WindowsPrincipal $([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        Write-LogMessage "  - Running with Administrator privileges." -ForegroundColour $Global:ColourSuccess
    } else {
        Write-LogMessage "  - NOT running with Administrator privileges." -Level "WARNING" -ForegroundColour $Global:ColourWarning
    }
    return $isAdmin
}
#endregion

#region --- Helper Function Invoke-HookScript ---
function Invoke-HookScript {
    [CmdletBinding()]
    param(
        [string]$ScriptPath,
        [string]$HookType,
        [hashtable]$HookParameters, 
        [switch]$IsSimulateMode     
    )
    if ([string]::IsNullOrWhiteSpace($ScriptPath)) { return }

    Write-LogMessage "`n[INFO] Attempting to execute $HookType script: $ScriptPath" -Level "HOOK"
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        Write-LogMessage "[WARNING] $HookType script not found at '$ScriptPath'. Skipping." -Level "WARNING" -ForegroundColour $Global:ColourWarning
        if ($Global:GlobalJobHookScriptData -is [System.Collections.Generic.List[object]]) {
            $Global:GlobalJobHookScriptData.Add([PSCustomObject]@{ Name = $HookType; Path = $ScriptPath; Status = "Not Found"; Output = ""})
        }
        return
    }

    $outputLog = [System.Collections.Generic.List[string]]::new()
    $status = "Success"
    try {
        if ($IsSimulateMode.IsPresent) { 
            Write-LogMessage "SIMULATE: Would execute $HookType script '$ScriptPath' with parameters: $($HookParameters | Out-String)" -Level "SIMULATE"
            $outputLog.Add("SIMULATE: Script execution skipped.")
            $status = "Simulated"
        } else {
            Write-LogMessage "  - Executing $HookType script..." -Level "HOOK"
            $processArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
            $paramString = ""
            
            foreach ($key in $HookParameters.Keys) {
                $value = $HookParameters[$key]
                if ($value -is [bool] -or $value -is [switch]) {
                    if ($value) { 
                        $paramString += " -$key"
                    }
                } elseif ($value -is [string] -and ($value.Contains(" ") -or $value.Contains("'") -or $value.Contains('"')) ) {
                    $escapedValueForCmd = $value -replace '"', '""' 
                    $paramString += " -$key " + '"' + $escapedValueForCmd + '"' 
                } elseif ($null -ne $value) { 
                    $paramString += " -$key $value"
                }
            }
            $processArgs += $paramString

            $tempStdOut = New-TemporaryFile
            $tempStdErr = New-TemporaryFile

            Write-LogMessage "    - PowerShell Arguments: $processArgs" -Level "DEBUG"
            $proc = Start-Process powershell.exe -ArgumentList $processArgs -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $tempStdOut.FullName -RedirectStandardError $tempStdErr.FullName

            $stdOutContent = Get-Content $tempStdOut.FullName -ErrorAction SilentlyContinue
            $stdErrContent = Get-Content $tempStdErr.FullName -ErrorAction SilentlyContinue

            Remove-Item $tempStdOut.FullName -Force -ErrorAction SilentlyContinue
            Remove-Item $tempStdErr.FullName -Force -ErrorAction SilentlyContinue

            if ($stdOutContent) {
                $stdOutContent | ForEach-Object { Write-LogMessage "    OUT: $_" -Level "HOOK" -ForegroundColour $Global:ColourValue; $outputLog.Add("OUTPUT: $_") }
            }
            if ($proc.ExitCode -ne 0) {
                Write-LogMessage "[ERROR] $HookType script '$ScriptPath' exited with code $($proc.ExitCode)." -Level "ERROR" -ForegroundColour $Global:ColourError
                $status = "Failure (ExitCode $($proc.ExitCode))"
                if ($stdErrContent) {
                    $stdErrContent | ForEach-Object { Write-LogMessage "    ERR: $_" -Level "ERROR" -ForegroundColour $Global:ColourError; $outputLog.Add("ERROR: $_") }
                }
            } elseif ($stdErrContent) {
                 Write-LogMessage "[WARNING] $HookType script '$ScriptPath' wrote to stderr despite exiting successfully." -Level "WARNING" -ForegroundColour $Global:ColourWarning
                 $stdErrContent | ForEach-Object { Write-LogMessage "    ERR: $_" -Level "WARNING" -ForegroundColour $Global:ColourWarning; $outputLog.Add("STDERR: $_") }
            }
            $currentStatusColour = if($status -like "Failure*"){$Global:ColourError}else{$Global:ColourSuccess}
            Write-LogMessage "  - $HookType script execution finished. Status: $status" -Level "HOOK" -ForegroundColour $currentStatusColour
        }
    } catch {
        Write-LogMessage "[ERROR] Exception while trying to execute $HookType script '$ScriptPath': $($_.Exception.Message)" -Level "ERROR" -ForegroundColour $Global:ColourError
        $outputLog.Add("EXCEPTION: $($_.Exception.Message)")
        $status = "Exception"
    }

    if ($Global:GlobalJobHookScriptData -is [System.Collections.Generic.List[object]]) {
        $Global:GlobalJobHookScriptData.Add([PSCustomObject]@{ Name = $HookType; Path = $ScriptPath; Status = $status; Output = ($outputLog -join [System.Environment]::NewLine) })
    }
}
#endregion

#region --- Get Archive Size Formatted ---
function Get-ArchiveSizeFormatted {
    [CmdletBinding()]
    param([string]$PathToArchive)
    $FormattedSize = "N/A"
    try {
        if (Test-Path -LiteralPath $PathToArchive -PathType Leaf) {
            $ArchiveFile = Get-Item -LiteralPath $PathToArchive -ErrorAction Stop
            $Size = $ArchiveFile.Length
            if ($Size -ge 1GB) { $FormattedSize = "{0:N2} GB" -f ($Size / 1GB) }
            elseif ($Size -ge 1MB) { $FormattedSize = "{0:N2} MB" -f ($Size / 1MB) }
            elseif ($Size -ge 1KB) { $FormattedSize = "{0:N2} KB" -f ($Size / 1KB) }
            else { $FormattedSize = "$Size Bytes" }
        } else {
            $FormattedSize = "File not found"
        }
    } catch {
        Write-LogMessage "[WARNING] Error getting size for '$PathToArchive': $($_.Exception.Message)" -Level "WARNING" -ForegroundColour $Global:ColourWarning
        $FormattedSize = "Error getting size"
    }
    return $FormattedSize
}
#endregion

#region --- Configuration Loading and Validation Function ---
function Import-AppConfiguration {
    [CmdletBinding()]
    param (
        [string]$UserSpecifiedPath,
        [switch]$IsTestConfigMode,
        [string]$MainScriptPSScriptRoot
    )

    $defaultConfigDir = Join-Path -Path $MainScriptPSScriptRoot -ChildPath "Config"
    $defaultConfigFileName = "Default.psd1"
    $defaultConfigPath = Join-Path -Path $defaultConfigDir -ChildPath $defaultConfigFileName

    $resolvedConfigPath = $null
    if (-not [string]::IsNullOrWhiteSpace($UserSpecifiedPath)) {
        $resolvedConfigPath = $UserSpecifiedPath
        Write-LogMessage "`n[INFO] Using specified configuration file: $($resolvedConfigPath)"
    } else {
        $resolvedConfigPath = $defaultConfigPath
        Write-LogMessage "`n[INFO] No -ConfigFile specified. Attempting to use default: $($resolvedConfigPath)"
    }

    if (-not (Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf)) {
        Write-LogMessage "FATAL: Configuration file '$resolvedConfigPath' not found." -Level "ERROR" -ForegroundColour $Global:ColourError
        return @{ IsValid = $false; ErrorMessage = "Configuration file not found at '$resolvedConfigPath'." }
    }

    $loadedConfiguration = $null
    try {
        $loadedConfiguration = Import-PowerShellDataFile -LiteralPath $resolvedConfigPath -ErrorAction Stop
        Write-LogMessage "  - Configuration loaded successfully from '$resolvedConfigPath'." -ForegroundColour $Global:ColourSuccess
    } catch {
        Write-LogMessage "FATAL: Could not load or parse configuration file '$resolvedConfigPath'. Error: $($_.Exception.Message)" -Level "ERROR" -ForegroundColour $Global:ColourError
        return @{ IsValid = $false; ErrorMessage = "Failed to parse configuration file: $($_.Exception.Message)" }
    }

    if ($null -eq $loadedConfiguration -or -not ($loadedConfiguration -is [hashtable])) {
        Write-LogMessage "FATAL: Configuration file '$resolvedConfigPath' did not load as a valid hashtable." -Level "ERROR" -ForegroundColour $Global:ColourError
        return @{ IsValid = $false; ErrorMessage = "Configuration file did not load as a valid hashtable." }
    }

    $validationMessages = [System.Collections.Generic.List[string]]::new()

    $vssCachePath = Get-ConfigValue -ConfigObject $loadedConfiguration -Key 'VSSMetadataCachePath' -DefaultValue "%TEMP%\diskshadow_cache_poshbackup.cab" 
    try {
        $expandedVssCachePath = [System.Environment]::ExpandEnvironmentVariables($vssCachePath) 
        $null = [System.IO.Path]::GetFullPath($expandedVssCachePath) 
        $parentDir = Split-Path -Path $expandedVssCachePath
        if ( ($null -ne $parentDir) -and (-not ([string]::IsNullOrEmpty($parentDir))) -and (-not (Test-Path -Path $parentDir -PathType Container)) ) {
             if ($IsTestConfigMode.IsPresent) {
                 Write-LogMessage "[INFO] VSSMetadataCachePath parent directory '$parentDir' does not exist (Test Mode: Informational)." -Level "INFO"
            }
        }
    } catch {
        $validationMessages.Add("Global 'VSSMetadataCachePath' ('$vssCachePath') is not a valid path format after expansion.")
    }

    $sevenZipPath = Get-ConfigValue -ConfigObject $loadedConfiguration -Key 'SevenZipPath' -DefaultValue $null
    if ([string]::IsNullOrWhiteSpace($sevenZipPath)) {
        $validationMessages.Add("Global 'SevenZipPath' is missing or empty in the configuration.")
    } elseif (-not (Test-Path -LiteralPath $sevenZipPath -PathType Leaf)) {
        $validationMessages.Add("Global 'SevenZipPath' ('$sevenZipPath') does not point to a valid file.")
    }

    $defaultDateFormat = Get-ConfigValue -ConfigObject $loadedConfiguration -Key 'DefaultArchiveDateFormat' -DefaultValue "yyyy-MMM-dd"
    if (-not ([string]$defaultDateFormat).Trim()) {
        $validationMessages.Add("Global 'DefaultArchiveDateFormat' cannot be empty if defined.")
    } else {
        try { Get-Date -Format $defaultDateFormat -ErrorAction Stop | Out-Null }
        catch { $validationMessages.Add("Global 'DefaultArchiveDateFormat' ('$defaultDateFormat') is not a valid date format string.") }
    }
 
    # UPDATED: Validate PauseBeforeExit with new string options
    $pauseSetting = Get-ConfigValue -ConfigObject $loadedConfiguration -Key 'PauseBeforeExit' -DefaultValue "OnFailureOrWarning" 
    $validPauseOptions = @('true', 'false', 'always', 'never', 'onfailure', 'onwarning', 'onfailureorwarning')
    if ($null -ne $pauseSetting) {
        if ($pauseSetting -is [bool]) {
            # Boolean true/false is acceptable and will be handled by the main script
        } elseif ($pauseSetting -is [string] -and $pauseSetting.ToString().ToLowerInvariant() -in $validPauseOptions) {
            # String is one of the valid options
        } else {
            $validationMessages.Add("Global 'PauseBeforeExit' has an invalid value ('$pauseSetting'). Must be boolean (`$true`/`$false`) or one of the strings (case-insensitive): $($validPauseOptions -join ', ').")
        }
    }


    if (-not ($loadedConfiguration.BackupLocations -is [hashtable])) {
        $validationMessages.Add("Global 'BackupLocations' is missing or is not a valid Hashtable.")
    } elseif ($loadedConfiguration.BackupLocations.Count -eq 0 -and -not $IsTestConfigMode.IsPresent) {
         Write-LogMessage "[WARNING] 'BackupLocations' is empty. No jobs to run unless specified by -BackupLocationName (which also requires definition)." -Level "WARNING"
    } else {
        if ($null -ne $loadedConfiguration.BackupLocations) {
            foreach ($jobKey in $loadedConfiguration.BackupLocations.Keys) {
                $jobConfig = $loadedConfiguration.BackupLocations[$jobKey]
                if (-not ($jobConfig -is [hashtable])) {
                    $validationMessages.Add("BackupLocation '$jobKey' is not a valid Hashtable.")
                    continue
                }
                if ([string]::IsNullOrWhiteSpace((Get-ConfigValue -ConfigObject $jobConfig -Key 'Path' -DefaultValue $null))) {
                    $validationMessages.Add("BackupLocation '$jobKey': 'Path' is missing or empty.")
                }
                if ([string]::IsNullOrWhiteSpace((Get-ConfigValue -ConfigObject $jobConfig -Key 'Name' -DefaultValue $null))) {
                    $validationMessages.Add("BackupLocation '$jobKey': 'Name' (base archive name) is missing or empty.")
                }
                
                if ($null -ne $jobConfig -and $jobConfig.ContainsKey('ArchiveExtension')) { 
                    $userArchiveExt = $jobConfig['ArchiveExtension']
                     if (-not ($userArchiveExt -match "^\.[a-zA-Z0-9]+([a-zA-Z0-9\.]*[a-zA-Z0-9]+)?$")) { 
                        $validationMessages.Add("BackupLocation '$jobKey': 'ArchiveExtension' ('$userArchiveExt') is invalid. Must start with '.' and contain valid extension characters (e.g., '.zip', '.7z', '.tar.gz').")
                    }
                }
                if ($null -ne $jobConfig -and $jobConfig.ContainsKey('ArchiveDateFormat')) {
                    $jobDateFormat = $jobConfig['ArchiveDateFormat']
                    if (-not ([string]$jobDateFormat).Trim()) {
                        $validationMessages.Add("BackupLocation '$jobKey': 'ArchiveDateFormat' cannot be empty if defined.")
                    } else {
                        try { Get-Date -Format $jobDateFormat -ErrorAction Stop | Out-Null }
                        catch { $validationMessages.Add("BackupLocation '$jobKey': 'ArchiveDateFormat' ('$jobDateFormat') is not a valid date format string.") }
                    }
                }
            }
        }
    }

    $defaultArchiveExtGlobal = Get-ConfigValue -ConfigObject $loadedConfiguration -Key 'DefaultArchiveExtension' -DefaultValue ".7z"
    if (-not ($defaultArchiveExtGlobal -match "^\.[a-zA-Z0-9]+([a-zA-Z0-9\.]*[a-zA-Z0-9]+)?$")) {
        $validationMessages.Add("Global 'DefaultArchiveExtension' ('$defaultArchiveExtGlobal') is invalid. Must start with '.' and contain valid extension characters.")
    }

    if ($loadedConfiguration.ContainsKey('BackupSets') -and $loadedConfiguration['BackupSets'] -is [hashtable]) {
        foreach ($setKey in $loadedConfiguration['BackupSets'].Keys) {
            $setConfig = $loadedConfiguration['BackupSets'][$setKey]
            if (-not ($setConfig -is [hashtable])) {
                $validationMessages.Add("BackupSet '$setKey' is not a valid Hashtable.")
                continue
            }
            $jobNames = @(Get-ConfigValue -ConfigObject $setConfig -Key 'JobNames' -DefaultValue @())
            if (-not ($jobNames -is [array]) -or $jobNames.Count -eq 0) {
                $validationMessages.Add("BackupSet '$setKey': 'JobNames' is missing, not an array, or is empty.")
            } else {
                foreach ($jobNameInSetCandidate in $jobNames) {
                    if ([string]::IsNullOrWhiteSpace($jobNameInSetCandidate)) { continue }
                    $jobNameInSet = $jobNameInSetCandidate.Trim()
                    if ($loadedConfiguration.ContainsKey('BackupLocations') -and $loadedConfiguration['BackupLocations'] -is [hashtable] -and -not $loadedConfiguration['BackupLocations'].ContainsKey($jobNameInSet)) {
                        $validationMessages.Add("BackupSet '$setKey': Job '$jobNameInSet' is not defined in 'BackupLocations'.")
                    } elseif (-not ($loadedConfiguration.ContainsKey('BackupLocations') -and $loadedConfiguration['BackupLocations'] -is [hashtable])) {
                        $validationMessages.Add("BackupSet '$setKey': Cannot validate Job '$jobNameInSet' because 'BackupLocations' is not a valid Hashtable or is missing.")
                    }
                }
            }
            $onError = Get-ConfigValue -ConfigObject $setConfig -Key 'OnErrorInJob' -DefaultValue "StopSet"
            if ($onError -notin @("StopSet", "ContinueSet")) {
                $validationMessages.Add("BackupSet '$setKey': 'OnErrorInJob' has an invalid value ('$onError'). Must be 'StopSet' or 'ContinueSet'.")
            }
        }
    } elseif ($loadedConfiguration.ContainsKey('BackupSets') -and -not ($loadedConfiguration['BackupSets'] -is [hashtable])) {
        $validationMessages.Add("Global 'BackupSets' exists but is not a valid Hashtable.")
    }

    if ($validationMessages.Count -gt 0) {
        Write-LogMessage "Configuration validation failed with the following errors:" -Level "ERROR" -ForegroundColour $Global:ColourError
        $validationMessages | ForEach-Object { Write-LogMessage "  - $_" -Level "ERROR" -ForegroundColour $Global:ColourError }
        return @{ IsValid = $false; ErrorMessage = "Configuration validation failed." }
    }

    return @{ IsValid = $true; Configuration = $loadedConfiguration; ActualPath = $resolvedConfigPath }
}
#endregion

#region --- Job/Set Resolution Function ---
function Get-JobsToProcess {
    [CmdletBinding()]
    param(
        [hashtable]$Config,
        [string]$SpecifiedJobName,
        [string]$SpecifiedSetName
    )
    $jobsToRun = [System.Collections.Generic.List[string]]::new()
    $setName = $null
    $stopSetOnErrorPolicy = $true 

    if (-not [string]::IsNullOrWhiteSpace($SpecifiedSetName)) {
        Write-LogMessage "`n[INFO] Backup Set specified: '$SpecifiedSetName'" -ForegroundColour $Global:ColourValue
        if ($Config.ContainsKey('BackupSets') -and $Config['BackupSets'] -is [hashtable] -and $Config['BackupSets'].ContainsKey($SpecifiedSetName)) {
            $setDefinition = $Config['BackupSets'][$SpecifiedSetName]
            $setName = $SpecifiedSetName
            $jobNamesInSet = @(Get-ConfigValue -ConfigObject $setDefinition -Key 'JobNames' -DefaultValue @())
            if ($jobNamesInSet -is [array] -and $jobNamesInSet.Count -gt 0) {
                $jobNamesInSet | ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_)) {$jobsToRun.Add($_.Trim())} }
                if ($jobsToRun.Count -eq 0) {
                     return @{ Success = $false; ErrorMessage = "Backup Set '$setName' has no valid 'JobNames' defined (all entries were empty or whitespace)." }
                }
                $stopSetOnErrorPolicy = if ((Get-ConfigValue -ConfigObject $setDefinition -Key 'OnErrorInJob' -DefaultValue "StopSet") -eq "ContinueSet") { $false } else { $true }
                Write-LogMessage "  - Jobs in set '$setName': $($jobsToRun -join ', ')"
                Write-LogMessage "  - On error in job for this set: $(if($stopSetOnErrorPolicy){'StopSet'}else{'ContinueSet'})"
            } else {
                return @{ Success = $false; ErrorMessage = "Backup Set '$setName' has no valid 'JobNames' defined or is empty." }
            }
        } else {
            $availableSetsMessage = "No Backup Sets are defined in the configuration."
            if ($Config.ContainsKey('BackupSets') -and $Config['BackupSets'] -is [hashtable] -and $Config['BackupSets'].Keys.Count -gt 0) {
                $setNameList = $Config['BackupSets'].Keys | Sort-Object | ForEach-Object { "`"$_`"" } 
                $availableSetsMessage = "Available Backup Sets: $($setNameList -join ', ')."
            }
            return @{ Success = $false; ErrorMessage = "Backup Set '$SpecifiedSetName' not found in configuration. $availableSetsMessage" }
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($SpecifiedJobName)) {
        if ($Config.ContainsKey('BackupLocations') -and $Config['BackupLocations'] -is [hashtable] -and $Config['BackupLocations'].ContainsKey($SpecifiedJobName)) {
            $jobsToRun.Add($SpecifiedJobName)
            Write-LogMessage "`n[INFO] Single Backup Location specified: '$SpecifiedJobName'" -ForegroundColour $Global:ColourValue
        } else {
            $availableJobsMessage = "No Backup Locations are defined in the configuration."
            if ($Config.ContainsKey('BackupLocations') -and $Config['BackupLocations'] -is [hashtable] -and $Config['BackupLocations'].Keys.Count -gt 0) {
                $jobNameList = $Config['BackupLocations'].Keys | Sort-Object | ForEach-Object { "`"$_`"" } 
                $availableJobsMessage = "Available Backup Locations: $($jobNameList -join ', ')."
            }
            return @{ Success = $false; ErrorMessage = "Specified BackupLocationName '$SpecifiedJobName' not found in configuration. $availableJobsMessage" }
        }
    } else { 
        $jobCount = 0
        if ($Config.ContainsKey('BackupLocations') -and $Config['BackupLocations'] -is [hashtable]) {
            $jobCount = $Config['BackupLocations'].Count
        }

        if ($jobCount -eq 1) {
            $singleJobKey = ($Config['BackupLocations'].Keys | Select-Object -First 1) 
            $jobsToRun.Add($singleJobKey)
            Write-LogMessage "`n[INFO] No job or set specified. Automatically selected single defined Backup Location: '$singleJobKey'" -ForegroundColour $Global:ColourSuccess
        } elseif ($jobCount -eq 0) {
            return @{ Success = $false; ErrorMessage = "No BackupLocationName or RunSet specified, and no Backup Locations are defined in the configuration." }
        } else { 
            $errorMessage = "No BackupLocationName or RunSet specified. Please choose one of the following:"
            $availableJobsMessage = "`n  Available Backup Locations (use -BackupLocationName ""Job Name""):" 
            if ($Config.ContainsKey('BackupLocations') -and $Config['BackupLocations'] -is [hashtable] -and $Config['BackupLocations'].Keys.Count -gt 0) {
                $Config['BackupLocations'].Keys | Sort-Object | ForEach-Object { $availableJobsMessage += "`n    - $_" }
            } else {
                $availableJobsMessage += "`n    (None defined)"
            }
            
            $availableSetsMessage = "`n  Available Backup Sets (use -RunSet ""Set Name""):" 
            if ($Config.ContainsKey('BackupSets') -and $Config['BackupSets'] -is [hashtable] -and $Config['BackupSets'].Keys.Count -gt 0) {
                $Config['BackupSets'].Keys | Sort-Object | ForEach-Object { $availableSetsMessage += "`n    - $_" }
            } else {
                $availableSetsMessage += "`n    (None defined)"
            }
            return @{ Success = $false; ErrorMessage = "$($errorMessage)$($availableJobsMessage)$($availableSetsMessage)" }
        }
    }

    if ($jobsToRun.Count -eq 0) {
        return @{ Success = $false; ErrorMessage = "No backup jobs determined to process after initial checks." }
    }

    return @{ Success = $true; JobsToRun = $jobsToRun; SetName = $setName; StopSetOnErrorPolicy = $stopSetOnErrorPolicy }
}
#endregion

#region --- Exported Functions ---
Export-ModuleMember -Function Write-LogMessage, Get-ConfigValue, Test-AdminPrivileges, Invoke-HookScript, Get-ArchiveSizeFormatted, Import-AppConfiguration, Get-JobsToProcess
#endregion
