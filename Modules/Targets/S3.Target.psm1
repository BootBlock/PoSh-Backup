# Modules\Targets\S3.Target.psm1
<#
.SYNOPSIS
    PoSh-Backup Target Provider for S3-Compatible Object Storage. This module now acts
    as a facade, orchestrating calls to specialised sub-modules.
.DESCRIPTION
    This module implements the PoSh-Backup target provider interface for S3-compatible
    destinations. It orchestrates the entire transfer and retention process by calling
    its sub-modules:
    - S3.CredentialHandler.psm1: Manages the secure retrieval of S3 credentials.
    - S3.TransferAgent.psm1: Handles the actual file upload using Write-S3Object.
    - S3.RetentionApplicator.psm1: Applies the remote retention policy.
    - S3.ConnectionTester.psm1: Contains the connectivity test logic.
    - S3.SettingsValidator.psm1: Contains the configuration validation logic.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.0.1 # BUGFIX: Correctly implement facade pattern to fix recursion error.
    DateCreated:    17-Jun-2025
    LastModified:   28-Jun-2025
    Purpose:        S3-Compatible Target Provider for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+, AWS.Tools.S3 module.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Targets
$s3SubModulePath = Join-Path -Path $PSScriptRoot -ChildPath "S3"
try {
    Import-Module -Name (Join-Path $s3SubModulePath "S3.CredentialHandler.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $s3SubModulePath "S3.TransferAgent.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $s3SubModulePath "S3.RetentionApplicator.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $s3SubModulePath "S3.ConnectionTester.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $s3SubModulePath "S3.SettingsValidator.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "S3.Target.psm1 (Facade) FATAL: Could not import a required sub-module. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- S3 Target Transfer Function (Orchestrator) ---
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
    & $LocalWriteLog -Message ("`n[INFO] S3 Target (Facade): Starting transfer for Job '{0}' to Target '{1}'." -f $JobName, $targetNameForLog) -Level "INFO"

    $result = @{ Success = $false; RemotePath = $null; ErrorMessage = $null; TransferSize = 0; TransferDuration = New-TimeSpan; TransferSizeFormatted = "N/A" }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        if (-not (Get-Module -Name AWS.Tools.S3 -ListAvailable)) { throw "AWS.Tools.S3 module is not installed." }
        Import-Module AWS.Tools.S3 -ErrorAction SilentlyContinue

        $s3Settings = $TargetInstanceConfiguration.TargetSpecificSettings
        $createJobSubDir = if ($s3Settings.ContainsKey('CreateJobNameSubdirectory')) { $s3Settings.CreateJobNameSubdirectory } else { $false }
        $remoteKeyPrefix = if ($createJobSubDir) { "$JobName/" } else { "" }
        $remoteObjectKey = $remoteKeyPrefix + $ArchiveFileName
        $result.RemotePath = "s3://$($s3Settings.BucketName)/$remoteObjectKey"

        if ($IsSimulateMode.IsPresent) {
            & $LocalWriteLog -Message "SIMULATE: Would upload '$ArchiveFileName' to '$($result.RemotePath)'." -Level "SIMULATE"
            if ($TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings')) { & $LocalWriteLog -Message "SIMULATE: Would apply retention policy." -Level "SIMULATE" }
            $result.Success = $true; $result.TransferSize = $LocalArchiveSizeBytes
            $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed; return $result
        }
        
        # 1. Get Credentials
        $credResult = Get-S3Credentials -TargetSpecificSettings $s3Settings -Logger $Logger
        if (-not $credResult.Success) { throw $credResult.ErrorMessage }
        
        $s3CommonParams = @{
            AccessKey = $credResult.AccessKey; SecretKey = $credResult.SecretKey
            Region = $s3Settings.Region; EndpointUrl = $s3Settings.ServiceUrl
            ForcePathStyle = $true; ErrorAction = 'Stop'
        }

        # 2. Upload File
        $uploadResult = Write-S3BackupObject -LocalSourcePath $LocalArchivePath -BucketName $s3Settings.BucketName `
            -ObjectKey $remoteObjectKey -S3CommonParameters $s3CommonParams -Logger $Logger -PSCmdletInstance $PSCmdlet
        if (-not $uploadResult.Success) { throw $uploadResult.ErrorMessage }
        
        $result.Success = $true; $result.TransferSize = $LocalArchiveSizeBytes
        
        # 3. Apply Remote Retention
        if ($TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings')) {
            Invoke-S3RetentionPolicy -RetentionSettings $TargetInstanceConfiguration.RemoteRetentionSettings `
                -BucketName $s3Settings.BucketName -RemoteKeyPrefix $remoteKeyPrefix `
                -S3CommonParameters $s3CommonParams -ArchiveBaseName $ArchiveBaseName -ArchiveExtension $ArchiveExtension `
                -ArchiveDateFormat $EffectiveJobConfig.JobArchiveDateFormat `
                -Logger $Logger -PSCmdletInstance $PSCmdlet
        }
    }
    catch {
        $result.ErrorMessage = "S3 Target '$targetNameForLog': Operation failed. Error: $($_.Exception.Message)"
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"; $result.Success = $false
    }
    finally {
        $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed
        $result.TransferSizeFormatted = Format-FileSize -Bytes $result.TransferSize
    }

    & $LocalWriteLog -Message ("[INFO] S3 Target (Facade): Finished transfer for Job '{0}' to Target '{1}'. Success: {2}." -f $JobName, $targetNameForLog, $result.Success) -Level "INFO"
    return $result
}
#endregion

# Export the main orchestrator function from this facade, AND the validation/testing functions from the sub-modules.
Export-ModuleMember -Function Invoke-PoShBackupTargetTransfer, Invoke-PoShBackupS3TargetSettingsValidation, Test-PoShBackupTargetConnectivity
