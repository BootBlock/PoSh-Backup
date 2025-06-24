# Modules\Targets\AzureBlob.Target.psm1
<#
.SYNOPSIS
    PoSh-Backup Target Provider for Microsoft Azure Blob Storage.
.DESCRIPTION
    This module implements the PoSh-Backup target provider interface for Azure Blob Storage.
    The core function, 'Invoke-PoShBackupTargetTransfer', is called by the main PoSh-Backup
    operations module when a backup job is configured to use a target of type "AzureBlob".

    The provider performs the following actions:
    - Checks for the presence of the 'Az.Storage' module.
    - Retrieves the storage account connection string from PowerShell SecretManagement.
    - Creates an Azure Storage Context for authentication.
    - Ensures the blob container exists.
    - Uploads the local backup archive file to the specified container.
    - If 'RemoteRetentionSettings' are defined, it applies a count-based retention policy
      by listing and deleting older backup instances (groups of blobs).
    - Supports simulation mode for all Azure operations.
    - Returns a detailed status hashtable for each file transfer attempt.

    A function, 'Invoke-PoShBackupAzureBlobTargetSettingsValidation', validates the target configuration.
    A function, 'Test-PoShBackupTargetConnectivity', validates the connection and container access.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    23-Jun-2025
    LastModified:   23-Jun-2025
    Purpose:        Azure Blob Storage Target Provider for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    The 'Az.Storage' module must be installed (`Install-Module Az.Storage -Scope CurrentUser`).
                    PowerShell SecretManagement configured for storing the connection string.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Targets
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "AzureBlob.Target.psm1 FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- Private Helper: Group Remote Azure Blob Instances ---
function Group-RemoteAzureBlobBackupInstancesInternal {
    param(
        [object[]]$AzureBlobObjectList,
        [string]$ArchiveBaseName,
        [string]$PrimaryArchiveExtension,
        [scriptblock]$Logger
    )
    & $Logger -Message "AzureBlob.Target/Group-RemoteAzureBlobBackupInstancesInternal: Grouping $($AzureBlobObjectList.Count) remote objects." -Level "DEBUG" -ErrorAction SilentlyContinue

    $instances = @{}
    $literalBase = [regex]::Escape($ArchiveBaseName)
    $literalExt = [regex]::Escape($PrimaryArchiveExtension)

    foreach ($blobObject in $AzureBlobObjectList) {
        $fileName = $blobObject.Name # For blobs, the 'Name' includes the full path/prefix
        if ($fileName.Contains('/')) {
            $fileName = Split-Path -Path $fileName -Leaf
        }

        $instanceKey = $null
        $fileSortTime = $blobObject.LastModified.DateTime

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
        $instances[$instanceKey].Files.Add($blobObject)

        if ($fileSortTime -lt $instances[$instanceKey].SortTime) {
            $instances[$instanceKey].SortTime = $fileSortTime
        }
    }
    return $instances
}
#endregion

#region --- Azure Blob Target Connectivity Test Function ---
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

    $containerName = $TargetSpecificSettings.ContainerName
    $storageAccountName = $TargetSpecificSettings.StorageAccountName
    & $LocalWriteLog -Message "  - Azure Blob Target: Testing connectivity to Storage Account '$storageAccountName', Container '$containerName'..." -Level "INFO"

    if (-not (Get-Module -Name Az.Storage -ListAvailable)) {
        return @{ Success = $false; Message = "Az.Storage module is not installed. Please install it using 'Install-Module Az.Storage'." }
    }
    Import-Module Az.Storage -ErrorAction SilentlyContinue

    try {
        $connectionString = Get-PoShBackupSecret -SecretName $TargetSpecificSettings.ConnectionStringSecretName -Logger $Logger -AsPlainText -SecretPurposeForLog "Azure Storage Connection String"
        if ([string]::IsNullOrWhiteSpace($connectionString)) { throw "Failed to retrieve a valid Connection String from SecretManagement." }

        $storageContext = New-AzStorageContext -ConnectionString $connectionString -ErrorAction Stop

        if (-not $PSCmdlet.ShouldProcess("Container: $containerName", "Test Azure Storage Container Accessibility")) {
            return @{ Success = $false; Message = "Azure container accessibility test skipped by user." }
        }

        $container = Get-AzStorageContainer -Name $containerName -Context $storageContext -ErrorAction Stop
        if ($null -ne $container) {
            $successMessage = "Successfully connected to storage account and found container '$containerName'."
            & $LocalWriteLog -Message "    - SUCCESS: $successMessage" -Level "SUCCESS"
            return @{ Success = $true; Message = $successMessage }
        }
        else {
            # This case is unlikely as Get-AzStorageContainer with -ErrorAction Stop would throw if not found.
            throw "Container '$containerName' not found."
        }
    }
    catch {
        $errorMessage = "Azure Blob Storage connection test failed. Error: $($_.Exception.Message)"
        & $LocalWriteLog -Message "    - FAILED: $errorMessage" -Level "ERROR"
        return @{ Success = $false; Message = $errorMessage }
    }
}
#endregion

