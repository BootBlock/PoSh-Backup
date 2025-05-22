# Meta\AIState.template.psd1
@{
  bundle_generation_time = "__BUNDLE_GENERATION_TIME_PLACEHOLDER__"
  bundler_script_version = "__BUNDLER_VERSION_PLACEHOLDER__" # Populated by bundler

  ai_development_watch_list = @(
    "CRITICAL (AI): ENSURE FULL, UNTRUNCATED FILES ARE PROVIDED WHEN REQUESTED. This was a REPEATED, CATASTROPHIC FAILURE during the 'Replicate' target provider development, affecting Operations.psm1, PoShBackupValidator.psm1, Default.psd1, and UNC.Target.psm1 across multiple attempts. EXTREME VIGILANCE AND A CHANGE IN AI STRATEGY (e.g., providing diffs for complex files) IS REQUIRED. User had to provide baselines multiple times.", # RE-EMPHASIZED + CURRENT SESSION MAJOR FAILURE
    "CRITICAL (AI): VERIFY LINE COUNTS AND COMMENT INTEGRITY when AI provides full script updates. Inadvertent removal/truncation has occurred repeatedly. This was a significant issue in the last session and a CATASTROPHIC issue in the current session. EXTREME VIGILANCE REQUIRED.", # RE-EMPHASIZED + CURRENT SESSION MAJOR FAILURE
    "CRITICAL (AI): Ensure no extraneous trailing whitespace is introduced on any lines, including apparently blank ones when providing code.",
    "CRITICAL (AI): When modifying existing files, EXPLICITLY CONFIRM THE BASELINE VERSION/CONTENT if there's ANY ambiguity. If providing full files, state the assumed baseline. If errors persist, switch to providing diffs/patches against a user-provided baseline.", # UPDATED with strategy
    "CRITICAL (SYNTAX): For literal triple backticks (```) in PowerShell strings meant for Markdown code fences, use single quotes: '''```'''. For example, using 'theSBvariable.AppendLine('''''''```''''''')' with single quotes for the outer string. Double quotes for the outer string will cause parsing errors or misinterpretation.",
    "CRITICAL (SYNTAX): Escaping special characters (like `$`, `{`, `}` within regex patterns) in PowerShell here-strings for JavaScript requires extreme care. PowerShell's parser may interpret sequences like `${}` as empty variable expressions. Methods like string concatenation within the JS, or careful backtick escaping (`$`) are needed.",
    "CRITICAL (SYNTAX): When providing replacement strings for PowerShell's -replace operator that include special characters (e.g., HTML entities like '<'), ensure these replacement strings are correctly quoted (typically single quotes) to be treated as literal strings by PowerShell.", 
    "SYNTAX: PowerShell ordered dictionaries (`[ordered]@{}`) use `(theDictVariable.PSObject.Properties.Name -contains 'Key')`, NOT `theDictVariable.ContainsKey('Key')`. ",
    "REGEX: Be cautious with string interpolation vs. literal characters in regex patterns. Test regex patterns carefully. Ensure PowerShell string parsing is correct before regex engine sees it.",
    "LOGIC: Verify `IsSimulateMode` flag is consistently propagated and handled, especially for I/O operations and status reporting, including through new Backup Target provider models.", 
    "DATA FLOW: Ensure data for reports (like `IsSimulationReport`, `OverallStatus`, `VSSStatus`, `VSSAttempted`, and new `TargetTransfers` array with its `ReplicationDetails`) is correctly set in `theReportDataRefVariable` (a ref object) *before* report generation functions are called.", # UPDATED
    "SCOPE: Double-check variable scopes. `$Global:StatusToColourMap` and associated `$Global:Colour<Name>` variables in `PoSh-Backup.ps1` must be correctly defined and accessible when `Write-LogMessage` (from `Utils.psm1`) is invoked, even during early module loading or from deeply nested calls. An explicit 'ERROR' key in the map resolved a color issue.", # NEW/UPDATED
    "STRUCTURE: Respect the modular design. Ensure functions are placed in the most logical module. New target providers go in `Modules\Targets\`.", 
    "BRACES/PARENS: Meticulously check for balanced curly braces `{}`, parentheses `()`, and square brackets `[]` in all generated code.",
    "PSSA (BUNDLER): Bundler's `Invoke-ScriptAnalyzer` summary may not perfectly reflect all suppressions from `PSScriptAnalyzerSettings.psd1` or inline suppressions, even if VS Code shows no issues. This was observed with `PSUseApprovedVerbs` which required careful inline suppression.", # UPDATED
    "PSSA (CLOSURES): PSScriptAnalyzer may not always detect parameter/variable usage within scriptblock closures assigned to local variables (e.g., `$LocalWriteLog` wrappers using a `$Logger` parameter from parent scope). Explicit, direct calls to the parameter within the main function body might be needed for PSSA appeasement.", # UPDATED
    "PESTER (SESSION): Current Pester tests are non-functional. No work done in this session.",
    "CRITICAL (PSD1_PARSING): `Import-PowerShellDataFile` can unexpectedly fail with 'dynamic expression' errors on double-quoted strings containing backtick-escaped `\$` if the overall string structure is complex. Safest to rephrase or use single-quoted strings.",
    "LOGIC (CONFIRMATION): The interaction between `[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='...')`, `$PSCmdlet.ShouldProcess()`, `$ConfirmPreference`, and explicit `-Confirm` parameters is complex. Test confirmation flows carefully.",
    "LOGIC (PATH_CREATION): `New-Item -ItemType Directory -Force` on UNC paths may not create intermediate parent directories robustly. Iterative path component creation is more reliable for UNC destinations (as implemented in `UNC.Target.psm1`'s `Initialize-RemotePathInternal`)." # NEW
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
      "external_dependencies.executables" 
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
      "7z.exe (7-Zip command-line tool - path configurable or auto-detected)"
    )
    powershell_modules = @( 
      "__PS_DEPENDENCIES_PLACEHOLDER__" 
    )
  }
}
