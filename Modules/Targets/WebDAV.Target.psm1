# Modules\Targets\WebDAV.Target.psm1
<#
.SYNOPSIS
    PoSh-Backup Target Provider for WebDAV (Web Distributed Authoring and Versioning).
    This module now acts as a facade, orchestrating calls to specialised sub-modules.
.DESCRIPTION
    This module implements the PoSh-Backup target provider interface for WebDAV destinations.
    It orchestrates the entire transfer and retention process by calling its sub-modules:
    - WebDAV.CredentialHandler.psm1: Retrieves credentials from PowerShell SecretManagement.
    - WebDAV.PathHandler.psm1: Ensures the remote directory structure exists using MKCOL.
    - WebDAV.TransferAgent.psm1: Manages the file upload using PUT requests.
    - WebDAV.RetentionApplicator.psm1: Applies the remote retention policy.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0 # Major refactoring into a facade with sub-modules.
    DateCreated:    05-Jun-2025
    LastModified:   28-Jun-2025
    Purpose:        WebDAV Target Provider for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Targets
$webdavSubModulePath = Join-Path -Path $PSScriptRoot -ChildPath "WebDAV"
try {
    Import-Module -Name (Join-Path $webdavSubModulePath "WebDAV.CredentialHandler.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $webdavSubModulePath "WebDAV.PathHandler.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $webdavSubModulePath "WebDAV.TransferAgent.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $webdavSubModulePath "WebDAV.RetentionApplicator.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "WebDAV.Target.psm1 (Facade) FATAL: Could not import a required sub-module. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- WebDAV Target Connectivity Test Function ---
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
    
    $webDAVUrl = $TargetSpecificSettings.WebDAVUrl
    $secretName = $TargetSpecificSettings.CredentialsSecretName
    
    & $LocalWriteLog -Message "  - WebDAV Target: Testing connectivity to URL '$webDAVUrl'..." -Level "INFO"

    if (-not $PSCmdlet.ShouldProcess($webDAVUrl, "Test WebDAV Connection (PROPFIND)")) {
        return @{ Success = $false; Message = "WebDAV connection test skipped by user." }
    }
    
    $credential = $null
    try {
        $credential = Get-WebDAVCredential -SecretName $secretName -VaultName $TargetSpecificSettings.CredentialsVaultName -Logger $Logger
    }
    catch {
        return @{ Success = $false; Message = "Failed to retrieve credential. Error: $($_.Exception.Message)" }
    }

    try {
        $timeout = if ($TargetSpecificSettings.ContainsKey('RequestTimeoutSec')) { $TargetSpecificSettings.RequestTimeoutSec } else { 30 }
        Invoke-WebRequest -Uri $webDAVUrl -Method "PROPFIND" -Credential $credential -Headers @{"Depth" = "0" } -TimeoutSec $timeout -ErrorAction Stop -OutNull
        
        $successMessage = "Successfully connected to '$webDAVUrl' and received a valid response."
        & $LocalWriteLog -Message "    - SUCCESS: $successMessage" -Level "SUCCESS"
        return @{ Success = $true; Message = $successMessage }
    }
    catch {
        $errorMessage = "Failed to connect or get a valid response from '$webDAVUrl'. Error: $($_.Exception.Message)"
        if ($_.Exception.Response) { $errorMessage += " Status: $($_.Exception.Response.StatusCode) $($_.Exception.Response.StatusDescription)" }
        & $LocalWriteLog -Message "    - FAILED: $errorMessage" -Level "ERROR"
        return @{ Success = $false; Message = $errorMessage }
    }
}
#endregion

#region --- WebDAV Target Settings Validation Function ---
function Invoke-PoShBackupWebDAVTargetSettingsValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [hashtable]$TargetInstanceConfiguration,
        [Parameter(Mandatory = $true)] [string]$TargetInstanceName,
        [Parameter(Mandatory = $true)] [ref]$ValidationMessagesListRef,
        [Parameter(Mandatory = $false)] [scriptblock]$Logger
    )
    if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) { & $Logger -Message "WebDAV.Target/Invoke-PoShBackupWebDAVTargetSettingsValidation: Logger active for '$TargetInstanceName'." -Level "DEBUG" -ErrorAction SilentlyContinue }

    $TargetSpecificSettings = $TargetInstanceConfiguration.TargetSpecificSettings
    if (-not ($TargetSpecificSettings -is [hashtable])) { $ValidationMessagesListRef.Value.Add("WebDAV Target '$TargetInstanceName': 'TargetSpecificSettings' must be a Hashtable."); return }
    
    if (-not $TargetSpecificSettings.ContainsKey('WebDAVUrl') -or -not ($TargetSpecificSettings.WebDAVUrl -is [string]) -or [string]::IsNullOrWhiteSpace($TargetSpecificSettings.WebDAVUrl)) {
        $ValidationMessagesListRef.Value.Add("WebDAV Target '$TargetInstanceName': 'WebDAVUrl' is missing or empty.")
    }
    if (-not $TargetSpecificSettings.ContainsKey('CredentialsSecretName') -or -not ($TargetSpecificSettings.CredentialsSecretName -is [string]) -or [string]::IsNullOrWhiteSpace($TargetSpecificSettings.CredentialsSecretName)) {
        $ValidationMessagesListRef.Value.Add("WebDAV Target '$TargetInstanceName': 'CredentialsSecretName' is missing or empty.")
    }
}
#endregion

