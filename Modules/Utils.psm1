<#
.SYNOPSIS
    Provides a collection of essential utility functions for the PoSh-Backup script.
    These include capabilities for logging, configuration value retrieval, administrative
    privilege checks, external hook script execution, archive size formatting, comprehensive
    application configuration import and validation, and resolving which backup jobs or sets to process.

.DESCRIPTION
    This module centralises common helper functions used throughout the PoSh-Backup solution,
    promoting code reusability, consistency, and maintainability. It handles tasks that are
    not specific to the core backup operations or report generation but are essential for the
    overall script's robust functionality and user experience.

    Key exported functions include:
    - Write-LogMessage: For standardised console and file logging with colour-coding.
    - Get-ConfigValue: Safely retrieves values from configuration hashtables with default fallbacks.
    - Test-AdminPrivilege: Checks if the script is running with administrator privileges.
    - Invoke-HookScript: Executes user-defined PowerShell scripts at various hook points.
    - Get-ArchiveSizeFormatted: Converts byte sizes to human-readable formats (KB, MB, GB).
    - Import-AppConfiguration: Loads, merges (Default.psd1 and User.psd1), and validates the
      PoSh-Backup configuration. It also handles 7-Zip path auto-detection by calling the
      Find-SevenZipExecutable function from the 7ZipManager.psm1 module.
    - Get-JobsToProcess: Determines the list of backup jobs to execute based on command-line
      parameters or default configuration rules.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.8.0 # Removed Find-SevenZipExecutable (moved to 7ZipManager.psm1).
    DateCreated:    10-May-2025
    LastModified:   17-May-2025
    Purpose:        Core utility functions for the PoSh-Backup solution.
    Prerequisites:  PowerShell 5.1+. Some functions may have dependencies on specific global
                    variables (e.g., $Global:StatusToColourMap) being set by the main script.
                    The 7ZipManager.psm1 module should be imported by the main script for
                    Find-SevenZipExecutable to be available to Import-AppConfiguration.
#>

#region --- Private Helper Functions ---
# Merges two hashtables deeply. If a key exists in both and its values are hashtables,
# they are recursively merged. Otherwise, the override value takes precedence.
function Merge-DeepHashtable {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Base,
        [Parameter(Mandatory)]
        [hashtable]$Override
    )

    $merged = $Base.Clone() # Start with a clone of the base hashtable

    foreach ($key in $Override.Keys) {
        if ($merged.ContainsKey($key) -and $merged[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) {
            # If key exists in both and both values are hashtables, recurse
            $merged[$key] = Merge-DeepHashtable -Base $merged[$key] -Override $Override[$key]
        }
        else {
            # Otherwise, the override value replaces or adds the key
            $merged[$key] = $Override[$key]
        }
    }
    return $merged
}

# Removed Find-SevenZipExecutable - It has been moved to Modules\7ZipManager.psm1
#endregion --- Private Helper Functions ---

