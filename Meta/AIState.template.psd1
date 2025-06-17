@{
  bundle_generation_time          = "__BUNDLE_GENERATION_TIME_PLACEHOLDER__"
  bundler_script_version          = "__BUNDLER_VERSION_PLACEHOLDER__" # Populated by bundler

  ai_development_watch_list       = @(
    "CRITICAL (AI): ENSURE FULL, UNTRUNCATED FILES ARE PROVIDED WHEN REQUESTED. EXTREME VIGILANCE AND A CHANGE IN AI STRATEGY REQUIRED.",
    "CRITICAL (AI): VERIFY LINE COUNTS AND COMMENT INTEGRITY. EXTREME VIGILANCE REQUIRED.",
    "CRITICAL (AI): Ensure no extraneous trailing whitespace.",
    "CRITICAL (AI): When modifying existing files, EXPLICITLY CONFIRM THE BASELINE VERSION/CONTENT. If errors persist, switch to diffs/patches or manual user changes.",
    "CRITICAL (AI STRATEGY): When a fix causes a regression or a similar error, STOP. Perform a deeper root cause analysis instead of iterative, surface-level fixes. The scheduling feature is a key example of this failure.",
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
    "MODULE_SCOPE (IMPORTANT): Functions from modules imported by a 'manager' or 'orchestrator' module are not automatically available to other modules called by that manager/orchestrator, nor to the script that called the manager. The module needing the function must typically import the provider of that function directly, or the calling script must import modules whose functions it will call directly after the manager/orchestrator returns. Using `-Global` on imports is a workaround but generally less desirable.",
    "CRITICAL (MODULE_STATE): Module-scoped variables (e.g., `$Script:MyVar`) are NOT shared across different imports of the same module within a single script run. If state must be maintained (like tracking active snapshot sessions), use a global variable (`$Global:MyVar`) and ensure its name is unique to the module's purpose.",
    "SYNTAX (CMDLET BEHAVIOR): Cmdlets that create or modify objects (e.g., Checkpoint-VM, New-ScheduledTaskTrigger) may not return the object by default. Always check if a -Passthru switch is needed to capture the result in a variable."
  )

  conversation_summary            = @(
    "--- Project Overview & Status ---",
    "Development of a comprehensive, modular PowerShell backup solution (PoSh-Backup v1.29.1).",
    "The project is heavily modularised into `Core`, `Managers`, `Utilities`, `Operations`, `Reporting`, and `Targets`.",
    "Bundler script `Generate-ProjectBundleForAI.ps1` (v__BUNDLER_VERSION_PLACEHOLDER__) is used to maintain session context.",
    "",
    "--- Key Architectural Concepts & Patterns ---",
    "   - **Facade Modules:** Key modules like `Utils.psm1`, `ConfigManager.psm1`, `Operations.psm1`, `7ZipManager.psm1`, and `ScriptModeHandler.psm1` act as facades, orchestrating calls to more specialised sub-modules. This keeps the high-level logic clean and separates concerns.",
    "   - **Provider Model:** Backup targets (UNC, SFTP, WebDAV, S3, Replicate) and infrastructure snapshots (Hyper-V) are implemented as pluggable providers, making the system extensible.",
    "   - **Script Mode Handling:** Non-backup operations (`-ListJobs`, `-TestConfig`, `-PinBackup`, etc.) are delegated to specialised modules under `Modules\ScriptModes\` to keep `PoSh-Backup.ps1` focused on orchestration.",
    "   - **Configuration:** A layered configuration system uses `Default.psd1` for all settings and `User.psd1` for user-specific overrides. A schema (`ConfigSchema.psd1`) is used for advanced validation.",
    "",
    "--- Completed Core Features (Stable) ---",
    "   - **Archive Creation:** Standard, multi-volume (split), and self-extracting (SFX) archives. Split archives override SFX creation.",
    "   - **Archive Management:** Listing contents, extracting files, and pinning/unpinning archives from retention.",
    "   - **7-Zip Control:** CPU affinity, custom temporary directory, include/exclude list files, and granular compression settings.",
    "   - **Data Integrity:** Checksum generation (single file or multi-volume manifest) and optional verification. Optional pre-delete archive testing.",
    "   - **Job Control:** Job dependencies/chaining, `Enabled = $false` flag, and configurable action on missing source paths (`FailJob`, `WarnAndContinue`, `SkipJob`).",
    "   - **System Integration:** Post-run system actions (shutdown, restart), integrated scheduling with Windows Task Scheduler, and a global maintenance mode.",
    "   - **Automated Verification:** A framework to automatically restore backups to a sandbox and verify their contents against a generated manifest.",
    "   - **Notifications:** A provider-based system supporting Email and Webhooks.",
    "   - **Usability:** CLI tab-completion for job/set names and numerous CLI override switches for troubleshooting and control.",
    "   - **Reporting & Logging:** Multi-format reports (HTML, JSON, CSV, etc.) and robust log file management with automated retention/compression.",
    "",
    "--- Important Implementation Patterns & Learnings to Retain ---",
    "   - **Pester Testing:** Found two successful patterns for testing module functions: **A)** Direct `Import-Module` with careful `$script:` scoping for data and function references. **B)** Copying logic into the `.Tests.ps1` file, dot-sourcing it, and then mocking its dependencies (like `Write-LogMessage`). Mocking `Write-LogMessage` is done via a dummy function that gets replaced by `Mock`. This context is critical for future test development.",
    "   - **Hyper-V Snapshots:** This was a complex implementation. **A critical finding was the need to use a `$Global:` variable (`$Global:PoShBackup_SnapshotManager_ActiveSessions`) to track the snapshot session across different module scopes.** A module-scoped `$Script:` variable was insufficient because the cleanup function was called from a different scope than the creation function. This pattern is essential if adding other stateful providers.",
    "   - **Conditional Dependency Checker:** The dependency check in `CoreSetupManager.psm1` was refactored to be context-aware. It runs *after* jobs are resolved and only checks for modules required by the jobs *actually being run*. This prevents errors for users who have not installed optional modules (like `Posh-SSH`) for features they are not using.",
    "   - **Parameter Set Management:** Implementing the various utility modes (`-ListArchiveContents`, `-PinBackup`, etc.) required a significant refactoring of the `param()` block in `PoSh-Backup.ps1` into distinct, mutually exclusive parameter sets (`Execution`, `Pinning`, `Listing`, etc.) to resolve ambiguity.",
    "",
    "--- Current Status ---",
    "The most recent refactoring decomposed the large `CoreSetupManager.psm1` into a facade and several smaller, single-responsibility sub-modules under `Modules\Managers\CoreSetupManager`. This included fixing several module scoping issues related to `Get-ConfigValue` and other functions not being available in the new sub-modules' scopes."
  )

  main_script_poSh_backup_version = "1.29.1 # Pass CheckForUpdate switch to CoreSetupManager."

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
      "Posh-SSH (for SFTP target provider)" # Assuming this is still a direct dependency for SFTP.Target.psm1
      # Microsoft.PowerShell.SecretManagement is a system component, not typically listed as an external module to *bundle*.
    )
  }
}
