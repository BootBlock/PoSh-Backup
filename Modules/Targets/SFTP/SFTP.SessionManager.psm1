# Modules\Targets\SFTP\SFTP.SessionManager.psm1
<#
.SYNOPSIS
    A sub-module for SFTP.Target.psm1. Manages the SFTP session lifecycle.
.DESCRIPTION
    This module provides functions to establish and terminate SFTP sessions using Posh-SSH.
    It handles the retrieval of credentials from secrets and the logic for both password-based
    and key-based authentication, including key passphrases. It has been updated to use
    SecureString and PSCredential objects directly, avoiding plain text conversion.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Refactored to use SecureString/PSCredential directly, removing ConvertTo-SecureString.
    DateCreated:    28-Jun-2025
    LastModified:   04-Jul-2025
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

    $credentialToUse = $null

    try {
        if (-not $PSCmdletInstance.ShouldProcess($sftpServer, "Establish SFTP Session")) {
            return @{ Success = $false; Session = $null; ErrorMessage = "SFTP Session creation for '$sftpServer' skipped by user." }
        }

        $sessionParams = @{
            ComputerName = $sftpServer
            Port         = $sftpPort
            ErrorAction  = 'Stop'
        }
        if ($skipHostKeyCheck) { $sessionParams.AcceptKey = $true }

        $sftpKeyFilePath = Get-PoShBackupSecret -SecretName $TargetSpecificSettings.SFTPKeyFileSecretName -Logger $Logger -AsPlainText -SecretPurposeForLog "SFTP Key File Path"

        if (-not [string]::IsNullOrWhiteSpace($sftpKeyFilePath)) {
            # --- Key-Based Authentication ---
            if (-not (Test-Path -LiteralPath $sftpKeyFilePath -PathType Leaf)) { throw "SFTP Key File not found at path '$sftpKeyFilePath'." }
            $sessionParams.KeyFile = $sftpKeyFilePath

            # Key passphrase (the "password" part of the credential) is optional.
            $securePassphrase = Get-PoShBackupSecret -SecretName $TargetSpecificSettings.SFTPKeyFilePassphraseSecretName -Logger $Logger -SecretPurposeForLog "SFTP Key Passphrase"
            if ($null -eq $securePassphrase) {
                # If no passphrase secret is defined or found, create an empty SecureString.
                $securePassphrase = (New-Object System.Security.SecureString)
            }

            $credentialToUse = New-Object System.Management.Automation.PSCredential($sftpUser, $securePassphrase)
            & $LocalWriteLog -Message ("  - SFTP.SessionManager: Attempting key-based authentication for user '$sftpUser'.") -Level "DEBUG"
        }
        else {
            # --- Password-Based Authentication ---
            $securePassword = Get-PoShBackupSecret -SecretName $TargetSpecificSettings.SFTPPasswordSecretName -Logger $Logger -SecretPurposeForLog "SFTP Password"
            if ($null -eq $securePassword) {
                throw "No key file was specified, and no password secret ('$($TargetSpecificSettings.SFTPPasswordSecretName)') was found or retrieved for authentication."
            }
            $credentialToUse = New-Object System.Management.Automation.PSCredential($sftpUser, $securePassword)
            & $LocalWriteLog -Message ("  - SFTP.SessionManager: Attempting password-based authentication for user '$sftpUser'.") -Level "DEBUG"
        }

        $sessionParams.Add("Credential", $credentialToUse)
        $sftpSession = New-SSHSession @sessionParams
        if (-not $sftpSession) { throw "Failed to establish SSH session (New-SSHSession returned null)." }

        & $LocalWriteLog -Message ("    - SFTP.SessionManager: SSH Session established (ID: $($sftpSession.SessionId)).") -Level "SUCCESS"
        return @{ Success = $true; Session = $sftpSession }

    } catch {
        $errorMessage = $_.Exception.Message
        if ($errorMessage -match 'key exchange|host key') {
            $advice = "This often means the SSH host key is new or has changed. To fix, either:"
            $advice += "`n      1. (Recommended) Connect once manually in an interactive PowerShell session (`New-SSHSession -ComputerName $sftpServer -Credential(Get-Credential)) to accept and save the host key."
            $advice += "`n      2. (Less Secure) Set 'SkipHostKeyCheck = `$true' in this target's configuration in User.psd1 to bypass this security check."
            & $LocalWriteLog -Message "Failed to establish SFTP session due to a host key issue." -Level "ERROR"
            & $LocalWriteLog -Message $advice -Level "ADVICE"
            return @{ Success = $false; Session = $null; ErrorMessage = "SFTP host key validation failed. Please see log for advice." }
        }
        else {
            return @{ Success = $false; Session = $null; ErrorMessage = "Failed to create SFTP session. Error: $errorMessage" }
        }
    } finally {
        # SecureStrings inside PSCredential objects are managed by PowerShell's garbage collector.
        # Direct disposal is not required here as we are not handling the SecureString directly anymore.
        if ($null -ne $credentialToUse) { $credentialToUse = $null }
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