#region --- Logging Function ---
function Write-LogMessage {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Writes a formatted log message to the console and, if enabled, to a job-specific log file
        and a global in-memory log entry list.
    .DESCRIPTION
        This function provides standardised logging capabilities for the PoSh-Backup script.
        It supports different message levels which can influence console colour output via the
        globally defined $Global:StatusToColourMap hashtable.
    .PARAMETER Message
        The log message string to write.
    .PARAMETER ForegroundColour
        The PowerShell console foreground colour to use for the message.
        Defaults to $Global:ColourInfo (typically Cyan). This is overridden if the specified
        'Level' has a corresponding entry in $Global:StatusToColourMap.
    .PARAMETER NoNewLine
        If specified, the message is written to the console without a trailing newline character.
    .PARAMETER Level
        A string indicating the severity or type of the log message (e.g., "INFO", "WARNING", "ERROR", "DEBUG", "VSS", "HOOK").
        This level is used to prefix the message in the file log and can determine the console colour
        if a mapping exists in $Global:StatusToColourMap. Defaults to "INFO".
        A level of "NONE" will suppress output to the file log and use the host's current foreground colour for console output unless $ForegroundColour is specified.
    .PARAMETER NoTimestampToLogFile
        If specified, the timestamp and level prefix are omitted from this specific message when writing
        to the job's text log file. Useful for multi-line output from external commands.
    .EXAMPLE
        Write-LogMessage "Backup job 'MyData' started successfully." -Level "SUCCESS"
    .EXAMPLE
        Write-LogMessage "Warning: File 'C:\temp\locked.docx' could not be accessed." -ForegroundColour Yellow -Level "WARNING"
    .EXAMPLE
        Write-LogMessage "Debug information: Variable X = $X" -Level "DEBUG"
    #>
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

    $effectiveConsoleColour = $ForegroundColour

    if ($Global:StatusToColourMap.ContainsKey($Level.ToUpperInvariant())) {
        $effectiveConsoleColour = $Global:StatusToColourMap[$Level.ToUpperInvariant()]
    } elseif ($Level.ToUpperInvariant() -eq 'NONE') {
        $effectiveConsoleColour = $Host.UI.RawUI.ForegroundColor
    }

    if ($NoNewLine) {
        Write-Host $consoleMessage -ForegroundColor $effectiveConsoleColour -NoNewline
    } else {
        Write-Host $consoleMessage -ForegroundColor $effectiveConsoleColour
    }

    # Add to in-memory log for potential inclusion in structured reports (e.g., HTML, JSON)
    if ($Global:GlobalJobLogEntries -is [System.Collections.Generic.List[object]]) {
        $Global:GlobalJobLogEntries.Add([PSCustomObject]@{
            Timestamp = if($NoTimestampToLogFile -and $Global:GlobalJobLogEntries.Count -gt 0) { "" } else { $timestamp } # Avoid repeating timestamp for continued lines
            Level     = $Level
            Message   = $Message
        })
    }

    # Write to physical log file if enabled
    if ($Global:GlobalEnableFileLogging -and $Global:GlobalLogFile -and $Level -ne "NONE") {
        try {
            Add-Content -Path $Global:GlobalLogFile -Value $logMessage -ErrorAction Stop
        } catch {
            # Fallback to Write-Host for critical log writing errors to avoid recursion
            Write-Host "CRITICAL: Failed to write to log file '$($Global:GlobalLogFile)'. Error: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}
#endregion

#region --- Helper Function Get-ConfigValue ---
function Get-ConfigValue {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Safely retrieves a value from a hashtable or PSObject, returning a default value if the key is not found.
    .DESCRIPTION
        This function provides a convenient way to access configuration settings. It checks if the
        provided configuration object (typically a hashtable) contains the specified key. If found,
        the key's value is returned. Otherwise, the provided default value is returned.
        It supports both hashtables and PSObjects with properties.
    .PARAMETER ConfigObject
        The configuration object (e.g., a hashtable loaded from a .psd1 file) to search.
    .PARAMETER Key
        The string name of the key or property whose value is to be retrieved.
    .PARAMETER DefaultValue
        The value to return if the key is not found in the ConfigObject or if ConfigObject is null.
    .EXAMPLE
        $timeout = Get-ConfigValue -ConfigObject $JobSettings -Key 'TimeoutSeconds' -DefaultValue 30
        # Retrieves 'TimeoutSeconds' from $JobSettings, or defaults to 30 if not found.
    .OUTPUTS
        System.Object
        The value associated with the key, or the DefaultValue.
    #>
    param (
        [object]$ConfigObject,
        [string]$Key,
        [object]$DefaultValue
    )
    if ($null -ne $ConfigObject -and $ConfigObject -is [hashtable] -and $ConfigObject.ContainsKey($Key)) {
        return $ConfigObject[$Key]
    }
    # Also handles PSObjects (like those from Import-CliXml or [PSCustomObject])
    elseif ($null -ne $ConfigObject -and -not ($ConfigObject -is [hashtable]) -and ($null -ne $ConfigObject.PSObject) -and ($null -ne $ConfigObject.PSObject.Properties.Name) -and $ConfigObject.PSObject.Properties.Name -contains $Key) {
        return $ConfigObject.$Key
    }
    return $DefaultValue
}
#endregion

#region --- Helper Function Test-AdminPrivilege ---
function Test-AdminPrivilege {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Checks if the current PowerShell session is running with Administrator privileges.
    .DESCRIPTION
        This function determines if the user executing the script has elevated (Administrator)
        privileges. This is crucial for operations like VSS that require such rights.
        It logs the result of the check.
    .OUTPUTS
        System.Boolean
        $true if running with Administrator privileges, $false otherwise.
    .EXAMPLE
        if (Test-AdminPrivilege) { Write-Host "Running as Admin." }
    #>
    param()
    Write-LogMessage "[INFO] Checking for Administrator privileges..." -Level "DEBUG"
    $currentUser = New-Object Security.Principal.WindowsPrincipal $([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        Write-LogMessage "  - Script is running with Administrator privileges." -Level "SUCCESS"
    } else {
        Write-LogMessage "  - Script is NOT running with Administrator privileges. VSS functionality will be unavailable." -Level "WARNING"
    }
    return $isAdmin
}
#endregion

#region --- Helper Function Invoke-HookScript ---
function Invoke-HookScript {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Executes a user-defined PowerShell script at a specified hook point during the backup process.
    .DESCRIPTION
        This function allows for custom actions to be performed at various stages of a backup job
        by executing an external PowerShell script. It handles parameter passing to the hook script
        and captures its output and exit code for logging and reporting.
    .PARAMETER ScriptPath
        The full path to the PowerShell script to be executed. If empty or the path is invalid,
        the hook is skipped.
    .PARAMETER HookType
        A string describing the type of hook (e.g., "PreBackup", "PostBackupOnSuccess").
        Used for logging purposes.
    .PARAMETER HookParameters
        A hashtable of parameters to pass to the hook script. These are passed as named
        command-line arguments to the script.
    .PARAMETER IsSimulateMode
        A switch. If present, the hook script execution will be simulated (logged as would-be-run)
        but not actually executed.
    .EXAMPLE
        Invoke-HookScript -ScriptPath "C:\Scripts\MyPreBackup.ps1" -HookType "PreBackup" -HookParameters @{ JobName = "MyJob"; TargetDir = "D:\Backup" }
    #>
    param(
        [string]$ScriptPath,
        [string]$HookType,
        [hashtable]$HookParameters,
        [switch]$IsSimulateMode
    )
    if ([string]::IsNullOrWhiteSpace($ScriptPath)) { return } # Skip if no script path is provided

    Write-LogMessage "`n[INFO] Attempting to execute $HookType script: $ScriptPath" -Level "HOOK"
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        Write-LogMessage "[WARNING] $HookType script not found at '$ScriptPath'. Skipping execution." -Level "WARNING"
        if ($Global:GlobalJobHookScriptData -is [System.Collections.Generic.List[object]]) {
            $Global:GlobalJobHookScriptData.Add([PSCustomObject]@{ Name = $HookType; Path = $ScriptPath; Status = "Not Found"; Output = "Script file not found at specified path."})
        }
        return
    }

    $outputLog = [System.Collections.Generic.List[string]]::new()
    $status = "Success" # Assume success unless an error occurs
    try {
        if ($IsSimulateMode.IsPresent) {
            Write-LogMessage "SIMULATE: Would execute $HookType script '$ScriptPath' with parameters: $($HookParameters | Out-String | ForEach-Object {$_.TrimEnd()})" -Level "SIMULATE"
            $outputLog.Add("SIMULATE: Script execution skipped due to simulation mode.")
            $status = "Simulated"
        } else {
            Write-LogMessage "  - Executing $HookType script: '$ScriptPath'" -Level "HOOK"
            $processArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
            $paramString = ""

            # Construct parameter string for powershell.exe
            foreach ($key in $HookParameters.Keys) {
                $value = $HookParameters[$key]
                if ($value -is [bool] -or $value -is [switch]) {
                    if ($value) { # For switches or booleans that are true
                        $paramString += " -$key"
                    }
                } elseif ($value -is [string] -and ($value.Contains(" ") -or $value.Contains("'") -or $value.Contains('"')) ) {
                    # Quote string parameters containing spaces or quotes
                    $escapedValueForCmd = $value -replace '"', '""' # Double up internal quotes for cmd.exe parsing
                    $paramString += " -$key " + '"' + $escapedValueForCmd + '"'
                } elseif ($null -ne $value) {
                    $paramString += " -$key $value"
                }
            }
            $processArgs += $paramString

            $tempStdOut = New-TemporaryFile
            $tempStdErr = New-TemporaryFile

            Write-LogMessage "    - PowerShell arguments for hook script: $processArgs" -Level "DEBUG"
            $proc = Start-Process powershell.exe -ArgumentList $processArgs -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $tempStdOut.FullName -RedirectStandardError $tempStdErr.FullName

            $stdOutContent = Get-Content $tempStdOut.FullName -Raw -ErrorAction SilentlyContinue
            $stdErrContent = Get-Content $tempStdErr.FullName -Raw -ErrorAction SilentlyContinue

            Remove-Item $tempStdOut.FullName -Force -ErrorAction SilentlyContinue
            Remove-Item $tempStdErr.FullName -Force -ErrorAction SilentlyContinue

            if (-not [string]::IsNullOrWhiteSpace($stdOutContent)) {
                Write-LogMessage "    $HookType Script STDOUT:" -Level "HOOK"
                $stdOutContent.Split([Environment]::NewLine) | ForEach-Object { Write-LogMessage "      | $_" -Level "HOOK" -NoTimestampToLogFile; $outputLog.Add("OUTPUT: $_") }
            }
            if ($proc.ExitCode -ne 0) {
                Write-LogMessage "[ERROR] $HookType script '$ScriptPath' exited with error code $($proc.ExitCode)." -Level "ERROR"
                $status = "Failure (ExitCode $($proc.ExitCode))"
                if (-not [string]::IsNullOrWhiteSpace($stdErrContent)) {
                    Write-LogMessage "    $HookType Script STDERR:" -Level "ERROR"
                    $stdErrContent.Split([Environment]::NewLine) | ForEach-Object { Write-LogMessage "      | $_" -Level "ERROR" -NoTimestampToLogFile; $outputLog.Add("ERROR: $_") }
                }
            } elseif (-not [string]::IsNullOrWhiteSpace($stdErrContent)) {
                 Write-LogMessage "[WARNING] $HookType script '$ScriptPath' wrote to STDERR despite exiting successfully (Code 0)." -Level "WARNING"
                 Write-LogMessage "    $HookType Script STDERR (Warning):" -Level "WARNING"
                 $stdErrContent.Split([Environment]::NewLine) | ForEach-Object { Write-LogMessage "      | $_" -Level "WARNING" -NoTimestampToLogFile; $outputLog.Add("STDERR_WARN: $_") }
            }
            $statusLevelForLog = if($status -like "Failure*"){"ERROR"}elseif($status -eq "Simulated"){"SIMULATE"}else{"SUCCESS"}
            Write-LogMessage "  - $HookType script execution finished. Status: $status" -Level $statusLevelForLog
        }
    } catch {
        Write-LogMessage "[ERROR] Exception occurred while trying to execute $HookType script '$ScriptPath': $($_.Exception.ToString())" -Level "ERROR"
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
    <#
    .SYNOPSIS
        Gets the size of a file and formats it into a human-readable string (Bytes, KB, MB, GB).
    .PARAMETER PathToArchive
        The full path to the file whose size is to be formatted.
    .EXAMPLE
        $sizeString = Get-ArchiveSizeFormatted -PathToArchive "C:\Backups\MyArchive.7z"
        Write-Host "Archive size: $sizeString"
    .OUTPUTS
        System.String
        A string representing the file size (e.g., "1.23 GB", "450.67 KB", "789 Bytes").
        Returns "File not found" or "Error getting size" if issues occur.
    #>
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
            Write-LogMessage "[DEBUG] File not found at '$PathToArchive' for size formatting." -Level "DEBUG"
            $FormattedSize = "File not found"
        }
    } catch {
        Write-LogMessage "[WARNING] Error getting file size for '$PathToArchive': $($_.Exception.Message)" -Level "WARNING"
        $FormattedSize = "Error getting size"
    }
    return $FormattedSize
}
#endregion

#region --- Configuration Loading and Validation Function ---
function Import-AppConfiguration {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Loads and validates the PoSh-Backup application configuration from .psd1 files.
    .DESCRIPTION
        This function is responsible for loading the PoSh-Backup configuration.
        It first attempts to load the base configuration from 'Config\Default.psd1'.
        Then, it checks for a 'Config\User.psd1' file and, if found, merges its settings over
        the base configuration (user settings take precedence).
        If a specific configuration file path is provided via -UserSpecifiedPath, only that file is loaded.

        After loading, it performs basic validation (e.g., 7-Zip path) and can optionally invoke
        advanced schema validation if 'EnableAdvancedSchemaValidation' is set to $true in the
        loaded configuration and the 'PoShBackupValidator.psm1' module is available.
        It also handles the auto-detection of the 7-Zip executable path if not explicitly set,
        by calling 'Find-SevenZipExecutable' (expected to be available from 7ZipManager.psm1).
    .PARAMETER UserSpecifiedPath
        Optional. The full path to a specific .psd1 configuration file to load.
        If provided, the default 'Config\Default.psd1' and 'Config\User.psd1' loading/merging logic is bypassed.
    .PARAMETER IsTestConfigMode
        Switch. Indicates if the script is running in -TestConfig mode. This affects some logging messages
        and validation behaviours (e.g., more verbose feedback on schema validation status).
    .PARAMETER MainScriptPSScriptRoot
        The $PSScriptRoot of the main PoSh-Backup.ps1 script. Used to resolve relative paths
        for default configuration files and modules.
    .EXAMPLE
        $configLoadResult = Import-AppConfiguration -MainScriptPSScriptRoot $PSScriptRoot
        if ($configLoadResult.IsValid) { $Configuration = $configLoadResult.Configuration }
    .EXAMPLE
        $configLoadResult = Import-AppConfiguration -UserSpecifiedPath "C:\PoShBackup\CustomConfig.psd1" -MainScriptPSScriptRoot $PSScriptRoot
    .OUTPUTS
        System.Collections.Hashtable
        Returns a hashtable with the following keys:
        - IsValid (boolean): $true if configuration loaded and passed basic validation, $false otherwise.
        - Configuration (hashtable): The loaded and merged configuration settings if IsValid is $true, $null otherwise.
        - ActualPath (string): The path to the primary configuration file that was loaded.
        - ErrorMessage (string): An error message if IsValid is $false.
        - UserConfigLoaded (boolean): $true if 'User.psd1' was successfully found and merged.
        - UserConfigPath (string): Path to 'User.psd1' if it was checked (even if not found or failed to load).
    #>
    param (
        [string]$UserSpecifiedPath,
        [switch]$IsTestConfigMode,
        [string]$MainScriptPSScriptRoot
    )

    $finalConfiguration = $null
    $userConfigLoadedSuccessfully = $false
    $primaryConfigPathForReturn = $null

    $defaultConfigDir = Join-Path -Path $MainScriptPSScriptRoot -ChildPath "Config"
    $defaultBaseConfigFileName = "Default.psd1"
    $defaultUserConfigFileName = "User.psd1"

    $defaultBaseConfigPath = Join-Path -Path $defaultConfigDir -ChildPath $defaultBaseConfigFileName
    $defaultUserConfigPath = Join-Path -Path $defaultConfigDir -ChildPath $defaultUserConfigFileName

    if (-not [string]::IsNullOrWhiteSpace($UserSpecifiedPath)) {
        Write-LogMessage "`n[INFO] Using user-specified configuration file: '$($UserSpecifiedPath)'" -Level "INFO"
        $primaryConfigPathForReturn = $UserSpecifiedPath
        if (-not (Test-Path -LiteralPath $UserSpecifiedPath -PathType Leaf)) {
            Write-LogMessage "FATAL: Specified configuration file '$UserSpecifiedPath' not found." -Level "ERROR"
            return @{ IsValid = $false; ErrorMessage = "Configuration file not found at '$UserSpecifiedPath'." }
        }
        try {
            $finalConfiguration = Import-PowerShellDataFile -LiteralPath $UserSpecifiedPath -ErrorAction Stop
            Write-LogMessage "  - Configuration loaded successfully from '$UserSpecifiedPath'." -Level "SUCCESS"
        } catch {
            Write-LogMessage "FATAL: Could not load or parse specified configuration file '$UserSpecifiedPath'. Error: $($_.Exception.Message)" -Level "ERROR"
            return @{ IsValid = $false; ErrorMessage = "Failed to parse configuration file '$UserSpecifiedPath': $($_.Exception.Message)" }
        }
    } else {
        $primaryConfigPathForReturn = $defaultBaseConfigPath
        Write-LogMessage "`n[INFO] No -ConfigFile specified by user. Loading base configuration from: '$($defaultBaseConfigPath)'" -Level "INFO"
        if (-not (Test-Path -LiteralPath $defaultBaseConfigPath -PathType Leaf)) {
            Write-LogMessage "FATAL: Base configuration file '$defaultBaseConfigPath' not found. This file is required for default operation." -Level "ERROR"
            return @{ IsValid = $false; ErrorMessage = "Base configuration file '$defaultBaseConfigPath' not found." }
        }
        try {
            $loadedBaseConfiguration = Import-PowerShellDataFile -LiteralPath $defaultBaseConfigPath -ErrorAction Stop
            Write-LogMessage "  - Base configuration loaded successfully from '$defaultBaseConfigPath'." -Level "SUCCESS"
            $finalConfiguration = $loadedBaseConfiguration
        } catch {
            Write-LogMessage "FATAL: Could not load or parse base configuration file '$defaultBaseConfigPath'. Error: $($_.Exception.Message)" -Level "ERROR"
            return @{ IsValid = $false; ErrorMessage = "Failed to parse base configuration file '$defaultBaseConfigPath': $($_.Exception.Message)" }
        }

        Write-LogMessage "[INFO] Checking for user override configuration at: '$($defaultUserConfigPath)'" -Level "INFO"
        if (Test-Path -LiteralPath $defaultUserConfigPath -PathType Leaf) {
            try {
                $loadedUserConfiguration = Import-PowerShellDataFile -LiteralPath $defaultUserConfigPath -ErrorAction Stop
                if ($null -ne $loadedUserConfiguration -and $loadedUserConfiguration -is [hashtable]) {
                    Write-LogMessage "  - User override configuration '$defaultUserConfigPath' found and loaded successfully." -Level "SUCCESS"
                    Write-LogMessage "  - Merging user configuration over base configuration..." -Level "DEBUG"
                    $finalConfiguration = Merge-DeepHashtable -Base $finalConfiguration -Override $loadedUserConfiguration
                    $userConfigLoadedSuccessfully = $true
                    Write-LogMessage "  - User configuration merged successfully." -Level "SUCCESS"
                } else {
                    Write-LogMessage "[WARNING] User override configuration file '$defaultUserConfigPath' was found but did not load as a valid hashtable (it might be empty or malformed). Skipping user overrides." -Level "WARNING"
                }
            } catch {
                Write-LogMessage "[WARNING] Could not load or parse user override configuration file '$defaultUserConfigPath'. Error: $($_.Exception.Message). Using base configuration only." -Level "WARNING"
            }
        } else {
            Write-LogMessage "  - User override configuration file '$defaultUserConfigPath' not found. Using base configuration only." -Level "INFO"
        }
    }

    if ($null -eq $finalConfiguration -or -not ($finalConfiguration -is [hashtable])) {
        Write-LogMessage "FATAL: Final configuration object is null or not a valid hashtable after loading/merging attempts." -Level "ERROR"
        return @{ IsValid = $false; ErrorMessage = "Final configuration is not a valid hashtable." }
    }

    $validationMessages = [System.Collections.Generic.List[string]]::new()

    $enableAdvancedValidation = Get-ConfigValue -ConfigObject $finalConfiguration -Key 'EnableAdvancedSchemaValidation' -DefaultValue $false
    if ($enableAdvancedValidation -eq $true) {
        Write-LogMessage "[INFO] Advanced Schema Validation is enabled in configuration. Attempting to load PoShBackupValidator module..." -Level "INFO"
        try {
            Import-Module -Name (Join-Path -Path $MainScriptPSScriptRoot -ChildPath "Modules\PoShBackupValidator.psm1") -Force -ErrorAction Stop
            Write-LogMessage "  - PoShBackupValidator module loaded successfully. Performing schema validation against loaded configuration..." -Level "DEBUG"
            Invoke-PoShBackupConfigValidation -ConfigurationToValidate $finalConfiguration -ValidationMessagesListRef ([ref]$validationMessages)
            if ($IsTestConfigMode.IsPresent -and $validationMessages.Count -eq 0) {
                 Write-LogMessage "[SUCCESS] Advanced schema validation completed (no schema errors found)." -Level "CONFIG_TEST"
            } elseif ($validationMessages.Count -gt 0) {
                 Write-LogMessage "[WARNING] Advanced schema validation found issues (see detailed errors below)." -Level "WARNING"
            }
        } catch {
            Write-LogMessage "[WARNING] Could not load or execute PoShBackupValidator module for advanced schema validation. This validation step will be skipped. Error: $($_.Exception.Message)" -Level "WARNING"
        }
    } else {
        if ($IsTestConfigMode.IsPresent) {
            Write-LogMessage "[INFO] Advanced Schema Validation is disabled in the configuration ('EnableAdvancedSchemaValidation' is `$false or missing)." -Level "INFO"
        }
    }

    $vssCachePath = Get-ConfigValue -ConfigObject $finalConfiguration -Key 'VSSMetadataCachePath' -DefaultValue "%TEMP%\diskshadow_cache_poshbackup.cab"
    try {
        $expandedVssCachePath = [System.Environment]::ExpandEnvironmentVariables($vssCachePath)
        $null = [System.IO.Path]::GetFullPath($expandedVssCachePath)
        $parentDir = Split-Path -Path $expandedVssCachePath
        if ( ($null -ne $parentDir) -and (-not ([string]::IsNullOrEmpty($parentDir))) -and (-not (Test-Path -Path $parentDir -PathType Container)) ) {
             if ($IsTestConfigMode.IsPresent) {
                 Write-LogMessage "[INFO] Note: The parent directory ('$parentDir') for the configured 'VSSMetadataCachePath' ('$expandedVssCachePath') does not currently exist. Diskshadow may attempt to create it." -Level "INFO"
            }
        }
    } catch {
        $validationMessages.Add("Global 'VSSMetadataCachePath' ('$vssCachePath') is not a valid path format after environment variable expansion or is otherwise invalid. Error: $($_.Exception.Message)")
    }

    $sevenZipPathFromConfigOriginal = Get-ConfigValue -ConfigObject $finalConfiguration -Key 'SevenZipPath' -DefaultValue $null
    $sevenZipPathSource = "configuration"

    if (-not ([string]::IsNullOrWhiteSpace($finalConfiguration.SevenZipPath)) -and (Test-Path -LiteralPath $finalConfiguration.SevenZipPath -PathType Leaf)) {
        if ($IsTestConfigMode.IsPresent) {
             Write-LogMessage "  - Effective 7-Zip Path set to: '$($finalConfiguration.SevenZipPath)' (Source: $sevenZipPathSource)." -Level "CONFIG_TEST"
        }
    } else {
        $initialPathIsEmpty = [string]::IsNullOrWhiteSpace($sevenZipPathFromConfigOriginal)
        if (-not $initialPathIsEmpty) {
            Write-LogMessage "[WARNING] Configured 'SevenZipPath' ('$sevenZipPathFromConfigOriginal') is invalid or not found. Attempting auto-detection..." -Level "WARNING"
        } else {
            Write-LogMessage "[INFO] 'SevenZipPath' is empty or not set in configuration. Attempting auto-detection..." -Level "INFO"
        }

        # Ensure Find-SevenZipExecutable is available (expected from 7ZipManager.psm1)
        if (-not (Get-Command Find-SevenZipExecutable -ErrorAction SilentlyContinue)) {
            $criticalErrorMsg = "CRITICAL: The function 'Find-SevenZipExecutable' is not available. Ensure '7ZipManager.psm1' is imported by PoSh-Backup.ps1. Cannot auto-detect 7-Zip path."
            Write-LogMessage $criticalErrorMsg -Level ERROR
            if (-not $validationMessages.Contains($criticalErrorMsg)) { $validationMessages.Add($criticalErrorMsg) }
            # Do not attempt to call it if not found, proceed to failure case
        } else {
            $foundPath = Find-SevenZipExecutable # Call the function (now from 7ZipManager.psm1)
            if ($null -ne $foundPath) {
                $finalConfiguration.SevenZipPath = $foundPath
                $sevenZipPathSource = if ($initialPathIsEmpty) { "auto-detected (config was empty)" } else { "auto-detected (configured path was invalid)" }
                Write-LogMessage "[INFO] Successfully auto-detected and using 7-Zip Path: '$foundPath'." -Level "INFO"
                if ($IsTestConfigMode.IsPresent) {
                    Write-LogMessage "  - Effective 7-Zip Path set to: '$foundPath' (Source: $sevenZipPathSource)." -Level "CONFIG_TEST"
                }
            } else {
                $errorMsg = if ($initialPathIsEmpty) {
                    "CRITICAL: 'SevenZipPath' is empty in configuration and auto-detection failed. PoSh-Backup cannot function without a valid 7-Zip path."
                } else {
                    "CRITICAL: Configured 'SevenZipPath' ('$sevenZipPathFromConfigOriginal') is invalid, and auto-detection also failed. PoSh-Backup cannot function."
                }
                if (-not $validationMessages.Contains($errorMsg)) { $validationMessages.Add($errorMsg) }
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($finalConfiguration.SevenZipPath) -or (-not (Test-Path -LiteralPath $finalConfiguration.SevenZipPath -PathType Leaf))) {
        $criticalErrorMsg = "CRITICAL: The effective 'SevenZipPath' ('$($finalConfiguration.SevenZipPath)') is invalid or not found after all checks. PoSh-Backup requires a valid 7z.exe path."
        if (-not $validationMessages.Contains($criticalErrorMsg) -and `
            -not ($validationMessages | Where-Object {$_ -like "CRITICAL: 'SevenZipPath' is empty in config and auto-detection failed*"}) -and `
            -not ($validationMessages | Where-Object {$_ -like "CRITICAL: Configured 'SevenZipPath' (*"})) {
             $validationMessages.Add($criticalErrorMsg)
        }
    }

    $defaultDateFormat = Get-ConfigValue -ConfigObject $finalConfiguration -Key 'DefaultArchiveDateFormat' -DefaultValue "yyyy-MMM-dd"
    if ($finalConfiguration.ContainsKey('DefaultArchiveDateFormat')) {
        if (-not ([string]$defaultDateFormat).Trim()) {
            $validationMessages.Add("Global setting 'DefaultArchiveDateFormat' is defined but empty. Please provide a valid .NET date format string or remove the key to use the script's internal default.")
        } else {
            try { Get-Date -Format $defaultDateFormat -ErrorAction Stop | Out-Null }
            catch { $validationMessages.Add("Global setting 'DefaultArchiveDateFormat' ('$defaultDateFormat') is not a valid .NET date format string. Error: $($_.Exception.Message)") }
        }
    }

    $pauseSetting = Get-ConfigValue -ConfigObject $finalConfiguration -Key 'PauseBeforeExit' -DefaultValue "OnFailureOrWarning"
    if ($finalConfiguration.ContainsKey('PauseBeforeExit')) {
        $validPauseOptions = @('true', 'false', 'always', 'never', 'onfailure', 'onwarning', 'onfailureorwarning')
        if (!($pauseSetting -is [bool] -or ($pauseSetting -is [string] -and $pauseSetting.ToString().ToLowerInvariant() -in $validPauseOptions))) {
            $validationMessages.Add("Global setting 'PauseBeforeExit' ('$pauseSetting') has an invalid value or type. Allowed: Boolean (`$true`/`$false`) or String (`'Always'`, `'Never'`, `'OnFailure'`, `'OnWarning'`, `'OnFailureOrWarning'`).")
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
                if ($null -ne $jobConfig -and $jobConfig.ContainsKey('ArchiveExtension')) {
                    $userArchiveExt = $jobConfig['ArchiveExtension']
                     if (-not ($userArchiveExt -match "^\.[a-zA-Z0-9]+([a-zA-Z0-9\.]*[a-zA-Z0-9]+)?$")) {
                        $validationMessages.Add("BackupLocation '$jobKey': 'ArchiveExtension' ('$userArchiveExt') is invalid. It must start with a dot '.' and contain valid file extension characters (e.g., '.zip', '.7z', '.tar.gz').")
                    }
                }
                if ($null -ne $jobConfig -and $jobConfig.ContainsKey('ArchiveDateFormat')) {
                    $jobDateFormat = $jobConfig['ArchiveDateFormat']
                    if (-not ([string]$jobDateFormat).Trim()) {
                        $validationMessages.Add("BackupLocation '$jobKey': 'ArchiveDateFormat' is defined but empty. Please provide a valid .NET date format string or remove the key to use the global default.")
                    } else {
                        try { Get-Date -Format $jobDateFormat -ErrorAction Stop | Out-Null }
                        catch { $validationMessages.Add("BackupLocation '$jobKey': 'ArchiveDateFormat' ('$jobDateFormat') is not a valid .NET date format string. Error: $($_.Exception.Message)") }
                    }
                }
            }
        }
    }

    if ($finalConfiguration.ContainsKey('DefaultArchiveExtension')) {
        $defaultArchiveExtGlobal = Get-ConfigValue -ConfigObject $finalConfiguration -Key 'DefaultArchiveExtension' -DefaultValue ".7z"
        if (-not ($defaultArchiveExtGlobal -match "^\.[a-zA-Z0-9]+([a-zA-Z0-9\.]*[a-zA-Z0-9]+)?$")) {
            $validationMessages.Add("Global setting 'DefaultArchiveExtension' ('$defaultArchiveExtGlobal') is invalid. It must start with a dot '.' and contain valid file extension characters.")
        }
    }

    if ($finalConfiguration.ContainsKey('BackupSets') -and $finalConfiguration.BackupSets -is [hashtable]) {
        foreach ($setKey in $finalConfiguration.BackupSets.Keys) {
            $setConfig = $finalConfiguration.BackupSets[$setKey]
            if ($setConfig -is [hashtable]) {
                $jobNamesInSetArray = @(Get-ConfigValue -ConfigObject $setConfig -Key 'JobNames' -DefaultValue @())
                if ($jobNamesInSetArray.Count -gt 0) {
                    foreach ($jobNameInSetCandidate in $jobNamesInSetArray) {
                        if ([string]::IsNullOrWhiteSpace($jobNameInSetCandidate)) {
                            $validationMessages.Add("BackupSet '$setKey': Contains an empty or whitespace-only job name in its 'JobNames' list.")
                            continue
                        }
                        $jobNameInSet = $jobNameInSetCandidate.Trim()
                        if ($finalConfiguration.ContainsKey('BackupLocations') -and $finalConfiguration.BackupLocations -is [hashtable] -and -not $finalConfiguration.BackupLocations.ContainsKey($jobNameInSet)) {
                            $validationMessages.Add("BackupSet '$setKey': Job '$jobNameInSet' listed in 'JobNames' is not defined in the 'BackupLocations' section.")
                        } elseif (-not ($finalConfiguration.ContainsKey('BackupLocations') -and $finalConfiguration.BackupLocations -is [hashtable])) {
                            $validationMessages.Add("BackupSet '$setKey': Cannot validate Job '$jobNameInSet' because 'BackupLocations' section is missing or not a valid Hashtable in the configuration.")
                        }
                    }
                }
            }
        }
    }

    if ($validationMessages.Count -gt 0) {
        Write-LogMessage "Configuration validation failed with the following errors/warnings:" -Level "ERROR"
        ($validationMessages | Select-Object -Unique) | ForEach-Object { Write-LogMessage "  - $_" -Level "ERROR" }
        return @{ IsValid = $false; ErrorMessage = "Configuration validation failed. See logs for details." }
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
    <#
    .SYNOPSIS
        Determines the list of backup jobs to process based on command-line parameters and configuration.
    .DESCRIPTION
        This function resolves which backup jobs should be run.
        - If -RunSet is specified, it attempts to find the set and returns its defined jobs.
        - If -BackupLocationName is specified (and -RunSet is not), it returns that single job.
        - If neither is specified:
            - If only one job is defined in the configuration, it returns that job.
            - Otherwise (zero or multiple jobs defined), it returns an error indicating the ambiguity.
        It also determines the 'StopSetOnError' policy for the resolved set.
    .PARAMETER Config
        The loaded PoSh-Backup configuration hashtable.
    .PARAMETER SpecifiedJobName
        The job name provided via the -BackupLocationName command-line parameter, if any.
    .PARAMETER SpecifiedSetName
        The set name provided via the -RunSet command-line parameter, if any.
    .EXAMPLE
        $resolved = Get-JobsToProcess -Config $Configuration -SpecifiedSetName "DailyBackups"
        if ($resolved.Success) { $jobs = $resolved.JobsToRun }
    .OUTPUTS
        System.Collections.Hashtable
        Returns a hashtable containing:
        - Success (boolean): $true if jobs were successfully resolved, $false otherwise.
        - JobsToRun (System.Collections.Generic.List[string]): A list of job names to process.
        - SetName (string): The name of the backup set being run, if applicable ($null otherwise).
        - StopSetOnErrorPolicy (boolean): $true if the set should stop on job failure, $false to continue.
        - ErrorMessage (string): An error message if Success is $false.
    #>
    param(
        [hashtable]$Config,
        [string]$SpecifiedJobName,
        [string]$SpecifiedSetName
    )
    $jobsToRun = [System.Collections.Generic.List[string]]::new()
    $setName = $null
    $stopSetOnErrorPolicy = $true

    if (-not [string]::IsNullOrWhiteSpace($SpecifiedSetName)) {
        Write-LogMessage "`n[INFO] Backup Set specified by user: '$SpecifiedSetName'" -Level "INFO"
        if ($Config.ContainsKey('BackupSets') -and $Config['BackupSets'] -is [hashtable] -and $Config['BackupSets'].ContainsKey($SpecifiedSetName)) {
            $setDefinition = $Config['BackupSets'][$SpecifiedSetName]
            $setName = $SpecifiedSetName
            $jobNamesInSet = @(Get-ConfigValue -ConfigObject $setDefinition -Key 'JobNames' -DefaultValue @())

            if ($jobNamesInSet.Count -gt 0) {
                $jobNamesInSet | ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_)) {$jobsToRun.Add($_.Trim())} }
                if ($jobsToRun.Count -eq 0) {
                     return @{ Success = $false; ErrorMessage = "Backup Set '$setName' is defined but its 'JobNames' list contains no valid (non-empty) job names." }
                }
                $stopSetOnErrorPolicy = if (((Get-ConfigValue -ConfigObject $setDefinition -Key 'OnErrorInJob' -DefaultValue "StopSet") -as [string]).ToUpperInvariant() -eq "CONTINUESET") { $false } else { $true }
                Write-LogMessage "  - Jobs to process in set '$setName': $($jobsToRun -join ', ')" -Level "INFO"
                Write-LogMessage "  - Policy for this set if a job fails: $(if($stopSetOnErrorPolicy){'StopSet'}else{'ContinueSet'})" -Level "INFO"
            } else {
                return @{ Success = $false; ErrorMessage = "Backup Set '$setName' is defined but has no 'JobNames' listed. Cannot process an empty set." }
            }
        } else {
            $availableSetsMessage = "No Backup Sets are currently defined in the configuration."
            if ($Config.ContainsKey('BackupSets') -and $Config['BackupSets'] -is [hashtable] -and $Config['BackupSets'].Keys.Count -gt 0) {
                $setNameList = $Config['BackupSets'].Keys | Sort-Object | ForEach-Object { "`"$_`"" }
                $availableSetsMessage = "Available Backup Sets in configuration: $($setNameList -join ', ')."
            }
            return @{ Success = $false; ErrorMessage = "Specified Backup Set '$SpecifiedSetName' was not found in the configuration. $availableSetsMessage" }
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($SpecifiedJobName)) {
        if ($Config.ContainsKey('BackupLocations') -and $Config['BackupLocations'] -is [hashtable] -and $Config['BackupLocations'].ContainsKey($SpecifiedJobName)) {
            $jobsToRun.Add($SpecifiedJobName)
            Write-LogMessage "`n[INFO] Single Backup Location specified by user: '$SpecifiedJobName'" -Level "INFO"
        } else {
            $availableJobsMessage = "No Backup Locations are currently defined in the configuration."
            if ($Config.ContainsKey('BackupLocations') -and $Config['BackupLocations'] -is [hashtable] -and $Config['BackupLocations'].Keys.Count -gt 0) {
                $jobNameList = $Config['BackupLocations'].Keys | Sort-Object | ForEach-Object { "`"$_`"" }
                $availableJobsMessage = "Available Backup Locations in configuration: $($jobNameList -join ', ')."
            }
            return @{ Success = $false; ErrorMessage = "Specified BackupLocationName '$SpecifiedJobName' was not found in the configuration. $availableJobsMessage" }
        }
    } else {
        $jobCount = 0
        if ($Config.ContainsKey('BackupLocations') -and $Config['BackupLocations'] -is [hashtable]) {
            $jobCount = $Config['BackupLocations'].Count
        }

        if ($jobCount -eq 1) {
            $singleJobKey = ($Config['BackupLocations'].Keys | Select-Object -First 1) # MODIFIED: Select to Select-Object
            $jobsToRun.Add($singleJobKey)
            Write-LogMessage "`n[INFO] No job or set specified by user. Automatically selected the single defined Backup Location: '$singleJobKey'" -Level "INFO"
        } elseif ($jobCount -eq 0) {
            return @{ Success = $false; ErrorMessage = "No BackupLocationName or RunSet specified, and no Backup Locations are defined in the configuration. Nothing to back up." }
        } else {
            $errorMessage = "No BackupLocationName or RunSet specified. Multiple Backup Locations are defined. Please choose one of the following:"
            $availableJobsMessage = "`n  Available Backup Locations (use -BackupLocationName ""Job Name""):"
            if ($Config.ContainsKey('BackupLocations') -and $Config['BackupLocations'] -is [hashtable] -and $Config['BackupLocations'].Keys.Count -gt 0) {
                $Config['BackupLocations'].Keys | Sort-Object | ForEach-Object { $availableJobsMessage += "`n    - $_" }
            } else {
                $availableJobsMessage += "`n    (Error: No jobs found despite jobCount > 1)"
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
        return @{ Success = $false; ErrorMessage = "No valid backup jobs could be determined to process after parsing parameters and configuration." }
    }

    return @{
        Success = $true;
        JobsToRun = $jobsToRun;
        SetName = $setName;
        StopSetOnErrorPolicy = $stopSetOnErrorPolicy
    }
}
#endregion

#region --- Exported Functions ---
Export-ModuleMember -Function Write-LogMessage, Get-ConfigValue, Test-AdminPrivilege, Invoke-HookScript, Get-ArchiveSizeFormatted, Import-AppConfiguration, Get-JobsToProcess
#endregion
