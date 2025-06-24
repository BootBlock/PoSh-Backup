# Modules\Targets\S3.Target.psm1
<#
.SYNOPSIS
    PoSh-Backup Target Provider for S3-Compatible Object Storage.
.DESCRIPTION
    This module implements the PoSh-Backup target provider interface for S3-compatible
    destinations like Amazon S3, MinIO, Backblaze B2, Cloudflare R2, etc.

    The core function, 'Invoke-PoShBackupTargetTransfer', will handle:
    - Retrieving S3 credentials from PowerShell SecretManagement.
    - Configuring the S3 client for the specified ServiceUrl and Region.
    - Uploading the backup archive to the target S3 bucket.
    - Applying a remote retention policy by listing and deleting older objects.

    The 'Invoke-PoShBackupS3TargetSettingsValidation' function validates the
    'TargetSpecificSettings' for S3 targets in the main configuration.
    A new function, 'Test-PoShBackupTargetConnectivity', validates the S3 connection and settings.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.5.0 # Refactored to use centralised Group-BackupInstancesByTimestamp utility.
    DateCreated:    17-Jun-2025
    LastModified:   24-Jun-2025
    Purpose:        S3-Compatible Target Provider for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    The 'AWS.Tools.S3' module must be installed (`Install-Module AWS.Tools.S3`).
                    PowerShell SecretManagement configured for storing credentials.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Targets
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utilities\RetentionUtils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "S3.Target.psm1 FATAL: Could not import dependent module Utils.psm1 or RetentionUtils.psm1. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- S3 Target Connectivity Test Function ---
function Test-PoShBackupTargetConnectivity {
    [CmdletBinding(SupportsShouldProcess = $true)]
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

    $accessKey = $null; $secretKey = $null
    try {
        $accessKey = Get-PoShBackupSecret -SecretName $TargetSpecificSettings.AccessKeySecretName -Logger $Logger -AsPlainText -SecretPurposeForLog "S3 Access Key"
        $secretKey = Get-PoShBackupSecret -SecretName $TargetSpecificSettings.SecretKeySecretName -Logger $Logger -AsPlainText -SecretPurposeForLog "S3 Secret Key"
        if ([string]::IsNullOrWhiteSpace($accessKey) -or [string]::IsNullOrWhiteSpace($secretKey)) { throw "Failed to retrieve valid S3 credentials from SecretManagement." }

        $s3CommonParams = @{
            AccessKey      = $accessKey
            SecretKey      = $secretKey
            Region         = $TargetSpecificSettings.Region
            EndpointUrl    = $TargetSpecificSettings.ServiceUrl
            ForcePathStyle = $true
            ErrorAction    = 'Stop'
        }
        
        $getBucketParams = $s3CommonParams.Clone()
        $getBucketParams.BucketName = $bucketName

        if (-not $PSCmdlet.ShouldProcess($bucketName, "Test S3 Bucket Accessibility")) {
            return @{ Success = $false; Message = "S3 bucket accessibility test skipped by user." }
        }

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
        $accessKey = $null; $secretKey = $null; [System.GC]::Collect()
    }
}
#endregion

