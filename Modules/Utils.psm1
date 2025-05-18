<#
.SYNOPSIS
    Provides a collection of essential utility functions for the PoSh-Backup script.
    These include capabilities for logging, configuration value retrieval, administrative
    privilege checks, external hook script execution, archive size formatting, and
    destination free space checking.
    Configuration loading and job resolution are handled by ConfigManager.psm1.

.DESCRIPTION
    This module centralises common helper functions used throughout the PoSh-Backup solution,
    promoting code reusability, consistency, and maintainability. It handles tasks that are
    not specific to the core backup operations, configuration management, or report generation
    but are essential for the overall script's robust functionality and user experience.

    Key exported functions include:
    - Write-LogMessage: For standardised console and file logging with colour-coding.
    - Get-ConfigValue: Safely retrieves values from configuration hashtables with default fallbacks.
    - Test-AdminPrivilege: Checks if the script is running with administrator privileges.
    - Invoke-HookScript: Executes user-defined PowerShell scripts at various hook points.
    - Get-ArchiveSizeFormatted: Converts byte sizes to human-readable formats (KB, MB, GB).
    - Test-DestinationFreeSpace: Checks if the destination directory has enough free space.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.10.0 # Moved Test-DestinationFreeSpace here from Operations.psm1.
    DateCreated:    10-May-2025
    LastModified:   17-May-2025
    Purpose:        Core utility functions for the PoSh-Backup solution.
    Prerequisites:  PowerShell 5.1+. Some functions may have dependencies on specific global
                    variables (e.g., $Global:StatusToColourMap) being set by the main script.
#>

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
            Write-Host "CRITICAL: Failed to write to log file '$($Global:GlobalLogFile)'. Error: $($_.Exception.Message)" -ForegroundColor Red
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
        [object]$DefaultValue
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

#region --- Helper Function Test-AdminPrivilege ---
function Test-AdminPrivilege {
    [CmdletBinding()]
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
    param(
        [string]$ScriptPath,
        [string]$HookType,
        [hashtable]$HookParameters,
        [switch]$IsSimulateMode
    )
    if ([string]::IsNullOrWhiteSpace($ScriptPath)) { return } 

    Write-LogMessage "`n[INFO] Attempting to execute $HookType script: $ScriptPath" -Level "HOOK"
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        Write-LogMessage "[WARNING] $HookType script not found at '$ScriptPath'. Skipping execution." -Level "WARNING"
        if ($Global:GlobalJobHookScriptData -is [System.Collections.Generic.List[object]]) {
            $Global:GlobalJobHookScriptData.Add([PSCustomObject]@{ Name = $HookType; Path = $ScriptPath; Status = "Not Found"; Output = "Script file not found at specified path."})
        }
        return
    }

    $outputLog = [System.Collections.Generic.List[string]]::new()
    $status = "Success" 
    try {
        if ($IsSimulateMode.IsPresent) {
            Write-LogMessage "SIMULATE: Would execute $HookType script '$ScriptPath' with parameters: $($HookParameters | Out-String | ForEach-Object {$_.TrimEnd()})" -Level "SIMULATE"
            $outputLog.Add("SIMULATE: Script execution skipped due to simulation mode.")
            $status = "Simulated"
        } else {
            Write-LogMessage "  - Executing $HookType script: '$ScriptPath'" -Level "HOOK"
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

#region --- Destination Free Space Check ---
function Test-DestinationFreeSpace {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Checks if the destination directory has enough free space for a backup operation.
    .DESCRIPTION
        This function verifies if the drive hosting the specified destination directory
        has at least the minimum required gigabytes (GB) of free space. It can be configured
        to either just warn or to cause the calling process to halt the job if space is insufficient.
    .PARAMETER DestDir
        The path to the destination directory. The free space of the drive hosting this directory will be checked.
    .PARAMETER MinRequiredGB
        The minimum amount of free space required in Gigabytes (GB). If set to 0 or a negative value,
        the check is considered passed (disabled).
    .PARAMETER ExitOnLow
        A boolean. If $true and the free space is below MinRequiredGB, the function will log a FATAL error
        and return $false, signaling the calling process to halt. If $false (default), it will log a WARNING
        and return $true, allowing the process to continue.
    .PARAMETER IsSimulateMode
        A switch. If $true, the actual free space check is skipped, a simulation message is logged,
        and the function returns $true.
    .OUTPUTS
        System.Boolean
        Returns $true if there is sufficient free space, or if the check is disabled/simulated,
        or if ExitOnLow is $false and space is low.
        Returns $false only if ExitOnLow is $true and free space is below the minimum requirement.
    .EXAMPLE
        # if (Test-DestinationFreeSpace -DestDir "D:\Backups" -MinRequiredGB 10 -ExitOnLow $true) {
        #   Write-Host "Sufficient space found."
        # } else {
        #   Write-Error "Insufficient space, job should halt."
        # }
    #>
    param(
        [string]$DestDir,
        [int]$MinRequiredGB,
        [bool]$ExitOnLow, 
        [switch]$IsSimulateMode
    )
    if ($MinRequiredGB -le 0) { return $true } 

    Write-LogMessage "`n[INFO] Utils: Checking destination free space for '$DestDir'..." -Level "INFO" # Prefixed with Utils
    Write-LogMessage "   - Minimum free space required: $MinRequiredGB GB" -Level "INFO"

    if ($IsSimulateMode.IsPresent) {
        Write-LogMessage "SIMULATE: Utils: Would check free space on '$DestDir'. Assuming sufficient space." -Level SIMULATE
        return $true
    }

    try {
        if (-not (Test-Path -LiteralPath $DestDir -PathType Container)) {
            Write-LogMessage "[WARNING] Utils: Destination directory '$DestDir' for free space check not found. Skipping." -Level WARNING
            return $true 
        }
        $driveLetter = (Get-Item -LiteralPath $DestDir).PSDrive.Name
        $destDrive = Get-PSDrive -Name $driveLetter -ErrorAction Stop
        $freeSpaceGB = [math]::Round($destDrive.Free / 1GB, 2)
        Write-LogMessage "   - Utils: Available free space on drive $($destDrive.Name) (hosting '$DestDir'): $freeSpaceGB GB" -Level "INFO"

        if ($freeSpaceGB -lt $MinRequiredGB) {
            Write-LogMessage "[WARNING] Utils: Low disk space on destination. Available: $freeSpaceGB GB, Required: $MinRequiredGB GB." -Level WARNING
            if ($ExitOnLow) {
                Write-LogMessage "FATAL: Utils: Exiting job due to insufficient free disk space (ExitOnLowSpaceIfBelowMinimum is true)." -Level ERROR
                return $false 
            }
        } else {
            Write-LogMessage "   - Utils: Free space check: OK (Available: $freeSpaceGB GB, Required: $MinRequiredGB GB)" -Level SUCCESS
        }
    } catch {
        Write-LogMessage "[WARNING] Utils: Could not determine free space for destination '$DestDir'. Check skipped. Error: $($_.Exception.Message)" -Level WARNING
    }
    return $true 
}
#endregion

#region --- Exported Functions ---
Export-ModuleMember -Function Write-LogMessage, Get-ConfigValue, Test-AdminPrivilege, Invoke-HookScript, Get-ArchiveSizeFormatted, Test-DestinationFreeSpace
#endregion
