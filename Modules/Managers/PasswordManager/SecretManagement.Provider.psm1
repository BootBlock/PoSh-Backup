# Modules\Managers\PasswordManager\SecretManagement.Provider.psm1
<#
.SYNOPSIS
    A provider sub-module for the PasswordManager facade. Handles password retrieval
    from PowerShell SecretManagement.
.DESCRIPTION
    This module provides the 'Get-PoShBackupSecretManagementPassword' function. It is
    responsible for retrieving a secret by name from a specified (or default) vault and
    returning it as a plain text string. It handles both SecureString and plain string
    secrets.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    26-Jun-2025
    LastModified:   26-Jun-2025
    Purpose:        SecretManagement password provider for the PasswordManager.
    Prerequisites:  PowerShell 5.1+.
                    The 'Microsoft.PowerShell.SecretManagement' module must be installed.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers\PasswordManager
try {
    Import-Module -Name (Join-Path $PSScriptRoot "Common.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "SecretManagement.Provider.psm1 FATAL: Could not import a dependent module. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Get-PoShBackupSecretManagementPassword {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SecretName,
        [Parameter(Mandatory = $false)]
        [string]$VaultName,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "PasswordManager/SecretManagement.Provider: Logger active for secret '$SecretName'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    
    $vaultInfoString = if (-not [string]::IsNullOrWhiteSpace($VaultName)) { " from vault '$VaultName'" } else { " from default vault" }
    & $LocalWriteLog -Message "`n[INFO] Attempting to retrieve archive password from SecretManagement (Secret: '$SecretName'$vaultInfoString)." -Level "INFO"

    if (-not (Get-Command Get-Secret -ErrorAction SilentlyContinue)) {
        throw "The PowerShell SecretManagement module (Microsoft.PowerShell.SecretManagement) does not appear to be available or its cmdlets are not found. Please ensure it and a vault provider (e.g., Microsoft.PowerShell.SecretStore) are installed and configured."
    }

    try {
        $getSecretParams = @{ Name = $SecretName; ErrorAction = 'Stop' }
        if (-not [string]::IsNullOrWhiteSpace($VaultName)) {
            $getSecretParams.Vault = $VaultName
        }
        $secretObject = Get-Secret @getSecretParams

        if ($null -eq $secretObject) {
            throw "Secret '$SecretName'$vaultInfoString not found or could not be retrieved using Get-Secret (returned null)."
        }
        
        if ($secretObject.Secret -is [System.Security.SecureString]) {
            & $LocalWriteLog -Message "  - Password (SecureString) successfully retrieved from SecretManagement for '$SecretName'$vaultInfoString." -Level "SUCCESS"
            return ConvertFrom-PoShBackupSecureString -SecureString $secretObject.Secret
        }
        elseif ($secretObject.Secret -is [string]) {
            & $LocalWriteLog -Message "  - Password (plain text string) successfully retrieved from SecretManagement for '$SecretName'$vaultInfoString." -Level "SUCCESS"
            return $secretObject.Secret
        }
        else {
            throw "Secret '$SecretName'$vaultInfoString retrieved, but its content was not a SecureString or a plain String. Type found: $($secretObject.Secret.GetType().FullName)"
        }
    }
    catch {
        $userFriendlyError = "Failed to retrieve secret '$SecretName'$vaultInfoString. This can often happen if the Secret Vault is locked. Try running `Unlock-SecretStore` before executing the script."
        & $LocalWriteLog -Message "[ERROR] $userFriendlyError" -Level "ERROR"
        & $LocalWriteLog -Message "  - Underlying SecretManagement Error: $($_.Exception.Message)" -Level "DEBUG"
        throw $userFriendlyError
    }
}

Export-ModuleMember -Function Get-PoShBackupSecretManagementPassword
