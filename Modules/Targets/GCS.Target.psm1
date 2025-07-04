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
    Version:        2.1.3 # FIX: Added ShouldProcess call to Test-PoShBackupTargetConnectivity.
    DateCreated:    23-Jun-2025
    LastModified:   04-Jul-2025
    Purpose:        Google Cloud Storage Target Provider for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+, gcloud CLI.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Targets
$gcsSubModulePath = Join-Path -Path $PSScriptRoot -ChildPath "GCS"
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "GCS.Target.psm1 (Facade) FATAL: Could not import a required sub-module. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- Facade Functions ---

function Invoke-PoShBackupGCSTargetSettingsValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [hashtable]$TargetInstanceConfiguration,
        [Parameter(Mandatory = $true)] [string]$TargetInstanceName,
        [Parameter(Mandatory = $true)] [ref]$ValidationMessagesListRef,
        [Parameter(Mandatory = $false)] [scriptblock]$Logger
    )
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "GCS\GCS.SettingsValidator.psm1") -Force -ErrorAction Stop
        Invoke-PoShBackupGCSTargetSettingsValidation @PSBoundParameters
    } catch { throw "Could not load the GCS.SettingsValidator sub-module. Error: $($_.Exception.Message)" }
}

function Test-PoShBackupTargetConnectivity {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)] [hashtable]$TargetSpecificSettings,
        [Parameter(Mandatory = $true)] [scriptblock]$Logger,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCmdlet]$PSCmdlet
    )
    if (-not $PSCmdlet.ShouldProcess("GCS Target Connectivity (delegated)", "Test")) { return }
    try {
        Import-Module -Name (Join-Path $PSScriptRoot "GCS\GCS.ConnectionTester.psm1") -Force -ErrorAction Stop
        return Test-PoShBackupTargetConnectivity @PSBoundParameters
    } catch { throw "Could not load the GCS.ConnectionTester sub-module. Error: $($_.Exception.Message)" }
}

function Invoke-PoShBackupTargetTransfer {
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
        try {
            Import-Module -Name (Join-Path $gcsSubModulePath "GCS.DependencyChecker.psm1") -Force -ErrorAction Stop
            $dependencyCheck = Test-GcsCliDependency -Logger $Logger
            if (-not $dependencyCheck.Success) { throw $dependencyCheck.ErrorMessage }
        } catch { throw "Could not load or execute the GCS.DependencyChecker module. Error: $($_.Exception.Message)" }

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
        try {
            Import-Module -Name (Join-Path $gcsSubModulePath "GCS.Authenticator.psm1") -Force -ErrorAction Stop
            $authResult = Invoke-GcsAuthentication -TargetSpecificSettings $gcsSettings -Logger $Logger
            if (-not $authResult.Success) { throw $authResult.ErrorMessage }
        } catch { throw "Could not load or execute the GCS.Authenticator module. Error: $($_.Exception.Message)" }

        # 2. Upload
        try {
            Import-Module -Name (Join-Path $gcsSubModulePath "GCS.TransferAgent.psm1") -Force -ErrorAction Stop
            $uploadResult = Start-PoShBackupGcsUpload -LocalSourcePath $LocalArchivePath -FullRemoteDestinationPath $fullRemotePath -Logger $Logger -PSCmdletInstance $PSCmdlet
            if (-not $uploadResult.Success) { throw $uploadResult.ErrorMessage }
        } catch { throw "Could not load or execute the GCS.TransferAgent module. Error: $($_.Exception.Message)" }

        $result.Success = $true; $result.TransferSize = $LocalArchiveSizeBytes

        # 3. Apply Remote Retention
        if ($TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings') -and $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -gt 0) {
            try {
                Import-Module -Name (Join-Path $gcsSubModulePath "GCS.RetentionApplicator.psm1") -Force -ErrorAction Stop
                Invoke-GCSRetentionPolicy -RetentionSettings $TargetInstanceConfiguration.RemoteRetentionSettings `
                    -BucketName $gcsSettings.BucketName `
                    -RemoteKeyPrefix $remoteKeyPrefix `
                    -ArchiveBaseName $ArchiveBaseName -ArchiveExtension $ArchiveExtension -ArchiveDateFormat $EffectiveJobConfig.JobArchiveDateFormat `
                    -Logger $Logger -PSCmdletInstance $PSCmdlet
            } catch { & $LocalWriteLog -Message "[WARNING] GCS.Target (Facade): Could not load or execute the GCS.RetentionApplicator. Remote retention skipped. Error: $($_.Exception.Message)" -Level "WARNING" }
        }
    }
    catch {
        $result.ErrorMessage = "GCS Target '$targetNameForLog': Operation failed. Error: $($_.Exception.Message)"
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"; $result.Success = $false
        $adviceMessage = "ADVICE: Check previous log messages for specific errors from authentication, upload, or retention steps. Ensure the gcloud CLI is working correctly and the service account has appropriate permissions ('Storage Object Admin' is a good starting point for full functionality)."
        & $Logger -Message $adviceMessage -Level "ADVICE"
    }
    finally {
        if ($authResult.ShouldDeactivate) {
            try {
                Import-Module -Name (Join-Path $gcsSubModulePath "GCS.Authenticator.psm1") -Force -ErrorAction Stop
                Revoke-GcsAuthentication -Logger $Logger
            } catch { & $LocalWriteLog -Message "[WARNING] GCS.Target (Facade): Could not load GCS.Authenticator for cleanup. Manual cleanup of credentials may be required." -Level "WARNING" }
        }
        $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed
        $result.TransferSizeFormatted = Format-FileSize -Bytes $result.TransferSize
    }

    & $LocalWriteLog -Message ("[INFO] GCS Target (Facade): Finished transfer for Job '{0}' to Target '{1}'. Success: {2}." -f $JobName, $targetNameForLog, $result.Success) -Level "INFO"
    return $result
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupTargetTransfer, Invoke-PoShBackupGCSTargetSettingsValidation, Test-PoShBackupTargetConnectivity
