# Modules\Utilities\Update\BackupHandler.psm1
<#
.SYNOPSIS
    A sub-module for the Update facade. Handles backing up the current PoSh-Backup installation.
.DESCRIPTION
    This module provides the 'Invoke-CurrentInstallationBackup' function, which is responsible
    for creating a complete, versioned backup of the current PoSh-Backup installation directory.
    This serves as a critical safety measure before the 'apply_update.ps1' script overwrites
    the existing files.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    25-Jun-2025
    LastModified:   25-Jun-2025
    Purpose:        To encapsulate the pre-update backup logic.
    Prerequisites:  PowerShell 5.1+.
#>

function Invoke-CurrentInstallationBackup {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath, # The PSScriptRoot of the current installation
        [Parameter(Mandatory = $true)]
        [version]$InstalledVersion,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "Update/BackupHandler: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO")
        & $Logger -Message $Message -Level $Level
    }

    & $LocalWriteLog -Message "  - Update/BackupHandler: Preparing to back up current installation..." -Level "DEBUG"

    try {
        $backupDirName = "PoSh-Backup_Backup_v$($InstalledVersion)_$(Get-Date -Format 'yyyyMMddHHmmss')"
        # Attempt to back up to a directory *outside* the main installation path.
        $backupParentDir = Split-Path -Path $SourcePath -Parent

        if ([string]::IsNullOrWhiteSpace($backupParentDir) -or (-not (Test-Path -LiteralPath $backupParentDir -PathType Container))) {
            # Fallback to a _Backups folder inside the current install path if parent is not accessible.
            & $LocalWriteLog -Message "    - Could not determine or access parent directory. Using fallback '_Backups' folder inside installation root." -Level "DEBUG"
            $backupParentDir = Join-Path -Path $SourcePath -ChildPath "_Backups"
            if (-not (Test-Path -LiteralPath $backupParentDir -PathType Container)) {
                New-Item -Path $backupParentDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }
        }

        $backupFullPath = Join-Path -Path $backupParentDir -ChildPath $backupDirName
        
        & $LocalWriteLog -Message "  - Update/BackupHandler: Backing up current installation from '$SourcePath' to '$backupFullPath'." -Level "INFO"
        Write-Host "Backing up current installation to '$backupFullPath'..." -ForegroundColor Cyan
        
        if (-not $PSCmdlet.ShouldProcess($backupFullPath, "Create Backup of Current Installation")) {
            throw "Backup of current installation was skipped by user."
        }

        Copy-Item -Path $SourcePath -Destination $backupFullPath -Recurse -Force -ErrorAction Stop
        
        & $LocalWriteLog -Message "    - Update/BackupHandler: Current installation backed up successfully." -Level "SUCCESS"
        Write-Host "Current version backed up successfully." -ForegroundColor Green

        return @{
            Success      = $true
            BackupPath   = $backupFullPath
            ErrorMessage = $null
        }
    }
    catch {
        $errorMessage = "Failed to back up current installation. Error: $($_.Exception.Message)"
        & $LocalWriteLog -Message "[ERROR] Update/BackupHandler: $errorMessage" -Level "ERROR"
        return @{
            Success      = $false
            BackupPath   = $null
            ErrorMessage = $errorMessage
        }
    }
}

Export-ModuleMember -Function Invoke-CurrentInstallationBackup
