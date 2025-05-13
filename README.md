# PoSh-Backup
A powerful PowerShell script for backing up your files that uses the free [7-Zip](https://www.7-zip.org/) compression software.

> **Notice:** You use this at your own risk! It hasn't undergone as much testing as I'd like, as it's still deep within development! **Another bonus:** I'm testing some AI features, and so this has been written via that AI under guidance.

## Features include:
*   **Enterprise-Grade PowerShell Solution:** Robust, modular design built with dedicated PowerShell modules for reliability, maintainability, and clarity.
*   **Flexible External Configuration:** Manage all backup jobs, global settings, and backup sets via a human-readable `.psd1` configuration file.
*   **Granular Backup Job Control:** Precisely define sources, destinations, archive names, retention policies, 7-Zip parameters, and more for each individual backup job.
*   **Backup Sets:** Group multiple jobs to run sequentially, with set-level error handling (stop on error or continue) for automated workflows.
*   **Live File Backups with VSS:** Utilise the Windows Volume Shadow Copy Service (VSS) to seamlessly back up open or locked files (requires Administrator privileges). Features configurable VSS context, reliable shadow copy creation, and a configurable metadata cache path.
*   **Advanced 7-Zip Integration:** Leverage 7-Zip for efficient, highly configurable compression. Customise archive type, compression level, method, dictionary/word/solid block sizes, thread count, and file exclusions.
*   **Secure Password Protection:** Encrypt backups with passwords, handled securely via temporary files (using 7-Zip's `-spf` switch) to prevent command-line exposure.
*   **Customizable Archive Naming:** Tailor archive filenames with a base name and a configurable date stamp (e.g., "yyyy-MMM-dd", "yyyyMMdd_HHmmss"). Set archive extensions (e.g., .7z, .zip) per job.
*   **Automatic Retry Mechanism:** Overcome transient failures during 7-Zip operations with configurable automatic retries and delays.
*   **CPU Priority Control:** Manage system resource impact by setting the 7-Zip process priority (e.g., Idle, BelowNormal, Normal, High).
*   **Extensible Script Hooks:** Execute your own custom PowerShell scripts at various stages of a backup job for ultimate operational flexibility.
*   **Rich HTML Reporting:** Generate comprehensive, highly customisable HTML reports for each job. Tailor titles, logos, company info, themes (via external CSS), and visible sections. Includes robust HTML encoding for XSS protection.
*   **Comprehensive Logging:** Get detailed, colour-coded console output and optional per-job text file logs for easy monitoring and troubleshooting.
*   **Safe Simulation Mode:** Perform a dry run (`-Simulate`) to preview backup operations without making any actual changes.
*   **Configuration Validation:** Quickly test and validate your configuration file (`-TestConfig`) before execution.
*   **Proactive Free Space Check:** Optionally verify sufficient destination disk space before starting backups to prevent failures.
*   **Archive Integrity Verification:** Optionally test the integrity of newly created archives to ensure backup reliability.
*   **Exit Pause:** Control script pausing behaviour on completion (Always, Never, OnFailure, etc.) for easier review of console output, with CLI override.

## How to Use
This information is coming soon to the wiki, but for now, run the `PoSh-Backup.ps1` script via PowerShell; it'll ask you whether you want to create the default `User.psd1` config file - you do, so hit Y and enter. Next, open up the `Config\User.psd1` file in a text editor [Visual Studio Code](https://code.visualstudio.com/) is good for this due to its syntax highlighting) and take a look; its comments function as live documentation.