#region --- S3 Target Settings Validation Function ---
function Invoke-PoShBackupS3TargetSettingsValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$TargetInstanceConfiguration, # CHANGED
        [Parameter(Mandatory = $true)]
        [string]$TargetInstanceName,
        [Parameter(Mandatory = $true)]
        [ref]$ValidationMessagesListRef,
        [Parameter(Mandatory = $false)]
        [scriptblock]$Logger
    )

    if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) {
        & $Logger -Message "S3.Target/Invoke-PoShBackupS3TargetSettingsValidation: Logger active. Validating settings for S3 Target '$TargetInstanceName'." -Level "DEBUG" -ErrorAction SilentlyContinue
    }

    # --- NEW: Extract settings from the main instance configuration ---
    $TargetSpecificSettings = $TargetInstanceConfiguration.TargetSpecificSettings
    $RemoteRetentionSettings = $TargetInstanceConfiguration.RemoteRetentionSettings
    # --- END NEW ---

    $fullPathToSettings = "Configuration.BackupTargets.$TargetInstanceName.TargetSpecificSettings"
    $fullPathToRetentionSettings = "Configuration.BackupTargets.$TargetInstanceName.RemoteRetentionSettings"

    if (-not ($TargetSpecificSettings -is [hashtable])) {
        $ValidationMessagesListRef.Value.Add("S3 Target '$TargetInstanceName': 'TargetSpecificSettings' must be a Hashtable, but found type '$($TargetSpecificSettings.GetType().Name)'. Path: '$fullPathToSettings'.")
        return
    }
    
    # ServiceUrl is optional for AWS S3, but required for MinIO etc.
    if ($TargetSpecificSettings.ContainsKey('ServiceUrl') -and -not ($TargetSpecificSettings.ServiceUrl -is [string])) {
        $ValidationMessagesListRef.Value.Add("S3 Target '$TargetInstanceName': 'ServiceUrl' in 'TargetSpecificSettings' must be a string if defined. Path: '$fullPathToSettings.ServiceUrl'.")
    }

    foreach ($s3Key in @('Region', 'BucketName', 'AccessKeySecretName', 'SecretKeySecretName')) {
        if (-not $TargetSpecificSettings.ContainsKey($s3Key) -or -not ($TargetSpecificSettings.$s3Key -is [string]) -or [string]::IsNullOrWhiteSpace($TargetSpecificSettings.$s3Key)) {
            $ValidationMessagesListRef.Value.Add("S3 Target '$TargetInstanceName': '$s3Key' in 'TargetSpecificSettings' is missing, not a string, or empty. Path: '$fullPathToSettings.$s3Key'.")
        }
    }

    foreach ($s3OptionalBoolKey in @('CreateJobNameSubdirectory')) {
        if ($TargetSpecificSettings.ContainsKey($s3OptionalBoolKey) -and -not ($TargetSpecificSettings.$s3OptionalBoolKey -is [boolean])) {
            $ValidationMessagesListRef.Value.Add("S3 Target '$TargetInstanceName': '$s3OptionalBoolKey' in 'TargetSpecificSettings' must be a boolean (`$true` or `$false`) if defined. Path: '$fullPathToSettings.$s3OptionalBoolKey'.")
        }
    }

    if ($null -ne $RemoteRetentionSettings) {
        if (-not ($RemoteRetentionSettings -is [hashtable])) {
            $ValidationMessagesListRef.Value.Add("S3 Target '$TargetInstanceName': 'RemoteRetentionSettings' must be a Hashtable if defined. Path: '$fullPathToRetentionSettings'.")
        }
        elseif ($RemoteRetentionSettings.ContainsKey('KeepCount')) {
            if (-not ($RemoteRetentionSettings.KeepCount -is [int]) -or $RemoteRetentionSettings.KeepCount -le 0) {
                $ValidationMessagesListRef.Value.Add("S3 Target '$TargetInstanceName': 'RemoteRetentionSettings.KeepCount' must be an integer greater than 0 if defined. Path: '$fullPathToRetentionSettings.KeepCount'.")
            }
        }
    }
}
#endregion

