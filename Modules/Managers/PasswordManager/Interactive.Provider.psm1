# Modules\Managers\PasswordManager\Interactive.Provider.psm1
<#
.SYNOPSIS
    A provider sub-module for the PasswordManager facade. Handles interactive password retrieval.
.DESCRIPTION
    This module provides the 'Get-PoShBackupInteractivePassword' function, which is responsible
    for prompting the user for credentials via the standard PowerShell Get-Credential dialogue
    and returning the password part as a plain text string.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    26-Jun-2025
    LastModified:   26-Jun-2025
    Purpose:        Interactive password provider for the PasswordManager.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers\PasswordManager
try {
    Import-Module -Name (Join-Path $PSScriptRoot "Common.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "Interactive.Provider.psm1 FATAL: Could not import a dependent module. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Get-PoShBackupInteractivePassword {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$JobName,
        [Parameter(Mandatory = $true)]
        [string]$UserNameHint,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "PasswordManager/Interactive.Provider: Logger active for job '$JobName'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    & $LocalWriteLog -Message "`n[INFO] Password required for '$JobName'. Method: Interactive prompt." -Level "INFO"

    try {
        $cred = Get-Credential -UserName $UserNameHint -Message "Enter password for 7-Zip archive of job: '$JobName'"
        if ($null -ne $cred) {
            & $LocalWriteLog -Message "  - Credentials obtained interactively for job '$JobName'." -Level "SUCCESS"
            return ConvertFrom-PoShBackupSecureString -SecureString $cred.Password
        }
        else {
            # User cancelled Get-Credential prompt
            throw "Password entry via Get-Credential was cancelled by the user for job '$JobName'."
        }
    }
    catch {
        & $LocalWriteLog -Message "FATAL: $($_.Exception.Message)" -Level "ERROR"
        throw # Re-throw to halt the job
    }
}

Export-ModuleMember -Function Get-PoShBackupInteractivePassword
