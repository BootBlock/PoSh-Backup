<#
.SYNOPSIS
    Manages the execution of custom user-defined PowerShell hook scripts at various
    stages of the PoSh-Backup process.

.DESCRIPTION
    The HookManager module centralises the logic for invoking external PowerShell scripts
    (hooks) provided by the user in the job configuration. These hooks allow for
    custom actions to be performed before a backup starts, after it succeeds, after it
    fails, or always after a backup attempt.

    The primary exported function, Invoke-PoShBackupHook, handles:
    - Checking if a script path is provided for a given hook type.
    - Validating the existence of the hook script file.
    - Executing the script in a separate PowerShell process, passing relevant job
      information (like JobName, Status, ConfigFile path, SimulateMode) as parameters.
    - Capturing STDOUT and STDERR from the hook script.
    - Logging the execution status and output of the hook script.
    - Storing hook script execution details in the $Global:GlobalJobHookScriptData list
      for inclusion in reports.

    This module requires a logger function to be passed for its operations.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    18-May-2025
    LastModified:   18-May-2025
    Purpose:        Centralised management of user-defined hook script execution.
    Prerequisites:  PowerShell 5.1+.
                    Requires a logger function passed via the -Logger parameter.
#>

#region --- Exported Hook Script Invocation Function ---
function Invoke-PoShBackupHook {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Executes a specified user-defined hook script.
    .DESCRIPTION
        This function is responsible for invoking a PowerShell script provided by the user
        at a specific hook point in the backup process (e.g., PreBackup, PostBackupOnSuccess).
        It runs the script in a new PowerShell process, captures its output and exit code,
        and logs the results. Details of the execution are added to the global hook script
        data collection for reporting.
    .PARAMETER ScriptPath
        The full path to the PowerShell hook script to be executed. If empty or null,
        the function will not attempt execution.
    .PARAMETER HookType
        A string identifying the type of hook being executed (e.g., "PreBackup",
        "PostBackupOnSuccess"). This is used for logging and reporting.
    .PARAMETER HookParameters
        A hashtable of parameters to be passed to the hook script. Keys are parameter names,
        and values are their corresponding values.
    .PARAMETER IsSimulateMode
        A switch. If $true, the script execution is simulated: it will be logged as if it
        were run, but the script itself will not be executed.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function. This is used
        for all logging performed by this function.
    .EXAMPLE
        # Called internally by Operations.psm1
        # Invoke-PoShBackupHook -ScriptPath "C:\Scripts\MyPreBackup.ps1" `
        #                       -HookType "PreBackup" `
        #                       -HookParameters @{ JobName = "ServerBackup"; SimulateMode = $false } `
        #                       -IsSimulateMode:$false `
        #                       -Logger ${function:Write-LogMessage}
    .OUTPUTS
        None. Results are logged and stored in $Global:GlobalJobHookScriptData.
    #>
    param(
        [string]$ScriptPath,
        [string]$HookType,
        [hashtable]$HookParameters,
        [switch]$IsSimulateMode,
        [Parameter(Mandatory=$true)]
        [scriptblock]$Logger
    )

    # Defensive PSSA appeasement line by directly calling the logger for this initial message
    & $Logger -Message "Invoke-PoShBackupHook: Logger parameter active for hook '$HookType'." -Level "DEBUG" -ErrorAction SilentlyContinue

    # Internal helper to use the passed-in logger consistently for other messages
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if ($null -ne $ForegroundColour) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    if ([string]::IsNullOrWhiteSpace($ScriptPath)) { return } 

    & $LocalWriteLog -Message "`n[INFO] HookManager: Attempting to execute $HookType script: $ScriptPath" -Level "HOOK"
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        & $LocalWriteLog -Message "[WARNING] HookManager: $HookType script not found at '$ScriptPath'. Skipping execution." -Level "WARNING"
        if ($Global:GlobalJobHookScriptData -is [System.Collections.Generic.List[object]]) {
            $Global:GlobalJobHookScriptData.Add([PSCustomObject]@{ Name = $HookType; Path = $ScriptPath; Status = "Not Found"; Output = "Script file not found at specified path."})
        }
        return
    }

    $outputLog = [System.Collections.Generic.List[string]]::new()
    $status = "Success" 
    try {
        if ($IsSimulateMode.IsPresent) {
            & $LocalWriteLog -Message "SIMULATE: HookManager: Would execute $HookType script '$ScriptPath' with parameters: $($HookParameters | Out-String | ForEach-Object {$_.TrimEnd()})" -Level "SIMULATE"
            $outputLog.Add("SIMULATE: Script execution skipped due to simulation mode.")
            $status = "Simulated"
        } else {
            & $LocalWriteLog -Message "  - HookManager: Executing $HookType script: '$ScriptPath'" -Level "HOOK"
            $processArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
            $paramString = ""

            foreach ($key in $HookParameters.Keys) {
                $value = $HookParameters[$key]
                if ($value -is [bool] -or $value -is [switch]) {
                    if ($value) { 
                        $paramString += " -$key"
                    }
                } elseif ($value -is [string] -and ($value.Contains(" ") -or $value.Contains("'") -or $value.Contains('"')) ) {
                    # For values with spaces/quotes, ensure they are correctly passed as a single argument.
                    # PowerShell.exe -File parameter passing can be tricky with complex strings.
                    # Enclosing in single quotes for the outer command, then double for internal PowerShell parsing.
                    # This might need more robust escaping if parameters themselves contain many special characters.
                    $escapedValueForCmd = $value -replace '"', '""' # Double up internal double quotes
                    $paramString += " -$key " + '"' + $escapedValueForCmd + '"'
                } elseif ($null -ne $value) {
                    $paramString += " -$key $value"
                }
            }
            $processArgs += $paramString

            # Using temporary files for STDOUT/STDERR redirection to capture multi-line output reliably.
            $tempStdOut = New-TemporaryFile
            $tempStdErr = New-TemporaryFile

            & $LocalWriteLog -Message "    - HookManager: PowerShell arguments for hook script: $processArgs" -Level "DEBUG"
            $proc = Start-Process powershell.exe -ArgumentList $processArgs -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $tempStdOut.FullName -RedirectStandardError $tempStdErr.FullName

            $stdOutContent = Get-Content $tempStdOut.FullName -Raw -ErrorAction SilentlyContinue
            $stdErrContent = Get-Content $tempStdErr.FullName -Raw -ErrorAction SilentlyContinue

            Remove-Item $tempStdOut.FullName -Force -ErrorAction SilentlyContinue
            Remove-Item $tempStdErr.FullName -Force -ErrorAction SilentlyContinue

            if (-not [string]::IsNullOrWhiteSpace($stdOutContent)) {
                & $LocalWriteLog -Message "    $HookType Script STDOUT:" -Level "HOOK"
                $stdOutContent.Split([Environment]::NewLine) | ForEach-Object { & $LocalWriteLog -Message "      | $_" -Level "HOOK" -NoTimestampToLogFile; $outputLog.Add("OUTPUT: $_") }
            }
            if ($proc.ExitCode -ne 0) {
                & $LocalWriteLog -Message "[ERROR] HookManager: $HookType script '$ScriptPath' exited with error code $($proc.ExitCode)." -Level "ERROR"
                $status = "Failure (ExitCode $($proc.ExitCode))"
                if (-not [string]::IsNullOrWhiteSpace($stdErrContent)) {
                    & $LocalWriteLog -Message "    $HookType Script STDERR:" -Level "ERROR"
                    $stdErrContent.Split([Environment]::NewLine) | ForEach-Object { & $LocalWriteLog -Message "      | $_" -Level "ERROR" -NoTimestampToLogFile; $outputLog.Add("ERROR: $_") }
                }
            } elseif (-not [string]::IsNullOrWhiteSpace($stdErrContent)) { # Exit code 0, but something was written to STDERR
                 & $LocalWriteLog -Message "[WARNING] HookManager: $HookType script '$ScriptPath' wrote to STDERR despite exiting successfully (Code 0)." -Level "WARNING"
                 & $LocalWriteLog -Message "    $HookType Script STDERR (Warning):" -Level "WARNING"
                 $stdErrContent.Split([Environment]::NewLine) | ForEach-Object { & $LocalWriteLog -Message "      | $_" -Level "WARNING" -NoTimestampToLogFile; $outputLog.Add("STDERR_WARN: $_") }
            }
            $statusLevelForLog = if($status -like "Failure*"){"ERROR"}elseif($status -eq "Simulated"){"SIMULATE"}else{"SUCCESS"}
            & $LocalWriteLog -Message "  - HookManager: $HookType script execution finished. Status: $status" -Level $statusLevelForLog
        }
    } catch {
        & $LocalWriteLog -Message "[ERROR] HookManager: Exception occurred while trying to execute $HookType script '$ScriptPath': $($_.Exception.ToString())" -Level "ERROR"
        $outputLog.Add("EXCEPTION: $($_.Exception.Message)")
        $status = "Exception"
    }

    # Add hook execution data to the global list for reporting.
    if ($Global:GlobalJobHookScriptData -is [System.Collections.Generic.List[object]]) {
        $Global:GlobalJobHookScriptData.Add([PSCustomObject]@{
            Name   = $HookType
            Path   = $ScriptPath
            Status = $status
            Output = ($outputLog -join [System.Environment]::NewLine)
        })
    }
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupHook
