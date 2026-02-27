# Modules\Managers\PasswordManager\SecureStringFile.Provider.psm1
<#
.SYNOPSIS
    A provider sub-module for the PasswordManager facade. Handles password retrieval
    from an encrypted SecureString file.
.DESCRIPTION
    This module provides the 'Get-PoShBackupSecureStringFilePassword' function. It is
    responsible for reading and decrypting a password from a .clixml file that was
    created using Export-CliXml on a SecureString object.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    26-Jun-2025
    LastModified:   26-Jun-2025
    Purpose:        SecureStringFile password provider for the PasswordManager.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers\PasswordManager
try {
    Import-Module -Name (Join-Path $PSScriptRoot "Common.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "SecureStringFile.Provider.psm1 FATAL: Could not import a dependent module. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Get-PoShBackupSecureStringFilePassword {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SecureStringPath,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "PasswordManager/SecureStringFile.Provider: Logger active for path '$SecureStringPath'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    & $LocalWriteLog -Message "`n[INFO] Attempting to retrieve archive password from SecureStringFile: '$SecureStringPath'." -Level "INFO"

    if (-not (Test-Path -LiteralPath $SecureStringPath -PathType Leaf)) {
        $errorMessage = "SecureStringFile not found at the specified path: '$SecureStringPath'."
        $adviceMessage = "ADVICE: Please ensure the path is correct in your configuration and that the file has not been moved or deleted."
        & $LocalWriteLog -Message $errorMessage -Level "ERROR"
        & $LocalWriteLog -Message $adviceMessage -Level "ADVICE"
        throw $errorMessage
    }

    try {
        $secureString = Import-Clixml -LiteralPath $SecureStringPath -ErrorAction Stop
        if ($secureString -is [System.Security.SecureString]) {
            & $LocalWriteLog -Message "  - Password successfully retrieved from SecureStringFile '$SecureStringPath'." -Level "SUCCESS"
            return ConvertFrom-PoShBackupSecureString -SecureString $secureString
        }
        else {
            throw "File '$SecureStringPath' did not contain a valid SecureString object. It contained type: $($secureString.GetType().FullName)"
        }
    }
    catch {
        $errorMessage = "Failed to read or decrypt SecureStringFile '$SecureStringPath'. Error: $($_.Exception.Message)"
        $adviceMessage = "ADVICE: This usually happens if the file was created by a different user account or on a different computer. It can only be decrypted by the same user who created it on the same machine."
        & $LocalWriteLog -Message "[ERROR] $errorMessage" -Level "ERROR"
        & $LocalWriteLog -Message $adviceMessage -Level "ADVICE"
        throw $errorMessage
    }
}

Export-ModuleMember -Function Get-PoShBackupSecureStringFilePassword
