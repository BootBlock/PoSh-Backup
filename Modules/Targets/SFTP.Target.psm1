# Modules\Targets\SFTP.Target.psm1
<#
.SYNOPSIS
    PoSh-Backup Target Provider for SFTP (SSH File Transfer Protocol).
    Handles transferring backup archives to SFTP servers, managing remote retention,
    and supporting various authentication methods via Posh-SSH and PowerShell SecretManagement.
    Now includes a function for validating its specific TargetSpecificSettings and RemoteRetentionSettings,
    and a new function for testing connectivity.

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
    - If 'RemoteRetentionSettings' (e.g., 'KeepCount') are defined, it applies a count-based
      retention policy to archives for the current job within the final remote directory.
    - Supports simulation mode for all SFTP operations.
    - Returns a detailed status hashtable.

    A function, 'Invoke-PoShBackupSFTPTargetSettingsValidation', validates the entire target configuration.
    A new function, 'Test-PoShBackupTargetConnectivity', validates the SFTP connection and path.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.3.0 # Refactored to use centralised Get-PoShBackupSecret utility.
    DateCreated:    22-May-2025
    LastModified:   23-Jun-2025
    Purpose:        SFTP Target Provider for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    The 'Posh-SSH' module must be installed (Install-Module Posh-SSH).
                    PowerShell SecretManagement configured if using secrets for credentials.
                    The user/account running PoSh-Backup must have appropriate network access
                    to the SFTP server and R/W/Delete permissions on the target remote path.
#>

#region --- Module Dependencies ---
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "SFTP.Target.psm1 FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}
#endregion

