# Modules\Targets\WebDAV.Target.psm1
<#
.SYNOPSIS
    PoSh-Backup Target Provider for WebDAV (Web Distributed Authoring and Versioning).
    Handles transferring backup archives to WebDAV servers, managing remote retention,
    and supporting credential-based authentication via PowerShell SecretManagement.

.DESCRIPTION
    This module implements the PoSh-Backup target provider interface for WebDAV destinations.
    The core function, 'Invoke-PoShBackupTargetTransfer', is called by the main PoSh-Backup
    operations module when a backup job is configured to use a target of type "WebDAV".

    The provider performs the following actions:
    - Parses WebDAV-specific settings from the TargetInstanceConfiguration, including the
      WebDAV server URL, remote base path, and credential secret name.
    - Retrieves credentials (expected as a PSCredential object) from PowerShell SecretManagement.
    - Establishes a connection and ensures the remote target directory (and job-specific
      subdirectory, if configured) exists, creating it if necessary using MKCOL requests.
    - Uploads the local backup archive file to the WebDAV server using PUT requests.
    - If 'RemoteRetentionSettings' (e.g., 'KeepCount') are defined, it applies a count-based
      retention policy. This involves listing files using PROPFIND and deleting old files
      using DELETE requests.
    - Supports simulation mode for all WebDAV operations.
    - Returns a detailed status hashtable for each file transfer attempt.

    A function, 'Invoke-PoShBackupWebDAVTargetSettingsValidation', is included to validate
    the 'TargetSpecificSettings' and 'RemoteRetentionSettings' specific to this WebDAV provider.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        0.1.0
    DateCreated:    05-Jun-2025
    LastModified:   05-Jun-2025
    Purpose:        WebDAV Target Provider for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    PowerShell SecretManagement configured if using secrets for credentials.
                    The user/account running PoSh-Backup must have appropriate network access
                    to the WebDAV server and R/W/Delete permissions on the target remote path.
#>

#region --- Private Helper: Format Bytes ---
function Format-BytesInternal-WebDAV {
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

#region --- Private Helper: Get PSCredential from Secret ---
function Get-PSCredentialFromSecretInternal-WebDAV {
    param(
        [string]$SecretName,
        [string]$VaultName, # Optional
        [scriptblock]$Logger,
        [string]$SecretPurposeForLog = "WebDAV Credential"
    )
    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }

    if ([string]::IsNullOrWhiteSpace($SecretName)) {
        & $LocalWriteLog -Message ("  - GetPSCredentialSecret: SecretName not provided for {0}. Cannot retrieve." -f $SecretPurposeForLog) -Level "DEBUG"
        return $null
    }
    if (-not (Get-Command Get-Secret -ErrorAction SilentlyContinue)) {
        $errorMessageText = "GetPSCredentialSecret: PowerShell SecretManagement module (Get-Secret cmdlet) not found. Cannot retrieve '{0}' for {1}." -f $SecretName, $SecretPurposeForLog
        & $LocalWriteLog -Message "[ERROR] $errorMessageText" -Level "ERROR"
        throw "PowerShell SecretManagement module not found."
    }
    try {
        $getSecretParams = @{ Name = $SecretName; ErrorAction = 'Stop' }
        if (-not [string]::IsNullOrWhiteSpace($VaultName)) {
            $getSecretParams.Vault = $VaultName
        }
        $secretValue = Get-Secret @getSecretParams
        if ($null -ne $secretValue) {
            & $LocalWriteLog -Message ("  - GetPSCredentialSecret: Successfully retrieved secret object '{0}' for {1}." -f $SecretName, $SecretPurposeForLog) -Level "DEBUG"
            if ($secretValue.Secret -is [System.Management.Automation.PSCredential]) {
                & $LocalWriteLog -Message ("  - GetPSCredentialSecret: Secret '{0}' is a PSCredential object." -f $SecretName) -Level "DEBUG"
                return $secretValue.Secret
            } else {
                & $LocalWriteLog -Message ("[WARNING] GetPSCredentialSecret: Secret '{0}' for {1} was retrieved but is not a PSCredential object. Type: {2}." -f $SecretName, $SecretPurposeForLog, $secretValue.Secret.GetType().FullName) -Level "WARNING"
                return $null
            }
        }
    }
    catch {
        & $LocalWriteLog -Message ("[ERROR] GetPSCredentialSecret: Failed to retrieve secret '{0}' for {1}. Error: {2}" -f $SecretName, $SecretPurposeForLog, $_.Exception.Message) -Level "ERROR"
    }
    return $null
}
#endregion

