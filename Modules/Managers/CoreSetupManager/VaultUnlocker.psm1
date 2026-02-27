# Modules\Managers\CoreSetupManager\VaultUnlocker.psm1
<#
.SYNOPSIS
    Handles unlocking the PowerShell SecretStore vault at script startup.
.DESCRIPTION
    This sub-module of CoreSetupManager provides a function to unlock the PowerShell
    SecretStore vault using a provided credential file. This is intended to be called
    at the beginning of a PoSh-Backup run to make secrets available for the session,
    eliminating the need for an external wrapper script in automated scenarios.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.1 # Added PSScriptAnalyzer suppression for VaultCredentialPath.
    DateCreated:    24-Jun-2025
    LastModified:   24-Jun-2025
    Purpose:        To centralise the vault unlocking logic.
    Prerequisites:  PowerShell 5.1+.
                    The 'Microsoft.PowerShell.SecretStore' module must be installed.
#>

function Invoke-PoShBackupVaultUnlock {
    [CmdletBinding()]
    param(
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'The parameter accepts a file path to an encrypted credential file, not a password itself.')]
        [Parameter(Mandatory = $true)]
        [string]$VaultCredentialPath,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "CoreSetupManager/VaultUnlocker/Invoke-PoShBackupVaultUnlock: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue

    if ([string]::IsNullOrWhiteSpace($VaultCredentialPath)) {
        & $Logger -Message "  - VaultUnlocker: VaultCredentialPath was empty. No unlock action will be taken." -Level "DEBUG"
        return
    }

    & $Logger -Message "`n[INFO] VaultUnlocker: Attempting to unlock PowerShell SecretStore vault..." -Level "INFO"
    & $Logger -Message "  - Using credential file: '$VaultCredentialPath'" -Level "INFO"

    if (-not (Test-Path -LiteralPath $VaultCredentialPath -PathType Leaf)) {
        throw "Vault credential file not found at the specified path: '$VaultCredentialPath'."
    }
    
    if (-not (Get-Module -Name Microsoft.PowerShell.SecretStore -ListAvailable)) {
        throw "The required 'Microsoft.PowerShell.SecretStore' module is not installed. Cannot unlock the vault."
    }
    Import-Module -Name Microsoft.PowerShell.SecretStore -ErrorAction Stop

    try {
        $credential = Import-CliXml -LiteralPath $VaultCredentialPath -ErrorAction Stop
        if ($null -eq $credential -or -not ($credential -is [System.Management.Automation.PSCredential])) {
            throw "The file '$VaultCredentialPath' did not contain a valid PSCredential object."
        }
        
        $vaultPassword = $credential.Password  # SecureString - avoids plaintext intermediate
        if ($null -eq $vaultPassword -or $vaultPassword.Length -eq 0) {
            throw "The credential object from '$VaultCredentialPath' does not contain a password."
        }

        # Check the vault status before attempting to unlock
        $vaultStatus = Get-SecretStoreConfiguration
        if ($vaultStatus.Authentication -eq 'Password' -and $vaultStatus.PasswordTimeout -gt 0) {
            & $Logger -Message "  - VaultUnlocker: Vault requires a password and has a timeout. Attempting unlock." -Level "DEBUG"
            Unlock-SecretStore -Password $vaultPassword -ErrorAction Stop
            & $Logger -Message "[SUCCESS] VaultUnlocker: PowerShell SecretStore vault successfully unlocked for this session." -Level "SUCCESS"
        }
        elseif ($vaultStatus.Authentication -ne 'Password') {
             & $Logger -Message "  - VaultUnlocker: Vault is not configured to use a password. No unlock action needed." -Level "INFO"
        }
        else { # No password timeout
             & $Logger -Message "  - VaultUnlocker: Vault is configured with a password but has no timeout (is already unlocked for the user session). No unlock action needed." -Level "INFO"
        }
    }
    catch {
        # Re-throw the exception with more context for the main script to handle.
        throw "Failed to unlock the PowerShell SecretStore vault. Error: $($_.Exception.Message)"
    }
    finally {
        # Clear the password variable from memory immediately after use.
        $vaultPassword = $null
        $credential = $null
    }
}

Export-ModuleMember -Function Invoke-PoShBackupVaultUnlock
