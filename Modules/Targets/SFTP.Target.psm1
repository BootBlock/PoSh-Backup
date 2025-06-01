# Modules\Targets\SFTP.Target.psm1
<#
.SYNOPSIS
    PoSh-Backup Target Provider for SFTP (SSH File Transfer Protocol).
    Handles transferring backup archives to SFTP servers, managing remote retention,
    and supporting various authentication methods via Posh-SSH and PowerShell SecretManagement.
    Now includes a function for validating its specific TargetSpecificSettings and RemoteRetentionSettings.

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

    A new function, 'Invoke-PoShBackupSFTPTargetSettingsValidation', is now included to validate
    the 'TargetSpecificSettings' and 'RemoteRetentionSettings' specific to this SFTP provider.
    This function is intended to be called by the PoShBackupValidator module.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.7 # Replication manifest thing
    DateCreated:    22-May-2025
    LastModified:   27-May-2025
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
        [Parameter(Mandatory = $true)]
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
            }
            elseif ($secretValue.Secret -is [string]) {
                return $secretValue.Secret
            }
            else {
                & $LocalWriteLog -Message ("[WARNING] GetSecret: Secret '{0}' for {1} was retrieved but is not a SecureString or String. Type: {2}." -f $SecretName, $SecretPurposeForLog, $secretValue.Secret.GetType().FullName) -Level "WARNING"
                return $null
            }
        }
    }
    catch {
        & $LocalWriteLog -Message ("[ERROR] GetSecret: Failed to retrieve secret '{0}' for {1}. Error: {2}" -f $SecretName, $SecretPurposeForLog, $_.Exception.Message) -Level "ERROR"
    }
    return $null
}
#endregion

