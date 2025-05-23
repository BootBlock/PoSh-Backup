# Modules\Targets\SFTP.Target.psm1
<#
.SYNOPSIS
    PoSh-Backup Target Provider for SFTP (SSH File Transfer Protocol).
    Handles transferring backup archives to SFTP servers, managing remote retention,
    and supporting various authentication methods via Posh-SSH and PowerShell SecretManagement.

.DESCRIPTION
    This module implements the PoSh-Backup target provider interface for SFTP destinations.
    The core function, 'Invoke-PoShBackupTargetTransfer', is called by the main PoSh-Backup
    operations module when a backup job is configured to use a target of type "SFTP".

    The provider performs the following actions:
    - Checks for the presence of the 'Posh-SSH' module, which is required for SFTP operations.
    - Parses SFTP-specific settings from the TargetInstanceConfiguration, including server address,
      port, remote path, username, and authentication details (password or key file path/passphrase
      retrieved from PowerShell SecretManagement).
    - Establishes an SFTP session.
    - Ensures the remote target directory (and job-specific subdirectory, if configured) exists,
      creating it if necessary.
    - Uploads the local backup archive to the SFTP server.
    - If 'RemoteRetentionSettings' (e.g., 'KeepCount') are defined, applies a count-based
      retention policy to archives for the current job within the final remote directory.
    - Supports simulation mode for all SFTP operations.
    - Returns a detailed status hashtable.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.2 # Add PSSA suppressions and defensive logging for unused parameters.
    DateCreated:    22-May-2025
    LastModified:   22-May-2025
    Purpose:        SFTP Target Provider for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    The 'Posh-SSH' module must be installed (Install-Module Posh-SSH).
                    PowerShell SecretManagement configured if using secrets for credentials.
                    The user/account running PoSh-Backup must have appropriate network access
                    to the SFTP server and R/W/Delete permissions on the target remote path.
#>

#region --- Private Helper: Format Bytes ---
# Internal helper function to format byte sizes into human-readable strings (KB, MB, GB).
function Format-BytesInternal-Sftp {
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
function Get-SecretFromVaultInternal-Sftp {
    param(
        [string]$SecretName,
        [string]$VaultName, # Optional
        [scriptblock]$Logger,
        [string]$SecretPurposeForLog = "SFTP Credential"
    )
    # Defensive PSSA appeasement
    & $Logger -Message "SFTP.Target/Get-SecretFromVaultInternal-Sftp: Logger active for secret '$SecretName'." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }

    if ([string]::IsNullOrWhiteSpace($SecretName)) {
        & $LocalWriteLog -Message ("  - GetSecret: SecretName not provided for {0}. Cannot retrieve." -f $SecretPurposeForLog) -Level "DEBUG"
        return $null
    }
    if (-not (Get-Command Get-Secret -ErrorAction SilentlyContinue)) {
        $errorMessage = "GetSecret: PowerShell SecretManagement module (Get-Secret cmdlet) not found. Cannot retrieve '{0}' for {1}." -f $SecretName, $SecretPurposeForLog
        & $LocalWriteLog -Message "[ERROR] $errorMessage" -Level "ERROR"
        throw "PowerShell SecretManagement module not found."
    }
    try {
        $getSecretParams = @{ Name = $SecretName; ErrorAction = 'Stop' }
        if (-not [string]::IsNullOrWhiteSpace($VaultName)) {
            $getSecretParams.Vault = $VaultName
        }
        $secretValue = Get-Secret @getSecretParams
        if ($null -ne $secretValue) {
            & $LocalWriteLog -Message ("  - GetSecret: Successfully retrieved secret '{0}' for {1}." -f $SecretName, $SecretPurposeForLog) -Level "DEBUG"
            if ($secretValue.Secret -is [System.Security.SecureString]) {
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretValue.Secret)
                $plainText = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                return $plainText
            } elseif ($secretValue.Secret -is [string]) {
                return $secretValue.Secret
            } else {
                & $LocalWriteLog -Message ("[WARNING] GetSecret: Secret '{0}' for {1} was retrieved but is not a SecureString or String. Type: {2}." -f $SecretName, $SecretPurposeForLog, $secretValue.Secret.GetType().FullName) -Level "WARNING"
                return $null
            }
        }
    } catch {
        & $LocalWriteLog -Message ("[ERROR] GetSecret: Failed to retrieve secret '{0}' for {1}. Error: {2}" -f $SecretName, $SecretPurposeForLog, $_.Exception.Message) -Level "ERROR"
    }
    return $null
}
#endregion