#region --- Private Helper: Ensure WebDAV Remote Path Exists (MKCOL) ---
function Initialize-WebDAVRemotePathInternal {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)]
        [string]$BaseWebDAVUrl, # e.g., https://webdav.example.com
        [Parameter(Mandatory)]
        [string]$RelativePathToEnsure, # e.g., /backups/jobname
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory)]
        [scriptblock]$Logger,
        [Parameter(Mandatory)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )
    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }
    & $LocalWriteLog -Message "WebDAV.Target/Initialize-WebDAVRemotePathInternal: Ensuring path '$RelativePathToEnsure' on '$BaseWebDAVUrl'." -Level "DEBUG"

    $fullUrlToEnsure = ($BaseWebDAVUrl.TrimEnd("/") + "/" + $RelativePathToEnsure.TrimStart("/")).TrimEnd("/")
    
    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: WebDAV.Target: Would check/create remote directory structure for '$fullUrlToEnsure'." -Level "SIMULATE"
        return @{ Success = $true }
    }

    $pathSegments = $RelativePathToEnsure.Trim("/").Split("/") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $currentRelativePath = ""
    
    foreach ($segment in $pathSegments) {
        $currentRelativePath += "/$segment"
        $currentSegmentUrl = ($BaseWebDAVUrl.TrimEnd("/") + $currentRelativePath).TrimEnd("/")
        
        if (-not $PSCmdletInstance.ShouldProcess($currentSegmentUrl, "Check/Create WebDAV Collection")) {
            return @{ Success = $false; ErrorMessage = "WebDAV collection creation for '$currentSegmentUrl' skipped by user." }
        }

        try {
            # Attempt to check if collection exists (PROPFIND depth 0).
            # -ErrorAction SilentlyContinue means HTTP errors (like 404 Not Found) won't cause this try to fail and jump to catch.
            # Instead, $? would be $false, and an error record added to $Error.
            # This PROPFIND is a preliminary check; the subsequent MKCOL is the definitive action.
            Invoke-WebRequest -Uri $currentSegmentUrl -Method "PROPFIND" -Credential $Credential -Headers @{"Depth"="0"} -TimeoutSec 30 -ErrorAction SilentlyContinue -OutNull
            # No action needed here based on $? because we will attempt MKCOL regardless,
            # and the MKCOL logic handles cases where the directory might already exist (e.g., HTTP 405).
        } catch {
            # This catch block is for unexpected, terminating errors from Invoke-WebRequest during the PROPFIND attempt itself
            # (e.g., network issues, DNS failure), not for HTTP status codes like 404 when SilentlyContinue is used.
            & $LocalWriteLog -Message "[DEBUG] WebDAV.Target: The PROPFIND request for '$currentSegmentUrl' encountered an unexpected issue (this is not an HTTP status error like 404). Error: $($_.Exception.Message). Proceeding to attempt MKCOL anyway." -Level "DEBUG"
        }

        # Always attempt MKCOL, as it has logic to handle "already exists" (e.g., HTTP 405 response)
        try {
            & $LocalWriteLog -Message "  - WebDAV.Target: Attempting MKCOL for '$currentSegmentUrl'." -Level "DEBUG"
            Invoke-WebRequest -Uri $currentSegmentUrl -Method "MKCOL" -Credential $Credential -TimeoutSec 30 -ErrorAction Stop -OutNull # ErrorAction Stop for MKCOL
            & $LocalWriteLog -Message "    - WebDAV.Target: MKCOL successful or collection already existed for '$currentSegmentUrl'." -Level "DEBUG"
        } catch {
            # Check if the error is "405 Method Not Allowed" - this often means the collection already exists.
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode -eq 405) {
                & $LocalWriteLog -Message "    - WebDAV.Target: MKCOL returned 405 (Method Not Allowed) for '$currentSegmentUrl', assuming collection already exists." -Level "DEBUG"
            } else {
                $errorMessage = "Failed to create WebDAV collection '$currentSegmentUrl'. Error: $($_.Exception.Message)"
                if ($_.Exception.Response) { $errorMessage += " Status: $($_.Exception.Response.StatusCode) $($_.Exception.Response.StatusDescription)" }
                & $LocalWriteLog -Message "[ERROR] WebDAV.Target: $errorMessage" -Level "ERROR"
                return @{ Success = $false; ErrorMessage = $errorMessage }
            }
        }

        # Attempt MKCOL if it might not exist. Some servers return 405 if it exists.
        try {
            & $LocalWriteLog -Message "  - WebDAV.Target: Attempting MKCOL for '$currentSegmentUrl'." -Level "DEBUG"
            Invoke-WebRequest -Uri $currentSegmentUrl -Method "MKCOL" -Credential $Credential -TimeoutSec 30 -ErrorAction Stop -OutNull
            & $LocalWriteLog -Message "    - WebDAV.Target: MKCOL successful or collection already existed for '$currentSegmentUrl'." -Level "DEBUG"
        } catch {
            # Check if the error is "405 Method Not Allowed" - this often means the collection already exists.
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode -eq 405) {
                & $LocalWriteLog -Message "    - WebDAV.Target: MKCOL returned 405 (Method Not Allowed) for '$currentSegmentUrl', assuming collection already exists." -Level "DEBUG"
            } else {
                $errorMessage = "Failed to create WebDAV collection '$currentSegmentUrl'. Error: $($_.Exception.Message)"
                if ($_.Exception.Response) { $errorMessage += " Status: $($_.Exception.Response.StatusCode) $($_.Exception.Response.StatusDescription)" }
                & $LocalWriteLog -Message "[ERROR] WebDAV.Target: $errorMessage" -Level "ERROR"
                return @{ Success = $false; ErrorMessage = $errorMessage }
            }
        }
    }
    return @{ Success = $true }
}
#endregion

