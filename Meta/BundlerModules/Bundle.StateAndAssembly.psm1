<#
.SYNOPSIS
    Handles the generation of the AI State block and the final assembly of
    all content pieces for the AI project bundle.

.DESCRIPTION
    This module is responsible for two main tasks in the bundler process:
    1. Generating the complex AI State hashtable, which includes project metadata,
       conversation summaries, watch lists, and auto-detected information.
    2. Formatting and assembling all the different parts of the bundle (header, AI state,
       project structure, tool outputs, file contents) into the final string
       that will be written to the AI bundle file.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.6 # Fixed unused variable $psModulesForState in Get-BundlerAIState.
    DateCreated:    17-May-2025
    LastModified:   18-May-2025
    Purpose:        AI State generation and final bundle assembly for the AI project bundler.
#>

# --- Exported Functions ---

function Get-BundlerAIState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot_DisplayName,
        [Parameter(Mandatory)]
        [string]$PoShBackupVersion,
        [Parameter(Mandatory)]
        [string]$BundlerScriptVersion,
        [Parameter(Mandatory)]
        [hashtable]$AutoDetectedModuleDescriptions,
        [Parameter(Mandatory)]
        [object]$AutoDetectedPsDependencies # Changed type to object for more flexible binding
    )

    # This is the definition of the AI State block.
    # It's placed here to keep the main bundler script cleaner.
    
    $psModulesForState = @() # Default to an empty array
    if ($null -ne $AutoDetectedPsDependencies) {
        try {
            # Attempt to treat it as a collection and sort
            $psModulesForState = @($AutoDetectedPsDependencies | Sort-Object -Unique)
        } catch {
            Write-Warning "Bundler StateAndAssembly: Could not process AutoDetectedPsDependencies. Defaulting to empty list for AI State. Type was: $($AutoDetectedPsDependencies.GetType().FullName)"
            # $psModulesForState remains an empty array
        }
    }

    # Construct the conversation summary dynamically
    # Version of PoShBackupValidator.psm1: v1.2.1
    # Version of ConfigManager.psm1: v1.0.4
    # Version of Operations.psm1: v1.13.2
    # Version of 7ZipManager.psm1: v1.0.5
    # Version of this file (Bundle.StateAndAssembly.psm1): v1.0.6
    # Version of PoSh-Backup.ps1 is $PoShBackupVersion
    # Version of Config\Default.psd1: v1.2.2
    # Version of Meta\BundlerModules\Bundle.FileProcessor.psm1: v1.0.1
    # Version of Meta\BundlerModules\Bundle.ExternalTools.psm1: v1.1.0

    $currentConversationSummary = @(
        "Development of a comprehensive PowerShell file backup solution (PoSh-Backup.ps1 v$($PoShBackupVersion)).",
        "Modular design: Core modules (Utils, ConfigManager, Operations, Reporting, 7ZipManager, VssManager, RetentionManager, HookManager), Reporting sub-modules, Config files, and Meta/ (bundler).",
        "New Feature: Treat 7-Zip Warnings as Success (PoSh-Backup v$($PoShBackupVersion)):",
        "  - Added 'TreatSevenZipWarningsAsSuccess' setting (global, per-job) to Config\\Default.psd1 (v1.2.2).",
        "  - Added '-TreatSevenZipWarningsAsSuccessCLI' switch to PoSh-Backup.ps1 (v$($PoShBackupVersion)).",
        "  - Updated PoShBackupValidator.psm1 (v1.2.1) schema.",
        "  - Updated ConfigManager.psm1 (v1.0.4) to process the effective setting.",
        "  - Updated Operations.psm1 (v1.13.2) to adjust job status based on this setting.",
        "  - Updated 7ZipManager.psm1 (v1.0.5) to adjust logging and retry logic.",
        "Logging Enhancement: 7ZipManager.psm1 (v1.0.5) now hides 7-Zip STDOUT when 'HideSevenZipOutput' is true (STDERR is still logged).",
        "Previous Refactoring (PoSh-Backup v1.9.12): Centralized hook script execution into HookManager.psm1 and ensured explicit module dependency imports (Utils.psm1 for logging) across core modules.",
        "Bundler Script (Generate-ProjectBundleForAI.ps1 v$($BundlerScriptVersion)) Modularization & Fixes:",
        "  - Bundle.FileProcessor.psm1 (v1.0.1) now flags missing PowerShell synopses in AI State.",
        "  - Bundle.ExternalTools.psm1 (v1.1.0) PoSh-Backup -TestConfig capture removed.",
        "  - Bundle.StateAndAssembly.psm1 (v1.0.6) fixed unused variable warning.", # This module's version
        "  - PoSh-Backup -TestConfig output capture was removed from the bundler due to reliability issues.",
        "General project status: Core functionality stable. PSSA clean. Pester tests non-functional."
    )

    $aiState = @{
        project_name = "PoSh Backup Solution";
        main_script_poSh_backup_version = $PoShBackupVersion; 
        ai_bundler_update_instructions = @{
            purpose = "Instructions for AI on how to regenerate the content of this `$aiState hashtable within the Generate-ProjectBundleForAI.ps1 script when requested by the user.";
            example_of_ai_provided_block_start = "`$aiState = @{"; 
            output_format_for_ai = "Provide the updated `$aiState block as a complete PowerShell hashtable string, ready for copy-pasting directly into Generate-ProjectBundleForAI.ps1 (specifically, into the Get-BundlerAIState function within Bundle.StateAndAssembly.psm1), replacing the existing `$aiState = @{ ... }` block. Ensure strings are correctly quoted and arrays use PowerShell syntax, e.g., `@('item1', 'item2')`.";
            reminder_for_ai = "When asked to update this state, proactively consider if any recent challenges or frequent corrections should be added to the 'ai_development_watch_list'.";
            fields_to_be_updated_by_user = @(
                "external_dependencies.executables (if new external tools are added - AI cannot auto-detect this reliably)"
            );
            fields_to_update_by_ai = @(
                "conversation_summary: Refine based on newly implemented and stable features reflected in the code. Focus on *what is currently in the code*.",
                "module_descriptions: AI should verify/update this based on current file synopses if major changes occur to files or new modules are added/removed (auto-detected by bundler).",
                "external_dependencies.powershell_modules: AI should verify this list if new #Requires statements are added/removed from scripts (auto-detected by bundler).",
                "main_script_poSh_backup_version: AI should update this if it modifies PoSh-Backup.ps1's version information (auto-read by this bundler).",
                "bundler_script_version: AI should update this if it modifies this bundler script's version information (auto-read by this bundler).",
                "ai_development_watch_list: AI should review this list. If new persistent common errors or important reminders have emerged during the session, AI should suggest or include updates to this list when asked to update the bundler state."
            );
            when_to_update = "Only when the user explicitly asks to 'update the bundler script's AI state'.";
            example_of_ai_provided_block_end = "}"
        };
        bundler_script_version = $BundlerScriptVersion; 
        conversation_summary = $currentConversationSummary; # Use the dynamically constructed summary
        project_root_folder_name = $ProjectRoot_DisplayName;
        bundle_generation_time = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss");
        module_descriptions = $AutoDetectedModuleDescriptions; 
        external_dependencies = @{
            executables = @(
                "7z.exe (7-Zip command-line tool - path configurable or auto-detected)"
            );
            powershell_modules = $psModulesForState 
        };
        ai_development_watch_list = @(
            "CRITICAL (AI): Ensure full, untruncated files are provided when requested by the user. AI has made this mistake multiple times.",
            "CRITICAL (AI): Verify line counts and comment integrity when AI provides full script updates; inadvertent removal/truncation has occurred (e.g., missing comments, fewer lines than expected).",
            "CRITICAL (AI): Ensure no extraneous trailing whitespace is introduced on any lines, including apparently blank ones when providing code.",
            "CRITICAL (SYNTAX): For literal triple backticks (```) in PowerShell strings meant for Markdown code fences, use single quotes: `'```' (e.g., `$sb.AppendLine('```')`). Double quotes will cause parsing errors or misinterpretation.",
            "SYNTAX: PowerShell ordered dictionaries (`[ordered]@{}`) use `(\$dict.PSObject.Properties.Name -contains 'Key')`, NOT `\$dict.ContainsKey('Key')`.",
            "REGEX: Be cautious with string interpolation vs. literal characters in regex patterns. Test regex patterns carefully. Ensure PowerShell string parsing is correct before regex engine sees it (e.g., use single-quoted strings for regex patterns, ensure proper escaping of special characters within the pattern if needed).",
            "LOGIC: Verify `IsSimulateMode` flag is consistently propagated and handled, especially for I/O operations and status reporting.",
            "DATA FLOW: Ensure data for reports (like `IsSimulationReport`, `OverallStatus`) is correctly set in the `\$ReportData` ref object *before* report generation functions are called.",
            "SCOPE: Double-check variable scopes when helper functions modify collections intended for wider use (prefer passing by ref or using script scope explicitly and carefully, e.g., `$script:varName`). Consider returning values from helper functions instead of direct script-scope modification for cleaner data flow, especially in modularized scripts.",
            "STRUCTURE: Respect the modular design (PoSh-Backup core modules, Reporting sub-modules, Bundler sub-modules). Ensure functions are placed in the most logical module.",
            "BRACES/PARENS: Meticulously check for balanced curly braces `{}`, parentheses `()`, and square brackets `[]` in all generated code, especially in complex `if/try/catch/finally` blocks and `param()` blocks.",
            "PSSA (BUNDLER): Bundler's `Invoke-ScriptAnalyzer` summary may not perfectly reflect all suppressions from `PSScriptAnalyzerSettings.psd1`, even if VS Code (with the settings file) shows no issues. This was observed with unused parameters in closures, requiring defensive code changes.",
            "PSSA (CLOSURES): PSScriptAnalyzer may not always detect parameter/variable usage within scriptblock closures assigned to local variables, potentially leading to false 'unused' warnings that require defensive/explicit calls for PSSA appeasement.",
            "PESTER (SESSION): Current Pester tests are non-functional. Significant issues encountered with Pester v5 environment, cmdlet availability (Get-Mock/Remove-Mock were not exported by Pester 5.7.1), mock scoping, and test logic that could not be resolved during the session. Further Pester work will require a reset or a different diagnostic approach."
        )
    }

    return $aiState
}

