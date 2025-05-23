# Meta\AIState.template.psd1
@{
  bundle_generation_time = "__BUNDLE_GENERATION_TIME_PLACEHOLDER__"
  bundler_script_version = "__BUNDLER_VERSION_PLACEHOLDER__" # Populated by bundler

  ai_development_watch_list = @(
    "CRITICAL (AI): ENSURE FULL, UNTRUNCATED FILES ARE PROVIDED WHEN REQUESTED. This was a REPEATED, CATASTROPHIC FAILURE during the 'Replicate' target provider development, AGAIN during 'PostRunAction' (README.md, Default.psd1, ConfigManager.psm1), and AGAIN during 'SFTP Target' (README.md). EXTREME VIGILANCE AND A CHANGE IN AI STRATEGY (e.g., AI requesting user to provide baselines for complex/long files, AI providing diffs/patches) IS REQUIRED. User had to provide baselines multiple times.", # RE-EMPHASIZED + CURRENT SESSION MAJOR FAILURE
    "CRITICAL (AI): VERIFY LINE COUNTS AND COMMENT INTEGRITY when AI provides full script updates. Inadvertent removal/truncation has occurred repeatedly. This was a significant issue in the last session and a CATASTROPHIC issue in the current session. EXTREME VIGILANCE REQUIRED.", # RE-EMPHASIZED + CURRENT SESSION MAJOR FAILURE
    "CRITICAL (AI): Ensure no extraneous trailing whitespace is introduced on any lines, including apparently blank ones when providing code.",
    "CRITICAL (AI): When modifying existing files, EXPLICITLY CONFIRM THE BASELINE VERSION/CONTENT if there's ANY ambiguity. If providing full files, state the assumed baseline. If errors persist, switch to providing diffs/patches against a user-provided baseline, or ask user to make manual changes based on AI instructions.", # UPDATED with strategy
    "CRITICAL (SYNTAX): For literal triple backticks (```) in PowerShell strings meant for Markdown code fences, use single quotes: '''```'''. For example, using 'theSBvariable.AppendLine('''''''```''''''')' with single quotes for the outer string. Double quotes for the outer string will cause parsing errors or misinterpretation.",
    "CRITICAL (SYNTAX): Escaping special characters (like `$`, `{`, `}` within regex patterns) in PowerShell here-strings for JavaScript requires extreme care. PowerShell's parser may interpret sequences like `${}` as empty variable expressions. Methods like string concatenation within the JS, or careful backtick escaping (`$`) are needed.",
    "CRITICAL (SYNTAX): When providing replacement strings for PowerShell's -replace operator that include special characters (e.g., HTML entities like '<'), ensure these replacement strings are correctly quoted (typically single quotes) to be treated as literal strings by PowerShell.",
    'CRITICAL (SYNTAX - PSD1/Strings): When generating PowerShell data files (.psd1) or strings that will be parsed by `Import-PowerShellDataFile` or similar, be extremely careful with nested quotes and variable expansion syntax like $($variable.Property). If a variable might be null or a property might not exist, this can lead to parsing errors (e.g., ''$()'' is invalid). Use string formatting (`-f`) or ensure variables/properties are resolved to actual values *before* embedding them in such strings, or use intermediate variables with checks.', # NEW - From SFTP.Target.psm1 error
    "SYNTAX: PowerShell ordered dictionaries (`[ordered]@{}`) use `(theDictVariable.PSObject.Properties.Name -contains 'Key')`, NOT `theDictVariable.ContainsKey('Key')`. ",
    "REGEX: Be cautious with string interpolation vs. literal characters in regex patterns. Test regex patterns carefully. Ensure PowerShell string parsing is correct before regex engine sees it.",
    "LOGIC: Verify `IsSimulateMode` flag is consistently propagated and handled, especially for I/O operations and status reporting, including through new Backup Target provider models and PostRunAction feature.",
    "DATA FLOW: Ensure data for reports (like `IsSimulationReport`, `OverallStatus`, `VSSStatus`, `VSSAttempted`, and new `TargetTransfers` array with its `ReplicationDetails`) is correctly set in `theReportDataRefRef` (a ref object) *before* report generation functions are called.", # Corrected variable name
    "SCOPE: Double-check variable scopes. `$Global:StatusToColourMap` and associated `$Global:Colour<Name>` variables in `PoSh-Backup.ps1` must be correctly defined and accessible when `Write-LogMessage` (from `Utils.psm1`) is invoked, even during early module loading or from deeply nested calls. An explicit 'ERROR' key in the map resolved a color issue.",
    "STRUCTURE: Respect the modular design. Ensure functions are placed in the most logical module. New target providers go in `Modules\Targets\`. New system state functions in `Modules\SystemStateManager.psm1`.",
    "BRACES/PARENS: Meticulously check for balanced curly braces `{}`, parentheses `()`, and square brackets `[]` in all generated code.",
    "PSSA (BUNDLER): Bundler's `Invoke-ScriptAnalyzer` summary may not perfectly reflect all suppressions from `PSScriptAnalyzerSettings.psd1` or inline suppressions, even if VS Code shows no issues. This was observed with `PSUseApprovedVerbs` which required careful inline suppression.",
    "PSSA (CLOSURES): PSScriptAnalyzer may not always detect parameter/variable usage within scriptblock closures assigned to local variables (e.g., `$LocalWriteLog` wrappers using a `$Logger` parameter from parent scope). Explicit, direct calls to the parameter within the main function body might be needed for PSSA appeasement.",
    "PESTER (SESSION): Current Pester tests are non-functional. No work done in this session.",
    "CRITICAL (PSD1_PARSING): `Import-PowerShellDataFile` can unexpectedly fail with 'dynamic expression' errors on double-quoted strings containing backtick-escaped `\$` if the overall string structure is complex. Safest to rephrase or use single-quoted strings.",
    "LOGIC (CONFIRMATION): The interaction between `[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='...')`, `$PSCmdlet.ShouldProcess()`, `$ConfirmPreference`, and explicit `-Confirm` parameters is complex. Test confirmation flows carefully, especially for new PostRunAction feature and target provider operations.", # UPDATED
    "LOGIC (PATH_CREATION): `New-Item -ItemType Directory -Force` on UNC paths may not create intermediate parent directories robustly. Iterative path component creation is more reliable for UNC destinations (as implemented in `UNC.Target.psm1`'s `Initialize-RemotePathInternal`). SFTP provider also needs robust remote path creation.", # UPDATED
    "LOGIC (POST_RUN_ACTION): Ensure the hierarchy for PostRunAction (CLI > Set > Job > Global Defaults) is correctly implemented and that `-Simulate` and `-TestConfig` modes properly simulate without executing system state changes."
  )

  conversation_summary = @(
    "__CONVERSATION_SUMMARY_PLACEHOLDER__" # Dynamically populated by Bundle.StateAndAssembly.psm1
  )

  main_script_poSh_backup_version = "__POSH_BACKUP_VERSION_PLACEHOLDER__"

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
      "external_dependencies.powershell_modules" # AI can update this based on new module dependencies
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
      "Posh-SSH (for SFTP target provider)" # NEW
      # "__PS_DEPENDENCIES_PLACEHOLDER__" # This placeholder will be replaced by bundler if other dependencies are auto-detected
    )
  }
}
