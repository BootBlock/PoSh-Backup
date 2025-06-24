# Modules\Utilities\CredentialUtils.psm1
<#
.SYNOPSIS
    Provides a centralised utility function for securely retrieving secrets from
    PowerShell SecretManagement for use within PoSh-Backup.
.DESCRIPTION
    This module contains the 'Get-PoShBackupSecret' function, which acts as a
    standardised wrapper around 'Get-Secret'. It handles the retrieval of secrets
    by name, provides consistent logging, and can return the secret as either
    a plain text string (for API keys, URLs, passphrases) or as a PSCredential
    object, depending on the need.

    This utility is designed to be used by various target providers and other
    components that require access to sensitive information stored in a vault.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    23-Jun-2025
    LastModified:   23-Jun-2025
    Purpose:        Centralised secret retrieval utility for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    The 'Microsoft.PowerShell.SecretManagement' module and a configured
                    vault provider are required on the host system.
#>

function Get-PoShBackupSecret {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SecretName,
        [Parameter(Mandatory = $false)]
        [string]$VaultName,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $false)]
        [string]$SecretPurposeForLog = "Credential",
        [Parameter(Mandatory = $false)]
        [switch]$AsPlainText,
        [Parameter(Mandatory = $false)]
        [switch]$AsCredential
    )

    # PSSA Appeasement: Use the Logger parameter
    & $Logger -Message "CredentialUtils/Get-PoShBackupSecret: Logger active for secret '$SecretName', purpose '$SecretPurposeForLog'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }

    if ([string]::IsNullOrWhiteSpace($SecretName)) {
        & $LocalWriteLog -Message ("  - Get-PoShBackupSecret: SecretName not provided for {0}. Cannot retrieve." -f $SecretPurposeForLog) -Level "DEBUG"
        return $null
    }
    if (-not (Get-Command Get-Secret -ErrorAction SilentlyContinue)) {
        throw "PowerShell SecretManagement module (Get-Secret cmdlet) not found. Cannot retrieve '$SecretName' for $SecretPurposeForLog."
    }

    try {
        $getSecretParams = @{ Name = $SecretName; ErrorAction = 'Stop' }
        if (-not [string]::IsNullOrWhiteSpace($VaultName)) {
            $getSecretParams.Vault = $VaultName
        }
        # Get-Secret returns PSCredential as the object itself, but other types as a PSCustomObject with a .Secret property.
        $secretObject = Get-Secret @getSecretParams

        if ($null -ne $secretObject) {
            & $LocalWriteLog -Message ("  - Get-PoShBackupSecret: Successfully retrieved secret object '{0}' for {1}." -f $SecretName, $SecretPurposeForLog) -Level "DEBUG"

            if ($AsCredential) {
                if ($secretObject -is [System.Management.Automation.PSCredential]) {
                    return $secretObject
                } else {
                    throw "Retrieved secret '$SecretName' is not a PSCredential object as required."
                }
            }

            # If not asking for a credential, get the underlying secret value
            $secretValue = if ($secretObject -is [System.Management.Automation.PSCredential]) {
                $secretObject.Password # This is a SecureString
            } else {
                $secretObject.Secret
            }

            if ($AsPlainText) {
                if ($secretValue -is [System.Security.SecureString]) {
                    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretValue)
                    $plainText = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                    return $plainText
                }
                # If it's already a string, just return it.
                return $secretValue.ToString()
            }

            # Default behaviour if no format is specified: return the raw secret value
            return $secretValue
        }
    }
    catch {
        $userFriendlyError = "Failed to retrieve secret '{0}' for {1}. This can often happen if the Secret Vault is locked. Try running `Unlock-SecretStore` before executing the script." -f $SecretName, $SecretPurposeForLog
        & $LocalWriteLog -Message "[ERROR] $userFriendlyError" -Level "ERROR"
        & $LocalWriteLog -Message "  - Underlying SecretManagement Error: $($_.Exception.Message)" -Level "DEBUG"
    }
    return $null
}

Export-ModuleMember -Function Get-PoShBackupSecret
