# Modules\Targets\SFTP\SFTP.SessionManager.psm1
<#
.SYNOPSIS
    A sub-module for SFTP.Target.psm1. Manages the SFTP session lifecycle.
.DESCRIPTION
    This module provides functions to establish and terminate SFTP sessions using Posh-SSH.
    It handles the retrieval of credentials from secrets and the logic for both password-based
    and key-based authentication, including key passphrases.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.1
    DateCreated:    28-Jun-2025
    LastModified:   28-Jun-2025
    Purpose:        To isolate SFTP session and authentication logic.
    Prerequisites:  PowerShell 5.1+, Posh-SSH module.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Targets\SFTP
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "SFTP.SessionManager.psm1 FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}
#endregion

function New-PoShBackupSftpSession {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$TargetSpecificSettings,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    
    $sftpServer = $TargetSpecificSettings.SFTPServerAddress
    $sftpPort = if ($TargetSpecificSettings.ContainsKey('SFTPPort')) { $TargetSpecificSettings.SFTPPort } else { 22 }
    $sftpUser = $TargetSpecificSettings.SFTPUserName
    $skipHostKeyCheck = if ($TargetSpecificSettings.ContainsKey('SkipHostKeyCheck')) { $TargetSpecificSettings.SkipHostKeyCheck } else { $false }
    
    $securePassphrase = $null
    $securePassword = $null
    
    try {
        if (-not $PSCmdletInstance.ShouldProcess($sftpServer, "Establish SFTP Session")) {
            return @{ Success = $false; Session = $null; ErrorMessage = "SFTP Session creation for '$sftpServer' skipped by user." }
        }

        $sessionParams = @{
            ComputerName = $sftpServer
            Port         = $sftpPort
            Username     = $sftpUser
            ErrorAction  = 'Stop'
        }
        if ($skipHostKeyCheck) { $sessionParams.AcceptKey = $true }

        $sftpPassword = Get-PoShBackupSecret -SecretName $TargetSpecificSettings.SFTPPasswordSecretName -Logger $Logger -AsPlainText -SecretPurposeForLog "SFTP Password"
        $sftpKeyFilePath = Get-PoShBackupSecret -SecretName $TargetSpecificSettings.SFTPKeyFileSecretName -Logger $Logger -AsPlainText -SecretPurposeForLog "SFTP Key File Path"
        $sftpKeyPassphrase = Get-PoShBackupSecret -SecretName $TargetSpecificSettings.SFTPKeyFilePassphraseSecretName -Logger $Logger -AsPlainText -SecretPurposeForLog "SFTP Key Passphrase"
        
        if (-not [string]::IsNullOrWhiteSpace($sftpKeyFilePath)) {
            if (-not (Test-Path -LiteralPath $sftpKeyFilePath -PathType Leaf)) { throw "SFTP Key File not found at path '$sftpKeyFilePath'." }
            $sessionParams.KeyFile = $sftpKeyFilePath
            if (-not [string]::IsNullOrWhiteSpace($sftpKeyPassphrase)) {
                $securePassphrase = ConvertTo-SecureString -String $sftpKeyPassphrase -AsPlainText -Force
                $sessionParams.KeyPassphrase = $securePassphrase
            }
            & $LocalWriteLog -Message ("  - SFTP.SessionManager: Attempting key-based authentication.") -Level "DEBUG"
        }
        elseif (-not [string]::IsNullOrWhiteSpace($sftpPassword)) {
            $securePassword = ConvertTo-SecureString -String $sftpPassword -AsPlainText -Force
            $sessionParams.Password = $securePassword
            & $LocalWriteLog -Message ("  - SFTP.SessionManager: Attempting password-based authentication.") -Level "DEBUG"
        }
        else {
            throw "No password secret or key file path secret provided for authentication."
        }

        $sftpSession = New-SSHSession @sessionParams
        if (-not $sftpSession) { throw "Failed to establish SSH session (New-SSHSession returned null)." }
        
        & $LocalWriteLog -Message ("    - SFTP.SessionManager: SSH Session established (ID: $($sftpSession.SessionId)).") -Level "SUCCESS"
        return @{ Success = $true; Session = $sftpSession }

    } catch {
        return @{ Success = $false; Session = $null; ErrorMessage = "Failed to create SFTP session. Error: $($_.Exception.Message)" }
    } finally {
        # SecureStrings must be disposed of after the cmdlet that uses them has finished.
        if ($securePassword) { $securePassword.Dispose() }
        if ($securePassphrase) { $securePassphrase.Dispose() }
    }
}

function Close-PoShBackupSftpSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Session,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    if ($null -eq $Session) { return }

    try {
        Remove-SSHSession -SessionId $Session.SessionId -ErrorAction SilentlyContinue
        & $Logger -Message ("  - SFTP.SessionManager: SSH Session ID $($Session.SessionId) closed.") -Level "DEBUG"
    } catch {
        # This is a cleanup operation, so we only log a warning if it fails.
        & $Logger -Message "  - SFTP.SessionManager: Error while closing SSH session ID $($Session.SessionId). It may have already been closed. Error: $($_.Exception.Message)" -Level "WARNING"
    }
}


Export-ModuleMember -Function New-PoShBackupSftpSession, Close-PoShBackupSftpSession
