# Modules\Targets\SFTP\SFTP.TransferAgent.psm1
<#
.SYNOPSIS
    A sub-module for SFTP.Target.psm1. Handles the file upload operation.
.DESCRIPTION
    This module provides the 'Start-PoShBackupSftpUpload' function. It is responsible for
    transferring a single local file to a remote SFTP destination using an established
    Posh-SSH session.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    28-Jun-2025
    LastModified:   28-Jun-2025
    Purpose:        To isolate the SFTP file upload logic.
    Prerequisites:  PowerShell 5.1+, Posh-SSH module.
#>

function Start-PoShBackupSftpUpload {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$SftpSession,
        [Parameter(Mandatory = $true)]
        [string]$LocalSourcePath,
        [Parameter(Mandatory = $true)]
        [string]$FullRemoteDestinationPath,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    & $Logger -Message "SFTP.TransferAgent: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    if (-not $PSCmdletInstance.ShouldProcess($FullRemoteDestinationPath, "Upload File via SFTP")) {
        return @{ Success = $false; ErrorMessage = "SFTP upload to '$FullRemoteDestinationPath' skipped by user." }
    }
    
    try {
        & $LocalWriteLog -Message "      - SFTP.TransferAgent: Uploading file '$LocalSourcePath'..." -Level "DEBUG"
        Set-SFTPFile -SessionId $SftpSession.SessionId -LocalFile $LocalSourcePath -RemoteFile $FullRemoteDestinationPath -ErrorAction Stop
        & $LocalWriteLog -Message "      - SFTP.TransferAgent: Upload completed successfully." -Level "SUCCESS"
        return @{ Success = $true }
    }
    catch {
        return @{ Success = $false; ErrorMessage = "Failed to upload file to '$FullRemoteDestinationPath'. Error: $($_.Exception.Message)" }
    }
}

Export-ModuleMember -Function Start-PoShBackupSftpUpload
