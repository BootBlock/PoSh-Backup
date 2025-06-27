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
    Version:        1.2.6 # Corrected 7-Zip output stream redirection.
    DateCreated:    29-May-2025
    LastModified:   27-Jun-2025
    Purpose:        7-Zip command execution logic for 7ZipManager.
    Prerequisites:  PowerShell 5.1+.
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
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )

    & $Logger -Message "7ZipManager/Executor/Invoke-7ZipOperation: Logger active. TreatWarningsAsSuccess: $TreatWarningsAsSuccess, Input Affinity: '$SevenZipCpuAffinityString'" -Level "DEBUG" -ErrorAction SilentlyContinue

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
    if (-not [string]::IsNullOrWhiteSpace($SevenZipCpuAffinityString)) {
        $numberOfLogicalProcessors = [int]$env:NUMBER_OF_PROCESSORS
        if ($numberOfLogicalProcessors -gt 0) {
            if ($SevenZipCpuAffinityString -match '^0x([0-9a-fA-F]+)$') {
                try { $cpuAffinityBitmask = ([Convert]::ToInt64($matches[0], 16)) -band ((1L -shl $numberOfLogicalProcessors) - 1L) }
                catch {
                    & $LocalWriteLog -Message "[DEBUG] 7ZipManager/Executor: Failed to parse hex affinity string '$_'. Silently ignoring." -Level "DEBUG"
                }
            }
            elseif ($SevenZipCpuAffinityString -match '^(\d+(,\d+)*)$') {
                $calculatedBitmask = 0L
                $SevenZipCpuAffinityString.Split(',') | ForEach-Object { try { [int]$_ } catch { -1 } } | Where-Object { $_ -ge 0 -and $_ -lt $numberOfLogicalProcessors } | ForEach-Object {
                    $calculatedBitmask = $calculatedBitmask -bor (1L -shl $_)
                }
                if ($calculatedBitmask -gt 0L) { $cpuAffinityBitmask = $calculatedBitmask }
            }
        }
    }

    while ($currentTry -lt $actualMaxTries) {
        $currentTry++; $attemptsMade = $currentTry
        if ($IsSimulateMode.IsPresent) {
            $simMessage = "SIMULATE: Would execute 7-Zip command: $($SevenZipArguments -join ' ')"
            & $LocalWriteLog -Message $simMessage -Level "SIMULATE"; $operationExitCode = 0; break
        }
        if (-not $PSCmdlet.ShouldProcess("Target: $($SevenZipArguments | Where-Object {$_ -notlike '-*'} | Select-Object -Last 1)", "Execute 7-Zip ($($SevenZipArguments[0]))")) {
            $operationExitCode = -1000; break
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew(); $process = $null
        try {
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $SevenZipPathExe
            $startInfo.Arguments = $argumentStringForProcess
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true # Always create no window; visibility handled by stream redirection.
            $startInfo.RedirectStandardOutput = $HideOutput.IsPresent
            $startInfo.RedirectStandardError = $true # Always redirect error stream to capture it

            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $startInfo
            $process.Start() | Out-Null
            try { $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]$ProcessPriority }
            catch {
                & $LocalWriteLog -Message "[DEBUG] 7ZipManager/Executor: Failed to set CPU affinity. Error: $($_.Exception.Message)" -Level "DEBUG"
            }
            if ($null -ne $cpuAffinityBitmask -and $cpuAffinityBitmask -ne 0L) {
                try { $process.ProcessorAffinity = [System.IntPtr]$cpuAffinityBitmask } catch {
                    & $LocalWriteLog -Message "[DEBUG] 7ZipManager/Executor: Failed to set CPU affinity. Error: $($_.Exception.Message)" -Level "DEBUG"
                }
            }

            $stdError = $process.StandardError.ReadToEnd()
            $process.WaitForExit()

            $operationExitCode = $process.ExitCode
            if (-not [string]::IsNullOrWhiteSpace($stdError)) {
                $logLevelForStdErr = if ($operationExitCode -eq 0 -or ($operationExitCode -eq 1 -and $TreatWarningsAsSuccess)) { "WARNING" } else { "ERROR" }
                & $LocalWriteLog -Message "  - 7ZipManager/Executor/7-Zip STDERR:" -Level $logLevelForStdErr
                $stdError.Split([Environment]::NewLine) | ForEach-Object { & $LocalWriteLog -Message "    | $_" -Level $logLevelForStdErr -NoTimestampToLogFile }
            }
        }
        catch { $operationExitCode = -999 }
        finally { $stopwatch.Stop(); $operationElapsedTime = $stopwatch.Elapsed; if ($null -ne $process) { $process.Dispose() } }

        if ($operationExitCode -eq 0) { break }
        if ($operationExitCode -eq 1 -and $TreatWarningsAsSuccess) { break }
        if ($currentTry -lt $actualMaxTries) { & $LocalWriteLog -Message "[WARNING] 7-Zip operation failed (Exit Code: $operationExitCode). Retrying in $actualDelaySeconds seconds..." -Level WARNING; Start-Sleep -Seconds $actualDelaySeconds }
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
        [switch]$VerifyCRC,
        [int]$MaxRetries = 1,
        [int]$RetryDelaySeconds = 60,
        [bool]$EnableRetries = $false,
        [bool]$TreatWarningsAsSuccess = $false,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    & $LocalWriteLog -Message "`n[INFO] 7ZipManager/Executor: Performing archive integrity test for '$ArchivePath'..."
    $testArguments = [System.Collections.Generic.List[string]]::new()
    $testArguments.Add("t")

    if ($VerifyCRC.IsPresent) { $testArguments.Add("-scrc") }
    $testArguments.Add($ArchivePath)
    if (-not [string]::IsNullOrWhiteSpace($PlainTextPassword)) { $testArguments.Add("-p$($PlainTextPassword)") }

    Write-ConsoleBanner -NameText "Testing Archive Integrity" -ValueText $ArchivePath -BannerWidth 78 -CenterText -PrependNewLine

    $sanitizedTreatWarnings = $false
    if ($TreatWarningsAsSuccess -is [bool]) { $sanitizedTreatWarnings = $TreatWarningsAsSuccess }

    $invokeParams = @{
        SevenZipPathExe = $SevenZipPathExe; SevenZipArguments = $testArguments.ToArray()
        ProcessPriority = $ProcessPriority; HideOutput = $HideOutput.IsPresent
        PlainTextPassword = $PlainTextPassword; SevenZipCpuAffinityString = $SevenZipCpuAffinityString
        MaxRetries = $MaxRetries; RetryDelaySeconds = $RetryDelaySeconds
        EnableRetries = $EnableRetries; TreatWarningsAsSuccess = $sanitizedTreatWarnings
        Logger = $Logger; PSCmdlet = $PSCmdlet
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
