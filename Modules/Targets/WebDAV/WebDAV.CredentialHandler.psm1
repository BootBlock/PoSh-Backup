# Modules\Targets\WebDAV\WebDAV.CredentialHandler.psm1
<#
.SYNOPSIS
    A sub-module for WebDAV.Target.psm1. Handles credential retrieval.
.DESCRIPTION
    This module provides the 'Get-WebDAVCredential' function. It is responsible for
    securely retrieving the required PSCredential object from PowerShell SecretManagement
    for authenticating with the WebDAV server.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    28-Jun-2025
    LastModified:   28-Jun-2025
    Purpose:        To isolate WebDAV credential retrieval logic.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Targets\WebDAV
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "WebDAV.CredentialHandler.psm1 FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Get-WebDAVCredential {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCredential])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SecretName,
        [Parameter(Mandatory = $false)]
        [string]$VaultName,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )
    
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    if ([string]::IsNullOrWhiteSpace($SecretName)) {
        throw "Cannot retrieve WebDAV credential. The 'CredentialsSecretName' setting is empty."
    }

    $credential = Get-PoShBackupSecret -SecretName $SecretName -VaultName $VaultName -Logger $Logger -AsCredential
    
    if ($null -eq $credential) {
        throw "Failed to retrieve PSCredential from secret '$SecretName'. Check previous logs for details."
    }

    & $LocalWriteLog -Message "  - WebDAV.CredentialHandler: Successfully retrieved PSCredential from secret '$SecretName'." -Level "DEBUG"
    return $credential
}

Export-ModuleMember -Function Get-WebDAVCredential
