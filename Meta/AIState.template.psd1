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
    "Development of a comprehensive PowerShell file backup solution (PoSh-Backup.ps1 v1.13.3).", # Updated version
    "Modular design: Core (Modules\\Core\\), Managers (Modules\\Managers\\), Utilities (Modules\\Utilities\\), Operations (Modules\\Operations\\), ConfigManagement (Modules\\ConfigManagement\\), Reporting (Modules\\Reporting\\), Targets (Modules\\Targets\\).",
    "AI State structure loaded from 'Meta\\AIState.template.psd1', dynamically populated by Bundler (v__BUNDLER_VERSION_PLACEHOLDER__).",
    "--- CURRENT FOCUS & RECENTLY COMPLETED (Current Session Segment) ---",
    "  - Feature: Granular Include/Exclude Lists from Files (7-Zip):",
    "    - Goal: Enhance include/exclude capabilities by allowing rules to be read from external list files.",
    "    - `Config\\Default.psd1` (v1.4.3 -> v1.4.4): Added global `DefaultSevenZipIncludeListFile`/`DefaultSevenZipExcludeListFile`, job-level `SevenZipIncludeListFile`/`SevenZipExcludeListFile`, and set-level `SevenZipIncludeListFile`/`SevenZipExcludeListFile` settings.",
    "    - `Modules\\ConfigManagement\\Assets\\ConfigSchema.psd1`: Updated for new list file settings. Corrected `ValidateScript` for list file paths (removed `-IsValid` parameter from `Test-Path`).",
    "    - `PoSh-Backup.ps1` (v1.13.2 -> v1.13.3): Added `-SevenZipIncludeListFileCLI` and `-SevenZipExcludeListFileCLI` parameters and updated `$cliOverrideSettings`.",
    "    - `Modules\\Core\\JobOrchestrator.psm1` (v1.0.2 -> v1.0.3): Retrieves set-level list file paths to pass to `EffectiveConfigBuilder`.",
    "    - `Modules\\ConfigManagement\\EffectiveConfigBuilder.psm1` (v1.0.7 -> v1.0.8): Updated to resolve include/exclude list file paths considering CLI > Set > Job > Global hierarchy and add to report data.",
    "    - `Modules\\Managers\\7ZipManager.psm1` (v1.0.12 -> v1.0.13): `Get-PoShBackup7ZipArgument` now uses resolved list file paths to add `-i@listfile.txt` / `-x@listfile.txt` switches, with warnings for non-existent files.",
    "    - `README.md`: Updated with new feature documentation.",
    "    - Resolved `PoShBackupValidator` warning related to `_PoShBackup_PSScriptRoot` being null during validation by adjusting its injection order in `ConfigLoader.psm1` (v1.1.3 -> v1.1.4).",
    "  - Refactor: `Operations.psm1` (v1.20.2 -> v1.21.2):", # Preserved from user's baseline
    "    - Goal: Improve readability and maintainability of `Invoke-PoShBackupJob`.",
    "    - Action: Refactored `Invoke-PoShBackupJob` into several internal, phase-based helper functions:",
    "      - Invoke-OperationsPhase_InitializeAndPreChecks",
    "      - Invoke-OperationsPhase_PreBackupHooksAndVSS",
    "      - Invoke-OperationsPhase_LocalArchiveAndRetention",
    "      - Invoke-OperationsPhase_RemoteTransfers",
    "    - State variables (`$currentJobStatus`, paths, etc.) managed in the main function, populated by helper return values.",
    "    - PSScriptAnalyzer warnings (PSAvoidAssignmentToAutomaticVariable, PSShouldProcess, PSAvoidUsingPlainTextForPassword) from initial refactoring addressed.",
    "    - `$TempPasswordFilePath` renamed to `$TempPassFilePath`.",
    "    - Tested successfully by the user.",
    "  - Refactor: Logging Function Relocation (Completed in Current Session Segment):", # Preserved from user's baseline
    "    - `Write-LogMessage` moved from `Modules\\Utilities\\Logging.psm1` to `Modules\\Managers\\LogManager.psm1` (v1.0.0 -> v1.1.0).",
    "    - `Modules\\Utilities\\Logging.psm1` (v1.0.0 -> v1.0.1) deprecated and deleted by the user.",
    "    - `Modules\\Utils.psm1` (v1.13.3 -> v1.14.0) updated to source `Write-LogMessage` from `Managers\\LogManager.psm1`.",
    "    - Tested successfully by the user.",
    "--- PREVIOUS SESSION SEGMENTS (Highlights) ---", # Preserved from user's baseline
    "  - Refactor: Manager Modules: Centralized manager modules (7Zip, Hook, Log (initial), Password, Retention, SystemState, Vss) into `Modules\\Managers\\`.",
    "  - Feature: Log File Retention: Implemented log file retention based on count.",
    "  - Feature: CPU Affinity/Core Limiting for 7-Zip: Added `SevenZipCpuAffinity` settings.",
    "  - Pester Testing - Phase 1: Utilities:",
    "    - Established Pattern A (direct import testing) for `ConfigUtils.Tests.ps1` (`Get-ConfigValue`).",
    "    - Established Pattern B (local copy testing) for `FileUtils.Tests.ps1` (its functions).",
    "    - Next Steps: Re-create `SystemUtils.Tests.ps1`.",
    "--- STABLE COMPLETED FEATURES (Brief Overview) ---", # Preserved from user's baseline
    "  - SFX Archives, Core Refactoring (JobOrchestrator, Utils facade, etc.), Archive Checksums, Post-Run System Actions, Backup Target Providers (UNC, Replicate, SFTP).",
    "--- PROJECT STATUS ---", # Updated
    "Overall: Core local/remote backup stable. Extensive refactoring complete including `Operations.psm1`. Log retention, CPU affinity, SFX, checksums, post-run actions, and 7-Zip include/exclude list files are implemented. Pester testing for utilities in progress. Logging function (`Write-LogMessage`) now managed by `LogManager.psm1`."
  )

  main_script_poSh_backup_version = "1.13.3" # Updated version

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
