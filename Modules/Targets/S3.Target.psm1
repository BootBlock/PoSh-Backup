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
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.1
    DateCreated:    17-Jun-2025
    LastModified:   17-Jun-2025
    Purpose:        S3-Compatible Target Provider for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    The 'AWS.Tools.S3' module must be installed (`Install-Module AWS.Tools.S3`).
                    PowerShell SecretManagement configured for storing credentials.
#>

#region --- Private Helper: Format Bytes ---
function Format-BytesInternal-S3 {
    param(
        [Parameter(Mandatory=$true)]
        [long]$Bytes
    )
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    else { return "$Bytes Bytes" }
}
#endregion

#region --- Private Helper: Get Secret from Vault ---
function Get-SecretFromVaultInternal-S3 {
    param(
        [string]$SecretName,
        [string]$VaultName, # Optional
        [scriptblock]$Logger,
        [string]$SecretPurposeForLog = "S3 Credential"
    )
    # PSScriptAnalyzer Appeasement: Use the Logger parameter
    & $Logger -Message "S3.Target/Get-SecretFromVaultInternal-S3: Logger active for secret '$SecretName'." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }

    if ([string]::IsNullOrWhiteSpace($SecretName)) {
        & $LocalWriteLog -Message ("  - GetSecret: SecretName not provided for {0}. Cannot retrieve." -f $SecretPurposeForLog) -Level "DEBUG"
        return $null
    }
    if (-not (Get-Command Get-Secret -ErrorAction SilentlyContinue)) {
        throw "PowerShell SecretManagement module (Get-Secret cmdlet) not found. Cannot retrieve '$SecretName' for $SecretPurposeForLog."
    }
    try {
        $getSecretParams = @{ Name = $SecretName; AsPlainText = $true; ErrorAction = 'Stop' }
        if (-not [string]::IsNullOrWhiteSpace($VaultName)) {
            $getSecretParams.Vault = $VaultName
        }
        $secretValue = Get-Secret @getSecretParams
        if ($null -ne $secretValue) {
            & $LocalWriteLog -Message ("  - GetSecret: Successfully retrieved secret '{0}' for {1}." -f $SecretName, $SecretPurposeForLog) -Level "DEBUG"
            return $secretValue
        }
    }
    catch {
        & $LocalWriteLog -Message ("[ERROR] GetSecret: Failed to retrieve secret '{0}' for {1}. Error: {2}" -f $SecretName, $SecretPurposeForLog, $_.Exception.Message) -Level "ERROR"
    }
    return $null
}
#endregion

#region --- Private Helper: Group Remote S3 Backup Instances ---
function Group-RemoteS3BackupInstancesInternal {
    param(
        [object[]]$S3ObjectList,
        [string]$ArchiveBaseName,
        [string]$PrimaryArchiveExtension,
        [scriptblock]$Logger
    )
    & $Logger -Message "S3.Target/Group-RemoteS3BackupInstancesInternal: Grouping $($S3ObjectList.Count) remote objects." -Level "DEBUG" -ErrorAction SilentlyContinue

    $instances = @{}
    $literalBase = [regex]::Escape($ArchiveBaseName)
    $literalExt = [regex]::Escape($PrimaryArchiveExtension)

    foreach ($s3Object in $S3ObjectList) {
        $fileName = Split-Path -Path $s3Object.Key -Leaf
        $instanceKey = $null
        $fileSortTime = $s3Object.LastModified

        $splitVolumePattern = "^($literalBase$literalExt)\.(\d{3,})$"
        $splitManifestPattern = "^($literalBase$literalExt)\.manifest\.[a-zA-Z0-9]+$"
        $singleFilePattern = "^($literalBase$literalExt)$"
        $sfxFilePattern = "^($literalBase\.[a-zA-Z0-9]+)$"
        $sfxManifestPattern = "^($literalBase\.[a-zA-Z0-9]+)\.manifest\.[a-zA-Z0-9]+$"

        if ($fileName -match $splitVolumePattern) { $instanceKey = $Matches[1] }
        elseif ($fileName -match $splitManifestPattern) { $instanceKey = $Matches[1] }
        elseif ($fileName -match $sfxManifestPattern) { $instanceKey = $Matches[1] }
        elseif ($fileName -match $singleFilePattern) { $instanceKey = $Matches[1] }
        elseif ($fileName -match $sfxFilePattern) { $instanceKey = $Matches[1] }

        if ($null -eq $instanceKey) { continue }

        if (-not $instances.ContainsKey($instanceKey)) {
            $instances[$instanceKey] = @{ SortTime = $fileSortTime; Files = [System.Collections.Generic.List[object]]::new() }
        }
        $instances[$instanceKey].Files.Add($s3Object)

        if ($fileSortTime -lt $instances[$instanceKey].SortTime) {
            $instances[$instanceKey].SortTime = $fileSortTime
        }
    }
    return $instances
}
#endregion