#region --- SFTP Target Settings Validation Function ---
function Invoke-PoShBackupSFTPTargetSettingsValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$TargetSpecificSettings,
        [Parameter(Mandatory = $true)]
        [string]$TargetInstanceName,
        [Parameter(Mandatory = $true)]
        [ref]$ValidationMessagesListRef, # Expects a [System.Collections.Generic.List[string]]
        [Parameter(Mandatory = $false)]
        [hashtable]$RemoteRetentionSettings, # Added to validate retention settings
        [Parameter(Mandatory = $false)]
        [scriptblock]$Logger
    )

    if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) {
        & $Logger -Message "SFTP.Target/Invoke-PoShBackupSFTPTargetSettingsValidation: Validating settings for SFTP Target '$TargetInstanceName'." -Level "DEBUG"
    }

    $fullPathToSettings = "Configuration.BackupTargets.$TargetInstanceName.TargetSpecificSettings"
    $fullPathToRetentionSettings = "Configuration.BackupTargets.$TargetInstanceName.RemoteRetentionSettings"

    if (-not ($TargetSpecificSettings -is [hashtable])) {
        $ValidationMessagesListRef.Value.Add("SFTP Target '$TargetInstanceName': 'TargetSpecificSettings' must be a Hashtable, but found type '$($TargetSpecificSettings.GetType().Name)'. Path: '$fullPathToSettings'.")
        return # Cannot proceed if the main settings block is not a hashtable
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
    if ($PSBoundParameters.ContainsKey('RemoteRetentionSettings') -and ($null -ne $RemoteRetentionSettings)) {
        if (-not ($RemoteRetentionSettings -is [hashtable])) {
            $ValidationMessagesListRef.Value.Add("SFTP Target '$TargetInstanceName': 'RemoteRetentionSettings' must be a Hashtable if defined. Path: '$fullPathToRetentionSettings'.")
        }
        elseif ($RemoteRetentionSettings.ContainsKey('KeepCount')) {
            if (-not ($RemoteRetentionSettings.KeepCount -is [int]) -or $RemoteRetentionSettings.KeepCount -le 0) {
                $ValidationMessagesListRef.Value.Add("SFTP Target '$TargetInstanceName': 'RemoteRetentionSettings.KeepCount' must be an integer greater than 0 if defined. Path: '$fullPathToRetentionSettings.KeepCount'.")
            }
        }
        # Add checks for other RemoteRetentionSettings keys if they are introduced for SFTP
    }
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
    $LocalWriteLog = { param([string]$Message, [string]$Level = "DEBUG") & $Logger -Message $Message -Level $Level }
    & $LocalWriteLog -Message "SFTP.Target/Group-RemoteSFTPBackupInstancesInternal: Scanning '$RemoteDirectoryToScan' for base '$BaseNameToMatch', primary ext '$PrimaryArchiveExtension'."

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

            # Define patterns to identify parts of a backup instance
            # Instance key should be "JobName [DateStamp].<PrimaryExtension>" e.g., "MyJob [2025-06-01].7z"
            
            $splitVolumePattern = "^($literalBase$literalExt)\.(\d{3,})$" # Matches "basename.priExt.001"
            $splitManifestPattern = "^($literalBase$literalExt)\.manifest\.[a-zA-Z0-9]+$" # Matches "basename.priExt.manifest.algo"
            
            # For single files, the instance key is "basename.actualFileExtension"
            # This needs to handle cases where PrimaryArchiveExtension (e.g. .7z for split) might differ from actual file (e.g. .exe for SFX)
            # $ArchiveBaseName is "JobName [DateStamp]"
            # $ArchiveExtension (PrimaryArchiveExtension here) is the one from job config (e.g. .7z or .exe)
            $singleFilePattern = "^($literalBase$literalExt)$" # e.g. MyJob [DateStamp].7z (if $ArchiveExtension is .7z)
            $sfxFilePattern = "^($literalBase\.[a-zA-Z0-9]+)$" # Catches "JobName [DateStamp].exe" more broadly
            $sfxManifestPattern = "^($literalBase\.[a-zA-Z0-9]+)\.manifest\.[a-zA-Z0-9]+$" # Catches "JobName [DateStamp].exe.manifest.algo"


            if ($fileName -match $splitVolumePattern) {
                # e.g., MyJob [DateStamp].7z.001
                $instanceKey = $Matches[1] # "MyJob [DateStamp].7z"
            }
            elseif ($fileName -match $splitManifestPattern) {
                # e.g., MyJob [DateStamp].7z.manifest.sha256
                $instanceKey = $Matches[1] # "MyJob [DateStamp].7z"
            }
            elseif ($fileName -match $sfxManifestPattern) {
                # e.g., MyJob [DateStamp].exe.manifest.sha256
                $instanceKey = $Matches[1] # This would be "MyJob [DateStamp].exe"
            }
            elseif ($fileName -match $singleFilePattern) {
                # e.g., MyJob [DateStamp].7z or MyJob [DateStamp].exe (if $ArchiveExtension matches)
                $instanceKey = $Matches[1]
            }
            elseif ($fileName -match $sfxFilePattern) {
                # e.g. MyJob [DateStamp].exe (if $ArchiveExtension was different, like .7z)
                $instanceKey = $Matches[1] # "MyJob [DateStamp].exe"
            }
            else {
                # Fallback if it starts with BaseNameToMatch but doesn't fit common patterns
                if ($fileName.StartsWith($BaseNameToMatch)) {
                    # Try to construct a key like "JobName [DateStamp].actualExt"
                    # This regex tries to capture up to the first dot after BaseNameToMatch that isn't part of a common multi-part like ".7z.001"
                    $basePlusExtMatch = $fileName -match "^($literalBase(\.[^.\s]+)?)" 
                    if ($basePlusExtMatch) {
                        $potentialKey = $Matches[1]
                        # If this potential key, when used to check for .001, matches the filename, it's likely a split set base
                        if ($fileName -match ([regex]::Escape($potentialKey) + "\.\d{3,}")) {
                            $instanceKey = $potentialKey
                        }
                        elseif ($fileName -match ([regex]::Escape($potentialKey) + "\.manifest\.[a-zA-Z0-9]+$")) {
                            $instanceKey = $potentialKey
                        }
                        elseif ($fileName -eq $potentialKey) {
                            # Exact match
                            $instanceKey = $potentialKey
                        }
                    }
                }
            }
            
            if ($null -eq $instanceKey) {
                & $LocalWriteLog -Message "SFTP.Target/GroupHelper: Could not determine instance key for remote file '$fileName'. Base: '$BaseNameToMatch', PrimaryExt: '$PrimaryArchiveExtension'. Skipping." -Level "VERBOSE"
                continue # Skips to the next file in $remoteFileObjects
            }

            if (-not $instances.ContainsKey($instanceKey)) {
                $instances[$instanceKey] = @{
                    SortTime = $fileSortTime # Initial sort time, will be refined
                    Files    = [System.Collections.Generic.List[object]]::new() # Store SFTP file objects
                }
            }
            $instances[$instanceKey].Files.Add($fileObject)

            # Refine SortTime: if it's a .001 part, its LastWriteTime is authoritative for the instance.
            # The PrimaryArchiveExtension is used here to correctly identify the first volume part.
            if ($fileName -match "$literalExt\.001$") { 
                if ($fileSortTime -lt $instances[$instanceKey].SortTime) {
                    $instances[$instanceKey].SortTime = $fileSortTime
                }
            }
        }
        
        # Second pass to refine sort times for instances that didn't have a .001 part explicitly found first
        # or if the first file encountered wasn't the .001 part.
        foreach ($keyToRefine in $instances.Keys) {
            if ($instances[$keyToRefine].Files.Count -gt 0) {
                # Try to find the .001 file specifically for this instance's primary extension
                $firstVolumeFile = $instances[$keyToRefine].Files | Where-Object { $_.Name -match ([regex]::Escape($keyToRefine) + "\.001$") } | Sort-Object LastWriteTime | Select-Object -First 1
                if (-not $firstVolumeFile -and $keyToRefine.EndsWith($PrimaryArchiveExtension)) {
                    # If key IS primary ext, and no .001, it might be a single file or .001 is missing
                    $firstVolumeFile = $instances[$keyToRefine].Files | Where-Object { $_.Name -eq $keyToRefine } | Sort-Object LastWriteTime | Select-Object -First 1
                }


                if ($firstVolumeFile) {
                    # Always prefer .001's time if present and it's earlier
                    if ($firstVolumeFile.LastWriteTime -lt $instances[$keyToRefine].SortTime) {
                        $instances[$keyToRefine].SortTime = $firstVolumeFile.LastWriteTime
                    }
                }
                else {
                    # If no .001 part, use the LastWriteTime of the earliest file in the group
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

            # $literalBaseNameForRemote = $ArchiveBaseName
            # $remoteFilePattern = "$($literalBaseNameForRemote)*$($ArchiveExtension)"

            # $existingRemoteBackups = Get-SFTPChildItem -SessionId $sftpSessionId -Path $remoteFinalDirectory -ErrorAction SilentlyContinue |
            # Where-Object { $_.Name -like $remoteFilePattern -and (-not $_.IsDirectory) } |
            # Sort-Object LastWriteTime -Descending

            if ($IsSimulateMode.IsPresent) {
                & $LocalWriteLog -Message ("SIMULATE: SFTP Target '{0}': Would scan '{1}', group instances by base '{2}' (primary ext '{3}'), sort, and delete oldest instances' files exceeding {4}." -f $targetNameForLog, $remoteFinalDirectoryForJob, $ArchiveBaseName, $ArchiveExtension, $remoteKeepCount) -Level "SIMULATE"
            }
            elseif ($sftpSessionIdForThisFileTransfer) {
                # Only run if session was established for the file transfer
                try {
                    # $ArchiveBaseName is "JobName [DateStamp]"
                    # $ArchiveExtension is the primary extension (e.g. .7z or .exe for SFX)
                    $remoteInstances = Group-RemoteSFTPBackupInstancesInternal -SftpSessionIdToUse $sftpSessionIdForThisFileTransfer -RemoteDirectoryToScan $remoteFinalDirectoryForJob -BaseNameToMatch $ArchiveBaseName -PrimaryArchiveExtension $ArchiveExtension -Logger $Logger
            
                    if ($remoteInstances.Count -gt $remoteKeepCount) {
                        $sortedInstances = $remoteInstances.GetEnumerator() | Sort-Object { $_.Value.SortTime } -Descending # Posh-SSH uses LastWriteTime, which our helper maps to SortTime
                        $instancesToDelete = $sortedInstances | Select-Object -Skip $remoteKeepCount
                
                        & $LocalWriteLog -Message ("    - SFTP Target '{0}': Found {1} remote instances. Will delete files for {2} older instance(s)." -f $targetNameForLog, $remoteInstances.Count, $instancesToDelete.Count) -Level "INFO"
                
                        foreach ($instanceEntry in $instancesToDelete) {
                            $instanceIdentifier = $instanceEntry.Name # This is the instance key, e.g., "JobName [DateStamp].7z"
                            & $LocalWriteLog -Message "      - SFTP Target '{0}': Preparing to delete instance files for '$instanceIdentifier' (SortTime: $($instanceEntry.Value.SortTime)) from '$remoteFinalDirectoryForJob'." -Level "WARNING"
                            foreach ($remoteFileObjInInstance in $instanceEntry.Value.Files) {
                                # $remoteFileObjInInstance is an SFTP file object
                                $fileToDeletePathOnSftp = "$remoteFinalDirectoryForJob/$($remoteFileObjInInstance.Name)"
                                if (-not $PSCmdlet.ShouldProcess($fileToDeletePathOnSftp, "Delete Remote SFTP File/Part (Retention)")) {
                                    & $LocalWriteLog -Message ("        - Deletion of '{0}' skipped by user." -f $fileToDeletePathOnSftp) -Level "WARNING"; continue
                                }
                                & $LocalWriteLog -Message ("        - Deleting: '{0}' (LastWriteTime: $($remoteFileObjInInstance.LastWriteTime))" -f $fileToDeletePathOnSftp) -Level "WARNING"
                                try { 
                                    Remove-SFTPItem -SessionId $sftpSessionIdForThisFileTransfer -Path $fileToDeletePathOnSftp -ErrorAction Stop
                                    & $LocalWriteLog "          - Status: DELETED" -Level "SUCCESS" 
                                }
                                catch { 
                                    & $LocalWriteLog "          - Status: FAILED to delete! Error: $($_.Exception.Message)" -Level "ERROR"
                                    # Decide if this individual file deletion failure should mark the overall transfer as failed
                                    # For now, we'll log it but not change $result.Success for the current file transfer
                                    # However, we should note the error in the aggregated error messages.
                                    $retentionDeleteError = "Failed to delete remote SFTP file '$fileToDeletePathOnSftp' for instance '$instanceIdentifier' during retention. Error: $($_.Exception.Message)"
                                    if ([string]::IsNullOrWhiteSpace($result.ErrorMessage)) { $result.ErrorMessage = $retentionDeleteError }
                                    else { $result.ErrorMessage += "; $retentionDeleteError" }
                                    # Consider if $result.Success for the *current file transfer* should be set to $false here.
                                    # If retention of *old* files fails, it doesn't mean the *current* upload failed.
                                    # However, it does mean the overall state of the target is not ideal.
                                    # For now, let's not set $result.Success to $false for the current file transfer due to old retention failure.
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
            elseif (-not $IsSimulateMode.IsPresent) {
                # This elseif corresponds to: if ($sftpSessionIdForThisFileTransfer)
                & $LocalWriteLog -Message ("  - SFTP Target '{0}': Skipping remote retention for file '$ArchiveFileName' as SFTP session was not established or current file transfer failed." -f $targetNameForLog) -Level "WARNING"
            }

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
                    }
                    catch {
                        & $LocalWriteLog -Message ("        - Status: FAILED to delete remote SFTP archive! Error: {0}" -f $_.Exception.Message) -Level "ERROR"
                        if ([string]::IsNullOrWhiteSpace($result.ErrorMessage)) { $result.ErrorMessage = "One or more SFTP retention deletions failed." }
                        else { $result.ErrorMessage += " Additionally, one or more SFTP retention deletions failed." }
                        $result.Success = $false
                    }
                }
            }
            else {
                & $LocalWriteLog -Message ("    - SFTP Target '{0}': No old remote archives to delete based on retention count {1}." -f $targetNameForLog, $remoteKeepCount) -Level "INFO"
            }
        }

    }
    catch {
        $result.ErrorMessage = "SFTP Target '$targetNameForLog': Operation failed. Error: $($_.Exception.Message)"
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"
        $result.Success = $false
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
    & $LocalWriteLog -Message ("[INFO] SFTP Target: Finished transfer attempt for Job '{0}' to Target '{1}'. Overall Success for this Target: {2}." -f $JobName, $targetNameForLog, $result.Success) -Level "INFO"
    return $result
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupTargetTransfer, Invoke-PoShBackupSFTPTargetSettingsValidation