#region --- SFTP Target Transfer Function ---
function Invoke-PoShBackupTargetTransfer {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    <#
    .SYNOPSIS
        Transfers a local backup archive to an SFTP server and manages remote retention.
    .DESCRIPTION
        This is the main exported function for the SFTP target provider. It handles the connection,
        authentication, directory creation, file upload, and remote retention for SFTP targets.
        It relies on the Posh-SSH module.
    .PARAMETER LocalArchivePath
        The full path to the local backup archive file that needs to be transferred.
    .PARAMETER TargetInstanceConfiguration
        A hashtable containing the full configuration for this specific SFTP target instance.
    .PARAMETER JobName
        The name of the overall backup job being processed.
    .PARAMETER ArchiveFileName
        The filename (leaf part) of the archive being transferred.
    .PARAMETER ArchiveBaseName
        The base name of the archive, without the date stamp or extension.
    .PARAMETER ArchiveExtension
        The extension of the archive file, including the dot.
    .PARAMETER IsSimulateMode
        A switch. If $true, SFTP operations are simulated.
    .PARAMETER Logger
        A mandatory scriptblock reference to the 'Write-LogMessage' function.
    .PARAMETER EffectiveJobConfig
        The fully resolved effective configuration for the current PoSh-Backup job.
    .PARAMETER LocalArchiveSizeBytes
        The size of the local archive in bytes.
    .PARAMETER LocalArchiveCreationTimestamp
        The creation timestamp of the local archive.
    .PARAMETER PasswordInUse
        A boolean indicating if the local archive was password protected.
    .PARAMETER PSCmdlet
        The automatic $PSCmdlet variable from the calling scope, for ShouldProcess.
    .OUTPUTS
        System.Collections.Hashtable
        Returns a hashtable with standard target provider output keys.
    #>
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

    # Defensive PSSA appeasement
    & $Logger -Message "SFTP.Target/Invoke-PoShBackupTargetTransfer: Logger parameter active for Job '$JobName', Target '$($TargetInstanceConfiguration._TargetInstanceName_)'." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }

    $targetNameForLog = $TargetInstanceConfiguration._TargetInstanceName_
    & $LocalWriteLog -Message ("`n[INFO] SFTP Target: Starting transfer for Job '{0}' to Target '{1}'." -f $JobName, $targetNameForLog) -Level "INFO"

    # PSSA Appeasement for otherwise unused parameters (logging them for debug/context)
    & $LocalWriteLog -Message ("  - SFTP Target Context: EffectiveJobConfig.JobName='{0}'." -f $EffectiveJobConfig.JobName) -Level "DEBUG"
    & $LocalWriteLog -Message ("  - SFTP Target Context: LocalArchiveCreationTimestamp='{0}'." -f $LocalArchiveCreationTimestamp) -Level "DEBUG"
    & $LocalWriteLog -Message ("  - SFTP Target Context: LocalArchivePasswordInUse='{0}'." -f $PasswordInUse) -Level "DEBUG"

    $result = @{
        Success          = $false
        RemotePath       = $null # Will be the full path on SFTP server
        ErrorMessage     = $null
        TransferSize     = 0
        TransferDuration = New-TimeSpan
    }
    $sftpSessionId = $null
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # Check for Posh-SSH module
    if (-not (Get-Module -Name Posh-SSH -ListAvailable)) {
        $result.ErrorMessage = "SFTP Target '$targetNameForLog': Posh-SSH module is not installed. Please install it using 'Install-Module Posh-SSH'."
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"
        $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed
        return $result
    }
    Import-Module Posh-SSH -ErrorAction SilentlyContinue # Ensure it's loaded

    # --- Parse SFTP Specific Settings ---
    $sftpSettings = $TargetInstanceConfiguration.TargetSpecificSettings
    $sftpServer = $sftpSettings.SFTPServerAddress
    $sftpPort = if ($sftpSettings.ContainsKey('SFTPPort')) { $sftpSettings.SFTPPort } else { 22 }
    $sftpUser = $sftpSettings.SFTPUserName
    $sftpRemoteBasePath = $sftpSettings.SFTPRemotePath.TrimEnd("/")
    $createJobSubDir = if ($sftpSettings.ContainsKey('CreateJobNameSubdirectory')) { $sftpSettings.CreateJobNameSubdirectory } else { $false }
    $skipHostKeyCheck = if ($sftpSettings.ContainsKey('SkipHostKeyCheck')) { $sftpSettings.SkipHostKeyCheck } else { $false }

    $sftpPassword = Get-SecretFromVaultInternal-Sftp -SecretName $sftpSettings.SFTPPasswordSecretName -Logger $Logger -SecretPurposeForLog "SFTP Password"
    $sftpKeyFilePathOnLocalMachine = Get-SecretFromVaultInternal-Sftp -SecretName $sftpSettings.SFTPKeyFileSecretName -Logger $Logger -SecretPurposeForLog "SFTP Key File Path"
    $sftpKeyPassphrase = Get-SecretFromVaultInternal-Sftp -SecretName $sftpSettings.SFTPKeyFilePassphraseSecretName -Logger $Logger -SecretPurposeForLog "SFTP Key Passphrase"

    if ([string]::IsNullOrWhiteSpace($sftpServer) -or [string]::IsNullOrWhiteSpace($sftpRemoteBasePath) -or [string]::IsNullOrWhiteSpace($sftpUser)) {
        $result.ErrorMessage = "SFTP Target '$targetNameForLog': SFTPServerAddress, SFTPRemotePath, or SFTPUserName is missing in TargetSpecificSettings."
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"
        $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed
        return $result
    }

    # Determine final remote directory
    $remoteFinalDirectory = if ($createJobSubDir) { "$sftpRemoteBasePath/$JobName" } else { $sftpRemoteBasePath }
    $fullRemoteArchivePath = "$remoteFinalDirectory/$ArchiveFileName"
    $result.RemotePath = $fullRemoteArchivePath

    & $LocalWriteLog -Message ("  - SFTP Target '{0}': Server '{1}:{2}', User '{3}', Remote Base Path '{4}', Create Subdir '{5}'." -f $targetNameForLog, $sftpServer, $sftpPort, $sftpUser, $sftpRemoteBasePath, $createJobSubDir) -Level "DEBUG"
    & $LocalWriteLog -Message ("    - Final Remote Directory for Archive: '{0}'" -f $remoteFinalDirectory) -Level "DEBUG"
    & $LocalWriteLog -Message ("    - Full Remote Archive Destination: '{0}'" -f $fullRemoteArchivePath) -Level "DEBUG"
    if ($skipHostKeyCheck) {
        & $LocalWriteLog -Message ("[WARNING] SFTP Target '{0}': SSH Host Key Check will be SKIPPED. This is INSECURE and only for trusted environments/testing." -f $targetNameForLog) -Level "WARNING"
    }

    # --- Simulation Mode ---
    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message ("SIMULATE: SFTP Target '{0}': Would attempt to connect to '{1}:{2}' as '{3}'." -f $targetNameForLog, $sftpServer, $sftpPort, $sftpUser) -Level "SIMULATE"
        if ($sftpKeyFilePathOnLocalMachine) { & $LocalWriteLog -Message ("SIMULATE:   Using key file (path retrieved from secret): '{0}'." -f $sftpKeyFilePathOnLocalMachine) -Level "SIMULATE" }
        elseif ($sftpPassword) { & $LocalWriteLog -Message "SIMULATE:   Using password (retrieved from secret)." -Level "SIMULATE" }
        else { & $LocalWriteLog -Message "SIMULATE:   No password or key file path provided from secrets." -Level "SIMULATE" }
        & $LocalWriteLog -Message ("SIMULATE: SFTP Target '{0}': Would ensure remote directory '{1}' exists." -f $targetNameForLog, $remoteFinalDirectory) -Level "SIMULATE"
        & $LocalWriteLog -Message ("SIMULATE: SFTP Target '{0}': Would upload '{1}' to '{2}'." -f $targetNameForLog, $LocalArchivePath, $fullRemoteArchivePath) -Level "SIMULATE"
        $result.Success = $true
        $result.TransferSize = $LocalArchiveSizeBytes
        $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed
        if ($TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings') -and $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -gt 0) {
            & $LocalWriteLog -Message ("SIMULATE: SFTP Target '{0}': Would apply remote retention (KeepCount: {1}) in '{2}'." -f $targetNameForLog, $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount, $remoteFinalDirectory) -Level "SIMULATE"
        }
        return $result
    }

    # --- Actual SFTP Operations ---
    if (-not $PSCmdlet.ShouldProcess(("SFTP Server: {0} (Path: {1})" -f $sftpServer, $fullRemoteArchivePath), "Transfer Archive via SFTP")) {
        $result.ErrorMessage = "SFTP Target '$targetNameForLog': Transfer to '$fullRemoteArchivePath' skipped by user (ShouldProcess)."
        & $LocalWriteLog -Message "[WARNING] $($result.ErrorMessage)" -Level "WARNING"
        $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed
        return $result
    }

    try {
        # Establish SFTP Session
        $sessionParams = @{ ComputerName = $sftpServer; Port = $sftpPort; Username = $sftpUser; ErrorAction = 'Stop' }
        if ($skipHostKeyCheck) { $sessionParams.AcceptKey = $true }

        if (-not [string]::IsNullOrWhiteSpace($sftpKeyFilePathOnLocalMachine)) {
            if (-not (Test-Path -LiteralPath $sftpKeyFilePathOnLocalMachine -PathType Leaf)) {
                $keySecretNameForError = if ($sftpSettings.ContainsKey('SFTPKeyFileSecretName')) { $sftpSettings.SFTPKeyFileSecretName } else { "N/A" }
                throw ("SFTP Key File not found at path '{0}' (retrieved from secret '{1}')." -f $sftpKeyFilePathOnLocalMachine, $keySecretNameForError)
            }
            $sessionParams.KeyFile = $sftpKeyFilePathOnLocalMachine
            if (-not [string]::IsNullOrWhiteSpace($sftpKeyPassphrase)) {
                $securePassphrase = ConvertTo-SecureString -String $sftpKeyPassphrase -AsPlainText -Force # PSScriptAnalyzer Suppress PSAvoidUsingConvertToSecureStringWithPlainText
                $sessionParams.KeyPassphrase = $securePassphrase
            }
            & $LocalWriteLog -Message ("  - SFTP Target '{0}': Attempting key-based authentication." -f $targetNameForLog) -Level "INFO"
        } elseif (-not [string]::IsNullOrWhiteSpace($sftpPassword)) {
            $securePassword = ConvertTo-SecureString -String $sftpPassword -AsPlainText -Force # PSScriptAnalyzer Suppress PSAvoidUsingConvertToSecureStringWithPlainText
            $sessionParams.Password = $securePassword
            & $LocalWriteLog -Message ("  - SFTP Target '{0}': Attempting password-based authentication." -f $targetNameForLog) -Level "INFO"
        } else {
            throw ("SFTP Target '{0}': No password secret or key file path secret provided for authentication." -f $targetNameForLog)
        }

        $sftpSession = New-SSHSession @sessionParams
        if (-not $sftpSession) { throw "Failed to establish SSH session." }
        $sftpSessionId = $sftpSession.SessionId
        & $LocalWriteLog -Message ("    - SFTP Target '{0}': SSH Session established (ID: {1})." -f $targetNameForLog, $sftpSessionId) -Level "SUCCESS"

        # Ensure remote directory exists
        if (-not (Test-SFTPPath -SessionId $sftpSessionId -Path $remoteFinalDirectory)) {
            & $LocalWriteLog -Message ("  - SFTP Target '{0}': Remote directory '{1}' not found. Attempting to create." -f $targetNameForLog, $remoteFinalDirectory) -Level "INFO"
            New-SFTPItem -SessionId $sftpSessionId -Path $remoteFinalDirectory -ItemType Directory -Force -ErrorAction Stop
            & $LocalWriteLog -Message ("    - SFTP Target '{0}': Remote directory '{1}' created or ensured." -f $targetNameForLog, $remoteFinalDirectory) -Level "SUCCESS"
        }

        # Upload file
        & $LocalWriteLog -Message ("  - SFTP Target '{0}': Uploading '{1}' to '{2}'..." -f $targetNameForLog, $LocalArchivePath, $fullRemoteArchivePath) -Level "INFO"
        Set-SFTPFile -SessionId $sftpSessionId -LocalFile $LocalArchivePath -RemoteFile $fullRemoteArchivePath -ErrorAction Stop
        $result.Success = $true
        $result.TransferSize = $LocalArchiveSizeBytes
        & $LocalWriteLog -Message ("    - SFTP Target '{0}': Archive uploaded successfully." -f $targetNameForLog) -Level "SUCCESS"

        # Remote Retention
        if ($TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings') -and `
            $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -is [int] -and `
            $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -gt 0) {
            
            $remoteKeepCount = $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount
            & $LocalWriteLog -Message ("  - SFTP Target '{0}': Applying remote retention (KeepCount: {1}) in '{2}'." -f $targetNameForLog, $remoteKeepCount, $remoteFinalDirectory) -Level "INFO"
            
            $literalBaseNameForRemote = $ArchiveBaseName
            $remoteFilePattern = "$($literalBaseNameForRemote)*$($ArchiveExtension)"

            $existingRemoteBackups = Get-SFTPChildItem -SessionId $sftpSessionId -Path $remoteFinalDirectory -ErrorAction SilentlyContinue |
                                     Where-Object { $_.Name -like $remoteFilePattern -and (-not $_.IsDirectory) } |
                                     Sort-Object LastWriteTime -Descending

            if (($null -ne $existingRemoteBackups) -and ($existingRemoteBackups.Count -gt $remoteKeepCount)) {
                $remoteBackupsToDelete = $existingRemoteBackups | Select-Object -Skip $remoteKeepCount
                & $LocalWriteLog -Message ("    - SFTP Target '{0}': Found {1} remote archives. Will delete {2} older ones." -f $targetNameForLog, $existingRemoteBackups.Count, $remoteBackupsToDelete.Count) -Level "INFO"
                foreach ($remoteFileObj in $remoteBackupsToDelete) {
                    $fileToDeletePath = "$remoteFinalDirectory/$($remoteFileObj.Name)"
                    if (-not $PSCmdlet.ShouldProcess($fileToDeletePath, "Delete Remote SFTP Archive (Retention)")) {
                        & $LocalWriteLog -Message ("      - SFTP Target '{0}': Deletion of '{1}' skipped by user." -f $targetNameForLog, $fileToDeletePath) -Level "WARNING"
                        continue
                    }
                    & $LocalWriteLog -Message ("      - SFTP Target '{0}': Deleting for retention: '{1}'" -f $targetNameForLog, $fileToDeletePath) -Level "WARNING"
                    try {
                        Remove-SFTPItem -SessionId $sftpSessionId -Path $fileToDeletePath -ErrorAction Stop
                        & $LocalWriteLog -Message "        - Status: DELETED (Remote SFTP Retention)" -Level "SUCCESS"
                    } catch {
                        & $LocalWriteLog -Message ("        - Status: FAILED to delete remote SFTP archive! Error: {0}" -f $_.Exception.Message) -Level "ERROR"
                        if ([string]::IsNullOrWhiteSpace($result.ErrorMessage)) { $result.ErrorMessage = "One or more SFTP retention deletions failed." }
                        else { $result.ErrorMessage += " Additionally, one or more SFTP retention deletions failed." }
                        $result.Success = $false
                    }
                }
            } else {
                & $LocalWriteLog -Message ("    - SFTP Target '{0}': No old remote archives to delete based on retention count {1}." -f $targetNameForLog, $remoteKeepCount) -Level "INFO"
            }
        }

    } catch {
        $result.ErrorMessage = "SFTP Target '$targetNameForLog': Operation failed. Error: $($_.Exception.Message)"
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"
        $result.Success = $false
    } finally {
        if ($sftpSessionId) {
            Remove-SSHSession -SessionId $sftpSessionId -ErrorAction SilentlyContinue
            & $LocalWriteLog -Message ("  - SFTP Target '{0}': SSH Session ID {1} closed." -f $targetNameForLog, $sftpSessionId) -Level "DEBUG"
        }
        if ($securePassword) { $securePassword.Dispose(); $securePassword = $null }
        if ($securePassphrase) { $securePassphrase.Dispose(); $securePassphrase = $null }
        $sftpPassword = $null; $sftpKeyPassphrase = $null
    }

    $stopwatch.Stop()
    $result.TransferDuration = $stopwatch.Elapsed
    & $LocalWriteLog -Message ("[INFO] SFTP Target: Finished transfer attempt for Job '{0}' to Target '{1}'. Overall Success for this Target: {2}." -f $JobName, $targetNameForLog, $result.Success) -Level "INFO"
    return $result
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupTargetTransfer
