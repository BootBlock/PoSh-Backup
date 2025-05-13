# PowerShell Data File for PoSh Backup Script Configuration (Default). --> THIS WILL GET OVERWRITTEN ON UPGRADE (to be fixed!) <--
# Version 1.0: Enhanced HTML Theming options, including CSS variable overrides.
@{
    #region --- General Global Settings ---
    SevenZipPath                    = "C:\Program Files\7-Zip\7z.exe" # Full path to 7z.exe. Essential for script operation.
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
                                                                      #   "OnFailureOrWarning": Pause if status is FAILURE OR WARNINGS (default behavior).
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
    HtmlReportTheme                 = "Light"                         # Name of the theme CSS file (without .css extension) located in the 'Config\Themes' directory
                                                                      # relative to PoSh-Backup.ps1.
                                                                      # Built-in options (you can add more): "Light", "Dark", "HighContrast", "Playful", "RetroTerminal".
                                                                      # A 'Base.css' file in 'Config\Themes' is always loaded first for foundational styles.
    
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
    EnableVSS                       = $false                          # Global default. $true to attempt using VSS (requires Admin). Can be overridden per job or by CLI.
    DefaultVSSContextOption         = "Persistent NoWriters"          # Diskshadow SET CONTEXT option.
                                                                      # "Persistent": Default, allows writers, snapshot persists after script. (Needs manual cleanup if script fails before VSS removal)
                                                                      # "Persistent NoWriters": Allows writers but tries to exclude them from modifying during shadow creation. Persists.
                                                                      # "Volatile NoWriters": Snapshot is auto-deleted when diskshadow exits or script ends. Often safer for scripted backups.
    VSSMetadataCachePath            = "%TEMP%\diskshadow_cache_poshbackup.cab" # Path for diskshadow's metadata cache file. %TEMP% is expanded.
    VSSPollingTimeoutSeconds        = 120                             # How long (seconds) the script will wait for VSS shadow copies to become available via WMI after creation command.
    VSSPollingIntervalSeconds       = 5                               # How often (seconds) to poll WMI while waiting for shadow copies.
    #endregion

    #region --- Retry Mechanism Settings (Global Defaults) ---
    EnableRetries                   = $true                           # Global default. $true to enable retries for 7-Zip operations. Can be overridden.
    MaxRetryAttempts                = 3                               # Maximum number of retry attempts for a failed 7-Zip operation (compression or test).
    RetryDelaySeconds               = 60                              # Delay in seconds between 7-Zip retry attempts.
    #endregion

    #region --- 7-Zip Process Priority Settings (Global Default) ---
    DefaultSevenZipProcessPriority  = "BelowNormal"                   # Windows process priority for 7z.exe.
                                                                      # Options: "Idle", "BelowNormal", "Normal", "AboveNormal", "High".
                                                                      # "BelowNormal" is a good compromise for background tasks.
    #endregion

    #region --- Destination Free Space Check Settings (Global Defaults) ---
    MinimumRequiredFreeSpaceGB      = 5                               # Minimum free Gigabytes required on destination drive. 0 or less to disable check.
    ExitOnLowSpaceIfBelowMinimum    = $false                          # $true to abort job if free space is below minimum, $false to only warn.
    #endregion

    #region --- Archive Integrity Test Settings (Global Default) ---
    DefaultTestArchiveAfterCreation = $false                          # $true to test archive integrity using '7z t' after successful creation. Can be overridden.
    #endregion

    #region --- Archive Filename Settings (Global Default) ---
    DefaultArchiveDateFormat        = "yyyy-MMM-dd"                   # Default .NET date format string for the date part of archive filenames.
                                                                      # Examples: "yyyy-MM-dd", "dd-MMM-yyyy_HH-mm-ss" (includes time), "yyMMdd".
    #endregion

    #region --- Global 7-Zip Parameter Defaults ---
    # These are passed directly to 7-Zip if not overridden at the job level.
    # Refer to 7-Zip documentation for the meaning of these switches.
    DefaultThreadCount              = 0                               # 7-Zip -mmt switch. 0 for 7-Zip auto-detection of CPU cores (usually optimal).
                                                                      # Set to a specific number (e.g., -mmt=4) to limit CPU usage.
    DefaultArchiveType              = "-t7z"                          # 7-Zip -t switch (e.g., -t7z, -tzip, -ttar, -tgzip).
    DefaultArchiveExtension         = ".7z"                           # Default file extension for archives. Should logically match DefaultArchiveType.
                                                                      # This is used for naming and retention policy matching.
    DefaultCompressionLevel         = "-mx=7"                         # 7-Zip -mx switch (e.g., -mx=0 store, -mx=1 fastest, -mx=5 normal, -mx=7 maximum, -mx=9 ultra).
    DefaultCompressionMethod        = "-m0=LZMA2"                     # 7-Zip -m0 switch (e.g., -m0=LZMA2, -m0=PPMd, -m0=Deflate for ZIP).
    DefaultDictionarySize           = "-md=128m"                      # 7-Zip -md switch.
    DefaultWordSize                 = "-mfb=64"                       # 7-Zip -mfb switch.
    DefaultSolidBlockSize           = "-ms=16g"                       # 7-Zip -ms switch (e.g., -ms=on for solid, -ms=off for non-solid, -ms=4g for 4GB solid blocks).
    DefaultCompressOpenFiles        = $true                           # 7-Zip -ssw switch (Compress shared files). VSS is generally better for reliable backup of open/locked files.
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
    # Get-Credential is an interactive command. For fully automated/scheduled tasks where no user can enter a password:
    #   - You would need to manage the password securely outside this script.
    #   - Options include using the PowerShell SecretManagement module, Windows Credential Manager, or storing
    #     an encrypted password (e.g., using ConvertTo-SecureString and DPAPI) and then retrieving and decrypting
    #     it within a wrapper script or a PreBackupScript hook.
    #   - The decrypted plain-text password would then need to be made available to this script, perhaps by
    #     modifying this script to accept a SecureString parameter or by having a hook script create the
    #     temporary password file that 7-Zip's -spf switch can read.
    #   - The current version of PoSh-Backup relies on interactive Get-Credential if UsePassword = $true.
    #endregion

    BackupLocations                 = @{
        "Projects"  = @{
            Path                    = "P:\*"                    # The path to recursively back-up
            Name                    = "Projects"                # What to call the on-disk file before the file extension
            DestinationDir          = "D:\Backups"              # Change to your destination backup archive location
            RetentionCount          = 3
            DeleteToRecycleBin      = $false
            UsePassword             = $false
            CredentialUserNameHint  = "ProjectBackupUser"
            EnableVSS               = $false
            SevenZipProcessPriority = "Normal"
            ReportGeneratorType     = "HTML"
        }
        "AnExample" = @{
            Path                       = "C:\Users\YourUser\Documents\ImportantDocs\*"
            Name                       = "MyImportantDocuments"
            ArchiveType                = "-tzip"
            ArchiveExtension           = ".zip"
            ArchiveDateFormat          = "dd-MM-yyyy"
            RetentionCount             = 5
            DeleteToRecycleBin         = $true
            UsePassword                = $false
            MinimumRequiredFreeSpaceGB = 2
            ReportGeneratorType        = "HTML"
            HtmlReportTheme            = "Dark"
        }

        #region --- Comprehensive Example (Commented Out for Reference) ---
        <#
        "ComprehensiveExample_WebApp" = @{
            "Path"                    = @(
                                        "C:\inetpub\wwwroot\MyWebApp", 
                                        "D:\Databases\MyWebApp_Config.xml"
                                      ) 
            "Name"                    = "WebApp_Production" 
            "DestinationDir"          = "\\BACKUPSERVER\Share\WebApps" 
            "RetentionCount"          = 14 # Keep two weeks of daily backups
            "DeleteToRecycleBin"      = $false # For network shares, Recycle Bin often not applicable or desired

            "UsePassword"             = $true 
            "CredentialUserNameHint"  = "WebAppBackupUser" 

            "ArchiveType"             = "-t7z"  
            "ArchiveExtension"        = ".7z"   
            "ArchiveDateFormat"       = "yyyy-MM-dd_HHmm" # More granular date for frequent backups

            "ThreadsToUse"            = 2 # Limit CPU impact during business hours
            "SevenZipProcessPriority" = "BelowNormal" 
            "CompressionLevel"        = "-mx=5"  # Faster compression
            "CompressOpenFiles"       = $true   
            "AdditionalExclusions"    = @(
                                        "*\logs\*.log",       # Exclude all .log files in any 'logs' subfolder
                                        "*\temp\*",           # Exclude all temp folders and their contents
                                        "web.config.temp",
                                        "*.TMP"
                                        ) 

            "EnableVSS"                     = $true 
            "VSSContextOption"              = "Volatile NoWriters" # Snapshot auto-deleted after use
            
            "EnableRetries"                 = $true 
            "MaxRetryAttempts"              = 2     
            "RetryDelaySeconds"             = 120    # Longer delay for potential network issues
            
            "MinimumRequiredFreeSpaceGB"    = 50    
            "ExitOnLowSpaceIfBelowMinimum"  = $true 
            "TestArchiveAfterCreation"      = $true
            
            "ReportGeneratorType"           = "HTML" 
            "HtmlReportTheme"               = "RetroTerminal" 
            "HtmlReportDirectory"           = "\\SHARE\AdminReports\PoShBackup\WebApp" 
            "HtmlReportTitlePrefix"         = "Web Application Backup Status"
            "HtmlReportLogoPath"            = "\\SHARE\Branding\WebAppLogo.png"
            "HtmlReportCustomCssPath"       = "\\SHARE\Branding\WebAppReportOverrides.css"
            "HtmlReportCompanyName"         = "Production Services Ltd."
            "HtmlReportOverrideCssVariables" = @{
                "--accent-color" = "darkred";
                "--header-border-color" = "black";
            }
            "HtmlReportShowSummary"         = $true
            "HtmlReportShowConfiguration"   = $true 
            "HtmlReportShowHooks"           = $true
            "HtmlReportShowLogEntries"      = $true

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
    # Group multiple BackupLocations to run sequentially.
    BackupSets                      = @{
        "Daily_Critical_Backups" = @{
            JobNames     = @( # Array of job names (keys from BackupLocations)
                "Projects",
                "AnExample"
                # "ComprehensiveExample_WebApp" # If uncommented and defined above
            )
            OnErrorInJob = "StopSet" # Options: "StopSet" (default) or "ContinueSet".
                                     # "StopSet": If a job in this set fails, subsequent jobs in this set are skipped.
                                     # "ContinueSet": Subsequent jobs in this set will run even if a prior one fails.
        }
        "Weekly_User_Data"       = @{
            JobNames = @(
                "AnExample"
            )
            # OnErrorInJob defaults to "StopSet" if not specified
        }
        "Nightly_Full_System_Simulate" = @{ # Example for a simulation run of multiple jobs
            JobNames = @("Projects", "AnExample")
            OnErrorInJob = "ContinueSet" 
            # Note: To run this set in simulation, you'd use: .\PoSh-Backup.ps1 -RunSet "Nightly_Full_System_Simulate" -Simulate
        }
    }
    #endregion
}
