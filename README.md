# PoSh-Backup
A powerful, modular PowerShell script for backing up your files and folders using the free [7-Zip](https://www.7-zip.org/) compression software. Now with extensible support for remote Backup Targets.

> **Notice:** This script is under active development. While it offers robust features, use it at your own risk, especially in production environments, until it has undergone more extensive community testing. This project is also an exploration of AI-assisted development.

## Features
*   **Enterprise-Grade PowerShell Solution:** Robust, modular design built with dedicated PowerShell modules for reliability, maintainability, and clarity.
*   **Flexible External Configuration:** Manage all backup jobs, global settings, backup sets, and remote **Backup Target** definitions via a human-readable `.psd1` configuration file.
*   **Local and Remote Backups:**
    *   Archives are initially created in a **local staging directory** (defined by `DestinationDir` in job settings).
    *   Jobs can be configured to additionally transfer these archives to one or more **remote Backup Targets** (e.g., UNC shares, with future support for FTP, S3, etc., via an extensible provider model).
    *   If no remote targets are specified for a job, the local staging directory serves as the final backup location.
*   **Granular Backup Job Control:** Precisely define sources, destinations (local staging), archive names, local retention policies, 7-Zip parameters, and **remote target assignments** for each individual backup job.
*   **Backup Sets:** Group multiple jobs to run sequentially, with set-level error handling (stop on error or continue) for automated workflows.
*   **Extensible Backup Target Providers:** A modular system (located in `Modules\Targets\`) allows for adding support for various remote storage types (a UNC provider is included initially). Each provider module is responsible for its specific transfer protocol and can implement its own remote retention logic.
*   **Configurable Retention Policies:**
    *   **Local Retention:** Manage archive versions in the local staging directory (`DestinationDir`) using the `LocalRetentionCount` setting per job.
    *   **Remote Retention:** Each Backup Target provider can, if designed to do so, implement its own retention logic on the remote storage (e.g., keep last X versions, delete after Y days). This is configured within the target's definition in the `BackupTargets` section (e.g., via `RemoteRetentionSettings`).
*   **Live File Backups with VSS:** Utilise the Windows Volume Shadow Copy Service (VSS) to seamlessly back up open or locked files (requires Administrator privileges). Features configurable VSS context, reliable shadow copy creation, and a configurable metadata cache path.
*   **Advanced 7-Zip Integration:** Leverage 7-Zip for efficient, highly configurable compression. Customise archive type, compression level, method, dictionary/word/solid block sizes, thread count, and file exclusions for local archive creation.
*   **Secure Password Protection:** Encrypt local backup archives with passwords, handled securely via temporary files (using 7-Zip's `-spf` switch) to prevent command-line exposure. Multiple password sources supported (Interactive, PowerShell SecretManagement, Encrypted File, Plaintext).
*   **Customisable Archive Naming:** Tailor local archive filenames with a base name and a configurable date stamp (e.g., "yyyy-MMM-dd", "yyyyMMdd_HHmmss"). Set archive extensions (e.g., .7z, .zip) per job.
*   **Automatic Retry Mechanism:** Overcome transient failures during 7-Zip operations for local archive creation. (Note: Retries for remote transfers are the responsibility of the specific Backup Target provider module, if implemented.)
*   **CPU Priority Control:** Manage system resource impact by setting the 7-Zip process priority (e.g., Idle, BelowNormal, Normal, High) for local archiving.
*   **Extensible Script Hooks:** Execute your own custom PowerShell scripts at various stages of a backup job for ultimate operational flexibility. Hook scripts now receive information about target transfer results if applicable.
*   **Multi-Format Reporting:** Generate comprehensive reports for each job.
    *   **Interactive HTML Reports:** Highly customisable with titles, logos, and themes (via external CSS). Now includes a dedicated section detailing the status of **Remote Target Transfers**.
        *   **Collapsible Sections:** Summary, Configuration, Hooks, Target Transfers, and Detailed Log sections are collapsible for easier navigation, with their open/closed state remembered in the browser (via `localStorage`).
        *   **Advanced Log Filtering:** Client-side keyword search and per-level checkbox filtering for log entries. Includes "Select All" / "Deselect All" buttons for log levels and a visual indicator when filters are active.
        *   **Keyword Highlighting:** Searched keywords are automatically highlighted within the log entries.
        *   **Dynamic Table Sorting:** Key data tables (Summary, Configuration, Hooks, Target Transfers) can be sorted by clicking column headers.
        *   **Copy to Clipboard:** Easily copy the output of executed hook scripts using a dedicated button.
        *   **Scroll to Top Button:** Appears on long reports for quick navigation back to the top of the page.
        *   **Configurable Favicon:** Display a custom icon in the browser tab for the report.
        *   **Print-Optimized:** Includes basic print-specific CSS for better paper output (e.g., hides interactive elements, ensures content is visible).
        *   **Simulation Banner:** Clearly distinguishes reports generated from simulation runs.
    *   **Other Formats:** CSV, JSON, XML (CliXml), Plain Text (TXT), and Markdown (MD) also supported for data export and integration, updated to include target transfer details where appropriate.
*   **Comprehensive Logging:** Get detailed, colour-coded console output and optional per-job text file logs for easy monitoring and troubleshooting of both local operations and remote transfers.
*   **Safe Simulation Mode:** Perform a dry run (`-Simulate`) to preview local backup operations, remote transfers, and retention actions without making any actual changes.
*   **Configuration Validation:** Quickly test and validate your configuration file (`-TestConfig`), including basic validation of Backup Target definitions. Optional advanced schema validation available.
*   **Proactive Free Space Check:** Optionally verify sufficient destination disk space in the local staging directory before starting backups to prevent failures.
*   **Archive Integrity Verification:** Optionally test the integrity of newly created local archives.
*   **Flexible 7-Zip Warning Handling:** Option to treat 7-Zip warnings (exit code 1, e.g., from skipped open files) as a success for job status reporting, configurable globally, per-job, or via CLI.
*   **Exit Pause Control:** Control script pausing behaviour on completion (Always, Never, OnFailure, etc.) for easier review of console output, with CLI override.

## Getting Started

### 1. Prerequisites
*   **PowerShell:** Version 5.1 or higher.
*   **7-Zip:** Must be installed. PoSh-Backup will attempt to auto-detect `7z.exe` in common Program Files locations or your system PATH. If not found, or if you wish to use a specific 7-Zip instance, you'll need to specify the full path in the configuration file. ([Download 7-Zip](https://www.7-zip.org/))
*   **Administrator Privileges:** Required if you plan to use the Volume Shadow Copy Service (VSS) feature for backing up open/locked files.
*   **Network/Remote Access:** For using Backup Targets, appropriate permissions and connectivity to the remote locations (e.g., UNC shares) are necessary for the user account running PoSh-Backup.

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
        *   `Targets/`: **New sub-directory for Backup Target provider modules** (e.g., `UNC.Target.psm1`).
    *   `Meta/`: Contains scripts related to the development of PoSh-Backup itself (like the script to generate bundles for AI).
    *   `Logs/`: Default directory where text log files will be stored for each job run (if file logging is enabled in the configuration).
    *   `Reports/`: Default directory where generated backup reports (HTML, CSV, etc.) will be saved.
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
    *   **`SevenZipPath`**:
        *   By default, this is empty (`""`), and the script tries to auto-detect `7z.exe`.
        *   If auto-detection fails, or you have multiple 7-Zip versions and want to specify one, set the full path here. Example: `'C:\Program Files\7-Zip\7z.exe'`.
    *   **`DefaultDestinationDir`**:
        *   This now serves as the default **local staging directory** where archives are first created before any potential remote transfer. Example: `'D:\Backup_StagingArea'`.
        *   Ensure this directory exists, or the script has permissions to create it.
    *   **`DeleteLocalArchiveAfterSuccessfulTransfer` (Global Setting):**
        *   Defaults to `$true`. If true, the locally staged archive will be deleted after it has been successfully transferred to ALL specified remote targets for a job. Can be overridden per job.
    *   **`TreatSevenZipWarningsAsSuccess`**: (Global Setting)
        *   Defaults to `$false`. If set to `$true`, 7-Zip warnings (like skipped files) will still result in a "SUCCESS" job status.
    *   **`BackupTargets` (New Global Section):**
        *   This is where you define your reusable, named remote target configurations.
        *   Each entry (a "target instance") specifies a `Type` (like "UNC", which corresponds to a provider module, e.g., `Modules\Targets\UNC.Target.psm1`) and `TargetSpecificSettings` for that type.
        *   Optionally, you can include `CredentialsSecretName` if the provider supports credentialed access via PowerShell SecretManagement, and `RemoteRetentionSettings` for provider-specific retention on the target.
        *   Example of defining a UNC target instance in `User.psd1` (or `Default.psd1`):
            ```powershell
            # Inside User.psd1 or Default.psd1, within the main @{ ... }
            BackupTargets = @{
                "MyMainUNCShare" = @{
                    Type = "UNC" # Refers to Modules\Targets\UNC.Target.psm1
                    TargetSpecificSettings = @{
                        UNCRemotePath = "\\fileserver01\backups\MyPoShBackups" # Base path on the UNC share
                        # Optional: CredentialsSecretName = "UNCShareCredentials" # For future credentialed access by provider
                    }
                    # Optional: Provider-specific remote retention (structure depends on the provider)
                    # RemoteRetentionSettings = @{ KeepCount = 7 } 
                }
                # Add other targets, e.g., for FTP, S3, etc. as providers become available.
            }
            ```
    *   **`BackupLocations` (Job Definitions):**
        *   This is the most important section for defining what to back up. It's a hashtable where each entry is a backup job.
        *   `User.psd1` (copied from `Default.psd1`) will contain example job definitions. Modify or replace these.
        *   Each job definition requires:
            *   `Path`: Source path(s) to back up (string or array of strings).
            *   `Name`: Base name for the archive file.
        *   Key settings for local and remote behaviour:
            *   `DestinationDir`: Specifies the **local staging directory** for this particular job's archive. Overrides `DefaultDestinationDir`.
            *   `LocalRetentionCount`: (Renamed from `RetentionCount`) Defines how many archive versions to keep in the local `DestinationDir` (staging area).
            *   `TargetNames` (New Setting): An array of strings. Each string must be a name of a target instance defined in the global `BackupTargets` section. If you specify target names here, the locally created archive will be transferred to each listed remote target. If `TargetNames` is omitted or empty, the backup is local-only to `DestinationDir`.
            *   `DeleteLocalArchiveAfterSuccessfulTransfer` (Job-Specific): Overrides the global setting for this job.
        *   Example job definition that creates a local archive and sends it to a remote target:
            ```powershell
            # Inside BackupLocations in User.psd1 or Default.psd1
            "MyDocumentsBackup" = @{
                Path           = @( # Array of paths to back up
                                 "C:\Users\YourUserName\Documents",
                                 "E:\WorkProjects\CriticalData"
                               )
                Name           = "UserDocumentsArchive" # Base name for the archive file
                DestinationDir = "E:\BackupStaging\MyDocs"   # Local staging location for this job.
                LocalRetentionCount = 3                     # Keep 3 versions in staging.

                TargetNames = @("MyMainUNCShare") # Send to the 'MyMainUNCShare' target defined in BackupTargets.
                DeleteLocalArchiveAfterSuccessfulTransfer = $true # Delete from E:\BackupStaging after successful UNC transfer.
                
                # Other job-specific settings like EnableVSS, ArchivePasswordMethod, etc.
            }

            "ImportantProject_LocalOnly" = @{
                Path           = "D:\Projects\CriticalProject"
                Name           = "CriticalProjectArchive"
                DestinationDir = "E:\FinalBackups\Projects" # This acts as the final local destination.
                LocalRetentionCount = 10                   # Keep 10 versions locally.
                # No TargetNames specified, so this is a local-only backup.
            }
            ```
3.  **Explore `Config\Default.psd1` for All Options:**
    *   Open `Config\Default.psd1` (but don't edit it for your settings). This file serves as a comprehensive reference. It contains detailed comments explaining every available global and job-specific setting.

### 4. Basic Usage Examples
Once your `Config\User.psd1` is configured with at least one backup job, you can run PoSh-Backup from a PowerShell console located in the script's root directory:

*   **Run a specific backup job (it may be local-only or also send to remote targets based on its configuration):**
    ```powershell
    .\PoSh-Backup.ps1 -BackupLocationName "MyDocumentsBackup"
    ```
    (Replace `"MyDocumentsBackup"` with the actual name of a job you defined in `BackupLocations`.)

*   **Run a predefined Backup Set:** (Backup Sets group multiple jobs and are defined in `User.psd1` or `Default.psd1`.)
    ```powershell
    .\PoSh-Backup.ps1 -RunSet "DailyCriticalBackups"
    ```
    (Replace `"DailyCriticalBackups"` with the name of a defined set.)

*   **Simulate a backup job (local archive creation and any remote transfers will be simulated):**
    ```powershell
    .\PoSh-Backup.ps1 -BackupLocationName "MyDocumentsBackup" -Simulate
    ```

*   **Run a job and treat 7-Zip warnings from local archiving as success for status reporting:**
    ```powershell
    .\PoSh-Backup.ps1 -BackupLocationName "MyFrequentlySkippedFilesJob" -TreatSevenZipWarningsAsSuccessCLI
    ```

*   **Test your configuration file for errors and view a summary of loaded settings:**
    ```powershell
    .\PoSh-Backup.ps1 -TestConfig
    ```
    (This is very useful after making changes to `User.psd1`.)

*   **List all defined backup jobs and their basic details:**
    ```powershell
    .\PoSh-Backup.ps1 -ListBackupLocations
    ```

*   **List all defined backup sets and the jobs they contain:**
    ```powershell
    .\PoSh-Backup.ps1 -ListBackupSets
    ```

### 5. Key Operational Command-Line Parameters
These parameters allow you to override certain configuration settings for a specific run:

*   `-UseVSS`: Forces the script to attempt using Volume Shadow Copy Service for all processed jobs (for local sources, requires Administrator privileges).
*   `-TestArchive`: Forces an integrity test of newly created *local* archives for all processed jobs.
*   `-Simulate`: Runs in simulation mode. Local archiving, remote transfers, and retention actions are logged but not actually executed.
*   `-TreatSevenZipWarningsAsSuccessCLI`: Forces 7-Zip exit code 1 (Warning) from *local* archiving to be treated as a success for the job status, overriding any configuration settings.
*   `-PauseBehaviourCLI <Always|Never|OnFailure|OnWarning|OnFailureOrWarning>`: Controls if the script pauses with a "Press any key to continue" message before exiting. Overrides the `PauseBeforeExit` setting in the configuration file.

For a full list of all command-line parameters and their descriptions, use PowerShell's built-in help:
```powershell
Get-Help .\PoSh-Backup.ps1 -Full
