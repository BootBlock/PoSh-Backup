# Modules\Managers\PasswordManager\Common.psm1
<#
.SYNOPSIS
    A common sub-module for the PasswordManager facade. Handles shared utilities.
.DESCRIPTION
    This module provides common helper functions used by multiple password provider sub-modules,
    specifically for securely converting a SecureString object to a plain text string.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    26-Jun-2025
    LastModified:   26-Jun-2025
    Purpose:        Shared utilities for password providers.
    Prerequisites:  PowerShell 5.1+.
#>

function ConvertFrom-PoShBackupSecureString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.SecureString]$SecureString
    )
    
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        $plainText = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        return $plainText
    }
    finally {
        # Ensure the unmanaged memory is zeroed out and freed, even if an error occurs.
        if ($bstr -ne [System.IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

Export-ModuleMember -Function ConvertFrom-PoShBackupSecureString
