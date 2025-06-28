# Modules\Targets\S3\S3.ConnectionTester.psm1
<#
.SYNOPSIS
    A sub-module for S3.Target.psm1. Handles connectivity testing.
.DESCRIPTION
    This module provides the 'Test-PoShBackupTargetConnectivity' function. It is
    responsible for verifying that a connection can be made to the configured
    S3-compatible endpoint and that the specified bucket is accessible with the
    provided credentials.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    28-Jun-2025
    LastModified:   28-Jun-2025
    Purpose:        To isolate the S3 target connectivity test logic.
    Prerequisites:  PowerShell 5.1+, AWS.Tools.S3 module.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Targets\S3
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "S3.CredentialHandler.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "S3.ConnectionTester.psm1 FATAL: Could not import a dependent module. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Test-PoShBackupTargetConnectivity {
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
    & $LocalWriteLog -Message "  - S3 Target: Testing connectivity to bucket '$bucketName'..." -Level "INFO"

    if (-not (Get-Module -Name AWS.Tools.S3 -ListAvailable)) {
        return @{ Success = $false; Message = "AWS.Tools.S3 module is not installed. Please install it using 'Install-Module AWS.Tools.S3'." }
    }
    Import-Module AWS.Tools.S3 -ErrorAction SilentlyContinue

    if (-not $PSCmdlet.ShouldProcess($bucketName, "Test S3 Bucket Accessibility")) {
        return @{ Success = $false; Message = "S3 bucket accessibility test skipped by user." }
    }

    $credResult = $null
    try {
        $credResult = Get-S3Credentials -TargetSpecificSettings $TargetSpecificSettings -Logger $Logger
        if (-not $credResult.Success) { throw $credResult.ErrorMessage }

        $s3CommonParams = @{
            AccessKey      = $credResult.AccessKey
            SecretKey      = $credResult.SecretKey
            Region         = $TargetSpecificSettings.Region
            EndpointUrl    = $TargetSpecificSettings.ServiceUrl
            ForcePathStyle = $true
            ErrorAction    = 'Stop'
        }

        $getBucketParams = $s3CommonParams.Clone()
        $getBucketParams.BucketName = $bucketName

        Get-S3Bucket @getBucketParams | Out-Null

        $successMessage = "Successfully connected to S3 endpoint and accessed bucket '$bucketName'."
        & $LocalWriteLog -Message "    - SUCCESS: $successMessage" -Level "SUCCESS"
        return @{ Success = $true; Message = $successMessage }
    }
    catch {
        $errorMessage = "S3 connection test failed. Error: $($_.Exception.Message)"
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $errorMessage += " Status Code: $($_.Exception.Response.StatusCode)."
        }
        & $LocalWriteLog -Message "    - FAILED: $errorMessage" -Level "ERROR"
        return @{ Success = $false; Message = $errorMessage }
    }
    finally {
        # Securely clear the credential variables
        if ($null -ne $credResult) {
            if ($credResult.ContainsKey('AccessKey')) { $credResult.AccessKey = $null }
            if ($credResult.ContainsKey('SecretKey')) { $credResult.SecretKey = $null }
        }
        [System.GC]::Collect()
    }
}

Export-ModuleMember -Function Test-PoShBackupTargetConnectivity
