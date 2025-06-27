# Modules\Managers\PasswordManager\SecureStringFile.Provider.psm1
<#
.SYNOPSIS
    A provider sub-module for the PasswordManager facade. Handles password retrieval
    from an encrypted SecureString file.
.DESCRIPTION
    This module provides the 'Get-PoShBackupSecureStringFilePassword' function. It is
    responsible for reading and decrypting a password from a .clixml file that was
c   reated using Export-CliXml on a SecureString object.
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
    
    if (-not (Test-Path -LiteralPath $SecureStringPath -PathType Leaf)) {
        throw "SecureStringFile not found at the specified path: '$SecureStringPath'."
    }

    & $LocalWriteLog -Message "`n[INFO] Attempting to retrieve archive password from SecureStringFile: '$SecureStringPath'." -Level INFO

    try {
        $secureString = Import-Clixml -LiteralPath $SecureStringPath -ErrorAction Stop
        if ($secureString -is [System.Security.SecureString]) {
            & $LocalWriteLog -Message "  - Password successfully retrieved from SecureStringFile '$SecureStringPath'." -Level SUCCESS
            return ConvertFrom-PoShBackupSecureString -SecureString $secureString
        }
        else {
            throw "File '$SecureStringPath' did not contain a valid SecureString object. It contained type: $($secureString.GetType().FullName)"
        }
    }
    catch {
        throw "Failed to read or decrypt SecureStringFile '$SecureStringPath'. Ensure the file was created correctly and is accessible by the current user. Error: $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function Get-PoShBackupSecureStringFilePassword
