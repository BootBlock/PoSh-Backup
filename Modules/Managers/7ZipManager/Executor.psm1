# Modules\Managers\7ZipManager\Executor.psm1
<#
.SYNOPSIS
    Sub-module for 7ZipManager. Handles the execution of 7-Zip commands for
    archiving and testing.
.DESCRIPTION
    This module contains the 'Invoke-7ZipOperation' and 'Test-7ZipArchive' functions.
    'Invoke-7ZipOperation' executes 7z.exe for creating archives, supporting process
    priority, CPU affinity, retries, and warning handling.
    'Test-7ZipArchive' uses 'Invoke-7ZipOperation' to test archive integrity, now with
    an option to verify internal file checksums (CRCs).
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.2.1 # Fixed bug in simulation message logic.
    DateCreated:    29-May-2025
    LastModified:   23-Jun-2025
    Purpose:        7-Zip command execution logic for 7ZipManager.
    Prerequisites:  PowerShell 5.1+.
                    Relies on Utils.psm1 (for logger functionality if used directly, though logger is passed, and for Write-ConsoleBanner).
#>

# Explicitly import Utils.psm1 from the main Modules directory.
# $PSScriptRoot here is Modules\Managers\7ZipManager.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "Executor.psm1 (7ZipManager submodule) FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}

