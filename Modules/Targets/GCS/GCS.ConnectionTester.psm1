# Modules\Targets\GCS\GCS.ConnectionTester.psm1
<#
.SYNOPSIS
    A sub-module for GCS.Target.psm1. Handles connectivity testing.
.DESCRIPTION
    This module provides the 'Test-PoShBackupTargetConnectivity' function. It is
    responsible for verifying that a connection can be made to the configured
    GCS bucket and that it is accessible with the current or configured credentials.
    It uses 'gcloud storage ls' to perform a non-destructive read test.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.1 # Added comment-based help and ADVICE logging.
    DateCreated:    02-Jul-2025
    LastModified:   02-Jul-2025
    Purpose:        To isolate the GCS target connectivity test logic.
    Prerequisites:  PowerShell 5.1+, gcloud CLI.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Targets\GCS
try {
    Import-Module -Name (Join-Path $PSScriptRoot "GCS.DependencyChecker.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "GCS.ConnectionTester.psm1 FATAL: Could not import a dependent module. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Test-PoShBackupTargetConnectivity {
<#
.SYNOPSIS
    Tests connectivity to a configured Google Cloud Storage bucket.
.DESCRIPTION
    This function checks for the gcloud CLI, then attempts to list the contents of the
    specified GCS bucket to verify connectivity and permissions.
.PARAMETER TargetSpecificSettings
    The 'TargetSpecificSettings' hashtable for the GCS target instance, which must contain
    the 'BucketName' key.
.PARAMETER Logger
    A mandatory scriptblock reference to the main 'Write-LogMessage' function.
.PARAMETER PSCmdlet
    A mandatory reference to the calling cmdlet's $PSCmdlet automatic variable, required
    for ShouldProcess support.
.OUTPUTS
    A hashtable indicating the success or failure of the test, with a descriptive message.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$TargetSpecificSettings,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )
    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }

    $bucketName = $TargetSpecificSettings.BucketName
    & $LocalWriteLog -Message "  - GCS Target: Testing connectivity to bucket 'gs://$bucketName'..." -Level "INFO"

    $dependencyCheck = Test-GcsCliDependency -Logger $Logger
    if (-not $dependencyCheck.Success) { return $dependencyCheck }

    if (-not $PSCmdlet.ShouldProcess("gs://$bucketName", "Test GCS Bucket Accessibility (gcloud storage ls)")) {
        return @{ Success = $false; Message = "GCS bucket accessibility test skipped by user." }
    }

    if ($TargetSpecificSettings.ContainsKey('ServiceAccountKeyFileSecretName')) {
        $keyFileSecretName = $TargetSpecificSettings.ServiceAccountKeyFileSecretName
        if (-not [string]::IsNullOrWhiteSpace($keyFileSecretName)) {
            $keyFilePath = Get-PoShBackupSecret -SecretName $keyFileSecretName -Logger $Logger -AsPlainText -SecretPurposeForLog "GCS Service Account Key File Path"
            if (-not [string]::IsNullOrWhiteSpace($keyFilePath) -and (Test-Path -LiteralPath $keyFilePath -PathType Leaf)) {
                & $LocalWriteLog -Message "  - GCS Target: Service account key file found. The test will rely on its validity if used for authentication." -Level "DEBUG"
            } else {
                 return @{ Success = $false; Message = "Service Account Key File not found at path retrieved from secret '$keyFileSecretName'." }
            }
        }
    }

    try {
        gcloud storage ls "gs://$bucketName" --limit 1 | Out-Null
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) { throw "gcloud command failed with exit code $exitCode."}

        $successMessage = "Successfully connected and listed content for bucket 'gs://$bucketName'."
        & $LocalWriteLog -Message "    - SUCCESS: $successMessage" -Level "SUCCESS"
        return @{ Success = $true; Message = $successMessage }
    }
    catch {
        $errorMessage = "GCS connection test failed. Error: $($_.Exception.Message)"
        $adviceMessage = "ADVICE: Ensure you are authenticated ('gcloud auth login', 'gcloud auth application-default login') or the specified service account key is valid and has the 'Storage Object Viewer' role on the project/bucket."
        & $LocalWriteLog -Message "    - FAILED: $errorMessage" -Level "ERROR"
        & $Logger -Message "      $adviceMessage" -Level "ADVICE"
        return @{ Success = $false; Message = $errorMessage }
    }
}

Export-ModuleMember -Function Test-PoShBackupTargetConnectivity
