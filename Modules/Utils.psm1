<#
.SYNOPSIS
    Provides a collection of essential utility functions for the PoSh-Backup script.
    These include capabilities for logging, configuration value retrieval, administrative
    privilege checks, archive size formatting, and destination free space checking.
    Configuration loading and job resolution are handled by ConfigManager.psm1.
    Hook script execution is handled by HookManager.psm1.

.DESCRIPTION
    This module centralises common helper functions used throughout the PoSh-Backup solution,
    promoting code reusability, consistency, and maintainability. It handles tasks that are
    not specific to the core backup operations, configuration management, report generation,
    or hook script execution, but are essential for the overall script's robust
    functionality and user experience.

    Key exported functions include:
    - Write-LogMessage: For standardised console and file logging with colour-coding.
    - Get-ConfigValue: Safely retrieves values from configuration hashtables with default fallbacks.
    - Test-AdminPrivilege: Checks if the script is running with administrator privileges.
    - Get-ArchiveSizeFormatted: Converts byte sizes to human-readable formats (KB, MB, GB).
    - Test-DestinationFreeSpace: Checks if the destination directory has enough free space.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.11.3
    DateCreated:    10-May-2025
    LastModified:   18-May-2025
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
    } 
    elseif ($Level.ToUpperInvariant() -eq 'NONE') {
        $effectiveConsoleColour = $Host.UI.RawUI.ForegroundColor
    }

    # Safety check: If $effectiveConsoleColour somehow became an empty string (and is not a ConsoleColor object), default it.
    if (($effectiveConsoleColour -is [string]) -and ([string]::IsNullOrWhiteSpace($effectiveConsoleColour))) {
        # DIAGNOSTIC START - Enhanced
        Write-Warning "Write-LogMessage (SAFETY CHECK TRIGGERED - IsNullOrWhiteSpace):"
        Write-Warning "  -> Original Level string passed: '$Level' (Length: $($Level.Length))"
        $levelBytes = [System.Text.Encoding]::UTF8.GetBytes($Level)
        $levelHex = ($levelBytes | ForEach-Object { $_.ToString("X2") }) -join " "
        Write-Warning "  -> Level string as Hex: $levelHex"
        Write-Warning "  -> Level.ToUpperInvariant(): '$($Level.ToUpperInvariant())'"
        Write-Warning "  -> ForegroundColour param was: '$ForegroundColour'"
        Write-Warning "  -> effectiveConsoleColour before this safety check: '$effectiveConsoleColour'"
        Write-Warning "  -> Message: '$Message'. Defaulting to Host's current colour."
        # DIAGNOSTIC END
        $effectiveConsoleColour = $Host.UI.RawUI.ForegroundColor
    }
    elseif (($null -eq $effectiveConsoleColour) -and ($Level.ToUpperInvariant() -ne 'NONE')) {
        # DIAGNOSTIC START - Enhanced
        Write-Warning "Write-LogMessage (SAFETY CHECK TRIGGERED - Null effectiveConsoleColour):"
        Write-Warning "  -> Original Level string passed: '$Level' (Length: $($Level.Length))"
        $levelBytes = [System.Text.Encoding]::UTF8.GetBytes($Level)
        $levelHex = ($levelBytes | ForEach-Object { $_.ToString("X2") }) -join " "
        Write-Warning "  -> Level string as Hex: $levelHex"
        Write-Warning "  -> Level.ToUpperInvariant(): '$($Level.ToUpperInvariant())'"
        Write-Warning "  -> ForegroundColour param was: '$ForegroundColour'"
        Write-Warning "  -> Global:StatusToColourMap contains key '$($Level.ToUpperInvariant())': $($Global:StatusToColourMap.ContainsKey($Level.ToUpperInvariant()))"
        if ($Global:StatusToColourMap.ContainsKey($Level.ToUpperInvariant())) {
            Write-Warning "  -> Value from StatusToColourMap for '$($Level.ToUpperInvariant())': '$($Global:StatusToColourMap[$Level.ToUpperInvariant()])'"
        }
        Write-Warning "  -> Message: '$Message'. Defaulting to Host's current colour."
        # DIAGNOSTIC END
        $effectiveConsoleColour = $Host.UI.RawUI.ForegroundColor
    }

    if ($NoNewLine) {
        Write-Host $consoleMessage -ForegroundColor $effectiveConsoleColour -NoNewline
    }
    else {
        Write-Host $consoleMessage -ForegroundColor $effectiveConsoleColour
    }

    if ($Global:GlobalJobLogEntries -is [System.Collections.Generic.List[object]]) {
        $Global:GlobalJobLogEntries.Add([PSCustomObject]@{
                Timestamp = if ($NoTimestampToLogFile -and $Global:GlobalJobLogEntries.Count -gt 0) { "" } else { $timestamp } 
                Level     = $Level
                Message   = $Message
            })
    }

    if ($Global:GlobalEnableFileLogging -and $Global:GlobalLogFile -and $Level -ne "NONE") {
        try {
            Add-Content -Path $Global:GlobalLogFile -Value $logMessage -ErrorAction Stop
        }
        catch {
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
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )
    # Defensive PSSA appeasement line by directly calling the logger for this initial message
    & $Logger -Message "Test-AdminPrivilege: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue

    # Internal helper to use the passed-in logger consistently for other messages
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    & $LocalWriteLog -Message "[INFO] Checking for Administrator privileges..." -Level "DEBUG"
    $currentUser = New-Object Security.Principal.WindowsPrincipal $([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        & $LocalWriteLog -Message "  - Script is running with Administrator privileges." -Level "SUCCESS"
    }
    else {
        & $LocalWriteLog -Message "  - Script is NOT running with Administrator privileges. VSS functionality will be unavailable." -Level "WARNING"
    }
    return $isAdmin
}
#endregion

#region --- Get Archive Size Formatted ---
function Get-ArchiveSizeFormatted {
    [CmdletBinding()]
    param(
        [string]$PathToArchive,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )
    # Defensive PSSA appeasement line by directly calling the logger for this initial message
    & $Logger -Message "Get-ArchiveSizeFormatted: Logger parameter active for path '$PathToArchive'." -Level "DEBUG" -ErrorAction SilentlyContinue

    # Internal helper to use the passed-in logger consistently for other messages
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    $FormattedSize = "N/A"
    try {
        if (Test-Path -LiteralPath $PathToArchive -PathType Leaf) {
            $ArchiveFile = Get-Item -LiteralPath $PathToArchive -ErrorAction Stop
            $Size = $ArchiveFile.Length
            if ($Size -ge 1GB) { $FormattedSize = "{0:N2} GB" -f ($Size / 1GB) }
            elseif ($Size -ge 1MB) { $FormattedSize = "{0:N2} MB" -f ($Size / 1MB) }
            elseif ($Size -ge 1KB) { $FormattedSize = "{0:N2} KB" -f ($Size / 1KB) }
            else { $FormattedSize = "$Size Bytes" }
        }
        else {
            & $LocalWriteLog -Message "[DEBUG] File not found at '$PathToArchive' for size formatting." -Level "DEBUG"
            $FormattedSize = "File not found"
        }
    }
    catch {
        & $LocalWriteLog -Message "[WARNING] Error getting file size for '$PathToArchive': $($_.Exception.Message)" -Level "WARNING"
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
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function.
    .OUTPUTS
        System.Boolean
        Returns $true if there is sufficient free space, or if the check is disabled/simulated,
        or if ExitOnLow is $false and space is low.
        Returns $false only if ExitOnLow is $true and free space is below the minimum requirement.
    .EXAMPLE
        # if (Test-DestinationFreeSpace -DestDir "D:\Backups" -MinRequiredGB 10 -ExitOnLow $true -Logger ${function:Write-LogMessage}) {
        #   Write-Host "Sufficient space found."
        # } else {
        #   Write-Error "Insufficient space, job should halt."
        # }
    #>
    param(
        [string]$DestDir,
        [int]$MinRequiredGB,
        [bool]$ExitOnLow, 
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )
    # Defensive PSSA appeasement line by directly calling the logger for this initial message
    & $Logger -Message "Test-DestinationFreeSpace: Logger parameter active for path '$DestDir'." -Level "DEBUG" -ErrorAction SilentlyContinue

    # Internal helper to use the passed-in logger consistently for other messages
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    if ($MinRequiredGB -le 0) { return $true } 

    & $LocalWriteLog -Message "`n[INFO] Utils: Checking destination free space for '$DestDir'..." -Level "INFO" 
    & $LocalWriteLog -Message "   - Minimum free space required: $MinRequiredGB GB" -Level "INFO"

    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: Utils: Would check free space on '$DestDir'. Assuming sufficient space." -Level SIMULATE
        return $true
    }

    try {
        if (-not (Test-Path -LiteralPath $DestDir -PathType Container)) {
            & $LocalWriteLog -Message "[WARNING] Utils: Destination directory '$DestDir' for free space check not found. Skipping." -Level WARNING
            return $true 
        }
        $driveLetter = (Get-Item -LiteralPath $DestDir).PSDrive.Name
        $destDrive = Get-PSDrive -Name $driveLetter -ErrorAction Stop
        $freeSpaceGB = [math]::Round($destDrive.Free / 1GB, 2)
        & $LocalWriteLog -Message "   - Utils: Available free space on drive $($destDrive.Name) (hosting '$DestDir'): $freeSpaceGB GB" -Level "INFO"

        if ($freeSpaceGB -lt $MinRequiredGB) {
            & $LocalWriteLog -Message "[WARNING] Utils: Low disk space on destination. Available: $freeSpaceGB GB, Required: $MinRequiredGB GB." -Level WARNING
            if ($ExitOnLow) {
                & $LocalWriteLog -Message "FATAL: Utils: Exiting job due to insufficient free disk space (ExitOnLowSpaceIfBelowMinimum is true)." -Level ERROR
                return $false 
            }
        }
        else {
            & $LocalWriteLog -Message "   - Utils: Free space check: OK (Available: $freeSpaceGB GB, Required: $MinRequiredGB GB)" -Level SUCCESS
        }
    }
    catch {
        & $LocalWriteLog -Message "[WARNING] Utils: Could not determine free space for destination '$DestDir'. Check skipped. Error: $($_.Exception.Message)" -Level WARNING
    }
    return $true 
}
#endregion

#region --- Exported Functions ---
Export-ModuleMember -Function Write-LogMessage, Get-ConfigValue, Test-AdminPrivilege, Get-ArchiveSizeFormatted, Test-DestinationFreeSpace
#endregion