#region --- Azure Blob Target Settings Validation Function ---
function Invoke-PoShBackupAzureBlobTargetSettingsValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$TargetInstanceConfiguration,
        [Parameter(Mandatory = $true)]
        [string]$TargetInstanceName,
        [Parameter(Mandatory = $true)]
        [ref]$ValidationMessagesListRef,
        [Parameter(Mandatory = $false)]
        [scriptblock]$Logger
    )

    if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) {
        & $Logger -Message "AzureBlob.Target/Invoke-PoShBackupAzureBlobTargetSettingsValidation: Logger active. Validating settings for Azure Blob Target '$TargetInstanceName'." -Level "DEBUG" -ErrorAction SilentlyContinue
    }

    $TargetSpecificSettings = $TargetInstanceConfiguration.TargetSpecificSettings
    $RemoteRetentionSettings = $TargetInstanceConfiguration.RemoteRetentionSettings

    if (-not ($TargetSpecificSettings -is [hashtable])) {
        $ValidationMessagesListRef.Value.Add("AzureBlob Target '$TargetInstanceName': 'TargetSpecificSettings' must be a Hashtable.")
        return
    }

    foreach ($key in @('StorageAccountName', 'ContainerName', 'AuthenticationMethod', 'ConnectionStringSecretName')) {
        if (-not $TargetSpecificSettings.ContainsKey($key) -or -not ($TargetSpecificSettings.$key -is [string]) -or [string]::IsNullOrWhiteSpace($TargetSpecificSettings.$key)) {
            $ValidationMessagesListRef.Value.Add("AzureBlob Target '$TargetInstanceName': '$key' in 'TargetSpecificSettings' is missing, not a string, or empty.")
        }
    }
    if ($TargetSpecificSettings.ContainsKey('AuthenticationMethod') -and $TargetSpecificSettings.AuthenticationMethod -ne 'ConnectionString') {
        $ValidationMessagesListRef.Value.Add("AzureBlob Target '$TargetInstanceName': Currently, only 'ConnectionString' is supported for 'AuthenticationMethod'.")
    }
    if ($TargetSpecificSettings.ContainsKey('CreateJobNameSubdirectory') -and -not ($TargetSpecificSettings.CreateJobNameSubdirectory -is [boolean])) {
        $ValidationMessagesListRef.Value.Add("AzureBlob Target '$TargetInstanceName': 'CreateJobNameSubdirectory' must be a boolean (`$true` or `$false`) if defined.")
    }

    if ($null -ne $RemoteRetentionSettings) {
        if (-not ($RemoteRetentionSettings -is [hashtable])) {
            $ValidationMessagesListRef.Value.Add("AzureBlob Target '$TargetInstanceName': 'RemoteRetentionSettings' must be a Hashtable if defined.")
        }
        elseif ($RemoteRetentionSettings.ContainsKey('KeepCount') -and (-not ($RemoteRetentionSettings.KeepCount -is [int]) -or $RemoteRetentionSettings.KeepCount -le 0)) {
            $ValidationMessagesListRef.Value.Add("AzureBlob Target '$TargetInstanceName': 'RemoteRetentionSettings.KeepCount' must be an integer greater than 0 if defined.")
        }
    }
}
#endregion

