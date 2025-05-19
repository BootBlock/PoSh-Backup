# Meta\AIState.template.psd1
@{
  bundle_generation_time = "__BUNDLE_GENERATION_TIME_PLACEHOLDER__"
  bundler_script_version = "__BUNDLER_VERSION_PLACEHOLDER__" # Populated by bundler

  ai_development_watch_list = @(
    "CRITICAL (AI): Ensure full, untruncated files are provided when requested by the user. AI has made this mistake multiple times, including during the most recent session regarding CSS and Validator module updates, and most recently with RetentionManager.psm1.", 
    "CRITICAL (AI): Verify line counts and comment integrity when AI provides full script updates; inadvertent removal/truncation has occurred (e.g., missing comments, fewer lines than expected). This was a significant issue in the last session, particularly with RetentionManager.psm1. This was also an issue in the current session with RetentionManager.psm1.", # EMPHASIS ADDED
    "CRITICAL (AI): Ensure no extraneous trailing whitespace is introduced on any lines, including apparently blank ones when providing code.",
    "CRITICAL (SYNTAX): For literal triple backticks (```) in PowerShell strings meant for Markdown code fences, use single quotes: '''```'''. For example, using 'theSBvariable.AppendLine('''''''```''''''')' with single quotes for the outer string. Double quotes for the outer string will cause parsing errors or misinterpretation.",
    "CRITICAL (SYNTAX): Escaping special characters (like `$`, `{`, `}` within regex patterns) in PowerShell here-strings for JavaScript requires extreme care. PowerShell's parser may interpret sequences like `${}` as empty variable expressions. Methods like string concatenation within the JS, or careful backtick escaping (`$`) are needed. This caused multiple iterations in a previous session.",
    "SYNTAX: PowerShell ordered dictionaries (`[ordered]@{}`) use `(theDictVariable.PSObject.Properties.Name -contains 'Key')`, NOT `theDictVariable.ContainsKey('Key')`. ",
    "REGEX: Be cautious with string interpolation vs. literal characters in regex patterns. Test regex patterns carefully. Ensure PowerShell string parsing is correct before regex engine sees it (e.g., use single-quoted strings for regex patterns, ensure proper escaping of special characters within the pattern if needed).",
    "LOGIC: Verify `IsSimulateMode` flag is consistently propagated and handled, especially for I/O operations and status reporting.",
    "DATA FLOW: Ensure data for reports (like `IsSimulationReport`, `OverallStatus`, `VSSStatus`, `VSSAttempted`) is correctly set in `theReportDataRefVariable` (a ref object) *before* report generation functions are called.", 
    "SCOPE: Double-check variable scopes when helper functions modify collections intended for wider use (prefer passing by ref or using script scope explicitly and carefully, e.g., `script:varName`). Consider returning values from helper functions instead of direct script-scope modification for cleaner data flow, especially in modularized scripts.",
    "STRUCTURE: Respect the modular design (PoSh-Backup core modules, Reporting sub-modules, Bundler sub-modules). Ensure functions are placed in the most logical module.",
    "BRACES/PARENS: Meticulously check for balanced curly braces `{}`, parentheses `()`, and square brackets `[]` in all generated code, especially in complex `if/try/catch/finally` blocks and `param()` blocks.",
    "PSSA (BUNDLER): Bundler's `Invoke-ScriptAnalyzer` summary may not perfectly reflect all suppressions from `PSScriptAnalyzerSettings.psd1`, even if VS Code (with the settings file) shows no issues. This was observed with unused parameters in closures, requiring defensive code changes.",
    "PSSA (CLOSURES): PSScriptAnalyzer may not always detect parameter/variable usage within scriptblock closures assigned to local variables, potentially leading to false 'unused' warnings that require defensive/explicit calls for PSSA appeasement.",
    "PESTER (SESSION): Current Pester tests are non-functional. Significant issues encountered with Pester v5 environment, cmdlet availability (Get-Mock/Remove-Mock were not exported by Pester 5.7.1), mock scoping, and test logic that could not be resolved during the session. Further Pester work will require a reset or a different diagnostic approach.",
    "CRITICAL (PSD1_PARSING): `Import-PowerShellDataFile` can unexpectedly fail with 'dynamic expression' errors on double-quoted strings containing backtick-escaped `\$` if the overall string structure is complex (e.g., includes other backticks, parentheses, or special characters that confuse its parser). The safest workaround is to rephrase such strings to avoid literal `\$` characters entirely, or use single-quoted strings if the content's internal quoting allows it simply.",
    "LOGIC (CONFIRMATION): The interaction between `[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='...')`, `$PSCmdlet.ShouldProcess()`, `$ConfirmPreference`, and explicit `-Confirm` parameters on both the function call and internal cmdlets (like `Remove-Item`) is complex. Carefully test confirmation flows, especially when aiming for conditional suppression of prompts based on configuration." 
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
      "external_dependencies.executables (if new external tools are added - AI cannot auto-detect this reliably)"
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
      "__PS_DEPENDENCIES_PLACEHOLDER__" # Dynamically populated
    )
  }
}