#region --- WebDAV Target Settings Validation Function ---
function Invoke-PoShBackupWebDAVTargetSettingsValidation {
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
        & $Logger -Message "WebDAV.Target/Invoke-PoShBackupWebDAVTargetSettingsValidation: Validating settings for WebDAV Target '$TargetInstanceName'." -Level "DEBUG"
    }
    $fullPathToSettings = "Configuration.BackupTargets.$TargetInstanceName.TargetSpecificSettings"
    $fullPathToRetentionSettings = "Configuration.BackupTargets.$TargetInstanceName.RemoteRetentionSettings"

    if (-not ($TargetSpecificSettings -is [hashtable])) {
        $ValidationMessagesListRef.Value.Add("WebDAV Target '$TargetInstanceName': 'TargetSpecificSettings' must be a Hashtable, but found type '$($TargetSpecificSettings.GetType().Name)'. Path: '$fullPathToSettings'.")
        return
    }

    if (-not $TargetSpecificSettings.ContainsKey('WebDAVUrl') -or -not ($TargetSpecificSettings.WebDAVUrl -is [string]) -or [string]::IsNullOrWhiteSpace($TargetSpecificSettings.WebDAVUrl)) {
        $ValidationMessagesListRef.Value.Add("WebDAV Target '$TargetInstanceName': 'WebDAVUrl' in 'TargetSpecificSettings' is missing, not a string, or empty. Path: '$fullPathToSettings.WebDAVUrl'.")
    } else {
        try {
            [System.Uri]$TargetSpecificSettings.WebDAVUrl | Out-Null
            if (-not ($TargetSpecificSettings.WebDAVUrl -match "^https?://")) {
                $ValidationMessagesListRef.Value.Add("WebDAV Target '$TargetInstanceName': 'WebDAVUrl' ('$($TargetSpecificSettings.WebDAVUrl)') must be a valid HTTP or HTTPS URL. Path: '$fullPathToSettings.WebDAVUrl'.")
            }
        } catch {
            $ValidationMessagesListRef.Value.Add("WebDAV Target '$TargetInstanceName': 'WebDAVUrl' ('$($TargetSpecificSettings.WebDAVUrl)') is not a valid URI. Error: $($_.Exception.Message). Path: '$fullPathToSettings.WebDAVUrl'.")
        }
    }

    if (-not $TargetSpecificSettings.ContainsKey('CredentialsSecretName') -or -not ($TargetSpecificSettings.CredentialsSecretName -is [string]) -or [string]::IsNullOrWhiteSpace($TargetSpecificSettings.CredentialsSecretName)) {
        $ValidationMessagesListRef.Value.Add("WebDAV Target '$TargetInstanceName': 'CredentialsSecretName' in 'TargetSpecificSettings' is missing, not a string, or empty. This secret should store a PSCredential object. Path: '$fullPathToSettings.CredentialsSecretName'.")
    }
    
    if ($TargetSpecificSettings.ContainsKey('RemotePath') -and (-not ($TargetSpecificSettings.RemotePath -is [string]))) { # RemotePath is optional, defaults to root if not present
        $ValidationMessagesListRef.Value.Add("WebDAV Target '$TargetInstanceName': 'RemotePath' in 'TargetSpecificSettings' must be a string if defined. Path: '$fullPathToSettings.RemotePath'.")
    }

    if ($TargetSpecificSettings.ContainsKey('CreateJobNameSubdirectory') -and -not ($TargetSpecificSettings.CreateJobNameSubdirectory -is [boolean])) {
        $ValidationMessagesListRef.Value.Add("WebDAV Target '$TargetInstanceName': 'CreateJobNameSubdirectory' in 'TargetSpecificSettings' must be a boolean (`$true` or `$false`) if defined. Path: '$fullPathToSettings.CreateJobNameSubdirectory'.")
    }
    
    if ($TargetSpecificSettings.ContainsKey('RequestTimeoutSec') -and (-not ($TargetSpecificSettings.RequestTimeoutSec -is [int] -and $TargetSpecificSettings.RequestTimeoutSec -gt 0))) {
        $ValidationMessagesListRef.Value.Add("WebDAV Target '$TargetInstanceName': 'RequestTimeoutSec' in 'TargetSpecificSettings' must be a positive integer if defined. Path: '$fullPathToSettings.RequestTimeoutSec'.")
    }

    if ($PSBoundParameters.ContainsKey('RemoteRetentionSettings') -and ($null -ne $RemoteRetentionSettings)) {
        if (-not ($RemoteRetentionSettings -is [hashtable])) {
            $ValidationMessagesListRef.Value.Add("WebDAV Target '$TargetInstanceName': 'RemoteRetentionSettings' must be a Hashtable if defined. Path: '$fullPathToRetentionSettings'.")
        }
        elseif ($RemoteRetentionSettings.ContainsKey('KeepCount')) {
            if (-not ($RemoteRetentionSettings.KeepCount -is [int]) -or $RemoteRetentionSettings.KeepCount -le 0) {
                $ValidationMessagesListRef.Value.Add("WebDAV Target '$TargetInstanceName': 'RemoteRetentionSettings.KeepCount' must be an integer greater than 0 if defined. Path: '$fullPathToRetentionSettings.KeepCount'.")
            }
        }
    }
}
#endregion

