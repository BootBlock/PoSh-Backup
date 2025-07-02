# Modules\Targets\GCS\GCS.TransferAgent.psm1
<#
.SYNOPSIS
    A sub-module for GCS.Target.psm1. Handles the file upload operation.
.DESCRIPTION
    This module provides the 'Start-PoShBackupGcsUpload' function. It is responsible for
    transferring a single local file to a remote GCS bucket using the 'gcloud storage cp' command.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.2 # Added ADVICE logging for upload failures.
    DateCreated:    02-Jul-2025
    LastModified:   02-Jul-2025
    Purpose:        To isolate the GCS file upload logic.
    Prerequisites:  PowerShell 5.1+, gcloud CLI.
#>

function Start-PoShBackupGcsUpload {
<#
.SYNOPSIS
    Uploads a single local file to a Google Cloud Storage bucket.
.DESCRIPTION
    This function uses the 'gcloud storage cp' command to upload a specified local file to a
    fully-qualified GCS path (e.g., gs://my-bucket/folder/file.zip). It respects PowerShell's
    -WhatIf preference via the SupportsShouldProcess attribute.
.PARAMETER LocalSourcePath
    The full path to the local file that will be uploaded.
.PARAMETER FullRemoteDestinationPath
    The full GCS path for the destination object, including the gs:// prefix.
.PARAMETER Logger
    A mandatory scriptblock reference to the main 'Write-LogMessage' function.
.PARAMETER PSCmdletInstance
    A mandatory reference to the calling cmdlet's $PSCmdlet automatic variable, required
    for ShouldProcess support.
.OUTPUTS
    A hashtable indicating the success or failure of the operation.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalSourcePath,
        [Parameter(Mandatory = $true)]
        [string]$FullRemoteDestinationPath, # e.g., "gs://bucket/path/file.7z"
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    & $Logger -Message "GCS.TransferAgent: Logger active for destination '$FullRemoteDestinationPath'." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    if (-not $PSCmdletInstance.ShouldProcess($FullRemoteDestinationPath, "Upload File to Google Cloud Storage")) {
        return @{ Success = $false; ErrorMessage = "GCS upload to '$FullRemoteDestinationPath' skipped by user." }
    }

    try {
        & $LocalWriteLog -Message "      - GCS.TransferAgent: Uploading file '$LocalSourcePath'..." -Level "DEBUG"

        # Use --quiet to suppress the progress bar for cleaner logs
        gcloud storage cp $LocalSourcePath $FullRemoteDestinationPath --quiet
        if ($LASTEXITCODE -ne 0) { throw "gcloud storage cp command failed with exit code $LASTEXITCODE." }

        & $LocalWriteLog -Message "      - GCS.TransferAgent: Upload completed successfully." -Level "SUCCESS"
        return @{ Success = $true }
    }
    catch {
        $errorMessage = "Failed to upload file to '$FullRemoteDestinationPath'. Error: $($_.Exception.Message)"
        $adviceMessage = "ADVICE: This is often a permissions issue. Ensure the authenticated account has the 'Storage Object Creator' or 'Storage Object Admin' role on the target bucket."
        & $Logger -Message $adviceMessage -Level "ADVICE"
        return @{ Success = $false; ErrorMessage = $errorMessage }
    }
}

Export-ModuleMember -Function Start-PoShBackupGcsUpload
