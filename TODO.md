**PoSh-Backup Project: Development TO-DO List**

This is a copy of the master list I have and so may occasionally be slightly behind.

**Also:** Some of the features within this list is bonkers. Properly _bonkers_.

**Table of Contents**

*   [I. Core Functionality & Feature Enhancements (7-Zip & General)](#i-core-functionality--feature-enhancements-7-zip--general)
*   [II. Advanced Backup Strategies & Data Handling](#ii-advanced-backup-strategies--data-handling)
*   [III. Backup Target Providers (New & Enhancements)](#iii-backup-target-providers-new--enhancements)
*   [IV. Utility, Management & Usability Features](#iv-utility-management--usability-features)
*   [V. Reporting & Notifications](#v-reporting--notifications)
*   [VI. Code Quality, Maintainability & Testing](#vi-code-quality-maintainability--testing)
*   [VII. Security (Review & Enhancements)](#vii-security-review--enhancements)
*   [VIII. User Experience (UX) & Usability](#viii-user-experience-ux--usability)
*   [IX. Advanced Configuration & Scripting](#ix-advanced-configuration--scripting)
*   [X. Documentation & Community](#x-documentation--community)
*   [XI. Enterprise & Data Centre Grade Features](#xi-enterprise--data-centre-grade-features)
*   [XII. User Experience & Accessibility (Continued - Home User Focus)](#xii-user-experience--accessibility-continued---home-user-focus)
*   [XIII. Advanced Data Management & Integrity (Continued)](#xiii-advanced-data-management--integrity-continued)
*   [XIV. Performance & Scalability (Continued)](#xiv-performance--scalability-continued)
*   [XV. Cross-Platform & Interoperability](#xv-cross-platform--interoperability)
*   [XVI. Extensibility & Developer Experience](#xvi-extensibility--developer-experience)
*   [XVII. Advanced Recovery & Restore Capabilities](#xvii-advanced-recovery--restore-capabilities)
*   [XVIII. Enhanced Security & Compliance (Continued)](#xviii-enhanced-security--compliance-continued)
*   [XIX. Operational Efficiency & Automation (Continued)](#xix-operational-efficiency--automation-continued)
*   [XX. Cloud Native & Virtualization Focus](#xx-cloud-native--virtualization-focus)
*   [XXI. User Interface & User Experience (Beyond Home User)](#xxi-user-interface--user-experience-beyond-home-user)
*   [XXII. AI & Intelligent Operations](#xxii-ai--intelligent-operations)
*   [XXIII. Extreme Resilience & Business Continuity](#xxiii-extreme-resilience--business-continuity)
*   [XXIV. Specialised Data & Application Support (Continued)](#xxiv-specialised-data--application-support-continued)
*   [XXV. Ecosystem & Integrations (Continued)](#xxv-ecosystem--integrations-continued)
*   [XXVI. Autonomous & Self-Healing Operations](#xxvi-autonomous--self-healing-operations)
*   [XXVII. Quantum-Resistant Encryption & Future-Proofing](#xxvii-quantum-resistant-encryption--future-proofing)
*   [XXVIII. Decentralised & Trustless Backup Paradigms](#xxviii-decentralised--trustless-backup-paradigms)
*   [XXIX. Hyper-Personalisation & Context-Awareness](#xxix-hyper-personalization--context-awareness)
*   [XXX. Sustainability & Energy Efficiency](#xxx-sustainability--energy-efficiency)
*   [XXXI. Core Functionality & Reliability Enhancements](#xxxi-core-functionality--reliability-enhancements)
*   [XXXII. Backup Target Enhancements (Practical)](#xxxii-backup-target-enhancements-practical)
*   [XXXIII. Usability & Convenience (Practical)](#xxxiii-usability--convenience-practical)
*   [XXXIV. Reporting & Logging (Practical)](#xxxiv-reporting--logging-practical)
*   [XXXV. Advanced Configuration (Practical)](#xxxv-advanced-configuration-practical)
*   [XXXVI. Operational Refinements & Edge Cases](#xxxvi-operational-refinements--edge-cases)
*   [XXXVII. Reporting & Logging Enhancements (Practical)](#xxxvii-reporting--logging-enhancements-practical)
*   [XXXVIII. User Interface & CLI (Practical)](#xxxviii-user-interface--cli-practical)
*   [XXXIX. Installation & Portability](#xxxix-installation--portability)
*   [XL. Advanced Job Control & Scheduling](#xl-advanced-job-control--scheduling)
*   [XLI. Data Lifecycle Management (Beyond Basic Retention)](#xli-data-lifecycle-management-beyond-basic-retention)
*   [XLII. Security & Hardening (Continued)](#xlii-security--hardening-continued)
*   [XLIII. User Customisation & Theming (Beyond HTML Reports)](#xliii-user-customization--theming-beyond-html-reports)
*   [XLIV. Advanced Diagnostics & Troubleshooting](#xliv-advanced-diagnostics--troubleshooting)
*   [XLV. Practical Job & Configuration Management](#xlv-practical-job--configuration-management)
*   [XLVI. Practical Archive & File Handling](#xlvi-practical-archive--file-handling)
*   [XLVII. Practical Reporting & Feedback](#xlvii-practical-reporting--feedback)
*   [XLVIII. Practical Security](#xlviii-practical-security)
*   [XLIX. Enhanced User Interaction & Guidance](#xlix-enhanced-user-interaction--guidance)
*   [L. Enhanced Configuration & Setup Assistance](#l-enhanced-configuration--setup-assistance)
*   [LI. Improved Operational Feedback & Control](#li-improved-operational-feedback--control)
*   [LII. Restore & Verification Enhancements (Practical)](#lii-restore--verification-enhancements-practical)
*   [LIII. User Safety & Convenience (Practical)](#liii-user-safety--convenience-practical)
*   [LIV. Enhanced User Interaction & Guidance (Continued)](#liv-enhanced-user-interaction--guidance-continued)
*   [LV. CLI & Operational Enhancements](#lv-cli--operational-enhancements)
*   [LVI. Documentation & Developer Guidance](#lvi-documentation--developer-guidance)

---

**I. Core Functionality & Feature Enhancements (7-Zip & General)**

1. **Feature: Archive Splitting Based on Media Presets**
    - **Goal:** Simplify archive splitting for common media types.
    - **Description:** Instead of just SplitVolumeSize (e.g., "700m"), allow presets like "CD-700", "DVD-4.7G", "BluRay-25G", "FAT32-4G". The script would translate these to appropriate byte sizes for 7-Zip.
    - **Scope & Impact:** `Config\Default.psd1`, `Modules\PoShBackupValidator.psm1`, `Modules\Managers\7ZipManager.psm1` (argument builder).
    - **Acceptance Criteria:** Users can specify presets; archives are split accordingly.

4. **Enhancement: Granular Control over VSS Writers**
    - **Goal:** Allow excluding specific VSS writers during shadow copy creation.
    - **Description:** Some VSS writers can cause issues or are unnecessary for certain backups. diskshadow supports excluding writers.
    - **Scope & Impact:** `Config\Default.psd1` (job-level `VSSExcludeWriters` array), `Modules\Managers\VssManager.psm1` (modify diskshadow script generation).
    - **Acceptance Criteria:** Specified VSS writers are excluded during shadow copy creation.

7.  **Feature: 7-Zip Archive Update Modes**
    *   **Goal:** Allow different update modes when an archive with the same name already exists.
    *   **Description:** Enables scenarios like synchronisation or freshening beyond simple overwriting.
    *   **Scope & Impact:**
        *   `Config\Default.psd1`: Add job-level `ArchiveUpdateMode` (e.g., "Overwrite", "AddReplace", "Synchronise", "Freshen").
        *   `Modules\PoShBackupValidator.psm1`: Validate `ArchiveUpdateMode` values.
        *   `Modules\7ZipManager.psm1`: Map `ArchiveUpdateMode` to 7-Zip `-u` sub-switches.
        *   `Modules\Operations.psm1`: Archive naming (date stamping) needs careful consideration with this feature.
    *   **Technical Considerations:** 7-Zip `-u` switch and its sub-parameters. Best for jobs not using date stamps in archive names, or where the date stamp is part of a constant base name.
    *   **Acceptance Criteria:** 7-Zip behaves as per the configured update mode.

8.  **Feature: Memory Usage Limits for 7-Zip (If Supported)**
	* *BB: I can't seem to see a switch for this, even though the file manager supports this?*
    *   **Goal:** Allow control over 7-Zip's memory usage.
    *   **Description:** Beneficial for memory-intensive compression algorithms.
    *   **Scope & Impact:** Requires research into 7-Zip documentation for relevant switches. If found, implement in config, validator, and `7ZipManager.psm1`.
    *   **Acceptance Criteria:** (Dependent on research) 7-Zip adheres to configured memory limits.

9.  **Feature: Credential Management for Network Share Access (UNC)**
    *   **Goal:** Allow PoSh-Backup to optionally access UNC paths using specified credentials.
    *   **Description:** Enables access to shares where the executing user lacks direct permissions.
    *   **Scope & Impact:**
        *   `Config\Default.psd1`: New global/job settings for `UNCCredentialSecretName`.
        *   `Modules\PoShBackupValidator.psm1`: Schema validation.
        *   `Modules\PasswordManager.psm1` (or new `CredentialManager.psm1`): Retrieve `PSCredential`.
        *   `Modules\Operations.psm1`: Logic for `New-PSDrive -Credential` or other methods. Complex for source paths with VSS.
    *   **Technical Considerations:** `New-PSDrive -Credential`, `Remove-PSDrive`, `Copy-Item -Credential`. Security of credential objects.
    *   **Acceptance Criteria:** PoSh-Backup accesses/writes to UNC paths using specified credentials.

10. **Feature: Parallel Job Processing (Advanced)**
    *   **Goal:** Allow independent jobs within a Backup Set to run in parallel.
    *   **Description:** Potential to speed up overall backup set completion.
    *   **Scope & Impact:**
        *   `Config\Default.psd1`: Set-level `EnableParallelJobExecution` (boolean), `MaxParallelJobs` (int).
        *   `PoSh-Backup.ps1`: Major refactoring of main processing loop for PowerShell Jobs or Runspaces.
        *   Logging, resource management, and error handling become more complex.
    *   **Technical Considerations:** `Start-Job`, Runspace API.
    *   **Acceptance Criteria:** Jobs in a parallel-enabled set run concurrently; logs and status are managed correctly.

11. **Feature: Bandwidth Throttling for Remote Transfers**
    *   **Goal:** Option to limit network bandwidth for remote target transfers.
    *   **Description:** Prevents saturation of network links.
    *   **Scope & Impact:**
        *   Highly dependent on target provider capabilities.
        *   `Config\Default.psd1`: Global or per-target `MaxBandwidthKBps` (int).
        *   Target Provider Modules: Each provider implements throttling if its tools support it (e.g., Robocopy `/IPG`, SFTP client options, or manual chunking/pausing).
    *   **Acceptance Criteria:** Remote transfers adhere to configured bandwidth limits.

**II. Advanced Backup Strategies & Data Handling**

1. **Feature: Deduplication-Awareness (Integration with External Tools)**
    - **Goal:** Facilitate integration with external block-level deduplication tools.
    - **Description:** PoSh-Backup itself wouldn't do deduplication, but could have hooks or modes to prepare data for, or hand off archives to, tools like BorgBackup, Restic, or VDO (Linux) / Windows Server Deduplication (if applicable to archive storage).
    - **Scope & Impact:** **Complex.** New hook types, potentially new target provider acting as a wrapper.
    - **Acceptance Criteria:** PoSh-Backup can successfully hand off data to a configured external deduplication tool/process.

2. **Feature: Archive Cataloguing/Indexing**
    - **Goal:** Create a searchable catalog of backed-up files and their archive locations.
    - **Description:** Allows users to quickly find which archive contains a specific version of a file without mounting/extracting multiple archives.
    - **Scope & Impact:** **Large.**
        - Modules\7ZipManager.psm1: Extract file listings (7z l -slt).
        - New module: ArchiveCatalogManager.psm1 to store/query catalog (e.g., SQLite database, JSON files).
        - PoSh-Backup.ps1: CLI options to search catalog.
    - **Acceptance Criteria:** Users can search for files and identify containing archives.

4. **Feature: Incremental/Differential Backups (7-Zip Advanced)**
    *   **Goal:** Implement incremental or differential backup strategies.
    *   **Description:** Reduces backup time and storage by backing up only changes.
    *   **Scope & Impact:** **Very large feature.**
        *   `Config\Default.psd1`: Job-level settings for backup type (Full, Incremental, Differential), frequency, manifest paths.
        *   `Modules\7ZipManager.psm1`: Use 7-Zip `-u` and synchronisation features.
        *   `Modules\Operations.psm1`: Major logic for backup chains, manifests, restoration.
        *   Retention becomes significantly more complex.
    *   **Technical Considerations:** 7-Zip `-u` switch. Robust manifest/state management.
    *   **Acceptance Criteria:** Incremental/differential backups are created correctly; restoration from a chain is possible.

5. **Feature: Backup Throttling (Overall Job Level)**
    *   **Goal:** Allow throttling of the entire backup job's I/O or CPU impact.
    *   **Description:** Holistic resource control for running backups on busy systems.
    *   **Scope & Impact:**
        *   `Config\Default.psd1`: Job-level `MaxJobIOPS`, `MaxJobCpuPercentage`.
        *   `Modules\Operations.psm1`: **Complex implementation.** May involve monitoring performance counters and strategic `Start-Sleep`.
    *   **Technical Considerations:** `Get-Counter`. Reliability across diverse hardware.
    *   **Acceptance Criteria:** Overall job impact on system resources is observably reduced.

6. **Feature: Support for Backing Up to Tape (via LTO drives/libraries)**
    *   **Goal:** Enable PoSh-Backup to write archives directly to tape media.
    *   **Description:** Addresses long-term archival and offsite storage needs.
    *   **Scope & Impact:** **Very significant feature.**
        *   Requires interaction with tape hardware/software. Likely via external CLI tools (e.g., `tar`, vendor utilities, LTFS tools).
        *   New Target Provider: `Tape.Target.psm1`.
        *   `Config\Default.psd1`: Settings for tape device, labelling, append/overwrite.
        *   Tape retention is different (append-only, etc.).
    *   **Technical Considerations:** OS support, available tape tools. PowerShell has limited native tape interaction.
    *   **Acceptance Criteria:** PoSh-Backup can write an archive to a configured tape device.

7. **Feature: "Snapshot and Hold" for Application-Consistent Backups**
    *   **Goal:** Mechanism to trigger application-native quiesce/snapshot, perform backup, then release.
    *   **Description:** For applications not using VSS writers effectively. Involves user-provided scripts.
    *   **Scope & Impact:**
        *   `Config\Default.psd1`: New job-level hook types (e.g., `ApplicationQuiesceScriptPath`, `ApplicationUnquiesceScriptPath`).
        *   `Modules\Operations.psm1`: Invoke hooks around file copying/archiving.
        *   Error handling: If quiesce fails, backup should not proceed. Unquiesce must run even if backup fails.
    *   **Acceptance Criteria:** User-supplied quiesce/unquiesce scripts execute correctly, enabling application-consistent backups.

**III. Backup Target Providers (New & Enhancements)**

19. **Enhancement: SFTP/FTP - Support for Active Mode**

    - **Goal:** Add option for Active FTP/SFTP mode if passive is problematic.

    - **Description:** Some network configurations require Active mode.

    - **Scope & Impact:** Modules\Targets\SFTP.Target.psm1, Modules\Targets\FTP.Target.psm1 (when created). Config setting for active/passive.

    - **Acceptance Criteria:** Transfers work correctly in configured active mode.

20. **Feature: Backup Target Provider - Rsync (via SSH or daemon)**
    - **Goal:** Add support for transferring backups using rsync.
    - **Description:** Efficient for transferring changes, especially if archives are uncompressed or only partially changed (though 7-Zip archives are typically
    - monolithic). Could be useful for replicating a directory of archives.
    - **Scope & Impact:** New module Modules\Targets\Rsync.Target.psm1.
    - **Technical Considerations:** Requires rsync client on the PoSh-Backup machine and rsync server on the target. Handles SSH keys/passwords.
    - **Acceptance Criteria:** Archives successfully transferred using rsync.

21. **Feature: Backup Target Provider - Backblaze B2**
    - **Goal:** Support for Backblaze B2 cloud storage.
    - **Description:** Cost-effective cloud storage option.
    - **Scope & Impact:** New module Modules\Targets\B2.Target.psm1.
    - **Technical Considerations:** B2 API interaction (likely via official CLI or PowerShell module if available).
    - **Acceptance Criteria:** Archives transferred to/retained on B2.

22. **Feature: Backup Target Provider - FTP/FTPS**
    *   **Goal:** Add support for transferring backups to FTP or FTPS servers.
    *   **Description:** Complements existing UNC and SFTP providers.
    *   **Scope & Impact:**
        *   New module: `Modules\Targets\FTP.Target.psm1`.
        *   `Config\Default.psd1`: New target type "FTP" with relevant settings (server, port, user, password secret, remote path, passive mode, FTPS options).
        *   `Modules\PoShBackupValidator.psm1`: Schema validation.
    *   **Technical Considerations:** .NET `System.Net.FtpWebRequest` (manual implementation for modes, SSL/TLS, errors) or external CLI tool (e.g., `WinSCP.com`).
    *   **Acceptance Criteria:** Archives successfully transferred to/retained on FTP/FTPS server.

23. **Feature: Backup Target Provider - Cloud Storage (Generic Placeholder)**
    *   **Goal:** Add support for major cloud storage providers (e.g., Azure Blob, Google Cloud Storage; AWS S3 is already implemented).
    *   **Description:** Enables direct backup to scalable cloud object storage.
    *   **Scope & Impact:** **Large.** Likely one new provider module per cloud service.
        *   E.g., `Modules\Targets\AzureBlob.Target.psm1`.
        *   `Config\Default.psd1`: New target types with service-specific settings (account/bucket names, regions, authentication keys/roles via SecretManagement).
        *   `Modules\PoShBackupValidator.psm1`: Schema validation for each.
    *   **Technical Considerations:** Use official PowerShell SDKs/modules for each cloud provider (e.g., `Az.Storage`). Handle authentication, multipart uploads for large files, object lifecycle/retention.
    *   **Acceptance Criteria:** Archives successfully transferred to/retained on configured cloud storage.

**IV. Utility, Management & Usability Features**

1. **Feature: Configuration Import/Export (CLI Utility)**

    - **Goal:** Allow users to export their current effective configuration for a job (or globally) to a file, or import a job definition.

    - **Description:** Useful for sharing, migrating, or templating job definitions.

    - **Scope & Impact:** PoSh-Backup.ps1 (new CLI switches), Modules\Core\ConfigManager.psm1.

    - **Acceptance Criteria:** Config can be exported and re-imported (with validation).

7. **Feature: Job Execution Time Limits / Timeouts**
    *   **Goal:** Define a maximum execution time for a backup job.
    *   **Description:** Prevents runaway jobs.
    *   **Scope & Impact:**
        *   `Config\Default.psd1`: Job-level `MaxExecutionTimeMinutes`.
        *   `Modules\Operations.psm1`: Monitor elapsed time; attempt graceful termination of 7-Zip.
    *   **Technical Considerations:** Timer monitoring. Safely terminating `7z.exe`.
    *   **Acceptance Criteria:** Jobs exceeding time limits are terminated and reported as timed-out.

8. **Feature: Pre-Flight Checks / Enhanced Dry Run Mode**
    *   **Goal:** Expand `-TestConfig` or create `-PreFlightCheck` for more comprehensive pre-run validation.
    *   **Description:** Verify source/destination accessibility, remote target connectivity/auth, estimate backup size.
    *   **Scope & Impact:**
        *   `PoSh-Backup.ps1`: New CLI switch.
        *   Various modules (`Operations.psm1`, target providers) need specific pre-flight check logic.
    *   **Acceptance Criteria:** Pre-flight check provides a report of potential issues.

**V. Reporting & Notifications**

30. **Enhancement: HTML Report - Add "Copy to Clipboard" for Configuration Sections**

    - **Goal:** Allow easy copying of displayed configuration settings from the HTML report.

    - **Description:** Similar to the existing "Copy Hook Output" button.

    - **Scope & Impact:** Modules\Reporting\Assets\ReportingHtml.Client.js, Modules\Reporting\ReportingHtml.psm1 (to structure config table appropriately).

    - **Acceptance Criteria:** Users can copy configuration key-value pairs.

32. **Enhancement: HTML Report - Visual Diff for Configuration Changes (Advanced)**

    - **Goal:** If a job's configuration changes between runs, highlight these changes in the HTML report's configuration section.

    - **Description:** Helps track what configuration was active for a specific historical backup.

    - **Scope & Impact:** **Complex.** Requires storing/comparing previous job configurations. Modules\Reporting\ReportingHtml.psm1.

    - **Acceptance Criteria:** HTML report visually indicates config changes from a previous run (if data available).

34. **Enhancement: Pre/Post Backup Script Output in HTML Report**
    *   **Goal:** Improve clarity of hook script output in HTML reports.
    *   **Description:** Delineate STDOUT and STDERR more clearly.
    *   **Scope & Impact:**
        *   `Modules\HookManager.psm1`: Capture STDOUT/STDERR separately.
        *   `Modules\Reporting\ReportingHtml.psm1`: Update HTML to display distinct STDOUT/STDERR.
    *   **Acceptance Criteria:** HTML report shows separate STDOUT/STDERR for hook outputs.

35. **Enhancement: Progress Indication for Long 7-Zip Operations (When Hidden)**
    *   **Goal:** Provide console progress feedback even when `HideSevenZipOutput` is `$true`.
    *   **Description:** For large archives, script can appear to hang.
    *   **Scope & Impact:** `Modules\7ZipManager.psm1`: **Major complexity.** Asynchronous STDOUT reading, parsing progress.
    *   **Technical Considerations:** `System.Diagnostics.Process` `OutputDataReceived` event. Regex for 7-Zip progress. User noted previous attempt was problematic.
    *   **Acceptance Criteria:** Console shows periodic progress updates for hidden 7-Zip operations.

38. **Feature: Customisable Report Templates (Advanced HTML)**
    *   **Goal:** Allow users to provide their own HTML template files for reports.
    *   **Description:** For complete control over HTML report structure.
    *   **Scope & Impact:**
        *   `Modules\Reporting\ReportingHtml.psm1`: **Major refactoring** to use a templating engine.
        *   `Config\Default.psd1`: Setting for custom HTML template path.
    *   **Acceptance Criteria:** Report generated using user-provided HTML template.

39. **Enhancement: Summary Report for Backup Sets**
    *   **Goal:** Generate an overall summary report when a Backup Set is run.
    *   **Description:** Currently, reports are per-job. A set-level report would summarise the status of all jobs within the set, total time, total data backed up (if feasible to aggregate), etc.
    *   **Scope & Impact:**
        *   `PoSh-Backup.ps1`: Collect aggregate data during set execution.
        *   `Modules\Reporting.psm1`: New function `Invoke-SetReportGenerator` or extend `Invoke-ReportGenerator`.
        *   Reporting sub-modules: Adapt to handle set-level summary data.
    *   **Acceptance Criteria:** A summary report is generated for a completed backup set.

**VI. Code Quality, Maintainability & Testing**

1. **Task: Static Code Analysis Integration (Beyond PSScriptAnalyzer)**

    - **Goal:** Integrate additional static analysis tools if beneficial.

    - **Description:** Tools that might catch different types of issues or enforce stricter style guides.

    - **Scope & Impact:** Research tools. Integrate into development/CI workflow.

    - **Acceptance Criteria:** Additional analysis performed; issues addressed.

2. **Task: Performance Profiling and Optimisation**

    - **Goal:** Identify and address performance bottlenecks in PoSh-Backup's own logic (not 7-Zip itself).

    - **Description:** Especially for large configurations, many jobs, or complex reporting.

    - **Scope & Impact:** Use Measure-Command, PowerShell profiler. Refactor critical code paths.

    - **Acceptance Criteria:** Measurable performance improvements in identified bottlenecks.

3. **Task: Implement Comprehensive Pester Tests**
    *   **Goal:** Create a robust suite of Pester tests.
    *   **Description:** Vital for stability, regression prevention, refactoring. Currently non-functional.
    *   **Scope & Impact:** New `Tests/` structure. Unit and Integration tests. Mocking.
    *   **Technical Considerations:** Pester framework, `Mock` command.
    *   **Acceptance Criteria:** Comprehensive Pester test suite passes and covers key functionalities.

4. **Task: Create PowerShell Module Manifests**
    *   **Goal:** Create `.psd1` manifest files for each `.psm1` module.
    *   **Description:** Improves versioning, explicit exports, metadata.
    *   **Scope & Impact:** Create manifests for all modules. Update `Import-Module` calls if needed.
    *   **Technical Considerations:** `New-ModuleManifest`.
    *   **Acceptance Criteria:** Each module has a manifest; modules load correctly.

5. **Task: Enhance Comment-Based Help for All Exported Module Functions**
    *   **Goal:** Ensure comprehensive comment-based help for all exported functions.
    *   **Description:** Improves usability and maintainability.
    *   **Scope & Impact:** Review all `.psm1` files; add/update help blocks.
    *   **Acceptance Criteria:** `Get-Help` displays complete, accurate help for all exported functions.

6. **Task: Review and Refine Error Handling in Modules**
    *   **Goal:** Ensure consistent, robust, informative error handling.
    *   **Description:** Catch specific exceptions, log meaningfully, `throw` critical errors.
    *   **Scope & Impact:** Systematic review of `try/catch` in all `.psm1` files.
    *   **Acceptance Criteria:** Errors handled gracefully; logs provide clear diagnostics.

**VII. Security (Review & Enhancements)**

1. **Feature: Read-Only Mode for Configuration Files**

    - **Goal:** Option to load configuration in a strictly read-only mode, preventing any accidental modification by PoSh-Backup itself (e.g., if a bug existed in a future auto-config-update feature).

    - **Description:** Safety measure.

    - **Scope & Impact:** Modules\ConfigManagement\ConfigLoader.psm1.

    - **Acceptance Criteria:** Config data is treated as immutable by the script if this mode is active.

2. **Enhancement: More Granular Permissions for apply_update.ps1**

    - **Goal:** Ensure apply_update.ps1 operates with the least privilege necessary.

    - **Description:** Review if all its actions truly require full admin, or if specific parts can be done with user-level permissions after initial elevation for specific tasks. (This is complex due to file system ACLs in Program Files, etc.).

    - **Scope & Impact:** Meta\apply_update.ps1.

    - **Acceptance Criteria:** Update process is as secure as possible regarding permissions.

3. **Feature: Encryption of Configuration File Sections (Advanced)**
    *   **Goal:** Allow encryption of sensitive parts of the configuration file.
    *   **Description:** Additional security for configuration at rest (e.g., API keys if not using SecretManagement).
    *   **Scope & Impact:** **Very complex.**
        *   `Modules\ConfigManager.psm1`: Detect/decrypt sections using a master key or user key.
        *   Utility for users to encrypt sections.
    *   **Technical Considerations:** `Protect-CmsMessage` / `Unprotect-CmsMessage`. Secure key management.
    *   **Acceptance Criteria:** Sensitive config sections can be stored encrypted and are decrypted at runtime.

4. **Feature: Immutable Backup Target Option (WORM-like)**
    *   **Goal:** Configure backups to be immutable for a period on supporting targets.
    *   **Description:** Protects against accidental deletion or ransomware.
    *   **Scope & Impact:** Highly dependent on target provider capabilities (e.g., S3 Object Lock).
        *   `Config\Default.psd1`: New settings for immutability in `TargetSpecificSettings` or `RemoteRetentionSettings`.
        *   Target Provider Modules: Implement logic to set immutability.
    *   **Acceptance Criteria:** Backups on supporting targets are made immutable as configured.

5. **Feature: Validate SSL/TLS Certificates for Remote Targets**
    *   **Goal:** Proper SSL/TLS certificate validation for FTPS, WebDAV, HTTPS-based targets.
    *   **Description:** Prevents man-in-the-middle attacks. Default should be to validate.
    *   **Scope & Impact:**
        *   Target Provider Modules: Ensure `ServerCertificateValidationCallback` is handled or default validation occurs.
        *   `Config\Default.psd1`: Options like `SkipCertificateCheck` (bool, default `$false`), `ExpectedCertificateThumbprint` (string).
    *   **Acceptance Criteria:** SSL/TLS connections are secure by default; options exist for specific scenarios with warnings.

**VIII. User Experience (UX) & Usability**

1. **Enhancement: Write-ConsoleBanner - Support for Multi-Line Value Text**

    - **Goal:** Allow the ValueText in Write-ConsoleBanner to span multiple lines gracefully within the banner.

    - **Description:** For longer version strings or more descriptive banner values.

    - **Scope & Impact:** Modules\Utilities\ConsoleDisplayUtils.psm1.

    - **Acceptance Criteria:** Multi-line value text is formatted correctly within the banner.

2. **Feature: Job Output Verbosity Control (Beyond Global Logging Levels)**

    - **Goal:** Allow users to set a "verbosity" for a specific job's console output during its run, independent of the overall script log level.

    - **Description:** E.g., run one critical job with -JobVerbosity Detailed while others run quietly.

    - **Scope & Impact:** Config\Default.psd1 (job-level ConsoleVerbosity), PoSh-Backup.ps1 (CLI override), Modules\Core\JobOrchestrator.psm1 (to respect this when calling Write-LogMessage or similar for job-specific console feedback).

    - **Acceptance Criteria:** Job console output reflects the configured verbosity.

3. **Enhancement: Interactive Configuration Setup/Guidance**
    *   **Goal:** Provide a guided setup or interactive mode for creating initial job configurations.
    *   **Description:** Lowers barrier to entry for new users.
    *   **Scope & Impact:**
        *   `PoSh-Backup.ps1`: New CLI switch (e.g., `-SetupInteractive`).
        *   New module/functions for interactive Q&A. Logic to update `User.psd1`.
    *   **Acceptance Criteria:** New user can use interactive setup to create a valid job definition.

4. **Enhancement: Improved `-TestConfig` Output**
    *   **Goal:** Make `-TestConfig` output more user-friendly and informative.
    *   **Description:** Structure output better, highlight potential issues, offer suggestions.
    *   **Scope & Impact:** `PoSh-Backup.ps1`: Refactor `-TestConfig` block.
    *   **Acceptance Criteria:** `-TestConfig` output is easier to read and provides more actionable insights.

5. **Enhancement: Internationalisation (I18N) / Localisation (L10N) Support**
    *   **Goal:** Prepare script for potential translation of messages and report text.
    *   **Description:** For non-English speaking users. **Very large undertaking.**
    *   **Scope & Impact:** Externalise all user-facing strings. Logic in `Utils.psm1` and reporting modules to load language strings.
    *   **Acceptance Criteria (Initial):** Key messages externalised; mechanism for loading language strings in place.

6. **Feature: Read-Only Mode for Specific Operations**
    *   **Goal:** Introduce a "read-only" mode for tasks like listing/testing archives.
    *   **Description:** Safety feature to prevent accidental writes/deletes during inspection.
    *   **Scope & Impact:**
        *   `PoSh-Backup.ps1`: New CLI switches implying read-only.
        *   Relevant modules: Respect a global "read-only" flag, bypassing write/delete operations.
    *   **Acceptance Criteria:** Read-only operations perform no write/delete actions.

**IX. Advanced Configuration & Scripting**

1. **Feature: Dynamic Variables in Configuration Strings**
    - **Goal:** Allow certain configuration string values to contain dynamic variables that PoSh-Backup resolves at runtime (e.g., environment variables, date/time stamps).
    - **Description:** E.g., DestinationDir = "D:\Backups\%USERNAME%\%COMPUTERNAME%" or ArchiveName = "JobA_$(Get-Date -Format yyyyMMdd)".
    - **Scope & Impact:** **Security implications.** Modules\ConfigManagement\EffectiveConfigBuilder.psm1 would need to safely parse and expand these. Strict control over what can be expanded.
    - **Acceptance Criteria:** Defined variables in config strings are correctly expanded at runtime.

2. **Feature: Support for PowerShell Classes for Custom Target Providers/Hooks**
    - **Goal:** Allow advanced users to develop custom target providers or complex hooks using PowerShell classes instead of just scripts.
    - **Description:** Enables more structured, object-oriented custom extensions.
    - **Scope & Impact:** Modules\Operations\RemoteTransferOrchestrator.psm1, Modules\Managers\HookManager.psm1 would need to detect and instantiate/call class methods.
    - **Acceptance Criteria:** Class-based custom providers/hooks can be loaded and executed.

3. **Feature: Centralised Configuration Management / Override Hierarchy**
    *   **Goal:** Allow sophisticated configuration layering (machine, user, environment-specific).
    *   **Description:** For enterprise deployment and varied user profiles.
    *   **Scope & Impact:**
        *   `Modules\ConfigManager.psm1`: Refactor to load/merge multiple config files by hierarchy/convention.
        *   `PoSh-Backup.ps1`: Logic to find override files.
        *   Documentation: Explain override order.
    *   **Acceptance Criteria:** Configurations are layered; overrides applied correctly.

4. **Feature: "Backup Profile" Support (CLI Selectable)**
    *   **Goal:** Define and select "profiles" via CLI, loading specific configurations.
    *   **Description:** E.g., `PoSh-Backup.ps1 -Profile "WorkstationDaily"`.
    *   **Scope & Impact:**
        *   `PoSh-Backup.ps1`: New CLI parameter `-Profile <ProfileName>`.
        *   `Modules\ConfigManager.psm1`: Load configs based on profile (e.g., `Config\Profiles\<ProfileName>\User.psd1`).
    *   **Acceptance Criteria:** Specified profile's configuration is loaded.

5. **Feature: Conditional Job Execution within Sets**
    *   **Goal:** Allow jobs within a Backup Set to execute conditionally based on previous job outcomes.
    *   **Description:** More granular control than set-level `OnErrorInJob`. E.g., "Run JobC only if JobA succeeded AND JobB failed."
    *   **Scope & Impact:**
        *   `Config\Default.psd1`: Complex new syntax in `BackupSets` for conditions.
        *   `PoSh-Backup.ps1`: Major refactoring of set processing logic.
    *   **Acceptance Criteria:** Jobs in a set execute based on defined conditional logic.

6. **Feature: Global Variable Injection for Hook Scripts**
    *   **Goal:** Allow defining custom global variables in config, passed to hook scripts.
    *   **Description:** Pass common settings/data to all hook scripts without hardcoding.
    *   **Scope & Impact:**
        *   `Config\Default.psd1`: New global `HookScriptGlobalVariables` (hashtable).
        *   `Modules\HookManager.psm1`: Inject variables into hook script process scope.
    *   **Acceptance Criteria:** Custom global variables are accessible within hook scripts.

**X. Documentation & Community**

1. **Task: Create "Quick Start" Guide / Tutorial**
    - **Goal:** A very simple, step-by-step guide for absolute beginners to get their first backup job running.
    - **Description:** Complements the more detailed README.
    - **Scope & Impact:** New documentation file (e.g., QUICK_START.md).
    - **Acceptance Criteria:** A new user can follow the quick start to run a basic backup.

2. **Task: Document Schema for TargetSpecificSettings for Each Provider**
    - **Goal:** Clearly document the expected TargetSpecificSettings hashtable structure for each target provider (UNC, SFTP, WebDAV, etc.) within the README or provider-specific docs.
    - **Description:** Helps users configure targets correctly. Currently, this is mostly in Default.psd1 examples or the provider's validation function.
    - **Scope & Impact:** Update README.md or create separate docs for each target provider.
    - **Acceptance Criteria:** Clear documentation for each target provider's specific settings.

3. **Task: Create a `CONTRIBUTING.md` Guide**
    *   **Goal:** Provide guidelines for community contributions.
    *   **Description:** How to report bugs, suggest features, coding standards, pull request process.
    *   **Scope & Impact:** New `CONTRIBUTING.md` file in project root.
    *   **Acceptance Criteria:** Clear contribution guidelines are available.

4. **Task: Set up a GitHub Pages Site for Documentation (or similar)**
    *   **Goal:** Host user-friendly documentation beyond the README.
    *   **Description:** Could include tutorials, detailed configuration guides, FAQ.
    *   **Scope & Impact:** Requires setting up GitHub Pages (or other static site generator) and writing content.
    *   **Acceptance Criteria:** Publicly accessible documentation site exists.

5. **Task: Example `User.psd1` Configurations**
    *   **Goal:** Provide a collection of example `User.psd1` files for common scenarios.
    *   **Description:** Helps new users get started quickly (e.g., simple document backup, server application backup, backup to multiple targets).
    *   **Scope & Impact:** Create a new `Config\Examples\` directory with sample `User.psd1` files.
    *   **Acceptance Criteria:** Several well-commented example configurations are available.


**XI. Enterprise & Data Centre Grade Features**

57. **Feature: Central Management Server & Dashboard**
    *   **Goal:** Provide a centralised web-based or application console for managing and monitoring multiple PoSh-Backup instances/clients and backup jobs across an enterprise.
    *   **Description:** View job status, history, storage utilization, client health, and remotely configure/trigger jobs.
    *   **Scope & Impact:** **Massive.** Requires a server-side component, database, agent communication protocol, web UI.
    *   **Acceptance Criteria:** Admins can manage and monitor their PoSh-Backup estate from a central console.

58. **Feature: Role-Based Access Control (RBAC) for Management**
    *   **Goal:** Implement granular permissions for accessing PoSh-Backup features and managing jobs/configurations.
    *   **Description:** E.g., Backup Operators, Restore Operators, View-Only Admins, Tenant Admins (for multi-tenancy).
    *   **Scope & Impact:** Tied to Central Management Server. Requires identity management integration (e.g., Active Directory, OAuth).
    *   **Acceptance Criteria:** Access to PoSh-Backup functionalities is controlled by defined roles and permissions.

59. **Feature: REST API for Programmatic Control & Integration**
    *   **Goal:** Expose PoSh-Backup functionalities via a REST API.
    *   **Description:** Enable automation, integration with orchestration tools, custom dashboards, and third-party applications.
    *   **Scope & Impact:** Server-side component for API hosting. Secure API authentication.
    *   **Acceptance Criteria:** Documented API endpoints allow for managing and monitoring backups programmatically.

60. **Feature: Automated Client Deployment & Configuration Management**
    *   **Goal:** Streamline deployment and configuration of PoSh-Backup clients/instances across many machines.
    *   **Description:** Use tools like PowerShell DSC, Ansible, SCCM, or a custom agent to push PoSh-Backup and its configurations.
    *   **Scope & Impact:** Integration with deployment tools. Central configuration repository.
    *   **Acceptance Criteria:** PoSh-Backup can be deployed and configured at scale with automation.

61. **Feature: Global Deduplication (Storage Backend Integration)**
    *   **Goal:** Integrate with or provide a storage backend that supports global source-side or target-side deduplication.
    *   **Description:** Significantly reduce storage footprint across all backups.
    *   **Scope & Impact:** **Huge.** Could involve integrating with existing deduplicating storage appliances/software (e.g., Dell PowerProtect DD, Veritas NetBackup MSDP) or building/integrating a custom solution (e.g., using content-defined chunking libraries).
    *   **Acceptance Criteria:** Measurable reduction in overall backup storage due to deduplication.

62. **Feature: Synthetic Full Backups**
    *   **Goal:** Create synthetic full backups from existing full and incremental/differential backups on the backup target.
    *   **Description:** Reduces backup window for full backups on the source system. Requires target-side processing capabilities.
    *   **Scope & Impact:** **Complex.** Requires intelligent target providers or a dedicated backup server component. Deep integration with incremental/differential logic.
    *   **Acceptance Criteria:** Synthetic fulls can be created and are valid for restore.

63. **Feature: Storage Tiering (Integration with Target Capabilities)**
    *   **Goal:** Automatically move older backups to cheaper/slower storage tiers (e.g., S3 Standard to Glacier Deep Archive, on-prem fast disk to slower NAS/tape).
    *   **Description:** Optimise storage costs based on data lifecycle policies.
    *   **Scope & Impact:** Target providers need to expose tiering capabilities. Policy engine in PoSh-Backup.
    *   **Acceptance Criteria:** Backups are moved between storage tiers according to defined policies.

64. **Feature: Immutable Backup Storage (WORM) Enhancements**
    *   **Goal:** Expand on existing WORM idea to include more target types and robust management.
    *   **Description:** Ensure compliance with regulations requiring immutable storage. Support for S3 Object Lock, Azure Immutable Blob, and potentially on-prem solutions with WORM capabilities.
    *   **Scope & Impact:** Target provider enhancements. Configuration for immutability periods, legal holds.
    *   **Acceptance Criteria:** Backups are verifiably immutable on supported targets.

65. **Feature: Bare Metal Recovery (BMR) Assistance / System State**
    *   **Goal:** While PoSh-Backup is file-focused, provide hooks or integration points to assist with BMR.
    *   **Description:** Could involve backing up critical system state components (e.g., boot configuration, registry hives if VSS allows) or integrating with tools like Windows Server Backup or third-party BMR solutions.
    *   **Scope & Impact:** Careful selection of what to include. May require very high privileges.
    *   **Acceptance Criteria:** PoSh-Backup can capture defined system state elements to aid in BMR.

66. **Feature: SAN/NAS Storage Snapshot Orchestration**
    *   **Goal:** Integrate with storage array snapshot capabilities.
    *   **Description:** Trigger array-level snapshots before VSS/file backup for near-instant application-consistent data capture, then back up from the array snapshot.
    *   **Scope & Impact:** **Complex.** New target/orchestration modules for specific storage vendor APIs (NetApp, Dell, HPE, etc.).
    *   **Acceptance Criteria:** PoSh-Backup can orchestrate storage array snapshots as part of a backup job.

67. **Feature: Multi-Tenancy Support**
    *   **Goal:** Allow a single PoSh-Backup management infrastructure to serve multiple isolated tenants (e.g., for MSPs).
    *   **Description:** Tenants have their own configurations, jobs, users, and view of their backups, isolated from others.
    *   **Scope & Impact:** Major architectural changes to Central Management Server, RBAC, configuration storage.
    *   **Acceptance Criteria:** Multiple tenants can use the system securely and in isolation.

68. **Feature: Geographic Replication & Disaster Recovery (DR) Orchestration**
    *   **Goal:** Manage replication of backup data between geographically separate sites or regions for DR purposes.
    *   **Description:** Automated replication of backup target data, with failover/failback considerations.
    *   **Scope & Impact:** Integration with target provider replication features (e.g., S3 Cross-Region Replication) or custom replication logic. DR runbook automation hooks.
    *   **Acceptance Criteria:** Backup data is replicated to DR site(s); DR testing/failover can be orchestrated.

69. **Feature: Advanced Auditing & Compliance Reporting**
    *   **Goal:** Generate detailed audit logs and reports for compliance purposes (e.g., GDPR, HIPAA, SOX).
    *   **Description:** Track all administrative actions, configuration changes, backup/restore operations, data access, retention policy enforcement. Immutable audit logs.
    *   **Scope & Impact:** Secure audit logging mechanism. Reporting engine for compliance templates.
    *   **Acceptance Criteria:** Comprehensive, tamper-evident audit trails and compliance reports are generated.

70. **Feature: Key Management Service (KMS) Integration**
    *   **Goal:** Integrate with enterprise KMS (e.g., HashiCorp Vault, Azure Key Vault, AWS KMS) for managing encryption keys.
    *   **Description:** Centralised and secure management of keys used for archive encryption or configuration encryption.
    *   **Scope & Impact:** `Modules\PasswordManager.psm1` (or new `KeyManager.psm1`). API integration with KMS providers.
    *   **Acceptance Criteria:** Encryption keys are managed through an external KMS.

71. **Feature: Self-Service Restore Portal for End-Users**
    *   **Goal:** Allow end-users (with appropriate permissions) to browse and restore their own files from backups.
    *   **Description:** Reduces load on backup administrators for common restore requests.
    *   **Scope & Impact:** Web UI component, integration with archive catalog, RBAC.
    *   **Acceptance Criteria:** Authorised users can perform self-service restores.

72. **Feature: Policy-Based Backup Management**
    *   **Goal:** Define backup policies (RPO, RTO, retention, target type, frequency) and apply them to groups of clients or data types.
    *   **Description:** Simplifies management in large environments by abstracting individual job configurations.
    *   **Scope & Impact:** Central Management Server. Policy engine.
    *   **Acceptance Criteria:** Backups are governed by centrally defined policies.

73. **Feature: Chargeback/Showback Reporting**
    *   **Goal:** Generate reports on backup resource consumption (storage, network, licenses if any) per department, tenant, or application.
    *   **Description:** For internal cost allocation or billing in MSP scenarios.
    *   **Scope & Impact:** Data collection from jobs and targets. Reporting engine.
    *   **Acceptance Criteria:** Resource consumption reports can be generated for defined entities.

74. **Enhancement: Support for Very Large Filesystems & Petabyte-Scale Data**
    *   **Goal:** Ensure PoSh-Backup can efficiently handle scanning and backing up extremely large file systems and datasets.
    *   **Description:** Optimizations in file enumeration, VSS handling for massive volumes, 7-Zip performance for huge archives, robust multi-volume splitting and management.
    *   **Scope & Impact:** Performance profiling and optimization across many modules.
    *   **Acceptance Criteria:** PoSh-Backup performs reliably and efficiently with terabyte/petabyte-scale sources.

75. **Feature: Application-Specific Backup & Restore Modules (Deep Integration)**
    *   **Goal:** Provide specialised modules for deeply integrated backup and restore of enterprise applications (e.g., SQL Server, Exchange, Oracle, SAP HANA).
    *   **Description:** Beyond simple VSS snapshots. Involves understanding application-specific backup APIs, log truncation, point-in-time recovery, granular restore (e.g., individual mailboxes/tables).
    *   **Scope & Impact:** **Massive.** Requires expert knowledge for each application. New set of "Application Provider" modules.
    *   **Acceptance Criteria:** Application-consistent backups with granular restore capabilities for supported applications.


**XII. User Experience & Accessibility (Continued - Home User Focus)**

76. **Feature: Simplified "One-Click" Backup Profile for Common User Folders**
    *   **Goal:** Provide an extremely simple way for non-technical home users to back up standard folders (Documents, Pictures, Desktop, etc.).
    *   **Description:** A pre-defined profile or a very simple GUI/CLI wizard that sets up a job to back up common user data to an external drive or a simple cloud target with sensible defaults.
    *   **Scope & Impact:** `PoSh-Backup.ps1` (new simplified mode/switch), `Config\Default.psd1` (pre-defined "HomeUserSimple" profile), potentially a minimal GUI wrapper.
    *   **Acceptance Criteria:** Home user can initiate a backup of their key folders with minimal configuration.

77. **Feature: "What Changed?" Report for Incremental/Differential Backups (User-Friendly)**
    *   **Goal:** For home users using incremental/differential backups, provide a simple report showing which files were added/changed in the latest backup.
    *   **Description:** Helps users understand what the backup actually did.
    *   **Scope & Impact:** Reporting modules, logic to parse 7-Zip `-u` output or compare manifests.
    *   **Acceptance Criteria:** A clear, concise list of changed files is available in reports.

78. **Feature: Integrated Restore Wizard (GUI or Enhanced CLI)**
    *   **Goal:** Simplify the process of restoring files for less technical users.
    *   **Description:** A guided process (CLI or simple GUI) to browse backups (perhaps using the archive catalog feature), select files/folders, and choose a restore location.
    *   **Scope & Impact:** New module for restore UI/logic, integration with archive listing and extraction.
    *   **Acceptance Criteria:** Users can easily find and restore their files.

79. **Feature: Automatic External Drive Detection & Backup Trigger**
    *   **Goal:** For home users, automatically trigger a specific backup job when a designated external backup drive is connected.
    *   **Description:** "Plug and Play" backup for external HDDs/SSDs.
    *   **Scope & Impact:** Background agent/service or scheduled task that monitors for drive connections (e.g., WMI events). Logic to match drive (e.g., by volume label or serial) to a job.
    *   **Acceptance Criteria:** Connecting a specific external drive automatically starts the associated backup job.

**XIII. Advanced Data Management & Integrity (Continued)**

81. **Feature: End-to-End Encryption (Client-Side Encryption Before Transfer)**
    *   **Goal:** Ensure data is encrypted *before* it leaves the client machine, even if the target provider also offers encryption (defense in depth).
    *   **Description:** The 7-Zip archive itself is encrypted with a user-provided password/key. This feature focuses on ensuring that if a target provider doesn't inherently encrypt the data *in transit* or *at rest* in a way the user trusts, PoSh-Backup has already secured it.
    *   **Scope & Impact:** This is largely covered by 7-Zip's password protection. The key is ensuring robust password management (`PasswordManager.psm1`) and clear documentation on how this provides client-side encryption. For targets like plain FTP, this is crucial.
    *   **Acceptance Criteria:** Data within the 7-Zip archive is encrypted locally before transfer to any target.

82. **Feature: Data Integrity Scrubbing / Proactive Verification**
    *   **Goal:** Periodically and automatically verify the integrity of existing backup archives (local and remote) even if not explicitly part of a restore or new backup.
    *   **Description:** Detects silent data corruption / bit rot over time.
    *   **Scope & Impact:** New scheduling mechanism (or tie into verification jobs). Logic to iterate through archives, perform tests (7z t, checksum verification). Reporting on findings.
    *   **Acceptance Criteria:** System can proactively scan and verify stored archives, reporting any integrity issues.

83. **Feature: Configurable Data Compression per Source/File Type**
    *   **Goal:** Allow different 7-Zip compression settings for different types of files within the *same* backup job.
    *   **Description:** E.g., use "Store" (no compression) for already compressed files like JPEGs/MP3s, but "Ultra" for documents.
    *   **Scope & Impact:** **Very complex for 7-Zip CLI.** 7-Zip typically applies settings to the whole archive operation. Might require multiple 7-Zip passes and then combining archives, or advanced use of list files with per-file parameters if 7-Zip supports it (unlikely for compression level).
    *   **Acceptance Criteria:** Different file types within a job are compressed with different settings.

84. **Feature: Backup Data Immutability on Local Filesystems (Advanced)**
    *   **Goal:** Provide options to make local backup files harder to delete/modify, even by an administrator, for a defined period.
    *   **Description:** Using filesystem ACLs, potentially special attributes (like `FILE_ATTRIBUTE_READONLY` combined with `Set-ItemProperty -Name IsReadOnly $true`), or even integrating with specialised file system filter drivers if going very deep. This is distinct from target-based immutability.
    *   **Scope & Impact:** **Complex and OS-dependent.** High risk if not implemented carefully.
    *   **Acceptance Criteria:** Local backup files have increased resistance to accidental/malicious modification/deletion.

**XIV. Performance & Scalability (Continued)**

85. **Feature: Intelligent Source Path Throttling for VSS**
    *   **Goal:** When using VSS on multiple volumes simultaneously, intelligently queue or limit concurrent VSS operations if system load becomes too high.
    *   **Description:** Prevents VSS from overwhelming I/O on very busy systems with many volumes.
    *   **Scope & Impact:** `Modules\Managers\VssManager.psm1`. Requires monitoring system I/O or VSS-specific counters.
    *   **Acceptance Criteria:** VSS operations are throttled under high load to maintain system stability.

86. **Feature: Asynchronous Remote Target Transfers (within a single job)**
    *   **Goal:** If a job has multiple remote targets, allow transfers to these targets to occur in parallel after the local archive is created.
    *   **Description:** Speeds up offloading the local archive to multiple destinations.
    *   **Scope & Impact:** `Modules\Operations\RemoteTransferOrchestrator.psm1`. Use PowerShell Jobs or Runspaces for parallel transfers. Complex error/status aggregation.
    *   **Acceptance Criteria:** Transfers to multiple remote targets for a single job occur concurrently.

87. **Feature: 7-Zip Solid Archive Rebuild/Update Optimisation**
    *   **Goal:** If using solid archives and only a few files change, investigate if 7-Zip has mechanisms to update the solid archive more efficiently than a full rebuild.
    *   **Description:** Solid archives compress better but are slow to update if any part changes.
    *   **Scope & Impact:** Deep research into 7-Zip capabilities. May not be feasible with CLI alone.
    *   **Acceptance Criteria:** Updates to solid archives are faster if only minor content changes.

**XV. Cross-Platform & Interoperability**

88. **Feature: Enhanced PowerShell Core / Cross-Platform Compatibility**
    *   **Goal:** Ensure PoSh-Backup runs as seamlessly as possible on PowerShell Core (Windows, Linux, macOS).
    *   **Description:** Review all OS-specific calls (e.g., VSS, `rundll32.exe` for system actions, drive letter assumptions). Provide alternative implementations or clear "not supported on this platform" messages.
    *   **Scope & Impact:** Review all modules. Conditional logic based on `$IsWindows`, `$IsLinux`, `$IsMacOS`.
    *   **Acceptance Criteria:** Core backup/restore functionality (especially for non-VSS, non-Windows-specific actions) works on Linux/macOS. Windows-specific features are gracefully handled.

89. **Feature: Standardised Archive Format Options (beyond 7-Zip native)**
    *   **Goal:** Option to output in more universally standard formats like TAR.GZ or plain ZIP (using 7-Zip's capabilities) for easier interoperability with non-Windows systems or tools that don't have 7-Zip.
    *   **Description:** While 7-Zip can create these, make it an explicit, easy choice in config.
    *   **Scope & Impact:** `Config\Default.psd1` (e.g., `OutputArchiveStandardFormat = "TAR.GZ"`), `Modules\Managers\7ZipManager.psm1` (adjust `-t` switch).
    *   **Acceptance Criteria:** User can configure output in standard TAR.GZ or ZIP.

90. **Feature: Backup Manifests in a Standard Format (e.g., JSON, XML)**
    *   **Goal:** In addition to any proprietary manifest, output a manifest of backed-up files in a standard, easily parsable format.
    *   **Description:** Useful for external auditing tools or custom scripting.
    *   **Scope & Impact:** `Modules\Operations\LocalArchiveProcessor.psm1`.
    *   **Acceptance Criteria:** A JSON or XML manifest listing files, sizes, timestamps is generated alongside the archive.

**XVI. Extensibility & Developer Experience**

91. **Feature: Well-Defined Plugin Architecture for Target Providers & Hooks**
    *   **Goal:** Formalise the interface for creating new target providers and hook scripts.
    *   **Description:** Provide base classes or PowerShell modules with defined functions/parameters that developers must implement. Include clear documentation and examples.
    *   **Scope & Impact:** Developer documentation. Potentially helper modules for plugin creation.
    *   **Acceptance Criteria:** Developers have a clear, documented process for extending PoSh-Backup.

92. **Feature: Developer Mode / Enhanced Debugging Output**
    *   **Goal:** Provide a mode with extremely verbose, developer-focused logging and diagnostics.
    *   **Description:** More detailed than standard "DEBUG" level. Might include internal state dumps, performance timings for specific functions.
    *   **Scope & Impact:** `PoSh-Backup.ps1` (CLI switch), enhanced logging calls throughout the codebase.
    *   **Acceptance Criteria:** Developer mode provides deep insights into script execution.

---

**XVII. Advanced Recovery & Restore Capabilities**

93. **Feature: Granular Restore from Application-Aware Backups (Expansion)**
    *   **Goal:** For applications where deep integration is added (e.g., SQL, Exchange), provide tools/CLI options for granular restores (single database, table, mailbox, item).
    *   **Description:** Moves beyond just restoring the raw backup files for these specific applications.
    *   **Scope & Impact:** Requires significant development within each application-specific provider module.
    *   **Acceptance Criteria:** Users can perform granular restores for supported applications.

94. **Feature: Point-in-Time Recovery (PITR) Orchestration**
    *   **Goal:** Orchestrate restores to a specific point in time, especially for databases or systems with continuous data protection or frequent log backups.
    *   **Description:** Involves restoring a full backup, then applying subsequent differential/incremental backups and transaction logs up to the desired moment.
    *   **Scope & Impact:** **Very Complex.** Deep integration with incremental/differential backup logic, log management, and application-specific restore commands.
    *   **Acceptance Criteria:** System can be restored to a user-specified point in time.

95. **Feature: "Instant Access" / "Live Mount" of Backups**
    *   **Goal:** Allow mounting a backup archive (especially VM or database backups) as a live, browsable volume or database instance without a full restore.
    *   **Description:** Provides rapid access to data for quick recovery of individual files or data verification.
    *   **Scope & Impact:** Highly dependent on backup format and underlying virtualization/database technology. May involve creating temporary VMs or database instances from backup files.
    *   **Technical Considerations:** Tools like `VHD(X) mounting`, `SQL Server RESTORE WITH SNAPSHOT`, third-party virtual lab software integration.
    *   **Acceptance Criteria:** Users can access data within backups near-instantly for specific use cases.

96. **Feature: Automated Restore Testing / DR Drills**
    *   **Goal:** Automate the process of regularly testing backup restorability and performing DR drills.
    *   **Description:** Schedule restores to an isolated environment, verify data integrity/application functionality, and report on success/failure.
    *   **Scope & Impact:** Requires an isolated test environment, scripting for application-level verification, integration with restore logic.
    *   **Acceptance Criteria:** Automated DR tests run successfully and provide verification reports.

**XVIII. Enhanced Security & Compliance (Continued)**

98. **Feature: FIPS 140-2 Compliance Mode (for 7-Zip & Cryptography)**
    *   **Goal:** Ensure that cryptographic operations (archive encryption, checksums) can operate in a FIPS 140-2 compliant manner.
    *   **Description:** For government or highly regulated industries. 7-Zip itself has a FIPS-compliant DLL option. PoSh-Backup would need to ensure it uses this and that other crypto (like `Get-FileHash`) uses FIPS-validated algorithms if the OS is in FIPS mode.
    *   **Scope & Impact:** `Modules\Managers\7ZipManager.psm1` (ensure it can use 7-Zip's FIPS DLL), review all cryptographic calls. Configuration option to enforce FIPS-mode operations.
    *   **Acceptance Criteria:** PoSh-Backup operates in a FIPS-compliant manner when configured.
    *   **Update:** 7-Zip is not FIPS compliant.

99. **Feature: Tamper-Proof Logging (Integration with Secure Logging Systems)**
    *   **Goal:** Ensure logs, especially audit logs, are highly resistant to tampering.
    *   **Description:** Forward logs to write-once storage, blockchain-based logging systems, or secure SIEMs with immutability features.
    *   **Scope & Impact:** `Modules\Managers\LogManager.psm1`, integration with specialised logging targets.
    *   **Acceptance Criteria:** Audit logs are stored in a verifiably tamper-proof manner.

**XIX. Operational Efficiency & Automation (Continued)**

100. **Feature: Predictive Analytics for Backup Failures & Storage Capacity**
    *   **Goal:** Analyze trends in backup job success/failure rates and storage consumption to predict potential future issues.
    *   **Description:** E.g., "Job X has a 70% chance of failing next week based on recent error patterns," or "Storage target Y will run out of space in approximately 30 days."
    *   **Scope & Impact:** Requires data collection and analysis engine (potentially part of Central Management Server). Machine learning capabilities.
    *   **Acceptance Criteria:** System provides predictive warnings about potential backup issues or capacity shortfalls.

101. **Feature: Automated Remediation for Common Backup Failures**
    *   **Goal:** For common, known backup failure reasons, attempt automated remediation steps.
    *   **Description:** E.g., if a VSS error occurs, attempt to restart relevant VSS services and retry. If a network share is temporarily unavailable, retry after a longer, configurable delay.
    *   **Scope & Impact:** Enhanced error handling logic in various modules. Configurable remediation scripts/actions.
    *   **Acceptance Criteria:** Script can automatically resolve certain common failure scenarios.

102. **Feature: Resource-Aware Scheduling**
    *   **Goal:** Schedule backup jobs based not just on time, but also on system resource availability (CPU, I/O, network) or presence of other conflicting processes.
    *   **Description:** Prevents backups from impacting critical production workloads.
    *   **Scope & Impact:** Integration with system monitoring. Advanced scheduling logic, potentially in Central Management Server or a sophisticated local agent.
    *   **Acceptance Criteria:** Backup jobs are dynamically scheduled or deferred based on system load.

**XX. Cloud Native & Virtualization Focus**

103. **Feature: Backup & Restore of Cloud PaaS Resources**
    *   **Goal:** Extend beyond IaaS VMs to back up PaaS resources (e.g., Azure SQL Database, AWS RDS, Azure App Service configurations).
    *   **Description:** Utilise cloud provider APIs to export/snapshot PaaS data and configurations.
    *   **Scope & Impact:** New "CloudPaaS" target providers or application-specific modules for each PaaS service.
    *   **Acceptance Criteria:** Supported PaaS resources can be backed up and restored.

104. **Feature: Kubernetes (K8s) Persistent Volume Claim (PVC) Backup**
    *   **Goal:** Provide a mechanism to back up data stored in Kubernetes PVCs.
    *   **Description:** Integrate with K8s snapshot APIs (CSI snapshots) or run PoSh-Backup within a container with access to the PVC to back up its contents.
    *   **Scope & Impact:** New "Kubernetes" or "PVC" target/source provider. Requires K8s API interaction.
    *   **Acceptance Criteria:** Data from K8s PVCs can be backed up.

105. **Feature: Direct Backup of Virtual Machine Disks (Hypervisor Agnostic where possible)**
    *   **Goal:** Option to back up VM virtual disks directly (e.g., VMDK, VHDX) without necessarily needing an in-guest agent for file-level backup, especially for offline VMs.
    *   **Description:** Could involve hypervisor API integration (vSphere, Hyper-V, Xen, KVM) or tools that can read these disk formats.
    *   **Scope & Impact:** New "VMDisk" source type. Complex hypervisor interactions.
    *   **Acceptance Criteria:** Virtual disk files can be backed up directly.
    *   **Note:** Direct Hyper-V support is now implemented, which unfortunately isn't agnostic.

106. **Feature: Cloud-to-Cloud Backup & Replication**
    *   **Goal:** Enable backing up data from one cloud provider/region to another.
    *   **Description:** E.g., Backup an AWS S3 bucket to Azure Blob storage, or replicate Azure VMs to a different Azure region for DR.
    *   **Scope & Impact:** Enhancements to cloud target providers to act as sources and destinations. Orchestration logic.
    *   **Acceptance Criteria:** Data can be backed up/replicated between configured cloud targets.

**XXI. User Interface & User Experience (Beyond Home User)**

108. **Feature: PoSh-Backup PowerShell Module Packaging**
    *   **Goal:** Package the entire PoSh-Backup solution as a proper PowerShell module installable from PowerShell Gallery or local repository.
    *   **Description:** Simplifies installation, updates, and version management. Makes functions more easily discoverable.
    *   **Scope & Impact:** Major refactoring of script structure into a formal module format (`.psm1` root, `.psd1` manifest). All functions become part of the module.
    *   **Acceptance Criteria:** `Install-Module PoShBackup` works; `Get-Command -Module PoShBackup` lists functions.

---

**XXII. AI & Intelligent Operations**

109. **Feature: AI-Powered Anomaly Detection in Backup Patterns**
    *   **Goal:** Use AI/ML to detect unusual backup behaviour that might indicate ransomware activity (e.g., sudden large change rates, unusual file types being backed up, encryption of source files before backup) or failing hardware.
    *   **Description:** Proactive threat detection and early warning based on deviations from established backup norms.
    *   **Scope & Impact:** Requires data collection, ML model training (potentially cloud-based ML services or local models), integration with alerting.
    *   **Acceptance Criteria:** System flags anomalous backup jobs with potential risk indicators.

110. **Feature: AI-Assisted Restore Point Recommendation**
    *   **Goal:** When a restore is needed (especially after a data corruption event or ransomware), use AI to analyze backup history and suggest the "cleanest" or most optimal restore point.
    *   **Description:** Analyze file change rates, known malware signatures within backups (if scanned), and user feedback on previous restores to recommend a point before the incident.
    *   **Scope & Impact:** Integration with archive catalog, potential for inline malware scanning of backup data (resource-intensive), ML model.
    *   **Acceptance Criteria:** System provides intelligent recommendations for restore points.

111. **Feature: Natural Language Interface for Queries & Operations (CLI/Chat)**
    *   **Goal:** Allow administrators to query backup status or initiate simple operations using natural language.
    *   **Description:** E.g., "PoSh-Backup, what was the status of the SQL backup last night?" or "PoSh-Backup, restore file 'mydoc.docx' from yesterday's backup for user 'jdoe'."
    *   **Scope & Impact:** Integration with NLP services/libraries. API for PoSh-Backup actions.
    *   **Acceptance Criteria:** Users can interact with PoSh-Backup using basic natural language commands.

**XXIII. Extreme Resilience & Business Continuity**

112. **Feature: Air-Gapped Backup Orchestration (Automated/Semi-Automated)**
    *   **Goal:** Facilitate and partially automate the process of moving backups to truly air-gapped storage.
    *   **Description:** Could involve staging backups to a designated "export zone," then providing prompts/scripts for manual transfer to offline media (tape, removable drives), and finally updating a catalog once the air-gapped copy is confirmed. For automated systems, it might involve controlling network ACLs to temporarily connect and disconnect an isolated backup vault.
    *   **Scope & Impact:** **Complex orchestration.** Workflow management. Secure catalog updates.
    *   **Acceptance Criteria:** Process for creating and tracking air-gapped backups is streamlined and verifiable.

113. **Feature: "Last Known Good Configuration" Automatic Rollback**
    *   **Goal:** If a configuration change leads to widespread backup failures, provide an option to automatically (or with admin approval) roll back to the last known good configuration.
    *   **Description:** Version control for configuration files, with status tracking to identify "good" versions.
    *   **Scope & Impact:** Configuration versioning system. Logic to detect widespread failures post-config change.
    *   **Acceptance Criteria:** System can revert to a previously working configuration to mitigate issues.

114. **Feature: Distributed Backup Network (Peer-to-Peer for Resilience)**
    *   **Goal:** For highly distributed organizations or even groups of trusted home users, allow parts of backups (or encrypted, sharded pieces) to be stored across multiple PoSh-Backup instances.
    *   **Description:** Decentralised storage for extreme resilience against single-site failure. **Extremely complex and high security considerations.**
    *   **Scope & Impact:** Peer-to-peer networking, data sharding, distributed catalog, strong encryption and authentication between peers.
    *   **Acceptance Criteria:** Data can be recovered even if some nodes in the distributed backup network are lost.

**XXIV. Specialised Data & Application Support (Continued)**

115. **Feature: Backup & Restore of Containerised Applications & Configurations (Docker, Kubernetes)**
    *   **Goal:** Go beyond just PVCs to back up entire application definitions, configurations (ConfigMaps, Secrets), and potentially container images from a registry.
    *   **Description:** Holistic backup for containerised workloads.
    *   **Scope & Impact:** Kubernetes/Docker API integration. Tools like Velero (for K8s) could be an inspiration or integration point.
    *   **Acceptance Criteria:** Full state of containerised applications can be backed up and restored.

116. **Feature: IoT Device Data Backup (Edge Computing)**
    *   **Goal:** Lightweight PoSh-Backup client or integration method for backing up data from IoT devices or edge gateways.
    *   **Description:** Handle potentially intermittent connectivity, low bandwidth, resource-constrained devices.
    *   **Scope & Impact:** New lightweight client/agent. Optimised transfer protocols (MQTT, CoAP integration?).
    *   **Acceptance Criteria:** Data from designated IoT devices/edge systems is backed up to a central location.

117. **Feature: Scientific/Research Data Sets (Large, Specialised Formats)**
    *   **Goal:** Optimised handling for very large scientific data formats (e.g., HDF5, NetCDF, FITS) or genomics data.
    *   **Description:** May involve understanding the structure of these files for more intelligent incremental backups (if possible) or integration with tools specific to these domains.
    *   **Scope & Impact:** Research into specific file formats. Potential for custom pre/post processing hooks or specialised 7-Zip settings.
    *   **Acceptance Criteria:** Large scientific datasets are backed up efficiently and verifiably.

**XXV. Ecosystem & Integrations (Continued)**

118. **Feature: Integration with Configuration Management Databases (CMDB)**
    *   **Goal:** Automatically discover clients/servers and data sources to back up based on CMDB data.
    *   **Description:** Keep backup jobs synchronised with the managed IT environment.
    *   **Scope & Impact:** API integration with popular CMDBs (ServiceNow, JIRA, etc.).
    *   **Acceptance Criteria:** Backup scope can be dynamically updated based on CMDB information.

119. **Feature: Integration with Security Information and Event Management (SIEM) Systems**
    *   **Goal:** Deeper integration than just Syslog/Event Log. Send structured security-relevant events to SIEMs.
    *   **Description:** Events like failed admin logins to PoSh-Backup, critical backup failures, detected tampering, immutability status changes.
    *   **Scope & Impact:** Standardised event formats (CEF, LEEF). `LogManager.psm1` enhancements.
    *   **Acceptance Criteria:** Security-relevant PoSh-Backup events are ingested and parsable by SIEM systems.

120. **Feature: Marketplace for Community Target Providers & Hooks**
    *   **Goal:** A centralised, curated repository or discovery mechanism for community-contributed PoSh-Backup extensions.
    *   **Description:** Similar to PowerShell Gallery for modules, but specifically for PoSh-Backup plugins.
    *   **Scope & Impact:** Website/platform development. Plugin validation and signing process.
    *   **Acceptance Criteria:** Users can easily find, install, and share PoSh-Backup extensions.

# Below is insanity
## Read at your own risk

---

**XXVI. Autonomous & Self-Healing Operations**

121. **Feature: AI-Driven Autonomous Backup Scheduling & Resource Optimisation**
    *   **Goal:** PoSh-Backup intelligently determines the optimal time and resource allocation for backups without explicit scheduling.
    *   **Description:** Learns workload patterns, network conditions, storage performance, and RPO requirements to dynamically schedule and throttle jobs for maximum efficiency and minimal impact. It might even decide *what* to back up based on change rates and importance.
    *   **Scope & Impact:** **Extremely complex AI/ML.** Continuous monitoring, predictive modeling, reinforcement learning.
    *   **Acceptance Criteria:** Backup operations are fully autonomous, meeting protection goals with optimal resource usage.

122. **Feature: Self-Healing Backup Infrastructure**
    *   **Goal:** If a backup target becomes unavailable or corrupted, PoSh-Backup automatically attempts to reroute backups to alternate targets or even provision new temporary storage, and initiate self-healing of corrupted backup chains from replicas.
    *   **Description:** Requires a highly aware and integrated system, potentially with cloud provisioning capabilities or control over a distributed storage network.
    *   **Scope & Impact:** Advanced error detection, automated decision-making, infrastructure-as-code integration.
    *   **Acceptance Criteria:** The backup system can autonomously recover from certain infrastructure failures affecting backup targets.

123. **Feature: Proactive Data Pre-Staging for Instant Recovery (Beyond Live Mount)**
    *   **Goal:** Based on predictive failure analysis or user access patterns, proactively "pre-stage" critical data or VMs from backups to a warm standby location for near-zero RTO.
    *   **Description:** If the system anticipates a high likelihood of needing a specific restore, it gets the data ready *before* the request.
    *   **Scope & Impact:** Predictive analytics, tight integration with virtualization/storage, resource-intensive.
    *   **Acceptance Criteria:** Critical systems/data can be recovered with virtually no downtime due to proactive staging.

**XXVII. Quantum-Resistant Encryption & Future-Proofing**

124. **Feature: Integration with Quantum-Resistant Cryptography Algorithms**
    *   **Goal:** Offer options to encrypt archives using emerging quantum-resistant algorithms.
    *   **Description:** As quantum computing evolves, current encryption standards may become vulnerable. This provides a forward-looking security option.
    *   **Scope & Impact:** Requires integration of QRC libraries (when mature and standardised). 7-Zip itself would likely need to support this first, or PoSh-Backup would need to perform an outer layer of QRC encryption.
    *   **Acceptance Criteria:** Archives can be encrypted using selected quantum-resistant algorithms.

125. **Feature: "Digital Will" / Emergency Data Release Protocol**
    *   **Goal:** A secure mechanism to allow designated trusted parties to access/recover backups in case the primary administrator is incapacitated or deceased.
    *   **Description:** Could involve multi-party authentication, time-delayed release, or integration with trusted third-party "digital executor" services.
    *   **Scope & Impact:** **High security and legal considerations.** Secure key escrow or multi-sig schemes.
    *   **Acceptance Criteria:** A secure and verifiable process exists for emergency data access by authorised individuals.

**XXVIII. Decentralised & Trustless Backup Paradigms**

126. **Feature: Fully Decentralised Backup Network (Blockchain-Assisted)**
    *   **Goal:** Enable backups to be stored across a decentralised network of participating nodes (potentially incentivised via cryptocurrency), with integrity and ownership verified via blockchain.
    *   **Description:** No central point of failure or control. Data is sharded, encrypted, and distributed.
    *   **Scope & Impact:** **Massive R&D.** Blockchain integration, peer-to-peer networking, advanced cryptography, tokenomics.
    *   **Acceptance Criteria:** Backups are securely stored and retrievable from a decentralised network.

127. **Feature: Zero-Knowledge Proofs for Backup Verification**
    *   **Goal:** Allow verification of backup integrity and completeness *without* the verifier needing access to the actual (decrypted) backup content.
    *   **Description:** Enhances privacy and security, especially when third parties are involved in auditing or verifying backups.
    *   **Scope & Impact:** Advanced cryptographic research and implementation (e.g., zk-SNARKs, zk-STARKs).
    *   **Acceptance Criteria:** Backup integrity can be proven without revealing the content.

**XXIX. Hyper-Personalization & Context-Awareness**

128. **Feature: User Intent Prediction for Backup & Restore**
    *   **Goal:** Based on user activity, application usage, and context, PoSh-Backup proactively suggests relevant backup operations or identifies files likely needing recovery after an issue.
    *   **Description:** E.g., "You've been working heavily on ProjectX.docx for 3 hours. Create a versioned backup?" or "System event logs show application Y crashed. Would you like to see recent backups of its data files?"
    *   **Scope & Impact:** Desktop activity monitoring (with user consent), application event integration, local ML models.
    *   **Acceptance Criteria:** PoSh-Backup provides timely and relevant contextual suggestions.

129. **Feature: Adaptive Backup Strategies Based on Data "Value" or Sensitivity**
    *   **Goal:** Automatically adjust backup frequency, retention, and target security based on AI-determined data value or sensitivity.
    *   **Description:** Integrate with Data Loss Prevention (DLP) tools or use content analysis to classify data. Highly sensitive or valuable data gets more aggressive protection.
    *   **Scope & Impact:** DLP integration, content scanning, AI for classification, dynamic policy adjustment.
    *   **Acceptance Criteria:** Backup policies adapt dynamically to the nature of the data being protected.

**XXX. Sustainability & Energy Efficiency**

130. **Feature: Carbon-Aware Backup Scheduling**
    *   **Goal:** Optionally schedule large backup operations during times of lower carbon intensity on the power grid (integrating with regional grid data APIs).
    *   **Description:** For environmentally conscious users and data centers aiming to reduce their carbon footprint.
    *   **Scope & Impact:** Integration with real-time carbon intensity APIs (e.g., Electricity Maps, WattTime). Advanced scheduling.
    *   **Acceptance Criteria:** Backup jobs can be scheduled to align with periods of cleaner energy availability.

131. **Feature: Power-Efficient Backup Modes**
    *   **Goal:** Options to run backups in a "low power" mode that minimises CPU/disk usage, extending battery life for laptops or reducing energy consumption for servers during non-critical backup windows.
    *   **Description:** Aggressive throttling, potentially using less CPU-intensive compression algorithms for these specific runs.
    *   **Scope & Impact:** `Config\Default.psd1` settings, `Modules\Managers\7ZipManager.psm1`, `Modules\Core\Operations.psm1`.
    *   **Acceptance Criteria:** A measurable reduction in power consumption during "power-efficient" backup runs.

---

**XXXI. Core Functionality & Reliability Enhancements**

132. **Feature: Handling of Very Long Paths (MAX_PATH)**
    *   **Goal:** Improve reliability when dealing with source or destination paths exceeding Windows' traditional MAX_PATH limit (260 chars).
    *   **Description:** Ensure 7-Zip is invoked correctly (it generally supports long paths if the OS does and paths are prefixed with `\\?\`) and that PowerShell cmdlets used for path manipulation/testing also handle them.
    *   **Scope & Impact:** Review path handling in `Modules\Managers\7ZipManager.psm1`, `Modules\Operations\LocalArchiveProcessor.psm1`, `Modules\Targets\*` (for remote paths), and utility functions.
    *   **Acceptance Criteria:** Backups and transfers involving long paths complete successfully where the OS and 7-Zip support it.

134. **Enhancement: More Robust Check for 7-Zip Executable during `-TestConfig`**
    *   **Goal:** Ensure that `-TestConfig` explicitly verifies the `SevenZipPath` not just for existence but also tries to get its version.
    *   **Description:** Currently, `ConfigLoader` validates the path. `-TestConfig` could go a step further and attempt to run `7z.exe` with a simple command (like `i`) to confirm it's a working 7-Zip.
    *   **Scope & Impact:** `Modules\ScriptModeHandler.psm1` (for `-TestConfig` logic), `Modules\Managers\7ZipManager.psm1`.
    *   **Acceptance Criteria:** `-TestConfig` provides clearer feedback if the configured `7z.exe` is not functional.

**XXXII. Backup Target Enhancements (Practical)**

137. **Enhancement: Standardised Transfer Retry Mechanism for Target Providers**
    *   **Goal:** Implement a consistent, configurable retry mechanism for the *transfer phase* within target providers.
    *   **Description:** Currently, 7-Zip operations have retries. This would add retries for network copy/upload operations if they fail (e.g., temporary network blip).
    *   **Scope & Impact:** `Config\Default.psd1` (per-target `TransferRetryAttempts`, `TransferRetryDelaySeconds`), all target provider modules would need to incorporate this retry loop.
    *   **Acceptance Criteria:** Failed remote transfers are retried according to configuration.

138. **Enhancement: SFTP/FTP - Explicit FTPS Support & Port Configuration**
    *   **Goal:** For a future FTP/FTPS provider, ensure clear options for Explicit vs. Implicit FTPS and custom ports.
    *   **Description:** Common requirements for secure FTP.
    *   **Scope & Impact:** `Modules\Targets\FTP.Target.psm1` (when created), `Config\Default.psd1`.
    *   **Acceptance Criteria:** FTPS connections can be established using specified mode and port.

**XXXIII. Usability & Convenience (Practical)**

140. **Enhancement: `-TestConfig` to Validate a Single Job Definition**
    *   **Goal:** Allow `-TestConfig -BackupLocationName "MyJob"` to validate only the specified job and its direct dependencies/settings.
    *   **Description:** Faster and more focused validation when working on a specific job.
    *   **Scope & Impact:** `Modules\ScriptModeHandler.psm1`, `Modules\PoShBackupValidator.psm1`.
    *   **Acceptance Criteria:** `-TestConfig` with a job name provides targeted validation output.

143. **Enhancement: Clearer Progress for Multi-Job Sets**
    *   **Goal:** Provide better console feedback on the overall progress when running a backup set.
    *   **Description:** E.g., "Starting Set 'DailyBackups' (3 jobs total)...", "Job 'Job1' (1 of 3) starting...", "Job 'Job1' (1 of 3) completed. Status: SUCCESS".
    *   **Scope & Impact:** `Modules\Core\JobOrchestrator.psm1`.
    *   **Acceptance Criteria:** Console output clearly indicates progress through a backup set.

**XXXIV. Reporting & Logging (Practical)**

144. **Enhancement: HTML Report - "Copy Full Log" Button**
    *   **Goal:** Add a button to the HTML report to easily copy the entire detailed log content to the clipboard.
    *   **Description:** Useful for sharing logs for troubleshooting.
    *   **Scope & Impact:** `Modules\Reporting\Assets\ReportingHtml.Client.js`.
    *   **Acceptance Criteria:** Users can copy the full log text from the HTML report.

145. **Enhancement: HTML Report - Option for Collapsible Configuration Section**
    *   **Goal:** Make the "Configuration Used" section in the HTML report collapsible, and potentially collapsed by default if it's very long.
    *   **Description:** Improves readability for reports with extensive job configurations.
    *   **Scope & Impact:** `Modules\Reporting\ReportingHtml.psm1`, `Modules\Reporting\Assets\ReportingHtml.Client.js`.
    *   **Acceptance Criteria:** Configuration section can be collapsed/expanded.

146. **Feature: Send Test Notification**
    *   **Goal:** Allow users to send a test email/notification to verify notification settings.
    *   **Description:** Part of `-TestConfig` or a new CLI switch `-TestNotification`.
    *   **Scope & Impact:** `PoSh-Backup.ps1`, new function in `NotificationManager.psm1` (when created) or email sending logic.
    *   **Acceptance Criteria:** A test notification can be successfully sent and received.

**XXXV. Advanced Configuration (Practical)**

147. **Feature: Job-Level Hook Parameter Overrides**
    *   **Goal:** Allow passing specific, simple parameters to hook scripts directly from the job's configuration, in addition to the standard set of parameters PoSh-Backup sends.
    *   **Description:** E.g., in job config: `PreBackupScriptParameters = @{ MyCustomFlag = $true; TargetServer = "SQL01" }`. These would be passed to the `PreBackupScriptPath`.
    *   **Scope & Impact:** `Config\Default.psd1`, `Modules\Managers\HookManager.psm1` (to merge and pass these).
    *   **Acceptance Criteria:** Custom parameters from job config are available in hook scripts.

---

**XXXVI. Operational Refinements & Edge Cases**

149. **Feature: Configurable behaviour for "Archive Already Exists" (Non-Date-Stamped Archives)**
    *   **Goal:** For jobs that *don't* use date stamps in archive names (e.g., for sync/update modes), define what to do if the target archive file already exists.
    *   **Description:** Options: "Overwrite" (current implicit default), "FailJob", "SkipJob", "AppendSuffix" (e.g., `archive.bak.7z`, `archive.bak1.7z`).
    *   **Scope & Impact:** `Config\Default.psd1` (job-level `OnArchiveExists`), `Modules\Operations\LocalArchiveProcessor.psm1`.
    *   **Acceptance Criteria:** Job behaves as configured when a non-date-stamped archive name collides.

150. **Enhancement: VSS - Retry Shadow Copy Creation on Transient Errors**
    *   **Goal:** If VSS shadow copy creation fails due to a transient error (e.g., VSS writers busy), automatically retry a few times.
    *   **Description:** Improves resilience of VSS operations.
    *   **Scope & Impact:** `Modules\Managers\VssManager.psm1` (within `New-VSSShadowCopy`).
    *   **Acceptance Criteria:** VSS creation retries on specific, known-transient errors.

151. **Feature: "Max Archive Age for Full Backup" (for Incremental/Differential Chains)**
    *   **Goal:** When using incremental/differential strategies, trigger a new full backup automatically if the last full backup is older than a configured age (e.g., 30 days).
    *   **Description:** Prevents excessively long incremental chains, improving restore performance and reliability.
    *   **Scope & Impact:** `Config\Default.psd1` (job-level `MaxFullBackupAgeDays`), logic in `Modules\Core\Operations.psm1` or `JobOrchestrator.psm1` to check age and override backup type.
    *   **Acceptance Criteria:** A new full backup is forced when the previous one exceeds the configured age.

152. **Feature: Pre-Job Script Hook (Global and Set Level)**
    *   **Goal:** Allow a script to run before a specific job (already exists), before any jobs in a set, or before any jobs in the entire PoSh-Backup run.
    *   **Description:** `GlobalPreScriptPath` already covers "before any jobs". This would add `SetPreScriptPath` to run before a set begins.
    *   **Scope & Impact:** `Config\Default.psd1` (set-level `SetPreScriptPath`), `Modules\Core\JobOrchestrator.psm1` (to invoke set-level pre-hook).
    *   **Acceptance Criteria:** Set-level pre-backup scripts execute before any job in the set.

**XXXVII. Reporting & Logging Enhancements (Practical)**

153. **Enhancement: HTML Report - Direct Link to Specific Log Entries from Summary/Errors**
    *   **Goal:** If the summary shows an error message or a specific failure, provide a clickable link in the HTML report that jumps directly to the relevant detailed log entry.
    *   **Description:** Improves navigation and troubleshooting within the HTML report.
    *   **Scope & Impact:** `Modules\Reporting\ReportingHtml.psm1` (needs to assign IDs to log entries and create links).
    *   **Acceptance Criteria:** Users can click on summary errors to navigate to detailed logs.

154. **Enhancement: Log File - Option to Include Job Configuration Snapshot**
    *   **Goal:** Optionally embed a snapshot of the effective job configuration used for that specific run at the beginning or end of the text log file.
    *   **Description:** Makes individual log files more self-contained for historical analysis, especially if main config files change over time.
    *   **Scope & Impact:** `Config\Default.psd1` (global/job `EmbedConfigInLogFile = $true`), `Modules\Managers\LogManager.psm1` or `JobOrchestrator.psm1`.
    *   **Acceptance Criteria:** Text log files can optionally contain the effective job configuration.

155. **Feature: "Last Successful Backup" Timestamp in Reports/Listings**
    *   **Goal:** Display the date/time of the last known successful backup for a job.
    *   **Description:** Useful for quick assessment of backup freshness in `-ListBackupLocations` output and in reports.
    *   **Scope & Impact:** Requires a mechanism to store/retrieve last success timestamps (e.g., a small status file per job, or parsing existing reports/logs if reliable). `Modules\ScriptModeHandler.psm1`, reporting modules.
    *   **Acceptance Criteria:** Last successful backup timestamp is displayed where relevant.

**XXXVIII. User Interface & CLI (Practical)**

**XXXIX. Installation & Portability**

159. **Feature: "Portable Mode" Option**
    *   **Goal:** Allow PoSh-Backup (and its modules/config) to run from a USB drive or network share without installation, with paths resolved relative to the main script.
    *   **Description:** Requires ensuring all module imports, config loading, and 7-Zip path detection can work from a dynamic base path. 7-Zip itself might need to be included in the portable package.
    *   **Scope & Impact:** Review all path handling. `Modules\Managers\7ZipManager\Discovery.psm1` might need to check for `7z.exe` relative to script root first.
    *   **Acceptance Criteria:** PoSh-Backup can run in a self-contained, portable manner.

---

**XL. Advanced Job Control & Scheduling**

161. **Feature: Event-Driven Backup Triggers (Beyond Drive Connection)**
    *   **Goal:** Trigger backup jobs based on specific system events or application events.
    *   **Description:** E.g., "Run JobX after ApplicationY writes a specific log event," "Run JobZ before Windows Update initiates a restart," "Run JobQ after X number of file changes in a monitored directory."
    *   **Scope & Impact:** Requires a background agent or integration with event monitoring systems (Windows Event Forwarding, WMI event subscriptions, FileSystemWatcher). **Complex.**
    *   **Acceptance Criteria:** Backups can be triggered by defined system or application events.

162. **Feature: Job "Profiles" within a Single Job Definition**
    *   **Goal:** Allow a single named backup job to have multiple "profiles" with slight variations (e.g., different source sub-paths, different remote target, different frequency) selectable via CLI.
    *   **Description:** Reduces duplication if many jobs are similar with minor tweaks. E.g., `PoSh-Backup.ps1 -BackupLocationName "MyServer" -JobProfile "DailyDifferential"` vs. `-JobProfile "WeeklyFullToCloud"`.
    *   **Scope & Impact:** `Config\Default.psd1` (new structure within `BackupLocations` to define profiles), `Modules\ConfigManagement\EffectiveConfigBuilder.psm1`.
    *   **Acceptance Criteria:** Users can select a specific profile for a job, applying its unique settings.

163. **Feature: Inter-Set Dependencies**
    *   **Goal:** Allow defining dependencies where one entire Backup Set must complete successfully before another Backup Set can start.
    *   **Description:** For complex, multi-stage backup workflows across different groups of jobs.
    *   **Scope & Impact:** `Config\Default.psd1` (new `DependsOnSets` key in `BackupSets`), `Modules\Managers\JobDependencyManager.psm1` (to handle set-level graph), `PoSh-Backup.ps1` (orchestration).
    *   **Acceptance Criteria:** Backup Sets can be chained based on dependencies.

164. **Feature: "Catch-up" Job Execution for Missed Schedules**
    *   **Goal:** If a scheduled backup job was missed (e.g., machine was off), automatically run it as soon as possible when the machine is next available.
    *   **Description:** Requires tracking last run times and scheduled times. Task Scheduler has some of this, but PoSh-Backup could manage its own state for more control.
    *   **Scope & Impact:** State management for job schedules. Logic in `PoSh-Backup.ps1` startup or a small agent.
    *   **Acceptance Criteria:** Missed scheduled jobs are run when the system becomes available.

**XLI. Data Lifecycle Management (Beyond Basic Retention)**

165. **Feature: Data Grooming / Archival Tiering within PoSh-Backup**
    *   **Goal:** Define policies to move older backups from primary backup storage to a secondary, cheaper/slower "archive" storage tier (both tiers managed by PoSh-Backup, potentially different target types).
    *   **Description:** E.g., keep 30 days of backups on fast NAS (UNC target), then move backups older than 30 days to a cloud archive (S3 Glacier via S3 target). This is distinct from target-native tiering.
    *   **Scope & Impact:** Policy engine. New job type ("ArchiveGroomingJob"). Logic to identify, transfer, and verify data between PoSh-Backup managed targets. Update catalog.
    *   **Acceptance Criteria:** Backups are moved between configured storage tiers based on policy.

166. **Feature: Legal Hold / eDiscovery Support**
    *   **Goal:** Ability to place specific backup instances or data from backups on "legal hold," preventing deletion by retention policies and facilitating eDiscovery searches.
    *   **Description:** Requires tagging backups, robust cataloging, and search capabilities.
    *   **Scope & Impact:** Integration with Archive Catalog. `Modules\Managers\RetentionManager.psm1` to respect holds. CLI/UI for managing holds and searches.
    *   **Acceptance Criteria:** Backups can be placed on legal hold and are exempt from deletion; data can be searched for eDiscovery.

**XLII. Security & Hardening (Continued)**

167. **Feature: Two-Factor Authentication (2FA/MFA) for Critical Operations**
    *   **Goal:** Require 2FA/MFA for critical PoSh-Backup operations if managed via a central console or for certain CLI actions (e.g., deleting a target, modifying global config).
    *   **Description:** Enhances security for administrative actions.
    *   **Scope & Impact:** Central Management Server or integration with identity providers supporting MFA.
    *   **Acceptance Criteria:** Critical operations can be protected by 2FA/MFA.

168. **Feature: Signed Hook Scripts & Configuration Files**
    *   **Goal:** Option to require that hook scripts and even configuration files are digitally signed, and PoSh-Backup verifies the signature before execution/loading.
    *   **Description:** Prevents unauthorised modification of scripts or critical configuration.
    *   **Scope & Impact:** `Modules\Managers\HookManager.psm1`, `Modules\ConfigManagement\ConfigLoader.psm1`. Use `Get-AuthenticodeSignature`.
    *   **Acceptance Criteria:** Script can be configured to only load/run signed components.

169. **Feature: "Quarantine" for Suspicious Backups**
    *   **Goal:** If AI Anomaly Detection (Feature #109) or an integrated malware scanner flags a backup set as potentially compromised (e.g., contains ransomware), automatically move it to a "quarantine" location/state.
    *   **Description:** Prevents accidental restoration of compromised data. Requires admin review to release or delete.
    *   **Scope & Impact:** Integration with anomaly detection/scanning. New logic for managing quarantined backups.
    *   **Acceptance Criteria:** Suspicious backups are automatically quarantined.

**XLIII. User Customization & Theming (Beyond HTML Reports)**

170. **Feature: Customisable Console Output Themes (Beyond Individual colours)**
    *   **Goal:** Allow users to define named themes for console output (e.g., "HighContrastConsole", "MinimalConsole") that set a collection of `$Global:Colour*` variables.
    *   **Description:** Similar to HTML report themes, but for the console.
    *   **Scope & Impact:** `Config\Default.psd1` (new section for console themes), `Modules\Managers\InitialisationManager.psm1` (to load selected theme).
    *   **Acceptance Criteria:** Users can select a console output theme.

171. **Feature: Sound Notifications for Job Completion/Failure (Optional)**
    *   **Goal:** Play a distinct sound for backup success, warning, or failure, for users who are nearby and want audible alerts.
    *   **Description:** Simple OS beep or custom sound files.
    *   **Scope & Impact:** `Config\Default.psd1` (enable sounds, paths to sound files), `Modules\Managers\FinalisationManager.psm1`.
    *   **Acceptance Criteria:** Audible notifications are played based on job outcome.

**XLIV. Advanced Diagnostics & Troubleshooting**

173. **Feature: Trace-Level Logging**
    *   **Goal:** An extremely verbose logging level beyond "DEBUG" for deep troubleshooting of PoSh-Backup's internal logic flow.
    *   **Description:** Logs entry/exit of most functions, key variable states, etc. Performance impact expected.
    *   **Scope & Impact:** `Write-LogMessage` enhancement. Many new log calls throughout the codebase.
    *   **Acceptance Criteria:** Trace-level logging provides highly detailed execution flow.

---

**XLV. Practical Job & Configuration Management**

174. **Feature: Job Grouping/Tagging in Configuration**
    *   **Goal:** Allow users to assign jobs to logical groups or apply tags in the configuration.
    *   **Description:** E.g., `Groups = @("Databases", "EuropeServers")` or `Tags = @("Critical", "Daily", "OffsiteCopy")`. This wouldn't directly affect execution order (that's `DependsOnJobs` or `BackupSets`) but would allow CLI operations to target jobs by group/tag.
    *   **Scope & Impact:** `Config\Default.psd1` (new job-level `Groups`/`Tags` array), `PoSh-Backup.ps1` (CLI parameters like `-RunJobGroup "Databases"`, `-RunJobsWithTag "Critical"`), `Modules\ConfigManagement\JobResolver.psm1`.
    *   **Acceptance Criteria:** Users can run collections of jobs based on defined groups or tags.

175. **Feature: Configuration "Includes" or "Snippets"**
    *   **Goal:** Allow users to define common configuration snippets (e.g., a standard set of 7-Zip parameters, a common remote target definition) in separate files and "include" them in multiple job or target definitions.
    *   **Description:** Reduces redundancy in large configurations (DRY principle).
    *   **Scope & Impact:** `Modules\ConfigManagement\ConfigLoader.psm1` would need to parse a special `@include "path/to/snippet.psd1"` directive and merge the content.
    *   **Acceptance Criteria:** Configuration snippets can be defined and included, reducing duplication.

**XLVI. Practical Archive & File Handling**

181. **Enhancement: More Informative "File Not Found" for Sources**
    *   **Goal:** When a source path specified in the config is not found, provide more context in the error/warning.
    *   **Description:** E.g., "Source path 'C:\Users\NonExistent\Docs' for job 'MyDocs' not found. This path was defined in 'User.psd1' at line X."
    *   **Scope & Impact:** `Modules\Core\Operations\JobPreProcessor.psm1`. Requires `ConfigLoader` to pass along source info of settings.
    *   **Acceptance Criteria:** Error messages for missing source paths are more informative.

**XLVII. Practical Reporting & Feedback**

182. **Enhancement: HTML Report - Visual Indication of Log Level in Filter Checkboxes**
    *   **Goal:** Style the log level filter checkboxes/labels in the HTML report with their corresponding colours.
    *   **Description:** Makes it easier to visually associate filter toggles with log entry colours. E.g., the "ERROR" checkbox label is red.
    *   **Scope & Impact:** `Modules\Reporting\ReportingHtml.psm1` (to add classes/styles to labels), `Modules\Reporting\Assets\ReportingHtml.Client.js` (if dynamic styling needed).
    *   **Acceptance Criteria:** Log level filter options are colour-coded.

183. **Feature: "Estimated Backup Size" in Pre-Flight Check / TestConfig**
    *   **Goal:** Provide an *estimate* of the total size of source files for a job during `-TestConfig` or a pre-flight check.
    *   **Description:** Helps users anticipate archive size and required destination space. Does not account for compression.
    *   **Scope & Impact:** `Modules\ScriptModeHandler.psm1` or new pre-flight logic. Iterate source paths with `Get-ChildItem | Measure-Object -Sum Length`.
    *   **Acceptance Criteria:** `-TestConfig` or pre-flight check outputs an estimated total source size.

184. **Enhancement: Clearer Indication of Which Config File a Setting Came From**
    *   **Goal:** In `-TestConfig` or `-GetEffectiveConfig` output, and potentially in HTML report's config section, indicate if a setting's value came from `Default.psd1`, `User.psd1`, a Set definition, or a CLI override.
    *   **Description:** Aids in understanding configuration layering.
    *   **Scope & Impact:** `Modules\ConfigManagement\EffectiveConfigBuilder.psm1` needs to track the source of each value. This is a significant change to how `Get-ConfigValue` and the builder work.
    *   **Acceptance Criteria:** Origin of effective settings is clearly displayed.

**XLVIII. Practical Security**

185. **Feature: Password Policy for Archive Passwords (Optional Enforcement)**
    *   **Goal:** Allow defining a minimum complexity/length for archive passwords when using the "Interactive" method.
    *   **Description:** Helps guide users to create stronger passwords. PoSh-Backup would validate the entered password against the policy before accepting it.
    *   **Scope & Impact:** `Config\Default.psd1` (global `ArchivePasswordPolicyRegex`, `ArchivePasswordPolicyDescription`), `Modules\Managers\PasswordManager.psm1` (in "Interactive" block).
    *   **Acceptance Criteria:** Interactively entered passwords are validated against the defined policy.

186. **Enhancement: Limit Scope of `PSCredential` Object from SecretManagement**
    *   **Goal:** When retrieving a `PSCredential` from SecretManagement (e.g., for WebDAV), ensure it's only held in memory for the minimum time necessary and explicitly cleared.
    *   **Description:** Reinforce secure handling of credential objects.
    *   **Scope & Impact:** Review `Modules\Targets\WebDAV.Target.psm1` and other future providers using `PSCredential` from secrets.
    *   **Acceptance Criteria:** `PSCredential` objects are handled with minimal exposure.

---

**XLIX. Enhanced User Interaction & Guidance**

187. **Feature: Interactive `-HelpMeChoose` Mode**
    *   **Goal:** Guide users through common backup scenarios to help them decide which parameters or configuration options to use.
    *   **Description:** A Q&A style interaction. E.g., "What do you want to back up (Documents, Specific Folder, Whole Drive)?" -> "Where do you want to save it (External Drive, Network Share, Cloud)?" -> "How often?" -> Suggests a sample CLI command or config snippet.
    *   **Scope & Impact:** `PoSh-Backup.ps1` (new switch), new interactive question/suggestion engine module.
    *   **Acceptance Criteria:** Users can get tailored suggestions for their backup needs through an interactive process.

188. **Feature: "What If I Run This?" - Enhanced `-Simulate` Output**
    *   **Goal:** Make the `-Simulate` output even clearer about *exactly* what actions would be taken, in plain language.
    *   **Description:** Instead of just "SIMULATE: Would copy X to Y", perhaps "SIMULATE: The following files from 'C:\Sources' would be compressed into an archive named 'Backup.7z' in 'D:\Dest'. This archive would then be copied to '\\Network\Share'."
    *   **Scope & Impact:** Refine logging messages in all modules when `$IsSimulateMode` is active to be more descriptive and less like internal debug logs.
    *   **Acceptance Criteria:** `-Simulate` output is very easy for a non-expert to understand.

189. **Feature: GUI Wrapper / Launcher (Simple Initial Version)**
    *   **Goal:** A very basic GUI to select common options and launch PoSh-Backup.ps1 with the correct parameters.
    *   **Description:** Not a full management console, but a simple frontend for common tasks like selecting a job from config, choosing a source/destination for a one-off backup, and hitting "Run". Could be built with PowerShell (WPF/XAML or Windows Forms) or a simple web interface if a local web server is too much.
    *   **Scope & Impact:** **Significant.** New GUI project.
    *   **Acceptance Criteria:** User can launch common backup operations from a simple GUI.

190. **Feature: "Explain This Setting" in `-TestConfig` or `-ListBackupLocations`**
    *   **Goal:** When listing jobs or testing config, provide an option to get a plain-language explanation of what a specific configuration key does.
    *   **Description:** E.g., `PoSh-Backup.ps1 -ListBackupLocations -ExplainSetting "TreatSevenZipWarningsAsSuccess"`.
    *   **Scope & Impact:** Store descriptions (perhaps from schema or a new lookup table). `Modules\ScriptModeHandler.psm1`.
    *   **Acceptance Criteria:** Users can get quick explanations of configuration settings.

191. **Enhancement: Progress Bar for Overall Backup Set**
    *   **Goal:** Display a `Write-Progress` bar for the completion of a Backup Set (e.g., "Processing Set 'Daily' - Job 2 of 5 complete").
    *   **Description:** Gives a better visual sense of overall progress for multi-job runs.
    *   **Scope & Impact:** `Modules\Core\JobOrchestrator.psm1`.
    *   **Acceptance Criteria:** A progress bar is shown for backup set execution.

192. **Feature: "Quick Restore Last Backup" Option**
    *   **Goal:** A simple CLI command to restore the absolute latest backup of a specific job to a designated temporary location.
    *   **Description:** E.g., `PoSh-Backup.ps1 -QuickRestore "MyDocsJob" -RestoreTo "C:\TempRestore"`. Assumes the latest archive is desired.
    *   **Scope & Impact:** `PoSh-Backup.ps1` (new switch), logic to find the latest archive for a job, `Modules\7ZipManager.psm1` (extraction).
    *   **Acceptance Criteria:** User can quickly restore the latest backup of a job.

194. **Feature: "Create Desktop Shortcut" for Specific Jobs/Sets**
    *   **Goal:** A utility command to create a desktop shortcut that runs a specific PoSh-Backup job or set with predefined parameters.
    *   **Description:** For users who prefer to launch backups by clicking an icon.
    *   **Scope & Impact:** `PoSh-Backup.ps1` (new switch, e.g., `-CreateShortcut -BackupLocationName "MyDocs"`), logic to create `.lnk` files.
    *   **Acceptance Criteria:** Desktop shortcuts can be created to run specific backup configurations.

195. **Enhancement: More Descriptive Error Messages with Actionable Advice**
    *   **Goal:** When errors occur, provide clearer messages that suggest possible causes or solutions.
    *   **Description:** Instead of just "Access Denied to X", perhaps "Access Denied to X. Ensure the user running PoSh-Backup has write permissions, or try running as Administrator if VSS or protected paths are involved."
    *   **Scope & Impact:** Review error handling and logging messages throughout all modules.
    *   **Acceptance Criteria:** Error messages are more user-friendly and offer troubleshooting hints.

196. **Feature: "First Run" Welcome & Quick Tip Message**
    *   **Goal:** On the very first execution of PoSh-Backup.ps1 (e.g., if no `User.psd1` and no log files exist), display a brief welcome message and a tip (like "Use `-TestConfig` to check your setup!").
    *   **Description:** Makes the initial experience less daunting.
    *   **Scope & Impact:** `PoSh-Backup.ps1` (startup logic).
    *   **Acceptance Criteria:** A welcome/tip message is shown on first run.

---

**L. Enhanced Configuration & Setup Assistance**

197. **Feature: Interactive `User.psd1` Editor (CLI-based)**
    *   **Goal:** A guided CLI tool to edit specific sections or jobs within `User.psd1` without manually opening the file.
    *   **Description:** E.g., `PoSh-Backup.ps1 -EditJob "MyDocsJob"` would present options to change source, destination, retention for that job.
    *   **Scope & Impact:** New CLI mode, functions to parse, modify, and save PSD1 data programmatically (carefully!).
    *   **Acceptance Criteria:** Users can modify common job settings via a guided CLI interface.

199. **Feature: "Best Practices" Configuration Analyzer**
    *   **Goal:** A mode that analyzes the current configuration and suggests improvements or points out potentially risky settings based on common best practices.
    *   **Description:** E.g., "Warning: Job 'X' has no remote target defined." or "Info: Consider enabling VSS for job 'Y' if source files might be open." or "Warning: PlainText password used for job Z."
    *   **Scope & Impact:** New CLI switch (e.g., `-AnalyzeConfig`), new module with analysis rules.
    *   **Acceptance Criteria:** Script provides actionable advice on configuration best practices.

**LI. Improved Operational Feedback & Control**

200. **Feature: Real-time Transfer Speed and ETA for Large Files/Targets**
    *   **Goal:** For target providers that support it (or where PoSh-Backup can monitor), display estimated transfer speed and ETA for large file uploads/downloads.
    *   **Description:** Provides better feedback during long remote operations.
    *   **Scope & Impact:** Target provider modules would need to report progress if possible. `RemoteTransferOrchestrator` to display.
    *   **Acceptance Criteria:** User sees real-time transfer stats for supported targets.

201. **Feature: Pause and Resume for Active Backup Job (CLI/Interactive)**
    *   **Goal:** Allow a currently running backup job (especially the 7-Zip or transfer part) to be paused and resumed.
    *   **Description:** Useful if the user suddenly needs system resources for another task.
    *   **Scope & Impact:** **Complex.** Requires ability to suspend/resume `7z.exe` process (if possible via OS calls) or for target transfers, manage state and restart. Might be easier for chunked transfers.
    *   **Acceptance Criteria:** A running job can be paused and later resumed.

203. **Enhancement: More Granular `-Simulate` Output Levels**
    *   **Goal:** Allow different levels of verbosity for simulation.
    *   **Description:** E.g., `-Simulate` (normal), `-Simulate -Verbose` (more detail), `-Simulate -Show7ZipCommands` (shows the exact 7-Zip command that would run).
    *   **Scope & Impact:** `PoSh-Backup.ps1` CLI parsing, adjust logging within simulate blocks.
    *   **Acceptance Criteria:** Simulation output verbosity can be controlled.

**LII. Restore & Verification Enhancements (Practical)**

204. **Feature: Search Within Archive(s) for a File (CLI Utility)**
    *   **Goal:** Allow searching for a filename (or pattern) across multiple backup archives for a specific job without extracting them.
    *   **Description:** Helps locate which backup version contains a needed file. Uses `7z l` and filters output.
    *   **Scope & Impact:** `PoSh-Backup.ps1` (new CLI switch), `Modules\Managers\7ZipManager.psm1`.
    *   **Acceptance Criteria:** User can search for filenames within a job's backup history.

205. **Feature: Restore to Original Location with Conflict Handling**
    *   **Goal:** When restoring, provide an option to restore files to their original locations, with choices for handling existing files (Overwrite, Skip, Rename Existing, Rename Restored).
    *   **Description:** Common restore requirement.
    *   **Scope & Impact:** Restore logic (new module or `7ZipManager` enhancement). Requires storing original paths if VSS was used.
    *   **Acceptance Criteria:** Files can be restored to original locations with user-defined conflict resolution.

206. **Feature: "Mount Backup Archive as Read-Only Drive" (using 7-Zip or OS tools)**
    *   **Goal:** For quick browsing of archive contents, allow mounting it as a temporary read-only drive letter or folder.
    *   **Description:** Some tools allow mounting archives. 7-Zip itself can be used with tools that map its output. Windows can mount ISOs (if archive is an ISO) or VHDs.
    *   **Scope & Impact:** Research tools/techniques. New utility function. May be limited by archive type.
    *   **Acceptance Criteria:** User can mount an archive for easy browsing.

**LIII. User Safety & Convenience (Practical)**

207. **Feature: "Undo Last Config Change" (Simple Version)**
    *   **Goal:** A very simple mechanism to revert `User.psd1` to its immediate previous version.
    *   **Description:** When `User.psd1` is saved by PoSh-Backup (e.g., after interactive edit or future auto-update of config structure), keep one backup (e.g., `User.psd1.bak`). A CLI command could restore this.
    *   **Scope & Impact:** `Modules\ConfigManagement\ConfigLoader.psm1` (or wherever config is written). New CLI utility.
    *   **Acceptance Criteria:** User can revert `User.psd1` to its last saved state.

208. **Enhancement: Confirmation Prompt Before Deleting a Backup Target Definition**
    *   **Goal:** If a future feature allows editing/deleting `BackupTargets` from config via CLI/UI, add a confirmation.
    *   **Description:** Prevents accidental deletion of a target definition that might be in use by many jobs.
    *   **Scope & Impact:** Future config editing module.
    *   **Acceptance Criteria:** Confirmation required before deleting a target definition.

209. **Feature: "What If I Delete This Job?" Impact Analysis**
    *   **Goal:** Before deleting a job definition, show other jobs or sets that might depend on it.
    *   **Description:** Prevents breaking dependency chains.
    *   **Scope & Impact:** Future config editing module. Integration with `JobDependencyManager.psm1`.
    *   **Acceptance Criteria:** User is warned about impacts before deleting a job definition.

---

**LIV. Enhanced User Experience & Onboarding**

210. **Feature: Interactive "First Time Setup" Wizard**
    *   **Goal:** Guide new users through essential initial configuration steps beyond just `User.psd1` creation.
    *   **Description:** This wizard could:
        *   Help locate/validate the 7-Zip path.
        *   Explain the `DefaultDestinationDir` and ask for a preferred default.
        *   Briefly explain `BackupLocations` vs. `BackupSets`.
        *   Offer to create a very simple first backup job (e.g., "My Documents to External Drive").
        *   Suggest running `-TestConfig` after setup.
    *   **Scope & Impact:** `PoSh-Backup.ps1` (trigger on first run or via `-SetupWizard` switch), new interactive module.
    *   **Acceptance Criteria:** New users are guided through a basic, functional setup.

211. **Feature: "Show Example Configuration" CLI Switch**
    *   **Goal:** Quickly display well-commented examples of specific configuration sections (e.g., a job definition, a target definition, a set definition) in the console.
    *   **Description:** E.g., `PoSh-Backup.ps1 -ShowExample JobDefinition` or `PoSh-Backup.ps1 -ShowExample TargetDefinition -Type SFTP`.
    *   **Scope & Impact:** `PoSh-Backup.ps1`, `Modules\ScriptModeHandler.psm1`. Store example snippets, perhaps in `Config\Default.psd1` or separate files.
    *   **Acceptance Criteria:** Users can easily view example configuration snippets from the CLI.

212. **Enhancement: Contextual Help Links in Error Messages**
    *   **Goal:** When common or known errors occur, include a short link in the error message to a relevant section in the README or online documentation.
    *   **Description:** E.g., "VSS Error 0x8004231f: VSS writer timed out. See [link to VSS troubleshooting section]."
    *   **Scope & Impact:** Review error messages throughout the codebase. Requires documentation to be in place and linkable.
    *   **Acceptance Criteria:** Relevant error messages provide direct links to troubleshooting documentation.

213. **Feature: "Human Readable" Configuration Summary in `-TestConfig`**
    *   **Goal:** Augment the `-TestConfig` output with a section that explains the effective settings for key jobs/targets in plain language.
    *   **Description:** Instead of just dumping config keys/values, translate them. E.g., "Job 'MyDocs' will back up 'C:\Users\Me\Documents' to '\\server\share\MyDocs_\[Date].7z', keeping 5 local copies. It will then be sent to SFTP target 'Offsite1'."
    *   **Scope & Impact:** `Modules\ScriptModeHandler.psm1`. Logic to interpret effective config and generate narrative.
    *   **Acceptance Criteria:** `-TestConfig` includes a plain language summary of what will happen.

214. **Enhancement: Visual Cues for Required vs. Optional Settings (e.g., in `-ShowExample`)**
    *   **Goal:** When displaying example configurations or help, visually distinguish between required and optional settings.
    *   **Description:** Could use colour, asterisks, or comments.
    *   **Scope & Impact:** `Modules\ScriptModeHandler.psm1` or wherever examples are generated/displayed.
    *   **Acceptance Criteria:** Users can easily identify mandatory configuration settings.

215. **Feature: "What's New?" / Changelog Display (CLI)**
    *   **Goal:** A CLI switch to display recent changes or the changelog for the current PoSh-Backup version.
    *   **Description:** E.g., `PoSh-Backup.ps1 -ViewChangelog`. The changelog could be a simple text file bundled with the script.
    *   **Scope & Impact:** `PoSh-Backup.ps1`, `Modules\ScriptModeHandler.psm1`. Maintain a `CHANGELOG.md` or similar.
    *   **Acceptance Criteria:** Users can view the script's version history and recent changes from the CLI.

216. **Enhancement: Consistent Date/Time Formatting in All Outputs**
    *   **Goal:** Ensure all dates and times displayed in logs, reports, and console messages use a consistent, user-friendly, and unambiguous format.
    *   **Description:** Review all `Get-Date -Format` calls. Consider ISO 8601 (e.g., `yyyy-MM-dd HH:mm:ss`) for logs, and perhaps a more localised friendly format for HTML reports if desired (though ISO 8601 is often preferred for clarity).
    *   **Scope & Impact:** Code review across all modules.
    *   **Acceptance Criteria:** Date and time displays are consistent and clear.

217. **Feature: "Dry Run" for Retention Policy Only**
    *   **Goal:** Allow users to see which files *would be* deleted by the retention policy for a job or target without actually deleting them or running a backup.
    *   **Description:** E.g., `PoSh-Backup.ps1 -TestRetention -BackupLocationName "MyJob"` or `-TestRetention -TargetName "MyRemoteTarget"`.
    *   **Scope & Impact:** `PoSh-Backup.ps1` (new switch), `Modules\Managers\RetentionManager.psm1` and target providers need to support a "list files to delete" mode.
    *   **Acceptance Criteria:** Users can get a report of files that retention policies would delete.

218. **Enhancement: Clearer Separation of "Warnings" vs. "Errors" in Final Summary**
    *   **Goal:** In the final script summary (console and reports), clearly distinguish between issues that are just warnings (job might still be considered usable) and actual errors (job likely failed or data is incomplete/corrupt).
    *   **Description:** The current "WARNINGS" status can sometimes be ambiguous if it includes critical issues.
    *   **Scope & Impact:** `Modules\Managers\FinalisationManager.psm1`, reporting modules. May need more granular status types internally.
    *   **Acceptance Criteria:** Final summary clearly differentiates warning-level issues from error-level issues.

219. **Feature: Simple Backup Job "Cloning" Utility (CLI)**
    *   **Goal:** A CLI command to quickly create a new backup job definition by copying an existing one, allowing the user to then specify a new name and modify it.
    *   **Description:** E.g., `PoSh-Backup.ps1 -CloneJob "MyDocsJob" -NewJobName "MyVideosJob"`. This would add the new job to `User.psd1`.
    *   **Scope & Impact:** `PoSh-Backup.ps1`, new function to read, modify, and save `User.psd1` content.
    *   **Acceptance Criteria:** Users can easily clone existing job definitions as a starting point for new ones.

---

**LIV. Enhanced User Interaction & Guidance (Continued)** (Assuming this is the last category from previous additions, adjust if needed)

220. **Enhancement: `-TestConfig` - Explicit "No Issues Found" Message**
    *   **Goal:** Provide clear positive feedback when configuration validation passes without any issues.
    *   **Description:** If `-TestConfig` completes all its validation checks (basic, schema, dependency, 7-Zip path) and no errors or warnings are generated, it should output a clear, affirmative message like "Configuration Test Passed: All checks completed successfully. No issues found."
    *   **Scope & Impact:** `Modules\ScriptModeHandler.psm1` (logic for `-TestConfig` output).
    *   **Acceptance Criteria:** Users receive unambiguous confirmation when their configuration is valid.

221. **Enhancement: HTML Report - Clickable Section Titles for Toggling**
    *   **Goal:** Improve the usability of collapsible sections in the HTML report.
    *   **Description:** Make the entire `<h2>` title text of each collapsible section (e.g., "Summary", "Detailed Log") clickable to toggle its open/closed state, in addition to the existing `▶`/`▼` icon.
    *   **Scope & Impact:** `Modules\Reporting\Assets\ReportingHtml.Client.js` (minor JavaScript adjustment to add event listener to titles).
    *   **Acceptance Criteria:** Users can click on section titles to expand/collapse them in the HTML report.

**LV. CLI & Operational Enhancements**

223. **Enhancement: `-Verbose` CLI Switch Consistency**
    *   **Goal:** Ensure consistent and intuitive behaviour for PowerShell common parameter `-Verbose`.
    *   **Description:**
        *   `-Verbose`: Consistently enable more detailed operational logging to the console for all relevant operations, complementing file logging.
    *   **Scope & Impact:** `PoSh-Backup.ps1` (parameter handling), review and adjust `Write-LogMessage` calls and other console output throughout all modules to respect these flags.
    *   **Acceptance Criteria:** `-Verbose` provides detailed console operational logs, aligning with standard PowerShell behaviour.

**LVI. Documentation & Developer Guidance**

225. **Refinement: Clarify "Modularise existing files" (Item I.1) Description**
    *   **Goal:** Ensure the intent of ongoing modularisation is clear.
    *   **Description (Updated for TO-DO list item I.1):** "Modularise existing files by grouping logically related functions into distinct modules or sub-modules. The primary goals are to enhance maintainability, improve code clarity, ensure each module has a well-defined responsibility, and keep individual file sizes manageable for both AI-assisted development (reducing truncation issues) and human comprehension. Avoid over-splitting into trivially small files if it does not significantly contribute to these goals. Focus on clear interfaces between modules."
    *   **Scope & Impact:** This is a refinement of an existing TO-DO item's description, guiding future refactoring efforts.
    *   **Acceptance Criteria:** Modularisation efforts follow these clearer guidelines.


### PoSh-Backup: Comprehensive Minor Enhancements `TODO` List
#### **Console Experience & CLI Usability (UX)**

*   **UX:** When running `-ExportDiagnosticPackage`, don't prompt the user to create `User.psd1`.
*   **UX:** When a user makes a typo in a job/set name, suggest the closest valid name (e.g., "Did you mean 'Projects'?").
*   **UX:** Add a `-CompletionNotification` switch that can play a system sound on success or failure, or display a messagebox, or something else.
*   **UX:** In the final summary, show a count of jobs that succeeded, failed, or had warnings.
*   **UX:** When pausing on exit, state the reason (e.g., "Pausing due to 'OnFailure' setting...").
*   **UX:** Add a `-NoBanner` switch to suppress just the initial ASCII art banner without enabling full `-Quiet` mode.
*   **UX:** When `-Quiet` is used, the final summary should still print, but only the one-line status and duration.
*   **UX:** Add a progress bar for the individual file copy operation in the `UNC.Target.psm1` provider for very large files.
*   **UX:** In interactive job selection menu, display job descriptions next to job names if they exist.
*   **UX:** Add a `-ShowConfigPath` switch to print the path(s) to the loaded configuration files and exit.
*   **UX:** When a dependency fails, explicitly list which subsequent jobs were skipped as a direct result.
*   **UX:** Add a `-Minimal` output switch that only shows banners, final status, and errors.
*   **UX:** When using `-GetEffectiveConfig`, display the source of the setting (e.g., "Global", "Set", "Job", "CLI").
*   **UX:** Add a `-ListPins` command to show all currently pinned archives for a given job or destination.
*   **UX:** The `-PinBackup` command should support wildcards to pin multiple archives at once.
*   **UX:** When a job is disabled, show its name in gray in the `-ListBackupLocations` output.
*   **UX:** The interactive menu should have a "Run All" option.
*   **UX:** The `-ForceRunInMaintenanceMode` switch should produce a prominent warning in the log.
*   **UX:** Add a `-RunSet` and `-BackupLocationName` argument completer for the `-SkipJob` parameter.

#### **Reporting & Logging**

*   **Reporting:** Add the computer name to the default report filenames (e.g., `JobName_ComputerName_Timestamp.html`).
*   **Reporting:** Add a direct link to the generated log file (if file logging is enabled) in the HTML report footer.
*   **Reporting:** Make the log level filter checkbox states (`DEBUG`, `INFO`, etc.) in the HTML report persist between page loads using `localStorage`.
*   **Reporting:** Add a "Copy Configuration" button to the HTML report to easily copy the key-value pairs of the job config.
*   **Reporting:** Add the total size of all backup files (for the current job) to the HTML report summary.
*   **Reporting:** In the HTML report, display the `Description` field for the job in the Summary section.
*   **Reporting:** The HTML report's `<title>` tag should lead with the job name for better browser tab identification.
*   **Reporting:** Add a "Copy Shareable Link" button to the HTML report that creates a link with a hash to a specific log line.
*   **Reporting:** In the text report, add a "TABLE OF CONTENTS" at the top.
*   **Reporting:** For CSV reports, generate a single manifest CSV that lists all other CSV files created for that run.
*   **Reporting:** The JSON report should include a top-level key for the script version it was generated with.
*   **Reporting:** Add a `TotalFilesBackedUp` count to the summary data and reports.
*   **Reporting:** In the HTML report, make the table headers "sticky" so they stay visible when scrolling through long tables.
*   **Reporting:** Add a "Print Report" button to the HTML report that triggers the browser's print dialogue.
*   **Reporting:** Add a "Time to First Byte" metric to remote target transfer reports.
*   **Reporting:** Log the PowerShell version (`$PSVersionTable`) at the start of every log file.
*   **Reporting:** In the HTML report, the search keyword should be highlighted in the log timestamp/level as well as the message.
*   **Logging:** Add a specific log level for retention actions to make them easier to filter.
*   **Logging:** When a file is deleted by retention, log its size.
*   **Logging:** Log the calculated checksum of a local archive *before* it is transferred to a remote target.
*   **Logging:** Add an option to log to the Windows Event Log in addition to a text file.
*   **Logging:** When a VSS shadow is created, log its unique ID.
*   **Logging:** When `-Quiet` is active, still log `ERROR` level messages to the console.
*   **Logging:** Add a `-LogToHost` parameter to force all log levels to the console, overriding `-Quiet`.

#### **Configuration & Job Control**

*   **Config:** Add a `-RetentionConfirmDelete` CLI switch to override the configuration setting for a single run.
*   **Config:** Allow `TargetNames` to be defined at the `BackupSets` level, applying to all jobs within that set.
*   **Config:** Add `PreSetScriptPath` and `PostSetScriptPath` hooks to `BackupSets`.
*   **Config:** Allow a job to have a `DependsOnSets` key to make an entire set a prerequisite.
*   **Config:** Add a global `ExcludePaths` array in the config that applies to all backup jobs.
*   **Config:** Add a `-SkipJobDependencies` switch to run a job without running its prerequisites.
*   **Config:** Add a `-SkipPostRunAction` switch to prevent any post-run system action for the current run.
*   **Config:** Allow a job to specify a `RetentionProfile` by name, defined in a new global `RetentionProfiles` section.
*   **Config:** Add support for a `-ConfigFile` parameter that accepts an array of paths, merging them in order.
*   **Config:** In `VerificationJobs`, add a `TargetRemoteName` key to allow verifying a backup on a remote target.

#### **Minor Features & Enhancements**

*   **Feature:** Add a `-GetLastBackupPath <JobName>` switch that finds and prints the full path to the most recent archive for a given job.
*   **Feature:** Add a `-GetTotalSize <JobName>` switch that calculates and displays the total disk space used by all archives for a given job.
*   **Feature:** Add a `-scs` (character set) switch to the 7-Zip arguments, configurable per-job, for specifying archive comment character sets (e.g., `-scsUTF-8`).
*   **Enhancement:** In the `UNC.Target.psm1` module, add a simple retry loop around the `Copy-Item` command to handle transient network errors.
*   **Enhancement:** Add a `-TestHook <FilePath>` utility switch that runs a specified script with dummy parameters to validate that it's executable.
*   **Enhancement:** The `-PinBackup` command should automatically find the base archive name if a user provides the path to a `.002` volume part.
*   **Enhancement:** Allow `Test-BackupTarget` to test all defined targets if no specific name is given.
*   **Enhancement:** When creating an SFX, log which specific `.sfx` module file (e.g., `7zCon.sfx`) was used.
*   **Enhancement:** Add a `-ClearRemoteTarget <TargetName>` utility to delete all backups from a specific remote target (with confirmation).
*   **Enhancement:** Add a `-BackupConfig` switch to create a quick backup of just the `Config` directory.
*   **Enhancement:** The `-ExportDiagnosticPackage` should include a list of all running processes.
*   **Enhancement:** The `SystemStateManager` should log which user initiated the shutdown/restart action.

#### **Robustness & Error Handling**

*   **Robustness:** When `Initialize-RemotePathInternal` fails, include the specific user account it was running as in the error message.
*   **Robustness:** At script startup, check for write permissions on the configured `LogDirectory` and warn the user if permissions are insufficient.
*   **Robustness:** The `-ExportDiagnosticPackage` should gracefully handle a missing `Logs` or `Config` directory.
*   **Robustness:** Add a timeout to the `Invoke-WebRequest` calls in the `WebDAV.Target` provider.
*   **Robustness:** The script should gracefully handle a read-only configuration file.
*   **Robustness:** Add a check for extremely long file paths and warn the user if they might exceed system limits.
*   **Robustness:** If a VSS snapshot fails, the error message should include the VSS error code.
*   **Robustness:** The `ScheduleManager` should validate that the `RunAsUser` account has "Log on as a batch job" rights.
*   **Robustness:** When a circular dependency is detected, list the full chain of jobs that form the loop.
*   **Robustness:** If `User.psd1` is malformed and cannot be parsed, the script should warn the user and proceed with just `Default.psd1`.