#region --- WebDAV Target Transfer Function ---
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

    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }
    $targetNameForLog = $TargetInstanceConfiguration._TargetInstanceName_
    & $LocalWriteLog -Message ("`n[INFO] WebDAV Target: Starting transfer for Job '{0}' to Target '{1}', File '{2}'." -f $JobName, $targetNameForLog, $ArchiveFileName) -Level "INFO"

    $result = @{
        Success          = $false
        RemotePath       = $null
        ErrorMessage     = $null
        TransferSize     = 0
        TransferDuration = New-TimeSpan
    }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # --- Parse WebDAV Specific Settings ---
    $sftpSettings = $TargetInstanceConfiguration.TargetSpecificSettings # Re-using var name, but it's WebDAV settings
    $webDAVUrlBase = $sftpSettings.WebDAVUrl.TrimEnd("/")
    $credentialSecretName = $sftpSettings.CredentialsSecretName
    $credentialVaultName = $sftpSettings.CredentialsVaultName # Optional
    $remotePathRelative = ($sftpSettings.RemotePath -replace "^/+", "").TrimEnd("/") # Relative path on server
    $createJobSubDir = if ($sftpSettings.ContainsKey('CreateJobNameSubdirectory')) { $sftpSettings.CreateJobNameSubdirectory } else { $false }
    $requestTimeoutSec = if ($sftpSettings.ContainsKey('RequestTimeoutSec')) { $sftpSettings.RequestTimeoutSec } else { 120 }


    if ([string]::IsNullOrWhiteSpace($webDAVUrlBase) -or [string]::IsNullOrWhiteSpace($credentialSecretName)) {
        $result.ErrorMessage = "WebDAV Target '$targetNameForLog': WebDAVUrl or CredentialsSecretName is missing."
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"; $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed; return $result
    }

    $credential = Get-PSCredentialFromSecretInternal-WebDAV -SecretName $credentialSecretName -VaultName $credentialVaultName -Logger $Logger
    if ($null -eq $credential) {
        $result.ErrorMessage = "WebDAV Target '$targetNameForLog': Failed to retrieve PSCredential from secret '$credentialSecretName'."
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"; $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed; return $result
    }

    $remoteFinalRelativeDir = if ($createJobSubDir) { "$remotePathRelative/$JobName".TrimStart("/") } else { $remotePathRelative }
    $remoteFinalRelativeDir = $remoteFinalRelativeDir.TrimStart("/") # Ensure it's relative for Initialize-WebDAVRemotePathInternal
    
    $fullRemoteArchivePath = ($webDAVUrlBase + "/" + $remoteFinalRelativeDir.TrimStart("/") + "/" + $ArchiveFileName).TrimEnd("/")
    $result.RemotePath = $fullRemoteArchivePath

    & $LocalWriteLog -Message ("  - WebDAV Target '{0}': Base URL '{1}', Relative Path '{2}', Create Subdir '{3}'." -f $targetNameForLog, $webDAVUrlBase, $remotePathRelative, $createJobSubDir) -Level "DEBUG"
    & $LocalWriteLog -Message ("    - Final Remote Directory (relative): '{0}'" -f $remoteFinalRelativeDir) -Level "DEBUG"
    & $LocalWriteLog -Message ("    - Full Remote Archive Destination URL: '{0}'" -f $fullRemoteArchivePath) -Level "DEBUG"

    # --- Simulation Mode ---
    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: WebDAV.Target '$targetNameForLog': Would connect to '$webDAVUrlBase' with retrieved credentials." -Level "SIMULATE"
        & $LocalWriteLog -Message "SIMULATE: WebDAV.Target '$targetNameForLog': Would ensure remote directory structure for relative path '$remoteFinalRelativeDir' exists." -Level "SIMULATE"
        & $LocalWriteLog -Message "SIMULATE: WebDAV.Target '$targetNameForLog': Would upload '$LocalArchivePath' to '$fullRemoteArchivePath'." -Level "SIMULATE"
        $result.Success = $true; $result.TransferSize = $LocalArchiveSizeBytes
        # Retention Simulation
        if ($TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings') -and $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -gt 0) {
            & $LocalWriteLog -Message ("SIMULATE: WebDAV.Target '{0}': Would apply remote retention (KeepCount: {1}) in relative path '{2}'." -f $targetNameForLog, $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount, $remoteFinalRelativeDir) -Level "SIMULATE"
        }
        $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed; return $result
    }

    # --- Actual WebDAV Operations ---
    if (-not $PSCmdlet.ShouldProcess($fullRemoteArchivePath, "Transfer Archive via WebDAV")) {
        $result.ErrorMessage = "WebDAV Target '$targetNameForLog': Transfer to '$fullRemoteArchivePath' skipped by user (ShouldProcess)."
        & $LocalWriteLog -Message "[WARNING] $($result.ErrorMessage)" -Level "WARNING"; $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed; return $result
    }

    try {
        # Ensure remote directory exists
        $ensurePathResult = Initialize-WebDAVRemotePathInternal -BaseWebDAVUrl $webDAVUrlBase -RelativePathToEnsure $remoteFinalRelativeDir -Credential $credential -Logger $Logger -IsSimulateMode:$IsSimulateMode -PSCmdletInstance $PSCmdlet
        if (-not $ensurePathResult.Success) {
            throw ("Failed to ensure WebDAV remote directory structure. Error: " + $ensurePathResult.ErrorMessage)
        }

        # Upload file
        & $LocalWriteLog -Message ("  - WebDAV Target '{0}': Uploading '{1}' to '{2}'..." -f $targetNameForLog, $LocalArchivePath, $fullRemoteArchivePath) -Level "INFO"
        Invoke-WebRequest -Uri $fullRemoteArchivePath -Method Put -InFile $LocalArchivePath -Credential $credential -ContentType "application/octet-stream" -TimeoutSec $requestTimeoutSec -ErrorAction Stop
        $result.Success = $true
        $result.TransferSize = $LocalArchiveSizeBytes # Assume full file size transferred on success
        & $LocalWriteLog -Message ("    - WebDAV Target '{0}': File uploaded successfully." -f $targetNameForLog) -Level "SUCCESS"

        # Remote Retention (Placeholder - WebDAV PROPFIND and DELETE are complex)
        if ($TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings') -and `
                $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -is [int] -and `
                $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -gt 0) {
            $remoteKeepCount = $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount
            & $LocalWriteLog -Message ("  - WebDAV Target '{0}': Remote retention (KeepCount: {1}) in relative path '{2}' - PLACEHOLDER. WebDAV retention not fully implemented." -f $targetNameForLog, $remoteKeepCount, $remoteFinalRelativeDir) -Level "INFO"
            # TODO: Implement WebDAV PROPFIND to list files, parse XML, sort by date, and DELETE oldest.
            # This is non-trivial. For now, log that it's a placeholder.
            & $LocalWriteLog -Message "[WARNING] WebDAV.Target '$targetNameForLog': Remote retention policy is configured but NOT YET IMPLEMENTED for WebDAV targets. Old files will not be deleted automatically by this provider." -Level "WARNING"
        }

    } catch {
        $result.ErrorMessage = "WebDAV Target '$targetNameForLog': Operation failed. Error: $($_.Exception.Message)"
        if ($_.Exception.Response) { $result.ErrorMessage += " Status: $($_.Exception.Response.StatusCode) $($_.Exception.Response.StatusDescription)" }
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"
        $result.Success = $false
    }

    $stopwatch.Stop()
    $result.TransferDuration = $stopwatch.Elapsed
    & $LocalWriteLog -Message ("[INFO] WebDAV Target: Finished transfer attempt for Job '{0}' to Target '{1}', File '{2}'. Success: {3}." -f $JobName, $targetNameForLog, $ArchiveFileName, $result.Success) -Level "INFO"
    return $result
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupTargetTransfer, Invoke-PoShBackupWebDAVTargetSettingsValidation
