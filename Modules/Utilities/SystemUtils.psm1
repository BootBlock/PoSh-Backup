# Modules\Utilities\SystemUtils.psm1
<#
.SYNOPSIS
    Provides utility functions for system-level interactions required by PoSh-Backup.
.DESCRIPTION
    This module contains functions that interact with the operating system or check
    system states, such as verifying administrator privileges and checking disk free space.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    25-May-2025
    LastModified:   25-May-2025
    Purpose:        System interaction utilities for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Requires a logger function to be passed to its functions.
#>

#region --- Helper Function Test-AdminPrivilege ---
function Test-AdminPrivilege {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )
    # Defensive PSSA appeasement line by directly calling the logger for this initial message
    & $Logger -Message "SystemUtils/Test-AdminPrivilege: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue

    # Internal helper to use the passed-in logger consistently for other messages
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        }
        else {
            & $Logger -Message $Message -Level $Level
        }
    }

    $currentUser = New-Object Security.Principal.WindowsPrincipal $([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        & $LocalWriteLog -Message "  - Admin Check: Script is running with Administrator privileges." -Level "DEBUG"
    }
    else {
        & $LocalWriteLog -Message "  - Admin Check: Script is NOT running with Administrator privileges. VSS functionality will be unavailable." -Level "DEBUG"
    }
    return $isAdmin
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
    & $Logger -Message "SystemUtils/Test-DestinationFreeSpace: Logger parameter active for path '$DestDir'." -Level "DEBUG" -ErrorAction SilentlyContinue

    # Internal helper to use the passed-in logger consistently for other messages
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        }
        else {
            & $Logger -Message $Message -Level $Level
        }
    }

    if ($MinRequiredGB -le 0) { return $true }

    & $LocalWriteLog -Message "`n[INFO] SystemUtils: Checking destination free space for '$DestDir'..." -Level "INFO"
    & $LocalWriteLog -Message "   - Minimum free space required: $MinRequiredGB GB" -Level "INFO"

    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: SystemUtils: Would check free space on '$DestDir'. Assuming sufficient space." -Level SIMULATE
        return $true
    }

    try {
        if (-not (Test-Path -LiteralPath $DestDir -PathType Container)) {
            & $LocalWriteLog -Message "[WARNING] SystemUtils: Destination directory '$DestDir' for free space check not found. Skipping." -Level WARNING
            return $true
        }
        $driveLetter = (Get-Item -LiteralPath $DestDir).PSDrive.Name
        $destDrive = Get-PSDrive -Name $driveLetter -ErrorAction Stop
        $freeSpaceGB = [math]::Round($destDrive.Free / 1GB, 2)
        & $LocalWriteLog -Message "   - SystemUtils: Available free space on drive $($destDrive.Name) (hosting '$DestDir'): $freeSpaceGB GB" -Level "INFO"

        if ($freeSpaceGB -lt $MinRequiredGB) {
            & $LocalWriteLog -Message "[WARNING] SystemUtils: Low disk space on destination. Available: $freeSpaceGB GB, Required: $MinRequiredGB GB." -Level WARNING
            if ($ExitOnLow) {
                & $LocalWriteLog -Message "FATAL: SystemUtils: Exiting job due to insufficient free disk space (ExitOnLowSpaceIfBelowMinimum is true)." -Level ERROR
                return $false
            }
        }
        else {
            & $LocalWriteLog -Message "   - SystemUtils: Free space check: OK (Available: $freeSpaceGB GB, Required: $MinRequiredGB GB)" -Level SUCCESS
        }
    }
    catch {
        & $LocalWriteLog -Message "[WARNING] SystemUtils: Could not determine free space for destination '$DestDir'. Check skipped. Error: $($_.Exception.Message)" -Level WARNING
    }
    return $true
}
#endregion

Export-ModuleMember -Function Test-AdminPrivilege, Test-DestinationFreeSpace
