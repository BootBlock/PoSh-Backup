# Modules\Managers\PasswordManager\PlainText.Provider.psm1
<#
.SYNOPSIS
    A provider sub-module for the PasswordManager facade. Handles insecure retrieval
    of a plain text password from the configuration.
.DESCRIPTION
    This module provides the 'Get-PoShBackupPlainTextPassword' function. It is responsible
    for reading a plain text password directly from the 'ArchivePasswordPlainText' key
    in the job configuration. This method is highly discouraged for security reasons but
    is provided for specific use cases where other methods are not feasible.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    26-Jun-2025
    LastModified:   26-Jun-2025
    Purpose:        PlainText password provider for the PasswordManager.
    Prerequisites:  PowerShell 5.1+.
#>

function Get-PoShBackupPlainTextPassword {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PlainTextPassword,
        [Parameter(Mandatory = $true)]
        [string]$JobName,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "PasswordManager/PlainText.Provider: Logger active for job '$JobName'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    if ([string]::IsNullOrWhiteSpace($PlainTextPassword)) {
        throw "ArchivePasswordMethod is 'PlainText' but 'ArchivePasswordPlainText' is empty or not defined in the configuration for job '$JobName'."
    }
    
    & $LocalWriteLog -Message "[SECURITY WARNING] Using PLAIN TEXT password from configuration for job '$JobName'. This is INSECURE and NOT RECOMMENDED for production environments." -Level "WARNING"
    
    return $PlainTextPassword
}

Export-ModuleMember -Function Get-PoShBackupPlainTextPassword
