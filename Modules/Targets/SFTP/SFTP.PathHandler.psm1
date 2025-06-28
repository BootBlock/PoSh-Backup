# Modules\Targets\SFTP\SFTP.PathHandler.psm1
<#
.SYNOPSIS
    A sub-module for SFTP.Target.psm1. Handles remote path validation and creation.
.DESCRIPTION
    This module provides the 'Set-SFTPTargetPath' function. It is responsible for ensuring
    that a given path exists on the remote SFTP server, creating the directory structure
    component-by-component if it does not.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    28-Jun-2025
    LastModified:   28-Jun-2025
    Purpose:        To isolate the SFTP remote path creation logic.
    Prerequisites:  PowerShell 5.1+, Posh-SSH module.
#>

function Set-SFTPTargetPath {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$SftpSession,
        [Parameter(Mandatory = $true)]
        [string]$RemotePath,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    & $Logger -Message "SFTP.PathHandler: Logger active for path '$RemotePath'." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    if (-not $PSCmdletInstance.ShouldProcess($RemotePath, "Ensure SFTP Directory Exists")) {
        return @{ Success = $false; ErrorMessage = "SFTP directory creation for '$RemotePath' skipped by user." }
    }

    try {
        if (Test-SFTPPath -SessionId $SftpSession.SessionId -Path $RemotePath -ErrorAction SilentlyContinue) {
            & $LocalWriteLog -Message "  - SFTP.PathHandler: Remote path '$RemotePath' already exists." -Level "DEBUG"
            return @{ Success = $true }
        }

        & $LocalWriteLog -Message "  - SFTP.PathHandler: Remote path '$RemotePath' not found. Creating..." -Level "DEBUG"
        New-SFTPItem -SessionId $SftpSession.SessionId -Path $RemotePath -ItemType Directory -Force -ErrorAction Stop
        
        # Verify creation
        if (Test-SFTPPath -SessionId $SftpSession.SessionId -Path $RemotePath -ErrorAction SilentlyContinue) {
            & $LocalWriteLog -Message "    - SFTP.PathHandler: Successfully created remote path '$RemotePath'." -Level "SUCCESS"
            return @{ Success = $true }
        } else {
            throw "Path creation was attempted but verification failed for '$RemotePath'."
        }
    }
    catch {
        return @{ Success = $false; ErrorMessage = "Failed to ensure remote path '$RemotePath' exists. Error: $($_.Exception.Message)" }
    }
}

Export-ModuleMember -Function Set-SFTPTargetPath
