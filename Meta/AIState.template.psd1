@{
  bundle_generation_time          = "__BUNDLE_GENERATION_TIME_PLACEHOLDER__"
  bundler_script_version          = "__BUNDLER_VERSION_PLACEHOLDER__" # Populated by bundler

  ai_development_watch_list       = @(
    "CRITICAL (AI): ENSURE FULL, UNTRUNCATED FILES ARE PROVIDED WHEN REQUESTED. EXTREME VIGILANCE AND A CHANGE IN AI STRATEGY REQUIRED.",
    "CRITICAL (AI): VERIFY LINE COUNTS AND COMMENT INTEGRITY. EXTREME VIGILANCE REQUIRED.",
    "CRITICAL (AI): Ensure no extraneous trailing whitespace.",
    "CRITICAL (AI): When modifying existing files, EXPLICITLY CONFIRM THE BASELINE VERSION/CONTENT. If errors persist, switch to diffs/patches or manual user changes.",
    "CRITICAL (AI STRATEGY): When a fix causes a regression or a similar error, STOP. Perform a deeper root cause analysis instead of iterative, surface-level fixes. The scheduling and notification features are key examples of this failure.",
    "CRITICAL (SYNTAX - ScheduledTasks): The `ScheduledTasks` module was BUGGY and has specific requirements:",
    "  - **RandomDelay:** The `-RandomDelay` parameter on `New-ScheduledTaskTrigger` is broken. The ONLY reliable method is to create the task definition *without* the delay, use `Export-ScheduledTask` to get the XML, manually inject the ISO 8601 string (e.g., `<RandomDelay>PT15M</RandomDelay>`), and then register the task using `Register-ScheduledTask -Xml`.",
    "  - **Finding Tasks:** `Get-ScheduledTask -TaskName 'MyTask' -TaskPath '\MyFolder'` is UNRELIABLE. The correct method is to get all tasks in the folder using a wildcard (`Get-ScheduledTask -TaskPath '\MyFolder\*'`) and then filter the results in PowerShell.",
    "  - **Deleting Tasks:** `Unregister-ScheduledTask` is also unreliable with `-TaskName` and `-TaskPath`. The correct method is to pass the task object directly using `-InputObject`.",
    "  - **Folder Existence:** `Get-ScheduledTaskFolder` is not universally available. The correct, compatible way to check for/create a folder is to use the `Schedule.Service` COM object.",
    "CRITICAL (SYNTAX - Hyper-V): The `Checkpoint-VM` cmdlet can be ambiguous. Use the `-VMName` parameter set (e.g., `Checkpoint-VM -VMName 'MyVM' -Name 'MyCheckpoint'`) for better compatibility instead of passing the full VM object (`-VM <object>`). The `-SnapshotMode` parameter does not exist.",
    "CRITICAL (SYNTAX - Hyper-V): The `Mount-VHD` cmdlet may not have a `-LiteralPath` parameter on all systems. Use the standard `-Path` parameter for compatibility.",
    "CRITICAL (SYNTAX): PowerShell 5.1 does not support inline if-statements like `$var = if (`$condition) { 'true' } else { 'false' }`. Use a standard multi-line if/else block to assign the variable before using it, especially inside here-strings or complex command arguments.",
    "CRITICAL (SYNTAX): PowerShell does not have a ternary operator (`condition ? true : false`). Use `if/else` statements or hashtable lookups.",
    "CRITICAL (SYNTAX): PowerShell logical AND is `-and`, not `&&`.",
    "CRITICAL (SYNTAX): PowerShell strings for Markdown triple backticks: use single quotes externally, e.g., ''''''.",
    "CRITICAL (SYNTAX): Escaping in PowerShell here-strings for JavaScript (e.g., `$`, `${}`) requires care.",
    "CRITICAL (SYNTAX): `-replace` operator replacement strings with special chars need single quotes.",
    "CRITICAL (SYNTAX - PSD1/Strings): Avoid `$(...)` in PSD1 strings if variables/properties might be null. Use formatting or pre-resolution.",
    "CRITICAL (PSD1_PARSING): `Import-PowerShellDataFile` can fail on double-quoted strings with backtick-escaped `\$`. Use single quotes or rephrase.",
    "AI STRATEGY (ACCURACY): When providing full files, state estimated line count difference and mention significant refactoring.",
    "AI STRATEGY (OUTPUT): Provide one file at a time unless small & related (confirm with user).",
    "STRUCTURE: Respect modular design (Core, Managers, Utilities, Operations, etc.). `Write-LogMessage` is now in `Managers\\LogManager.psm1`.",
    "SCOPE: Global color/status map variables in `PoSh-Backup.ps1` (now initialised by `InitialisationManager.psm1`) must be accessible for `Write-LogMessage` (via `Utils.psm1` facade from `Managers\\LogManager.psm1`).",
    "SYNTAX (PSSA): `$null` should be on the left side of equality comparisons (e.g., `if (`$null -eq `$variable)`).",
    "SYNTAX (PSSA): Ensure all functions use approved PowerShell verbs (e.g., Invoke-, Get-, Set-).",
    "MODULE_SCOPE (IMPORTANT): Functions from modules imported by a 'manager' or 'orchestrator' module are not automatically available to other modules called by that manager/orchestrator, nor to the script that called the manager. The module needing the function must typically import the provider of that function directly, or the calling script must import modules whose functions it will call directly after the manager/orchestrator returns. Using `-Global` on imports is a workaround but generally less desirable.",
    "CRITICAL (MODULE_STATE): Module-scoped variables (e.g., `$Script:MyVar`) are NOT shared across different imports of the same module within a single script run. If state must be maintained (like tracking active snapshot sessions), use a global variable (`$Global:MyVar`) and ensure its name is unique to the module's purpose.",
    "SYNTAX (CMDLET BEHAVIOR): Cmdlets that create or modify objects (e.g., Checkpoint-VM, New-ScheduledTaskTrigger) may not return the object by default. Always check if a -Passthru switch is needed to capture the result in a variable."
  )

  conversation_summary            = @(
    "--- Project Overview & Status ---",
    "Development of a comprehensive, modular PowerShell backup solution (PoSh-Backup v1.39.0).",
    "The project is heavily modularised into `Core`, `Managers`, `Utilities`, `Operations`, `Reporting`, and `Targets`.",
    "Bundler script `Generate-ProjectBundleForAI.ps1` (v__BUNDLER_VERSION_PLACEHOLDER__) is used to maintain session context.",
    "",
    "--- Refactor: Lazy Loading & Performance (Completed) ---",
    "   - Goal: Significantly improve script startup time by loading modules on demand.",
    "   - **Diagnosis:** The previous eager-loading strategy in `CoreSetupManager` and other facades caused a noticeable delay on every run.",
    "   - **Implementation:**",
    "     - Refactored `CoreSetupManager` to only load modules essential for configuration and utility modes.",
    "     - All other orchestrator/facade modules (`JobOrchestrator`, `FinalisationManager`, `ScriptModeHandler`, `7ZipManager`, `VssManager`, `RetentionManager`, `NotificationManager`, `PasswordManager`, `ScheduleManager`, and all Target Providers) were modified to lazy-load their sub-modules/dependencies just-in-time within `try/catch` blocks.",
    "   - **Result:** Drastically reduced startup time for simple operations like `-ListJobs` or `-TestConfig`, as operational modules are no longer loaded unless a full backup run is initiated.",
    "",
    "--- Feature: Actionable Advice & Enhanced Error Handling (Completed) ---",
    "   - Goal: Improve user experience by providing clear, actionable advice for common configuration errors and environmental issues.",
    "   - New Log Level: Added a new 'ADVICE' log level with a distinct colour (`DarkCyan`) to `InitialisationManager.psm1` to make suggestions stand out.",
    "   - Implemented in many areas, including: missing admin rights, locked secret vaults, missing dependencies/executables, SFTP host key errors, and numerous configuration warnings (missing paths, circular dependencies, invalid values).",
    "   - This initiative makes the script significantly easier to troubleshoot and configure correctly.",
    "",
    "--- Refactor: Modularise GCS.Target.psm1 (Completed) ---",
    "   - Goal: Decompose the GCS target provider into a facade and specialised sub-modules, aligning it with other target providers.",
    "   - `GCS.Target.psm1` (v1.0.0 -> v2.0.2) refactored into a facade orchestrating calls to new sub-modules for dependency checking, authentication, transfer, retention, validation, and connectivity testing.",
    "",
    "--- Refactor: Modularise ReportingHtml.psm1 (Completed) ---",
    "   - Goal: Decompose the large `ReportingHtml.psm1` to improve maintainability.",
    "   - `ReportingHtml.psm1` (v2.0.5 -> v3.0.0) refactored into a facade orchestrating calls to new sub-modules for asset loading, HTML fragment generation, and final report assembly.",
    "   - Fixed several bugs during this refactor related to alias exports, string formatting (`-f` operator creating object[]), and regex escaping.",
    "",
    "--- Feature: Parallel Remote Transfers (Completed) ---",
    "   - Goal: Improve performance for jobs with multiple remote targets.",
    "   - `Modules\\Operations\\RemoteTransferOrchestrator\\TargetProcessor.psm1` refactored to use `Start-ThreadJob`.",
    "   - Transfers to multiple targets (e.g., UNC, SFTP, S3) for a single job now run concurrently instead of sequentially.",
    "",
    "--- Feature: Critical Safety & Usability Checks (Completed) ---",
    "   - **Recursive Path Validation:** Added a critical safety check to `PathValidator.psm1` to prevent a job's destination directory from being configured inside its own source path.",
    "   - **Reporting Performance:** Refactored `ReportingTxt.psm1` and `ReportingMd.psm1` to use `System.Text.StringBuilder`, significantly improving performance for jobs with large logs.",
    "",
    "--- Feature: Desktop (Toast) Notifications (Completed) ---",
    "   - Goal: Add a 'Desktop' notification provider for native Windows toast notifications.",
    "   - Implemented a version-aware solution: Native WinRT APIs are used for PowerShell 5.1 (bypassing a parser bug), while the `BurntToast` module is used for PowerShell 7+.",
    "",
    "--- Feature: Resilient UNC Transfers with Robocopy (Completed) ---",
    "   - Goal: Provide a more robust alternative to `Copy-Item` for network transfers.",
    "   - Added `UseRobocopy` (boolean) and a `RobocopySettings` hashtable to the UNC target's configuration to allow for highly customisable transfers.",
    "",
    "--- Feature: Scheduling for Verification Jobs (Completed) ---",
    "   - Goal: Allow automated, scheduled execution of backup verification jobs.",
    "   - Added a 'Schedule' block to the 'VerificationJobs' configuration schema and updated `ScheduleManager.psm1` to process it.",
    "",
    "--- Feature: Pre-Flight Check Mode (Completed) ---",
    "   - Goal: Add a '-PreFlightCheck' mode to validate environmental readiness before a backup.",
    "   - New module `PreFlightChecker.psm1` and sub-modules created to handle the core logic.",
    "",
    "--- Key Architectural Concepts & Patterns ---",
    "   - **Facade Modules:** Key modules like `Utils.psm1`, `ConfigManager.psm1`, `Operations.psm1`, `7ZipManager.psm1`, and `ScriptModeHandler.psm1` act as facades, orchestrating calls to more specialised sub-modules.",
    "   - **Provider Model:** Backup targets (UNC, SFTP, WebDAV, S3, GCS, Replicate), infrastructure snapshots (Hyper-V), and notifications (Email, Webhook, Desktop) are implemented as pluggable providers.",
    "   - **Script Mode Handling:** Non-backup operations (`-ListJobs`, `-TestConfig`, `-PinBackup`, etc.) are delegated to specialised modules under `Modules\ScriptModes\`.",
    "   - **Configuration:** A layered configuration system uses `Default.psd1` for all settings and `User.psd1` for user-specific overrides. A schema (`ConfigSchema.psd1`) is used for advanced validation.",
    "   - **Pester Testing:** Found two successful patterns for testing module functions: **A)** Direct `Import-Module` with careful `$script:` scoping for data and function references. **B)** Copying logic into the `.Tests.ps1` file, dot-sourcing it, and then mocking its dependencies.",
    "",
    "--- Completed Core Features (Stable) ---",
    "   - **Archive Creation:** Standard, multi-volume (split), and self-extracting (SFX) archives.",
    "   - **Archive Management:** Listing contents, extracting files, and pinning/unpinning archives from retention.",
    "   - **7-Zip Control:** CPU affinity, custom temporary directory, include/exclude list files, and granular compression settings.",
    "   - **Data Integrity:** Checksum generation (single file or multi-volume manifest) and optional verification.",
    "   - **Job Control:** Job dependencies/chaining, `Enabled = $false` flag, and configurable action on missing source paths (`FailJob`, `WarnAndContinue`, `SkipJob`).",
    "   - **System Integration:** Post-run system actions (shutdown, restart), integrated scheduling with Windows Task Scheduler, and a global maintenance mode.",
    "   - **Automated Verification:** A framework to automatically restore backups to a sandbox and verify their contents against a generated manifest.",
    "   - **Usability:** CLI tab-completion for job/set names and an interactive job selection menu.",
    "   - **Reporting & Logging:** Multi-format reports (HTML, JSON, CSV, etc.) and robust log file management with automated retention/compression."
  )

  main_script_poSh_backup_version = "1.40.0 # Implemented lazy loading for core operational modules."

  ai_bundler_update_instructions  = @{
    purpose                            = "Instructions for AI on how to regenerate the content of the AI state hashtable by providing the content for 'Meta\\AIState.template.psd1' when requested by the user."
    when_to_update                     = "Only when the user explicitly asks to 'update the bundler script's AI state'."
    example_of_ai_provided_block_start = "# Meta\\AIState.template.psd1"
    output_format_for_ai               = "Provide the updated content for 'Meta\\AIState.template.psd1' as a complete PowerShell data file string, ready for copy-pasting. Ensure strings are correctly quoted and arrays use PowerShell syntax, e.g., `@('item1', 'item2')`. Placeholders like '__BUNDLER_VERSION_PLACEHOLDER__' should be kept as literal strings in the template provided by AI; they will be dynamically replaced by the bundler script."
    reminder_for_ai                    = "When asked to update this state, proactively consider if any recent challenges or frequent corrections should be added to the 'ai_development_watch_list'. The AI should provide the *full content* of the AIState.template.psd1 file, not just a PowerShell 'aiStateVariable = @{...}' block for a .psm1 file."
    fields_to_update_by_ai             = @(
      "ai_development_watch_list",
      "ai_bundler_update_instructions",
      "external_dependencies.executables",
      "external_dependencies.powershell_modules"
    )
    fields_to_be_updated_by_user       = @(
      "external_dependencies.executables (if new external tools are added - AI cannot auto-detect this reliably if path is not hardcoded/standard)"
    )
    example_of_ai_provided_block_end   = "}"
  }

  module_descriptions             = @{
    "__MODULE_DESCRIPTIONS_PLACEHOLDER__" = "This is a placeholder entry that is dynamically populated by the bundler script based on the synopsis of each project file."
  }

  project_root_folder_name        = "__PROJECT_ROOT_NAME_PLACEHOLDER__"
  project_name                    = "PoSh Backup Solution"

  external_dependencies           = @{
    executables        = @(
      "7z.exe (7-Zip command-line tool - path configurable or auto-detected)",
      "powercfg.exe (Windows Power Configuration Utility - for Hibernate check)",
      "rundll32.exe (Windows utility - for Hibernate, Sleep, Lock actions)",
      "shutdown.exe (Windows utility - for Shutdown, Restart, LogOff actions)",
      "robocopy.exe (Windows utility - for resilient UNC transfers)",
      "gcloud.cmd (Google Cloud SDK - for GCS target provider)"
    )
    powershell_modules = @(
      "Posh-SSH (for SFTP target provider)",
      "BurntToast (for Desktop notifications on PowerShell 7+)",
      "AWS.Tools.S3 (for S3-Compatible target provider)",
      "Az.Storage (for Azure Blob target provider)",
      "Hyper-V (for Hyper-V snapshot provider)",
      "Microsoft.PowerShell.SecretManagement (for all credential handling)"
    )
  }
}
