<#
.SYNOPSIS
    Manages all 7-Zip executable interactions for the PoSh-Backup solution.
    This includes finding the 7-Zip executable, constructing command arguments,
    executing 7-Zip operations (archiving, testing), and handling retries.

.DESCRIPTION
    The 7ZipManager module centralises 7-Zip specific logic, making the main backup script
    and other modules cleaner by abstracting the direct interactions with the 7z.exe tool.
    It provides functions to:
    - Auto-detect the 7z.exe path.
    - Build the complex argument list required for 7-Zip commands based on configuration.
    - Execute 7-Zip for creating archives, supporting features like process priority and retries.
    - Execute 7-Zip for testing archive integrity, also with retry support.

    This module relies on utility functions (like Write-LogMessage, Get-ConfigValue) being made
    available globally by the main PoSh-Backup script importing Utils.psm1, or by passing a logger
    reference for functions that need it.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.2 # All functions now accept and use -Logger.
    DateCreated:    17-May-2025
    LastModified:   18-May-2025
    Purpose:        Centralised 7-Zip interaction logic for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    7-Zip (7z.exe) must be installed.
                    Core PoSh-Backup module Utils.psm1 (for Write-LogMessage, Get-ConfigValue)
                    should be loaded by the parent script, or logger passed explicitly.
#>

#region --- 7-Zip Executable Finder ---
function Find-SevenZipExecutable {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Attempts to find the 7z.exe executable in common locations or the system PATH.
    .DESCRIPTION
        This function searches for 7z.exe in standard installation directories (Program Files, Program Files (x86))
        and then checks the system's PATH environment variable. It's used by the configuration loading
        process to auto-detect the 7-Zip path if not explicitly set by the user.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function.
        Used for logging the auto-detection process.
    .OUTPUTS
        System.String
        The full path to the found 7z.exe, or $null if not found.
    .EXAMPLE
        # $sevenZipPath = Find-SevenZipExecutable -Logger ${function:Write-LogMessage}
        # if ($sevenZipPath) { Write-Host "Found 7-Zip at $sevenZipPath" }
    #>
    param(
        [Parameter(Mandatory=$true)]
        [scriptblock]$Logger
    )

    # Internal helper to use the passed-in logger consistently
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if ($null -ne $ForegroundColour) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    # Defensive PSSA appeasement line
    & $LocalWriteLog -Message "Find-SevenZipExecutable: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue


    & $LocalWriteLog -Message "  - Attempting to auto-detect 7z.exe..." -Level "DEBUG"
    $commonPaths = @(
        (Join-Path -Path $env:ProgramFiles -ChildPath "7-Zip\7z.exe"),
        (Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath "7-Zip\7z.exe")
    )

    foreach ($pathAttempt in $commonPaths) {
        if ($null -ne $pathAttempt -and (Test-Path -LiteralPath $pathAttempt -PathType Leaf)) {
            & $LocalWriteLog -Message "    - Auto-detected 7z.exe at '$pathAttempt' (common installation location)." -Level "INFO"
            return $pathAttempt
        }
    }

    # Try finding 7z.exe via Get-Command (searches PATH environment variable)
    try {
        $pathFromCommand = (Get-Command 7z.exe -ErrorAction SilentlyContinue).Source
        if (-not [string]::IsNullOrWhiteSpace($pathFromCommand) -and (Test-Path -LiteralPath $pathFromCommand -PathType Leaf)) {
            & $LocalWriteLog -Message "    - Auto-detected 7z.exe at '$pathFromCommand' (found in system PATH)." -Level "INFO"
            return $pathFromCommand
        }
    }
    catch {
        & $LocalWriteLog -Message "    - 7z.exe not found in system PATH (Get-Command error: $($_.Exception.Message))." -Level "DEBUG"
    }

    & $LocalWriteLog -Message "    - Auto-detection failed to find 7z.exe in common locations or system PATH. Please ensure 'SevenZipPath' is set in the configuration." -Level "DEBUG"
    return $null # Return null if not found
}
#endregion

