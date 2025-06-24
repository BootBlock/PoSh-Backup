# Modules\Utilities\FileUtils.psm1
<#
.SYNOPSIS
    Provides utility functions for file-related operations required by PoSh-Backup.
.DESCRIPTION
    This module contains functions that perform operations on files, such as
    formatting file sizes for human readability and generating file checksums.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Added generic Format-FileSize function.
    DateCreated:    25-May-2025
    LastModified:   23-Jun-2025
    Purpose:        File operation utilities for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Requires a logger function to be passed to its functions.
#>

#region --- Get Archive Size Formatted ---
function Get-ArchiveSizeFormatted {
    [CmdletBinding()]
    param(
        [string]$PathToArchive,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )
    # Defensive PSSA appeasement line by directly calling the logger for this initial message
    & $Logger -Message "FileUtils/Get-ArchiveSizeFormatted: Logger parameter active for path '$PathToArchive'." -Level "DEBUG" -ErrorAction SilentlyContinue

    # Internal helper to use the passed-in logger consistently for other messages
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    $FormattedSize = "N/A"
    try {
        if (Test-Path -LiteralPath $PathToArchive -PathType Leaf) {
            $ArchiveFile = Get-Item -LiteralPath $PathToArchive -ErrorAction Stop
            # Delegate to the new generic function
            $FormattedSize = Format-FileSize -Bytes $ArchiveFile.Length
        }
        else {
            & $LocalWriteLog -Message "[DEBUG] FileUtils: File not found at '$PathToArchive' for size formatting." -Level "DEBUG"
            $FormattedSize = "File not found"
        }
    }
    catch {
        & $LocalWriteLog -Message "[WARNING] FileUtils: Error getting file size for '$PathToArchive': $($_.Exception.Message)" -Level "WARNING"
        $FormattedSize = "Error getting size"
    }
    return $FormattedSize
}
#endregion

#region --- Format File Size ---
function Format-FileSize {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [long]$Bytes
    )
    # This centralised function provides consistent file size formatting. [2, 8]
    if ($Bytes -lt 0) { return "0 Bytes" }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    else { return "$Bytes Bytes" }
}
#endregion

#region --- Get File Hash ---
function Get-PoshBackupFileHash {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Generates a cryptographic hash for a specified file using Get-FileHash.
    .DESCRIPTION
        This function calculates the hash of a file using the specified algorithm.
        It's a wrapper around Get-FileHash for consistent logging and error handling
        within the PoSh-Backup context.
    .PARAMETER FilePath
        The full path to the file for which to generate the hash.
    .PARAMETER Algorithm
        The hashing algorithm to use. Valid values are those supported by Get-FileHash
        (e.g., "SHA1", "SHA256", "SHA384", "SHA512", "MD5").
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function.
    .OUTPUTS
        System.String
        The hexadecimal string representation of the file hash, or $null if an error occurs.
    .EXAMPLE
        # $hash = Get-PoshBackupFileHash -FilePath "C:\archive.7z" -Algorithm "SHA256" -Logger ${function:Write-LogMessage}
        # if ($hash) { Write-Host "SHA256 Hash: $hash" }
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePath,
        [Parameter(Mandatory=$true)]
        [ValidateSet("SHA1", "SHA256", "SHA384", "SHA512", "MD5")]
        [string]$Algorithm,
        [Parameter(Mandatory=$true)]
        [scriptblock]$Logger
    )
    # Defensive PSSA appeasement line
    & $Logger -Message "FileUtils/Get-PoshBackupFileHash: Logger parameter active for path '$FilePath', Algorithm '$Algorithm'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        & $LocalWriteLog -Message "[ERROR] FileUtils: File not found at '$FilePath'. Cannot generate hash." -Level "ERROR"
        return $null
    }

    & $LocalWriteLog -Message "  - FileUtils: Generating $Algorithm hash for file '$FilePath'..." -Level "DEBUG"
    try {
        $fileHashObject = Get-FileHash -LiteralPath $FilePath -Algorithm $Algorithm -ErrorAction Stop
        if ($null -ne $fileHashObject -and -not [string]::IsNullOrWhiteSpace($fileHashObject.Hash)) {
            & $LocalWriteLog -Message "    - FileUtils: $Algorithm hash generated successfully: $($fileHashObject.Hash)." -Level "DEBUG"
            return $fileHashObject.Hash.ToUpperInvariant() # Return uppercase hash
        } else {
            & $LocalWriteLog -Message "[WARNING] FileUtils: Get-FileHash returned no hash or an empty hash for '$FilePath'." -Level "WARNING"
            return $null
        }
    }
    catch {
        & $LocalWriteLog -Message "[ERROR] FileUtils: Failed to generate $Algorithm hash for '$FilePath'. Error: $($_.Exception.Message)" -Level "ERROR"
        return $null
    }
}
#endregion

Export-ModuleMember -Function Get-ArchiveSizeFormatted, Get-PoshBackupFileHash, Format-FileSize
