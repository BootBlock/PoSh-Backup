# PowerShell Data File for PoSh Backup Script Configuration (Default).
# --> THIS WILL GET OVERWRITTEN ON UPGRADE if you do not use a User.psd1 file for your customisations! <--
# It is strongly recommended to copy this file to 'User.psd1' in the same 'Config' directory
# and make all your modifications there. User.psd1 will override these defaults.
#
# Version 1.3.6: Added Checksum Generation & Verification settings.
@{
    #region --- Password Management Instructions ---
    # To protect your archives with a password, choose ONE method per job by setting 'ArchivePasswordMethod'.
    #
    # Available 'ArchivePasswordMethod' values:
    #   "None"             : (Default) No password will be used for the archive.
    #   "Interactive"      : Prompts the user for credentials via a standard PowerShell Get-Credential dialogue.
    #                        - Optional: Use 'CredentialUserNameHint' within the job settings to pre-fill the username in the prompt.
    #   "SecretManagement" : (RECOMMENDED FOR AUTOMATED/SCHEDULED TASKS) Retrieves the password from PowerShell SecretManagement.
    #                        This is a secure way to store and retrieve secrets.
    #                        Requires:
    #                          - 'ArchivePasswordSecretName': The name of the secret as stored in your SecretManagement vault.
    #                          - Optional: 'ArchivePasswordVaultName': The name of the SecretManagement vault. If omitted, the default registered vault is used.
    #                        Setup: You need the 'Microsoft.PowerShell.SecretManagement' module and a vault provider module (e.g., 'Microsoft.PowerShell.SecretStore') installed and configured.
    #                               Refer to PowerShell documentation for 'Register-SecretVault' and 'Set-Secret'.
    #   "SecureStringFile" : Reads a password from an encrypted file. The file must have been created by exporting a SecureString object using Export-CliXml.
    #                        Requires:
    #                          - 'ArchivePasswordSecureStringPath': The full path to the .clixml file containing the encrypted SecureString.
    #                        To create the file:
    #                           $SecurePass = Read-Host -AsSecureString "Enter password for archive:"
    #                           $SecurePass | Export-CliXml -Path "C:\path\to\your\passwordfile.clixml"
    #                        Note: This file is encrypted using Windows Data Protection API (DPAPI) and is typically only decryptable by the same user account on the same computer.
    #   "PlainText"        : (HIGHLY DISCOURAGED - INSECURE) Reads the password directly as plain text from this configuration file.
    #                        Requires:
    #                          - 'ArchivePasswordPlainText': The actual password string.
    #                        WARNING: Storing passwords in plain text is a significant security risk. Use this method only if you fully understand the implications and in environments where security is not a primary concern.
    #
    # How it works:
    # - If a password method other than "None" is chosen, 7-Zip's header encryption switch (-mhe=on) is automatically added to protect archive metadata.
    # - The script securely obtains the password (if applicable), writes it to a temporary file, and instructs 7-Zip to read the password from this file using its -spf switch.
    # - This temporary password file is deleted immediately after the 7-Zip process exits, minimising exposure.
    #
    # Legacy Setting 'UsePassword':
    # - The older setting 'UsePassword = $true' is still recognised for backward compatibility.
    # - If 'ArchivePasswordMethod' is "None" (or not set) AND 'UsePassword' is $true, the script will default to the "Interactive" method.
    # - It is recommended to explicitly use 'ArchivePasswordMethod' for clarity and future compatibility.
    #endregion

    #region --- General Global Settings ---
    SevenZipPath                    = ""                              # Full path to 7z.exe (e.g., 'C:\Program Files\7-Zip\7z.exe').
                                                                      # Leave empty ("") to allow the script to attempt auto-detection from common installation locations and the system PATH.
                                                                      # If auto-detection fails and this path is empty or invalid, the script will error.
    DefaultDestinationDir           = "D:\Backups\LocalStage"         # Default LOCAL STAGING directory where backup archives will be initially created.
                                                                      # If remote targets (see 'BackupTargets' and 'TargetNames') are specified for a job, this directory
                                                                      # serves as a temporary holding area before transfer.
                                                                      # If no remote targets are used for a job, this acts as the final backup destination.
                                                                      # Ensure this path exists, or the script has permissions to create it.
    DeleteLocalArchiveAfterSuccessfulTransfer = $true                 # Global default. If $true, the local archive in 'DefaultDestinationDir' (or job-specific 'DestinationDir')
                                                                      # will be deleted AFTER all specified remote target transfers for that job have completed successfully.
                                                                      # If $false, the local staged copy is kept. If no remote targets are specified for a job, this setting has no effect.
                                                                      # Can be overridden per job in 'BackupLocations'.
    HideSevenZipOutput              = $true                           # $true (default) to hide 7-Zip's console window during compression and testing operations.
                                                                      # $false to show the 7-Zip console window (can be useful for diagnosing 7-Zip specific issues).
                                                                      # Note: Even if hidden, 7-Zip's STDERR is captured and logged by PoSh-Backup if issues occur. STDOUT is not logged by default when hidden.
    PauseBeforeExit                 = "OnFailureOrWarning"            # Controls if the script pauses with a "Press any key to continue..." message before exiting.
                                                                      # Useful for reviewing console output, especially after errors or warnings.
                                                                      # Valid string values (case-insensitive), or boolean $true/$false:
                                                                      #   "Always" or $true: Always pause (unless -Simulate is used without a specific CLI override for pausing).
                                                                      #   "Never" or $false: Never pause.
                                                                      #   "OnFailure": Pause only if the overall script status is FAILURE.
                                                                      #   "OnWarning": Pause only if the overall script status is WARNINGS.
                                                                      #   "OnFailureOrWarning": (Default) Pause if status is FAILURE OR WARNINGS.
    EnableAdvancedSchemaValidation  = $true                           # $true to enable detailed schema-based validation of this configuration file's structure and values.
                                                                      # If $true, the 'PoShBackupValidator.psm1' module must be present in the '.\Modules' folder.
                                                                      # Recommended for advanced users or when troubleshooting configuration issues.
    TreatSevenZipWarningsAsSuccess  = $false                          # Global default. $true to treat 7-Zip exit code 1 (Warning) as a success for the job's status.
                                                                      # If $false (default), 7-Zip warnings will result in the job status being "WARNINGS".
                                                                      # Useful if backups commonly encounter benign warnings (e.g., files in use that are skipped).
                                                                      # Can be overridden per job or by the -TreatSevenZipWarningsAsSuccessCLI command-line parameter.
    RetentionConfirmDelete          = $true                           # Global default. $true to prompt for confirmation before deleting old LOCAL archives during retention.
                                                                      # Set to $false to automatically delete without prompting (useful for scheduled tasks).
                                                                      # This is overridden by -Confirm:$false on the PoSh-Backup.ps1 command line.
                                                                      # Can also be overridden per job.
    #endregion

    #region --- Logging Settings ---
    EnableFileLogging               = $true                           # $true to enable detailed text log files for each job run; $false to disable.
    LogDirectory                    = "Logs"                          # Directory to store log files.
                                                                      # If a relative path (e.g., "Logs" or ".\MyLogs"), it's relative to the PoSh-Backup script's root directory.
                                                                      # Can also be an absolute path (e.g., "C:\BackupLogs").
                                                                      # The script will attempt to create this directory if it doesn't exist.
    #endregion

    #region --- Reporting Settings (Global Defaults) ---
    ReportGeneratorType             = @("HTML")                       # Default report type(s) to generate. Can be a single string or an array of strings.
                                                                      # Available options (case-insensitive): "HTML", "CSV", "JSON", "XML", "TXT", "MD", "None".
                                                                      # "None" will disable report generation for types it's applied to.
                                                                      # This global setting can be overridden on a per-job basis.

    # --- Directory settings for each report type (can be overridden per job) ---
    # If relative, paths are from the PoSh-Backup script's root directory. Absolute paths are also supported.
    CsvReportDirectory              = "Reports"                       # Directory for CSV reports.
    JsonReportDirectory             = "Reports"                       # Directory for JSON reports.
    XmlReportDirectory              = "Reports"                       # Directory for XML (CliXml) reports.
    TxtReportDirectory              = "Reports"                       # Directory for Plain Text (TXT) summary reports.
    MdReportDirectory               = "Reports"                       # Directory for Markdown (MD) reports.

    # --- HTML Specific Reporting Settings (used if "HTML" is in ReportGeneratorType) ---
    HtmlReportDirectory             = "Reports"                       # Directory to store HTML reports.
    HtmlReportTitlePrefix           = "PoSh Backup Status Report"     # Prefix for the HTML report's browser title and main H1 heading. The job name is appended.
    HtmlReportLogoPath              = ""                              # Optional: Full UNC or local path to a logo image (e.g., PNG, JPG, GIF, SVG).
                                                                      # If provided and the image is valid, it will be embedded in the report header.
    HtmlReportFaviconPath           = ""                              # Optional: Full UNC or local path to a favicon file (e.g., .ico, .png, .svg).
                                                                      # If provided, it will be embedded as the report's browser tab icon.
    HtmlReportCustomCssPath         = ""                              # Optional: Full path to a user-provided .css file for additional or overriding report styling.
                                                                      # This CSS is loaded *after* the selected theme's CSS and any specific CSS variable overrides from this config.
    HtmlReportCompanyName           = "PoSh Backup Solutions"         # Company name, your name, or any desired text displayed in the report footer.
    HtmlReportTheme                 = "Light"                         # Name of the theme CSS file (without the .css extension) located in the 'Config\Themes' directory
                                                                      # (relative to PoSh-Backup.ps1).
                                                                      # Built-in themes: "Light", "Dark", "HighContrast", "Playful", "RetroTerminal".
                                                                      # A 'Base.css' file in 'Config\Themes' is always loaded first, providing foundational styles.

    # Override specific CSS variables for the selected theme (or base styles if no theme is explicitly chosen).
    # This allows fine-grained colour/style adjustments without creating an entirely new theme file.
    # Keys should be valid CSS variable names (e.g., "--accent-colour"), and values should be valid CSS colour codes or other CSS values.
    HtmlReportOverrideCssVariables  = @{
        # Example: To change the main accent colour for all HTML reports globally:
        # "--accent-colour"       = "#005A9C" # A specific shade of blue
        # To change the main container background for all reports:
        # "--container-bg-colour" = "#FAFAFA" # A very light grey
    }
    HtmlReportShowSummary           = $true                           # $true to include the summary table in the HTML report.
    HtmlReportShowConfiguration     = $true                           # $true to include the job configuration details (as used for the backup) in the HTML report.
    HtmlReportShowHooks             = $true                           # $true to include details of any executed hook scripts (pre/post backup) and their status/output.
    HtmlReportShowLogEntries        = $true                           # $true to include the detailed log messages from the script execution in the HTML report.
    #endregion

    #region --- Volume Shadow Copy Service (VSS) Settings (Global Defaults) ---
    EnableVSS                       = $false                          # Global default. $true to attempt using VSS for backups.
                                                                      # VSS allows backing up files that are open or locked by other processes. Requires Administrator privileges.
                                                                      # Note: VSS only applies to local volumes. If source paths are on network shares (UNC paths),
                                                                      # VSS will be skipped for those specific paths even if enabled for the job.
                                                                      # Can be overridden per job or by the -UseVSS command-line parameter.
    DefaultVSSContextOption         = "Persistent NoWriters"          # Default 'SET CONTEXT' option for diskshadow.exe.
                                                                      # "Persistent": Allows writers, snapshot persists after script (needs manual cleanup if script fails before VSS removal).
                                                                      # "Persistent NoWriters": Tries to exclude writers during shadow creation; snapshot persists.
                                                                      # "Volatile NoWriters": (Often Recommended for Scripts) Snapshot is automatically deleted when the VSS context is released by the script. Safer for automated backups.
    VSSMetadataCachePath            = "%TEMP%\diskshadow_cache_poshbackup.cab" # Path for diskshadow's metadata cache file. The %TEMP% environment variable is expanded.
    VSSPollingTimeoutSeconds        = 120                             # Maximum time (in seconds) to wait for VSS shadow copies to become available and detectable via WMI.
    VSSPollingIntervalSeconds       = 5                               # How often (in seconds) to poll WMI while waiting for shadow copies to be ready.
    #endregion

    #region --- Retry Mechanism Settings (Global Defaults) ---
    EnableRetries                   = $true                           # Global default. $true to enable the retry mechanism for failed 7-Zip operations (compression or archive testing).
                                                                      # Can be overridden per job or by the -EnableRetriesCLI command-line parameter.
    MaxRetryAttempts                = 3                               # Maximum number of retry attempts for a failed 7-Zip operation.
    RetryDelaySeconds               = 60                              # Delay in seconds between 7-Zip retry attempts.
    #endregion

    #region --- 7-Zip Process Priority Settings (Global Default) ---
    DefaultSevenZipProcessPriority  = "BelowNormal"                   # Default Windows process priority for the 7z.exe process.
                                                                      # Options (case-insensitive): "Idle", "BelowNormal", "Normal", "AboveNormal", "High".
                                                                      # "BelowNormal" is generally a good compromise for background tasks to minimise impact on other system activities.
    #endregion

    #region --- Destination Free Space Check Settings (Global Defaults) ---
    MinimumRequiredFreeSpaceGB      = 5                               # Minimum free Gigabytes (GB) required on the LOCAL STAGING destination drive before starting a backup.
                                                                      # Set to 0 or a negative value to disable this check.
    ExitOnLowSpaceIfBelowMinimum    = $false                          # $false (default) to only issue a warning and continue with the backup attempt.
                                                                      # $true to abort the job if free space is below the specified minimum.
    #endregion

    #region --- Archive Integrity Test Settings (Global Default) ---
    DefaultTestArchiveAfterCreation = $false                          # Global default. $true to automatically test the integrity of newly created archives using '7z t'.
                                                                      # Can be overridden per job or by the -TestArchive command-line parameter.
    #endregion

    #region --- Archive Filename Settings (Global Default) ---
    DefaultArchiveDateFormat        = "yyyy-MMM-dd"                   # Default .NET date format string used for the date component in archive filenames.
                                                                      # Examples: "yyyy-MM-dd", "dd-MMM-yyyy_HH-mm-ss" (includes time), "yyMMdd".
    #endregion

    #region --- Checksum Settings (Global Defaults) --- NEW REGION
    DefaultGenerateArchiveChecksum      = $false                      # Global default. $true to generate a checksum file for the local archive.
    DefaultChecksumAlgorithm            = "SHA256"                    # Global default. Algorithm for checksum. Valid: "SHA1", "SHA256", "SHA384", "SHA512", "MD5".
    DefaultVerifyArchiveChecksumOnTest  = $false                      # Global default. $true to verify checksum during archive test (if TestArchiveAfterCreation is also true).
                                                                      # Checksum file is named <ArchiveFileName>.<Algorithm>.checksum (e.g., MyJob_Date.7z.SHA256.checksum).
    #endregion

    #region --- Global 7-Zip Parameter Defaults ---
    # These settings are passed directly as command-line switches to 7-Zip if not overridden at the job level.
    # Refer to the 7-Zip command-line documentation for the precise meaning and impact of these switches.
    DefaultThreadCount              = 0                               # 7-Zip -mmt switch (multithreading). 0 (or omitting the switch) allows 7-Zip to auto-detect optimal thread count.
                                                                      # Set to a specific number (e.g., 4 for `-mmt=4`) to limit CPU core usage.
    DefaultArchiveType              = "-t7z"                          # 7-Zip -t (type) switch. Examples: -t7z, -tzip, -ttar, -tgzip.
    DefaultArchiveExtension         = ".7z"                           # Default file extension for generated archives. This should logically match the DefaultArchiveType.
                                                                      # Used for archive naming and for matching files during retention policy application.
    DefaultCompressionLevel         = "-mx=7"                         # 7-Zip -mx (compression level) switch.
                                                                      # Examples: -mx=0 (Store - no compression), -mx=1 (Fastest), -mx=5 (Normal), -mx=7 (Maximum), -mx=9 (Ultra).
    DefaultCompressionMethod        = "-m0=LZMA2"                     # 7-Zip -m0 (compression method) switch. Examples: -m0=LZMA2, -m0=PPMd (for .7z); -m0=Deflate (for .zip).
    DefaultDictionarySize           = "-md=128m"                      # 7-Zip -md (dictionary size) switch. E.g., -md=64m, -md=256m.
    DefaultWordSize                 = "-mfb=64"                       # 7-Zip -mfb (word size or fast bytes) switch. E.g., -mfb=32, -mfb=128.
    DefaultSolidBlockSize           = "-ms=16g"                       # 7-Zip -ms (solid mode block size) switch.
                                                                      # Examples: -ms=on (default solid block size), -ms=off (non-solid), -ms=4g (4GB solid blocks).
    DefaultCompressOpenFiles        = $true                           # 7-Zip -ssw switch (Compress shared files). If $true, adds -ssw.
                                                                      # VSS is generally a more robust method for backing up open/locked files if available.
    DefaultScriptExcludeRecycleBin  = '-x!$RECYCLE.BIN'               # Default 7-Zip exclusion pattern for Recycle Bin folders on all drives.
    DefaultScriptExcludeSysVolInfo  = '-x!System Volume Information'  # Default 7-Zip exclusion pattern for System Volume Information folders.
    #endregion

    #region --- Backup Target Definitions (Global) ---
    # Define named remote target configurations here. These can be referenced by jobs in 'BackupLocations'.
    # Each target instance must have a 'Type' (e.g., "UNC", "Replicate", "FTP", "S3") and 'TargetSpecificSettings'.
    # 'CredentialsSecretName' is optional for providers that might use PS SecretManagement for auth.
    # 'RemoteRetentionSettings' is optional and provider-specific for managing retention on the target.
    BackupTargets = @{
        "ExampleUNCShare" = @{
            Type = "UNC" # Provider module 'Modules\Targets\UNC.Target.psm1' will handle this
            TargetSpecificSettings = @{
                UNCRemotePath = "\\fileserver01\backups\MyPoShBackups" # Base path on the UNC share
                # NEW SETTING: Controls if a JobName subdirectory is created under UNCRemotePath.
                # $false (default): Archive saved directly into UNCRemotePath (e.g., \\server\share\archive.7z)
                # $true: Archive saved into UNCRemotePath\JobName\ (e.g., \\server\share\JobName\archive.7z)
                CreateJobNameSubdirectory = $false 
            }
            # Optional: For UNC, if alternate credentials are needed to write to the share.
            # CredentialsSecretName = "UNCFileServer01Creds" # Name of a Generic Credentials secret in PowerShell SecretManagement.

            # Optional: Provider-specific retention settings for this target.
            # The structure and meaning of 'RemoteRetentionSettings' are entirely up to the specific target provider module.
            # Example for a hypothetical UNC provider that supports count-based retention on the remote share:
            # RemoteRetentionSettings = @{
            #    KeepCount = 10 # e.g., Keep the last 10 archives for any job using this target, on the remote share.
            #    # KeepDays  = 0  # e.g., Or keep archives for X days. 0 means not used. (Provider specific)
            # }
        }
        "ExampleReplicatedStorage" = @{ # NEW EXAMPLE FOR REPLICATE PROVIDER
            Type = "Replicate" # Provider module 'Modules\Targets\Replicate.Target.psm1' will handle this
            TargetSpecificSettings = @( # This MUST be an array of hashtables, each defining one destination
                @{ # First destination for replication
                    Path = "E:\LocalReplicas\MainServer" # Can be a local path (e.g., another internal drive)
                    CreateJobNameSubdirectory = $true # Archives for a job (e.g., "WebServer") go to E:\LocalReplicas\MainServer\WebServer
                    RetentionSettings = @{ KeepCount = 7 } # Keep 7 versions of archives for this job in this specific location
                },
                @{ # Second destination for replication
                    Path = "\\NAS-BACKUP\OffsiteReplicas\SQL" # Can be a UNC path
                    CreateJobNameSubdirectory = $false # Archives for job "SQLBackup" go directly into \\NAS-BACKUP\OffsiteReplicas\SQL
                    RetentionSettings = @{ KeepCount = 30 } # Keep 30 versions of archives for this job in this specific location
                },
                @{ # Third destination (simple, no job subdir, no specific retention configured for this path)
                    Path = "F:\ExternalHDD\ArchiveMirror" # e.g., a USB drive
                    # CreateJobNameSubdirectory defaults to $false if not specified
                    # RetentionSettings is not specified, so no retention will be applied by the Replicate provider for this path
                }
            )
            # Note: 'CredentialsSecretName' or global 'RemoteRetentionSettings' are generally not applicable
            # at the top level of a "Replicate" target instance. Credentials and retention are typically
            # configured per-destination-path if needed by the underlying mechanism (though this simple
            # Replicate provider uses standard Copy-Item and its own retention).
        }
        "ExampleSFTPServer" = @{
            Type = "SFTP" # Provider module 'Modules\Targets\SFTP.Target.psm1' will handle this
            TargetSpecificSettings = @{
                SFTPServerAddress   = "sftp.example.com"    # Mandatory: SFTP server hostname or IP
                SFTPPort            = 22                    # Optional: Defaults to 22 if not specified
                SFTPRemotePath      = "/backups/poshbackup" # Mandatory: Base path on the SFTP server
                SFTPUserName        = "backupuser"          # Mandatory: Username for SFTP authentication
                
                # --- Authentication Methods (choose one or rely on agent if Posh-SSH supports it) ---
                # Option 1: Password-based (using PowerShell SecretManagement)
                SFTPPasswordSecretName = "MySftpUserPassword" # Optional: Name of secret storing the password

                # Option 2: Key-based (private key file path stored in SecretManagement, passphrase optional)
                # SFTPKeyFileSecretName = "MySftpPrivateKeyPath" # Optional: Name of secret storing the *path* to the private key file (e.g., C:\Keys\sftp_rsa)
                # SFTPKeyFilePassphraseSecretName = "MySftpKeyPassphrase" # Optional: Name of secret storing the key's passphrase, if any

                # --- Other SFTP Settings ---
                CreateJobNameSubdirectory = $true # Optional: If $true, creates /backups/poshbackup/JobName/ on the SFTP server. Default is $false.
                SkipHostKeyCheck    = $false      # Optional: Default $false. If $true, skips SSH host key verification (INSECURE - use with extreme caution).
            }
            # Optional: Remote retention settings for this SFTP target.
            # The SFTP provider will implement logic based on these settings (e.g., KeepCount).
            RemoteRetentionSettings = @{
                KeepCount = 7 # e.g., Keep the last 7 archives for any job using this target, on the SFTP server.
            }
        }
        # "ExampleS3Bucket" = @{ # Example for a future S3 target provider
        #    Type = "S3"
        #    TargetSpecificSettings = @{
        #        BucketName = "my-s3-backup-bucket"
        #        Region     = "eu-west-2"
        #        AccessKeySecretName = "S3BackupUserAccessKey" # Secret containing AWS Access Key ID
        #        SecretKeySecretName = "S3BackupUserSecretKey" # Secret containing AWS Secret Access Key
        #        RemotePathPrefix    = "PoShBackupArchives/"   # Optional prefix within the bucket
        #    }
        #    RemoteRetentionSettings = @{ # Example S3 retention settings
        #        # S3 provider might use this to apply/check an S3 Lifecycle Policy, or manage versions.
        #        ApplyLifecyclePolicy = $true
        #        LifecyclePolicyDaysToExpire = 30
        #    }
        # }
    }
    #endregion
    
    #region --- Post-Run Action Defaults (Global) ---
    # NEW SECTION: Defines default behavior for actions to take after a job or set completes.
    # These can be overridden at the job or set level.
    # A CLI parameter will override all configured PostRunActions.
    PostRunActionDefaults = @{
        Enabled         = $false # $true to enable post-run actions by default.
        Action          = "None" # Default action. Valid: "None", "Shutdown", "Restart", "Hibernate", "LogOff", "Sleep", "Lock".
        DelaySeconds    = 0      # Delay in seconds before performing the action. 0 for immediate.
                                 # During the delay, a message will show with a countdown, allowing cancellation by pressing 'C'.
        TriggerOnStatus = @("SUCCESS") # Array of job/set statuses that will trigger the action.
                                       # Valid: "SUCCESS", "WARNINGS", "FAILURE", "SIMULATED_COMPLETE", "ANY".
                                       # "ANY" means the action triggers if Enabled=$true, regardless of status.
        ForceAction     = $false # For "Shutdown" or "Restart", $true attempts to force the operation (e.g., closing apps without saving).
    }
    #endregion

    #region --- Backup Locations (Job Definitions) ---
    # Define individual backup jobs here. Each key in this hashtable represents a unique job name.
    BackupLocations                 = @{
        "Projects"  = @{
            Path                    = "P:\Images\*"                   # Path(s) to back up. Can be a single string or an array of strings for multiple sources.
            Name                    = "Projects"                      # Base name for the archive file (date stamp and extension will be appended).
            DestinationDir          = "D:\Backups\LocalStage\Projects" # Specific LOCAL STAGING destination for this job.
            #TargetNames             = @("ExampleUNCShare")            # OPTIONAL: Array of target names from 'BackupTargets'. E.g., @("ExampleUNCShare")
                                                                      # If empty or not present, this job is local-only to DestinationDir.
            DeleteLocalArchiveAfterSuccessfulTransfer = $true         # Job-specific override for the global setting.

            LocalRetentionCount     = 3                               # Number of archive versions for this job to keep in 'DestinationDir'. (Previously 'RetentionCount')
            DeleteToRecycleBin      = $false                          # For local retention in 'DestinationDir'.
            RetentionConfirmDelete  = $false                          # Job-specific override for local retention: auto-delete old local archives without prompting.

            ArchivePasswordMethod   = "None"                          # Password method: "None", "Interactive", "SecretManagement", "SecureStringFile", "PlainText". See instructions at top.
            # CredentialUserNameHint  = "ProjectBackupUser"             # For "Interactive" method.
            # ArchivePasswordSecretName = ""                            # For "SecretManagement" method.
            # ArchivePasswordVaultName  = ""                            # Optional for "SecretManagement".
            # ArchivePasswordSecureStringPath = ""                      # For "SecureStringFile" method.
            # ArchivePasswordPlainText  = ""                            # For "PlainText" method (INSECURE).

            # UsePassword             = $false                          # Legacy. If ArchivePasswordMethod is "None" and this is $true, "Interactive" is used.

            EnableVSS               = $false                          # $true to use VSS for this job (requires Admin). Overrides global EnableVSS.
            SevenZipProcessPriority = "Normal"                        # Override global 7-Zip priority for this specific job.
            ReportGeneratorType     = @("HTML")                       # Report type(s) for this job. Overrides global ReportGeneratorType.
            TreatSevenZipWarningsAsSuccess = $false                   # Optional per-job override. If $true, 7-Zip exit code 1 (Warning) is treated as success for this job.
            
            # NEW Checksum Settings for this job
            GenerateArchiveChecksum     = $true                       # Example: Enable checksum generation for this job
            ChecksumAlgorithm           = "SHA256"                    # Use SHA256
            VerifyArchiveChecksumOnTest = $true                       # Verify checksum if TestArchiveAfterCreation is also true

            # NEW: Job-specific PostRunAction settings. Overrides PostRunActionDefaults.
            # PostRunAction = @{
            #     Enabled         = $true
            #     Action          = "Shutdown" 
            #     DelaySeconds    = 60
            #     TriggerOnStatus = @("SUCCESS", "WARNINGS") 
            #     ForceAction     = $false
            # }
        }
        "AnExample_WithRemoteTarget" = @{ # THIS IS THE ORIGINAL "AnExample" JOB - MODIFIED
            Path                       = "C:\Users\YourUser\Documents\ImportantDocs\*"
            Name                       = "MyImportantDocuments"
            DestinationDir             = "D:\Backups\LocalStage\Docs" # LOCAL STAGING directory. Archive is created here first.

            TargetNames                = @("ExampleUNCShare")         # Archive will be sent to "ExampleUNCShare" (defined in BackupTargets) after local creation.
            DeleteLocalArchiveAfterSuccessfulTransfer = $true         # Delete from local staging after successful transfer to ALL targets.

            LocalRetentionCount        = 5                            # Number of archive versions to keep in the local 'DestinationDir'. (Previously 'RetentionCount')
            DeleteToRecycleBin         = $true                        # Note: Ensure this is appropriate if 'DestinationDir' is a network share (less common for staging).
            RetentionConfirmDelete     = $false                       # Example: This job will auto-delete old local archives without prompting.

            ArchivePasswordMethod      = "Interactive"                # Example: Prompts for password for this job.
            CredentialUserNameHint     = "DocsUser"

            ArchiveType                = "-tzip"                      # Example: Use ZIP format for this job. Overrides DefaultArchiveType.
            ArchiveExtension           = ".zip"                       # Must match ArchiveType. Overrides DefaultArchiveExtension.
            ArchiveDateFormat          = "dd-MM-yyyy"                 # Custom date format for this job's archives. Overrides DefaultArchiveDateFormat.
            MinimumRequiredFreeSpaceGB = 2                            # Custom free space check for local staging. Overrides global setting.
            HtmlReportTheme            = "RetroTerminal"              # Use a specific HTML report theme for this job.
            TreatSevenZipWarningsAsSuccess = $true                    # Example: For this job, 7-Zip warnings are considered success.
            
            # Checksum settings (will use global defaults if not specified here, e.g., DefaultGenerateArchiveChecksum = $false)
            # GenerateArchiveChecksum     = $false 
            # VerifyArchiveChecksumOnTest = $false

            # PostRunAction = @{ Enabled = $false } # Example: Explicitly disable for this job
        }
        "Docs_Replicated_Example" = @{ # NEW EXAMPLE JOB USING THE REPLICATE TARGET
            Path                       = @("C:\Users\YourUser\Documents\Reports", "C:\Users\YourUser\Pictures\Screenshots")
            Name                       = "UserDocs_MultiCopy" # Example: base name for the archive
            DestinationDir             = "C:\BackupStaging\UserDocs" # Local staging directory before replication
            
            TargetNames                = @("ExampleReplicatedStorage") # Reference the "Replicate" target instance defined in BackupTargets
            
            # This setting applies to deleting the archive from "C:\BackupStaging\UserDocs" AFTER
            # the "ExampleReplicatedStorage" target (which involves multiple copies) completes successfully.
            DeleteLocalArchiveAfterSuccessfulTransfer = $true 
            
            LocalRetentionCount        = 2 # Keep very few archive versions in the local staging area "C:\BackupStaging\UserDocs"
            
            ArchivePasswordMethod      = "None" # Or any other valid password method
            EnableVSS                  = $true  # Example: Use VSS for source files

            # Checksum settings for this job
            GenerateArchiveChecksum     = $true
            ChecksumAlgorithm           = "MD5" # Example: Using MD5 for this job
            VerifyArchiveChecksumOnTest = $true

            # PostRunAction = @{ Action = "Hibernate"; TriggerOnStatus = @("ANY"); DelaySeconds = 10 } # Example
        }
        "CriticalData_To_SFTP_Example" = @{
            Path                    = "E:\CriticalApplication\Data"
            Name                    = "AppCriticalData_SFTP"
            DestinationDir          = "D:\BackupStaging\SFTP_Stage" # Local staging before SFTP transfer
            
            TargetNames             = @("ExampleSFTPServer") # Reference the SFTP target instance
            
            DeleteLocalArchiveAfterSuccessfulTransfer = $true # Delete from C:\BackupStaging after successful SFTP
            LocalRetentionCount     = 1 # Keep only 1 in local staging
            
            ArchivePasswordMethod   = "SecretManagement"
            ArchivePasswordSecretName = "MyArchiveEncryptionPassword" # Password for the 7z archive itself
            
            EnableVSS               = $true
            TestArchiveAfterCreation= $true # Good practice for critical data

            # Checksum settings for this job
            GenerateArchiveChecksum     = $true
            ChecksumAlgorithm           = "SHA512"
            VerifyArchiveChecksumOnTest = $true
            
            PostRunAction = @{
                Enabled         = $true
                Action          = "Lock"
                TriggerOnStatus = @("SUCCESS")
            }
        }

        #region --- Comprehensive Example (Commented Out for Reference) ---
        <#
        "ComprehensiveExample_WebApp" = @{
            Path                    = @(                             # Multiple source paths can be specified in an array.
                                        "C:\inetpub\wwwroot\MyWebApp",
                                        "D:\Databases\MyWebApp_Config.xml"
                                      )
            Name                    = "WebApp_Production"
            DestinationDir          = "\\BACKUPSERVER\Share\WebApps\LocalStage_WebApp"  # Example: Local staging to a network share (less common, but possible).
                                                                                      # Or simply "C:\BackupStage\WebApp" for true local staging.
            LocalRetentionCount     = 1                               # Keep only the latest copy locally in staging after successful transfers. (Previously 'RetentionCount')
            DeleteLocalArchiveAfterSuccessfulTransfer = $true         # Delete from staging if all remote transfers succeed.
            RetentionConfirmDelete  = $false                          # For local retention, auto-delete.

            # This job will attempt to send the archive to both "ExampleUNCShare" and "ExampleS3Bucket" (if defined).
            TargetNames             = @(
                                        "ExampleUNCShare" # Defined in global BackupTargets
                                        # "ExampleS3Bucket" # Assumes this is also defined in BackupTargets
                                      )

            ArchivePasswordMethod   = "SecretManagement"
            ArchivePasswordSecretName = "WebAppBackupPassword"        # Name of the secret stored in SecretManagement.
            # ArchivePasswordVaultName= "MyProductionVault"           # Optional: Specify vault if not default.

            ArchiveType             = "-t7z"
            ArchiveExtension        = ".7z"
            ArchiveDateFormat       = "yyyy-MM-dd_HHmm"               # More granular date format for frequent backups.

            ThreadsToUse            = 2                               # Override DefaultThreadCount to limit CPU impact.
            SevenZipProcessPriority = "BelowNormal"
            CompressionLevel        = "-mx=5"                         # Balance of speed and compression.
            AdditionalExclusions    = @(                              # Array of 7-Zip exclusion patterns specific to this job.
                                        "*\logs\*.log",                 # Exclude all .log files in any 'logs' subfolder.
                                        "*\temp\*",                     # Exclude all temp folders and their contents.
                                        "web.config.temp",
                                        "*.TMP"
                                        )

            EnableVSS                     = $true
            VSSContextOption              = "Volatile NoWriters"      # Recommended for scripted backups; snapshot auto-deleted.

            EnableRetries                 = $true                     # For 7-Zip operations
            MaxRetryAttempts              = 2
            RetryDelaySeconds             = 120                       # Longer delay, perhaps for transient network issues.

            MinimumRequiredFreeSpaceGB    = 50                        # For local staging
            ExitOnLowSpaceIfBelowMinimum  = $true
            TestArchiveAfterCreation      = $true                     # Always test this critical backup.
            TreatSevenZipWarningsAsSuccess = $false                   # Explicitly keep default behavior for this critical job.

            # Checksum settings for this comprehensive job
            GenerateArchiveChecksum     = $true
            ChecksumAlgorithm           = "SHA256"
            VerifyArchiveChecksumOnTest = $true

            ReportGeneratorType           = @("HTML", "JSON")         # Generate both HTML and JSON reports.
            HtmlReportTheme               = "Dark"
            HtmlReportDirectory           = "\\SHARE\AdminReports\PoShBackup\WebApp" # Custom directory for this job's HTML reports.
            HtmlReportTitlePrefix         = "Web Application Backup Status"
            HtmlReportLogoPath            = "\\SHARE\Branding\WebAppLogo.png"
            HtmlReportFaviconPath         = "\\SHARE\Branding\WebAppFavicon.ico" # Example job-specific favicon
            HtmlReportCustomCssPath       = "\\SHARE\Branding\WebAppReportOverrides.css"
            HtmlReportCompanyName         = "Production Services Ltd."
            HtmlReportOverrideCssVariables = @{
                "--accent-colour"        = "darkred";
                "--header-border-colour" = "black";
            }

            PreBackupScriptPath           = "C:\Scripts\BackupPrep\WebApp_PreBackup.ps1"
            PostBackupScriptOnSuccessPath = "C:\Scripts\BackupPrep\WebApp_PostSuccess.ps1"
            PostBackupScriptOnFailurePath = "C:\Scripts\BackupPrep\WebApp_PostFailure_Alert.ps1"
            PostBackupScriptAlwaysPath    = "C:\Scripts\BackupPrep\WebApp_PostAlways_Cleanup.ps1"
            
            # PostRunAction = @{
            #     Enabled         = $true
            #     Action          = "LogOff" 
            #     DelaySeconds    = 300 # 5 minutes
            #     TriggerOnStatus = @("ANY") 
            # }
        }
        #>
        #endregion
    }
    #endregion

    #region --- Backup Sets ---
    # Backup Sets allow grouping multiple BackupLocations (defined above) to run sequentially
    # when PoSh-Backup.ps1 is called with the -RunSet <SetName> command-line parameter.
    BackupSets                      = @{
        "Daily_Critical_Backups" = @{
            JobNames     = @(                                         # Array of job names (these must be keys from BackupLocations defined above).
                "Projects", 
                "AnExample_WithRemoteTarget",
                "Docs_Replicated_Example", 
                "CriticalData_To_SFTP_Example"
            )
            OnErrorInJob = "StopSet"                                  # Defines behaviour if a job within this set fails.
                                                                      # "StopSet": (Default) If a job fails, subsequent jobs in THIS SET are skipped. The script may continue to other sets if applicable.
                                                                      # "ContinueSet": Subsequent jobs in THIS SET will attempt to run even if a prior one fails.
            # NEW: Set-specific PostRunAction. Overrides job-level PostRunActions within this set,
            # and also overrides PostRunActionDefaults.
            # This action applies AFTER the entire set (and its final hooks) completes.
            # PostRunAction = @{
            #     Enabled         = $true
            #     Action          = "Restart"
            #     DelaySeconds    = 120
            #     TriggerOnStatus = @("SUCCESS") # Only restart if the entire set was successful
            #     ForceAction     = $true
            # }
        }
        "Weekly_User_Data"       = @{
            JobNames = @(
                "AnExample_WithRemoteTarget",
                "Docs_Replicated_Example" 
            )
            # OnErrorInJob defaults to "StopSet" if not specified for a set.
            # PostRunAction = @{ Enabled = $false } # Example: No post-run action for this set
        }
        "Nightly_Full_System_Simulate" = @{                           # Example for a simulation run of multiple jobs.
            JobNames = @("Projects", "AnExample_WithRemoteTarget", "Docs_Replicated_Example", "CriticalData_To_SFTP_Example")
            OnErrorInJob = "ContinueSet"
            # Note: To run this set in simulation mode, you would use:
            # .\PoSh-Backup.ps1 -RunSet "Nightly_Full_System_Simulate" -Simulate
        }
    }
    #endregion
}