#region --- 7-Zip Argument Builder ---
function Get-PoShBackup7ZipArgument {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Constructs the command-line argument list for executing 7z.exe based on effective job configuration.
    .DESCRIPTION
        This function takes the effective configuration for a backup job, the final archive path,
        source paths, and an optional temporary password file path, then assembles the
        appropriate 7-Zip command-line switches and arguments for an archive creation operation.
    .PARAMETER EffectiveConfig
        A hashtable containing the fully resolved configuration settings for the current backup job.
        This includes 7-Zip specific parameters (compression level, type, etc.), exclusions,
        and password usage flags. It's also expected to contain a 'GlobalConfigRef' key pointing
        to the global configuration for default exclusion patterns.
    .PARAMETER FinalArchivePath
        The full path and filename for the target archive that 7-Zip will create.
    .PARAMETER CurrentJobSourcePathFor7Zip
        The source path(s) to be archived. This can be a single string or an array of strings.
        These paths might be original source paths or VSS shadow paths.
    .PARAMETER TempPasswordFile
        Optional. The full path to a temporary file containing the password for archive encryption.
        If provided, 7-Zip's -spf switch will be used.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function.
    .OUTPUTS
        System.Array
        An array of strings, where each string is an argument or switch for 7z.exe.
    .EXAMPLE
        # $args = Get-PoShBackup7ZipArgument -EffectiveConfig $jobSettings -FinalArchivePath "D:\Backup.7z" -CurrentJobSourcePathFor7Zip "C:\Data" -Logger ${function:Write-LogMessage}
        # & "7z.exe" $args
    #>
    param(
        [Parameter(Mandatory)] [hashtable]$EffectiveConfig,
        [Parameter(Mandatory)] [string]$FinalArchivePath,
        [Parameter(Mandatory)] [object]$CurrentJobSourcePathFor7Zip, # Can be string or array of strings
        [Parameter(Mandatory=$false)]
        [string]$TempPasswordFile = $null,
        [Parameter(Mandatory=$true)]
        [scriptblock]$Logger
    )

    # Internal helper to use the passed-in logger consistently
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if ($null -ne $ForegroundColour) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    # Defensive PSSA appeasement line
    & $LocalWriteLog -Message "Get-PoShBackup7ZipArgument: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $sevenZipArgs = [System.Collections.Generic.List[string]]::new()
    $sevenZipArgs.Add("a") # Add (archive) command

    # Add configured 7-Zip switches
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobArchiveType)) { $sevenZipArgs.Add($EffectiveConfig.JobArchiveType) }
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobCompressionLevel)) { $sevenZipArgs.Add($EffectiveConfig.JobCompressionLevel) }
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobCompressionMethod)) { $sevenZipArgs.Add($EffectiveConfig.JobCompressionMethod) }
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobDictionarySize)) { $sevenZipArgs.Add($EffectiveConfig.JobDictionarySize) }
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobWordSize)) { $sevenZipArgs.Add($EffectiveConfig.JobWordSize) }
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.JobSolidBlockSize)) { $sevenZipArgs.Add($EffectiveConfig.JobSolidBlockSize) }
    if ($EffectiveConfig.JobCompressOpenFiles) { $sevenZipArgs.Add("-ssw") } # Compress shared files
    if (-not [string]::IsNullOrWhiteSpace($EffectiveConfig.ThreadsSetting)) {$sevenZipArgs.Add($EffectiveConfig.ThreadsSetting) } # -mmt or -mmt=N

    # Add default global exclusions (Recycle Bin, System Volume Information)
    $sevenZipArgs.Add((Get-ConfigValue -ConfigObject $EffectiveConfig.GlobalConfigRef -Key 'DefaultScriptExcludeRecycleBin' -DefaultValue '-x!$RECYCLE.BIN'))
    $sevenZipArgs.Add((Get-ConfigValue -ConfigObject $EffectiveConfig.GlobalConfigRef -Key 'DefaultScriptExcludeSysVolInfo' -DefaultValue '-x!System Volume Information'))

    # Add job-specific additional exclusions
    if ($EffectiveConfig.JobAdditionalExclusions -is [array] -and $EffectiveConfig.JobAdditionalExclusions.Count -gt 0) {
        $EffectiveConfig.JobAdditionalExclusions | ForEach-Object {
            if (-not [string]::IsNullOrWhiteSpace($_)) {
                $exclusion = $_.Trim()
                # Ensure it's a valid 7-Zip exclusion switch if not already prefixed
                if (-not ($exclusion.StartsWith("-x!") -or $exclusion.StartsWith("-xr!") -or $exclusion.StartsWith("-i!") -or $exclusion.StartsWith("-ir!"))) {
                    $exclusion = "-x!$($exclusion)" # Default to exclude switch
                }
                $sevenZipArgs.Add($exclusion)
            }
        }
    }

    # Add password related switches if a password is in use
    if ($EffectiveConfig.PasswordInUseFor7Zip) {
        $sevenZipArgs.Add("-mhe=on") # Encrypt archive headers
        if (-not [string]::IsNullOrWhiteSpace($TempPasswordFile)) {
            $sevenZipArgs.Add("-spf`"$TempPasswordFile`"") # Read password from temp file
        } else {
            & $LocalWriteLog -Message "[WARNING] PasswordInUseFor7Zip is true but no temporary password file was provided to 7-Zip; the archive might not be password-protected as intended." -Level WARNING
        }
    }

    if ([string]::IsNullOrWhiteSpace($FinalArchivePath)) {
        & $LocalWriteLog -Message "[CRITICAL] Final Archive Path is NULL or EMPTY in Get-PoShBackup7ZipArgument. 7-Zip command will likely fail or use an unexpected name." -Level ERROR
    }
    $sevenZipArgs.Add($FinalArchivePath) # The target archive path/name

    # Add source paths to be archived
    if ($CurrentJobSourcePathFor7Zip -is [array]) {
        $CurrentJobSourcePathFor7Zip | ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_)) {$sevenZipArgs.Add($_)} }
    } elseif (-not [string]::IsNullOrWhiteSpace($CurrentJobSourcePathFor7Zip)) {
        $sevenZipArgs.Add($CurrentJobSourcePathFor7Zip)
    }
    return $sevenZipArgs.ToArray()
}
#endregion

#region --- 7-Zip Operation Invoker ---
function Invoke-7ZipOperation {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')] # Archiving can be medium impact
    <#
    .SYNOPSIS
        Invokes a 7-Zip command (typically for archiving or testing) with support for retries.
    .DESCRIPTION
        This function executes the 7z.exe command-line tool with the provided arguments.
        It supports configuring the process priority for 7-Zip, optionally hiding its console output
        (while still capturing STDOUT/STDERR for logging if issues occur), and implementing a
        retry mechanism for transient failures.
    .PARAMETER SevenZipPathExe
        The full path to the 7z.exe executable.
    .PARAMETER SevenZipArguments
        An array of strings representing the arguments to pass to 7z.exe (e.g., "a", "-t7z", "archive.7z", "source_folder").
    .PARAMETER ProcessPriority
        The Windows process priority for 7z.exe. Valid values: "Idle", "BelowNormal", "Normal", "AboveNormal", "High".
        Defaults to "Normal".
    .PARAMETER HideOutput
        A switch. If present, 7-Zip's console window will be hidden. Output streams are still captured for logging.
    .PARAMETER IsSimulateMode
        A switch. If present, the 7-Zip command will be logged as if it were run, but not actually executed.
        A success (exit code 0) is simulated.
    .PARAMETER MaxRetries
        The maximum number of times to attempt the 7-Zip operation if it fails.
        Defaults to 1 (meaning one attempt, no retries, if EnableRetries is $false).
    .PARAMETER RetryDelaySeconds
        The delay in seconds between retry attempts. Defaults to 60.
    .PARAMETER EnableRetries
        A boolean. $true to enable the retry mechanism, $false to perform only one attempt.
        Defaults to $false.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function.
    .OUTPUTS
        System.Collections.Hashtable
        Returns a hashtable containing:
        - ExitCode (int): The exit code from the 7-Zip process (or a simulated code).
        - ElapsedTime (System.TimeSpan): The time taken for the 7-Zip operation.
        - AttemptsMade (int): The number of attempts made to execute the command.
    .EXAMPLE
        # $result = Invoke-7ZipOperation -SevenZipPathExe "C:\7z\7z.exe" -SevenZipArguments "a archive.7z C:\data" -EnableRetries $true -MaxRetries 3 -Logger ${function:Write-LogMessage}
        # if ($result.ExitCode -ne 0) { Write-Error "7-Zip failed!" }
    #>
    param(
        [string]$SevenZipPathExe,
        [array]$SevenZipArguments,
        [string]$ProcessPriority = "Normal",
        [switch]$HideOutput,
        [switch]$IsSimulateMode,
        [int]$MaxRetries = 1, # Default to 1 attempt (no retries) if EnableRetries is false
        [int]$RetryDelaySeconds = 60,
        [bool]$EnableRetries = $false,
        [Parameter(Mandatory=$true)]
        [scriptblock]$Logger
    )

    # Internal helper to use the passed-in logger consistently
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if ($null -ne $ForegroundColour) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    # Defensive PSSA appeasement line
    & $LocalWriteLog -Message "Invoke-7ZipOperation: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $currentTry = 0
    $actualMaxTries = if ($EnableRetries) { [math]::Max(1, $MaxRetries) } else { 1 } # Ensure at least 1 try
    $actualDelaySeconds = if ($EnableRetries -and $actualMaxTries -gt 1) { $RetryDelaySeconds } else { 0 }
    $operationExitCode = -1 # Default to an error state
    $operationElapsedTime = New-TimeSpan -Seconds 0
    $attemptsMade = 0

    # Prepare argument string for display and process execution, ensuring paths with spaces are quoted
    $argumentStringForProcess = ""
    foreach ($argItem in $SevenZipArguments) {
        if ($argItem -match "\s" -and -not (($argItem.StartsWith('"') -and $argItem.EndsWith('"')) -or ($argItem.StartsWith("'") -and $argItem.EndsWith("'")))) {
            $argumentStringForProcess += """$argItem"" " # Add quotes if space and not already quoted
        } else {
            $argumentStringForProcess += "$argItem "
        }
    }
    $argumentStringForProcess = $argumentStringForProcess.TrimEnd()

    while ($currentTry -lt $actualMaxTries) {
        $currentTry++; $attemptsMade = $currentTry

        if ($IsSimulateMode.IsPresent) {
            & $LocalWriteLog -Message "SIMULATE: 7-Zip Operation (Attempt $currentTry/$actualMaxTries would be): `"$SevenZipPathExe`" $argumentStringForProcess" -Level SIMULATE
            $operationExitCode = 0 # Simulate success for 7-Zip command itself
            $operationElapsedTime = New-TimeSpan -Seconds 0 # Simulate no time taken
            break # Exit loop in simulate mode after logging
        }

        if (-not $PSCmdlet.ShouldProcess("Target: $($SevenZipArguments | Where-Object {$_ -notlike '-*'} | Select-Object -Last 1)", "Execute 7-Zip ($($SevenZipArguments[0]))")) {
             & $LocalWriteLog -Message "   - 7-Zip execution (Attempt $currentTry/$actualMaxTries) skipped by user (ShouldProcess)." -Level WARNING
             $operationExitCode = -1000 # Indicate user skip
             break
        }

        & $LocalWriteLog -Message "   - Attempting 7-Zip execution (Attempt $currentTry/$actualMaxTries)..."
        & $LocalWriteLog -Message "     Command: `"$SevenZipPathExe`" $argumentStringForProcess" -Level DEBUG

        $validPriorities = "Idle", "BelowNormal", "Normal", "AboveNormal", "High"
        if ([string]::IsNullOrWhiteSpace($ProcessPriority) -or $ProcessPriority -notin $validPriorities) {
            & $LocalWriteLog -Message "[WARNING] Invalid or empty 7-Zip process priority '$ProcessPriority' specified. Defaulting to 'Normal'." -Level WARNING; $ProcessPriority = "Normal"
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew(); $process = $null
        try {
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $SevenZipPathExe
            $startInfo.Arguments = $argumentStringForProcess
            $startInfo.UseShellExecute = $false # Required for stream redirection
            $startInfo.CreateNoWindow = $HideOutput.IsPresent
            $startInfo.WindowStyle = if($HideOutput.IsPresent) { [System.Diagnostics.ProcessWindowStyle]::Hidden } else { [System.Diagnostics.ProcessWindowStyle]::Normal }

            if ($HideOutput.IsPresent) {
                $startInfo.RedirectStandardOutput = $true
                $startInfo.RedirectStandardError = $true
            }

            & $LocalWriteLog -Message "  - Starting 7-Zip process with priority: $ProcessPriority" -Level DEBUG
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $startInfo
            $process.Start() | Out-Null
            try { $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]$ProcessPriority }
            catch { & $LocalWriteLog -Message "[WARNING] Failed to set 7-Zip process priority to '$ProcessPriority'. Error: $($_.Exception.Message)" -Level WARNING }

            $stdOutput = ""
            $stdError = ""
            $outputTask = $null
            $errorTask = $null

            if ($HideOutput.IsPresent) { # Asynchronously read output streams if hidden
                $outputTask = $process.StandardOutput.ReadToEndAsync()
                $errorTask = $process.StandardError.ReadToEndAsync()
            }

            $process.WaitForExit() # Wait for the 7-Zip process to complete

            if ($HideOutput.IsPresent) { # Process captured output
                if ($null -ne $outputTask) {
                    try { $stdOutput = $outputTask.GetAwaiter().GetResult() } catch { try { $stdOutput = $process.StandardOutput.ReadToEnd() } catch { & $LocalWriteLog -Message "    - DEBUG: Fallback ReadToEnd STDOUT for 7-Zip failed: $($_.Exception.Message)" -Level DEBUG } }
                }
                 if ($null -ne $errorTask) {
                    try { $stdError = $errorTask.GetAwaiter().GetResult() } catch { try { $stdError = $process.StandardError.ReadToEnd() } catch { & $LocalWriteLog -Message "    - DEBUG: Fallback ReadToEnd STDERR for 7-Zip failed: $($_.Exception.Message)" -Level DEBUG } }
                 }

                if (-not [string]::IsNullOrWhiteSpace($stdOutput)) {
                    & $LocalWriteLog -Message "  - 7-Zip STDOUT (captured as HideSevenZipOutput is true):" -Level DEBUG
                    $stdOutput.Split([Environment]::NewLine) | ForEach-Object { & $LocalWriteLog -Message "    | $_" -Level DEBUG -NoTimestampToLogFile }
                }
                # Always log STDERR if present, as it usually indicates issues.
                if (-not [string]::IsNullOrWhiteSpace($stdError)) {
                    & $LocalWriteLog -Message "  - 7-Zip STDERR:" -Level ERROR
                    $stdError.Split([Environment]::NewLine) | ForEach-Object { & $LocalWriteLog -Message "    | $_" -Level ERROR -NoTimestampToLogFile }
                }
            }
            $operationExitCode = $process.ExitCode
        } catch {
            & $LocalWriteLog -Message "[ERROR] Failed to start or manage the 7-Zip process. Error: $($_.Exception.ToString())" -Level ERROR
            $operationExitCode = -999 # Arbitrary code for script-level failure to launch 7-Zip
        } finally {
            $stopwatch.Stop()
            $operationElapsedTime = $stopwatch.Elapsed
            if ($null -ne $process) { $process.Dispose() }
        }

        & $LocalWriteLog -Message "   - 7-Zip attempt $currentTry finished. Exit Code: $operationExitCode. Elapsed Time: $operationElapsedTime"
        # 7-Zip Exit Codes: 0=No error, 1=Warning (e.g., locked files not archived), 2=Fatal error
        if ($operationExitCode -in @(0,1)) { break } # Success or Warning, stop retrying
        elseif ($currentTry -lt $actualMaxTries) {
            & $LocalWriteLog -Message "[WARNING] 7-Zip operation failed (Exit Code: $operationExitCode). Retrying in $actualDelaySeconds seconds..." -Level WARNING
            Start-Sleep -Seconds $actualDelaySeconds
        } else {
            & $LocalWriteLog -Message "[ERROR] 7-Zip operation failed after $actualMaxTries attempt(s) (Final Exit Code: $operationExitCode)." -Level ERROR
        }
    }
    return @{ ExitCode = $operationExitCode; ElapsedTime = $operationElapsedTime; AttemptsMade = $attemptsMade }
}
#endregion

#region --- 7-Zip Archive Tester ---
function Test-7ZipArchive {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low')] # Testing is low impact
    <#
    .SYNOPSIS
        Tests the integrity of a 7-Zip archive using '7z t' command.
    .DESCRIPTION
        This function invokes 7z.exe to perform an integrity test on a specified archive file.
        It supports passing a temporary password file if the archive is encrypted and includes
        options for process priority, output hiding, and retries similar to Invoke-7ZipOperation.
    .PARAMETER SevenZipPathExe
        The full path to the 7z.exe executable.
    .PARAMETER ArchivePath
        The full path to the archive file to be tested.
    .PARAMETER TempPasswordFile
        Optional. The full path to a temporary file containing the password if the archive is encrypted.
    .PARAMETER ProcessPriority
        The Windows process priority for 7z.exe during the test. Defaults to "Normal".
    .PARAMETER HideOutput
        A switch. If present, 7-Zip's console window will be hidden.
    .PARAMETER MaxRetries
        Maximum number of retry attempts if the test command fails. Defaults to 1.
    .PARAMETER RetryDelaySeconds
        Delay in seconds between retry attempts. Defaults to 60.
    .PARAMETER EnableRetries
        A boolean. $true to enable retries, $false for a single attempt. Defaults to $false.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function.
    .OUTPUTS
        System.Collections.Hashtable
        Returns a hashtable containing:
        - ExitCode (int): The exit code from the 7-Zip test process.
        - ElapsedTime (System.TimeSpan): The time taken for the test operation.
        - AttemptsMade (int): The number of attempts made.
    .EXAMPLE
        # $testResult = Test-7ZipArchive -SevenZipPathExe "C:\7z\7z.exe" -ArchivePath "D:\backup.7z" -Logger ${function:Write-LogMessage}
        # if ($testResult.ExitCode -ne 0) { Write-Warning "Archive test failed!" }
    #>
    param(
        [string]$SevenZipPathExe,
        [string]$ArchivePath,
        [Parameter(Mandatory=$false)]
        [string]$TempPasswordFile = $null,
        [string]$ProcessPriority = "Normal",
        [switch]$HideOutput,
        [int]$MaxRetries = 1,
        [int]$RetryDelaySeconds = 60,
        [bool]$EnableRetries = $false,
        [Parameter(Mandatory=$true)]
        [scriptblock]$Logger
    )

    # Internal helper to use the passed-in logger consistently
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if ($null -ne $ForegroundColour) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    # Defensive PSSA appeasement line
    & $LocalWriteLog -Message "Test-7ZipArchive: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue

    & $LocalWriteLog -Message "`n[INFO] Performing archive integrity test for '$ArchivePath'..."
    $testArguments = [System.Collections.Generic.List[string]]::new()
    $testArguments.Add("t") # Test command
    $testArguments.Add($ArchivePath) # Archive to test

    if (-not [string]::IsNullOrWhiteSpace($TempPasswordFile) -and (Test-Path -LiteralPath $TempPasswordFile)) {
        $testArguments.Add("-spf`"$TempPasswordFile`"") # Add password file if provided
    }
    & $LocalWriteLog -Message "   - Test Command (raw args before Invoke-7ZipOperation internal quoting): `"$SevenZipPathExe`" $($testArguments -join ' ')" -Level DEBUG

    $invokeParams = @{
        SevenZipPathExe = $SevenZipPathExe; SevenZipArguments = $testArguments.ToArray()
        ProcessPriority = $ProcessPriority; HideOutput = $HideOutput.IsPresent
        MaxRetries = $MaxRetries; RetryDelaySeconds = $RetryDelaySeconds; EnableRetries = $EnableRetries
        IsSimulateMode = $false # Testing is never simulated in this function
        Logger = $Logger # Pass the logger down
    }
    # Invoke-7ZipOperation handles ShouldProcess for the actual 7-Zip execution
    $result = Invoke-7ZipOperation @invokeParams

    $msg = if ($result.ExitCode -eq 0) { "PASSED" } else { "FAILED (7-Zip Test Exit Code: $($result.ExitCode))" }
    $levelForResult = if ($result.ExitCode -eq 0) { "SUCCESS" } else { "ERROR" }
    & $LocalWriteLog -Message "  - Archive Test Result for '$ArchivePath': $msg" -Level $levelForResult
    return $result
}
#endregion

Export-ModuleMember -Function Find-SevenZipExecutable, Get-PoShBackup7ZipArgument, Invoke-7ZipOperation, Test-7ZipArchive
