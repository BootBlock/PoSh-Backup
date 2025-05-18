# PowerShell Data File for PoSh Backup Script Configuration (Default).
# --> THIS WILL GET OVERWRITTEN ON UPGRADE if you do not use a User.psd1 file for your customisations! <--
# It is strongly recommended to copy this file to 'User.psd1' in the same 'Config' directory
# and make all your modifications there. User.psd1 will override these defaults.
#
# Version 1.2.2: Added TreatSevenZipWarningsAsSuccess setting.
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
    DefaultDestinationDir           = "D:\Backups"                    # Default directory where backup archives will be stored if not specified per job.
                                                                      # Ensure this path exists, or the script has permissions to create it.
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
    EnableAdvancedSchemaValidation  = $false                          # $true to enable detailed schema-based validation of this configuration file's structure and values.
                                                                      # If $true, the 'PoShBackupValidator.psm1' module must be present in the '.\Modules' folder.
                                                                      # Recommended for advanced users or when troubleshooting configuration issues.
    TreatSevenZipWarningsAsSuccess  = $false                          # Global default. $true to treat 7-Zip exit code 1 (Warning) as a success for the job's status.
                                                                      # If $false (default), 7-Zip warnings will result in the job status being "WARNINGS".
                                                                      # Useful if backups commonly encounter benign warnings (e.g., files in use that are skipped).
                                                                      # Can be overridden per job or by the -TreatSevenZipWarningsAsSuccessCLI command-line parameter.
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
    MinimumRequiredFreeSpaceGB      = 5                               # Minimum free Gigabytes (GB) required on the destination drive before starting a backup.
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

    #region --- Backup Locations (Job Definitions) ---
    # Define individual backup jobs here. Each key in this hashtable represents a unique job name.
    BackupLocations                 = @{
        "Projects"  = @{
            Path                    = "P:\Images\*"                   # Path(s) to back up. Can be a single string or an array of strings for multiple sources.
                                                                      # Wildcards are supported as per 7-Zip's capabilities.
            Name                    = "Projects"                      # Base name for the archive file (date stamp and extension will be appended).
            DestinationDir          = "D:\Backups"                    # Specific destination for this job. If omitted, DefaultDestinationDir is used.
            RetentionCount          = 3                               # Number of archive versions for this job to keep. Older archives beyond this count will be deleted.
            DeleteToRecycleBin      = $false                          # $true to send old archives to the Recycle Bin; $false for permanent deletion.

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
        }
        "AnExample" = @{
            Path                       = "C:\Users\YourUser\Documents\ImportantDocs\*"
            Name                       = "MyImportantDocuments"
            ArchiveType                = "-tzip"                         # Example: Use ZIP format for this job. Overrides DefaultArchiveType.
            ArchiveExtension           = ".zip"                          # Must match ArchiveType. Overrides DefaultArchiveExtension.
            ArchiveDateFormat          = "dd-MM-yyyy"                    # Custom date format for this job's archives. Overrides DefaultArchiveDateFormat.
            RetentionCount             = 5
            DeleteToRecycleBin         = $true

            ArchivePasswordMethod      = "Interactive"                   # Example: Prompts for password for this job.
            CredentialUserNameHint     = "DocsUser"

            MinimumRequiredFreeSpaceGB = 2                               # Custom free space check for this job. Overrides global setting.
            HtmlReportTheme            = "RetroTerminal"                 # Use a specific HTML report theme for this job.
            TreatSevenZipWarningsAsSuccess = $true                      # Example: For this job, 7-Zip warnings are considered success.
        }

        #region --- Comprehensive Example (Commented Out for Reference) ---
        <#
        "ComprehensiveExample_WebApp" = @{
            "Path"                    = @(                             # Multiple source paths can be specified in an array.
                                        "C:\inetpub\wwwroot\MyWebApp",
                                        "D:\Databases\MyWebApp_Config.xml"
                                      )
            "Name"                    = "WebApp_Production"
            "DestinationDir"          = "\\BACKUPSERVER\Share\WebApps"  # Example: Backup to a network share.
            "RetentionCount"          = 14                              # Keep two weeks of daily backups.
            "DeleteToRecycleBin"      = $false                          # Recycle Bin might not be applicable/desired for network shares.

            "ArchivePasswordMethod"   = "SecretManagement"
            "ArchivePasswordSecretName" = "WebAppBackupPassword"        # Name of the secret stored in SecretManagement.
            # "ArchivePasswordVaultName"= "MyProductionVault"           # Optional: Specify vault if not default.

            "ArchiveType"             = "-t7z"
            "ArchiveExtension"        = ".7z"
            "ArchiveDateFormat"       = "yyyy-MM-dd_HHmm"               # More granular date format for frequent backups.

            "ThreadsToUse"            = 2                               # Override DefaultThreadCount to limit CPU impact.
            "SevenZipProcessPriority" = "BelowNormal"
            "CompressionLevel"        = "-mx=5"                         # Balance of speed and compression.
            "AdditionalExclusions"    = @(                             # Array of 7-Zip exclusion patterns specific to this job.
                                        "*\logs\*.log",                 # Exclude all .log files in any 'logs' subfolder.
                                        "*\temp\*",                     # Exclude all temp folders and their contents.
                                        "web.config.temp",
                                        "*.TMP"
                                        )

            "EnableVSS"                     = $true
            "VSSContextOption"              = "Volatile NoWriters"      # Recommended for scripted backups; snapshot auto-deleted.

            "EnableRetries"                 = $true
            "MaxRetryAttempts"              = 2
            "RetryDelaySeconds"             = 120                       # Longer delay, perhaps for transient network issues.

            "MinimumRequiredFreeSpaceGB"    = 50
            "ExitOnLowSpaceIfBelowMinimum"  = $true
            "TestArchiveAfterCreation"      = $true                     # Always test this critical backup.
            "TreatSevenZipWarningsAsSuccess" = $false                   # Explicitly keep default behavior for this critical job.

            "ReportGeneratorType"           = @("HTML", "JSON")         # Generate both HTML and JSON reports.
            "HtmlReportTheme"               = "Dark"
            "HtmlReportDirectory"           = "\\SHARE\AdminReports\PoShBackup\WebApp" # Custom directory for this job's HTML reports.
            "HtmlReportTitlePrefix"         = "Web Application Backup Status"
            "HtmlReportLogoPath"            = "\\SHARE\Branding\WebAppLogo.png"
            "HtmlReportCustomCssPath"       = "\\SHARE\Branding\WebAppReportOverrides.css"
            "HtmlReportCompanyName"         = "Production Services Ltd."
            "HtmlReportOverrideCssVariables" = @{
                "--accent-colour"        = "darkred";
                "--header-border-colour" = "black";
            }
            # "HtmlReportShowSummary"       = $true # These default to $true if not specified
            # "HtmlReportShowConfiguration" = $true
            # "HtmlReportShowHooks"         = $true
            # "HtmlReportShowLogEntries"    = $true

            # Paths to custom PowerShell scripts to run at different stages of this specific job.
            "PreBackupScriptPath"           = "C:\Scripts\BackupPrep\WebApp_PreBackup.ps1"
            "PostBackupScriptOnSuccessPath" = "C:\Scripts\BackupPrep\WebApp_PostSuccess.ps1"
            "PostBackupScriptOnFailurePath" = "C:\Scripts\BackupPrep\WebApp_PostFailure_Alert.ps1"
            "PostBackupScriptAlwaysPath"    = "C:\Scripts\BackupPrep\WebApp_PostAlways_Cleanup.ps1"
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
                "AnExample"
                # "ComprehensiveExample_WebApp" # If uncommented and defined above.
            )
            OnErrorInJob = "StopSet"                                 # Defines behaviour if a job within this set fails.
                                                                      # "StopSet": (Default) If a job fails, subsequent jobs in THIS SET are skipped. The script may continue to other sets if applicable.
                                                                      # "ContinueSet": Subsequent jobs in THIS SET will attempt to run even if a prior one fails.
        }
        "Weekly_User_Data"       = @{
            JobNames = @(
                "AnExample"
            )
            # OnErrorInJob defaults to "StopSet" if not specified for a set.
        }
        "Nightly_Full_System_Simulate" = @{                           # Example for a simulation run of multiple jobs.
            JobNames = @("Projects", "AnExample")
            OnErrorInJob = "ContinueSet"
            # Note: To run this set in simulation mode, you would use:
            # .\PoSh-Backup.ps1 -RunSet "Nightly_Full_System_Simulate" -Simulate
        }
    }
    #endregion
}