#region --- Azure Blob Target Transfer Function ---
function Invoke-PoShBackupTargetTransfer {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
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
        [Parameter(Mandatory = $true)] [datetime]$LocalArchiveCreationTimestamp,
        [Parameter(Mandatory = $true)] [bool]$PasswordInUse,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCmdlet]$PSCmdlet
    )

    $null = $EffectiveJobConfig, $LocalArchiveCreationTimestamp, $PasswordInUse # PSSA Appeasement

    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }
    $targetNameForLog = $TargetInstanceConfiguration._TargetInstanceName_
    & $LocalWriteLog -Message ("`n[INFO] AzureBlob Target: Starting transfer for Job '{0}' to Target '{1}'." -f $JobName, $targetNameForLog) -Level "INFO"

    $result = @{ Success = $false; RemotePath = $null; ErrorMessage = $null; TransferSize = 0; TransferDuration = New-TimeSpan }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    if (-not (Get-Module -Name Az.Storage -ListAvailable)) {
        $result.ErrorMessage = "AzureBlob Target '$targetNameForLog': Az.Storage module is not installed. Please install it using 'Install-Module Az.Storage'."
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"; $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed; return $result
    }
    Import-Module Az.Storage -ErrorAction SilentlyContinue

    $azSettings = $TargetInstanceConfiguration.TargetSpecificSettings
    $containerName = $azSettings.ContainerName
    $createJobSubDir = if ($azSettings.ContainsKey('CreateJobNameSubdirectory')) { $azSettings.CreateJobNameSubdirectory } else { $false }
    $remoteKeyPrefix = if ($createJobSubDir) { "$JobName/" } else { "" }
    $remoteBlobName = $remoteKeyPrefix + $ArchiveFileName
    $result.RemotePath = "https://$($azSettings.StorageAccountName).blob.core.windows.net/$containerName/$remoteBlobName"

    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: Would connect to Azure Storage Account '$($azSettings.StorageAccountName)'." -Level "SIMULATE"
        & $LocalWriteLog -Message "SIMULATE: Would ensure container '$containerName' exists." -Level "SIMULATE"
        & $LocalWriteLog -Message "SIMULATE: The archive file '$ArchiveFileName' would be uploaded to Container '$containerName' as Blob '$remoteBlobName'." -Level "SIMULATE"
        if ($TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings') -and $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -gt 0) {
            & $LocalWriteLog -Message ("SIMULATE: After upload, retention policy (Keep: {0}) would be applied to blobs with prefix '{1}'." -f $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount, $remoteKeyPrefix) -Level "SIMULATE"
        }
        $result.Success = $true; $result.TransferSize = $LocalArchiveSizeBytes
        $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed; return $result
    }

    if (-not $PSCmdlet.ShouldProcess($result.RemotePath, "Upload File to Azure Blob Storage")) {
        $result.ErrorMessage = "AzureBlob Target '$targetNameForLog': Upload to '$($result.RemotePath)' skipped by user."; & $LocalWriteLog -Message "[WARNING] $($result.ErrorMessage)" -Level "WARNING"
        $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed; return $result
    }

    try {
        $connectionString = Get-PoShBackupSecret -SecretName $azSettings.ConnectionStringSecretName -Logger $Logger -AsPlainText -SecretPurposeForLog "Azure Storage Connection String"
        if ([string]::IsNullOrWhiteSpace($connectionString)) { throw "Failed to retrieve a valid Connection String from SecretManagement." }

        $storageContext = New-AzStorageContext -ConnectionString $connectionString -ErrorAction Stop

        $container = Get-AzStorageContainer -Name $containerName -Context $storageContext -ErrorAction SilentlyContinue
        if ($null -eq $container) {
            & $LocalWriteLog -Message "  - AzureBlob Target '{0}': Container '{1}' not found. Attempting to create." -f $targetNameForLog, $containerName -Level "INFO"
            New-AzStorageContainer -Name $containerName -Context $storageContext -ErrorAction Stop | Out-Null
        }

        & $LocalWriteLog -Message ("  - AzureBlob Target '{0}': Uploading file '{1}' to blob '{2}'..." -f $targetNameForLog, $ArchiveFileName, $remoteBlobName) -Level "INFO"
        Set-AzStorageBlobContent -File $LocalArchivePath -Container $containerName -Blob $remoteBlobName -Context $storageContext -Force -ErrorAction Stop | Out-Null

        $result.Success = $true; $result.TransferSize = $LocalArchiveSizeBytes
        & $LocalWriteLog -Message ("    - AzureBlob Target '{0}': File uploaded successfully." -f $targetNameForLog) -Level "SUCCESS"

        if ($TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings') -and $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -is [int] -and $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -gt 0) {
            $remoteKeepCount = $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount
            & $LocalWriteLog -Message ("  - AzureBlob Target '{0}': Applying remote retention (KeepCount: {1}) in Container '{2}' with Prefix '{3}'." -f $targetNameForLog, $remoteKeepCount, $containerName, $remoteKeyPrefix) -Level "INFO"

            $allRemoteBlobs = Get-AzStorageBlob -Container $containerName -Context $storageContext -Prefix $remoteKeyPrefix
            $remoteInstances = Group-RemoteAzureBlobBackupInstancesInternal -AzureBlobObjectList $allRemoteBlobs -ArchiveBaseName $ArchiveBaseName -PrimaryArchiveExtension $ArchiveExtension -Logger $Logger

            if ($remoteInstances.Count -gt $remoteKeepCount) {
                $sortedInstances = $remoteInstances.GetEnumerator() | Sort-Object { $_.Value.SortTime } -Descending
                $instancesToDelete = $sortedInstances | Select-Object -Skip $remoteKeepCount
                & $LocalWriteLog -Message ("    - AzureBlob Target '{0}': Found {1} remote instances. Will delete files for {2} older instance(s)." -f $targetNameForLog, $remoteInstances.Count, $instancesToDelete.Count) -Level "INFO"

                foreach ($instanceEntry in $instancesToDelete) {
                    & $LocalWriteLog "      - AzureBlob Target '{0}': Preparing to delete instance files for '$($instanceEntry.Name)'." -Level "WARNING"
                    foreach ($blobToDelete in $instanceEntry.Value.Files) {
                        if (-not $PSCmdlet.ShouldProcess($blobToDelete.Name, "Delete Remote Azure Blob (Retention)")) {
                            & $LocalWriteLog ("        - Deletion of '{0}' skipped by user." -f $blobToDelete.Name) -Level "WARNING"; continue
                        }
                        & $LocalWriteLog ("        - Deleting: '{0}' (LastModified: $($blobToDelete.LastModified))" -f $blobToDelete.Name) -Level "WARNING"
                        try {
                            Remove-AzStorageBlob -Blob $blobToDelete.Name -Container $containerName -Context $storageContext -Confirm:$false -ErrorAction Stop
                            & $LocalWriteLog "          - Status: DELETED" -Level "SUCCESS"
                        } catch {
                            $retentionErrorMsg = "Failed to delete remote blob '$($blobToDelete.Name)'. Error: $($_.Exception.Message)"
                            & $LocalWriteLog "          - Status: FAILED! $retentionErrorMsg" -Level "ERROR"
                            if ([string]::IsNullOrWhiteSpace($result.ErrorMessage)) { $result.ErrorMessage = $retentionErrorMsg } else { $result.ErrorMessage += "; $retentionErrorMsg" }
                        }
                    }
                }
            }
        }
    }
    catch {
        $result.ErrorMessage = "AzureBlob Target '$targetNameForLog': Operation failed. Error: $($_.Exception.Message)"
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"; $result.Success = $false
    }
    finally {
        $connectionString = $null; [System.GC]::Collect()
    }

    $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed
    $result.TransferSizeFormatted = Format-FileSize -Bytes $result.TransferSize
    & $LocalWriteLog -Message ("[INFO] AzureBlob Target: Finished transfer attempt for Job '{0}' to Target '{1}'. Success: {2}." -f $JobName, $targetNameForLog, $result.Success) -Level "INFO"
    return $result
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupTargetTransfer, Invoke-PoShBackupAzureBlobTargetSettingsValidation, Test-PoShBackupTargetConnectivity