#region --- Private Helper: Group Remote SFTP Backup Instances ---
function Group-RemoteSFTPBackupInstancesInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$SftpSessionIdToUse,
        [Parameter(Mandatory = $true)]
        [string]$RemoteDirectoryToScan,
        [Parameter(Mandatory = $true)]
        [string]$BaseNameToMatch, # e.g., "JobName [DateStamp]"
        [Parameter(Mandatory = $true)]
        [string]$PrimaryArchiveExtension, # e.g., ".7z" (the one used for .001, .002, or the manifest base)
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    # PSSA Appeasement and initial log entry:
    & $Logger -Message "SFTP.Target/Group-RemoteSFTPBackupInstancesInternal: Logger active. Scanning '$RemoteDirectoryToScan' for base '$BaseNameToMatch', primary ext '$PrimaryArchiveExtension'." -Level "DEBUG" -ErrorAction SilentlyContinue

    # Define LocalWriteLog for subsequent use within this function if needed by other parts of it.
    # Looking at the previous version of the file, $LocalWriteLog was used multiple times in this function.
    $LocalWriteLog = { param([string]$Message, [string]$Level = "DEBUG") & $Logger -Message $Message -Level $Level }

    $instances = @{}
    $literalBase = [regex]::Escape($BaseNameToMatch) # e.g. "JobName \[DateStamp\]"
    $literalExt = [regex]::Escape($PrimaryArchiveExtension) # e.g. "\.7z"

    try {
        # Get all non-directory items from the remote path
        $remoteFileObjects = Get-SFTPChildItem -SessionId $SftpSessionIdToUse -Path $RemoteDirectoryToScan -ErrorAction Stop | Where-Object { -not $_.IsDirectory }

        if ($null -eq $remoteFileObjects) {
            & $LocalWriteLog -Message "SFTP.Target/GroupHelper: No files found in remote directory '$RemoteDirectoryToScan'."
            return $instances
        }

        foreach ($fileObject in $remoteFileObjects) {
            $fileName = $fileObject.Name
            $instanceKey = $null
            $fileSortTime = $fileObject.LastWriteTime # Posh-SSH SftpFile object has LastWriteTime

            $splitVolumePattern = "^($literalBase$literalExt)\.(\d{3,})$" # Matches "basename.priExt.001"
            $splitManifestPattern = "^($literalBase$literalExt)\.manifest\.[a-zA-Z0-9]+$" # Matches "basename.priExt.manifest.algo"
            $singleFilePattern = "^($literalBase$literalExt)$" # e.g. MyJob [DateStamp].7z (if $ArchiveExtension is .7z)
            $sfxFilePattern = "^($literalBase\.[a-zA-Z0-9]+)$" # Catches "JobName [DateStamp].exe" more broadly
            $sfxManifestPattern = "^($literalBase\.[a-zA-Z0-9]+)\.manifest\.[a-zA-Z0-9]+$" # Catches "JobName [DateStamp].exe.manifest.algo"


            if ($fileName -match $splitVolumePattern) {
                $instanceKey = $Matches[1]
            }
            elseif ($fileName -match $splitManifestPattern) {
                $instanceKey = $Matches[1]
            }
            elseif ($fileName -match $sfxManifestPattern) {
                $instanceKey = $Matches[1]
            }
            elseif ($fileName -match $singleFilePattern) {
                $instanceKey = $Matches[1]
            }
            elseif ($fileName -match $sfxFilePattern) {
                $instanceKey = $Matches[1]
            }
            else {
                if ($fileName.StartsWith($BaseNameToMatch)) {
                    $basePlusExtMatch = $fileName -match "^($literalBase(\.[^.\s]+)?)"
                    if ($basePlusExtMatch) {
                        $potentialKey = $Matches[1]
                        if ($fileName -match ([regex]::Escape($potentialKey) + "\.\d{3,}") -or `
                                $fileName -match ([regex]::Escape($potentialKey) + "\.manifest\.[a-zA-Z0-9]+$") -or `
                                $fileName -eq $potentialKey) {
                            $instanceKey = $potentialKey
                        }
                    }
                }
            }

            if ($null -eq $instanceKey) {
                & $LocalWriteLog -Message "SFTP.Target/GroupHelper: Could not determine instance key for remote file '$fileName'. Base: '$BaseNameToMatch', PrimaryExt: '$PrimaryArchiveExtension'. Skipping." -Level "VERBOSE"
                continue
            }

            if (-not $instances.ContainsKey($instanceKey)) {
                $instances[$instanceKey] = @{
                    SortTime = $fileSortTime # Initial sort time, will be refined
                    Files    = [System.Collections.Generic.List[object]]::new() # Store SFTP file objects
                }
            }
            $instances[$instanceKey].Files.Add($fileObject)

            if ($fileName -match "$literalExt\.001$") {
                if ($fileSortTime -lt $instances[$instanceKey].SortTime) {
                    $instances[$instanceKey].SortTime = $fileSortTime
                }
            }
        }

        foreach ($keyToRefine in $instances.Keys) {
            if ($instances[$keyToRefine].Files.Count -gt 0) {
                $firstVolumeFile = $instances[$keyToRefine].Files | Where-Object { $_.Name -match ([regex]::Escape($keyToRefine) + "\.001$") } | Sort-Object LastWriteTime | Select-Object -First 1
                if (-not $firstVolumeFile -and $keyToRefine.EndsWith($PrimaryArchiveExtension)) {
                    $firstVolumeFile = $instances[$keyToRefine].Files | Where-Object { $_.Name -eq $keyToRefine } | Sort-Object LastWriteTime | Select-Object -First 1
                }


                if ($firstVolumeFile) {
                    if ($firstVolumeFile.LastWriteTime -lt $instances[$keyToRefine].SortTime) {
                        $instances[$keyToRefine].SortTime = $firstVolumeFile.LastWriteTime
                    }
                }
                elseif ($instances[$keyToRefine].Files.Count -gt 0) {
                    $earliestFileInGroup = $instances[$keyToRefine].Files | Sort-Object LastWriteTime | Select-Object -First 1
                    if ($earliestFileInGroup -and $earliestFileInGroup.LastWriteTime -lt $instances[$keyToRefine].SortTime) {
                        $instances[$keyToRefine].SortTime = $earliestFileInGroup.LastWriteTime
                    }
                }
            }
        }

    }
    catch {
        & $LocalWriteLog -Message "SFTP.Target/GroupHelper: Error listing or processing files in '$RemoteDirectoryToScan'. Error: $($_.Exception.Message)" -Level "ERROR"
    }
    & $LocalWriteLog -Message "SFTP.Target/GroupHelper: Found $($instances.Keys.Count) distinct instances in '$RemoteDirectoryToScan' for base '$BaseNameToMatch'."
    return $instances
}
#endregion

