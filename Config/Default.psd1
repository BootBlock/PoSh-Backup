# Config/Default.psd1
# PowerShell Data File for PoSh Backup Script Configuration (Default).
# --> THIS WILL GET OVERWRITTEN ON UPGRADE if you do not use a User.psd1 file for your customisations! <--
# It is strongly recommended to copy this file to 'User.psd1' in the same 'Config' directory
# and make all your modifications there. User.psd1 will override these defaults.
#
# Version 1.9.2: Added VerificationJobs section for automated restore testing.
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
    MaintenanceModeEnabled          = $false                          # Global switch. If $true, PoSh-Backup will not start any new backup jobs and will exit immediately with a message.
                                                                      # This is one of two ways to enable maintenance mode.
    MaintenanceModeFilePath         = ".\.maintenance"                # Path to an on-disk flag file. If this file exists, PoSh-Backup will enter maintenance mode.
                                                                      # This allows enabling/disabling maintenance mode without editing config files.
                                                                      # Use a relative path (like '.\.maintenance') for a file in the script root, or an absolute path.
    MaintenanceModeMessage          = "PoSh-Backup is currently in maintenance mode.`n      New backup jobs will not be started." # The message to display when exiting due to maintenance mode.

    SevenZipPath                    = ""                              # Full path to 7z.exe (e.g., 'C:\Program Files\7-Zip\7z.exe').
                                                                      # Leave empty ("") to allow the script to attempt auto-detection from common installation locations and the system PATH.
                                                                      # If auto-detection fails and this path is empty or invalid, the script will error.
    DefaultDestinationDir           = "D:\Backups\LocalStage"         # Default directory where backup archives will be initially created.
                                                                      # If remote targets (see 'BackupTargets' and 'TargetNames') are specified for a job, this directory
                                                                      # serves as a temporary LOCAL STAGING area before transfer.
                                                                      # If no remote targets are used for a job, this acts as the FINAL BACKUP DESTINATION.
                                                                      # Ensure this path exists, or the script has permissions to create it.
    DeleteLocalArchiveAfterSuccessfulTransfer = $true                 # Global default. If $true, the local archive in 'DefaultDestinationDir' (or job-specific 'DestinationDir')
                                                                      # will be deleted AFTER all specified remote target transfers for that job have completed successfully.
                                                                      # If $false, the local copy is kept. If no remote targets are specified for a job, this setting has no effect
                                                                      # as the archive in 'DestinationDir' is the final backup.
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
    DefaultLogRetentionCount        = 30                              # Global default for the number of log files to keep per job name pattern.
                                                                      # Set to 0 to keep all log files (infinite retention).
                                                                      # Can be overridden at the job or set level.
    CompressOldLogs                 = $false                          # If $true, log files marked for deletion by retention will be compressed into an archive instead of being permanently deleted.
    OldLogCompressionFormat         = "Zip"                           # Format for the compressed log archive. Valid values: "Zip".
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

    #region --- Notification Settings (Global) ---
    # Define reusable notification provider profiles here. Jobs and sets can then reference these by name.
    NotificationProfiles = @{
        # Example profile for the "Email" provider.
        "Office365" = @{
            Type             = "Email" # Specifies to use the email notification provider.
            ProviderSettings = @{
                SMTPServer           = "smtp.office365.com"
                SMTPPort             = 587
                EnableSsl            = $true
                FromAddress          = "backup-alerts@your-domain.com"
                # Name of the secret in PowerShell SecretManagement storing the PSCredential object.
                CredentialSecretName = "Office365BackupUserCredentials"
                # CredentialVaultName  = "MySpecificVault" # Optional
            }
        }

        # Example profile for the generic "Webhook" provider (e.g., for Microsoft Teams or Slack).
        "TeamsAlertsChannel" = @{
            Type             = "Webhook" # Specifies to use the webhook notification provider.
            ProviderSettings = @{
                # Name of the secret in PowerShell SecretManagement storing the full webhook URL.
                WebhookUrlSecretName = "TeamsAlertsWebhookUrl"
                # WebhookUrlVaultName  = "MySpecificVault" # Optional

                # The HTTP method to use. "POST" is most common for webhooks.
                Method = "POST"

                # Optional: A hashtable of custom headers to send with the request.
                Headers = @{
                    # Example: "Authorization" = "Bearer MyToken"
                }

                # The request body template. Placeholders like {JobName}, {Status}, etc., will be replaced.
                # This example is a simple JSON payload suitable for many services.
                # For Microsoft Teams, you would use a more complex "Adaptive Card" JSON structure here.
                BodyTemplate = @'
{
    "text": "PoSh-Backup Job ''{JobName}'' finished with status: **{Status}**",
    "summary": "Backup for {JobName} finished.",
    "sections": [{
        "activityTitle": "PoSh-Backup Report",
        "activitySubtitle": "Job: {JobName} on {ComputerName}",
        "facts": [
            { "name": "Status", "value": "{Status}" },
            { "name": "Start Time", "value": "{StartTime}" },
            { "name": "Duration", "value": "{Duration}" },
            { "name": "Archive Path", "value": "{ArchivePath}" },
            { "name": "Archive Size", "value": "{ArchiveSize}" },
            { "name": "Error Message", "value": "{ErrorMessage}" }
        ],
        "markdown": true
    }]
}
'@
            }
        }
    }

    # Define the default behaviour for notifications.
    # These settings can be overridden at the job or set level.
    DefaultNotificationSettings = @{
        Enabled         = $false # Master switch. Set to $true in a job/set to enable notifications for it.
        ProfileName     = ""     # The name of the profile (from NotificationProfiles above) to use. MUST be specified in job/set if Enabled is $true.
        ToAddress       = @()    # For "Email" provider: An array of recipient email addresses. E.g., @("admin@example.com"). Ignored by "Webhook" provider.

        # The subject line for "Email" provider notifications. Placeholders will be replaced. Ignored by "Webhook" provider.
        # Available placeholders: {JobName}, {SetName}, {Status}, {Date}, {Time}, {ComputerName}
        Subject         = "PoSh-Backup Report for Job: {JobName} - Status: {Status}"

        # An array of job/set statuses that will trigger a notification to be sent.
        # Valid: "SUCCESS", "WARNINGS", "FAILURE", "SIMULATED_COMPLETE", "ANY".
        TriggerOnStatus = @("FAILURE", "WARNINGS")
    }
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

    #region --- Snapshot Provider Settings (Global) ---
    # Define named snapshot provider configurations here. These can be referenced by jobs in 'BackupLocations'.
    # This feature allows PoSh-Backup to orchestrate infrastructure-level snapshots (e.g., Hyper-V, VMware, SAN)
    # before performing a file-level backup from the snapshot. This is the gold standard for backing up active
    # virtual machines and large databases with minimal performance impact on the live system.
    SnapshotProviders = @{
        # Example for a local Hyper-V host.
        "LocalHyperV" = @{
            Type = "HyperV" # Provider module 'Modules\SnapshotProviders\HyperV.Snapshot.psm1' will handle this.
                            # Requires the Hyper-V PowerShell module to be installed on the machine running PoSh-Backup.
            ProviderSpecificSettings = @{
                # For local Hyper-V, no ComputerName is needed.
                # For a remote Hyper-V host, you would specify it here:
                # ComputerName = "MyHyperVHost01"
            }
            # Optional: If connecting to a remote Hyper-V host, specify credentials.
            # The secret should store a PSCredential object with rights to manage Hyper-V on the remote host.
            # CredentialsSecretName = "HyperVAdminCreds"
        }

        # Example for a VMware vCenter server (hypothetical future provider).
        # "MyVCenter" = @{
        #    Type = "VMware" # Would require Modules\SnapshotProviders\VMware.Snapshot.psm1
        #                     # and the VMware PowerCLI module.
        #    ProviderSpecificSettings = @{
        #        Server = "vcenter.mydomain.local"
        #    }
        #    CredentialsSecretName = "VCenterBackupUserCreds"
        # }
    }
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

    DefaultVerifyLocalArchiveBeforeTransfer = $false                  # Global default. $true to test local archive integrity (and checksum if enabled) *before* any remote transfers.
                                                                      # If this test fails, remote transfers for the job will be skipped.
    #endregion

    #region --- Archive Filename Settings (Global Default) ---
    DefaultArchiveDateFormat        = "yyyy-MMM-dd"                   # Default .NET date format string used for the date component in archive filenames.
                                                                      # Examples: "yyyy-MM-dd", "dd-MMM-yyyy_HH-mm-ss" (includes time), "yyMMdd".
    DefaultCreateSFX                = $false                          # Global default. $true to create a Self-Extracting Archive (.exe).
                                                                      # If $true, the final archive extension will be '.exe'. Windows-specific.
    DefaultSFXModule                = "Console"                       # Global default for SFX module type.
                                                                      # "Console": (Default) Uses 7-Zip's default console SFX module (e.g., 7zCon.sfx). Extracts to current dir without prompt.
                                                                      # "GUI": Uses 7-Zip's standard GUI SFX module (e.g., 7zS.sfx). Prompts user for extraction path.
                                                                      # "Installer": Uses 7-Zip's installer-like GUI SFX module (e.g., 7zSD.sfx). Prompts user for extraction path.
    DefaultSplitVolumeSize          = ""                              # Global default for splitting archives. Empty means no split.
                                                                      # Examples: "100m" (100 Megabytes), "4g" (4 Gigabytes), "700k" (700 Kilobytes).
                                                                      # Use 'k', 'm', 'g'. Case might matter for 7-Zip; schema will enforce lowercase.
    DefaultGenerateSplitArchiveManifest = $false                      # Global default. $true to generate a manifest file listing all volumes and their checksums for split archives.
                                                                      # If $true and SplitVolumeSize is active, this overrides DefaultGenerateArchiveChecksum for the primary archive file.
    #endregion

    #region --- Checksum Settings (Global Defaults) ---
    DefaultGenerateArchiveChecksum      = $false                      # Global default. $true to generate a checksum file for the local archive.
                                                                      # For split archives, if DefaultGenerateSplitArchiveManifest is $false, this applies to the first volume (.001).
    DefaultChecksumAlgorithm            = "SHA256"                    # Global default. Algorithm for checksum. Valid: "SHA1", "SHA256", "SHA384", "SHA512", "MD5".
    DefaultVerifyArchiveChecksumOnTest  = $false                      # Global default. $true to verify checksum during archive test (if TestArchiveAfterCreation is also true).
                                                                      # Checksum file is named <ArchiveFileName>.<Algorithm>.checksum (e.g., MyJob_Date.7z.SHA256.checksum).
    #endregion

    #region --- Global 7-Zip Parameter Defaults ---
    # These settings are passed directly as command-line switches to 7-Zip if not overridden at the job level.
    # Refer to the 7-Zip command-line documentation for the precise meaning and impact of these switches.
    DefaultThreadCount              = 0                               # 7-Zip -mmt switch (multithreading). 0 (or omitting the switch) allows 7-Zip to auto-detect optimal thread count.
                                                                      # Set to a specific number (e.g., 4 for `-mmt=4`) to limit CPU core usage.
    DefaultSevenZipCpuAffinity      = ""                              # Optional. 7-Zip CPU core affinity.
                                                                      # Examples: "0,1" (for cores 0 and 1), "0x3" (bitmask for cores 0 and 1).
                                                                      # Empty string or $null means no affinity is set (7-Zip uses all available cores).
                                                                      # This is passed to Start-Process -Affinity.
    DefaultSevenZipIncludeListFile  = ""                              # Global default path to a 7-Zip include list file (e.g., "C:\BackupConfig\GlobalIncludes.txt"). Used with -i@.
    DefaultSevenZipExcludeListFile  = ""                              # Global default path to a 7-Zip exclude list file (e.g., "C:\BackupConfig\GlobalExcludes.txt"). Used with -x@.

    DefaultSevenZipTempDirectory    = ""                              # Optional. Global default path to a directory for 7-Zip's temporary files. If empty, 7-Zip uses the system default.
                                                                      # This location must already exist, if specified.

    DefaultArchiveType              = "-t7z"                          # 7-Zip -t (type) switch. Examples: -t7z, -tzip, -ttar, -tgzip.
                                                                      # This determines the internal format of the archive, even if an SFX (.exe) is created.
    DefaultArchiveExtension         = ".7z"                           # Default file extension for generated archives if NOT creating an SFX.
                                                                      # If CreateSFX is true for a job, the extension will be '.exe'.
                                                                      # This setting is still used for matching files during retention policy application if SFX is not used.
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
    DefaultFollowSymbolicLinks      = $false                          # Global default. If $false (default), 7-Zip will NOT follow symbolic links/junctions (uses -snl switch).
                                                                      # Set to $true to have 7-Zip follow links and archive their target content. This can sometimes cause
                                                                      # "Access is denied" warnings on certain system-created junction points.
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
                # Controls if a JobName subdirectory is created under UNCRemotePath.
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
        "ExampleReplicatedStorage" = @{
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
        "ExampleWebDAVServer" = @{ # WebDAV Example
            Type = "WebDAV" # Provider module 'Modules\Targets\WebDAV.Target.psm1' will handle this
            TargetSpecificSettings = @{
                WebDAVUrl             = "https://webdav.example.com/remote.php/dav/files/backupuser" # Full URL to the base WebDAV directory
                CredentialsSecretName = "MyWebDAVUserCredentials" # Secret should store a PSCredential object (Username + Password)
                # CredentialsVaultName  = "MySpecificVault"       # Optional: Specify vault if not default
                RemotePath            = "PoShBackupArchives"      # Optional: Relative path within the WebDAVUrl to store backups. If empty, uses WebDAVUrl root.
                CreateJobNameSubdirectory = $true                 # Optional: If $true, creates /PoShBackupArchives/JobName/. Default is $false.
                RequestTimeoutSec     = 120                     # Optional: Timeout for WebDAV requests in seconds. Default is 120.
            }
            RemoteRetentionSettings = @{
                KeepCount = 5 # Example: Keep the last 5 backup instances on this WebDAV target.
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
    # Defines default behavior for actions to take after a job or set completes.
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

    #region --- NEW: Automated Backup Verification ---
    # Define automated verification jobs. These run independently of backup jobs via a new CLI switch.
    VerificationJobs = @{
        # Example verification job.
        "Verify_Pojects" = @{
            # Master switch for this verification job. Set to $true to enable.
            Enabled = $true

            # The name of the backup job (from BackupLocations) whose archives you want to test.
            TargetJobName = "projects"
            
            # The name of the secret (in PowerShell SecretManagement) that holds the password for the
            # archive, if it's encrypted. This is required if the target job creates encrypted archives.
            #ArchivePasswordSecretName = "VMBackupPassword"

            # A temporary, empty directory where the archive will be restored for verification.
            # WARNING: The contents of this directory may be cleared automatically. Do not use an important path.
            SandboxPath = "D:\Backup_Verification_Sandbox"

            # What to do if the sandbox path is not empty when the job starts.
            # "Fail" (default): The verification job will fail.
            # "CleanAndContinue": The verification job will attempt to delete the contents and proceed.
            OnDirtySandbox = "CleanAndContinue"

            # An array of verification steps to perform after the restore.
            # Available steps:
            # - "TestArchive": Simply tests the archive integrity using `7z t`. This happens before restore.
            # - "VerifyChecksums": (Most thorough) For each restored file, recalculates its checksum and
            #   compares it against the value stored in the backup's manifest file. Fails if the manifest
            #   is missing or if any checksum does not match.
            # - "CompareFileCount": A basic check to ensure the number of restored files/folders matches
            #   the count from the archive's listing.
            VerificationSteps = @("TestArchive", "VerifyChecksums")
            
            # How many of the most recent backup instances for the TargetJobName to test.
            # '1' will test only the very latest backup. '3' will test the latest three.
            TestLatestCount = 1
        }
    }
    #endregion

    #region --- Backup Locations (Job Definitions) ---
    # Define individual backup jobs here. Each key in this hashtable represents a unique job name.
    BackupLocations                 = @{
        "Projects"  = @{
            Path                    = "P:\Images\*"                   # Path(s) to back up. Can be a single string or an array of strings for multiple sources.
            Name                    = "Projects"                      # Base name for the archive file (date stamp and extension will be appended).
            DestinationDir          = "D:\Backups"                    # Specific directory for this job. If remote targets are specified, this acts as a LOCAL STAGING area.
            Enabled                 = $true                           # Set to $false to disable this job without deleting its configuration.
            PinOnCreation           = $false                          # Set to $true to automatically pin the archive created by this job, protecting it from retention.
            #TargetNames             = @("ExampleUNCShare")           # OPTIONAL: Array of target names from 'BackupTargets'. E.g., @("ExampleUNCShare")
                                                                      # If no remote targets, this is the FINAL BACKUP DESTINATION.
                                                                      # If empty or not present, this job is local-only to DestinationDir.
            DeleteLocalArchiveAfterSuccessfulTransfer = $true         # Job-specific override. Only effective if TargetNames are specified.

            LocalRetentionCount     = 3                               # Number of archive versions for this job to keep in 'DestinationDir'.
            LogRetentionCount       = 10                              # Job-specific log retention.
            DeleteToRecycleBin      = $false                          # For local retention in 'DestinationDir'.
            RetentionConfirmDelete  = $false                          # Job-specific override for local retention: auto-delete old local archives without prompting.

            DependsOnJobs           = @()                             # Array of job names this job depends on. E.g., @("DatabaseBackupJob")

            ArchivePasswordMethod   = "None"                          # Password method: "None", "Interactive", "SecretManagement", "SecureStringFile", "PlainText". See instructions at top.
            # CredentialUserNameHint  = "ProjectBackupUser"           # For "Interactive" method.
            # ArchivePasswordSecretName = ""                          # For "SecretManagement" method.
            # ArchivePasswordVaultName  = ""                          # Optional for "SecretManagement".
            # ArchivePasswordSecureStringPath = ""                    # For "SecureStringFile" method.
            # ArchivePasswordPlainText  = ""                          # For "PlainText" method (INSECURE).

            # UsePassword             = $false                        # Legacy. If ArchivePasswordMethod is "None" and this is $true, "Interactive" is used.

            EnableVSS               = $false                          # $true to use VSS for this job (requires Admin). Overrides global EnableVSS.
            SevenZipProcessPriority = "Normal"                        # Override global 7-Zip priority for this specific job.
            SevenZipCpuAffinity     = ""                              # Job-specific CPU affinity for 7-Zip. E.g., "0,1" or "0x3". Empty means use global default.
            # SevenZipIncludeListFile = "D:\MyIncludes.txt"           # Job-specific include list file.
            # SevenZipExcludeListFile = "D:\MyExcludes.txt"           # Job-specific exclude list file.
            SevenZipTempDirectory   = ""                              # Optional. Job-specific path for 7-Zip's temporary files. Overrides global default. Must already exist.
            ReportGeneratorType     = @("HTML")                       # Report type(s) for this job. Overrides global ReportGeneratorType.
            FollowSymbolicLinks     = $false                          # Job-specific override for following symbolic links.
            TreatSevenZipWarningsAsSuccess = $false                   # Optional per-job override. If $true, 7-Zip exit code 1 (Warning) is treated as success for this job.

            CreateSFX               = $false                          # Job-specific. $true to create a Self-Extracting Archive (.exe).
            SFXModule               = "Console"                       # Job-specific SFX module type. "Console", "GUI", "Installer".
                                                                      # If CreateSFX is $true, ArchiveExtension effectively becomes ".exe".
            #SplitVolumeSize         = ""                             # Job-specific volume size (e.g., "100m", "4g"). Empty for no split.
            #GenerateSplitArchiveManifest = $false                    # Job-specific. $true to generate a manifest for split archives. Overrides GenerateArchiveChecksum for the primary archive.

            GenerateArchiveChecksum       = $true                     # Example: Enable checksum generation for this job
            GenerateContentsManifest      = $true
            ChecksumAlgorithm             = "SHA256"                  # Use SHA256
            VerifyArchiveChecksumOnTest   = $true                     # Verify checksum if TestArchiveAfterCreation is also true

            PreBackupScriptPath           = ""                        # A script to run before this specific backup job begins.
            PostLocalArchiveScriptPath    = ""                        # A script to run after local archive creation/testing, but BEFORE remote transfers.
            PostBackupScriptOnSuccessPath = ""                        # A script to run after this backup job completes with a status of SUCCESS or WARNINGS.
            PostBackupScriptOnFailurePath = ""                        # A script to run after this backup job completes with a status of FAILURE.
            PostBackupScriptAlwaysPath    = ""                        # A script to run after a backup job finishes, regardless of status.

            # --- Notification Settings for this Job ---
            # These settings override the DefaultNotificationSettings.
            NotificationSettings = @{
                Enabled         = $false                              # Set to $true to enable alerts for this specific job.
                ProfileName     = ""                                  # Which profile from NotificationProfiles to use.
                #ToAddress       = @("your_email@example.com")        # For Email provider
                TriggerOnStatus = @("ANY")                            # Notify regardless of whether this job succeeds, warns, or fails.
            }

            # PostRunAction = @{
            #     Enabled         = $true
            #     Action          = "Shutdown"
            #     DelaySeconds    = 60
            #     TriggerOnStatus = @("SUCCESS", "WARNINGS")
            #     ForceAction     = $false
            # }
            Schedule = @{ Enabled = $false } # Placeholder for this job
        }
        "AnExample_WithRemoteTarget" = @{
            Path                       = "C:\Users\YourUser\Documents\ImportantDocs\*"
            Name                       = "MyImportantDocuments"
            DestinationDir             = "D:\Backups\LocalStage"      # LOCAL STAGING directory, as TargetNames are specified below. Archive is created here first.
            Enabled                    = $true                        # Set to $false to disable this job without deleting its configuration.
            PinOnCreation              = $false                       # Set to $true to automatically pin the archive created by this job.

            TargetNames                = @("ExampleUNCShare")         # Archive will be sent to "ExampleUNCShare" (defined in BackupTargets) after local creation.
            DeleteLocalArchiveAfterSuccessfulTransfer = $true         # Delete from local staging after successful transfer to ALL targets.

            LocalRetentionCount        = 5                            # Number of archive versions to keep in the local 'DestinationDir'.
            # LogRetentionCount will use DefaultLogRetentionCount (e.g., 30)
            DeleteToRecycleBin         = $true                        # Note: Ensure this is appropriate if 'DestinationDir' is a network share (less common for staging).
            RetentionConfirmDelete     = $false                       # Example: This job will auto-delete old local archives without prompting.

            DependsOnJobs              = @()

            ArchivePasswordMethod      = "Interactive"                # Example: Prompts for password for this job.
            CredentialUserNameHint     = "DocsUser"

            ArchiveType                = "-tzip"                      # Example: Use ZIP format for this job. Overrides DefaultArchiveType.
            ArchiveExtension           = ".zip"                       # Must match ArchiveType. Overrides DefaultArchiveExtension.
                                                                      # If CreateSFX is $true, this will be overridden to ".exe" for the final file.
            CreateSFX                  = $false                       # Example, not creating SFX here.
            SFXModule                  = "Console"                    # Default if CreateSFX is false, but good to show.
            SplitVolumeSize            = "700m"                       # NEW EXAMPLE: Split into 700MB volumes.
            GenerateSplitArchiveManifest = $true                     # NEW EXAMPLE: Generate manifest for these split volumes.
            ArchiveDateFormat          = "dd-MM-yyyy"                 # Custom date format for this job's archives. Overrides DefaultArchiveDateFormat.
            MinimumRequiredFreeSpaceGB = 2                            # Custom free space check for local staging. Overrides global setting.
            HtmlReportTheme            = "RetroTerminal"              # Use a specific HTML report theme for this job.
            TreatSevenZipWarningsAsSuccess = $true                    # Example: For this job, 7-Zip warnings are considered success.
            SevenZipCpuAffinity        = "0"                          # Example: Restrict 7-Zip to core 0 for this job.
            SevenZipIncludeListFile    = ""
            SevenZipExcludeListFile    = ""

            # Checksum settings (will use global defaults if not specified here, e.g., DefaultGenerateArchiveChecksum = $false)
            # GenerateArchiveChecksum     = $false # This would be ignored if GenerateSplitArchiveManifest is true for a split archive.
            # VerifyArchiveChecksumOnTest = $false

            NotificationSettings = @{
                Enabled         = $false
            }
            # PostRunAction = @{ Enabled = $false }                   # Example: Explicitly disable for this job
            Schedule = @{ Enabled = $false } # Placeholder for this job
        }
        "HyperV_VM_Backup_Example" = @{
            # --- NEW: Snapshot Orchestration Example ---
            # When using a SnapshotProvider with 'SourceIsVMName = $true', 'Path' becomes an array where:
            # - Element 0 is the Name of the Virtual Machine to be snapshotted.
            # - Subsequent elements (optional) are the specific paths *inside* the VM to back up.
            #   If only the VM name is provided (e.g., Path = "MyVM"), the entire mounted VM disk will be backed up.
            Path                     = @(
                "Windows10",                                          # Element 0: The VM Name. <-- CHANGE THIS to your test VM name.
                "C:\Users\Public"                                     # Element 1 (Optional): A specific folder to back up from the snapshot.
                #"D:\Data\Important"                                  # Element 2 (Optional): Another folder from another drive in the VM.
            )
            SourceIsVMName           = $true                           # Tells PoSh-Backup to treat 'Path' as a VM name for the snapshot provider.
            SnapshotProviderName     = "LocalHyperV"                   # Links this job to the 'LocalHyperV' provider defined in 'SnapshotProviders'.

            Name                     = "Windows10"
            DestinationDir           = "D:\Backups"                    # <-- CHANGE THIS to a valid path on your system.
            GenerateContentsManifest = $true
            Enabled                  = $true
            LocalRetentionCount      = 5
            #TargetNames             = @("ExampleUNCShare")
            DeleteLocalArchiveAfterSuccessfulTransfer = $true

            # VSS is still relevant. The snapshot provider will trigger VSS *inside* the guest VM
            # to ensure application-consistent snapshots. Requires Hyper-V Integration Services in the guest.
            EnableVSS                = $true

            # Other settings apply as normal to the resulting archive.
            ArchivePasswordMethod    = "None" #"SecretManagement"
            ArchivePasswordSecretName = "VMBackupPassword"
            TreatSevenZipWarningsAsSuccess = $true
            NotificationSettings = @{
                Enabled         = $false
                ProfileName     = "Office365"
                ToAddress       = @("vm-admins@example.com")
                TriggerOnStatus = @("FAILURE")
            }
            Schedule = @{
                Enabled = $true
                Type = 'Daily'
                Time = '02:00'
            }
        }
        #region --- Comprehensive Example (Commented Out for Reference) ---
        <#
        "ComprehensiveExample_WebApp" = @{
            Path                    = @(
                                        "C:\inetpub\wwwroot\MyWebApp",
                                        "D:\Databases\MyWebApp_Config.xml"
                                      )
            Name                    = "WebApp_Production"
            DestinationDir          = "\\BACKUPSERVER\Share\WebApps\LocalStage_WebApp"
            Enabled                 = $true                                    # Set to $false to disable this job without deleting its configuration.
            PinOnCreation           = $true                                    # This important backup will be pinned.

            LocalRetentionCount                       = 1
            LogRetentionCount                         = 15                     # Example: Keep 15 logs for this specific job
            VerifyLocalArchiveBeforeTransfer          = $false                 # Job-specific override. $true to test local archive before remote transfer.
            DeleteLocalArchiveAfterSuccessfulTransfer = $true
            RetentionConfirmDelete  = $false

            DependsOnJobs           = @("ComprehensiveExample_Database") # NEW EXAMPLE

            TargetNames             = @(
                                        "ExampleUNCShare"
                                        # "ExampleS3Bucket"
                                      )

            ArchivePasswordMethod   = "SecretManagement"
            ArchivePasswordSecretName = "WebAppBackupPassword"
            # ArchivePasswordVaultName= "MyProductionVault"

            ArchiveType             = "-t7z"
            ArchiveExtension        = ".7z"
            CreateSFX               = $true                           # Example: Create SFX
            SFXModule               = "Installer"                     # Example: Use Installer SFX
            SplitVolumeSize         = ""                              # No split if SFX is primary goal.
            # GenerateSplitArchiveManifest = $false                   # Not applicable if not splitting.
            ArchiveDateFormat       = "yyyy-MM-dd_HHmm"

            ThreadsToUse            = 2
            SevenZipProcessPriority = "BelowNormal"
            SevenZipCpuAffinity     = "0,1,2,3"                       # Example: Use first 4 cores
            SevenZipIncludeListFile = "\\SHARE\Config\WebApp_Includes.txt"
            SevenZipExcludeListFile = "\\SHARE\Config\WebApp_Excludes.txt"
            AdditionalExclusions    = @(
                                        "*\logs\*.log",
                                        "*\temp\*",
                                        "web.config.temp",
                                        "*.TMP"
                                        )

            EnableVSS                     = $true
            VSSContextOption              = "Volatile NoWriters"

            EnableRetries                 = $true
            MaxRetryAttempts              = 2
            RetryDelaySeconds             = 120

            MinimumRequiredFreeSpaceGB    = 50
            ExitOnLowSpaceIfBelowMinimum  = $true
            TestArchiveAfterCreation      = $true
            TreatSevenZipWarningsAsSuccess = $false

            GenerateArchiveChecksum     = $true # This would be ignored if GenerateSplitArchiveManifest is true and SplitVolumeSize is active.
            ChecksumAlgorithm           = "SHA256"
            VerifyArchiveChecksumOnTest = $true

            ReportGeneratorType           = @("HTML", "JSON")
            HtmlReportTheme               = "Dark"
            HtmlReportDirectory           = "\\SHARE\AdminReports\PoShBackup\WebApp"
            HtmlReportTitlePrefix         = "Web Application Backup Status"
            HtmlReportLogoPath            = "\\SHARE\Branding\WebAppLogo.png"
            HtmlReportFaviconPath         = "\\SHARE\Branding\WebAppFavicon.ico"
            HtmlReportCustomCssPath       = "\\SHARE\Branding\WebAppReportOverrides.css"
            HtmlReportOverrideCssVariables = @{
                "--accent-colour"        = "darkred";
                "--header-border-colour" = "black";
            }

            PreBackupScriptPath           = "C:\Scripts\BackupPrep\WebApp_PreBackup.ps1"
            PostBackupScriptOnSuccessPath = "C:\Scripts\BackupPrep\WebApp_PostSuccess.ps1"
            PostBackupScriptOnFailurePath = "C:\Scripts\BackupPrep\WebApp_PostFailure_Alert.ps1"
            PostBackupScriptAlwaysPath    = "C:\Scripts\BackupPrep\WebApp_PostAlways_Cleanup.ps1"

            NotificationSettings = @{
                Enabled         = $true
                ProfileName     = "Office365"
                ToAddress       = @("webapp-alerts@example.com")
                TriggerOnStatus = @("FAILURE", "WARNINGS")
            }
            # PostRunAction = @{
            #     Enabled         = $true
            #     Action          = "LogOff"
            #     DelaySeconds    = 300
            #     TriggerOnStatus = @("ANY")
            # }
            Schedule = @{ Enabled = $false } # Placeholder for this job
        }
        "ComprehensiveExample_Database" = @{ # Example of a prerequisite job
            Path                    = "D:\SQL_Backups\MyWebAppDB.bak"
            Name                    = "Database_Production"
            DestinationDir          = "\\BACKUPSERVER\Share\DBs\LocalStage_DB"
            LocalRetentionCount     = 3
            DependsOnJobs           = @() # No dependencies for this one
            SplitVolumeSize         = ""  # No split
            # GenerateSplitArchiveManifest = $false
            # ... other settings ...
            NotificationSettings = @{
                Enabled         = $false
            }
            Schedule = @{ Enabled = $false } # Placeholder for this job
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
            JobNames     = @(
                "Projects",
                "HyperV_VM_Backup_Example"
            )
            OnErrorInJob = "StopSet"
            LogRetentionCount = 7 # Logs for jobs run as part of this set will keep only 7 files, overriding their individual or global settings.
            SevenZipIncludeListFile = "C:\BackupConfig\Set_DailyCritical_Includes.txt"
            SevenZipExcludeListFile = "C:\BackupConfig\Set_DailyCritical_Excludes.txt"

            # Notification settings for a set are sent *after the entire set completes*.
            # The status used for TriggerOnStatus will be the overall status of the set.
            # This overrides any NotificationSettings on individual jobs within the set.
            NotificationSettings = @{
                Enabled         = $true
                ProfileName     = "Office365"
                ToAddress       = @("it-team@example.com")
                Subject         = "PoSh-Backup Set Report: {SetName} - Overall Status: {Status}"
                TriggerOnStatus = @("FAILURE", "WARNINGS")
            }

            # PostRunAction = @{
            #     Enabled         = $true
            #     Action          = "Restart"
            #     DelaySeconds    = 120
            #     TriggerOnStatus = @("SUCCESS")
            #     ForceAction     = $true
            # }
        }
        "Weekly_User_Data"       = @{
            JobNames = @(
                "AnExample_WithRemoteTarget"
            )
            # OnErrorInJob defaults to "StopSet" if not specified for a set.
            # LogRetentionCount will be inherited from each job's config or global default.
            SevenZipIncludeListFile = ""
            SevenZipExcludeListFile = ""
            # PostRunAction = @{ Enabled = $false }
            NotificationSettings = @{
                Enabled         = $false
            }
        }
        "Nightly_Full_System_Simulate" = @{
            JobNames = @("Projects", "AnExample_WithRemoteTarget", "HyperV_VM_Backup_Example")
            OnErrorInJob = "ContinueSet"
            SevenZipIncludeListFile = ""
            SevenZipExcludeListFile = ""
            # Note: To run this set in simulation mode, you would use:
            # .\PoSh-Backup.ps1 -RunSet "Nightly_Full_System_Simulate" -Simulate
        }
    }
    #endregion
}