#region --- 7-Zip Operation Invoker ---
function Invoke-7ZipOperation {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [string]$SevenZipPathExe,
        [array]$SevenZipArguments,
        [Parameter(Mandatory = $false)]
        [string]$PlainTextPassword = $null,
        [string]$ProcessPriority = "Normal",
        [Parameter(Mandatory = $false)]
        [string]$SevenZipCpuAffinityString = $null,
        [switch]$HideOutput,
        [switch]$IsSimulateMode,
        [int]$MaxRetries = 1,
        [int]$RetryDelaySeconds = 60,
        [bool]$EnableRetries = $false,
        [bool]$TreatWarningsAsSuccess = $false,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "7ZipManager/Executor/Invoke-7ZipOperation: Logger parameter active. TreatWarningsAsSuccess: $TreatWarningsAsSuccess, Input Affinity: '$SevenZipCpuAffinityString'" -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if ($null -ne $ForegroundColour) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        }
        else {
            & $Logger -Message $Message -Level $Level
        }
    }

    $currentTry = 0
    $actualMaxTries = if ($EnableRetries) { [math]::Max(1, $MaxRetries) } else { 1 }
    $actualDelaySeconds = if ($EnableRetries -and $actualMaxTries -gt 1) { $RetryDelaySeconds } else { 0 }
    $operationExitCode = -1
    $operationElapsedTime = New-TimeSpan -Seconds 0
    $attemptsMade = 0

    $argumentsForThisAttempt = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($PlainTextPassword)) {
        $argumentsForThisAttempt.Add("-mhe=on")
        $argumentsForThisAttempt.Add("-p$PlainTextPassword")
        & $LocalWriteLog -Message "  - 7ZipManager/Executor/Invoke-7ZipOperation: Password switch added to arguments." -Level "DEBUG"
    }
    $SevenZipArguments | ForEach-Object { $argumentsForThisAttempt.Add($_) }

    $argumentStringForProcess = ""
    foreach ($argItem in $argumentsForThisAttempt) {
        if ($argItem.StartsWith("-p") -and (-not [string]::IsNullOrWhiteSpace($PlainTextPassword)) ) {
            $argumentStringForProcess += "$argItem "
        }
        elseif ($argItem -match "\s" -and -not (($argItem.StartsWith('"') -and $argItem.EndsWith('"')) -or ($argItem.StartsWith("'") -and $argItem.EndsWith("'")))) {
            $argumentStringForProcess += """$argItem"" "
        }
        else {
            $argumentStringForProcess += "$argItem "
        }
    }
    $argumentStringForProcess = $argumentStringForProcess.TrimEnd()

    $cpuAffinityBitmask = $null
    $originalSevenZipCpuAffinityString = $SevenZipCpuAffinityString
    $finalAffinityStringForLog = "None (Not configured)"

    if (-not [string]::IsNullOrWhiteSpace($originalSevenZipCpuAffinityString)) {
        $numberOfLogicalProcessors = 0
        try {
            $numberOfLogicalProcessors = [int]$env:NUMBER_OF_PROCESSORS
            if ($numberOfLogicalProcessors -le 0) { throw "NUMBER_OF_PROCESSORS environment variable is invalid (<=0)." }
            & $LocalWriteLog -Message "  - 7ZipManager/Executor/CPU Affinity: System has $numberOfLogicalProcessors logical processors." -Level "DEBUG"
        }
        catch {
            & $LocalWriteLog -Message "[WARNING] 7ZipManager/Executor/CPU Affinity: Could not determine a valid number of logical processors from `$env:NUMBER_OF_PROCESSORS. Error: $($_.Exception.Message). CPU Affinity will not be applied." -Level "WARNING"
            $numberOfLogicalProcessors = 0
            $finalAffinityStringForLog = "None (System core count undetermined for input '$originalSevenZipCpuAffinityString')"
        }

        if ($numberOfLogicalProcessors -gt 0) {
            if ($originalSevenZipCpuAffinityString -match '^0x([0-9a-fA-F]+)$') {
                $userHexBitmaskString = $matches[0]
                try {
                    $userBitmask = [Convert]::ToInt64($userHexBitmaskString, 16)
                    $systemMaxValidBitmask = (1L -shl $numberOfLogicalProcessors) - 1L
                    $clampedBitmask = $userBitmask -band $systemMaxValidBitmask
                    $cpuAffinityBitmask = $clampedBitmask
                    if ($clampedBitmask -ne $userBitmask) {
                        & $LocalWriteLog -Message "[WARNING] 7ZipManager/Executor/CPU Affinity: User-provided hex bitmask '$userHexBitmaskString' (Decimal: $userBitmask) exceeds system's capabilities (Max valid: 0x$($systemMaxValidBitmask.ToString('X'))). Clamped to effective bitmask 0x$($clampedBitmask.ToString('X')) (Decimal: $clampedBitmask)." -Level "WARNING"
                        $finalAffinityStringForLog = "Bitmask: 0x$($clampedBitmask.ToString('X')) (from input '$userHexBitmaskString', clamped to system max 0x$($systemMaxValidBitmask.ToString('X')))"
                    }
                    else {
                        $finalAffinityStringForLog = "Bitmask: $userHexBitmaskString (Decimal: $userBitmask)"
                    }
                }
                catch {
                    & $LocalWriteLog -Message "[WARNING] 7ZipManager/Executor/CPU Affinity: Error converting user-provided hex bitmask '$userHexBitmaskString' to integer. Error: $($_.Exception.Message). Affinity will not be applied." -Level "WARNING"
                    $cpuAffinityBitmask = $null
                    $finalAffinityStringForLog = "None (input '$userHexBitmaskString' was an invalid hex number)"
                }
            }
            elseif ($originalSevenZipCpuAffinityString -match '^(\d+(,\d+)*)$') {
                $userInputCoreListString = $matches[0]
                $coreNumbersFromInput = $userInputCoreListString.Split(',') | ForEach-Object { try { [int]$_ } catch { -999 } }
                $validCoreNumbers = [System.Collections.Generic.List[int]]::new()
                $invalidCoreNumbersSpecified = [System.Collections.Generic.List[string]]::new()
                $calculatedBitmask = 0L
                foreach ($coreNum in $coreNumbersFromInput) {
                    if ($coreNum -eq -999) {
                        $invalidCoreNumbersSpecified.Add("(unparsable entry)")
                        & $LocalWriteLog -Message "[WARNING] 7ZipManager/Executor/CPU Affinity: Unparsable entry found in core list '$userInputCoreListString'. It will be ignored." -Level "WARNING"
                        continue
                    }
                    if ($coreNum -ge 0 -and $coreNum -lt $numberOfLogicalProcessors) {
                        $validCoreNumbers.Add($coreNum)
                        $calculatedBitmask = $calculatedBitmask -bor (1L -shl $coreNum)
                    }
                    else {
                        $invalidCoreNumbersSpecified.Add($coreNum.ToString())
                        & $LocalWriteLog -Message "[WARNING] 7ZipManager/Executor/CPU Affinity: Specified core '$coreNum' is out of valid range (0 to $($numberOfLogicalProcessors - 1)). It will be ignored." -Level "WARNING"
                    }
                }
                if ($validCoreNumbers.Count -gt 0) {
                    $cpuAffinityBitmask = $calculatedBitmask
                    $effectiveCoresString = $validCoreNumbers -join ','
                    if ($invalidCoreNumbersSpecified.Count -gt 0) {
                        $finalAffinityStringForLog = "Cores: $effectiveCoresString (from input '$userInputCoreListString', invalid/ignored: $($invalidCoreNumbersSpecified -join ','), effective bitmask 0x$($cpuAffinityBitmask.ToString('X')))"
                    }
                    else {
                        $finalAffinityStringForLog = "Cores: $effectiveCoresString (from input '$userInputCoreListString', effective bitmask 0x$($cpuAffinityBitmask.ToString('X')))"
                    }
                }
                else {
                    $cpuAffinityBitmask = $null
                    & $LocalWriteLog -Message "[WARNING] 7ZipManager/Executor/CPU Affinity: No valid CPU cores specified in input '$userInputCoreListString' after validation against $numberOfLogicalProcessors system cores. No affinity will be applied." -Level "WARNING"
                    $finalAffinityStringForLog = "None (input '$userInputCoreListString' resulted in no valid cores for system with $numberOfLogicalProcessors cores)"
                }
            }
            else {
                & $LocalWriteLog -Message "[WARNING] 7ZipManager/Executor/CPU Affinity: Invalid SevenZipCpuAffinity string format: '$originalSevenZipCpuAffinityString'. Expected comma-separated core numbers (e.g., '0,1') or a hex bitmask (e.g., '0x3'). Affinity will not be applied." -Level "WARNING"
                $cpuAffinityBitmask = $null
                $finalAffinityStringForLog = "None (input '$originalSevenZipCpuAffinityString' has invalid format)"
            }
        }
    }

    while ($currentTry -lt $actualMaxTries) {
        $currentTry++; $attemptsMade = $currentTry
        if ($IsSimulateMode.IsPresent) {
            # --- Enhanced Simulation Message Logic ---
            $action = $SevenZipArguments[0]
            switch ($action) {
                'a' { # Archive
                    $nonSwitchArgs = $SevenZipArguments | Where-Object { $_ -notlike '-*' }
                    $archivePath = $nonSwitchArgs[1] # CORRECTED: Index 1 is the archive path
                    $sourcePaths = $nonSwitchArgs | Select-Object -Skip 2 # CORRECTED: Skip command and archive path
                    $sourcePathString = if ($sourcePaths.Count -gt 0) { ($sourcePaths -join ', ') } else { "(from list file)" }
                    
                    $simMessage = "SIMULATE: The following source(s) would be compressed into a new archive: `n"
                    $simMessage += "           Sources: $sourcePathString `n"
                    $simMessage += "           Archive: $archivePath"
                    
                    if ($finalAffinityStringForLog -ne "None (Not configured)") {
                        $simMessage += "`n           CPU Affinity: $finalAffinityStringForLog"
                    }
                    & $LocalWriteLog -Message $simMessage -Level "SIMULATE"
                }
                't' { # Test
                    $archivePath = $SevenZipArguments | Where-Object { $_ -notlike '-*' } | Select-Object -First 1
                    $simMessage = "SIMULATE: The integrity of archive '$archivePath' would be tested."
                    if (($SevenZipArguments -join ' ') -match '-scrc') {
                        $simMessage += " (Internal file checksums would be verified)."
                    }
                    & $LocalWriteLog -Message $simMessage -Level "SIMULATE"
                }
                default { # Fallback for other commands like 'l', 'x', etc.
                    $affinitySimMsg = if ($finalAffinityStringForLog -ne "None (Not configured)") { " (Affinity: $finalAffinityStringForLog)" } else { " (Affinity: Not configured)" }
                    & $LocalWriteLog -Message "SIMULATE: 7-Zip Operation (Attempt $currentTry/$actualMaxTries would be): `"$SevenZipPathExe`" $argumentStringForProcess$affinitySimMsg" -Level SIMULATE
                }
            }
            # --- End Enhanced Simulation Message Logic ---

            $operationExitCode = 0
            $operationElapsedTime = New-TimeSpan -Seconds 0
            break
        }
        if (-not $PSCmdlet.ShouldProcess("Target: $($SevenZipArguments | Where-Object {$_ -notlike '-*'} | Select-Object -Last 1)", "Execute 7-Zip ($($SevenZipArguments[0]))")) {
            & $LocalWriteLog -Message "   - 7ZipManager/Executor/7-Zip execution (Attempt $currentTry/$actualMaxTries) skipped by user (ShouldProcess)." -Level WARNING
            $operationExitCode = -1000
            break
        }
        & $LocalWriteLog -Message "   - 7ZipManager/Executor: Attempting 7-Zip execution (Attempt $currentTry/$actualMaxTries)..."
        & $LocalWriteLog -Message "     Command: `"$SevenZipPathExe`" $argumentStringForProcess" -Level DEBUG
        $validPriorities = "Idle", "BelowNormal", "Normal", "AboveNormal", "High"
        if ([string]::IsNullOrWhiteSpace($ProcessPriority) -or $ProcessPriority -notin $validPriorities) {
            & $LocalWriteLog -Message "[WARNING] 7ZipManager/Executor: Invalid or empty 7-Zip process priority '$ProcessPriority' specified. Defaulting to 'Normal'." -Level WARNING; $ProcessPriority = "Normal"
        }
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew(); $process = $null
        try {
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $SevenZipPathExe
            $startInfo.Arguments = $argumentStringForProcess
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $HideOutput.IsPresent
            $startInfo.WindowStyle = if ($HideOutput.IsPresent) { [System.Diagnostics.ProcessWindowStyle]::Hidden } else { [System.Diagnostics.ProcessWindowStyle]::Normal }
            $startInfo.RedirectStandardError = $true
            if ($HideOutput.IsPresent) { $startInfo.RedirectStandardOutput = $true }
            & $LocalWriteLog -Message "  - 7ZipManager/Executor: Starting 7-Zip process with priority: $ProcessPriority" -Level DEBUG
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $startInfo
            $process.Start() | Out-Null
            try { $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]$ProcessPriority }
            catch { & $LocalWriteLog -Message "[WARNING] 7ZipManager/Executor: Failed to set 7-Zip process priority to '$ProcessPriority'. Error: $($_.Exception.Message)" -Level WARNING }
            if ($null -ne $cpuAffinityBitmask -and $cpuAffinityBitmask -ne 0L) {
                try { $process.ProcessorAffinity = [System.IntPtr]$cpuAffinityBitmask; & $LocalWriteLog -Message "  - 7ZipManager/Executor/CPU Affinity applied to 7-Zip process (PID: $($process.Id)). Effective affinity: $finalAffinityStringForLog." -Level "INFO" }
                catch { & $LocalWriteLog -Message "[WARNING] 7ZipManager/Executor: Failed to set CPU Affinity for 7-Zip process (PID: $($process.Id)). Effective affinity string: $finalAffinityStringForLog. Error: $($_.Exception.Message)" -Level "WARNING" }
            }
            elseif ($null -ne $cpuAffinityBitmask -and $cpuAffinityBitmask -eq 0L) { & $LocalWriteLog -Message "  - 7ZipManager/Executor/CPU Affinity: Resulting bitmask is 0 (no cores selected). No affinity will be applied. Original input: '$originalSevenZipCpuAffinityString'." -Level "INFO" }
            elseif (-not [string]::IsNullOrWhiteSpace($originalSevenZipCpuAffinityString)) { & $LocalWriteLog -Message "  - 7ZipManager/Executor/CPU Affinity: Not applied. Reason: $finalAffinityStringForLog." -Level "INFO" }
            $stdError = ""; if ($HideOutput.IsPresent) { $process.WaitForExit(); $stdError = $process.StandardError.ReadToEnd() } else { $process.WaitForExit() }
            $operationExitCode = $process.ExitCode
            if ($HideOutput.IsPresent -and (-not [string]::IsNullOrWhiteSpace($stdError))) {
                $logLevelForStdErr = if ($process.ExitCode -eq 0 -or ($process.ExitCode -eq 1 -and $TreatWarningsAsSuccess)) { "WARNING" } else { "ERROR" }
                & $LocalWriteLog -Message "  - 7ZipManager/Executor/7-Zip STDERR (captured as HideSevenZipOutput is true):" -Level $logLevelForStdErr
                $stdError.Split([Environment]::NewLine) | ForEach-Object { & $LocalWriteLog -Message "    | $_" -Level $logLevelForStdErr -NoTimestampToLogFile }
            }
        }
        catch { & $LocalWriteLog -Message "[ERROR] 7ZipManager/Executor: Failed to start or manage the 7-Zip process. Error: $($_.Exception.ToString())" -Level ERROR; $operationExitCode = -999 }
        finally { $stopwatch.Stop(); $operationElapsedTime = $stopwatch.Elapsed; if ($null -ne $process) { $process.Dispose() } }
        & $LocalWriteLog -Message "   - 7ZipManager/Executor/7-Zip attempt $currentTry finished. Exit Code: $operationExitCode. Elapsed Time: $operationElapsedTime"
        if ($operationExitCode -eq 0) { break }
        if ($operationExitCode -eq 1) { if ($TreatWarningsAsSuccess) { & $LocalWriteLog -Message "   - 7ZipManager/Executor: 7-Zip Warning (Exit Code 1) occurred but is being treated as success for this job." -Level INFO; break } }
        if ($operationExitCode -ne 0 -and ($operationExitCode -ne 1 -or ($operationExitCode -eq 1 -and -not $TreatWarningsAsSuccess))) {
            if ($currentTry -lt $actualMaxTries) { & $LocalWriteLog -Message "[WARNING] 7ZipManager/Executor: 7-Zip operation indicated an issue (Exit Code: $operationExitCode). Retrying in $actualDelaySeconds seconds..." -Level WARNING; Start-Sleep -Seconds $actualDelaySeconds }
            else { & $LocalWriteLog -Message "[ERROR] 7ZipManager/Executor: 7-Zip operation failed after $actualMaxTries attempt(s) (Final Exit Code: $operationExitCode)." -Level ERROR }
        }
    }
    return @{ ExitCode = $operationExitCode; ElapsedTime = $operationElapsedTime; AttemptsMade = $attemptsMade }
}
#endregion

#region --- 7-Zip Archive Tester ---
function Test-7ZipArchive {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [string]$SevenZipPathExe,
        [string]$ArchivePath,
        [Parameter(Mandatory = $false)]
        [string]$PlainTextPassword = $null,
        [string]$ProcessPriority = "Normal",
        [Parameter(Mandatory = $false)]
        [string]$SevenZipCpuAffinityString = $null,
        [switch]$HideOutput,
        [switch]$VerifyCRC, # NEW
        [int]$MaxRetries = 1,
        [int]$RetryDelaySeconds = 60,
        [bool]$EnableRetries = $false,
        [bool]$TreatWarningsAsSuccess = $false,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "7ZipManager/Executor/Test-7ZipArchive: Logger parameter active. TreatWarningsAsSuccess: $TreatWarningsAsSuccess, Input Affinity: '$SevenZipCpuAffinityString'" -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if ($null -ne $ForegroundColour) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        }
        else {
            & $Logger -Message $Message -Level $Level
        }
    }

    & $LocalWriteLog -Message "`n[INFO] 7ZipManager/Executor: Performing archive integrity test for '$ArchivePath'..."
    $testArguments = [System.Collections.Generic.List[string]]::new()
    $testArguments.Add("t") # Test command

    if ($VerifyCRC.IsPresent) {
        $testArguments.Add("-scrc") # Add switch to verify CRCs
        & $LocalWriteLog -Message "   - CRC Verification is ENABLED for this test." -Level "DEBUG"
    }

    $testArguments.Add($ArchivePath)

    if (-not [string]::IsNullOrWhiteSpace($PlainTextPassword)) {
        $testArguments.Add("-p$($PlainTextPassword)")
    }

    & $LocalWriteLog -Message "   - 7ZipManager/Executor/Test Command (raw args before Invoke-7ZipOperation internal quoting): `"$SevenZipPathExe`" $($testArguments -join ' ')" -Level DEBUG

    Write-ConsoleBanner -NameText "Testing Archive Integrity" -ValueText $ArchivePath -BannerWidth 78 -CenterText -PrependNewLine

    $invokeParams = @{
        SevenZipPathExe = $SevenZipPathExe; SevenZipArguments = $testArguments.ToArray()
        ProcessPriority = $ProcessPriority; HideOutput = $HideOutput.IsPresent
        PlainTextPassword = $PlainTextPassword
        SevenZipCpuAffinityString = $SevenZipCpuAffinityString
        MaxRetries = $MaxRetries; RetryDelaySeconds = $RetryDelaySeconds; EnableRetries = $EnableRetries
        TreatWarningsAsSuccess = $sanitizedTreatWarnings
        IsSimulateMode = $false
        Logger = $Logger
    }
    if ((Get-Command Invoke-7ZipOperation).Parameters.ContainsKey('PSCmdlet')) {
        $invokeParams.PSCmdlet = $PSCmdlet
    }

    $result = Invoke-7ZipOperation @invokeParams

    $msg = if ($result.ExitCode -eq 0) { "PASSED" }
    elseif ($result.ExitCode -eq 1 -and $TreatWarningsAsSuccess) { "PASSED (7-Zip Test Warning Exit Code: 1, treated as success)" }
    else { "FAILED (7-Zip Test Exit Code: $($result.ExitCode))" }

    $levelForResult = if ($result.ExitCode -eq 0 -or ($result.ExitCode -eq 1 -and $TreatWarningsAsSuccess)) { "SUCCESS" } else { "ERROR" }
    & $LocalWriteLog -Message "  - 7ZipManager/Executor/Archive Test Result for '$ArchivePath': $msg" -Level $levelForResult
    return $result
}
#endregion

Export-ModuleMember -Function Invoke-7ZipOperation, Test-7ZipArchive
