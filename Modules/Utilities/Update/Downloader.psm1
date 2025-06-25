# Modules\Utilities\Update\Downloader.psm1
<#
.SYNOPSIS
    A sub-module for the Update facade. Handles the download of the update package.
.DESCRIPTION
    This module provides the 'Invoke-UpdatePackageDownload' function, which is responsible
    for downloading the PoSh-Backup update package from a specified URL into a temporary directory.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    25-Jun-2025
    LastModified:   25-Jun-2025
    Purpose:        To encapsulate the update package download logic.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Utilities\Update
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "Update\Downloader.psm1 FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- Exported Functions ---

function Invoke-UpdatePackageDownload {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DownloadUrl,
        [Parameter(Mandatory = $true)]
        [string]$TempDirectory,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "Update/Downloader: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue
    
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO")
        & $Logger -Message $Message -Level $Level
    }

    & $LocalWriteLog -Message "  - Update/Downloader: Preparing to download update..." -Level "DEBUG"

    $downloadFileName = Split-Path -Path $DownloadUrl -Leaf
    if ([string]::IsNullOrWhiteSpace($downloadFileName)) {
        $downloadFileName = "PoSh-Backup-Update-Package.zip"
        & $LocalWriteLog -Message "    - Could not determine filename from URL. Using default: '$downloadFileName'." -Level "WARNING"
    }

    $downloadedFilePath = Join-Path -Path $TempDirectory -ChildPath $downloadFileName
    & $LocalWriteLog -Message "  - Update/Downloader: Downloading from '$DownloadUrl' to '$downloadedFilePath'." -Level "INFO"

    try {
        # Use Write-Progress for better user feedback on large downloads
        Write-Progress -Activity "Downloading PoSh-Backup Update" -Status "Contacting server..." -PercentComplete 0
        
        $webRequestParams = @{
            Uri         = $DownloadUrl
            OutFile     = $downloadedFilePath
            TimeoutSec  = 300 # 5 minutes
            ErrorAction = 'Stop'
        }
        Invoke-WebRequest @webRequestParams
        
        Write-Progress -Activity "Downloading PoSh-Backup Update" -Status "Download complete." -Completed
        & $LocalWriteLog -Message "    - Update/Downloader: Download completed successfully." -Level "SUCCESS"

        return @{
            Success            = $true
            DownloadedFilePath = $downloadedFilePath
            ErrorMessage       = $null
        }
    }
    catch {
        Write-Progress -Activity "Downloading PoSh-Backup Update" -Status "Download FAILED." -Completed
        $errorMessage = "Failed to download update package. Error: $($_.Exception.Message)"
        & $LocalWriteLog -Message "[ERROR] Update/Downloader: $errorMessage" -Level "ERROR"
        return @{
            Success            = $false
            DownloadedFilePath = $null
            ErrorMessage       = $errorMessage
        }
    }
}

Export-ModuleMember -Function Invoke-UpdatePackageDownload

#endregion
