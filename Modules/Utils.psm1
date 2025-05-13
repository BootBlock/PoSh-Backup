# PowerShell Module: Utils.psm1
# Version 1.0: Updated PauseBeforeExit validation to include new string options (Always, Never, OnFailure, etc.).
# Version 1.1: Added User Configuration Override (User.psd1) and deep merge functionality.
# Version 1.2: Added auto-detection for 7-Zip executable.
# Version 1.4: Moved schema validation to PoShBackupValidator.psm1 (optional) and refined 7zip path detection.

#region --- Private Helper Functions ---
function Merge-DeepHashtables {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Base,
        [Parameter(Mandatory)]
        [hashtable]$Override
    )

    $merged = $Base.Clone() # Start with a copy of the base to avoid modifying the original $Base in place

    foreach ($key in $Override.Keys) {
        if ($merged.ContainsKey($key) -and $merged[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) {
            # Key exists in both and both values are hashtables, so recurse
            $merged[$key] = Merge-DeepHashtables -Base $merged[$key] -Override $Override[$key]
        }
        else {
            # Override value takes precedence, or a new key is added
            # This also handles cases where the type might change (e.g., base has a string, override has a bool)
            $merged[$key] = $Override[$key]
        }
    }
    return $merged
}

function Find-SevenZipExecutable {
    [CmdletBinding()]
    param()

    Write-LogMessage "  - Attempting to auto-detect 7z.exe..." -Level "DEBUG"
    $commonPaths = @(
        (Join-Path -Path $env:ProgramFiles -ChildPath "7-Zip\7z.exe"),
        (Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath "7-Zip\7z.exe") # Check x86 path if it exists
    )

    foreach ($pathAttempt in $commonPaths) {
        if ($null -ne $pathAttempt -and (Test-Path -LiteralPath $pathAttempt -PathType Leaf)) {
            Write-LogMessage "    - Auto-detected 7z.exe at '$pathAttempt' (common location)." -Level "INFO"
            return $pathAttempt
        }
    }

    try {
        $pathFromCommand = (Get-Command 7z.exe -ErrorAction SilentlyContinue).Source
        if (-not [string]::IsNullOrWhiteSpace($pathFromCommand) -and (Test-Path -LiteralPath $pathFromCommand -PathType Leaf)) {
            Write-LogMessage "    - Auto-detected 7z.exe at '$pathFromCommand' (from system PATH)." -Level "INFO"
            return $pathFromCommand
        }
    }
    catch {
        # Get-Command might throw if not found, even with SilentlyContinue for some errors.
        Write-LogMessage "    - 7z.exe not found in system PATH (Get-Command)." -Level "DEBUG"
    }
    
    Write-LogMessage "    - Auto-detection failed to find 7z.exe in common locations or system PATH." -Level "DEBUG"
    return $null
}
#endregion --- Private Helper Functions ---

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

    $finalConfiguration = $null
    $baseConfigPath = $null
    $userConfigPath = $null
    $userConfigLoadedSuccessfully = $false
    $primaryConfigPathForReturn = $null 

    $defaultConfigDir = Join-Path -Path $MainScriptPSScriptRoot -ChildPath "Config"
    $defaultBaseConfigFileName = "Default.psd1"
    $defaultUserConfigFileName = "User.psd1" 

    $defaultBaseConfigPath = Join-Path -Path $defaultConfigDir -ChildPath $defaultBaseConfigFileName
    $defaultUserConfigPath = Join-Path -Path $defaultConfigDir -ChildPath $defaultUserConfigFileName

    if (-not [string]::IsNullOrWhiteSpace($UserSpecifiedPath)) {
        Write-LogMessage "`n[INFO] Using specified configuration file: $($UserSpecifiedPath)"
        $primaryConfigPathForReturn = $UserSpecifiedPath
        if (-not (Test-Path -LiteralPath $UserSpecifiedPath -PathType Leaf)) {
            Write-LogMessage "FATAL: Specified configuration file '$UserSpecifiedPath' not found." -Level "ERROR" -ForegroundColour $Global:ColourError
            return @{ IsValid = $false; ErrorMessage = "Configuration file not found at '$UserSpecifiedPath'." }
        }
        try {
            $finalConfiguration = Import-PowerShellDataFile -LiteralPath $UserSpecifiedPath -ErrorAction Stop
            Write-LogMessage "  - Configuration loaded successfully from '$UserSpecifiedPath'." -ForegroundColour $Global:ColourSuccess
        } catch {
            Write-LogMessage "FATAL: Could not load or parse specified configuration file '$UserSpecifiedPath'. Error: $($_.Exception.Message)" -Level "ERROR" -ForegroundColour $Global:ColourError
            return @{ IsValid = $false; ErrorMessage = "Failed to parse configuration file '$UserSpecifiedPath': $($_.Exception.Message)" }
        }
    } else {
        $baseConfigPath = $defaultBaseConfigPath
        $userConfigPath = $defaultUserConfigPath
        $primaryConfigPathForReturn = $baseConfigPath
        Write-LogMessage "`n[INFO] No -ConfigFile specified. Loading base configuration from: $($baseConfigPath)"
        if (-not (Test-Path -LiteralPath $baseConfigPath -PathType Leaf)) {
            Write-LogMessage "FATAL: Base configuration file '$baseConfigPath' not found. This file is required." -Level "ERROR" -ForegroundColour $Global:ColourError
            return @{ IsValid = $false; ErrorMessage = "Base configuration file '$baseConfigPath' not found." }
        }
        try {
            $loadedBaseConfiguration = Import-PowerShellDataFile -LiteralPath $baseConfigPath -ErrorAction Stop
            Write-LogMessage "  - Base configuration loaded successfully from '$baseConfigPath'." -ForegroundColour $Global:ColourSuccess
            $finalConfiguration = $loadedBaseConfiguration
        } catch {
            Write-LogMessage "FATAL: Could not load or parse base configuration file '$baseConfigPath'. Error: $($_.Exception.Message)" -Level "ERROR" -ForegroundColour $Global:ColourError
            return @{ IsValid = $false; ErrorMessage = "Failed to parse base configuration file '$baseConfigPath': $($_.Exception.Message)" }
        }
        Write-LogMessage "[INFO] Checking for user override configuration at: $($userConfigPath)"
        if (Test-Path -LiteralPath $userConfigPath -PathType Leaf) {
            try {
                $loadedUserConfiguration = Import-PowerShellDataFile -LiteralPath $userConfigPath -ErrorAction Stop
                if ($null -ne $loadedUserConfiguration -and $loadedUserConfiguration -is [hashtable]) {
                    Write-LogMessage "  - User override configuration '$userConfigPath' found and loaded successfully." -ForegroundColour $Global:ColourSuccess
                    Write-LogMessage "  - Merging user configuration over base configuration..." -Level "DEBUG"
                    $finalConfiguration = Merge-DeepHashtables -Base $finalConfiguration -Override $loadedUserConfiguration
                    $userConfigLoadedSuccessfully = $true
                    Write-LogMessage "  - User configuration merged successfully." -ForegroundColour $Global:ColourSuccess
                } else {
                    Write-LogMessage "[WARNING] User override configuration file '$userConfigPath' did not load as a valid hashtable. Skipping user overrides." -Level "WARNING" -ForegroundColour $Global:ColourWarning
                }
            } catch {
                Write-LogMessage "[WARNING] Could not load or parse user override configuration file '$userConfigPath'. Error: $($_.Exception.Message). Using base configuration only." -Level "WARNING" -ForegroundColour $Global:ColourWarning
            }
        } else {
            Write-LogMessage "  - User override configuration file '$userConfigPath' not found. Using base configuration only."
        }
    }

    if ($null -eq $finalConfiguration -or -not ($finalConfiguration -is [hashtable])) {
        Write-LogMessage "FATAL: Final configuration is not a valid hashtable after loading/merging." -Level "ERROR" -ForegroundColour $Global:ColourError
        return @{ IsValid = $false; ErrorMessage = "Final configuration is not a valid hashtable." }
    }
    
    $validationMessages = [System.Collections.Generic.List[string]]::new()

    # --- Optional Advanced Schema Validation ---
    $enableAdvancedValidation = Get-ConfigValue -ConfigObject $finalConfiguration -Key 'EnableAdvancedSchemaValidation' -DefaultValue $false
    if ($enableAdvancedValidation -eq $true) {
        Write-LogMessage "[INFO] Advanced Schema Validation is enabled. Attempting to load PoShBackupValidator module..." -Level "INFO"
        try {
            Import-Module -Name (Join-Path -Path $MainScriptPSScriptRoot -ChildPath "Modules\PoShBackupValidator.psm1") -Force -ErrorAction Stop
            Write-LogMessage "  - PoShBackupValidator module loaded. Performing schema validation..." -Level "DEBUG"
            # Invoke the validation function from the external module
            Invoke-PoShBackupConfigValidation -ConfigurationToValidate $finalConfiguration -ValidationMessagesListRef ([ref]$validationMessages)
            if ($IsTestConfigMode.IsPresent -and $validationMessages.Count -eq 0) { # Only log success if in test mode and no existing messages
                 Write-LogMessage "[SUCCESS] Advanced schema validation completed successfully (no new errors found by schema)." -Level "CONFIG_TEST" -ForegroundColour $Global:ColourSuccess
            }
        } catch {
            Write-LogMessage "[WARNING] Could not load or execute PoShBackupValidator module. Advanced schema validation will be skipped. Error: $($_.Exception.Message)" -Level "WARNING"
        }
    } else {
        if ($IsTestConfigMode.IsPresent) { 
            Write-LogMessage "[INFO] Advanced Schema Validation is disabled in the configuration ('EnableAdvancedSchemaValidation' is `$false or missing)." -Level "CONFIG_TEST"
        }
    }
    # --- End Optional Advanced Schema Validation ---

    # --- Specific Value Validations (these remain important) ---
    $vssCachePath = Get-ConfigValue -ConfigObject $finalConfiguration -Key 'VSSMetadataCachePath' -DefaultValue "%TEMP%\diskshadow_cache_poshbackup.cab" 
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

    # Handle SevenZipPath: Use configured, or auto-detect, then validate final path.
    $sevenZipPathFromConfigOriginal = Get-ConfigValue -ConfigObject $finalConfiguration -Key 'SevenZipPath' -DefaultValue $null
    $sevenZipPathSource = "configuration"

    if (-not ([string]::IsNullOrWhiteSpace($finalConfiguration.SevenZipPath)) -and (Test-Path -LiteralPath $finalConfiguration.SevenZipPath -PathType Leaf)) {
        # Path is already good in $finalConfiguration (either from config or previous auto-detection)
        if ($IsTestConfigMode.IsPresent) {
             # Determine source for logging if it wasn't explicitly set by auto-detection below
            if ($sevenZipPathFromConfigOriginal -ne $finalConfiguration.SevenZipPath -and (-not [string]::IsNullOrWhiteSpace($finalConfiguration.SevenZipPath))) {
                $sevenZipPathSource = "auto-detected" # Generic if source unclear
            }
            Write-LogMessage "  - Effective 7-Zip Path: '$($finalConfiguration.SevenZipPath)' (Source: $sevenZipPathSource)." -Level "CONFIG_TEST"
        }
    } else { # Path in $finalConfiguration is bad or empty, try to resolve
        $initialPathIsEmpty = [string]::IsNullOrWhiteSpace($sevenZipPathFromConfigOriginal)
        if (-not $initialPathIsEmpty) {
            Write-LogMessage "[WARNING] Configured 'SevenZipPath' ('$sevenZipPathFromConfigOriginal') is invalid or not found. Attempting auto-detection..." -Level "WARNING"
        } else {
            Write-LogMessage "[INFO] 'SevenZipPath' is empty in configuration. Attempting auto-detection..." -Level "INFO"
        }
        
        $foundPath = Find-SevenZipExecutable
        if ($null -ne $foundPath) {
            $finalConfiguration.SevenZipPath = $foundPath # Update the configuration
            $sevenZipPathSource = if ($initialPathIsEmpty) { "auto-detected (config empty)" } else { "auto-detected (config invalid)" }
            Write-LogMessage "[INFO] Using auto-detected 7-Zip Path: '$foundPath'." -Level "INFO"
            if ($IsTestConfigMode.IsPresent) {
                Write-LogMessage "  - Effective 7-Zip Path set to: '$foundPath' (Source: $sevenZipPathSource)." -Level "CONFIG_TEST"
            }
        } else {
            $errorMsg = if ($initialPathIsEmpty) {
                "CRITICAL: 'SevenZipPath' is empty in config and auto-detection failed. PoSh-Backup cannot function."
            } else {
                "CRITICAL: Configured 'SevenZipPath' ('$sevenZipPathFromConfigOriginal') is invalid, and auto-detection failed. PoSh-Backup cannot function."
            }
            if (-not $validationMessages.Contains($errorMsg)) { $validationMessages.Add($errorMsg) }
        }
    }
    # Final check, ensuring no silent failure if $finalConfiguration.SevenZipPath remains bad after all attempts
    if ([string]::IsNullOrWhiteSpace($finalConfiguration.SevenZipPath) -or (-not (Test-Path -LiteralPath $finalConfiguration.SevenZipPath -PathType Leaf))) {
        $criticalErrorMsg = "CRITICAL: Effective 'SevenZipPath' ('$($finalConfiguration.SevenZipPath)') is invalid or not found after all checks."
        if (-not $validationMessages.Contains($criticalErrorMsg) -and `
            -not $validationMessages.Contains("CRITICAL: 'SevenZipPath' is empty in config and auto-detection failed. PoSh-Backup cannot function.") -and `
            -not $validationMessages.Contains("CRITICAL: Configured 'SevenZipPath' ('$sevenZipPathFromConfigOriginal') is invalid, and auto-detection failed. PoSh-Backup cannot function.") ) {
             $validationMessages.Add($criticalErrorMsg)
        }
    }


    $defaultDateFormat = Get-ConfigValue -ConfigObject $finalConfiguration -Key 'DefaultArchiveDateFormat' -DefaultValue "yyyy-MMM-dd"
    if ($finalConfiguration.ContainsKey('DefaultArchiveDateFormat')) { 
        if (-not ([string]$defaultDateFormat).Trim()) {
            $validationMessages.Add("Global 'DefaultArchiveDateFormat' cannot be empty if defined.")
        } else {
            try { Get-Date -Format $defaultDateFormat -ErrorAction Stop | Out-Null }
            catch { $validationMessages.Add("Global 'DefaultArchiveDateFormat' ('$defaultDateFormat') is not a valid date format string.") }
        }
    }
 
    $pauseSetting = Get-ConfigValue -ConfigObject $finalConfiguration -Key 'PauseBeforeExit' -DefaultValue "OnFailureOrWarning" 
    if ($finalConfiguration.ContainsKey('PauseBeforeExit')) {
        $validPauseOptions = @('true', 'false', 'always', 'never', 'onfailure', 'onwarning', 'onfailureorwarning')
        if (!($pauseSetting -is [bool] -or ($pauseSetting -is [string] -and $pauseSetting.ToString().ToLowerInvariant() -in $validPauseOptions))) {
            $validationMessages.Add("Global 'PauseBeforeExit' ('$pauseSetting') has an invalid value or type. Check schema definition or documentation.")
        }
    }

    if (($null -eq $finalConfiguration.BackupLocations -or $finalConfiguration.BackupLocations.Count -eq 0) -and -not $IsTestConfigMode.IsPresent `
        -and -not ($PSBoundParameters.ContainsKey('ListBackupLocations') -and $ListBackupLocations.IsPresent) `
        -and -not ($PSBoundParameters.ContainsKey('ListBackupSets') -and $ListBackupSets.IsPresent) ) {
         Write-LogMessage "[WARNING] 'BackupLocations' is empty. No jobs to run unless specified by -BackupLocationName (which also requires definition)." -Level "WARNING"
    } else {
        if ($null -ne $finalConfiguration.BackupLocations -and $finalConfiguration.BackupLocations -is [hashtable]) {
            foreach ($jobKey in $finalConfiguration.BackupLocations.Keys) {
                $jobConfig = $finalConfiguration.BackupLocations[$jobKey]
                # Specific format checks that complement schema validation
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

    if ($finalConfiguration.ContainsKey('DefaultArchiveExtension')) {
        $defaultArchiveExtGlobal = Get-ConfigValue -ConfigObject $finalConfiguration -Key 'DefaultArchiveExtension' -DefaultValue ".7z"
        if (-not ($defaultArchiveExtGlobal -match "^\.[a-zA-Z0-9]+([a-zA-Z0-9\.]*[a-zA-Z0-9]+)?$")) {
            $validationMessages.Add("Global 'DefaultArchiveExtension' ('$defaultArchiveExtGlobal') is invalid. Must start with '.' and contain valid extension characters.")
        }
    }

    if ($finalConfiguration.ContainsKey('BackupSets') -and $finalConfiguration.BackupSets -is [hashtable]) {
        foreach ($setKey in $finalConfiguration.BackupSets.Keys) {
            $setConfig = $finalConfiguration.BackupSets[$setKey]
            if ($setConfig -is [hashtable]) { # Schema would catch if $setConfig is not a hashtable
                $jobNames = @(Get-ConfigValue -ConfigObject $setConfig -Key 'JobNames' -DefaultValue @())
                if ($jobNames.Count -gt 0) { # Schema ensures JobNames is an array and required
                    foreach ($jobNameInSetCandidate in $jobNames) {
                        if ([string]::IsNullOrWhiteSpace($jobNameInSetCandidate)) { continue } # Schema doesn't check content of array items
                        $jobNameInSet = $jobNameInSetCandidate.Trim()
                        if ($finalConfiguration.ContainsKey('BackupLocations') -and $finalConfiguration.BackupLocations -is [hashtable] -and -not $finalConfiguration.BackupLocations.ContainsKey($jobNameInSet)) {
                            $validationMessages.Add("BackupSet '$setKey': Job '$jobNameInSet' is not defined in 'BackupLocations'.")
                        } elseif (-not ($finalConfiguration.ContainsKey('BackupLocations') -and $finalConfiguration.BackupLocations -is [hashtable])) {
                            $validationMessages.Add("BackupSet '$setKey': Cannot validate Job '$jobNameInSet' because 'BackupLocations' is not a valid Hashtable or is missing.")
                        }
                    }
                }
            }
        }
    }
    
    if ($validationMessages.Count -gt 0) {
        Write-LogMessage "Configuration validation failed with the following errors:" -Level "ERROR" -ForegroundColour $Global:ColourError
        # Deduplicate messages before printing
        ($validationMessages | Select-Object -Unique) | ForEach-Object { Write-LogMessage "  - $_" -Level "ERROR" -ForegroundColour $Global:ColourError }
        return @{ IsValid = $false; ErrorMessage = "Configuration validation failed." }
    }

    return @{ 
        IsValid = $true; 
        Configuration = $finalConfiguration; 
        ActualPath = $primaryConfigPathForReturn; 
        UserConfigLoaded = $userConfigLoadedSuccessfully;
        UserConfigPath = if($userConfigLoadedSuccessfully -or (Test-Path -LiteralPath $defaultUserConfigPath -PathType Leaf)) {$defaultUserConfigPath} else {$null}
    }
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
