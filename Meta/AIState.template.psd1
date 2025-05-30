# Meta\AIState.template.psd1
@{
  bundle_generation_time          = "__BUNDLE_GENERATION_TIME_PLACEHOLDER__"
  bundler_script_version          = "__BUNDLER_VERSION_PLACEHOLDER__" # Populated by bundler

  ai_development_watch_list       = @(
    "CRITICAL (AI): ENSURE FULL, UNTRUNCATED FILES ARE PROVIDED WHEN REQUESTED. EXTREME VIGILANCE AND A CHANGE IN AI STRATEGY REQUIRED.",
    "CRITICAL (AI): VERIFY LINE COUNTS AND COMMENT INTEGRITY. EXTREME VIGILANCE REQUIRED.",
    "CRITICAL (AI): Ensure no extraneous trailing whitespace.",
    "CRITICAL (AI): When modifying existing files, EXPLICITLY CONFIRM THE BASELINE VERSION/CONTENT. If errors persist, switch to diffs/patches or manual user changes.",
    "CRITICAL (SYNTAX): PowerShell strings for Markdown triple backticks: use single quotes externally, e.g., '''`'''.",
    "CRITICAL (SYNTAX): Escaping in PowerShell here-strings for JavaScript (e.g., `$`, `${}`) requires care.",
    "CRITICAL (SYNTAX): `-replace` operator replacement strings with special chars need single quotes.",
    "CRITICAL (SYNTAX - PSD1/Strings): Avoid `$(...)` in PSD1 strings if variables/properties might be null. Use formatting or pre-resolution.",
    "CRITICAL (PSD1_PARSING): `Import-PowerShellDataFile` can fail on double-quoted strings with backtick-escaped `\$`. Use single quotes or rephrase.",
    "AI STRATEGY (ACCURACY): When providing full files, state estimated line count difference and mention significant refactoring.",
    "AI STRATEGY (OUTPUT): Provide one file at a time unless small & related (confirm with user).",
    "STRUCTURE: Respect modular design (Core, Managers, Utilities, Operations, etc.). `Write-LogMessage` is now in `Managers\\LogManager.psm1`.",
    "SCOPE: Global color/status map variables in `PoSh-Backup.ps1` must be accessible for `Write-LogMessage` (via `Utils.psm1` facade from `Managers\\LogManager.psm1`).",
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
    "  - **General Pester 5 Notes for This Environment:** `Import-Module` + `Get-Command` + `$script:`-scoped data is key for Pattern A. `$MyInvocation.MyCommand.ScriptBlock.File` for self dot-sourcing. `(`$result.GetType().IsArray) | Should -Be `$true` for array assertion. Clear shared mock log arrays in `BeforeEach` if used. PSSA `PSUseDeclaredVarsMoreThanAssignments` and `$var = `$null` interaction."
  )

  conversation_summary            = @(
    "Development of a comprehensive PowerShell file backup solution (PoSh-Backup.ps1 v1.14.1).", # Updated version
    "Modular design: Core (Modules\\Core\\), Managers (Modules\\Managers\\), Utilities (Modules\\Utilities\\), Operations (Modules\\Operations\\), ConfigManagement (Modules\\ConfigManagement\\), Reporting (Modules\\Reporting\\), Targets (Modules\\Targets\\).",
    "AI State structure loaded from 'Meta\\AIState.template.psd1', dynamically populated by Bundler (v__BUNDLER_VERSION_PLACEHOLDER__).",
    "--- CURRENT FOCUS & RECENTLY COMPLETED (Current Session Segment) ---",
    "  - Feature: Backup Job Chaining / Dependencies:",
    "    - Goal: Define dependencies, so a job runs only after another's success.",
    "    - New Module `Modules\\Managers\\JobDependencyManager.psm1` (v0.3.5):",
    "      - `Test-PoShBackupJobDependencyGraph`: Validates for non-existent jobs and circular dependencies.",
    "      - `Build-JobExecutionOrder`: Builds job execution order using topological sort, considering all direct/indirect dependencies of initially targeted jobs.",
    "      - Internal collections refactored to use PowerShell native arrays/hashtables and `New-Object System.Collections.Queue` to resolve environment-specific instantiation errors for generic types.",
    "      - Added more explicit logging to satisfy PSScriptAnalyzer warnings for Logger parameters.",
    "    - `Config\\Default.psd1` (v1.4.4 -> v1.4.5): Added job-level `DependsOnJobs = @()` setting.",
    "    - `Modules\\ConfigManagement\\Assets\\ConfigSchema.psd1`: Updated for `DependsOnJobs` setting.",
    "    - `Modules\\PoShBackupValidator.psm1` (v1.6.3 -> v1.6.5): Imports `JobDependencyManager` and calls `Test-PoShBackupJobDependencyGraph` for dependency validation. Debug Write-Host lines removed.",
    "    - `PoSh-Backup.ps1` (v1.13.3 -> v1.14.0): Imports `JobDependencyManager`. Calls `Build-JobExecutionOrder` to get the final ordered list of jobs. Handles errors from this process. Debugging constructs for function referencing removed.",
    "    - `Modules\\Core\\JobOrchestrator.psm1` (v1.0.3 -> v1.1.1):",
    "      - Consumes the dependency-ordered job list.",
    "      - Tracks effective success status of completed jobs (considers `TreatSevenZipWarningsAsSuccess`).",
    "      - Checks prerequisite job success before running dependent jobs; skips jobs if dependencies unmet.",
    "      - Interacts with `StopSetOnErrorPolicy` for skipped/failed jobs.",
    "  - Correction: 7-Zip Password Handling:",
    "    - Identified that `-spf` 7-Zip switch was misunderstood; it's for storing full paths, not password files.",
    "    - Refactored to use the correct `-p{password}` switch for archive encryption.",
    "    - `Modules\\Operations\\JobPreProcessor.psm1` (v1.0.2 -> v1.0.3): No longer creates temp password files; returns plain text password directly.",
    "    - `Modules\\Core\\Operations.psm1` (v1.21.1 -> v1.21.2): Retrieves plain text password from pre-processor, passes it to local archive operations, and removed temp file cleanup.",
    "    - `Modules\\Operations\\LocalArchiveProcessor.psm1` (v1.0.9 -> v1.0.10): Accepts plain text password and passes it to 7ZipManager functions.",
    "    - `Modules\\Managers\\7ZipManager.psm1` (v1.0.14 -> v1.1.1):", # Assuming v1.0.14 was the one with the bad -spf space fix.
    "      - `Get-PoShBackup7ZipArgument`: No longer handles any password-related switches.",
    "      - `Invoke-7ZipOperation`: Accepts plain text password, adds `-mhe=on` and `-p{password}` to arguments.",
    "      - `Test-7ZipArchive`: Accepts plain text password, adds `-p{password}` to test arguments.",
    "    - Resolved `Unsupported -spf` errors from 7-Zip.",
    "  - PSScriptAnalyzer Cleanup:",
    "    - `Modules\\Managers\\7ZipManager.psm1` (v1.1.0 -> v1.1.1): Removed unused `TempPassFile` parameter from `Get-PoShBackup7ZipArgument`.",
    "    - `Modules\\Managers\\JobDependencyManager.psm1` (v0.3.3 -> v0.3.5): Renamed `Test-JobDependencies` to `Test-PoShBackupJobDependencyGraph`; added logging to satisfy PSSA for Logger parameters.",
    "    - `Modules\\PoShBackupValidator.psm1` (v1.6.4 -> v1.6.5): Updated to call renamed `Test-PoShBackupJobDependencyGraph`.",
    "  - Feature: Multi-Volume (Split) Archives (7-Zip):",
    "    - Goal: Allow creation of backup archives split into multiple volumes.",
    "    - `Config\\Default.psd1` (v1.4.5 -> v1.4.6): Added global `DefaultSplitVolumeSize` and job-level `SplitVolumeSize` (string, e.g., '100m', '4g').",
    "    - `Modules\\ConfigManagement\\Assets\\ConfigSchema.psd1`: Updated for `SplitVolumeSize` with pattern validation `(^$)|(^\\d+[kmg]$)`.",
    "    - `Modules\\ConfigManagement\\EffectiveConfigBuilder.psm1` (v1.0.8 -> v1.0.9): Resolves `SplitVolumeSize`. If active, it overrides `CreateSFX` (sets to `$false`) and logs a warning. Adds `SplitVolumeSize` to report data.",
    "    - `Modules\\Managers\\7ZipManager.psm1` (v1.1.1 -> v1.1.2): `Get-PoShBackup7ZipArgument` now adds the `-v{size}` switch if a valid `SplitVolumeSize` is in effective config.",
    "    - `Modules\\Core\\Operations.psm1` (v1.21.2 -> v1.21.3): Passes the correct archive extension (internal base extension if splitting, otherwise job archive extension) to `Invoke-BackupRetentionPolicy`.",
    "    - `Modules\\Managers\\RetentionManager.psm1` (v1.0.9 -> v1.1.0): Refactored `Invoke-BackupRetentionPolicy` to correctly identify and manage multi-volume archive sets as single entities for retention counting and deletion.",
    "    - Reporting modules (`ReportingCsv.psm1`, `ReportingJson.psm1`, `ReportingXml.psm1`, `ReportingTxt.psm1`, `ReportingMd.psm1`, `ReportingHtml.psm1`) updated to reflect `SplitVolumeSize` in summaries/outputs.",
    "    - `PoSh-Backup.ps1` (v1.14.0 -> v1.14.1): Added `-SplitVolumeSizeCLI` parameter and integrated it into CLI override logic and logging.",
    "    - `Modules\\PoShBackupValidator.psm1` (v1.6.5 -> v1.6.6): Corrected typo in `Test-PoShBackupJobDependencyGraph` call. Schema-driven validation implicitly handles `SplitVolumeSize` via updated `ConfigSchema.psd1`.",
    "    - `README.md`: Updated with feature details, configuration, SFX interaction, and CLI override.",
    "--- PREVIOUS SESSION SEGMENTS (Highlights, from user baseline) ---",
    "  - Feature: Granular Include/Exclude Lists from Files (7-Zip):",
    "    - `Config\\Default.psd1` (v1.4.3 -> v1.4.4): Added global, job, and set-level list file settings.",
    "    - `Modules\\ConfigManagement\\Assets\\ConfigSchema.psd1`: Updated for list files, corrected `ValidateScript`.",
    "    - `PoSh-Backup.ps1` (v1.13.2 -> v1.13.3): Added CLI params for list files.",
    "    - `Modules\\Core\\JobOrchestrator.psm1` (v1.0.2 -> v1.0.3): Retrieves set-level list files.",
    "    - `Modules\\ConfigManagement\\EffectiveConfigBuilder.psm1` (v1.0.7 -> v1.0.8): Resolves list file hierarchy.",
    "    - `Modules\\Managers\\7ZipManager.psm1` (v1.0.12 -> v1.1.1): Uses list files for `-i@`/`-x@` switches.",
    "    - `README.md`: Updated.",
    "    - Resolved `PoShBackupValidator` warning for `_PoShBackup_PSScriptRoot` in `ConfigLoader.psm1` (v1.1.3 -> v1.1.4).",
    "  - Refactor: `Operations.psm1` (v1.20.2 -> v1.21.2): Refactored `Invoke-PoShBackupJob` into internal, phase-based helper functions.",
    "  - Refactor: Logging Function Relocation: `Write-LogMessage` moved to `Modules\\Managers\\LogManager.psm1`.",
    "  - Refactor: Manager Modules: Centralized manager modules into `Modules\\Managers\\`.",
    "  - Feature: Log File Retention: Implemented log file retention based on count.",
    "  - Feature: CPU Affinity/Core Limiting for 7-Zip: Added `SevenZipCpuAffinity` settings.",
    "  - Pester Testing - Phase 1: Utilities: Established Pattern A (direct import) and Pattern B (local copy) for utility function testing.",
    "--- STABLE COMPLETED FEATURES (Brief Overview, from user baseline) ---",
    "  - SFX Archives, Core Refactoring (JobOrchestrator, Utils facade, etc.), Archive Checksums, Post-Run System Actions, Backup Target Providers (UNC, Replicate, SFTP).",
    "--- PROJECT STATUS ---",
    "Overall: Core local/remote backup stable. Extensive refactoring complete. Log retention, CPU affinity, SFX, checksums, post-run actions, 7-Zip include/exclude list files, job dependency/chaining, and multi-volume (split) archives features are implemented. Pester testing for utilities in progress. Logging function (`Write-LogMessage`) now managed by `LogManager.psm1`."
  )

  main_script_poSh_backup_version = "1.14.1" # Reflects -SplitVolumeSizeCLI parameter

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
      "Posh-SSH (for SFTP target provider)"
    )
  }
}
