<#
.SYNOPSIS
    Handles the generation of the AI State block and the final assembly of
    all content pieces for the AI project bundle.

.DESCRIPTION
    This module is responsible for two main tasks in the bundler process:
    1. Generating the complex AI State hashtable, which includes project metadata,
       conversation summaries, watch lists, and auto-detected information.
       The AI State structure is loaded from 'Meta\AIState.template.psd1' and then
       dynamically populated.
    2. Formatting and assembling all the different parts of the bundle (header, AI state,
       project structure, tool outputs, file contents) into the final string
       that will be written to the AI bundle file.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.7 # Load AI State from Meta\AIState.template.psd1.
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

    # $PSScriptRoot for this module (Bundle.StateAndAssembly.psm1) is Meta\BundlerModules
    # The AIState.template.psd1 is intended to be in Meta\
    $aiStateTemplatePath = Join-Path -Path $PSScriptRoot -ChildPath "..\AIState.template.psd1"
    
    $aiState = $null
    try {
        $aiState = Import-PowerShellDataFile -LiteralPath $aiStateTemplatePath -ErrorAction Stop
    } catch {
        Write-Error "FATAL (Bundler StateAndAssembly): Could not load AI State template from '$aiStateTemplatePath'. Error: $($_.Exception.Message)"
        # Return a minimal error state or re-throw, depending on desired bundler robustness
        return @{
            error = "Failed to load AIState.template.psd1"
            details = $_.Exception.Message
            bundle_generation_time = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }

    # Populate/Overwrite dynamic fields in the loaded template
    $aiState.bundle_generation_time = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $aiState.main_script_poSh_backup_version = $PoShBackupVersion
    $aiState.bundler_script_version = $BundlerScriptVersion
    $aiState.project_root_folder_name = $ProjectRoot_DisplayName
    $aiState.module_descriptions = $AutoDetectedModuleDescriptions # This is a hashtable itself
    
    $psModulesForState = @() 
    if ($null -ne $AutoDetectedPsDependencies) {
        try {
            $psModulesForState = @($AutoDetectedPsDependencies | Sort-Object -Unique)
        } catch {
            Write-Warning "Bundler StateAndAssembly: Could not process AutoDetectedPsDependencies. Defaulting to empty list for AI State. Type was: $($AutoDetectedPsDependencies.GetType().FullName)"
        }
    }
    # Ensure external_dependencies key exists before trying to access its subkey
    if (-not $aiState.ContainsKey('external_dependencies')) { $aiState.external_dependencies = @{} }
    $aiState.external_dependencies.powershell_modules = $psModulesForState 

    # Dynamically construct the conversation summary
    # Versions of PoShBackupValidator.psm1: v1.2.1
    # Versions of ConfigManager.psm1: v1.0.4
    # Versions of Operations.psm1: v1.13.2
    # Versions of 7ZipManager.psm1: v1.0.5
    # Versions of this file (Bundle.StateAndAssembly.psm1): v1.0.7 (New Version)
    # Versions of PoSh-Backup.ps1 is $PoShBackupVersion
    # Versions of Config\Default.psd1: v1.2.2
    # Versions of Meta\BundlerModules\Bundle.FileProcessor.psm1: v1.0.1
    # Versions of Meta\BundlerModules\Bundle.ExternalTools.psm1: v1.1.0
    # New file Meta\AIState.template.psd1 (not versioned in the same way, but its existence is key)

    $currentConversationSummary = @(
        "Development of a comprehensive PowerShell file backup solution (PoSh-Backup.ps1 v$($PoShBackupVersion)).",
        "Modular design: Core modules, Reporting sub-modules, Config files, and Meta/ (bundler).",
        "AI State structure is now loaded from 'Meta\\AIState.template.psd1' and dynamically populated by Bundle.StateAndAssembly.psm1 (v1.0.7).",
        "New Feature (PoSh-Backup): Treat 7-Zip Warnings as Success (PoSh-Backup v$($PoShBackupVersion)):",
        "  - Added 'TreatSevenZipWarningsAsSuccess' setting (global, per-job) to Config\\Default.psd1 (v1.2.2).",
        "  - Added '-TreatSevenZipWarningsAsSuccessCLI' switch to PoSh-Backup.ps1 (v$($PoShBackupVersion)).",
        "  - Updated PoShBackupValidator.psm1 (v1.2.1) schema.",
        "  - Updated ConfigManager.psm1 (v1.0.4) to process the effective setting.",
        "  - Updated Operations.psm1 (v1.13.2) to adjust job status based on this setting.",
        "  - Updated 7ZipManager.psm1 (v1.0.5) to adjust logging and retry logic.",
        "Logging Enhancement: 7ZipManager.psm1 (v1.0.5) now hides 7-Zip STDOUT when 'HideSevenZipOutput' is true (STDERR is still logged).",
        "Previous Refactoring (PoSh-Backup v1.9.12): Centralized hook script execution into HookManager.psm1.",
        "Bundler Script (Generate-ProjectBundleForAI.ps1 v$($BundlerScriptVersion)) Modularization & Fixes:",
        "  - Bundle.FileProcessor.psm1 (v1.0.1) now flags missing PowerShell synopses in AI State.",
        "  - Bundle.ExternalTools.psm1 (v1.1.0) PoSh-Backup -TestConfig capture removed.",
        "  - PoSh-Backup -TestConfig output capture was removed from the bundler due to reliability issues.",
        "General project status: Core functionality stable. PSSA clean. Pester tests non-functional."
    )
    $aiState.conversation_summary = $currentConversationSummary

    return $aiState
}

function Format-AIBundleContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$HeaderContent,
        [Parameter(Mandatory)]
        [hashtable]$AIStateHashtable,
        [Parameter(Mandatory)]
        [string]$ProjectStructureContent,
        [Parameter(Mandatory=$false)]
        [string]$AnalyzerSettingsFileContent, 
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
        $null = $finalOutputBuilder.AppendLine(($AIStateHashtable | ConvertTo-Json -Depth 10 -Compress)) # Added -Compress
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

    # 4. PSScriptAnalyzerSettings.psd1 content (if provided)
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

    # 5. PSScriptAnalyzer Summary (if provided)
    if (-not [string]::IsNullOrWhiteSpace($PSSASummaryOutputContent)) {
        $null = $finalOutputBuilder.AppendLine("--- PS_SCRIPT_ANALYZER_SUMMARY ---")
        $null = $finalOutputBuilder.AppendLine($PSSASummaryOutputContent) 
        $null = $finalOutputBuilder.AppendLine("--- END_PS_SCRIPT_ANALYZER_SUMMARY ---")
        $null = $finalOutputBuilder.AppendLine("")
    }

    # 6. Bundled Files Content
    $null = $finalOutputBuilder.Append($BundledFilesContent) 

    # 7. Footer
    $null = $finalOutputBuilder.AppendLine("-----------------------------------")
    $null = $finalOutputBuilder.AppendLine("--- END OF PROJECT FILE BUNDLE ---")

    return $finalOutputBuilder.ToString()
}

Export-ModuleMember -Function Get-BundlerAIState, Format-AIBundleContent