#region --- SFTP Target Connectivity Test Function ---
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
    
    $sftpServer = $TargetSpecificSettings.SFTPServerAddress
    & $LocalWriteLog -Message "  - SFTP Target: Testing connectivity to server '$sftpServer'..." -Level "INFO"

    if (-not (Get-Module -Name Posh-SSH -ListAvailable)) {
        return @{ Success = $false; Message = "Posh-SSH module is not installed. Please install it using 'Install-Module Posh-SSH'." }
    }
    Import-Module Posh-SSH -ErrorAction SilentlyContinue
    
    $sftpSessionId = $null
    $securePassphrase = $null
    $securePassword = $null
    
    try {
        $sessionParams = @{
            ComputerName = $sftpServer
            Port         = if ($TargetSpecificSettings.ContainsKey('SFTPPort')) { $TargetSpecificSettings.SFTPPort } else { 22 }
            Username     = $TargetSpecificSettings.SFTPUserName
            ErrorAction  = 'Stop'
        }
        if ($TargetSpecificSettings.ContainsKey('SkipHostKeyCheck') -and $TargetSpecificSettings.SkipHostKeyCheck -eq $true) {
            $sessionParams.AcceptKey = $true
        }

        $sftpPassword = Get-PoShBackupSecret -SecretName $TargetSpecificSettings.SFTPPasswordSecretName -Logger $Logger -AsPlainText -SecretPurposeForLog "SFTP Password"
        $sftpKeyFilePath = Get-PoShBackupSecret -SecretName $TargetSpecificSettings.SFTPKeyFileSecretName -Logger $Logger -AsPlainText -SecretPurposeForLog "SFTP Key File Path"
        $sftpKeyPassphrase = Get-PoShBackupSecret -SecretName $TargetSpecificSettings.SFTPKeyFilePassphraseSecretName -Logger $Logger -AsPlainText -SecretPurposeForLog "SFTP Key Passphrase"
        
        if (-not [string]::IsNullOrWhiteSpace($sftpKeyFilePath)) {
            if (-not (Test-Path -LiteralPath $sftpKeyFilePath -PathType Leaf)) { throw "SFTP Key File not found at path '$sftpKeyFilePath'." }
            $sessionParams.KeyFile = $sftpKeyFilePath
            if (-not [string]::IsNullOrWhiteSpace($sftpKeyPassphrase)) {
                $securePassphrase = ConvertTo-SecureString -String $sftpKeyPassphrase -AsPlainText -Force
                $sessionParams.KeyPassphrase = $securePassphrase
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($sftpPassword)) {
            $securePassword = ConvertTo-SecureString -String $sftpPassword -AsPlainText -Force
            $sessionParams.Password = $securePassword
        }
        else {
            throw "No password secret or key file path secret provided for authentication."
        }

        if (-not $PSCmdlet.ShouldProcess($sftpServer, "Establish SFTP Test Connection")) {
            return @{ Success = $false; Message = "SFTP connection test skipped by user." }
        }

        $sftpSession = New-SSHSession @sessionParams
        if (-not $sftpSession) { throw "Failed to establish SSH session." }
        $sftpSessionId = $sftpSession.SessionId

        & $LocalWriteLog -Message "    - SUCCESS: SFTP session established successfully (Session ID: $sftpSessionId)." -Level "SUCCESS"

        $remotePath = $TargetSpecificSettings.SFTPRemotePath
        & $LocalWriteLog -Message "  - SFTP Target: Testing remote path '$remotePath'..." -Level "INFO"
        if (Test-SFTPPath -SessionId $sftpSessionId -Path $remotePath) {
            & $LocalWriteLog -Message "    - SUCCESS: Remote path '$remotePath' exists." -Level "SUCCESS"
            return @{ Success = $true; Message = "Connection successful and remote path exists." }
        }
        else {
            return @{ Success = $false; Message = "Connection successful, but remote path '$remotePath' does not exist." }
        }
    }
    catch {
        $errorMessage = "SFTP connection test failed. Error: $($_.Exception.Message)"
        & $LocalWriteLog -Message "    - FAILED: $errorMessage" -Level "ERROR"
        return @{ Success = $false; Message = $errorMessage }
    }
    finally {
        if ($sftpSessionId) { Remove-SSHSession -SessionId $sftpSessionId -ErrorAction SilentlyContinue }
        if ($securePassword) { $securePassword.Dispose() }
        if ($securePassphrase) { $securePassphrase.Dispose() }
    }
}
#endregion

