# Modules\Targets\WebDAV\WebDAV.TransferAgent.psm1
<#
.SYNOPSIS
    A sub-module for WebDAV.Target.psm1. Handles the file upload operation.
.DESCRIPTION
    This module provides the 'Start-PoShBackupWebDAVUpload' function. It is responsible for
    transferring a single local file to a remote WebDAV destination using an authenticated
    HTTP PUT request.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    28-Jun-2025
    LastModified:   28-Jun-2025
    Purpose:        To isolate the WebDAV file upload logic.
    Prerequisites:  PowerShell 5.1+.
#>

function Start-PoShBackupWebDAVUpload {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FullRemoteDestinationUrl,
        [Parameter(Mandatory = $true)]
        [string]$LocalSourcePath,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory = $true)]
        [int]$RequestTimeoutSec,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    & $Logger -Message "WebDAV.TransferAgent: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    if (-not $PSCmdletInstance.ShouldProcess($FullRemoteDestinationUrl, "Upload File via WebDAV (PUT)")) {
        return @{ Success = $false; ErrorMessage = "WebDAV upload to '$FullRemoteDestinationUrl' skipped by user." }
    }
    
    try {
        & $LocalWriteLog -Message "      - WebDAV.TransferAgent: Uploading file '$LocalSourcePath'..." -Level "DEBUG"
        Invoke-WebRequest -Uri $FullRemoteDestinationUrl -Method Put -InFile $LocalSourcePath -Credential $Credential -ContentType "application/octet-stream" -TimeoutSec $RequestTimeoutSec -ErrorAction Stop | Out-Null
        & $LocalWriteLog -Message "      - WebDAV.TransferAgent: Upload completed successfully." -Level "SUCCESS"
        return @{ Success = $true }
    }
    catch {
        $errorMessage = "Failed to upload file to '$FullRemoteDestinationUrl'. Error: $($_.Exception.Message)"
        if ($_.Exception.Response) { $errorMessage += " Status: $($_.Exception.Response.StatusCode) $($_.Exception.Response.StatusDescription)" }
        return @{ Success = $false; ErrorMessage = $errorMessage }
    }
}

Export-ModuleMember -Function Start-PoShBackupWebDAVUpload
