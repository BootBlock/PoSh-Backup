# Modules\Utilities\Update\Verifier.psm1
<#
.SYNOPSIS
    A sub-module for the Update facade. Handles the verification of the downloaded update package.
.DESCRIPTION
    This module provides the 'Invoke-UpdatePackageVerification' function, which is responsible
    for calculating the SHA256 checksum of the downloaded update file and comparing it against
    the expected checksum provided in the remote version manifest. This ensures the downloaded
    file is not corrupt or tampered with.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    25-Jun-2025
    LastModified:   25-Jun-2025
    Purpose:        To encapsulate the update package verification logic.
    Prerequisites:  PowerShell 5.1+.
                    Depends on Utils.psm1 for Get-PoshBackupFileHash.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Utilities\Update
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "Update\Verifier.psm1 FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- Exported Functions ---

function Invoke-UpdatePackageVerification {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $false)] # Checksum is optional in the manifest
        [string]$ExpectedChecksum,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO")
        & $Logger -Message $Message -Level $Level
    }

    & $LocalWriteLog -Message "  - Update/Verifier: Beginning verification for file '$FilePath'." -Level "DEBUG"

    if ([string]::IsNullOrWhiteSpace($ExpectedChecksum)) {
        & $LocalWriteLog -Message "  - Update/Verifier: No SHA256Checksum was provided in the remote manifest. Skipping checksum verification." -Level "WARNING"
        Write-Host "WARNING: No checksum provided in manifest to verify download integrity." -ForegroundColor Yellow
        return @{
            Success      = $true
            ErrorMessage = "Checksum verification skipped as none was provided."
        }
    }

    & $LocalWriteLog -Message "  - Update/Verifier: Verifying checksum of downloaded package..." -Level "INFO"
    Write-Host "Verifying downloaded file integrity..." -ForegroundColor Cyan

    $cleanExpectedChecksum = $ExpectedChecksum.Trim().ToUpperInvariant()
    $actualChecksum = (Get-PoshBackupFileHash -FilePath $FilePath -Algorithm "SHA256" -Logger $Logger).Trim().ToUpperInvariant()

    if ($null -eq $actualChecksum) {
        $errorMessage = "Checksum verification failed because the hash could not be calculated for '$FilePath'."
        & $LocalWriteLog -Message "[ERROR] Update/Verifier: $errorMessage" -Level "ERROR"
        return @{
            Success      = $false
            ErrorMessage = $errorMessage
        }
    }
    
    if ($actualChecksum -ne $cleanExpectedChecksum) {
        $errorMessage = "Checksum mismatch! Expected: '$cleanExpectedChecksum', Actual: '$actualChecksum'. The downloaded file may be corrupted or tampered with."
        & $LocalWriteLog -Message "[ERROR] Update/Verifier: $errorMessage" -Level "ERROR"
        return @{
            Success      = $false
            ErrorMessage = $errorMessage
        }
    }
    
    & $LocalWriteLog -Message "    - Update/Verifier: Checksum VERIFIED." -Level "SUCCESS"
    Write-Host "File integrity verified." -ForegroundColor Green
    
    return @{
        Success      = $true
        ErrorMessage = $null
    }
}

Export-ModuleMember -Function Invoke-UpdatePackageVerification

#endregion