#region --- WebDAV Target Transfer Function ---
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
    & $LocalWriteLog -Message ("`n[INFO] WebDAV Target (Facade): Starting transfer for Job '{0}' to Target '{1}'." -f $JobName, $targetNameForLog) -Level "INFO"

    $result = @{ Success = $false; RemotePath = $null; ErrorMessage = $null; TransferSize = 0; TransferDuration = New-TimeSpan }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $webDAVSettings = $TargetInstanceConfiguration.TargetSpecificSettings
        $webDAVUrlBase = $webDAVSettings.WebDAVUrl.TrimEnd("/")
        $requestTimeoutSec = if ($webDAVSettings.ContainsKey('RequestTimeoutSec')) { $webDAVSettings.RequestTimeoutSec } else { 120 }

        if ([string]::IsNullOrWhiteSpace($webDAVUrlBase)) { throw "WebDAVUrl is missing in TargetSpecificSettings." }

        $credential = Get-WebDAVCredential -SecretName $webDAVSettings.CredentialsSecretName -VaultName $webDAVSettings.CredentialsVaultName -Logger $Logger
        
        $remotePathRelative = ($webDAVSettings.RemotePath -replace "^/+", "").TrimEnd("/")
        $createJobSubDir = if ($webDAVSettings.ContainsKey('CreateJobNameSubdirectory')) { $webDAVSettings.CreateJobNameSubdirectory } else { $false }
        $remoteFinalRelativeDirForJob = if ($createJobSubDir) { "$remotePathRelative/$JobName".TrimStart("/") } else { $remotePathRelative }
        $remoteFinalRelativeDirForJob = $remoteFinalRelativeDirForJob.TrimStart("/")
        
        $fullRemoteArchivePath = ($webDAVUrlBase + "/" + $remoteFinalRelativeDirForJob.TrimStart("/") + "/" + $ArchiveFileName).TrimEnd("/")
        $result.RemotePath = $fullRemoteArchivePath

        if ($IsSimulateMode.IsPresent) {
            & $LocalWriteLog -Message "SIMULATE: Would establish WebDAV connection, ensure path exists, and upload '$ArchiveFileName' to '$fullRemoteArchivePath'." -Level "SIMULATE"
            $result.Success = $true; $result.TransferSize = $LocalArchiveSizeBytes
            $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed; return $result
        }

        # 1. Ensure Path Exists
        $pathResult = Set-WebDAVTargetPath -BaseWebDAVUrl $webDAVUrlBase -RelativePathToEnsure $remoteFinalRelativeDirForJob `
            -Credential $credential -RequestTimeoutSec $requestTimeoutSec -Logger $Logger -PSCmdletInstance $PSCmdlet
        if (-not $pathResult.Success) { throw $pathResult.ErrorMessage }

        # 2. Upload File
        $uploadResult = Start-PoShBackupWebDAVUpload -FullRemoteDestinationUrl $fullRemoteArchivePath -LocalSourcePath $LocalArchivePath `
            -Credential $credential -RequestTimeoutSec $requestTimeoutSec -Logger $Logger -PSCmdletInstance $PSCmdlet
        if (-not $uploadResult.Success) { throw $uploadResult.ErrorMessage }
        
        $result.Success = $true; $result.TransferSize = $LocalArchiveSizeBytes
        & $LocalWriteLog -Message ("    - WebDAV Target (Facade): File uploaded successfully.") -Level "SUCCESS"

        # 3. Apply Remote Retention
        if ($TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings')) {
            Invoke-WebDAVRetentionPolicy -RetentionSettings $TargetInstanceConfiguration.RemoteRetentionSettings `
                -BaseWebDAVUrl $webDAVUrlBase -RemoteJobDirectoryRelative $remoteFinalRelativeDirForJob `
                -Credential $credential -RequestTimeoutSec $requestTimeoutSec `
                -ArchiveBaseName $ArchiveBaseName -ArchiveExtension $ArchiveExtension -ArchiveDateFormat $EffectiveJobConfig.JobArchiveDateFormat `
                -Logger $Logger -PSCmdletInstance $PSCmdlet
        }
    }
    catch {
        $result.ErrorMessage = "WebDAV Target '$targetNameForLog': Operation failed. Error: $($_.Exception.Message)"
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"; $result.Success = $false
    }

    $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed
    $result.TransferSizeFormatted = Format-FileSize -Bytes $result.TransferSize
    & $LocalWriteLog -Message ("[INFO] WebDAV Target (Facade): Finished transfer for Job '{0}' to Target '{1}'. Success: {2}." -f $JobName, $targetNameForLog, $result.Success) -Level "INFO"
    return $result
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupTargetTransfer, Invoke-PoShBackupWebDAVTargetSettingsValidation, Test-PoShBackupTargetConnectivity
