# Meta\AIState.template.psd1
@{
  bundle_generation_time = "__BUNDLE_GENERATION_TIME_PLACEHOLDER__"
  bundler_script_version = "__BUNDLER_VERSION_PLACEHOLDER__" # Populated by bundler

  ai_development_watch_list = @(
    "CRITICAL (AI): ENSURE FULL, UNTRUNCATED FILES ARE PROVIDED WHEN REQUESTED. This was a REPEATED, CATASTROPHIC FAILURE during the 'Replicate' target provider development, AGAIN during 'PostRunAction' (README.md, Default.psd1, ConfigManager.psm1), and AGAIN during 'SFTP Target' (README.md). EXTREME VIGILANCE AND A CHANGE IN AI STRATEGY (e.g., AI requesting user to provide baselines for complex/long files, AI providing diffs/patches) IS REQUIRED. User had to provide baselines multiple times.",
    "CRITICAL (AI): VERIFY LINE COUNTS AND COMMENT INTEGRITY when AI provides full script updates. Inadvertent removal/truncation has occurred repeatedly. This was a significant issue in the last session and a CATASTROPHIC issue in the current session. EXTREME VIGILANCE REQUIRED.",
    "CRITICAL (AI): Ensure no extraneous trailing whitespace is introduced on any lines, including apparently blank ones when providing code.",
    "CRITICAL (AI): When modifying existing files, EXPLICITLY CONFIRM THE BASELINE VERSION/CONTENT if there's ANY ambiguity. If providing full files, state the assumed baseline. If errors persist, switch to providing diffs/patches against a user-provided baseline, or ask user to make manual changes based on AI instructions.",
    "CRITICAL (SYNTAX): For literal triple backticks (```) in PowerShell strings meant for Markdown code fences, use single quotes: '''```'''. For example, using 'theSBvariable.AppendLine('''''''```''''''')' with single quotes for the outer string. Double quotes for the outer string will cause parsing errors or misinterpretation.",
    "CRITICAL (SYNTAX): Escaping special characters (like `$`, `{`, `}` within regex patterns) in PowerShell here-strings for JavaScript requires extreme care. PowerShell's parser may interpret sequences like `${}` as empty variable expressions. Methods like string concatenation within the JS, or careful backtick escaping (`$`) are needed.",
    "CRITICAL (SYNTAX): When providing replacement strings for PowerShell's -replace operator that include special characters (e.g., HTML entities like '<'), ensure these replacement strings are correctly quoted (typically single quotes) to be treated as literal strings by PowerShell.",
    'CRITICAL (SYNTAX - PSD1/Strings): When generating PowerShell data files (.psd1) or strings that will be parsed by `Import-PowerShellDataFile` or similar, be extremely careful with nested quotes and variable expansion syntax like $($variable.Property). If a variable might be null or a property might not exist, this can lead to parsing errors (e.g., ''$()'' is invalid). Use string formatting (`-f`) or ensure variables/properties are resolved to actual values *before* embedding them in such strings, or use intermediate variables with checks.',
    "SYNTAX: PowerShell ordered dictionaries (`[ordered]@{}`) use `(theDictVariable.PSObject.Properties.Name -contains 'Key')`, NOT `theDictVariable.ContainsKey('Key')`. ",
    "REGEX: Be cautious with string interpolation vs. literal characters in regex patterns. Test regex patterns carefully. Ensure PowerShell string parsing is correct before regex engine sees it.",
    "LOGIC: Verify `IsSimulateMode` flag is consistently propagated and handled, especially for I/O operations and status reporting, including through new Backup Target provider models and PostRunAction feature.",
    "DATA FLOW: Ensure data for reports (like `IsSimulationReport`, `OverallStatus`, `VSSStatus`, `VSSAttempted`, and new `TargetTransfers` array with its `ReplicationDetails`) is correctly set in `theReportDataRefRef` (a ref object) *before* report generation functions are called.",
    "SCOPE: Double-check variable scopes. `$Global:StatusToColourMap` and associated `$Global:Colour<Name>` variables in `PoSh-Backup.ps1` must be correctly defined and accessible when `Write-LogMessage` (from `Utils.psm1`) is invoked, even during early module loading or from deeply nested calls. An explicit 'ERROR' key in the map resolved a color issue.",
    "STRUCTURE: Respect the modular design. Ensure functions are placed in the most logical module. New target providers go in `Modules\Targets\`. New system state functions in `Modules\SystemStateManager.psm1`. Ensure new sub-modules (e.g., under `Modules\Operations\` or `Modules\ConfigManagement\`) are correctly structured and imported.",
    "BRACES/PARENS: Meticulously check for balanced curly braces `{}`, parentheses `()`, and square brackets `[]` in all generated code.",
    "PSSA (BUNDLER): Bundler's `Invoke-ScriptAnalyzer` summary may not perfectly reflect all suppressions from `PSScriptAnalyzerSettings.psd1` or inline suppressions, even if VS Code shows no issues. This was observed with `PSUseApprovedVerbs`. The interpretation of 'empty catch block' also needs attention; ensure catch blocks either `throw` or use `Write-Error` explicitly if PSSA continues to flag them despite logging.",
    "PSSA (CMDLET VERBS): Ensure new public functions follow approved verbs. If a plural noun seems descriptive for an internal orchestrator (e.g. `Invoke-AllRemoteTargetTransfers`), discuss if renaming (e.g. `Invoke-RemoteTargetTransferOrchestration`) or suppression is preferred. Strict adherence was chosen in recent refactoring.",
    "PSSA (CLOSURES): PSScriptAnalyzer may not always detect parameter/variable usage within scriptblock closures assigned to local variables (e.g., `$LocalWriteLog` wrappers using a `$Logger` parameter from parent scope). Explicit, direct calls to the parameter within the main function body might be needed for PSSA appeasement.",
    "PESTER (SESSION): Current Pester tests are non-functional. No work done in this session.",
    "CRITICAL (PSD1_PARSING): `Import-PowerShellDataFile` can unexpectedly fail with 'dynamic expression' errors on double-quoted strings containing backtick-escaped `\$` if the overall string structure is complex. Safest to rephrase or use single-quoted strings.",
    "LOGIC (CONFIRMATION): The interaction between `[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='...')`, `$PSCmdlet.ShouldProcess()`, `$ConfirmPreference`, and explicit `-Confirm` parameters is complex. Test confirmation flows carefully, especially for new PostRunAction feature and target provider operations.",
    "LOGIC (PATH_CREATION): `New-Item -ItemType Directory -Force` on UNC paths may not create intermediate parent directories robustly. Iterative path component creation is more reliable for UNC destinations (as implemented in `UNC.Target.psm1`'s `Initialize-RemotePathInternal`). SFTP provider also needs robust remote path creation.",
    "LOGIC (POST_RUN_ACTION): Ensure the hierarchy for PostRunAction (CLI > Set > Job > Global Defaults) is correctly implemented and that `-Simulate` and `-TestConfig` modes properly simulate without executing system state changes.",
    "VERBS: Ensure all new functions use approved PowerShell verbs. If an unapproved verb seems most descriptive for an internal helper, discuss with the user or use a PSScriptAnalyzer suppression with justification.",
    "AI STRATEGY (ACCURACY): When providing new or updated full files, ALWAYS perform a mental diff against the presumed baseline. State the estimated line count difference (e.g., '+15 lines', '-5 lines', 'approx. +/- 10 lines for significant refactoring'). This helps the user quickly gauge the scope of changes and verify completeness, especially for longer files. If the changes are extensive or involve complex refactoring, explicitly mention this as well.",
    "AI STRATEGY (OUTPUT): Provide only one file at a time for review and integration, UNLESS explicitly requested otherwise by the user OR if multiple files are very small (e.g., less than ~20-30 lines each) and closely related, in which case confirm with the user if a combined provision is acceptable. This helps manage UI limitations and focused review."
  )

  conversation_summary = @(
    "Development of a comprehensive PowerShell file backup solution (PoSh-Backup.ps1 v1.11.5).",
    "Modular design: Core modules, Reporting sub-modules (including Modules\Reporting\Assets and Modules\ConfigManagement\Assets directories), Config files, and Meta/ (bundler).",
    "AI State structure is loaded from 'Meta\\AIState.template.psd1' and dynamically populated by Bundle.StateAndAssembly.psm1 (v1.1.8).",
    "--- Further Modularisation of PoSh-Backup.ps1 and ReportingHtml.psm1 (Current Session) ---",
    "  - Goal: Reduce size of larger script files for AI efficiency and improve maintainability.",
    "  - `PoSh-Backup.ps1` (v1.11.4 -> v1.11.5) refactored:",
    "    - Logic for `-ListBackupLocations`, `-ListBackupSets`, and `-TestConfig` modes moved to a new module.",
    "    - New module: `Modules\\ScriptModeHandler.psm1` (v1.0.0) created to handle these informational modes, which calls `exit` internally.",
    "    - This significantly reduced the line count of `PoSh-Backup.ps1` (approx. -90 lines).",
    "  - `Modules\\Reporting\\ReportingHtml.psm1` (v1.9.2 -> v1.9.10) refactored in two stages:",
    "    - Stage 1: Client-side JavaScript externalised to `Modules\\Reporting\\Assets\\ReportingHtml.Client.js`.",
    "    - Stage 2: Static HTML structure aggressively externalised to `Modules\\Reporting\\Assets\\ReportingHtml.template.html`.",
    "    - `ReportingHtml.psm1` now primarily handles data processing and injection into the HTML template, significantly reducing its line count.",
    "  - `Modules\\PoShBackupValidator.psm1` (v1.3.6 -> v1.4.0) refactored:",
    "    - Embedded schema definition (`$Script:PoShBackup_ConfigSchema`) moved to an external file: `Modules\\ConfigManagement\\Assets\\ConfigSchema.psd1`.",
    "    - `PoShBackupValidator.psm1` now loads the schema from this external file, significantly reducing its own size.",
    "  - PSSA warning for unused Logger parameter in `ReportingHtml.psm1` (v1.9.10) addressed by adding a direct call to the logger.",
    "  - Console blank line issue during HTML report generation investigated and resolved by refactoring internal logger helper in `ReportingHtml.psm1` and removing temporary diagnostic lines.",
    "--- Major Refactoring: Modularisation of Operations.psm1 and ConfigManager.psm1 (Previous Session) ---",
    "  - Goal: Improve maintainability, readability, and testability of large modules.",
    "  - `Operations.psm1` (v1.18.6 -> v1.19.0) refactored:",
    "    - Now acts as an orchestrator for job lifecycle stages.",
    "    - New sub-module: `Modules\\Operations\\LocalArchiveProcessor.psm1` (v1.0.1) created to handle local archive creation, checksums, and testing.",
    "    - New sub-module: `Modules\\Operations\\RemoteTransferOrchestrator.psm1` (v1.0.0) created to manage transfers to remote targets.",
    "  - `ConfigManager.psm1` (v1.1.5 -> v1.2.0) refactored:",
    "    - Now acts as a facade for configuration management functions.",
    "    - New sub-module: `Modules\\ConfigManagement\\ConfigLoader.psm1` (v1.0.0) created for `Import-AppConfiguration`.",
    "    - New sub-module: `Modules\\ConfigManagement\\JobResolver.psm1` (v1.0.0) created for `Get-JobsToProcess`.",
    "    - New sub-module: `Modules\\ConfigManagement\\EffectiveConfigBuilder.psm1` (v1.0.0) created for `Get-PoShBackupJobEffectiveConfiguration`.",
    "  - All changes tested successfully by the user.",
    "--- Previous Major Feature: Archive Checksum Generation & Verification ---",
    "  - Goal: Enhance archive integrity with optional checksums.",
    "  - Configuration (`Config\\Default.psd1` v1.3.6):",
    "    - Added global defaults: `DefaultGenerateArchiveChecksum`, `DefaultChecksumAlgorithm`, `DefaultVerifyArchiveChecksumOnTest`.",
    "    - Added job-level settings: `GenerateArchiveChecksum`, `ChecksumAlgorithm`, `VerifyArchiveChecksumOnTest`.",
    "  - Schema Validation (`Modules\\PoShBackupValidator.psm1` v1.3.6):",
    "    - Updated schema to validate new checksum settings at global and job levels.",
    "  - Utility Function (`Modules\\Utils.psm1` v1.12.0):",
    "    - Added `Get-PoshBackupFileHash` function using `Get-FileHash` for checksum calculation.",
    "  - Operations (`Modules\\Operations.psm1` v1.18.6 - before refactor):",
    "    - Logic to generate checksum file (e.g., `archive.7z.sha256`) after local archive creation if enabled.",
    "    - Logic to verify checksum against archive content during archive testing if enabled.",
    "    - Checksum details (value, algorithm, file path, verification status) added to report data.",
    "  - Config Management (`Modules\\ConfigManager.psm1` v1.1.5 - before refactor):",
    "    - `Get-PoShBackupJobEffectiveConfiguration` now resolves checksum settings for jobs.",
    "  - Reporting Modules Updated (v1.9.2 for HTML, v1.2.2 for TXT/CSV, v1.3.2 for MD, v1.1.4 for JSON, v1.2.2 for XML):",
    "    - HTML, TXT, MD, CSV reports now display checksum information in the summary section.",
    "    - JSON and XML reports implicitly include checksum data as part of the main report object.",
    "  - Main Script (PoSh-Backup.ps1 v1.11.0 - for checksums, current v1.11.5):",
    "    - Synopsis and description updated to reflect the new checksum feature.",
    "  - Documentation (`README.md`): Updated to explain the new Checksum feature, configuration, and impact on archive testing.",
    "--- Previous Major Feature: Post-Run System Actions (Shutdown, Restart, etc.) ---",
    "  - Goal: Allow PoSh-Backup to perform system state changes after job/set completion.",
    "  - New Module (`Modules\\SystemStateManager.psm1` v1.0.2):",
    "    - Created to handle system state changes (Shutdown, Restart, Hibernate, LogOff, Sleep, Lock).",
    "    - Includes `Invoke-SystemStateAction` function.",
    "  - Configuration (`Config\\Default.psd1` v1.3.5):",
    "    - Added global `PostRunActionDefaults` section and job/set level `PostRunAction` settings.",
    "  - Schema Validation (`Modules\\PoShBackupValidator.psm1` v1.3.5): Updated for PostRunAction.",
    "  - Config Management (`Modules\\ConfigManager.psm1` v1.1.4 - before checksums & refactor): Updated for PostRunAction.",
    "  - Main Script (`PoSh-Backup.ps1` v1.10.1 - for PostRunAction): Updated for PostRunAction.",
    "  - Documentation (`README.md`): Updated for Post-Run System Action feature.",
    "--- Previous Major Feature: Backup Targets (Expanded) ---",
    "  - Goal: Allow backups to be sent to remote locations via an extensible provider model.",
    "  - Configuration (Default.psd1 v1.3.3): Added `BackupTargets`, `TargetNames`, etc.",
    "  - Target Providers: UNC.Target.psm1(v1.1.2),Replicate.Target.psm1(v1.0.2),SFTP.Target.psm1 (v1.0.3).",
    "  - Operations.psm1 (v1.17.3 - before PostRunAction, Checksum, & refactor): Orchestrated target transfers.",
    "  - Reporting Modules: Updated for `TargetTransfers` data.",
    "  - README.md: Updated for 'Replicate' and 'SFTP' target providers.",
    "--- Previous Work (Selected Highlights) ---",
    "Network Share Handling Improvements, Retention Policy Confirmation, HTML Report Enhancements, PSSA compliance.",
    "Bundler Script (Generate-ProjectBundleForAI.ps1 v1.25.2) is stable.",
    "Overall project status: Core local backup stable. Remote targets, Post-Run Actions, Checksums features added. Major refactorings completed. PoSh-Backup.ps1, ReportingHtml.psm1, and PoShBackupValidator.psm1significantly reduced in size. PSSA summary expected to be clean except for known SFTPConvertTo-SecureStringitems and theOperations.psm1 empty catch block anomaly. Pester tests non-functional."
  )

  main_script_poSh_backup_version = "__POSH_BACKUP_VERSION_PLACEHOLDER__" # Will be 1.11.5

  ai_bundler_update_instructions = @{
    purpose = "Instructions for AI on how to regenerate the content of the AI state hashtable by providing the content for 'Meta\\AIState.template.psd1' when requested by the user."
    when_to_update = "Only when the user explicitly asks to 'update the bundler script's AI state'."
    example_of_ai_provided_block_start = "# Meta\\AIState.template.psd1"
    output_format_for_ai = "Provide the updated content for 'Meta\\AIState.template.psd1' as a complete PowerShell data file string, ready for copy-pasting. Ensure strings are correctly quoted and arrays use PowerShell syntax, e.g., `@('item1', 'item2')`. Placeholders like '__BUNDLER_VERSION_PLACEHOLDER__' should be kept as literal strings in the template provided by AI; they will be dynamically replaced by the bundler script."
    reminder_for_ai = "When asked to update this state, proactively consider if any recent challenges or frequent corrections should be added to the 'ai_development_watch_list'. The AI should provide the *full content* of the AIState.template.psd1 file, not just a PowerShell 'aiStateVariable = @{...}' block for a .psm1 file."
    fields_to_update_by_ai = @(
      "ai_development_watch_list",
      "ai_bundler_update_instructions",
      "external_dependencies.executables",
      "external_dependencies.powershell_modules"
    )
    fields_to_be_updated_by_user = @(
      "external_dependencies.executables (if new external tools are added - AI cannot auto-detect this reliably if path is not hardcoded/standard)"
    )
    example_of_ai_provided_block_end = "}"
  }

  module_descriptions = @{
    "__MODULE_DESCRIPTIONS_PLACEHOLDER__" = "This is a placeholder entry." # Dynamically populated
  }

  project_root_folder_name = "__PROJECT_ROOT_NAME_PLACEHOLDER__"
  project_name = "PoSh Backup Solution"

  external_dependencies = @{
    executables = @(
      "7z.exe (7-Zip command-line tool - path configurable or auto-detected)",
      "powercfg.exe (Windows Power Configuration Utility - for Hibernate check)",
      "rundll32.exe (Windows utility - for Hibernate, Sleep, Lock actions)",
      "shutdown.exe (Windows utility - for Shutdown, Restart, LogOff actions)"
    )
    powershell_modules = @(
      "Posh-SSH (for SFTP target provider)"
      # "__PS_DEPENDENCIES_PLACEHOLDER__" # This placeholder will be replaced by bundler if other dependencies are auto-detected
    )
  }
}