#region --- S3 Target Transfer Function ---
function Invoke-PoShBackupTargetTransfer {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalArchivePath,
        [Parameter(Mandatory = $true)]
        [hashtable]$TargetInstanceConfiguration,
        [Parameter(Mandatory = $true)]
        [string]$JobName,
        [Parameter(Mandatory = $true)]
        [string]$ArchiveFileName,
        [Parameter(Mandatory = $true)]
        [string]$ArchiveBaseName,
        [Parameter(Mandatory = $true)]
        [string]$ArchiveExtension,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $true)]
        [long]$LocalArchiveSizeBytes,
        [Parameter(Mandatory = $true)]
        [datetime]$LocalArchiveCreationTimestamp,
        [Parameter(Mandatory = $true)]
        [bool]$PasswordInUse,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )

    if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) {
        & $Logger -Message "S3.Target/Invoke-PoShBackupTargetTransfer: Logger active for Job '$JobName'." -Level "DEBUG" -ErrorAction SilentlyContinue
        # FIXED: Use the $JobName parameter instead of trying to get it from $EffectiveJobConfig
        $contextMessage = "  - S3.Target Context (PSSA): JobName='{0}', CreationTS='{1}', PwdInUse='{2}'." -f $JobName, $LocalArchiveCreationTimestamp, $PasswordInUse
        & $Logger -Message $contextMessage -Level "DEBUG" -ErrorAction SilentlyContinue
    }

    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }
    $targetNameForLog = $TargetInstanceConfiguration._TargetInstanceName_
    & $LocalWriteLog -Message ("`n[INFO] S3 Target: Starting transfer for Job '{0}' to Target '{1}'." -f $JobName, $targetNameForLog) -Level "INFO"

    $result = @{
        Success = $false; RemotePath = $null; ErrorMessage = $null
        TransferSize = 0; TransferDuration = New-TimeSpan; TransferSizeFormatted = "N/A"
    }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    if (-not (Get-Module -Name AWS.Tools.S3 -ListAvailable)) {
        $result.ErrorMessage = "S3 Target '$targetNameForLog': AWS.Tools.S3 module is not installed. Please install it using 'Install-Module AWS.Tools.S3'."
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"; $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed; return $result
    }
    Import-Module AWS.Tools.S3 -ErrorAction SilentlyContinue

    $s3Settings = $TargetInstanceConfiguration.TargetSpecificSettings
    $createJobSubDir = if ($s3Settings.ContainsKey('CreateJobNameSubdirectory')) { $s3Settings.CreateJobNameSubdirectory } else { $false }
    $remoteKeyPrefix = if ($createJobSubDir) { "$JobName/" } else { "" }
    $remoteObjectKey = $remoteKeyPrefix + $ArchiveFileName
    $result.RemotePath = "s3://$($s3Settings.BucketName)/$remoteObjectKey"

    if ($IsSimulateMode.IsPresent) {
        $simMessage = "SIMULATE: The archive file '$ArchiveFileName' would be uploaded to Bucket '$($s3Settings.BucketName)' with the S3 Key '$remoteObjectKey'."
        & $LocalWriteLog -Message $simMessage -Level "SIMULATE"
        if ($TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings') -and $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -gt 0) {
            & $LocalWriteLog -Message ("SIMULATE: After the upload, the retention policy (Keep: {0}) would be applied to objects under the prefix '{1}'." -f $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount, $remoteKeyPrefix) -Level "SIMULATE"
        }
        $result.Success = $true; $result.TransferSize = $LocalArchiveSizeBytes
        $result.TransferSizeFormatted = Format-FileSize -Bytes $result.TransferSize
        $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed; return $result
    }

    if (-not $PSCmdlet.ShouldProcess($result.RemotePath, "Upload File to S3-Compatible Storage")) {
        $result.ErrorMessage = "S3 Target '$targetNameForLog': Upload to '$($result.RemotePath)' skipped by user."; & $LocalWriteLog -Message "[WARNING] $($result.ErrorMessage)" -Level "WARNING"
        $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed; return $result
    }

    $accessKey = $null; $secretKey = $null
    try {
        $accessKey = Get-PoShBackupSecret -SecretName $s3Settings.AccessKeySecretName -Logger $Logger -AsPlainText -SecretPurposeForLog "S3 Access Key"
        $secretKey = Get-PoShBackupSecret -SecretName $s3Settings.SecretKeySecretName -Logger $Logger -AsPlainText -SecretPurposeForLog "S3 Secret Key"
        if ([string]::IsNullOrWhiteSpace($accessKey) -or [string]::IsNullOrWhiteSpace($secretKey)) { throw "Failed to retrieve valid S3 credentials from SecretManagement." }

        # Build parameter hashtable for all S3 cmdlets
        $s3CommonParams = @{
            AccessKey      = $accessKey
            SecretKey      = $secretKey
            Region         = $s3Settings.Region
            EndpointUrl    = $s3Settings.ServiceUrl
            ForcePathStyle = $true
            ErrorAction    = 'Stop'
        }

        & $LocalWriteLog -Message ("  - S3 Target '{0}': Uploading file '{1}'..." -f $targetNameForLog, $ArchiveFileName) -Level "INFO"
        $writeS3Params = $s3CommonParams.Clone()
        $writeS3Params.BucketName = $s3Settings.BucketName
        $writeS3Params.Key = $remoteObjectKey
        $writeS3Params.File = $LocalArchivePath
        Write-S3Object @writeS3Params
        
        $result.Success = $true; $result.TransferSize = $LocalArchiveSizeBytes
        $result.TransferSizeFormatted = Format-FileSize -Bytes $result.TransferSize
        & $LocalWriteLog -Message ("    - S3 Target '{0}': File uploaded successfully." -f $targetNameForLog) -Level "SUCCESS"

        if ($TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings') -and $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -is [int] -and $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -gt 0) {
            $remoteKeepCount = $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount
            & $LocalWriteLog -Message ("  - S3 Target '{0}': Applying remote retention (KeepCount: {1}) in Bucket '{2}' with Prefix '{3}'." -f $targetNameForLog, $remoteKeepCount, $s3Settings.BucketName, $remoteKeyPrefix) -Level "INFO"
            
            $getS3ListParams = $s3CommonParams.Clone()
            $getS3ListParams.BucketName = $s3Settings.BucketName
            $getS3ListParams.Prefix = $remoteKeyPrefix
            $allRemoteObjects = Get-S3ObjectV2 @getS3ListParams
            
            $fileObjectListForGrouping = $allRemoteObjects | ForEach-Object { 
                [PSCustomObject]@{ 
                    Name = (Split-Path -Path $_.Key -Leaf); 
                    SortTime = $_.LastModified; 
                    OriginalObject = $_ 
                }
            }

            $remoteInstances = Group-BackupInstancesByTimestamp -FileObjectList $fileObjectListForGrouping `
                -ArchiveBaseName $ArchiveBaseName `
                -ArchiveDateFormat $EffectiveJobConfig.JobArchiveDateFormat `
                -PrimaryArchiveExtension $ArchiveExtension `
                -Logger $Logger
            
            if ($remoteInstances.Count -gt $remoteKeepCount) {
                $sortedInstances = $remoteInstances.GetEnumerator() | Sort-Object { $_.Value.SortTime } -Descending
                $instancesToDelete = $sortedInstances | Select-Object -Skip $remoteKeepCount
                & $LocalWriteLog -Message ("    - S3 Target '{0}': Found {1} remote instances. Will delete files for {2} older instance(s)." -f $targetNameForLog, $remoteInstances.Count, $instancesToDelete.Count) -Level "INFO"

                foreach ($instanceEntry in $instancesToDelete) {
                    & $LocalWriteLog "      - S3 Target '{0}': Preparing to delete instance files for '$($instanceEntry.Name)'." -Level "WARNING"
                    foreach ($s3ObjectContainer in $instanceEntry.Value.Files) {
                        $s3ObjectToDelete = $s3ObjectContainer.OriginalObject
                        if (-not $PSCmdlet.ShouldProcess($s3ObjectToDelete.Key, "Delete Remote S3 Object (Retention)")) {
                            & $LocalWriteLog -Message ("        - Deletion of '{0}' skipped by user." -f $s3ObjectToDelete.Key) -Level "WARNING"; continue
                        }
                        & $LocalWriteLog -Message ("        - Deleting: '{0}'" -f $s3ObjectToDelete.Key) -Level "WARNING"
                        try {
                            $removeS3Params = $s3CommonParams.Clone()
                            $removeS3Params.BucketName = $s3Settings.BucketName
                            $removeS3Params.Key = $s3ObjectToDelete.Key
                            $removeS3Params.Force = $true
                            Remove-S3Object @removeS3Params
                            & $LocalWriteLog "          - Status: DELETED" -Level "SUCCESS"
                        }
                        catch {
                            $retentionErrorMsg = "Failed to delete remote S3 object '$($s3ObjectToDelete.Key)'. Error: $($_.Exception.Message)"
                            & $LocalWriteLog "          - Status: FAILED! $retentionErrorMsg" -Level "ERROR"
                            if ([string]::IsNullOrWhiteSpace($result.ErrorMessage)) { $result.ErrorMessage = $retentionErrorMsg } else { $result.ErrorMessage += "; $retentionErrorMsg" }
                        }
                    }
                }
            }
            else { & $LocalWriteLog ("    - S3 Target '{0}': No old instances to delete based on retention count {1} (Found: $($remoteInstances.Count))." -f $targetNameForLog, $remoteKeepCount) -Level "INFO" }
        }

    }
    catch {
        $result.ErrorMessage = "S3 Target '$targetNameForLog': Operation failed. Error: $($_.Exception.Message)"
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"; $result.Success = $false
    }
    finally {
        $accessKey = $null; $secretKey = $null; [System.GC]::Collect()
    }

    $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed
    & $LocalWriteLog -Message ("[INFO] S3 Target: Finished transfer attempt for Job '{0}' to Target '{1}'. Success: {2}." -f $JobName, $targetNameForLog, $result.Success) -Level "INFO"
    return $result
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupTargetTransfer, Invoke-PoShBackupS3TargetSettingsValidation, Test-PoShBackupTargetConnectivity
