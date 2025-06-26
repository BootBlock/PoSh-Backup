# Modules\Managers\NotificationManager\Common.psm1
<#
.SYNOPSIS
    A common sub-module for the NotificationManager facade. Handles shared utilities like secret retrieval.
.DESCRIPTION
    This module provides common helper functions used by multiple notification provider sub-modules,
    specifically for retrieving credentials and other secrets from PowerShell SecretManagement.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    26-Jun-2025
    LastModified:   26-Jun-2025
    Purpose:        Shared utilities for notification providers.
    Prerequisites:  PowerShell 5.1+.
#>

function Get-PoShBackupNotificationSecret {
    [CmdletBinding()]
    param(
        [string]$SecretName,
        [string]$VaultName, # Optional
        [scriptblock]$Logger,
        [string]$SecretPurposeForLog = "Notification Credential"
    )

    # PSScriptAnalyzer Appeasement: Use the Logger parameter
    & $Logger -Message "NotificationManager/Common/Get-PoShBackupNotificationSecret: Logger active for secret '$SecretName', purpose '$SecretPurposeForLog'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }

    if ([string]::IsNullOrWhiteSpace($SecretName)) {
        & $LocalWriteLog -Message ("  - GetSecret: SecretName not provided for {0}. Cannot retrieve." -f $SecretPurposeForLog) -Level "DEBUG"
        return $null
    }
    if (-not (Get-Command Get-Secret -ErrorAction SilentlyContinue)) {
        throw "PowerShell SecretManagement module (Get-Secret cmdlet) not found. Cannot retrieve '$SecretName' for $SecretPurposeForLog."
    }
    try {
        $getSecretParams = @{ Name = $SecretName; ErrorAction = 'Stop' }
        if (-not [string]::IsNullOrWhiteSpace($VaultName)) { $getSecretParams.Vault = $VaultName }
        $secretObject = Get-Secret @getSecretParams
        if ($null -ne $secretObject) {
            & $LocalWriteLog -Message ("  - GetSecret: Successfully retrieved secret object '{0}' for {1}." -f $SecretName, $SecretPurposeForLog) -Level "DEBUG"
            # Return the entire secret object, let the caller decide how to handle it (PSCredential, string, etc.)
            return $secretObject
        }
    }
    catch {
        & $LocalWriteLog -Message ("[ERROR] GetSecret: Failed to retrieve secret '{0}' for {1}. Error: {2}" -f $SecretName, $SecretPurposeForLog, $_.Exception.Message) -Level "ERROR"
    }
    return $null
}

Export-ModuleMember -Function Get-PoShBackupNotificationSecret