function Format-AIBundleContent {
    [CmdletBinding()]
    <#
    .SYNOPSIS
        Formats and assembles all constituent parts of the AI bundle into a single string.
    .DESCRIPTION
        This function takes various pre-generated content strings (header, AI state, project structure, etc.)
        and concatenates them in the correct order using a StringBuilder to produce the final, complete
        content for the AI bundle file.
        The PoSh-Backup -TestConfig output has been removed from the bundle.
    .PARAMETER HeaderContent
        The introductory header string for the bundle.
    .PARAMETER AIStateHashtable
        The AI State data, which will be converted to JSON within this function.
    .PARAMETER ProjectStructureContent
        A string representing the project's directory structure.
    .PARAMETER AnalyzerSettingsFileContent
        Optional. The content of the PSScriptAnalyzerSettings.psd1 file.
    .PARAMETER PSSASummaryOutputContent
        Optional. The formatted summary output from PSScriptAnalyzer.
    .PARAMETER BundledFilesContent
        A string containing all the formatted file contents for the bundle.
    .OUTPUTS
        System.String
        The complete, assembled content of the AI bundle as a single string.
    .EXAMPLE
        # $finalBundle = Format-AIBundleContent -HeaderContent $header -AIStateHashtable $state -ProjectStructureContent $structure -BundledFilesContent $files
        # $finalBundle | Set-Content "bundle.txt"
    #>
    param(
        [Parameter(Mandatory)]
        [string]$HeaderContent,
        [Parameter(Mandatory)]
        [hashtable]$AIStateHashtable,
        [Parameter(Mandatory)]
        [string]$ProjectStructureContent,
        # TestConfigOutputContent parameter removed
        [Parameter(Mandatory=$false)]
        [string]$AnalyzerSettingsFileContent, # Content of PSScriptAnalyzerSettings.psd1
        [Parameter(Mandatory=$false)]
        [string]$PSSASummaryOutputContent,
        [Parameter(Mandatory)]
        [string]$BundledFilesContent
    )

    $finalOutputBuilder = [System.Text.StringBuilder]::new()

    # 1. Header
    $null = $finalOutputBuilder.Append($HeaderContent)

    # 2. AI State
    $null = $finalOutputBuilder.AppendLine("--- AI_STATE_START ---")
    $null = $finalOutputBuilder.AppendLine('```json')
    if ($null -ne $AIStateHashtable) {
        $null = $finalOutputBuilder.AppendLine(($AIStateHashtable | ConvertTo-Json -Depth 10))
    } else {
        $null = $finalOutputBuilder.AppendLine("(AI State Hashtable was null and could not be converted to JSON)")
    }
    $null = $finalOutputBuilder.AppendLine('```')
    $null = $finalOutputBuilder.AppendLine("--- AI_STATE_END ---")
    $null = $finalOutputBuilder.AppendLine("")

    # 3. Project Structure Overview
    $null = $finalOutputBuilder.AppendLine("--- PROJECT_STRUCTURE_OVERVIEW ---")
    $null = $finalOutputBuilder.AppendLine($ProjectStructureContent) 
    $null = $finalOutputBuilder.AppendLine("--- END_PROJECT_STRUCTURE_OVERVIEW ---")
    $null = $finalOutputBuilder.AppendLine("")

    # 4. PoSh-Backup -TestConfig Output (SECTION REMOVED)
    # if (-not [string]::IsNullOrWhiteSpace($TestConfigOutputContent)) {
    #     $null = $finalOutputBuilder.AppendLine("--- POSH_BACKUP_TESTCONFIG_OUTPUT_START ---")
    #     $null = $finalOutputBuilder.AppendLine($TestConfigOutputContent) 
    #     $null = $finalOutputBuilder.AppendLine("--- POSH_BACKUP_TESTCONFIG_OUTPUT_END ---")
    #     $null = $finalOutputBuilder.AppendLine("")
    # }

    # 5. PSScriptAnalyzerSettings.psd1 content (if provided)
    if (-not [string]::IsNullOrWhiteSpace($AnalyzerSettingsFileContent)) {
        $null = $finalOutputBuilder.AppendLine("--- PSSCRIPTANALYZER_SETTINGS_FILE_CONTENT_START ---")
        $null = $finalOutputBuilder.AppendLine("Path: PSScriptAnalyzerSettings.psd1 (Project Root)")
        $null = $finalOutputBuilder.AppendLine("--- FILE_CONTENT ---")
        $null = $finalOutputBuilder.AppendLine('```powershell')
        $null = $finalOutputBuilder.AppendLine($AnalyzerSettingsFileContent)
        $null = $finalOutputBuilder.AppendLine('```')
        $null = $finalOutputBuilder.AppendLine("--- PSSCRIPTANALYZER_SETTINGS_FILE_CONTENT_END ---")
        $null = $finalOutputBuilder.AppendLine("")
    }

    # 6. PSScriptAnalyzer Summary (if provided)
    if (-not [string]::IsNullOrWhiteSpace($PSSASummaryOutputContent)) {
        $null = $finalOutputBuilder.AppendLine("--- PS_SCRIPT_ANALYZER_SUMMARY ---")
        $null = $finalOutputBuilder.AppendLine($PSSASummaryOutputContent) 
        $null = $finalOutputBuilder.AppendLine("--- END_PS_SCRIPT_ANALYZER_SUMMARY ---")
        $null = $finalOutputBuilder.AppendLine("")
    }

    # 7. Bundled Files Content
    $null = $finalOutputBuilder.Append($BundledFilesContent) 

    # 8. Footer
    $null = $finalOutputBuilder.AppendLine("-----------------------------------")
    $null = $finalOutputBuilder.AppendLine("--- END OF PROJECT FILE BUNDLE ---")

    return $finalOutputBuilder.ToString()
}

Export-ModuleMember -Function Get-BundlerAIState, Format-AIBundleContent
