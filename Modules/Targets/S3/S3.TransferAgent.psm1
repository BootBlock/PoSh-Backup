# Modules\Targets\S3\S3.TransferAgent.psm1
<#
.SYNOPSIS
    A sub-module for S3.Target.psm1. Handles the file upload operation.
.DESCRIPTION
    This module provides the 'Write-S3BackupObject' function. It is responsible for
    transferring a single local file to a remote S3-compatible destination using the
    AWS.Tools.S3 module.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    28-Jun-2025
    LastModified:   28-Jun-2025
    Purpose:        To isolate the S3 file upload logic.
    Prerequisites:  PowerShell 5.1+, AWS.Tools.S3 module.
#>

function Write-S3BackupObject {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalSourcePath,
        [Parameter(Mandatory = $true)]
        [string]$BucketName,
        [Parameter(Mandatory = $true)]
        [string]$ObjectKey,
        [Parameter(Mandatory = $true)]
        [hashtable]$S3CommonParameters, # Contains credentials, region, endpoint, etc.
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    & $Logger -Message "S3.TransferAgent: Logger active for Key '$ObjectKey'." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    $fullS3Path = "s3://$BucketName/$ObjectKey"
    if (-not $PSCmdletInstance.ShouldProcess($fullS3Path, "Upload File to S3")) {
        return @{ Success = $false; ErrorMessage = "S3 upload to '$fullS3Path' skipped by user." }
    }

    try {
        & $LocalWriteLog -Message "      - S3.TransferAgent: Uploading file '$LocalSourcePath'..." -Level "DEBUG"

        $writeS3Params = $S3CommonParameters.Clone()
        $writeS3Params.BucketName = $BucketName
        $writeS3Params.Key = $ObjectKey
        $writeS3Params.File = $LocalSourcePath

        Write-S3Object @writeS3Params

        # Write-S3Object does not return an object on success, it throws on failure.
        # If we get here, the upload was successful.
        & $LocalWriteLog -Message "      - S3.TransferAgent: Upload completed successfully." -Level "SUCCESS"
        return @{ Success = $true }
    }
    catch {
        $errorMessage = "Failed to upload file to '$fullS3Path'. Error: $($_.Exception.Message)"
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $errorMessage += " Status Code: $($_.Exception.Response.StatusCode)."
        }
        return @{ Success = $false; ErrorMessage = $errorMessage }
    }
}

Export-ModuleMember -Function Write-S3BackupObject