#region --- SFTP Target Settings Validation Function ---
function Invoke-PoShBackupSFTPTargetSettingsValidation {
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
        & $Logger -Message "SFTP.Target/Invoke-PoShBackupSFTPTargetSettingsValidation: Logger active. Validating settings for SFTP Target '$TargetInstanceName'." -Level "DEBUG" -ErrorAction SilentlyContinue
    }
    
    # --- NEW: Extract settings from the main instance configuration ---
    $TargetSpecificSettings = $TargetInstanceConfiguration.TargetSpecificSettings
    $RemoteRetentionSettings = $TargetInstanceConfiguration.RemoteRetentionSettings
    # --- END NEW ---

    $fullPathToSettings = "Configuration.BackupTargets.$TargetInstanceName.TargetSpecificSettings"
    $fullPathToRetentionSettings = "Configuration.BackupTargets.$TargetInstanceName.RemoteRetentionSettings"

    if (-not ($TargetSpecificSettings -is [hashtable])) {
        $ValidationMessagesListRef.Value.Add("SFTP Target '$TargetInstanceName': 'TargetSpecificSettings' must be a Hashtable, but found type '$($TargetSpecificSettings.GetType().Name)'. Path: '$fullPathToSettings'.")
        return
    }

    foreach ($sftpKey in @('SFTPServerAddress', 'SFTPRemotePath', 'SFTPUserName')) {
        if (-not $TargetSpecificSettings.ContainsKey($sftpKey) -or -not ($TargetSpecificSettings.$sftpKey -is [string]) -or [string]::IsNullOrWhiteSpace($TargetSpecificSettings.$sftpKey)) {
            $ValidationMessagesListRef.Value.Add("SFTP Target '$TargetInstanceName': '$sftpKey' in 'TargetSpecificSettings' is missing, not a string, or empty. Path: '$fullPathToSettings.$sftpKey'.")
        }
    }

    if ($TargetSpecificSettings.ContainsKey('SFTPPort') -and -not ($TargetSpecificSettings.SFTPPort -is [int] -and $TargetSpecificSettings.SFTPPort -gt 0 -and $TargetSpecificSettings.SFTPPort -le 65535)) {
        $ValidationMessagesListRef.Value.Add("SFTP Target '$TargetInstanceName': 'SFTPPort' in 'TargetSpecificSettings' must be an integer between 1 and 65535 if defined. Path: '$fullPathToSettings.SFTPPort'.")
    }

    foreach ($sftpOptionalStringKey in @('SFTPPasswordSecretName', 'SFTPKeyFileSecretName', 'SFTPKeyFilePassphraseSecretName')) {
        if ($TargetSpecificSettings.ContainsKey($sftpOptionalStringKey) -and (-not ($TargetSpecificSettings.$sftpOptionalStringKey -is [string]) -or [string]::IsNullOrWhiteSpace($TargetSpecificSettings.$sftpOptionalStringKey)) ) {
            $ValidationMessagesListRef.Value.Add("SFTP Target '$TargetInstanceName': '$sftpOptionalStringKey' in 'TargetSpecificSettings' must be a non-empty string if defined. Path: '$fullPathToSettings.$sftpOptionalStringKey'.")
        }
    }

    foreach ($sftpOptionalBoolKey in @('CreateJobNameSubdirectory', 'SkipHostKeyCheck')) {
        if ($TargetSpecificSettings.ContainsKey($sftpOptionalBoolKey) -and -not ($TargetSpecificSettings.$sftpOptionalBoolKey -is [boolean])) {
            $ValidationMessagesListRef.Value.Add("SFTP Target '$TargetInstanceName': '$sftpOptionalBoolKey' in 'TargetSpecificSettings' must be a boolean (`$true` or `$false`) if defined. Path: '$fullPathToSettings.$sftpOptionalBoolKey'.")
        }
    }

    # Validate RemoteRetentionSettings for SFTP
    if ($null -ne $RemoteRetentionSettings) {
        if (-not ($RemoteRetentionSettings -is [hashtable])) {
            $ValidationMessagesListRef.Value.Add("SFTP Target '$TargetInstanceName': 'RemoteRetentionSettings' must be a Hashtable if defined. Path: '$fullPathToRetentionSettings'.")
        }
        elseif ($RemoteRetentionSettings.ContainsKey('KeepCount')) {
            if (-not ($RemoteRetentionSettings.KeepCount -is [int]) -or $RemoteRetentionSettings.KeepCount -le 0) {
                $ValidationMessagesListRef.Value.Add("SFTP Target '$TargetInstanceName': 'RemoteRetentionSettings.KeepCount' must be an integer greater than 0 if defined. Path: '$fullPathToRetentionSettings.KeepCount'.")
            }
        }
    }
}
#endregion

