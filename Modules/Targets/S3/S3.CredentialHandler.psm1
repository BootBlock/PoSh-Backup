# Modules\Targets\S3\S3.CredentialHandler.psm1
<#
.SYNOPSIS
    A sub-module for S3.Target.psm1. Handles S3 credential retrieval.
.DESCRIPTION
    This module provides the 'Get-S3Credentials' function. It is responsible for
    securely retrieving the S3 Access Key and Secret Key from PowerShell SecretManagement.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    28-Jun-2025
    LastModified:   28-Jun-2025
    Purpose:        To isolate S3 credential retrieval logic.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Targets\S3
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "S3.CredentialHandler.psm1 FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Get-S3Credentials {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$TargetSpecificSettings,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    $accessKey = $null
    $secretKey = $null

    try {
        & $LocalWriteLog -Message "  - S3.CredentialHandler: Retrieving S3 credentials from SecretManagement..." -Level "DEBUG"
        $accessKey = Get-PoShBackupSecret -SecretName $TargetSpecificSettings.AccessKeySecretName -Logger $Logger -AsPlainText -SecretPurposeForLog "S3 Access Key"
        $secretKey = Get-PoShBackupSecret -SecretName $TargetSpecificSettings.SecretKeySecretName -Logger $Logger -AsPlainText -SecretPurposeForLog "S3 Secret Key"

        if ([string]::IsNullOrWhiteSpace($accessKey) -or [string]::IsNullOrWhiteSpace($secretKey)) {
            throw "Failed to retrieve valid S3 Access Key or Secret Key from SecretManagement."
        }

        & $LocalWriteLog -Message "  - S3.CredentialHandler: Successfully retrieved S3 credentials." -Level "DEBUG"
        return @{
            Success   = $true
            AccessKey = $accessKey
            SecretKey = $secretKey
        }
    }
    catch {
        return @{
            Success      = $false
            ErrorMessage = "Failed to get S3 credentials. Error: $($_.Exception.Message)"
        }
    }
}

Export-ModuleMember -Function Get-S3Credentials
