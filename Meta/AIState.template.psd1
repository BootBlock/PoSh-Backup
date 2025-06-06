@{
  bundle_generation_time          = "__BUNDLE_GENERATION_TIME_PLACEHOLDER__"
  bundler_script_version          = "__BUNDLER_VERSION_PLACEHOLDER__" # Populated by bundler

  ai_development_watch_list       = @(
    "CRITICAL (AI): ENSURE FULL, UNTRUNCATED FILES ARE PROVIDED WHEN REQUESTED. EXTREME VIGILANCE AND A CHANGE IN AI STRATEGY REQUIRED.",
    "CRITICAL (AI): VERIFY LINE COUNTS AND COMMENT INTEGRITY. EXTREME VIGILANCE REQUIRED.",
    "CRITICAL (AI): Ensure no extraneous trailing whitespace.",
    "CRITICAL (AI): When modifying existing files, EXPLICITLY CONFIRM THE BASELINE VERSION/CONTENT. If errors persist, switch to diffs/patches or manual user changes.",
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
    "PESTER (v5.7.1 Environment - Key Learnings & Workarounds):",
    "  - **Pattern A: Testing ACTUAL IMPORTED Module Functions (e.g., for `ConfigUtils.Tests.ps1`):**",
    "    1. `BeforeAll`: `Import-Module Utils.psm1` (the facade). Get command reference: `$script:FuncRef = Get-Command Utils\\MyFunction`.",
    "    2. `BeforeEach` (in `Context`): Set up test data using `$script:` scope: `$script:testData = @{...}`.",
    "    3. `It`: Call `& `$script:FuncRef -Parameter `$script:testData`. This pattern *now works* for `Get-ConfigValue`.",
    "  - **Pattern B: Testing LOCAL COPIES of Function Logic (e.g., for `FileUtils.Tests.ps1`):**",
    "    1. Top-level of `.Tests.ps1`: Define dummy functions and local copies of functions under test.",
    "    2. `BeforeAll`: Dot-source self, mock dependencies, get `$script:` references to local test functions.",
    "    3. `It` blocks: Call local functions via `$script:` reference. Local functions call mocked dependencies directly. Assert mock calls (`Should -Invoke`). For external cmdlets like `Get-FileHash`, make them injectable `[scriptblock]` parameters in local test functions.",
    "  - **General Pester 5 Notes for This Environment:** `Import-Module` + `Get-Command` + `$script:`-scoped data is key for Pattern A. `$MyInvocation.MyCommand.ScriptBlock.File` for self dot-sourcing. `(`$result.GetType().IsArray) | Should -Be `$true` for array assertion. Clear shared mock log arrays in `BeforeEach` if used. PSSA `PSUseDeclaredVarsMoreThanAssignments` and `$var = `$null` interaction.",
    "MODULE_SCOPE (IMPORTANT): Functions from modules imported by a 'manager' or 'orchestrator' module are not automatically available to other modules called by that manager/orchestrator, nor to the script that called the manager. The module needing the function must typically import the provider of that function directly, or the calling script must import modules whose functions it will call directly after the manager/orchestrator returns. Using `-Global` on imports is a workaround but generally less desirable."
  )

  conversation_summary            = @(
    "Development of a comprehensive PowerShell file backup solution (PoSh-Backup.ps1 v1.18.0).",
    "Modular design: Core (Modules\\Core\\), Managers (Modules\\Managers\\), Utilities (Modules\\Utilities\\), Operations (Modules\\Operations\\), ConfigManagement (Modules\\ConfigManagement\\), Reporting (Modules\\Reporting\\), Targets (Modules\\Targets\\).",
    "AI State structure loaded from 'Meta\\AIState.template.psd1', dynamically populated by Bundler (v__BUNDLER_VERSION_PLACEHOLDER__).",
    "--- CLI Usability Enhancements (Completed in Previous Session Segment) ---",
    "    - **Goal:** Add several command-line switches to improve usability and troubleshooting.",
    "    - **Feature: -Version Switch**",
    "        - `PoSh-Backup.ps1` (v1.18.0 -> v1.19.0): Added `-Version` parameter and help text.",
    "        - `Modules\\Managers\\CoreSetupManager.psm1`: Updated to pass the switch.",
    "        - `Modules\\ScriptModeHandler.psm1`: Added logic to display the script version and exit.",
    "    - **Feature: -Quiet Switch**",
    "        - `PoSh-Backup.ps1` (v1.19.0 -> v1.20.0): Added `-Quiet` parameter and set a `$Global:IsQuietMode` flag.",
    "        - `Modules\\Managers\\LogManager.psm1`: `Write-LogMessage` updated to suppress non-error console output when quiet mode is active.",
    "        - `Modules\\Utilities\\ConsoleDisplayUtils.psm1`: `Write-ConsoleBanner` updated to respect quiet mode.",
    "        - `Modules\\Managers\\InitialisationManager.psm1`: Updated to suppress author info block in quiet mode.",
    "    - **Feature: Troubleshooting Toggles**",
    "        - `PoSh-Backup.ps1` (v1.20.0 -> v1.21.0): Added `-SkipVSS` and `-SkipRetriesCLI` parameters.",
    "        - `Modules\\Managers\\CliManager.psm1`: Updated to recognize the new switches.",
    "        - `Modules\\ConfigManagement\\EffectiveConfigBuilder\\OperationalSettings.psm1`: Updated to implement the override logic for the new switches.",
    "        - `README.md`: Updated to document the new switches.",
    "--- Modularisation of PoSh-Backup.ps1 (Completed in Previous Session Segment) ---",
    "    - Goal: Reduce the size and complexity of `PoSh-Backup.ps1` by extracting logical blocks into new manager modules.",
    "    - **Phase 1: CLI Override Processing**",
    "        - New Module `Modules\\Managers\\CliManager.psm1` (v1.0.0) created.",
    "            - Contains `Get-PoShBackupCliOverride` function to process `$PSBoundParameters` from `PoSh-Backup.ps1` and return the `$cliOverrideSettings` hashtable.",
    "        - `PoSh-Backup.ps1` (v1.14.6 -> v1.15.0):",
    "            - Imports `CliManager.psm1`.",
    "            - Calls `Get-PoShBackupCliOverride` to populate `$cliOverrideSettings`.",
    "            - Removed manual definition of `$cliOverrideSettings` hashtable.",
    "    - **Phase 2: Initial Script Setup (Globals, Banner)**",
    "        - New Module `Modules\\Managers\\InitialisationManager.psm1` (v1.0.0) created.",
    "            - Contains `Invoke-PoShBackupInitialSetup` function to:",
    "                - Define global colour variables (e.g., `$Global:ColourInfo`).",
    "                - Define global status-to-colour map (`$Global:StatusToColourMap`).",
    "                - Initialise global logging variables (e.g., `$Global:GlobalLogFile`).",
    "                - Display the starting script banner (including dynamic version extraction).",
    "        - `PoSh-Backup.ps1` (v1.15.0 -> v1.16.0):",
    "            - Imports `InitialisationManager.psm1`.",
    "            - Calls `Invoke-PoShBackupInitialSetup` at the beginning.",
    "            - Removed the corresponding global variable definitions and banner logic.",
    "    - **Phase 3: Core Setup (Module Imports, Config Load, Job Resolution)**",
    "        - New Module `Modules\\Managers\\CoreSetupManager.psm1` (v1.0.0, then to v1.0.2) created.",
    "            - Contains `Invoke-PoShBackupCoreSetup` function to:",
    "                - Import the bulk of core and manager modules (ConfigManager, Operations, Reporting, various Managers, etc.).",
    "                - Load and validate application configuration (calling `Import-AppConfiguration`).",
    "                - Handle informational script modes (calling `Invoke-PoShBackupScriptMode`).",
    "                - Validate 7-Zip path.",
    "                - Initialise global file logging variables based on config.",
    "                - Resolve jobs to process (calling `Get-JobsToProcess`).",
    "                - Build final job execution order (calling `Build-JobExecutionOrder`).",
    "                - Returns key results like `$Configuration`, `$jobsToProcess`, etc.",
    "        - `PoSh-Backup.ps1` (v1.16.0 -> v1.17.0):",
    "            - Imports `CoreSetupManager.psm1`.",
    "            - Calls `Invoke-PoShBackupCoreSetup` and receives necessary variables.",
    "            - Removed the corresponding blocks of logic.",
    "        - Addressed module scope issues where `Find-SevenZipExecutable` (from `7ZipManager` via `Discovery.psm1`) was not found by `SevenZipPathResolver.psm1`. Resolved by having `SevenZipPathResolver.psm1` explicitly import `7ZipManager.psm1`.",
    "        - Addressed module scope issues where `Invoke-PoShBackupRun` (from `JobOrchestrator.psm1`) and `Invoke-PoShBackupPostRunActionHandler` (from `PostRunActionOrchestrator.psm1`) were not found by `PoSh-Backup.ps1`. Resolved by having `PoSh-Backup.ps1` explicitly import these two modules after `CoreSetupManager.psm1` has run. Also ensured `JobOrchestrator.psm1` imports `ConfigManager.psm1` and `Reporting.psm1`.",
    "    - **Phase 4: Finalisation (Summary, Pause, Exit)**",
    "        - New Module `Modules\\Managers\\FinalisationManager.psm1` (v1.0.0) created.",
    "            - Contains `Invoke-PoShBackupFinalisation` function to:",
    "                - Display completion banner.",
    "                - Log final script statistics.",
    "                - Call `Invoke-PoShBackupPostRunActionHandler` (from `PostRunActionOrchestrator.psm1`, which `FinalisationManager.psm1` now imports).",
    "                - Handle pause behaviour.",
    "                - Exit with appropriate status code.",
    "        - `PoSh-Backup.ps1` (v1.17.1 -> v1.18.0):",
    "            - Imports `FinalisationManager.psm1`.",
    "            - Calls `Invoke-PoShBackupFinalisation` at the end.",
    "            - Removed the corresponding finalisation logic.",
    "        - Addressed syntax error in `PoSh-Backup.ps1` call to `Invoke-PoShBackupFinalisation` for the `-JobNameForLog` parameter (missing `$()` for subexpression).",
    "--- PREVIOUS MAJOR FEATURES (Summary from prior state) ---", # Ensure this is above the new section if it exists
    "  - Update Checking and Self-Application Framework (Meta\\Version.psd1, Utilities\\Update.psm1, Meta\\apply_update.ps1, Meta\\Package-PoShBackupRelease.ps1).",
    "  - Pester Testing - Phase 1: Utilities (ConfigUtils.Tests.ps1, FileUtils.Tests.ps1 established patterns; SystemUtils.Tests.ps1 was next).",
    "  - Multi-Volume (Split) Archives, Job Chaining/Dependencies, 7-Zip Password Handling (-p switch), Include/Exclude List Files, CPU Affinity.",
    "  - Core Refactorings (Operations, Logging, Managers, Utils facade, PoSh-Backup.ps1 main loop to JobOrchestrator, ScriptModeHandler).",
    "  - SFX Archives, Checksums, Post-Run Actions, Expanded Backup Targets (UNC, Replicate, SFTP), Log File Retention.",
    "--- Feature: Disable Job Flag (Completed in Previous Session Segment) ---",
    "    - Goal: Allow individual jobs to be disabled via an 'Enabled = $false' flag in configuration.",
    "    - `Config\\Default.psd1`: Added `Enabled = $true` (boolean) to example job definitions.",
    "    - `Modules\\ConfigManagement\\Assets\\ConfigSchema.psd1`: Added `Enabled` key (boolean, optional) to the job schema.",
    "    - `Modules\\ConfigManagement\\JobResolver.psm1`: Modified `Get-JobsToProcess` to filter out jobs where `Enabled` is `$false` during job/set resolution.",
    "    - `Modules\\Managers\\JobDependencyManager.psm1`:",
    "        - `Build-JobExecutionOrder` now skips initially specified disabled jobs.",
    "        - `Test-PoShBackupJobDependencyGraph` now flags dependencies on disabled jobs as errors.",
    "    - `Modules\\Core\\JobOrchestrator.psm1`: Modified `Invoke-PoShBackupRun` to perform a final check and skip execution of disabled jobs, generating a minimal 'SKIPPED_DISABLED' report.",
    "    - Resolved 'Get-ConfigValue not recognized' error in `JobDependencyManager.psm1` by adding a direct `Import-Module Utils.psm1`.",
    "--- Feature: Backup Target Provider - WebDAV (Completed in Previous Session Segment) ---",
    "    - Goal: Add support for transferring backups to WebDAV shares, including remote retention.",
    "    - `Modules\\Targets\\WebDAV.Target.psm1` (v0.1.0 -> v0.2.0):",
    "        - Added internal helper function `Group-RemoteWebDAVBackupInstancesInternal` to list and group backup instances from the WebDAV server using `PROPFIND` and parsing the XML response.",
    "        - `Invoke-PoShBackupTargetTransfer` modified to:",
    "            - Call `Group-RemoteWebDAVBackupInstancesInternal` after successful uploads if retention is configured (`RemoteRetentionSettings.KeepCount`).",
    "            - Determine which instances to delete based on `KeepCount`.",
    "            - Use the `DELETE` WebDAV method to remove files belonging to instances marked for deletion.",
    "            - Respect simulation mode for retention operations.",
    "        - `Initialize-WebDAVRemotePathInternal` improved to better handle PROPFIND checks before MKCOL.",
    "    - `Config\\Default.psd1`: No changes in this segment (WebDAV example was added previously).",
    "    - `Modules\\ConfigManagement\\Assets\\ConfigSchema.psd1`: No changes in this segment (WebDAV type was added previously).",
    "    - `Modules\\PoShBackupValidator.psm1`: No direct code changes needed due to dynamic validation (WebDAV validation function was added previously).",
    "    - `README.md`: Updated to reflect that WebDAV remote retention is now implemented.",
    "    - User reported syntax errors in `WebDAV.Target.psm1` v0.2.0 (around line 146 in `Initialize-WebDAVRemotePathInternal` for logging PROPFIND status/error) which were manually corrected by the user."
    "--- Feature: Conditional Dependency Checker (Completed in Previous Session Segment) ---",
    "    - **Goal:** Prevent the script from failing if an optional external module (like `Posh-SSH`) is missing but the feature requiring it (like an SFTP target) is not being used in the current run.",
    "    - **Attempt 1 (Unconditional):** A dependency check was added to `CoreSetupManager.psm1` that checked for all potential dependencies at startup. This failed for users who did not have `Posh-SSH` installed, regardless of their configuration.",
    "    - **Attempt 2 (Config-Aware):** The checker was modified to only look for dependencies if a corresponding feature (e.g., a target of type 'SFTP') was defined anywhere in the configuration. This was still too aggressive, as the default config file includes an SFTP example, forcing new users to edit the file to run the script.",
    "    - **Final Implementation (Context-Aware):** The dependency check in `CoreSetupManager.psm1` (v1.1.2) was moved to run *after* the configuration is loaded and the specific jobs for the current run are resolved. The check is now passed the list of active jobs and only validates dependencies that are actually required by those jobs.",
    "    - **Documentation:** Added detailed comments within `CoreSetupManager.psm1` explaining the new pattern and how to add future conditional dependency checks.",
    "    - **Status:** The feature is now working as intended, providing a robust and user-friendly dependency validation experience.",
    "--- Feature: Pin Backup on Creation (Current Session Segment) ---",
    "    - **Goal:** Allow a user to pin a backup at creation time, either via a CLI switch or a per-job configuration setting.",
    "    - **Configuration:**",
    "        - `Config\Default.psd1`: Added `PinOnCreation = $false` (boolean) to the example job definitions.",
    "        - `Modules\ConfigManagement\Assets\ConfigSchema.psd1`: Updated the job schema to include the optional `PinOnCreation` boolean key.",
    "    - **CLI Parameters & Logic:**",
    "        - `PoSh-Backup.ps1`: Added a new `-Pin` switch. Defined `Execution` and `Pinning` Parameter Sets to resolve ambiguity between running a job and managing an existing pin.",
    "        - `Modules\Managers\CliManager.psm1`: Updated to recognise the new `-Pin` switch.",
    "        - `Modules\ConfigManagement\EffectiveConfigBuilder\OperationalSettings.psm1`: Updated to resolve the final `PinOnCreation` setting, giving the `-Pin` CLI switch precedence over the job configuration.",
    "    - **Core Implementation:**",
    "        - `Modules\Operations\LocalArchiveProcessor.psm1`: After a successful archive creation, it now checks the effective `PinOnCreation` flag. If true, it calls `Add-PoShBackupPin` to create the `.pinned` marker file.",
    "        - `Modules\Managers\PinManager.psm1`: The `Add-PoShBackupPin` function was made more robust to handle file creation errors and now writes descriptive, human-readable content to the `.pinned` file.",
    "    - **Bug Fix:** Resolved an issue where using `-PinBackup` or `-UnpinBackup` would fail because the script was trying to resolve a backup job to run. Corrected the order of operations in `CoreSetupManager.psm1` to handle these informational/management modes before attempting job resolution.",
    "--- PROJECT STATUS ---",
    "Overall: PoSh-Backup.ps1 significantly modularised. Core local/remote backup stable. A comprehensive Backup Pinning feature (for existing archives and on-creation) is now implemented. The dependency checker is now context-aware, improving startup robustness. PSSA warnings: 2 known for SFTP.Target.psm1 (ConvertTo-SecureString)."
  )

  main_script_poSh_backup_version = "1.22.0 # Added -Pin switch and explicit parameter sets."

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
    "__MODULE_DESCRIPTIONS_PLACEHOLDER__" = "This is a placeholder entry." # Dynamically populated
    # Descriptions for new modules will be added here by the bundler based on their synopsis
    "Modules\\Managers\\CliManager.psm1" = "Manages Command-Line Interface (CLI) parameter processing for PoSh-Backup."
    "Modules\\Managers\\InitialisationManager.psm1" = "Manages the initial setup of global variables and console display for PoSh-Backup."
    "Modules\\Managers\\CoreSetupManager.psm1" = "Manages the core setup phase of PoSh-Backup, including module imports, configuration loading, job resolution, and dependency ordering."
    "Modules\\Managers\\FinalisationManager.psm1" = "Manages the finalisation tasks for the PoSh-Backup script, including summary display, post-run action invocation, pause behaviour, and exit code."
    "Modules\\Targets\\WebDAV.Target.psm1" = "PoSh-Backup Target Provider for WebDAV (Web Distributed Authoring and Versioning). Handles transferring backup archives to WebDAV servers, managing remote retention (PROPFIND/DELETE), and supporting credential-based authentication via PowerShell SecretManagement."
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
