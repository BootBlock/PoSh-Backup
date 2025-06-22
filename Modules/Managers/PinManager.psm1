# Modules\Managers\PinManager.psm1
<#
.SYNOPSIS
    Manages the pinning and unpinning of PoSh-Backup archives to protect them
    from automatic retention policy deletion.
.DESCRIPTION
    This module provides functions to create and remove '.pinned' marker files
    associated with backup archives. The presence of a '.pinned' file (e.g.,
    'MyBackup.7z.pinned') signals to the RetentionManager that the corresponding
    archive ('MyBackup.7z') should be exempt from any automated deletion.

    The created '.pinned' file now contains metadata about when, by whom, and
    optionally why the backup was pinned.

    This module is intended to be called by the ScriptModeHandler when a user
    invokes the -PinBackup or -UnpinBackup command-line parameters.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.2.0 # Added -Reason parameter to Add-PoShBackupPin.
    DateCreated:    06-Jun-2025
    LastModified:   21-Jun-2025
    Purpose:        To manage the lifecycle of backup archive pins.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Exported Functions ---

function Add-PoShBackupPin {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [string]$Reason,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    # PSSA Appeasement: Use the Logger parameter directly.
    & $Logger -Message "PinManager/Add-PoShBackupPin: Logger parameter active for path '$Path'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO")
        & $Logger -Message $Message -Level $Level
    }

    & $LocalWriteLog -Message "PinManager/Add-PoShBackupPin: Attempting to pin backup archive at '$Path'." -Level "DEBUG"

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        & $LocalWriteLog -Message "PinManager/Add-PoShBackupPin: Cannot pin file. Path does not exist or is not a file: '$Path'." -Level "ERROR"
        return
    }

    $pinFilePath = "$($Path).pinned"

    if (Test-Path -LiteralPath $pinFilePath -PathType Leaf) {
        & $LocalWriteLog -Message "PinManager/Add-PoShBackupPin: Archive is already pinned. Marker file already exists at '$pinFilePath'." -Level "INFO"
        return
    }

    if (-not $PSCmdlet.ShouldProcess($pinFilePath, "Create Pin Marker File")) {
        & $LocalWriteLog -Message "PinManager/Add-PoShBackupPin: Pin creation for '$Path' skipped by user." -Level "WARNING"
        return
    }

    try {
        # Create descriptive content for the pin file.
        $reasonText = if (-not [string]::IsNullOrWhiteSpace($Reason)) { $Reason } else { "-" }
        
        $pinContent = @"
# PoSh-Backup Pinned Archive Marker File
#
# This file's presence prevents the associated backup archive from being automatically
# deleted by retention policies. The archive and its related parts (volumes, manifests)
# will be ignored during retention scans.
#
# To unpin the archive and make it subject to retention again, either delete this
# .pinned file manually, or use the -UnpinBackup command:
#
#   .\\PoSh-Backup.ps1 -UnpinBackup "$Path"
#
# --- METADATA ---
# Associated Archive: $($Path)
# Pinned Date       : $(Get-Date -Format 'o')
# Pinned By         : $($env:USERDOMAIN)\$($env:USERNAME)
# Pinned On         : $($env:COMPUTERNAME)
# Pin Reason        : $reasonText
#
"@

        # Use New-Item to explicitly create the file first, which is a more robust approach.
        New-Item -Path $pinFilePath -ItemType File -Value $pinContent -Force -ErrorAction Stop | Out-Null
        
        & $LocalWriteLog -Message "PinManager/Add-PoShBackupPin: Successfully pinned backup archive. Marker created at '$pinFilePath'." -Level "SUCCESS"
    }
    catch {
        & $LocalWriteLog -Message "PinManager/Add-PoShBackupPin: Failed to create pin marker file at '$pinFilePath'. Error: $($_.Exception.Message)" -Level "ERROR"
    }
}

function Remove-PoShBackupPin {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    # PSSA Appeasement: Use the Logger parameter directly.
    & $Logger -Message "PinManager/Remove-PoShBackupPin: Logger parameter active for path '$Path'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO")
        & $Logger -Message $Message -Level $Level
    }

    & $LocalWriteLog -Message "PinManager/Remove-PoShBackupPin: Attempting to unpin backup archive at '$Path'." -Level "DEBUG"

    $pinFilePath = "$($Path).pinned"

    if (-not (Test-Path -LiteralPath $pinFilePath -PathType Leaf)) {
        & $LocalWriteLog -Message "PinManager/Remove-PoShBackupPin: Archive is not pinned. Marker file not found at '$pinFilePath'." -Level "INFO"
        return
    }

    if (-not $PSCmdlet.ShouldProcess($pinFilePath, "Remove Pin Marker File")) {
        & $LocalWriteLog -Message "PinManager/Remove-PoShBackupPin: Pin removal for '$Path' skipped by user." -Level "WARNING"
        return
    }

    try {
        Remove-Item -LiteralPath $pinFilePath -Force -ErrorAction Stop
        & $LocalWriteLog -Message "PinManager/Remove-PoShBackupPin: Successfully unpinned backup archive. Marker file removed from '$pinFilePath'." -Level "SUCCESS"
    }
    catch {
        & $LocalWriteLog -Message "PinManager/Remove-PoShBackupPin: Failed to remove pin marker file at '$pinFilePath'. Error: $($_.Exception.Message)" -Level "ERROR"
    }
}

#endregion

Export-ModuleMember -Function Add-PoShBackupPin, Remove-PoShBackupPin
