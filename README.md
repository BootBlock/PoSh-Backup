# PoSh-Backup
A powerful, modular PowerShell script for backing up your files and folders using the free [7-Zip](https://www.7-zip.org/) compression software. Now with extensible support for remote Backup Targets, optional post-run system actions, optional archive checksum generation/verification, optional Self-Extracting Archive (SFX) creation, optional 7-Zip CPU core affinity (with validation and CLI override), optional verification of local archives before remote transfer, configurable log file retention, support for 7-Zip include/exclude list files, backup job chaining/dependencies, multi-volume (split) archive creation (with CLI override), and a global maintenance mode.

> **Notice:** This script is under active development. While it offers robust features, use it at your own risk, especially in production environments, until it has undergone more extensive community testing. This project is also an exploration of AI-assisted development.

## Features
*   **Enterprise-Grade PowerShell Solution:** Robust, modular design built with dedicated PowerShell modules for reliability, maintainability, and clarity.
*   **Infrastructure Snapshot Orchestration (Hyper-V):** Perform application-consistent backups of live Hyper-V virtual machines with minimal performance impact. PoSh-Backup orchestrates the creation of a VM checkpoint, mounts the snapshot's virtual disk(s) to the host, backs up the data from the static snapshot, and then automatically cleans up the checkpoint and mount points. This allows for reliable backups of entire VMs or specific folders within them.
*   **Flexible External Configuration:** Manage all backup jobs, global settings, backup sets, remote **Backup Target** definitions, and **Post-Run System Actions** via a human-readable `.psd1` configuration file.
*   **Maintenance Mode:** A global flag (either in the configuration file or via a simple on-disk `.maintenance` file) can prevent any new backup jobs from starting. This is ideal for performing system maintenance without generating failed job reports. The mode can be easily toggled via a command-line switch (`-Maintenance $true/$false`) and bypassed for a specific run if needed (`-ForceRunInMaintenanceMode`).
*   **Automated Backup Verification:** Define and run verification jobs that automatically restore a backup to a temporary "sandbox" location and perform integrity checks. This includes verifying file sizes, modification dates, and CRC checksums against a manifest created during the backup, providing a high degree of confidence that backups are restorable and uncorrupted.
*   **Integrated Backup Scheduling:** Define backup schedules directly within your job configurations. A simple command (`-SyncSchedules`) synchronises these settings with the Windows Task Scheduler, creating, updating, or removing tasks as needed for a true "set and forget" experience.
*   **Flexible Notifications (Email & Webhooks):** Automatically send notifications upon job or set completion. Configure multiple notification profiles, choosing between providers like "Email" (for standard SMTP alerts) or "Webhook" (for sending formatted messages to platforms like Microsoft Teams, Slack, or Discord).
*   **Local and Remote Backups:**
    *   Archives are initially created directly in the directory specified by the effective `DestinationDir` setting for the job.
    *   If remote targets (e.g., UNC shares, SFTP servers) are configured for the job, this `DestinationDir` acts as a **local staging area** before the archive is transferred.
    *   If no remote targets are specified for a job, the archive in `DestinationDir` serves as the **final backup destination**.
*   **Granular Backup Job Control:** Precisely define sources, the primary archive creation directory (`DestinationDir`), archive names, local retention policies, **remote target assignments**, and **post-run actions** for each individual backup job.
*   **Backup Job Chaining / Dependencies:** Define prerequisite jobs for a backup job using the `DependsOnJobs` array setting in the configuration. A job will only execute if all its specified prerequisite jobs have completed successfully. Success for a prerequisite is determined by its final status, taking into account its specific `TreatSevenZipWarningsAsSuccess` setting (i.e., a status of "SUCCESS", "SIMULATED_COMPLETE", or "WARNINGS" if that job treats warnings as success, will allow dependent jobs to proceed). The script automatically builds a valid execution order for the targeted job(s) and their dependencies, and will detect and report circular dependencies during configuration testing (`-TestConfig`) or before a run.
*   **Backup Sets:** Group multiple jobs to run. If jobs within a set have dependencies defined via `DependsOnJobs`, they will be ordered accordingly within the set's execution. The set-level error handling (`OnErrorInJob`: "StopSet" or "ContinueSet") interacts with both operational job failures and jobs skipped due to failed prerequisites. For example, if `OnErrorInJob` is "StopSet", a critical prerequisite failure that causes a dependent job to be skipped can halt the entire set. Set-level post-run actions are also supported.
*   **Extensible Backup Target Providers:** A modular system (located in `Modules\Targets\`) allows for adding support for various remote storage types.
    *   **UNC Provider:** Transfers archives to standard network shares.
    *   **Replicate Provider:** Copies an archive to multiple specified local or UNC paths, with individual retention settings per destination.
    *   **SFTP Provider (via Posh-SSH module):** Transfers archives to SFTP servers, supporting password and key-based authentication.
*   **Configurable Retention Policies:**
    *   **Local Retention:** Manage archive versions in the `DestinationDir` using the `LocalRetentionCount` setting per job.
    *   **Remote Retention:** Each Backup Target provider can, if designed to do so, implement its own retention logic on the remote storage (e.g., keep last X versions, delete after Y days). This is configured within the target's definition in the `BackupTargets` section (e.g., via `RemoteRetentionSettings` or per-destination settings for providers like "Replicate").
*   **Live File Backups with VSS:** Utilise the Windows Volume Shadow Copy Service (VSS) to seamlessly back up open or locked files (requires Administrator privileges). Features configurable VSS context, reliable shadow copy creation, and a configurable metadata cache path.
*   **Advanced 7-Zip Integration:** Leverage 7-Zip for efficient, highly configurable compression. Customise archive type, compression level, method, dictionary/word/solid block sizes, and thread count for local archive creation.
    *   **Include/Exclude List Files:** Define complex include or exclude rules for 7-Zip by specifying paths to external text files. These files contain patterns (one per line) that 7-Zip will use with its `-i@listfile` or `-x@listfile` switches. Configurable globally, per-job, per-set, or via CLI.
    *   **Multi-Volume (Split) Archives:** Optionally split large archives into smaller volumes (e.g., "100m", "4g"). Configurable per job or via CLI. This will override SFX creation if both are set for a job.
*   **Secure Password Protection:** Encrypt local backup archives with passwords. The password, whether obtained interactively, from PowerShell SecretManagement, an encrypted file, or plain text (discouraged), is now passed directly to 7-Zip using its standard `-p{password}` switch. While this avoids intermediate temporary password files, the command line itself (which can sometimes be logged or inspected) will contain the password switch.
*   **Customisable Archive Naming:** Tailor local archive filenames with a base name and a configurable date stamp (e.g., "yyyy-MMM-dd", "yyyyMMdd_HHmmss"). Set archive extensions (e.g., .7z, .zip) per job.
*   **Automatic Retry Mechanism:** Overcome transient failures during 7-Zip operations for local archive creation. (Note: Retries for remote transfers are the responsibility of the specific Backup Target provider module, if implemented.)
*   **CPU Priority Control:** Manage system resource impact by setting the 7-Zip process priority (e.g., Idle, BelowNormal, Normal, High) for local archiving.
*   **7-Zip CPU Core Affinity:** Optionally restrict the 7-Zip process to specific CPU cores using a comma-separated list (e.g., "0,1") or a hexadecimal bitmask (e.g., "0x3") for finer-grained resource control. User input is validated against available system cores, and clamped if necessary. Can be overridden via CLI.
*   **Extensible Script Hooks:** Execute your own custom PowerShell scripts at various stages of a backup job for ultimate operational flexibility. Hook scripts now receive information about target transfer results if applicable.
*   **Multi-Format Reporting:** Generate comprehensive reports for each job.
    *   **Interactive HTML Reports:** Highly customisable with titles, logos, and themes (via external CSS). Now includes a dedicated section detailing the status of **Remote Target Transfers** and **Archive Checksum** information in the summary.
        *   **Collapsible Sections:** Summary, Configuration, Hooks, Target Transfers, and Detailed Log sections are collapsible for easier navigation, with their open/closed state remembered in the browser (via `localStorage`).
        *   **Advanced Log Filtering:** Client-side keyword search and per-level checkbox filtering for log entries. Includes "Select All" / "Deselect All" buttons for log levels and a visual indicator when filters are active.
        *   **Keyword Highlighting:** Searched keywords are automatically highlighted within the log entries.
        *   **Dynamic Table Sorting:** Key data tables (Summary, Configuration, Hooks, Target Transfers) can be sorted by clicking column headers.
        *   **Copy to Clipboard:** Easily copy the output of executed hook scripts using a dedicated button.
        *   **Scroll to Top Button:** Appears on long reports for quick navigation back to the top of the page.
        *   **Configurable Favicon:** Display a custom icon in the browser tab for the report.
        *   **Print-Optimized:** Includes basic print-specific CSS for better paper output (e.g., hides interactive elements, ensures content is visible).
        *   **Simulation Banner:** Clearly distinguishes reports generated from simulation runs.
    *   **Other Formats:** CSV, JSON, XML (CliXml), Plain Text (TXT), and Markdown (MD) also supported for data export and integration, updated to include target transfer and checksum details where appropriate.
*   **Comprehensive Logging:** Get detailed, colour-coded console output and optional per-job text file logs for easy monitoring and troubleshooting of both local operations and remote transfers.
*   **Log File Retention:** Automatically manage the number of log files kept per job. Configurable globally, per job, or per backup set, with a CLI override. A setting of `0` means infinite retention. This prevents the `Logs/` directory from growing indefinitely.
*   **Pin Backups:** Protect specific backup archives from automatic deletion by retention policies. This can be done by pinning an existing archive via `-PinBackup <path>` or by pinning the result of the current run via the `-Pin` switch.
*   **Safe Simulation Mode:** Perform a dry run (`-Simulate`) to preview local backup operations, remote transfers, retention (archive and log files), **post-run system actions**, and **checksum operations** without making any actual changes.
*   **Configuration Validation:** Quickly test and validate your configuration file (`-TestConfig`). This includes basic validation of Backup Target definitions and **job dependency validation** (checking for circular references and dependencies on non-existent jobs). Optional advanced schema validation for the overall configuration structure is also available.
*   **Archive Inspection & Restore Utilities:** Inspect or restore files directly from the command line. Use `-ListArchiveContents` to see what's inside an archive, and `-ExtractFromArchive` to restore the entire archive or specific files/folders from it. Both utilities fully support encrypted archives.
*   **Proactive Free Space Check:** Optionally verify sufficient destination disk space in the `DestinationDir` before starting backups to prevent failures.
*   **Archive Integrity Verification:** Optionally test the integrity of newly created local archives using `7z t`.
*   **Archive Checksum Generation & Verification:** Optionally generate a checksum file (e.g., SHA256, MD5) for the local archive. If archive testing is enabled, this checksum can also be verified against the archive content for an additional layer of integrity validation.
*   **Self-Extracting Archives (SFX):** Optionally create Windows self-extracting archives (.exe) with selectable SFX module types (Console, GUI, Installer). Overridden if `SplitVolumeSize` is active.
*   **Flexible 7-Zip Warning Handling:** Option to treat 7-Zip warnings (exit code 1, e.g., from skipped open files) as a success for job status reporting, configurable globally, per-job, or via CLI.
*   **Exit Pause Control:** Control script pausing behaviour on completion (Always, Never, OnFailure, etc.) for easier review of console output, with CLI override.
*   **Post-Run System Actions:** Optionally configure the script to perform system actions like Shutdown, Restart, Hibernate, LogOff, Sleep, or Lock Workstation after a job or set completes. This is configurable based on the final status (Success, Warnings, Failure, Any), can include a delay with a cancellation prompt, and can be forced via CLI parameters.
*   **Verify Local Archive Before Transfer:** Optionally test the local archive's integrity (including checksum if enabled) *before* attempting any remote transfers. If this verification fails, remote transfers for that job are skipped, preventing propagation of potentially corrupt archives.
*   **Update Checking:** Manually check for new versions of PoSh-Backup. If an update is found, the user will be informed and can choose to initiate the download and application of the update. (Self-application of the update is currently under development).

## Getting Started

### 1. Prerequisites
*   **PowerShell:** Version 5.1 or higher.
*   **7-Zip:** Must be installed. PoSh-Backup will attempt to auto-detect `7z.exe` in common Program Files locations or your system PATH. If not found, or if you wish to use a specific 7-Zip instance, you'll need to specify the full path in the configuration file. ([Download 7-Zip](https://www.7-zip.org/))
*   **Posh-SSH Module:** Required if you plan to use the SFTP Backup Target feature. Install via PowerShell: `Install-Module Posh-SSH -Scope CurrentUser` (or `AllUsers` if you have admin rights and want it available system-wide).*   **Administrator Privileges:** Required if you plan to use the Volume Shadow Copy Service (VSS) feature for backing up open/locked files, and potentially for some Post-Run System Actions (e.g., Shutdown, Restart, Hibernate).
*   **Hyper-V Module:** Required if you plan to use the Hyper-V Snapshot Orchestration feature. On Windows Client OS, this is installed via "Turn Windows features on or off". On Windows Server, it's installed as a server role.
*   **(WebDAV):** The WebDAV target provider uses built-in PowerShell cmdlets (`Invoke-WebRequest`) and does not require an additional external module for its core functionality.
*   **Network/Remote Access:** For using Backup Targets, appropriate permissions and connectivity to the remote locations (e.g., UNC shares) are necessary for the user account running PoSh-Backup. For the Update Checking feature, internet access is required to fetch the remote version manifest.

**What this means for you:**
*   If you configure `RemoteRetentionSettings` for a WebDAV target, PoSh-Backup will currently **not** automatically delete older backup sets from your WebDAV server.
*   The local retention policy for the staging directory (`DestinationDir`) will still apply as configured for the job.

We plan to implement full remote retention capabilities for WebDAV targets in a future update. Please check the release notes for updates on this feature.

### 2. Installation & Initial Setup
1.  **Obtain the Script:**
    *   Download the project files (e.g., as a ZIP archive from the project page) or clone the repository if you use Git.
    *   Extract/place the `PoSh-Backup` folder in your desired location (e.g., `C:\Scripts\PoSh-Backup`).
2.  **Directory Structure Overview:**
    *   `PoSh-Backup.ps1`: The main executable script you will run.
    *   `Config/`: Contains all configuration files.
        *   `Default.psd1`: The master configuration file. It lists all available settings with detailed comments explaining each one. **It's recommended not to edit this file directly**, as your changes would be overwritten if you update the script.
        *   `User.psd1`: (Will be created on first run if it doesn't exist) This is where your custom settings go.
        *   `Themes/`: Contains CSS files for different HTML report themes.
    *   `Modules/`: Contains PowerShell modules that provide the core functionality.
        *   `Core/`: Core orchestration and operational logic (e.g., `JobOrchestrator.psm1`, `Operations.psm1`).
        *   `Managers/`: Modules for managing specific functionalities (e.g., `7ZipManager.psm1`, `VssManager.psm1`, `LogManager.psm1`, `JobDependencyManager.psm1`, `SystemStateManager.psm1`, etc.).
        *   `Operations/`: Sub-modules for specific phases of a backup job (e.g., `JobPreProcessor.psm1`, `LocalArchiveProcessor.psm1`).
        *   `Reporting/`: Modules related to report generation.
        *   `SnapshotProviders/`: Sub-directory for infrastructure snapshot provider modules (e.g., `HyperV.Snapshot.psm1`).
        *   `Targets/`: Sub-directory for Backup Target provider modules.
        *   `Utilities/`: Sub-directory for specialised utility modules (including `Update.psm1` for update checks).
        *   (Other direct .psm1 files like `Utils.psm1`, `ScriptModeHandler.psm1`, `PoShBackupValidator.psm1`)
3.  **First Run & User Configuration:**
    *   Open a PowerShell console.
    *   Navigate to the root directory where you placed the `PoSh-Backup` folder (e.g., `cd C:\Scripts\PoSh-Backup`).
    *   Execute the main script: `.\PoSh-Backup.ps1`
    *   On the very first run, if `Config\User.psd1` does not exist, the script will prompt you to create it by copying `Config\Default.psd1`.
        *   It is **highly recommended** to type `Y` and press Enter.
        *   This action creates `Config\User.psd1` as a copy of `Config\Default.psd1`. You should then edit `Config\User.psd1` with your specific settings. Any settings defined in `User.psd1` will override the corresponding settings from `Default.psd1`. This ensures your customisations are preserved when the script is updated.
    *   After creating `User.psd1`, the script will likely inform you that no backup jobs are defined (unless you've already edited it) or it might exit.

### 3. Configuration
1.  **Edit `Config\User.psd1`:** (or `Config\Default.psd1` if not using a user config for testing).
2.  **Key Settings to Review/Modify Initially:**
    *   **`MaintenanceModeEnabled` and `MaintenanceModeFilePath`**:
        *   `MaintenanceModeEnabled = $false`: Set this to `$true` in your `User.psd1` to halt all backups via configuration.
        *   `MaintenanceModeFilePath = ".\.maintenance"`: If a file exists at this path (relative to the script root by default), maintenance mode will be active regardless of the config setting. This is the recommended way to toggle the mode. Use `.\PoSh-Backup.ps1 -Maintenance $true` or `$false` to manage this file automatically.
    *   **`SevenZipPath`**:
        *   By default, this is empty (`""`), and the script tries to auto-detect `7z.exe`.
        *   If auto-detection fails, or you have multiple 7-Zip versions and want to specify one, set the full path here. Example: `'C:\Program Files\7-Zip\7z.exe'`.
    *   **`DefaultDestinationDir`**:
        *   This serves as the default directory where backup archives are created.
        *   If remote targets (see `BackupTargets` and `TargetNames`) are specified for a job, this directory acts as a **local staging area** before transfer.
        *   If no remote targets are used for a job, this acts as the **final backup destination**.
        *   Example: `'D:\Backups\PrimaryArchiveLocation'`.
        *   Ensure this directory exists, or the script has permissions to create it.
    *   **`DeleteLocalArchiveAfterSuccessfulTransfer` (Global Setting):**
        *   Defaults to `$true`. If true, the archive in `DefaultDestinationDir` (or job-specific `DestinationDir`) will be deleted after it has been successfully transferred to ALL specified remote targets for that job. Has no effect if no remote targets are configured for the job. Can be overridden per job.
    *   **`TreatSevenZipWarningsAsSuccess`**: (Global Setting)
        *   Defaults to `$false`. If set to `$true`, 7-Zip warnings (like skipped files) will still result in a "SUCCESS" job status.
    *   **`DefaultLogRetentionCount` (Global Setting):**
        *   Defaults to `30`. This specifies the number of log files to keep for each job name pattern in the `LogDirectory`.
        *   Set to `0` to keep all log files (infinite retention).
        *   This can be overridden by `LogRetentionCount` at the job level or set level, or by the `-LogRetentionCountCLI` parameter.
    *   **Checksum Settings (Global Defaults):**
        *   `DefaultGenerateArchiveChecksum` (boolean, default `$false`): Set to `$true` to enable checksum generation for all jobs by default.
        *   `DefaultChecksumAlgorithm` (string, default `"SHA256"`): Specifies the default algorithm (e.g., "SHA1", "SHA256", "SHA512", "MD5").
        *   `DefaultVerifyArchiveChecksumOnTest` (boolean, default `$false`): If `$true` (and `DefaultTestArchiveAfterCreation` is also true), the generated checksum will be verified against the archive during the archive test phase.
    *   **`DefaultVerifyLocalArchiveBeforeTransfer` (Global Setting):**
        *   Defaults to `$false`. If set to `$true`, the local archive integrity (including checksum if `DefaultGenerateArchiveChecksum` and `DefaultVerifyArchiveChecksumOnTest` are also true) will be tested *before* any remote transfers are attempted. If this test fails, remote transfers for the job will be skipped.
    *   **`DefaultCreateSFX` (Global Setting):**
        *   `DefaultSFXModule` (string, default `"Console"`): Determines the type of SFX created if `DefaultCreateSFX` is true.
            *   `"Console"` or `"Default"`: Default 7-Zip console SFX (e.g., `7zCon.sfx`). Extracts to current directory without prompting.
            *   `"GUI"`: Standard GUI SFX (e.g., `7zS.sfx`). Prompts user for extraction path.
            *   `"Installer"`: Installer-like GUI SFX (e.g., `7zSD.sfx`). Prompts user for extraction path.
    *   **Split Volume Settings (Global Default):**
        *   `DefaultSplitVolumeSize`: String (e.g., "100m", "4g", "700k"). An empty string (`""`) means no splitting by default. Use lowercase 'k', 'm', or 'g'.
            *   **Note on SFX and Splitting:** If a job is configured for both SFX creation (`CreateSFX = $true`) and volume splitting (a valid `SplitVolumeSize` is set), **volume splitting will take precedence**, and SFX creation will be automatically disabled for that job. A warning will be logged.
    *   **`DefaultSevenZipCpuAffinity` (Global Setting):**
        *   `DefaultSevenZipCpuAffinity` (string, default `""`): Optionally restrict 7-Zip to specific CPU cores.
            *   Examples: `"0,1"` (for cores 0 and 1), `"0x3"` (bitmask for cores 0 and 1).
            *   An empty string or `$null` means no affinity is set (7-Zip uses all available cores).
            *   User input is validated against available system cores and clamped if necessary.
    *   **`DefaultSevenZipIncludeListFile` (Global Setting):**
        *   `DefaultSevenZipIncludeListFile` (string, default `""`): Optionally specify a path to a text file containing patterns for 7-Zip to include (one pattern per line). Used with 7-Zip's `-i@listfile` switch.
    *   **`DefaultSevenZipExcludeListFile` (Global Setting):**
        *   `DefaultSevenZipExcludeListFile` (string, default `""`): Optionally specify a path to a text file containing patterns for 7-Zip to exclude (one pattern per line). Used with 7-Zip's `-x@listfile` switch.
    *   **`BackupTargets` (Global Section):**
        *   This is where you define your reusable, named remote target configurations.
        *   Each entry (a "target instance") specifies a `Type` (like "UNC", "Replicate") and `TargetSpecificSettings` for that type.
        *   Optionally, you can include `CredentialsSecretName` if the provider supports credentialed access via PowerShell SecretManagement, and `RemoteRetentionSettings` for provider-specific retention on the target (or per-destination for "Replicate" type).
        *   Example of defining a UNC target instance:
            ```powershell
            # Inside User.psd1 or Default.psd1, within the main @{ ... }
            BackupTargets = @{

                "MyMainUNCShare" = @{
                    Type = "UNC" # Refers to Modules\Targets\UNC.Target.psm1
                    TargetSpecificSettings = @{
                        UNCRemotePath = "\\fileserver01\backups\MyPoShBackups"
                        CreateJobNameSubdirectory = $false # Optional, default is $false
                    }
                    # Optional: RemoteRetentionSettings = @{ KeepCount = 7 }
                }

                # Example for the "Replicate" target type
                "MyReplicatedBackups" = @{
                    Type = "Replicate" # Refers to Modules\Targets\Replicate.Target.psm1
                    TargetSpecificSettings = @( # Array of destination configurations
                        @{ # Destination 1
                            Path = "E:\SecondaryCopies\CriticalData"
                            CreateJobNameSubdirectory = $true # Archives for job "JobA" go to E:\SecondaryCopies\CriticalData\JobA
                            RetentionSettings = @{ KeepCount = 5 } # Keep 5 versions at this specific destination
                        },
                        @{ # Destination 2
                            Path = "\\NAS\ArchiveMirror\Important"
                            # CreateJobNameSubdirectory defaults to $false if not specified
                            RetentionSettings = @{ KeepCount = 10 } # Keep 10 versions at this specific destination
                        },
                        @{ # Destination 3 (simple, no job subdir, no specific retention here)
                            Path = "F:\USBStick\QuickAccess"
                        }
                    )
                }

                "MySecureFTPServer" = @{ # SFTP Target Example
                    Type = "SFTP" # Refers to Modules\Targets\SFTP.Target.psm1
                    TargetSpecificSettings = @{
                        SFTPServerAddress   = "sftp.yourdomain.com"    # Mandatory: SFTP server hostname or IP
                        SFTPPort            = 22                       # Optional: Defaults to 22
                        SFTPRemotePath      = "/remote/backup/path"    # Mandatory: Base path on SFTP server
                        SFTPUserName        = "sftp_backup_user"       # Mandatory: SFTP username

                        # --- Authentication: Choose one method ---
                        # 1. Password-based (password stored in PowerShell SecretManagement)
                        SFTPPasswordSecretName = "SftpUserPasswordSecret" # Name of the secret for the user's password

                        # 2. Key-based (private key file *path* stored in SecretManagement)
                        # SFTPKeyFileSecretName = "SftpUserPrivateKeyPathSecret" # Name of secret for the private key file path (e.g., C:\path\to\id_rsa)
                        # SFTPKeyFilePassphraseSecretName = "SftpKeyPassphraseSecret" # Optional: Name of secret for the key's passphrase

                        # --- Other SFTP Settings ---
                        CreateJobNameSubdirectory = $true # Optional: Default $false. If $true, creates /remote/backup/path/JobName/
                        SkipHostKeyCheck    = $false      # Optional: Default $false. If $true, skips SSH host key verification (INSECURE).
                    }
                    RemoteRetentionSettings = @{ # Optional: Retention on the SFTP server
                        KeepCount = 5 # Keep the last 5 archives for this job on this SFTP target
                    }
                }

                "MyNextcloudWebDAV" = @{ # WebDAV Target Example
                    Type = "WebDAV" # Refers to Modules\Targets\WebDAV.Target.psm1
                    TargetSpecificSettings = @{
                        WebDAVUrl             = "https://cloud.example.com/remote.php/dav/files/youruser" # Full URL to your WebDAV base directory
                        CredentialsSecretName = "NextcloudCredentials" # Secret should store a PSCredential object (Username + App Password/Token or Regular Password)
                        # CredentialsVaultName  = "MySpecificVault"       # Optional: Specify vault if not default
                        RemotePath            = "PoShBackup"            # Optional: Relative path within the WebDAVUrl to store backups.
                                                                    # e.g., /PoShBackup. If empty or not present, uses the root of WebDAVUrl.
                        CreateJobNameSubdirectory = $true               # Optional: If $true, creates /PoShBackup/JobName/. Default is $false.
                        RequestTimeoutSec     = 180                   # Optional: Timeout for WebDAV HTTP requests in seconds. Default is 120.
                    }
                    RemoteRetentionSettings = @{ # Optional: Retention on the WebDAV server
                        KeepCount = 7 # Example: Keep the last 7 backup instances for any job using this target.
                                    # NOTE: WebDAV retention is currently a placeholder and not fully implemented in WebDAV.Target.psm1 v0.1.0.
                                    # Manual cleanup on the WebDAV server will be required.
                    }
                }       # Add other targets, e.g., for FTP, S3, etc. as providers become available.
            }
            ```
    *   **Notification Settings (Global):**
        *   **`NotificationProfiles`**: This is where you define reusable notification provider configurations. Each profile needs a `Type`.
            ```powershell
            NotificationProfiles = @{
                # Example for the "Email" provider
                "Office365" = @{
                    Type             = "Email"
                    ProviderSettings = @{
                        SMTPServer           = "smtp.office365.com"
                        SMTPPort             = 587
                        EnableSsl            = $true
                        FromAddress          = "backup-alerts@your-domain.com"
                        CredentialSecretName = "Office365BackupUserCredentials" # Secret stores a PSCredential object
                    }
                }
                # Example for the generic "Webhook" provider
                "TeamsAlertsChannel" = @{
                    Type             = "Webhook"
                    ProviderSettings = @{
                        WebhookUrlSecretName = "TeamsAlertsWebhookUrl" # Secret stores the full webhook URL string
                        Method               = "POST"
                        # BodyTemplate is a here-string containing the JSON payload.
                        # Placeholders like {JobName}, {Status}, {ErrorMessage}, etc., will be replaced.
                        BodyTemplate         = @'
{
    "text": "PoSh-Backup Job ''{JobName}'' finished with status: **{Status}**"
}
'@
                    }
                }
            }
            ```
        *   **`DefaultNotificationSettings`**: These are the default notification settings for all jobs/sets.
            ```powershell
            DefaultNotificationSettings = @{
                Enabled         = $false # Master switch, must be $true in a job/set to send notifications.
                ProfileName     = ""     # Must be set in job/set, e.g., "Office365".
                ToAddress       = @()    # For Email provider: E.g., @("admin@your-domain.com")
                Subject         = "PoSh-Backup Report for Job: {JobName} - Status: {Status}"
                TriggerOnStatus = @("FAILURE", "WARNINGS") # Send notifications only on failure or warnings.
            }
            ```
    *   **`BackupLocations` (Job Definitions):**
        *   This is the most important section for defining what to back up. It's a hashtable where each entry is a backup job.
        *   `User.psd1` (copied from `Default.psd1`) will contain example job definitions. Modify or replace these.
        *   Each job definition requires:
            *   `Path`: Source path(s) to back up (string or array of strings).
            *   `Name`: Base name for the archive file.
        *   **`DependsOnJobs` (Job-Level Setting):**
            *   An array of job name strings that this job depends on. Example: `DependsOnJobs = @("DatabaseBackupJob", "LogArchiveJob")`
            *   The current job will only run if all jobs listed in `DependsOnJobs` complete successfully (success considers the prerequisite job's `TreatSevenZipWarningsAsSuccess` setting).
            *   The script will attempt to order jobs to satisfy these dependencies and will detect circular dependencies.
        *   Key settings for local and remote behaviour:
        *   Key settings for local and remote behaviour:
            *   `DestinationDir`: Specifies the directory where this job's archive is created. If remote targets are used, this acts as a **local staging directory**. If no remote targets are used, this is the **final backup destination**. Overrides `DefaultDestinationDir`.
            *   `LocalRetentionCount`: (Renamed from `RetentionCount`) Defines how many archive versions to keep in the `DestinationDir`.
            *   `LogRetentionCount`: Defines how many log files to keep for this specific job. Overrides `DefaultLogRetentionCount`. A value of `0` means infinite retention for this job's logs.
            *   `TargetNames`: An array of strings. Each string must be a name of a target instance defined in the global `BackupTargets` section. If you specify target names here, the locally created archive will be transferred to each listed remote target. If `TargetNames` is omitted or empty, the backup is local-only to `DestinationDir`.
            *   `DeleteLocalArchiveAfterSuccessfulTransfer` (Job-Specific): Overrides the global setting for this job.
        *   **Checksum Settings (Job-Specific):**
            *   `GenerateArchiveChecksum` (boolean): Overrides `DefaultGenerateArchiveChecksum`.
            *   `ChecksumAlgorithm` (string): Overrides `DefaultChecksumAlgorithm`.
            *   `VerifyArchiveChecksumOnTest` (boolean): Overrides `DefaultVerifyArchiveChecksumOnTest`.
        *   **`VerifyLocalArchiveBeforeTransfer` (Job-Specific):**
            *   Overrides `DefaultVerifyLocalArchiveBeforeTransfer`. Set to `$true` to enable pre-transfer verification for this specific job.
        *   **Self-Extracting Archive (SFX) Setting (Job-Specific):**
            *   `CreateSFX` (boolean, default `$false`): Set to `$true` to create a self-extracting archive (.exe) for this job.
            *   `SFXModule` (string, default from global `DefaultSFXModule`): Specifies the type of SFX if `CreateSFX` is true. Options: `"Console"`, `"GUI"`, `"Installer"`.
            *   If `CreateSFX` is `$true`, the `ArchiveExtension` setting for this job (or the global `DefaultArchiveExtension`) will effectively be overridden to `.exe` for the output file. The original `ArchiveExtension` (e.g., ".7z", ".zip") is still used internally to determine the archive type (e.g., for the 7-Zip `-t` switch).
            *   SFX archives are Windows-specific executables.
        *   **7-Zip CPU Core Affinity (Job-Specific):**
            *   `SevenZipCpuAffinity` (string, default from global `DefaultSevenZipCpuAffinity`): Optionally restrict 7-Zip to specific CPU cores for this job.
                *   Examples: `"0,1"` (for cores 0 and 1), `"0x3"` (bitmask for cores 0 and 1).
                *   An empty string or `$null` means no affinity is set (7-Zip uses all available cores).
                *   User input is validated against available system cores and clamped if necessary.
        *   **Job-specific Split Volume Settings:**
            *   `SplitVolumeSize`: String (e.g., "100m", "4g"). Overrides `DefaultSplitVolumeSize`. An empty string or omitting the key uses the default (which might also be empty, meaning no split).
                *   Example: `SplitVolumeSize = "2g"` # Splits into 2 Gigabyte volumes.
                *   Remember the conflict with SFX: if this is set to a valid value, `CreateSFX` will be treated as `$false` for this job.
        *   **7-Zip Include/Exclude List Files (Job-Specific):**
            *   `SevenZipIncludeListFile` (string, default from global `DefaultSevenZipIncludeListFile`): Path to a text file for 7-Zip include patterns for this job.
            *   `SevenZipExcludeListFile` (string, default from global `DefaultSevenZipExcludeListFile`): Path to a text file for 7-Zip exclude patterns for this job.
        *   **Notification Settings (Job-Specific):**
            *   `NotificationSettings`: A hashtable to override the `DefaultNotificationSettings` for this specific job.
                ```powershell
                NotificationSettings = @{
                    Enabled         = $true
                    ProfileName     = "TeamsAlertsChannel" # Must match a name in NotificationProfiles
                    TriggerOnStatus = @("FAILURE") # Only notify on failure for this job
                }
                ```
        *   Example job definition that creates a local archive, sends it to a remote target, includes checksum settings, creates an SFX, sets CPU affinity, specifies log retention, and uses an exclude list file:
            ```powershell
            # Inside BackupLocations in User.psd1 or Default.psd1
            "MyDocumentsBackupSFX_GUI_Affinity" = @{
                Path           = @(
                                "C:\Users\YourUserName\Documents",
                                "E:\WorkProjects\CriticalData"
                            )
                Name           = "UserDocumentsSFX_GUI_Affinity"
                DestinationDir = "E:\BackupStorage\MyDocsSFX"
                LocalRetentionCount = 3
                LogRetentionCount   = 15 # Keep last 15 logs for this job

                TargetNames = @("MyMainUNCShare")
                DeleteLocalArchiveAfterSuccessfulTransfer = $true

                CreateSFX                   = $true  # Create a self-extracting .exe
                SFXModule                   = "GUI"  # Use the GUI SFX module (prompts for path)
                SplitVolumeSize             = "100m" # Split into 100 MB volumes
                ArchiveExtension            = ".7z"  # Internal archive type will be 7z, final file will be .exe

                GenerateArchiveChecksum     = $true
                ChecksumAlgorithm           = "SHA256"
                VerifyArchiveChecksumOnTest = $true
                VerifyLocalArchiveBeforeTransfer = $true # Ensure this archive is good before sending to MyMainUNCShare
                SevenZipCpuAffinity         = "0,1"  # Restrict 7-Zip to CPU cores 0 and 1
                SevenZipExcludeListFile     = "C:\PoShBackup\Config\MyDocsExcludes.txt"
            }

            # Inside BackupLocations in User.psd1 or Default.psd1
            "MyDocs_To_WebDAV" = @{
                Path                       = "C:\Users\YourUserName\Documents\ImportantProject"
                Name                       = "ProjectDocs_WebDAV"
                DestinationDir             = "D:\PoShBackup_Staging\WebDAV" # Local staging directory
                TargetNames                = @("MyNextcloudWebDAV")         # Reference the WebDAV target instance defined above
                DeleteLocalArchiveAfterSuccessfulTransfer = $true
                LocalRetentionCount        = 2
                ArchivePasswordMethod      = "SecretManagement"
                ArchivePasswordSecretName  = "MyArchivePasswordForWebDAV" # Separate secret for archive encryption if needed
                # ... other relevant job settings like CreateSFX, SplitVolumeSize, etc. ...
            }
            ```
    *   **`BackupSets` (Set Definitions):**
        *   Each set defined under `BackupSets` can also have its own `LogRetentionCount`.
        *   This setting, if present, overrides both the job-level `LogRetentionCount` for jobs within that set and the `DefaultLogRetentionCount`.
        *   **7-Zip Include/Exclude List Files (Set-Specific):**
            *   `SevenZipIncludeListFile` (string, default from global `DefaultSevenZipIncludeListFile`): Path to a text file for 7-Zip include patterns for all jobs in this set. Overrides job-level and global settings.
            *   `SevenZipExcludeListFile` (string, default from global `DefaultSevenZipExcludeListFile`): Path to a text file for 7-Zip exclude patterns for all jobs in this set. Overrides job-level and global settings.
        *   **Notification Settings (Set-Specific):**
            *   `NotificationSettings`: A hashtable to override the `DefaultNotificationSettings` for the entire set. A notification is sent *after the entire set completes*, based on the set's overall status. This overrides any notification settings on individual jobs within the set.
        *   Example for a set:
            ```powershell
            "NightlyServerMaintenance" = @{
                JobNames     = @("WebAppBackup", "SQLBackup")
                OnErrorInJob = "StopSet"
                LogRetentionCount = 7 # Logs for WebAppBackup & SQLBackup will keep 7 files when run via this set.
                SevenZipExcludeListFile = "C:\PoShBackup\Config\ServerMaintenanceExcludes.txt" # Exclude list for this set
                NotificationSettings = @{
                    Enabled         = $true
                    ProfileName     = "Office365"
                    ToAddress       = @("it-admins@example.com")
                    Subject         = "PoSh-Backup Set Report: {SetName} - Overall Status: {Status}"
                    TriggerOnStatus = @("FAILURE", "WARNINGS")
                }
                PostRunAction = @{
                    Enabled         = $true
                    Action          = "Restart"
                    DelaySeconds    = 300 # 5-minute delay
                    TriggerOnStatus = @("SUCCESS", "WARNINGS") # Restart even if there were warnings
                    ForceAction     = $true
                }
            }
            ```
    *   **`PostRunActionDefaults` (Global Post-Run System Action Settings):**
        *   Located in `Config\Default.psd1` (and copied to `User.psd1`), this section defines the default behavior for actions to take after the script finishes processing a job or set.
        *   Example structure in `PostRunActionDefaults`:
            ```powershell
            PostRunActionDefaults = @{
                Enabled         = $false # Default: $false (disabled)
                Action          = "None" # Default: "None". Others: "Shutdown", "Restart", "Hibernate", "LogOff", "Sleep", "Lock"
                DelaySeconds    = 0      # Default: 0 (immediate action if enabled)
                                 # During the delay, a message will show with a countdown, allowing cancellation by pressing 'C'.
                TriggerOnStatus = @("SUCCESS") # Default: Only on "SUCCESS". Can be array: @("SUCCESS", "WARNINGS"), or @("ANY")
                                       # "ANY" means the action triggers if Enabled=$true, regardless of status.
                ForceAction     = $false # Default: $false. If $true, attempts to force Shutdown/Restart.
            }
            ```
    *   **`PostRunAction` in `BackupLocations` (Job-Specific Post-Run Actions):**
        *   Each job defined under `BackupLocations` can have its own `PostRunAction` hashtable.
        *   This allows you to specify a particular system action to occur *after that specific job completes* (and its hooks run).
        *   These job-level settings override `PostRunActionDefaults`.
        *   Example for a job:
            ```powershell
            "MyCriticalJob" = @{
                Path = "C:\Data\Critical"
                Name = "CriticalDataBackup"
                # ... other job settings ...
                PostRunAction = @{
                    Enabled         = $true
                    Action          = "Shutdown"
                    DelaySeconds    = 120 # 2-minute delay with cancel prompt
                    TriggerOnStatus = @("SUCCESS")
                    ForceAction     = $false
                }
            }
            ```
    *   **`PostRunAction` in `BackupSets` (Set-Specific Post-Run Actions):**
        *   Each set defined under `BackupSets` can also have its own `PostRunAction` hashtable.
        *   This action occurs *after all jobs in the set have completed* (and the set's final hooks, if any, run).
        *   A `PostRunAction` defined at the set level *overrides* any `PostRunAction` settings from individual jobs within that set, and also overrides `PostRunActionDefaults`.
        *   Example for a set:
            ```powershell
            "NightlyServerMaintenance" = @{
                JobNames     = @("WebAppBackup", "SQLBackup")
                OnErrorInJob = "StopSet"
                LogRetentionCount = 7 # Also applies log retention for jobs in this set
                SevenZipExcludeListFile = "C:\PoShBackup\Config\ServerMaintenanceExcludes.txt" # Exclude list for this set
                PostRunAction = @{
                    Enabled         = $true
                    Action          = "Restart"
                    DelaySeconds    = 300 # 5-minute delay
                    TriggerOnStatus = @("SUCCESS", "WARNINGS") # Restart even if there were warnings
                    ForceAction     = $true
                }
            }
            ```
3.  **Explore `Config\Default.psd1` for All Options:**
    *   Open `Config\Default.psd1` (but don't edit it for your settings). This file serves as a comprehensive reference. It contains detailed comments explaining every available global and job-specific setting.

### Backing Up Virtual Machines via Snapshot Orchestration
This is a powerful enterprise feature that allows for application-consistent backups of live virtual machines with minimal performance impact.

**How it Works:**
Instead of backing up files directly from the live VM's file system, PoSh-Backup orchestrates the underlying hypervisor (currently Hyper-V) to:
1.  Create a temporary, application-consistent checkpoint (snapshot) of the target VM.
2.  Mount the virtual hard disk(s) from this checkpoint onto the host machine where PoSh-Backup is running.
3.  Perform the 7-Zip backup operation against the data on the mounted, static snapshot.
4.  Once the backup is complete, automatically dismount the disk(s) and remove the checkpoint from the VM, leaving the live VM untouched.

**Host System Setup for Hyper-V:**
1.  **Administrator Privileges:** You must run `PoSh-Backup.ps1` from a PowerShell session with Administrator privileges.
2.  **Hyper-V PowerShell Module:** The `Hyper-V` module must be installed and enabled.
3.  **SAN Policy:** The host's SAN Policy must be set to `OnlineAll` to allow the mounted VHDs to be automatically brought online. To check and set this, run `diskpart` as an administrator, then use the commands `san policy` to view and `san policy=OnlineAll` to set.
4.  **BitLocker:** The guest VM's volumes **must not** be encrypted with BitLocker. The host OS cannot read BitLocker-encrypted volumes when mounting a VHD, and the backup will fail.

**Configuration Example:**

1.  **Define the Provider:** In `Config\Default.psd1` (or `User.psd1`), ensure a provider is defined in the `SnapshotProviders` section. For a local Hyper-V host, this is all you need:
    ```powershell
    SnapshotProviders = @{
        "LocalHyperV" = @{
            Type = "HyperV"
            ProviderSpecificSettings = @{}
        }
    }
    ```

2.  **Define the Backup Job:** Create a job in `BackupLocations`.
    ```powershell
    "HyperV_VM_Backup_Example" = @{
        # When using a SnapshotProvider, 'Path' becomes an array where:
        # - Element 0 is the Name of the Virtual Machine to be snapshotted.
        # - Subsequent elements (optional) are the specific paths *inside* the VM to back up.
        #   If only the VM name is provided (e.g., Path = "MyVM"), the entire mounted VM disk is backed up.
        Path                    = @(
            "MyWebApp-VM01",      # The VM Name.
            "C:\inetpub\wwwroot", # A specific folder to back up from the snapshot.
            "D:\Logs"             # Another folder from another drive in the VM.
        )
        SourceIsVMName          = $true         # Tells PoSh-Backup to use the Snapshot Provider.
        SnapshotProviderName    = "LocalHyperV" # Links this job to the provider defined above.

        # Standard job settings:
        Name                    = "MyWebAppVM_Backup"
        DestinationDir          = "D:\Backups\VMs"
        LocalRetentionCount     = 7
        EnableVSS               = $true # Still recommended for application consistency inside the guest.
    }
    ```

### 4. Basic Usage Examples
Once your `Config\User.psd1` is configured with at least one backup job, you can run PoSh-Backup from a PowerShell console located in the script's root directory:

*   **Enable Maintenance Mode (prevents jobs from running):**
    ```powershell
    .\PoSh-Backup.ps1 -Maintenance $true
    ```

*   **Disable Maintenance Mode:**
    ```powershell
    .\PoSh-Backup.ps1 -Maintenance $false
    ```

*   **Force a job to run even if Maintenance Mode is active:**
    ```powershell
    .\PoSh-Backup.ps1 -BackupLocationName "MyDocs_To_UNC" -ForceRunInMaintenanceMode
    ```

*   **Run a specific backup job, ensure it's verified before any remote transfer, and keep only the last 5 log files for this job:**
    ```powershell
    .\PoSh-Backup.ps1 -BackupLocationName "MyDocumentsBackupSFX_GUI_Affinity" -VerifyLocalArchiveBeforeTransferCLI -LogRetentionCountCLI 5
    ```
    (Replace `"MyDocumentsBackupSFX_GUI_Affinity"` with the actual name of a job you defined in `BackupLocations`. If this job has a `PostRunAction` configured, it will be evaluated after the job.)

*   **Run a predefined Backup Set:** (Backup Sets group multiple jobs and are defined in `User.psd1` or `Default.psd1`.)
    ```powershell
    .\PoSh-Backup.ps1 -RunSet "DailyCriticalBackups"
    ```
    (Replace `"DailyCriticalBackups"` with the name of a defined set. If the "DailyCriticalBackups" set has a `PostRunAction`, it will be evaluated after all jobs in the set complete. This set-level action overrides any job-level post-run actions within the set. Log retention for jobs in this set will follow the set's `LogRetentionCount` if defined, otherwise job or global settings.)

*   **Run a Hyper-V VM backup job:**
    ```powershell
    .\PoSh-Backup.ps1 -BackupLocationName "HyperV_VM_Backup_Example"
    ```

*   **Simulate a backup job (local archive creation, any remote transfers, checksum operations, SFX creation, CPU affinity application, log retention, and post-run actions will be simulated):**
    ```powershell
    .\PoSh-Backup.ps1 -BackupLocationName "MyDocumentsBackupSFX_GUI_Affinity" -Simulate
    ```

*   **Run a job and treat 7-Zip warnings from local archiving as success for status reporting:**
    ```powershell
    .\PoSh-Backup.ps1 -BackupLocationName "MyFrequentlySkippedFilesJob" -TreatSevenZipWarningsAsSuccessCLI
    ```

*   **Test your configuration file for errors and view a summary of loaded settings (post-run actions also simulated):**
    ```powershell
    .\PoSh-Backup.ps1 -TestConfig
    ```
    (This is very useful after making changes to `User.psd1`. If this job has dependencies, they will be processed first according to the defined order.)

*   **List all defined backup jobs and their basic details:**
    ```powershell
    .\PoSh-Backup.ps1 -ListBackupLocations
    ```

*   **List all defined backup sets and the jobs they contain:**
    ```powershell
    .\PoSh-Backup.ps1 -ListBackupSets
    ```

*   **CLI Override for Post-Run Action:** Force a shutdown after any job/set, regardless of configuration, with a 60-second delay, only if the overall status is SUCCESS or WARNINGS:
    ```powershell
    .\PoSh-Backup.ps1 -BackupLocationName "MyImportantJob" -PostRunActionCli "Shutdown" -PostRunActionDelaySecondsCli 60 -PostRunActionTriggerOnStatusCli @("SUCCESS", "WARNINGS")
    ```
    To prevent any post-run action, even if configured:
    ```powershell
    .\PoSh-Backup.ps1 -RunSet "NightlyServerMaintenance" -PostRunActionCli "None"
    ```
*   **CLI Override for 7-Zip CPU Affinity:** Run a job and restrict 7-Zip to cores 0 and 1:
    ```powershell
    .\PoSh-Backup.ps1 -BackupLocationName "MyLargeArchiveJob" -SevenZipCpuAffinityCLI "0,1"
    ```
*   **CLI Override for 7-Zip Exclude List File:** Run a job using a specific exclude list file:
    ```powershell
    .\PoSh-Backup.ps1 -BackupLocationName "MySensitiveDataJob" -SevenZipExcludeListFileCLI "C:\BackupConfig\GlobalExcludes.txt"

*   **CLI Override for Splitting Archives:**
    ```powershell
    .\PoSh-Backup.ps1 -BackupLocationName "MyVeryLargeBackup" -SplitVolumeSizeCLI "10g"
    ```
    (This runs "MyVeryLargeBackup" and splits the archive into 10GB volumes, overriding any `SplitVolumeSize` or `CreateSFX` settings in the configuration for this job.)
    ```

*   **Run a job and pin the resulting archive:**
    ```powershell
    .\PoSh-Backup.ps1 -BackupLocationName "MyPreUpgradeBackup" -Pin
    ```
    (This runs the "MyPreUpgradeBackup" job and automatically creates a `.pinned` file for the new archive, protecting it from retention.)

*   **Run a backup set and suppress console output:**
    ```powershell
    .\PoSh-Backup.ps1 -RunSet "DailyCriticalBackups" -Quiet
    ```

*   **Check for PoSh-Backup Updates:**
    ```powershell
    .\PoSh-Backup.ps1 -CheckForUpdate
    ```
    (This will connect to the internet to check for a newer version of the script and inform you of the result. It will not perform any backup operations.)

    ### Integrated Backup Scheduling
    PoSh-Backup now includes a powerful feature to manage scheduled backups directly from your configuration file, providing a true "set and forget" capability. This works by translating schedule settings in your `User.psd1` into tasks within the native Windows Task Scheduler.

    **How it Works:**
    1.  **Configure:** You define a `Schedule` block within any backup job in your `User.psd1` file.
    2.  **Synchronise:** You run a new command, `.\PoSh-Backup.ps1 -SyncSchedules`, from an **Administrator** PowerShell prompt.
    3.  **Execute:** The script reads your configuration and creates, updates, or removes tasks in the Windows Task Scheduler to match your settings. The Task Scheduler then takes over and runs your backup jobs automatically according to the defined triggers.

    **Configuration Example:**

    Here is an example of a `Schedule` block you can add inside a job definition in `User.psd1`:

    ```powershell
    "MyDocumentsBackup" = @{
        Path = "C:\Users\MyUser\Documents"
        Name = "MyDocuments"
        # ... other job settings ...

        # --- Integrated Scheduling Settings ---
        Schedule = @{
            # Master switch for this job's schedule.
            Enabled = $true

            # Type of schedule: 'Daily', 'Weekly', 'OnLogon', 'OnStartup'
            Type = 'Weekly'

            # Time to run (24-hour format). Required for Daily/Weekly.
            Time = '20:30'

            # Days for a 'Weekly' schedule.
            DaysOfWeek = @('Tuesday', 'Friday')

            # User to run the task as: 'SYSTEM' or 'Author' (the user who runs -SyncSchedules).
            # 'SYSTEM' is powerful but may lack network permissions. 'Author' is often safer.
            RunAsUser = 'Author'

            # Set to $true if the job requires VSS or other admin rights.
            HighestPrivileges = $true

            # If $true, will try to wake the computer from sleep to run the backup.
            WakeToRun = $true
        }
    }

### Automated Backup Verification
PoSh-Backup includes a powerful feature to automate the verification of your backups, providing a high degree of confidence that they are valid and restorable. This works by defining "Verification Jobs" that restore an archive to a temporary "sandbox" location and then check the restored files against a manifest that was created during the original backup.

**How it Works:**
1.  **Enable Manifest Creation:** For any backup job you wish to verify, you must first enable the creation of a contents manifest. In your `User.psd1`, add `GenerateContentsManifest = $true` to the job's definition. This creates a `.contents.manifest` file alongside the backup archive, listing every file's path, size, modification date, attributes, and CRC checksum.
2.  **Configure a Verification Job:** In the `VerificationJobs` section of your `User.psd1`, define a new verification task. You specify which backup job to target, where the temporary sandbox directory is, and what checks to perform.
3.  **Run Verification:** From an Administrator PowerShell prompt, run the command `.\PoSh-Backup.ps1 -RunVerificationJobs`.
4.  **Process:** The script will find the latest backup for your target job, restore it to the sandbox, perform the checks, log the results, and then clean up the sandbox.

**Configuration Example:**

Here is an example of a `VerificationJobs` block you can add to `User.psd1`:

```powershell
# In Config\User.psd1
VerificationJobs = @{
    "Verify_Projects_Backup" = @{
        # Master switch for this verification job. Set to $true to enable.
        Enabled = $true

        # The name of the BackupLocation whose archives you want to test.
        # This job *must* have 'GenerateContentsManifest = $true' set.
        TargetJobName = "Projects" 
        
        # If the target archive is encrypted, provide the secret name.
        ArchivePasswordSecretName = "MyArchivePassword" # Optional

        # A temporary, empty directory where the archive will be restored for verification.
        # WARNING: The contents of this directory will be cleared automatically if not empty
        # and OnDirtySandbox is set to 'CleanAndContinue'.
        SandboxPath = "D:\Backup_Verification_Sandbox"

        # What to do if the sandbox path is not empty when the job starts.
        # "Fail" (default): The verification job will fail.
        # "CleanAndContinue": The verification job will attempt to delete the contents and proceed.
        OnDirtySandbox = "CleanAndContinue"

        # An array of verification steps to perform after the restore.
        # - "TestArchive": Runs `7z t` on the archive file itself.
        # - "VerifyChecksums": Parses the contents manifest and verifies the existence,
        #   size, modification date, and CRC checksum for every restored file.
        VerificationSteps = @("TestArchive", "VerifyChecksums")
        
        # How many of the most recent backup instances for the TargetJobName to test.
        # '1' will test only the very latest backup. '3' will test the latest three.
        TestLatestCount = 1
    }
}
```

### 5. Key Operational Command-Line Parameters
These parameters allow you to override certain configuration settings for a specific run:

*   `-Maintenance <boolean>`: A utility parameter to enable (`$true`) or disable (`$false`) maintenance mode by creating or deleting the on-disk flag file. This does not run a backup.
*   `-ForceRunInMaintenanceMode`: Forces a backup job or set to run even if maintenance mode is active.
*   `-UseVSS`: Forces the script to attempt using Volume Shadow Copy Service for all processed jobs (for local sources, requires Administrator privileges). Overridden by `-SkipVSS`.
*   `-SkipVSS`: Forces the script to NOT use VSS, overriding any configuration or the `-UseVSS` switch. Useful for troubleshooting.
*   `-EnableRetriesCLI`: Forces the enabling of the 7-Zip retry mechanism for local archiving. Overridden by `-SkipRetriesCLI`.
*   `-SkipRetriesCLI`: Forces the disabling of the 7-Zip retry mechanism, overriding any configuration or the `-EnableRetriesCLI` switch. Useful for troubleshooting.
*   `-TestArchive`: Forces an integrity test of newly created *local* archives for all processed jobs. If checksum generation and verification are enabled for the job, this will include checksum verification. This is independent of `-VerifyLocalArchiveBeforeTransferCLI`.
*   `-VerifyLocalArchiveBeforeTransferCLI`: Forces verification of the local archive (including checksum if enabled for the job) *before* any remote transfers are attempted. Overrides configuration settings. If verification fails, remote transfers for the job are skipped.
*   `-Simulate`: Runs in simulation mode. Local archiving, remote transfers, retention actions (archive and log), checksum operations, SFX creation, CPU affinity application, and post-run system actions are logged but not actually executed.
*   `-TreatSevenZipWarningsAsSuccessCLI`: Forces 7-Zip exit code 1 (Warning) from *local* archiving to be treated as a success for the job status, overriding any configuration settings.
*   `-NotificationProfileNameCLI <ProfileName>`: Overrides any configured notification profile for the current run. The specified `<ProfileName>` must be defined in the `NotificationProfiles` section of your configuration. This will also force notifications to be enabled for the run.
*   `-SevenZipCpuAffinityCLI <AffinityString>`: Overrides any configured 7-Zip CPU core affinity. Examples: `"0,1"` or `"0x3"`.
*   `-SevenZipIncludeListFileCLI <FilePath>`: Overrides any configured 7-Zip include list file with the specified file path.
*   `-SevenZipExcludeListFileCLI <FilePath>`: Overrides any configured 7-Zip exclude list file with the specified file path.
*   `-SplitVolumeSizeCLI <SizeString>`: Overrides archive splitting configuration (e.g., "100m", "4g"). An empty string (`""`) passed to this CLI parameter will disable splitting if it was enabled in the config. This will also override SFX creation if a valid split size is provided.
*   `-LogRetentionCountCLI <Count>`: Overrides all configured log retention counts (global, job, set). Specifies the number of log files to keep per job name pattern. A value of `0` means infinite retention (keep all logs).
*   `-PauseBehaviourCLI <Always|Never|OnFailure|OnWarning|OnFailureOrWarning>`: Controls if the script pauses with a "Press any key to continue" message before exiting. Overrides the `PauseBeforeExit` setting in the configuration file.
*   `-PostRunActionCli <Action>`: Overrides all configured post-run actions.
    *   Valid `<Action>`: "None", "Shutdown", "Restart", "Hibernate", "LogOff", "Sleep", "Lock".
*   `-PostRunActionDelaySecondsCli <Seconds>`: Delay for the CLI-specified action. Defaults to 0 if `-PostRunActionCli` is used but this parameter is not.
*   `-PostRunActionForceCli`: Switch to force Shutdown/Restart for the CLI-specified action.
*   `-PostRunActionTriggerOnStatusCli <StatusArray>`: Status(es) to trigger CLI action. Defaults to `@("ANY")` if `-PostRunActionCli` is used but this parameter is not. Valid: "SUCCESS", "WARNINGS", "FAILURE", "SIMULATED_COMPLETE", "ANY".
*   `-Pin`: Optional. A switch parameter. If present, the backup archive(s) created during this specific run will be automatically pinned, protecting them from retention policies.
*   `-PinBackup <FilePath>`: Pins the backup archive specified by `<FilePath>`, protecting it from retention policies. This creates a `.pinned` marker file alongside the archive.
*   `-UnpinBackup <FilePath>`: Unpins the backup archive specified by `<FilePath>`, making it subject to retention policies again. This removes the `.pinned` marker file.
*   `-ListArchiveContents <FilePath>`: Lists the contents of the backup archive specified by `<FilePath>`. This is a utility mode and does not run a backup.
*   `-RunVerificationJobs`: A switch to run all enabled automated backup verification jobs defined in the configuration. This performs a restore to a temporary sandbox location and verifies the integrity of the restored files against a manifest created during the backup. This is a standalone mode and will not perform any regular backup jobs.
*   `-ArchivePasswordSecretName <SecretName>`: For use with utility modes like `-ListArchiveContents`. Specifies the name of the secret in PowerShell SecretManagement that holds the password for an encrypted archive.
*   `-ExtractFromArchive <FilePath>`: Extracts files from the backup archive specified by `<FilePath>`. Must be used with `-ExtractToDirectory`.
*   `-ExtractToDirectory <DirectoryPath>`: The destination directory where files will be extracted.
*   `-ItemsToExtract <String[]>`: Optional. An array of specific file or folder paths inside the archive to extract. If omitted, the entire archive is extracted.
*   `-ForceExtract`: Optional. A switch. If present, extraction will overwrite existing files in the destination directory without prompting.
*   `-SyncSchedules`: Synchronises job schedules from the configuration file with the Windows Task Scheduler, creating, updating, or removing tasks as needed, then exits. Requires Administrator privileges.
*   `-CheckForUpdate`: Checks for available updates to PoSh-Backup online and then exits. Does not perform any backup operations.
*   `-Quiet`: Suppresses all non-essential console output. Critical errors will still be displayed. Useful for scheduled tasks.

### Pinning Backups to Prevent Deletion
PoSh-Backup includes a feature to "pin" a specific backup archive, which makes it immune to automatic deletion by local or remote retention policies. This is useful for preserving important milestone backups, such as the first backup of a new system, a backup from before a major upgrade, or a known-good full backup that you want to keep as a baseline.

*   **How it Works:**
    *   Pinning a backup is achieved by creating a "marker file" in the same directory as the archive. The marker file has the exact same name as the archive file but with `.pinned` appended.
    *   For example, to pin the archive `MyJob [2025-06-06].7z`, a file named `MyJob [2025-06-06].7z.pinned` is created.
    *   When the retention policy runs, it scans for these `.pinned` files. Any backup instance associated with a `.pinned` file is completely ignored by the retention logic and will not be counted towards the `KeepCount`.

There are two ways to pin a backup: during its creation, or after it already exists.

#### Pinning an Archive During Creation
Use this method when you know in advance that the backup you are about to create needs to be preserved.

*   **Via Command-Line:** The easiest way is to add the `-Pin` switch to your backup command.
    ```powershell
    .\PoSh-Backup.ps1 -BackupLocationName "MyPreUpgradeBackup" -Pin
    ```
*   **Via Configuration:** You can make this behaviour permanent for a specific job by setting `PinOnCreation = $true` in its configuration in `User.psd1`.

#### Managing Pins on Existing Backups
Use this method to manage pins on any archive that already exists in your backup destination.

*   **To Pin an Existing Backup:**
    ```powershell
    .\PoSh-Backup.ps1 -PinBackup "D:\Backups\MyJob [2025-06-06].7z"
    ```
    This command will create the `D:\Backups\MyJob [2025-06-06].7z.pinned` file.

*   **To Unpin an Existing Backup:**
    ```powershell
    .\PoSh-Backup.ps1 -UnpinBackup "D:\Backups\MyJob [2025-06-06].7z"
    ```
    This command will remove the `.pinned` marker file, making the archive subject to normal retention policies on the next run.

*   **Important Notes on Pinned Backups:**
    *   Pinning applies to an entire backup instance. If you pin the first volume of a multi-volume set (e.g., `archive.7z.001`), the entire set (all `.00x` parts and any associated manifest) is considered pinned. The marker file should be named after the base archive, e.g., `archive.7z.pinned`. The `-PinBackup` command handles this correctly if you point it to the `.001` file.
    *   Pinned backups are *not* counted in the retention number. If you have `KeepCount = 5` and 2 backups are pinned, the retention policy will still keep the 5 most recent *unpinned* backups, in addition to the 2 pinned ones.

### Archive Management Utilities
PoSh-Backup includes command-line utilities for inspecting and restoring from existing backup archives without performing a full backup run.

#### Listing Archive Contents
You can list the contents of any archive file to see what files and folders it contains. This is useful for quickly verifying an archive or finding a specific file before you restore it.

*   **Command:**
    ```powershell
    .\PoSh-Backup.ps1 -ListArchiveContents "D:\Backups\MyJob [2025-06-06].7z"
    ```

*   **For Encrypted Archives:** If the archive is password-protected, you must also provide the name of the secret where the password is stored in PowerShell SecretManagement.
    ```powershell
    .\PoSh-Backup.ps1 -ListArchiveContents "D:\EncryptedBackups\SecureJob [2025-06-06].7z" -ArchivePasswordSecretName "MyBackupPasswordSecret"
    ```

#### Extracting from an Archive (Restore)
You can restore the entire contents of an archive, or just specific files and folders, to a directory of your choice.

*   **To Restore an Entire Archive:**
    Provide the path to the archive and a destination directory. The original folder structure will be preserved.
    ```powershell
    .\PoSh-Backup.ps1 -ExtractFromArchive "D:\Backups\MyJob [2025-06-06].7z" -ExtractToDirectory "C:\Temp\Restore"
    ```

*   **To Restore Specific Files or Folders:**
    You can specify one or more items to extract. The paths must match what is shown in the `-ListArchiveContents` output.
    ```powershell
    # Restore a single file and an entire folder
    .\PoSh-Backup.ps1 -ExtractFromArchive "D:\Backups\MyJob [2025-06-06].7z" `
                      -ExtractToDirectory "C:\Temp\SpecificRestore" `
                      -ItemsToExtract "Path\To\MyDocument.txt", "Path\To\MyFolder"
    ```

*   **For Encrypted Archives:** Use the `-ArchivePasswordSecretName` parameter, just like with listing.
    ```powershell
    .\PoSh-Backup.ps1 -ExtractFromArchive "D:\EncryptedBackups\SecureJob [2025-06-06].7z" `
                      -ExtractToDirectory "C:\Temp\Restore" `
                      -ArchivePasswordSecretName "MyBackupPasswordSecret"
    ```

*   **Handling Existing Files (Overwrite Behaviour):**
    *   By default, if a file already exists in the destination, 7-Zip will **skip** extracting it to prevent accidental data loss.
    *   To force the extraction to overwrite any existing files, add the `-ForceExtract` switch.
    ```powershell
    .\PoSh-Backup.ps1 -ExtractFromArchive "D:\Backups\MyJob [2025-06-06].7z" -ExtractToDirectory "C:\Temp\Restore" -ForceExtract
    ```

### Update Checking
PoSh-Backup can check if a newer version is available online. This is a manual check initiated by the user.

*   **How it Works:**
    1.  When `.\PoSh-Backup.ps1 -CheckForUpdate` is run, the script contacts a predefined URL (hardcoded in `Modules\Utilities\Update.psm1`) to fetch a "version manifest" file. This manifest contains details about the latest official release.
    2.  The script compares the `InstalledVersion` from your local `Meta\Version.psd1` file with the `LatestVersion` from the remote manifest.
    3.  If an update is available, details such as the new version number, release date, release notes URL, and download URL will be displayed.
    4.  The script will then prompt if you wish to attempt an automatic update. (Note: The self-application of the update is currently under development. For now, you will be directed to download and apply it manually.)
    5.  If your version is current or newer (e.g., a development build), an appropriate message will be shown.
*   **Local Version File (`Meta\Version.psd1`):** This file in your PoSh-Backup installation directory stores the version number and release date of your current installation. It's updated by the developers with each release.
*   **Automatic Updates:** This feature informs you about updates and then prompts you on whether you would like to update. Note that this feature hasn't been fully tested; ensure you have manually backed up any custom `Config\` configuration files first.
*   **Internet Access:** Requires an internet connection to fetch the remote version manifest.

For a full list of all command-line parameters and their descriptions, use PowerShell's built-in help:
```powershell
Get-Help .\PoSh-Backup.ps1 -Full
