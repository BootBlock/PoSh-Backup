# PowerShell Data File for PoSh Backup Script Configuration (Default).
# --> THIS WILL GET OVERWRITTEN ON UPGRADE if you don't use a User.psd1 for your changes! <--
# Version 1.2: Added EnableAdvancedSchemaValidation. SevenZipPath empty for auto-detection. Comments reformatted.
@{
    #region --- General Global Settings ---
    SevenZipPath                    = ""                              # Full path to 7z.exe. Leave empty to attempt auto-detection.
                                                                      # If auto-detection fails, script will error.
    DefaultDestinationDir           = "D:\Backups"                    # Default backup destination if not specified per job.
                                                                      # Ensure this path exists or can be created by the script.
    HideSevenZipOutput              = $true                           # $true to hide 7-Zip's console window during compression/testing.
                                                                      # $false to show it (can be useful for diagnosing 7-Zip issues).
                                                                      # Note: If true, STDOUT/STDERR are captured and logged by PoSh-Backup.
    PauseBeforeExit                 = "OnFailureOrWarning"            # Controls if the script pauses before exiting.
                                                                      # Valid string values (case-insensitive), or boolean $true/$false:
                                                                      #   "Always" or $true: Always pause (unless -Simulate is used).
                                                                      #   "Never" or $false: Never pause.
                                                                      #   "OnFailure": Pause only if the overall script status is FAILURE.
                                                                      #   "OnWarning": Pause only if the overall script status is WARNINGS.
                                                                      #   "OnFailureOrWarning": Pause if status is FAILURE OR WARNINGS (default).
    EnableAdvancedSchemaValidation  = $false                          # $true to enable detailed schema validation via PoShBackupValidator.psm1.
                                                                      # If $true, PoShBackupValidator.psm1 must be present in Modules folder.
                                                                      # Recommended for advanced users or during config troubleshooting.
    #endregion

    #region --- Logging Settings ---
    EnableFileLogging               = $true                           # $true to enable detailed text log files per job, $false to disable.
    LogDirectory                    = "Logs"                          # Directory to store log files. If relative, it's from PSScriptRoot (e.g., ".\Logs").
                                                                      # Can be an absolute path (e.g., "C:\BackupLogs").
                                                                      # The script will attempt to create this directory if it doesn't exist.
    #endregion

    #region --- Reporting Settings (Global Defaults) ---
    ReportGeneratorType             = "HTML"                          # Primary report type. Options: "HTML", "None". (Future: "CSV", "XML")
                                                                      # This can be overridden per job.
    
    # --- HTML Specific Reporting Settings (used if ReportGeneratorType is "HTML") ---
    HtmlReportDirectory             = "Reports"                       # Directory to store HTML reports. If relative, from PSScriptRoot (e.g., ".\Reports").
                                                                      # Can be an absolute path. Script will attempt to create it.
    HtmlReportTitlePrefix           = "PoSh Backup Status Report"     # Prefix for the HTML report browser title and H1 tag. Job name is appended.
    HtmlReportLogoPath              = ""                              # Optional: Full UNC or local path to a logo image (PNG, JPG, GIF, SVG).
                                                                      # If provided and valid, the logo will be embedded in the report header.
    HtmlReportCustomCssPath         = ""                              # Optional: Full path to a user-provided .css file for additional or overriding report styling.
                                                                      # This CSS is loaded *after* the selected theme's CSS and any CSS variable overrides.
    HtmlReportCompanyName           = "Joe Cox"                       # Company name, or your name, displayed in the report footer.
    HtmlReportTheme                 = "Light"                         # Name of the theme CSS file (without .css extension) located in 'Config\Themes'
                                                                      # relative to PoSh-Backup.ps1.
                                                                      # Built-in: "Light", "Dark", "HighContrast", "Playful", "RetroTerminal".
                                                                      # A 'Base.css' in 'Config\Themes' is always loaded first.
    
    # Override specific CSS variables for the selected theme (or base if no theme).
    # This allows fine-grained colour/style adjustments without creating a whole new theme file.
    # Keys should be valid CSS variable names (e.g., "--accent-color"), values are valid CSS color codes/values.
    HtmlReportOverrideCssVariables  = @{                            
        # Example: To change the main accent colour for all HTML reports globally:
        # "--accent-color"       = "#005A9C" # A specific shade of blue
        # To change the main container background for all reports:
        # "--container-bg-color" = "#FAFAFA" 
    }
    HtmlReportShowSummary           = $true                           # $true to include the summary table in the HTML report.
    HtmlReportShowConfiguration     = $true                           # $true to include the job configuration details used for the backup.
    HtmlReportShowHooks             = $true                           # $true to include details of executed hook scripts and their status/output.
    HtmlReportShowLogEntries        = $true                           # $true to include the detailed log messages from the script execution.
    #endregion

    #region --- Volume Shadow Copy Service (VSS) Settings (Global Defaults) ---
    EnableVSS                       = $false                          # Global default. $true to attempt using VSS (requires Admin).
                                                                      # Can be overridden per job or by CLI.
    DefaultVSSContextOption         = "Persistent NoWriters"          # Diskshadow SET CONTEXT option.
                                                                      # "Persistent": Allows writers, snapshot persists (needs manual cleanup on script failure).
                                                                      # "Persistent NoWriters": Tries to exclude writers during shadow creation. Persists.
                                                                      # "Volatile NoWriters": Snapshot auto-deleted. Safer for scripted backups.
    VSSMetadataCachePath            = "%TEMP%\diskshadow_cache_poshbackup.cab" # Path for diskshadow's metadata cache file. %TEMP% is expanded.
    VSSPollingTimeoutSeconds        = 120                             # How long (seconds) to wait for VSS shadow copies to become available via WMI.
    VSSPollingIntervalSeconds       = 5                               # How often (seconds) to poll WMI while waiting for shadow copies.
    #endregion

    #region --- Retry Mechanism Settings (Global Defaults) ---
    EnableRetries                   = $true                           # Global default. $true to enable retries for 7-Zip operations. Can be overridden.
    MaxRetryAttempts                = 3                               # Max number of retry attempts for a failed 7-Zip operation (compression or test).
    RetryDelaySeconds               = 60                              # Delay in seconds between 7-Zip retry attempts.
    #endregion

    #region --- 7-Zip Process Priority Settings (Global Default) ---
    DefaultSevenZipProcessPriority  = "BelowNormal"                   # Windows process priority for 7z.exe.
                                                                      # Options: "Idle", "BelowNormal", "Normal", "AboveNormal", "High".
                                                                      # "BelowNormal" is a good compromise for background tasks.
    #endregion

    #region --- Destination Free Space Check Settings (Global Defaults) ---
    MinimumRequiredFreeSpaceGB      = 5                               # Minimum free Gigabytes required on destination. 0 or less to disable check.
    ExitOnLowSpaceIfBelowMinimum    = $false                          # $true to abort job if free space is below minimum, $false to only warn.
    #endregion

    #region --- Archive Integrity Test Settings (Global Default) ---
    DefaultTestArchiveAfterCreation = $false                          # $true to test archive integrity using '7z t' after creation. Can be overridden.
    #endregion

    #region --- Archive Filename Settings (Global Default) ---
    DefaultArchiveDateFormat        = "yyyy-MMM-dd"                   # Default .NET date format string for the date part of archive filenames.
                                                                      # Examples: "yyyy-MM-dd", "dd-MMM-yyyy_HH-mm-ss" (includes time), "yyMMdd".
    #endregion

    #region --- Global 7-Zip Parameter Defaults ---
    # These are passed directly to 7-Zip if not overridden at the job level.
    # Refer to 7-Zip documentation for the meaning of these switches.
    DefaultThreadCount              = 0                               # 7-Zip -mmt switch. 0 for 7-Zip auto-detection (usually optimal).
                                                                      # Set to a specific number (e.g., -mmt=4) to limit CPU usage.
    DefaultArchiveType              = "-t7z"                          # 7-Zip -t switch (e.g., -t7z, -tzip, -ttar, -tgzip).
    DefaultArchiveExtension         = ".7z"                           # Default file extension for archives. Should logically match DefaultArchiveType.
                                                                      # This is used for naming and retention policy matching.
    DefaultCompressionLevel         = "-mx=7"                         # 7-Zip -mx switch (e.g., -mx=0 store, -mx=1 fastest, -mx=5 normal, -mx=7 max, -mx=9 ultra).
    DefaultCompressionMethod        = "-m0=LZMA2"                     # 7-Zip -m0 switch (e.g., -m0=LZMA2, -m0=PPMd, -m0=Deflate for ZIP).
    DefaultDictionarySize           = "-md=128m"                      # 7-Zip -md switch.
    DefaultWordSize                 = "-mfb=64"                       # 7-Zip -mfb switch.
    DefaultSolidBlockSize           = "-ms=16g"                       # 7-Zip -ms switch (e.g., -ms=on solid, -ms=off non-solid, -ms=4g for 4GB blocks).
    DefaultCompressOpenFiles        = $true                           # 7-Zip -ssw switch (Compress shared files). VSS is generally better for open/locked files.
    DefaultScriptExcludeRecycleBin  = '-x!$RECYCLE.BIN'               # Default 7-Zip exclusion for Recycle Bin folders on all drives.
    DefaultScriptExcludeSysVolInfo  = '-x!System Volume Information'  # Default 7-Zip exclusion for System Volume Information folders.
    #endregion

    #region --- Password Management Instructions ---
    # To use passwords with backups:
    # 1. For the desired backup location below, set 'UsePassword = $true'.
    # 2. Optionally, set 'CredentialUserNameHint' to pre-fill the username in the Get-Credential dialogue.
    # 3. When the script runs for that location, it will prompt for credentials using Get-Credential.
    #    The password obtained is written to a temporary, secure file and 7-Zip is instructed to read the
    #    password from this file using its -spf switch. The temporary file is deleted immediately after 7-Zip exits.
    #    This method is more secure than passing the password directly on the command line.
    #    The 7-Zip switch -mhe=on (encrypt headers) is automatically added when a password is used.
    #
    # For Non-Interactive/Scheduled Tasks (Advanced):
    # Get-Credential is an interactive command. For fully automated/scheduled tasks:
    #   - Manage the password securely outside this script (e.g., PowerShell SecretManagement module,
    #     Windows Credential Manager, or storing an encrypted password with DPAPI).
    #   - Retrieve and decrypt it within a wrapper script or a PreBackupScript hook.
    #   - The decrypted plain-text password would then need to be made available to this script,
    #     perhaps by modifying this script or by a hook script creating the temporary password file.
    #   - The current PoSh-Backup version relies on interactive Get-Credential if UsePassword = $true.
    #endregion

    BackupLocations                 = @{
        "Projects"  = @{
            Path                    = "P:\Images\*"                          # Path to recursively back-up.
            Name                    = "Projects"                      # Base name for the archive file (before date/extension).
            DestinationDir          = "D:\Backups"                    # Override global DefaultDestinationDir if needed.
            RetentionCount          = 3                               # Number of archive versions to keep.
            DeleteToRecycleBin      = $false                          # $true to send old archives to Recycle Bin, $false for permanent delete.
            UsePassword             = $false                          # Set to $true to enable password protection for this job.
            CredentialUserNameHint  = "ProjectBackupUser"             # Pre-filled username for Get-Credential if UsePassword is $true.
            EnableVSS               = $false                          # $true to use VSS for this job (requires Admin).
            SevenZipProcessPriority = "Normal"                        # Override global 7-Zip priority for this job.
            ReportGeneratorType     = "HTML"                          # Report type for this job ("HTML", "None").
        }
        "AnExample" = @{
            Path                       = "C:\Users\YourUser\Documents\ImportantDocs\*"
            Name                       = "MyImportantDocuments"
            ArchiveType                = "-tzip"                         # Example: Use ZIP format for this job.
            ArchiveExtension           = ".zip"                          # Must match ArchiveType.
            ArchiveDateFormat          = "dd-MM-yyyy"                    # Custom date format for this job's archives.
            RetentionCount             = 5
            DeleteToRecycleBin         = $true
            UsePassword                = $false
            MinimumRequiredFreeSpaceGB = 2                               # Custom free space check for this job.
            ReportGeneratorType        = "HTML"
            HtmlReportTheme            = "Dark"                          # Use the Dark theme for this job's HTML report.
        }

        #region --- Comprehensive Example (Commented Out for Reference) ---
        <#
        "ComprehensiveExample_WebApp" = @{
            "Path"                    = @(                             # Multiple source paths can be specified in an array.
                                        "C:\inetpub\wwwroot\MyWebApp", 
                                        "D:\Databases\MyWebApp_Config.xml"
                                      ) 
            "Name"                    = "WebApp_Production" 
            "DestinationDir"          = "\\BACKUPSERVER\Share\WebApps"  # Backup to a network share.
            "RetentionCount"          = 14                              # Keep two weeks of daily backups.
            "DeleteToRecycleBin"      = $false                          # Recycle Bin often not applicable for network shares.

            "UsePassword"             = $true 
            "CredentialUserNameHint"  = "WebAppBackupUser" 

            "ArchiveType"             = "-t7z"  
            "ArchiveExtension"        = ".7z"   
            "ArchiveDateFormat"       = "yyyy-MM-dd_HHmm"               # More granular date for frequent backups.

            "ThreadsToUse"            = 2                               # Limit CPU impact if 7-Zip's auto-detection is too high.
            "SevenZipProcessPriority" = "BelowNormal" 
            "CompressionLevel"        = "-mx=5"                         # Faster compression than default.
            "CompressOpenFiles"       = $true                           # 7-Zip's own open file handling (VSS is often better).
            "AdditionalExclusions"    = @(                             # Array of 7-Zip exclusion patterns.
                                        "*\logs\*.log",                 # Exclude all .log files in any 'logs' subfolder.
                                        "*\temp\*",                     # Exclude all temp folders and their contents.
                                        "web.config.temp",
                                        "*.TMP"
                                        ) 

            "EnableVSS"                     = $true 
            "VSSContextOption"              = "Volatile NoWriters"      # Snapshot auto-deleted after use. Recommended for scripts.
            
            "EnableRetries"                 = $true 
            "MaxRetryAttempts"              = 2     
            "RetryDelaySeconds"             = 120                       # Longer delay, perhaps for transient network issues.
            
            "MinimumRequiredFreeSpaceGB"    = 50    
            "ExitOnLowSpaceIfBelowMinimum"  = $true 
            "TestArchiveAfterCreation"      = $true                     # Always test this critical backup.
            
            "ReportGeneratorType"           = "HTML" 
            "HtmlReportTheme"               = "RetroTerminal" 
            "HtmlReportDirectory"           = "\\SHARE\AdminReports\PoShBackup\WebApp" 
            "HtmlReportTitlePrefix"         = "Web Application Backup Status"
            "HtmlReportLogoPath"            = "\\SHARE\Branding\WebAppLogo.png"
            "HtmlReportCustomCssPath"       = "\\SHARE\Branding\WebAppReportOverrides.css"
            "HtmlReportCompanyName"         = "Production Services Ltd."
            "HtmlReportOverrideCssVariables" = @{
                "--accent-color"        = "darkred";
                "--header-border-color" = "black";
            }
            "HtmlReportShowSummary"         = $true
            "HtmlReportShowConfiguration"   = $true 
            "HtmlReportShowHooks"           = $true
            "HtmlReportShowLogEntries"      = $true

            # Paths to custom PowerShell scripts to run at different stages.
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
    # Group multiple BackupLocations to run sequentially using the -RunSet CLI parameter.
    BackupSets                      = @{
        "Daily_Critical_Backups" = @{
            JobNames     = @(                                         # Array of job names (keys from BackupLocations defined above).
                "Projects",
                "AnExample"
                # "ComprehensiveExample_WebApp" # If uncommented and defined above.
            )
            OnErrorInJob = "StopSet"                                 # Options: "StopSet" (default) or "ContinueSet".
                                                                      # "StopSet": If a job in this set fails, subsequent jobs in this set are skipped.
                                                                      # "ContinueSet": Subsequent jobs in this set will run even if a prior one fails.
        }
        "Weekly_User_Data"       = @{
            JobNames = @(
                "AnExample"
            )
            # OnErrorInJob defaults to "StopSet" if not specified.
        }
        "Nightly_Full_System_Simulate" = @{                           # Example for a simulation run of multiple jobs.
            JobNames = @("Projects", "AnExample")
            OnErrorInJob = "ContinueSet" 
            # Note: To run this set in simulation, use: 
            # .\PoSh-Backup.ps1 -RunSet "Nightly_Full_System_Simulate" -Simulate
        }
    }
    #endregion
}