#region --- SFTP Target Transfer Function ---
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

    # Defensive PSSA appeasement
    & $Logger -Message "SFTP.Target/Invoke-PoShBackupTargetTransfer: Logger active for Job '$JobName', Target '$($TargetInstanceConfiguration._TargetInstanceName_)'." -Level "DEBUG" -ErrorAction SilentlyContinue
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

    $sftpPassword = Get-PoShBackupSecret -SecretName $sftpSettings.SFTPPasswordSecretName -Logger $Logger -AsPlainText -SecretPurposeForLog "SFTP Password"
    $sftpKeyFilePathOnLocalMachine = Get-PoShBackupSecret -SecretName $sftpSettings.SFTPKeyFileSecretName -Logger $Logger -AsPlainText -SecretPurposeForLog "SFTP Key File Path"
    $sftpKeyPassphrase = Get-PoShBackupSecret -SecretName $sftpSettings.SFTPKeyFilePassphraseSecretName -Logger $Logger -AsPlainText -SecretPurposeForLog "SFTP Key Passphrase"

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
        $authMethod = if ($sftpKeyFilePathOnLocalMachine) { "a key file" } elseif ($sftpPassword) { "a password" } else { "an unknown method" }
        $simMessage = "SIMULATE: An SFTP connection would be established to '$sftpServer' as user '$sftpUser' using $authMethod. "
        $simMessage += "The remote directory '$remoteFinalDirectory' would be created if it does not exist. "
        $simMessage += "The archive file '$ArchiveFileName' would then be uploaded to '$fullRemoteArchivePath'."
        & $LocalWriteLog -Message $simMessage -Level "SIMULATE"

        if ($TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings') -and $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -gt 0) {
            $retentionKeepCount = $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount
            & $LocalWriteLog -Message "SIMULATE: After the upload, the retention policy (Keep: $retentionKeepCount) would be applied to the remote directory '$remoteFinalDirectory'." -Level "SIMULATE"
        }
        
        $result.Success = $true
        $result.TransferSize = $LocalArchiveSizeBytes
        $result.TransferSizeFormatted = Format-FileSize -Bytes $result.TransferSize
        $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed
        return $result
    }

    # --- Actual SFTP Operations ---
    if (-not $PSCmdlet.ShouldProcess(("SFTP Server: {0} (Path: {1})" -f $sftpServer, $fullRemoteArchivePath), "Transfer Archive via SFTP")) {
        $result.ErrorMessage = "SFTP Target '$targetNameForLog': Transfer to '$fullRemoteArchivePath' skipped by user (ShouldProcess)."
        & $LocalWriteLog -Message "[WARNING] $($result.ErrorMessage)" -Level "WARNING"
        $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed
        return $result
    }

    $securePassphrase = $null
    $securePassword = $null
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
                # PSScriptAnalyzer Suppress PSAvoidUsingConvertToSecureStringWithPlainText - Posh-SSH cmdlet requires SecureString. Passphrase is from secure storage.
                $securePassphrase = ConvertTo-SecureString -String $sftpKeyPassphrase -AsPlainText -Force
                $sessionParams.KeyPassphrase = $securePassphrase
            }
            & $LocalWriteLog -Message ("  - SFTP Target '{0}': Attempting key-based authentication." -f $targetNameForLog) -Level "INFO"
        }
        elseif (-not [string]::IsNullOrWhiteSpace($sftpPassword)) {
            # PSScriptAnalyzer Suppress PSAvoidUsingConvertToSecureStringWithPlainText - Posh-SSH cmdlet requires SecureString. Password is from secure storage.
            $securePassword = ConvertTo-SecureString -String $sftpPassword -AsPlainText -Force
            $sessionParams.Password = $securePassword
            & $LocalWriteLog -Message ("  - SFTP Target '{0}': Attempting password-based authentication." -f $targetNameForLog) -Level "INFO"
        }
        else {
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
            
            try {
                $remoteInstances = Group-RemoteSFTPBackupInstancesInternal -SftpSessionIdToUse $sftpSessionId `
                    -RemoteDirectoryToScan $remoteFinalDirectory `
                    -BaseNameToMatch $ArchiveBaseName `
                    -PrimaryArchiveExtension $ArchiveExtension `
                    -Logger $Logger

                if ($remoteInstances.Count -gt $remoteKeepCount) {
                    $sortedInstances = $remoteInstances.GetEnumerator() | Sort-Object { $_.Value.SortTime } -Descending
                    $instancesToDelete = $sortedInstances | Select-Object -Skip $remoteKeepCount
                    & $LocalWriteLog -Message ("    - SFTP Target '{0}': Found {1} remote instances. Will delete files for {2} older instance(s)." -f $targetNameForLog, $remoteInstances.Count, $instancesToDelete.Count) -Level "INFO"
                    foreach ($instanceEntry in $instancesToDelete) {
                        $instanceIdentifier = $instanceEntry.Name
                        & $LocalWriteLog "      - SFTP Target '{0}': Preparing to delete instance files for '$instanceIdentifier' (SortTime: $($instanceEntry.Value.SortTime))." -Level "WARNING"
                        foreach ($remoteFileObjInInstance in $instanceEntry.Value.Files) {
                            $fileToDeletePathOnSftp = "$remoteFinalDirectory/$($remoteFileObjInInstance.Name)"
                            if (-not $PSCmdlet.ShouldProcess($fileToDeletePathOnSftp, "Delete Remote SFTP File/Part (Retention)")) {
                                & $LocalWriteLog -Message ("        - Deletion of '{0}' skipped by user." -f $fileToDeletePathOnSftp) -Level "WARNING"; continue
                            }
                            & $LocalWriteLog -Message ("        - Deleting: '{0}' (LastWriteTime: $($remoteFileObjInInstance.LastWriteTime))" -f $fileToDeletePathOnSftp) -Level "WARNING"
                            try {
                                Remove-SFTPItem -SessionId $sftpSessionId -Path $fileToDeletePathOnSftp -ErrorAction Stop
                                & $LocalWriteLog "          - Status: DELETED" -Level "SUCCESS"
                            }
                            catch {
                                $retentionErrorMsg = "Failed to delete remote SFTP file '$fileToDeletePathOnSftp' for instance '$instanceIdentifier' during retention. Error: $($_.Exception.Message)"
                                & $LocalWriteLog "          - Status: FAILED! $retentionErrorMsg" -Level "ERROR"
                                if ([string]::IsNullOrWhiteSpace($result.ErrorMessage)) { $result.ErrorMessage = $retentionErrorMsg }
                                else { $result.ErrorMessage += "; $retentionErrorMsg" }
                            }
                        }
                    }
                }
                else {
                    & $LocalWriteLog ("    - SFTP Target '{0}': No old instances to delete based on retention count {1} (Found: $($remoteInstances.Count))." -f $targetNameForLog, $remoteKeepCount) -Level "INFO"
                }
            }
            catch {
                $retError = "Error during SFTP remote retention execution: $($_.Exception.Message)"
                & $LocalWriteLog "[WARNING] SFTP Target '$targetNameForLog': $retError" -Level "WARNING"
                if ([string]::IsNullOrWhiteSpace($result.ErrorMessage)) { $result.ErrorMessage = $retError } else { $result.ErrorMessage += "; $retError" }
            }
        }

    }
    catch {
        $result.ErrorMessage = "SFTP Target '$targetNameForLog': Operation failed. Error: $($_.Exception.Message)"
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"; $result.Success = $false
    }
    finally {
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
    $result.TransferSizeFormatted = Format-FileSize -Bytes $result.TransferSize
    & $LocalWriteLog -Message ("[INFO] SFTP Target: Finished transfer attempt for Job '{0}' to Target '{1}', File '{2}'. Success: {3}." -f $JobName, $targetNameForLog, $ArchiveFileName, $result.Success) -Level "INFO"
    return $result
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupTargetTransfer, Invoke-PoShBackupSFTPTargetSettingsValidation, Test-PoShBackupTargetConnectivity
