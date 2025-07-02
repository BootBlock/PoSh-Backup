# Modules\Targets\GCS.Target.psm1
<#
.SYNOPSIS
    PoSh-Backup Target Provider for Google Cloud Storage (GCS). This module now acts
    as a facade, orchestrating calls to specialised sub-modules.
.DESCRIPTION
    This module implements the PoSh-Backup target provider interface for GCS destinations.
    It orchestrates the entire transfer and retention process by calling its sub-modules:
    - GCS.DependencyChecker.psm1: Verifies the gcloud CLI is installed.
    - GCS.Authenticator.psm1: Handles service account activation and revocation.
    - GCS.TransferAgent.psm1: Manages the actual file upload.
    - GCS.RetentionApplicator.psm1: Applies the remote retention policy.
    - GCS.SettingsValidator.psm1: Validates the target's configuration.
    - GCS.ConnectionTester.psm1: Tests connectivity to the GCS bucket.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.0.2 # Added ADVICE logging to catch block.
    DateCreated:    23-Jun-2025
    LastModified:   02-Jul-2025
    Purpose:        Google Cloud Storage Target Provider for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+, gcloud CLI.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Targets
$gcsSubModulePath = Join-Path -Path $PSScriptRoot -ChildPath "GCS"
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $gcsSubModulePath "GCS.DependencyChecker.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $gcsSubModulePath "GCS.Authenticator.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $gcsSubModulePath "GCS.TransferAgent.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $gcsSubModulePath "GCS.RetentionApplicator.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $gcsSubModulePath "GCS.SettingsValidator.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $gcsSubModulePath "GCS.ConnectionTester.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "GCS.Target.psm1 (Facade) FATAL: Could not import a required sub-module. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- GCS Target Transfer Function (Facade Orchestrator) ---
function Invoke-PoShBackupTargetTransfer {
<#
.SYNOPSIS
    Orchestrates the transfer of a backup archive to a Google Cloud Storage bucket.
.DESCRIPTION
    This function acts as a facade, coordinating a sequence of operations to securely
    and reliably transfer a backup file to GCS. It handles dependency checking,
    authentication, file upload, and remote retention policy application by calling
    specialised sub-modules for each task.
.PARAMETER LocalArchivePath
    The full path to the local backup archive file to be transferred.
.PARAMETER TargetInstanceConfiguration
    The complete configuration hashtable for the specific GCS target instance being used.
.PARAMETER JobName
    The name of the parent backup job, used for creating subdirectories if configured.
.PARAMETER ArchiveFileName
    The filename of the archive being transferred (e.g., 'MyJob [Date].7z').
.PARAMETER ArchiveBaseName
    The base name of the archive, without the date stamp or extension (e.g., 'MyJob').
.PARAMETER ArchiveExtension
    The primary extension of the archive (e.g., '.7z'), used for retention policy discovery.
.PARAMETER IsSimulateMode
    A switch indicating if the operation should be simulated without making actual changes.
.PARAMETER Logger
    A mandatory scriptblock reference to the main 'Write-LogMessage' function.
.PARAMETER EffectiveJobConfig
    The fully resolved configuration for the current job, used to retrieve settings like the date format.
.PARAMETER LocalArchiveSizeBytes
    The size of the local archive file in bytes, used for reporting.
.PARAMETER PSCmdlet
    A mandatory reference to the calling cmdlet's $PSCmdlet automatic variable.
.OUTPUTS
    A hashtable containing the final status and details of the transfer operation.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$LocalArchivePath,
        [Parameter(Mandatory = $true)] [hashtable]$TargetInstanceConfiguration,
        [Parameter(Mandatory = $true)] [string]$JobName,
        [Parameter(Mandatory = $true)] [string]$ArchiveFileName,
        [Parameter(Mandatory = $true)] [string]$ArchiveBaseName,
        [Parameter(Mandatory = $true)] [string]$ArchiveExtension,
        [Parameter(Mandatory = $true)] [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)] [scriptblock]$Logger,
        [Parameter(Mandatory = $true)] [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $true)] [long]$LocalArchiveSizeBytes,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCmdlet]$PSCmdlet
    )

    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }
    $targetNameForLog = $TargetInstanceConfiguration._TargetInstanceName_
    & $LocalWriteLog -Message ("`n[INFO] GCS Target (Facade): Starting transfer for Job '{0}' to Target '{1}'." -f $JobName, $targetNameForLog) -Level "INFO"

    $result = @{ Success = $false; RemotePath = $null; ErrorMessage = $null; TransferSize = 0; TransferDuration = New-TimeSpan; TransferSizeFormatted = "N/A" }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $authResult = @{ ShouldDeactivate = $false }

    try {
        $dependencyCheck = Test-GcsCliDependency -Logger $Logger
        if (-not $dependencyCheck.Success) { throw $dependencyCheck.ErrorMessage }

        $gcsSettings = $TargetInstanceConfiguration.TargetSpecificSettings
        $createJobSubDir = if ($gcsSettings.ContainsKey('CreateJobNameSubdirectory')) { $gcsSettings.CreateJobNameSubdirectory } else { $false }
        $remoteKeyPrefix = if ($createJobSubDir) { "$JobName/" } else { "" }
        $fullRemotePath = "gs://$($gcsSettings.BucketName)/$remoteKeyPrefix$ArchiveFileName"
        $result.RemotePath = $fullRemotePath

        if ($IsSimulateMode.IsPresent) {
            & $LocalWriteLog -Message "SIMULATE: Would upload file '$ArchiveFileName' to '$fullRemotePath' using gcloud." -Level "SIMULATE"
            if ($TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings')) { & $LocalWriteLog -Message "SIMULATE: Would apply retention policy." -Level "SIMULATE" }
            $result.Success = $true; $result.TransferSize = $LocalArchiveSizeBytes
            $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed; return $result
        }

        # 1. Authenticate
        $authResult = Invoke-GcsAuthentication -TargetSpecificSettings $gcsSettings -Logger $Logger
        if (-not $authResult.Success) { throw $authResult.ErrorMessage }

        # 2. Upload
        $uploadResult = Start-PoShBackupGcsUpload -LocalSourcePath $LocalArchivePath -FullRemoteDestinationPath $fullRemotePath -Logger $Logger -PSCmdletInstance $PSCmdlet
        if (-not $uploadResult.Success) { throw $uploadResult.ErrorMessage }

        $result.Success = $true; $result.TransferSize = $LocalArchiveSizeBytes

        # 3. Apply Remote Retention
        if ($TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings') -and $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -gt 0) {
            Invoke-GCSRetentionPolicy -RetentionSettings $TargetInstanceConfiguration.RemoteRetentionSettings `
                -BucketName $gcsSettings.BucketName `
                -RemoteKeyPrefix $remoteKeyPrefix `
                -ArchiveBaseName $ArchiveBaseName -ArchiveExtension $ArchiveExtension -ArchiveDateFormat $EffectiveJobConfig.JobArchiveDateFormat `
                -Logger $Logger -PSCmdletInstance $PSCmdlet
        }
    }
    catch {
        $result.ErrorMessage = "GCS Target '$targetNameForLog': Operation failed. Error: $($_.Exception.Message)"
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"; $result.Success = $false
        $adviceMessage = "ADVICE: Check previous log messages for specific errors from authentication, upload, or retention steps. Ensure the gcloud CLI is working correctly and the service account has appropriate permissions ('Storage Object Admin' is a good starting point for full functionality)."
        & $Logger -Message $adviceMessage -Level "ADVICE"
    }
    finally {
        # 4. Clean up authentication if needed
        if ($authResult.ShouldDeactivate) {
            Revoke-GcsAuthentication -Logger $Logger
        }
        $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed
        $result.TransferSizeFormatted = Format-FileSize -Bytes $result.TransferSize
    }

    & $LocalWriteLog -Message ("[INFO] GCS Target (Facade): Finished transfer for Job '{0}' to Target '{1}'. Success: {2}." -f $JobName, $targetNameForLog, $result.Success) -Level "INFO"
    return $result
}
#endregion

# Export the main transfer function from this facade, and the validation/testing functions from the sub-modules.
Export-ModuleMember -Function Invoke-PoShBackupTargetTransfer, Invoke-PoShBackupGCSTargetSettingsValidation, Test-PoShBackupTargetConnectivity
