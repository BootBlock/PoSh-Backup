# Modules\Targets\GCS\GCS.Authenticator.psm1
<#
.SYNOPSIS
    A sub-module for GCS.Target.psm1. Manages service account authentication.
.DESCRIPTION
    This module provides functions to activate and revoke Google Cloud service account
    credentials using a key file. This encapsulates the authentication state management
    for a GCS transfer operation.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.2 # Added ADVICE logging for authentication failures.
    DateCreated:    02-Jul-2025
    LastModified:   02-Jul-2025
    Purpose:        To isolate the GCS authentication logic.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Targets\GCS
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "GCS.Authenticator.psm1 FATAL: Could not import a dependent module. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Invoke-GcsAuthentication {
<#
.SYNOPSIS
    Activates a Google Cloud service account using a key file from secrets.
.DESCRIPTION
    This function retrieves a path to a service account key file from PowerShell SecretManagement.
    If a valid path is found, it uses 'gcloud auth activate-service-account' to authenticate.
    If no key is specified, it assumes ambient gcloud authentication is being used.
.PARAMETER TargetSpecificSettings
    The 'TargetSpecificSettings' hashtable for the GCS target instance, which should contain
    the 'ServiceAccountKeyFileSecretName' key.
.PARAMETER Logger
    A mandatory scriptblock reference to the main 'Write-LogMessage' function.
.OUTPUTS
    A hashtable with 'Success' (boolean) and 'ShouldDeactivate' (boolean) keys.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$TargetSpecificSettings,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "GCS.Authenticator/Invoke-GcsAuthentication: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    if (-not $TargetSpecificSettings.ContainsKey('ServiceAccountKeyFileSecretName')) {
        & $LocalWriteLog -Message "  - GCS.Authenticator: No service account key specified. Relying on ambient gcloud authentication." -Level "DEBUG"
        return @{ Success = $true; ShouldDeactivate = $false }
    }

    $keyFileSecretName = $TargetSpecificSettings.ServiceAccountKeyFileSecretName
    if ([string]::IsNullOrWhiteSpace($keyFileSecretName)) {
        & $LocalWriteLog -Message "  - GCS.Authenticator: Service account key secret name is empty. Relying on ambient gcloud authentication." -Level "DEBUG"
        return @{ Success = $true; ShouldDeactivate = $false }
    }

    try {
        $keyFilePath = Get-PoShBackupSecret -SecretName $keyFileSecretName -Logger $Logger -AsPlainText -SecretPurposeForLog "GCS Service Account Key File Path"
        if ([string]::IsNullOrWhiteSpace($keyFilePath) -or -not (Test-Path -LiteralPath $keyFilePath -PathType Leaf)) {
            $advice = "ADVICE: Ensure the secret '$keyFileSecretName' exists and contains the correct, full path to your service account's JSON key file."
            & $Logger -Message $advice -Level "ADVICE"
            throw "GCS Service Account Key File not found at path retrieved from secret '$keyFileSecretName'."
        }

        & $LocalWriteLog -Message "  - GCS.Authenticator: Activating service account from key file '$keyFilePath'..." -Level "INFO"
        gcloud auth activate-service-account --key-file=$keyFilePath
        if ($LASTEXITCODE -ne 0) { throw "gcloud auth activate-service-account command failed." }

        return @{ Success = $true; ShouldDeactivate = $true }
    }
    catch {
        $errorMessage = "Failed to activate GCS service account. Error: $($_.Exception.Message)"
        $adviceMessage = "ADVICE: Check that the service account has the 'Storage Object Admin' role on the target bucket and that the key file is not corrupt."
        & $Logger -Message $adviceMessage -Level "ADVICE"
        return @{ Success = $false; ErrorMessage = $errorMessage }
    }
}

function Revoke-GcsAuthentication {
<#
.SYNOPSIS
    Revokes temporary service account credentials.
.DESCRIPTION
    This function calls 'gcloud auth revoke --all' to deactivate any temporary service
    account credentials that were activated for a transfer operation. This helps ensure
    the script leaves the authentication state as it found it.
.PARAMETER Logger
    A mandatory scriptblock reference to the main 'Write-LogMessage' function.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "GCS.Authenticator/Revoke-GcsAuthentication: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    try {
        & $LocalWriteLog -Message "  - GCS.Authenticator: Revoking temporary service account credentials." -Level "INFO"
        gcloud auth revoke --all
        if ($LASTEXITCODE -ne 0) {
            & $LocalWriteLog -Message "  - GCS.Authenticator: 'gcloud auth revoke' command finished with a non-zero exit code, which may be expected if no account was active." -Level "DEBUG"
        }
    }
    catch {
        # This is a cleanup step, so we only log a warning on failure.
        & $LocalWriteLog -Message "[WARNING] GCS.Authenticator: An error occurred while revoking GCS credentials. Manual cleanup may be required. Error: $($_.Exception.Message)" -Level "WARNING"
    }
}

Export-ModuleMember -Function Invoke-GcsAuthentication, Revoke-GcsAuthentication