#region --- S3 Target Settings Validation Function ---
function Invoke-PoShBackupS3TargetSettingsValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$TargetSpecificSettings,
        [Parameter(Mandatory = $true)]
        [string]$TargetInstanceName,
        [Parameter(Mandatory = $true)]
        [ref]$ValidationMessagesListRef,
        [Parameter(Mandatory = $false)]
        [hashtable]$RemoteRetentionSettings,
        [Parameter(Mandatory = $false)]
        [scriptblock]$Logger
    )

    if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) {
        & $Logger -Message "S3.Target/Invoke-PoShBackupS3TargetSettingsValidation: Logger active. Validating settings for S3 Target '$TargetInstanceName'." -Level "DEBUG" -ErrorAction SilentlyContinue
    }

    $fullPathToSettings = "Configuration.BackupTargets.$TargetInstanceName.TargetSpecificSettings"
    $fullPathToRetentionSettings = "Configuration.BackupTargets.$TargetInstanceName.RemoteRetentionSettings"

    if (-not ($TargetSpecificSettings -is [hashtable])) {
        $ValidationMessagesListRef.Value.Add("S3 Target '$TargetInstanceName': 'TargetSpecificSettings' must be a Hashtable, but found type '$($TargetSpecificSettings.GetType().Name)'. Path: '$fullPathToSettings'.")
        return
    }

    foreach ($s3Key in @('ServiceUrl', 'Region', 'BucketName', 'AccessKeySecretName', 'SecretKeySecretName')) {
        if (-not $TargetSpecificSettings.ContainsKey($s3Key) -or -not ($TargetSpecificSettings.$s3Key -is [string]) -or [string]::IsNullOrWhiteSpace($TargetSpecificSettings.$s3Key)) {
            $ValidationMessagesListRef.Value.Add("S3 Target '$TargetInstanceName': '$s3Key' in 'TargetSpecificSettings' is missing, not a string, or empty. Path: '$fullPathToSettings.$s3Key'.")
        }
    }

    foreach ($s3OptionalBoolKey in @('CreateJobNameSubdirectory')) {
        if ($TargetSpecificSettings.ContainsKey($s3OptionalBoolKey) -and -not ($TargetSpecificSettings.$s3OptionalBoolKey -is [boolean])) {
            $ValidationMessagesListRef.Value.Add("S3 Target '$TargetInstanceName': '$s3OptionalBoolKey' in 'TargetSpecificSettings' must be a boolean (`$true` or `$false`) if defined. Path: '$fullPathToSettings.$s3OptionalBoolKey'.")
        }
    }

    if ($PSBoundParameters.ContainsKey('RemoteRetentionSettings') -and ($null -ne $RemoteRetentionSettings)) {
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
        [Parameter(Mandatory=$true)]
        [string]$LocalArchivePath,
        [Parameter(Mandatory=$true)]
        [hashtable]$TargetInstanceConfiguration,
        [Parameter(Mandatory=$true)]
        [string]$JobName,
        [Parameter(Mandatory=$true)]
        [string]$ArchiveFileName,
        [Parameter(Mandatory=$true)]
        [string]$ArchiveBaseName,
        [Parameter(Mandatory=$true)]
        [string]$ArchiveExtension,
        [Parameter(Mandatory=$true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory=$true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory=$true)]
        [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory=$true)]
        [long]$LocalArchiveSizeBytes,
        [Parameter(Mandatory=$true)]
        [datetime]$LocalArchiveCreationTimestamp,
        [Parameter(Mandatory=$true)]
        [bool]$PasswordInUse,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )

    if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) {
        & $Logger -Message "S3.Target/Invoke-PoShBackupTargetTransfer: Logger active for Job '$JobName'." -Level "DEBUG" -ErrorAction SilentlyContinue
        $contextMessage = "  - S3.Target Context (PSSA): EffectiveJobConfig.JobName='{0}', CreationTS='{1}', PwdInUse='{2}'." -f $EffectiveJobConfig.JobName, $LocalArchiveCreationTimestamp, $PasswordInUse
        & $Logger -Message $contextMessage -Level "DEBUG" -ErrorAction SilentlyContinue
    }

    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }
    $targetNameForLog = $TargetInstanceConfiguration._TargetInstanceName_
    & $LocalWriteLog -Message ("`n[INFO] S3 Target: Starting transfer for Job '{0}' to Target '{1}'." -f $JobName, $targetNameForLog) -Level "INFO"

    $result = @{
        Success          = $false; RemotePath       = $null; ErrorMessage     = $null
        TransferSize     = 0;      TransferDuration = New-TimeSpan
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
        & $LocalWriteLog -Message "SIMULATE: S3 Target '$targetNameForLog': Would upload '$LocalArchivePath' to Bucket '$($s3Settings.BucketName)' with Key '$remoteObjectKey'." -Level "SIMULATE"
        $result.Success = $true; $result.TransferSize = $LocalArchiveSizeBytes
        if ($TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings') -and $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -gt 0) {
            & $LocalWriteLog -Message ("SIMULATE: S3 Target '{0}': Would apply remote retention (KeepCount: {1}) in Bucket '{2}' with Prefix '{3}'." -f $targetNameForLog, $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount, $s3Settings.BucketName, $remoteKeyPrefix) -Level "SIMULATE"
        }
        $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed; return $result
    }

    if (-not $PSCmdlet.ShouldProcess($result.RemotePath, "Upload File to S3-Compatible Storage")) {
        $result.ErrorMessage = "S3 Target '$targetNameForLog': Upload to '$($result.RemotePath)' skipped by user."; & $LocalWriteLog -Message "[WARNING] $($result.ErrorMessage)" -Level "WARNING"
        $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed; return $result
    }

    $accessKey = $null; $secretKey = $null
    try {
        $accessKey = Get-SecretFromVaultInternal-S3 -SecretName $s3Settings.AccessKeySecretName -Logger $Logger -SecretPurposeForLog "S3 Access Key"
        $secretKey = Get-SecretFromVaultInternal-S3 -SecretName $s3Settings.SecretKeySecretName -Logger $Logger -SecretPurposeForLog "S3 Secret Key"
        if ([string]::IsNullOrWhiteSpace($accessKey) -or [string]::IsNullOrWhiteSpace($secretKey)) { throw "Failed to retrieve valid S3 credentials from SecretManagement." }

        $s3Config = New-Object Amazon.S3.AmazonS3Config
        $s3Config.ServiceURL = $s3Settings.ServiceUrl
        $s3Config.AuthenticationRegion = $s3Settings.Region
        $s3Config.ForcePathStyle = $true

        & $LocalWriteLog -Message ("  - S3 Target '{0}': Uploading file '{1}'..." -f $targetNameForLog, $ArchiveFileName) -Level "INFO"
        Write-S3Object -BucketName $s3Settings.BucketName -Key $remoteObjectKey -File $LocalArchivePath -AccessKey $accessKey -SecretKey $secretKey -S3ClientConfig $s3Config -ErrorAction Stop
        $result.Success = $true; $result.TransferSize = $LocalArchiveSizeBytes
        & $LocalWriteLog -Message ("    - S3 Target '{0}': File uploaded successfully." -f $targetNameForLog) -Level "SUCCESS"

        if ($TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings') -and $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -is [int] -and $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -gt 0) {
            $remoteKeepCount = $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount
            & $LocalWriteLog -Message ("  - S3 Target '{0}': Applying remote retention (KeepCount: {1}) in Bucket '{2}' with Prefix '{3}'." -f $targetNameForLog, $remoteKeepCount, $s3Settings.BucketName, $remoteKeyPrefix) -Level "INFO"
            
            $allRemoteObjects = Get-S3ObjectList -BucketName $s3Settings.BucketName -Prefix $remoteKeyPrefix -AccessKey $accessKey -SecretKey $secretKey -S3ClientConfig $s3Config
            $remoteInstances = Group-RemoteS3BackupInstancesInternal -S3ObjectList $allRemoteObjects -ArchiveBaseName $ArchiveBaseName -PrimaryArchiveExtension $ArchiveExtension -Logger $Logger
            
            if ($remoteInstances.Count -gt $remoteKeepCount) {
                $sortedInstances = $remoteInstances.GetEnumerator() | Sort-Object { $_.Value.SortTime } -Descending
                $instancesToDelete = $sortedInstances | Select-Object -Skip $remoteKeepCount
                & $LocalWriteLog -Message ("    - S3 Target '{0}': Found {1} remote instances. Will delete files for {2} older instance(s)." -f $targetNameForLog, $remoteInstances.Count, $instancesToDelete.Count) -Level "INFO"

                foreach ($instanceEntry in $instancesToDelete) {
                    & $LocalWriteLog -Message "      - S3 Target '{0}': Preparing to delete instance files for '$($instanceEntry.Name)'." -Level "WARNING"
                    foreach ($s3ObjectToDelete in $instanceEntry.Value.Files) {
                        if (-not $PSCmdlet.ShouldProcess($s3ObjectToDelete.Key, "Delete Remote S3 Object (Retention)")) {
                            & $LocalWriteLog -Message ("        - Deletion of '{0}' skipped by user." -f $s3ObjectToDelete.Key) -Level "WARNING"; continue
                        }
                        & $LocalWriteLog -Message ("        - Deleting: '{0}'" -f $s3ObjectToDelete.Key) -Level "WARNING"
                        try {
                            Remove-S3Object -BucketName $s3Settings.BucketName -Key $s3ObjectToDelete.Key -AccessKey $accessKey -SecretKey $secretKey -S3ClientConfig $s3Config -Force -ErrorAction Stop
                            & $LocalWriteLog "          - Status: DELETED" -Level "SUCCESS"
                        } catch {
                             $retentionErrorMsg = "Failed to delete remote S3 object '$($s3ObjectToDelete.Key)'. Error: $($_.Exception.Message)"
                             & $LocalWriteLog "          - Status: FAILED! $retentionErrorMsg" -Level "ERROR"
                             if ([string]::IsNullOrWhiteSpace($result.ErrorMessage)) { $result.ErrorMessage = $retentionErrorMsg } else { $result.ErrorMessage += "; $retentionErrorMsg" }
                        }
                    }
                }
            } else { & $LocalWriteLog ("    - S3 Target '{0}': No old instances to delete based on retention count {1}." -f $targetNameForLog, $remoteKeepCount) -Level "INFO" }
        }

    } catch {
        $result.ErrorMessage = "S3 Target '$targetNameForLog': Operation failed. Error: $($_.Exception.Message)"
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"; $result.Success = $false
    } finally {
        $accessKey = $null; $secretKey = $null; [System.GC]::Collect()
    }

    $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed
    & $LocalWriteLog -Message ("[INFO] S3 Target: Finished transfer attempt for Job '{0}' to Target '{1}'. Success: {2}." -f $JobName, $targetNameForLog, $result.Success) -Level "INFO"
    return $result
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupTargetTransfer, Invoke-PoShBackupS3TargetSettingsValidation
