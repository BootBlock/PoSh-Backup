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
    "Development of a comprehensive, modular PowerShell backup solution (PoSh-Backup v1.29.4).",
    "The project is heavily modularised into `Core`, `Managers`, `Utilities`, `Operations`, `Reporting`, and `Targets`.",
    "Bundler script `Generate-ProjectBundleForAI.ps1` (v__BUNDLER_VERSION_PLACEHOLDER__) is used to maintain session context.",
    "",
    "Added additional parameters to Write-NameValue; try and make use of them.",
    ""
    "",
    "--- Feature: Desktop (Toast) Notifications (Completed in Previous Session) ---",
    "   - Goal: Add a 'Desktop' notification provider for native Windows toast notifications.",
    "   - Stage 1 (Initial Native API): Attempted to use WinRT APIs directly via `[Windows.UI.Notifications.ToastNotificationManager,...]`. This FAILED in PowerShell 5.1 with a `Cannot find an overload for ToString and the argument count: 1` error due to a known parser bug.",
    "   - Stage 2 (BurntToast Module): Reverted to using the `BurntToast` module. This also FAILED in PowerShell 5.1 because the module internally calls the same buggy WinRT APIs.",
    "   - Stage 3 (Final Hybrid Solution):",
    "     - Implemented version-aware logic in `Modules\\Managers\\NotificationManager.psm1` (v1.4.1).",
    "     - **For Windows PowerShell 5.1:** It now uses `[System.Type]::GetType()` to load WinRT APIs directly, bypassing the parser bug.",
    "     - **For PowerShell 7+:** It uses the `BurntToast` module, which is the standard for modern PowerShell.",
    "     - A one-time setup creates a `PoSh-Backup.lnk` in the Start Menu to register the necessary AppID for notifications.",
    "   - Configured `Config\\Default.psd1` and `ConfigSchema.psd1` to add the 'Desktop' provider.",
    "   - Updated `Modules\\Managers\\CoreSetupManager\\DependencyChecker.psm1` to conditionally require `BurntToast` only when running on PowerShell 7+ and a Desktop profile is in use.",
    "   - Updated `README.md` to document the feature and its conditional dependency.",
    "",
    "--- Feature: Resilient UNC Transfers with Robocopy (Completed in Previous Session) ---",
    "   - Goal: Provide a more robust alternative to `Copy-Item` for network transfers.",
    "   - `Config\\Default.psd1` (v1.9.5 -> v1.9.6): Added `UseRobocopy` (boolean) and a `RobocopySettings` hashtable to the UNC target's `TargetSpecificSettings` to allow for highly customisable transfers.",
    "   - `Modules\\Targets\\UNC.Target.psm1` (v1.3.0 -> v1.4.0):",
    "     - Added internal functions `Build-RobocopyArgumentsInternal` and `Invoke-RobocopyTransferInternal`.",
    "     - `Invoke-PoShBackupTargetTransfer` now conditionally uses Robocopy if `UseRobocopy` is enabled in the target's configuration.",
    "     - `Invoke-PoShBackupUNCTargetSettingsValidation` updated to recognise the new Robocopy keys.",
    "   - `README.md`: Updated to document the new feature, its prerequisites (`Robocopy.exe`), and configuration options.",
    "   - Fixed PSSA warnings for unused `Logger` parameters in `NotificationManager.psm1` and `UNC.Target.psm1`.",
    "",
    "--- Feature: Scheduling for Verification Jobs (Completed in Previous Session) ---",
    "   - Goal: Allow automated, scheduled execution of backup verification jobs.",
    "   - Config\\Default.psd1 (v1.9.5 -> v1.9.6): Added a 'Schedule' block to the example verification job definition.",
    "   - Modules\\ConfigManagement\\Assets\\ConfigSchema.psd1: Updated the schema to validate the new 'Schedule' block within 'VerificationJobs'.",
    "   - PoSh-Backup.ps1 (v1.29.5 -> v1.30.0): Added a new '-VerificationJobName' parameter to allow scheduled tasks to target a single verification job.",
    "   - Modules\\ScriptModeHandler.psm1 (v2.1.0 -> v2.2.0) & Modules\\ScriptModes\\MaintenanceAndVerification.psm1 (v1.0.0 -> v1.1.0): Updated to handle the new '-VerificationJobName' parameter.",
    "   - Modules\\Managers\\ScheduleManager.psm1 (v1.0.8 -> v1.1.1): Significantly refactored to process schedules for both backup and verification jobs and to fix PSScriptAnalyzer warnings.",
    "   - README.md: Updated to document the new feature and its configuration.",
    "",
    "--- Feature: Pre-Flight Check Mode (Current Session) ---",
    "   - Goal: Add a '-PreFlightCheck' mode to validate environmental readiness before a backup.",
    "   - PoSh-Backup.ps1 (v1.30.0 -> v1.31.0): Added the '-PreFlightCheck' parameter and assigned it to a new 'PreFlight' parameter set.",
    "   - Modules\\Managers\\CliManager.psm1 (v1.3.0 -> v1.3.1): Updated to recognise the new parameter.",
    "   - Modules\\Managers\\CoreSetupManager.psm1 (v2.1.2 -> v2.2.0): Updated to accept and pass through the new parameter (includes a bug fix where the parameter was initially missing).",
    "   - Modules\\ScriptModeHandler.psm1 (v2.2.0 -> v2.3.0): Updated to delegate the new mode to the diagnostics sub-module.",
    "   - Modules\\ScriptModes\\Diagnostics.psm1 (v1.2.0 -> v1.3.0): Updated to orchestrate the pre-flight check by calling a new, dedicated checker module.",
    "   - New Module: 'Modules\\ScriptModes\\PreFlightChecker.psm1' (v1.0.0) created to contain the core logic for checking source/destination paths, hook scripts, and remote target connectivity.",
    "   - README.md: Updated to document the new -PreFlightCheck feature and its usage.",
    "",
    "--- Key Architectural Concepts & Patterns ---",
    "   - **Facade Modules:** Key modules like `Utils.psm1`, `ConfigManager.psm1`, `Operations.psm1`, `7ZipManager.psm1`, and `ScriptModeHandler.psm1` act as facades, orchestrating calls to more specialised sub-modules.",
    "   - **Provider Model:** Backup targets (UNC, SFTP, WebDAV, S3, Replicate), infrastructure snapshots (Hyper-V), and notifications (Email, Webhook, Desktop) are implemented as pluggable providers.",
    "   - **Script Mode Handling:** Non-backup operations (`-ListJobs`, `-TestConfig`, `-PinBackup`, etc.) are delegated to specialised modules under `Modules\ScriptModes\`.",
    "   - **Configuration:** A layered configuration system uses `Default.psd1` for all settings and `User.psd1` for user-specific overrides. A schema (`ConfigSchema.psd1`) is used for advanced validation.",
    "",
    "--- UX & Reliability Polish (Current Session) ---",
    "   - Goal: A series of minor enhancements to improve usability and robustness.",
    "   - Feature: Replicate Target 'ContinueOnError':",
    "     - Added a 'ContinueOnError' boolean setting to the Replicate target provider in `Config\\Default.psd1` and `ConfigSchema.psd1`.",
    "     - `Replicate.Target.psm1` was updated to use this setting, allowing it to continue replicating to other destinations even if one fails.",
    "     - This required a refactor of the validation contract in `PoShBackupValidator.psm1` to pass the entire target instance to provider validators, allowing them to see settings outside of `TargetSpecificSettings`.",
    "     - All other target providers (`UNC`, `SFTP`, `S3`, `WebDAV`) were updated to conform to the new validation contract.",
    "   - Feature: Timed User Config Prompt:",
    "     - Added `UserPromptTimeoutSeconds` to `Config\\Default.psd1` and `ConfigSchema.psd1`.",
    "     - `UserConfigHandler.psm1` updated with logic for a timed prompt, preventing hangs in semi-interactive sessions.",
    "   - Feature: Interactive Menu Multi-Select:",
    "     - `JobResolver.psm1` updated to allow selection of multiple comma-separated jobs/sets from the interactive menu.",
    "   - Feature: Job/Set Descriptions:",
    "     - Added an optional `Description` field to `BackupLocations` and `BackupSets` in `Config\\Default.psd1` and `ConfigSchema.psd1`.",
    "     - `Listing.psm1` updated to display these descriptions in the `-ListBackupLocations` and `-ListBackupSets` modes.",
    "   - Bug Fixes:",
    "     - Corrected a parameter set definition error in `PoSh-Backup.ps1` that caused `-VerificationJobName` to incorrectly prompt for `-RunVerificationJobs`.",
    "     - Fixed a regression in `UserConfigHandler.psm1` where the interactive prompt was being incorrectly skipped by using a more reliable check for an interactive host.",
    "     - Fixed a bug in `JobResolver.psm1` where selecting an ad-hoc job from the menu could incorrectly inherit the name and properties of a predefined set.",
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
    "   - **Reporting & Logging:** Multi-format reports (HTML, JSON, CSV, etc.) and robust log file management with automated retention/compression.",
    "",
    "--- Important Implementation Patterns & Learnings to Retain ---",
    "   - **Pester Testing:** Found two successful patterns for testing module functions: **A)** Direct `Import-Module` with careful `$script:` scoping for data and function references. **B)** Copying logic into the `.Tests.ps1` file, dot-sourcing it, and then mocking its dependencies.",
    "   - **Hyper-V Snapshots:** A critical finding was the need to use a `$Global:` variable (`$Global:PoShBackup_SnapshotManager_ActiveSessions`) to track the snapshot session across different module scopes.",
    "   - **Conditional Dependency Checker:** The dependency check in `CoreSetupManager.psm1` is context-aware. It runs *after* jobs are resolved and only checks for modules required by the jobs *actually being run*.",
    "   - **Interactive Job/Set Selection:** When no job or set is specified via CLI, PoSh-Backup now displays a user-friendly, two-column menu of available jobs and sets. This is accomplished via `Modules\ConfigManagement\JobResolver.psm1`."
  )

  main_script_poSh_backup_version = "1.32.0 # Added RunOnlyIfPathExists to config"

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
      "shutdown.exe (Windows utility - for Shutdown, Restart, LogOff actions)"
    )
    powershell_modules = @(
      "Posh-SSH (for SFTP target provider)",
      "BurntToast (for Desktop notifications on PowerShell 7+)",
      "AWS.Tools.S3 (for S3-Compatible target provider)"
    )
  }
}
