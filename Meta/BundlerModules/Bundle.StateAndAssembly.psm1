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
    Version:        1.1.1 # Updated summary for UNC Target's CreateJobNameSubdirectory option.
    DateCreated:    17-May-2025
    LastModified:   19-May-2025
    Purpose:        AI State generation and final bundle assembly for the AI project bundler.
#>

# Explicitly import Utils.psm1 from the parent Meta directory to ensure Get-ScriptVersionFromContent is available
# $PSScriptRoot here is Meta\BundlerModules
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Modules\Utils.psm1") -Force -ErrorAction Stop -WarningAction SilentlyContinue
} catch {
    Write-Warning "Bundle.StateAndAssembly.psm1: Could not import main Utils.psm1 for Get-ConfigValue. This might affect dynamic population if specific config values were needed here (currently not)."
}


#region --- Exported Functions ---

function Get-BundlerAIState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot_DisplayName,
        [Parameter(Mandatory)]
        [string]$PoShBackupVersion, # Version of the main PoSh-Backup.ps1 script
        [Parameter(Mandatory)]
        [string]$BundlerScriptVersion, # Version of Generate-ProjectBundleForAI.ps1
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
    $aiState.main_script_poSh_backup_version = $PoShBackupVersion # e.g., "1.10.0"
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
    # Reflects state AFTER the current session's changes for Backup Targets
    # Version of THIS Bundle.StateAndAssembly.psm1 module
    $thisModuleVersion = "1.1.1" # Version of THIS Bundle.StateAndAssembly.psm1 module

    $currentConversationSummary = @(
        "Development of a comprehensive PowerShell file backup solution (PoSh-Backup.ps1 v$($PoShBackupVersion)).", # e.g. v1.10.0
        "Modular design: Core modules, Reporting sub-modules, Config files, and Meta/ (bundler).",
        "AI State structure is loaded from 'Meta\\AIState.template.psd1' and dynamically populated by Bundle.StateAndAssembly.psm1 (v$($thisModuleVersion)).",
        "--- Major New Feature: Backup Targets ---",
        "  - Goal: Allow backups to be sent to remote locations (UNC, FTP, S3, etc.) via an extensible provider model.",
        "  - Configuration (`Default.psd1` v1.3.1):", # Updated version
        "    - Added global `BackupTargets` section to define named remote target instances (e.g., Type 'UNC', `TargetSpecificSettings`).",
        "    - In `BackupLocations` (job definitions): Renamed `RetentionCount` to `LocalRetentionCount`, added `TargetNames` (array), `DeleteLocalArchiveAfterSuccessfulTransfer` (boolean).",
        "    - For UNC targets, added `CreateJobNameSubdirectory` (boolean, default `$false`) to `TargetSpecificSettings` to control if archives are placed directly in `UNCRemotePath` or in a `JobName` subfolder.", # NEW sub-point
        "  - `ConfigManager.psm1` (v1.1.0): Updated to load and resolve all new target-related settings.",
        "  - `PoShBackupValidator.psm1` (v1.3.1): Schema updated for all new target settings, including `CreateJobNameSubdirectory` for UNC.", # Updated version
        "  - New Target Provider Module (`Modules\\Targets\\UNC.Target.psm1` v1.0.1):", # Updated version
        "    - Created to handle transfers to UNC paths.",
        "    - Implements `Invoke-PoShBackupTargetTransfer` function.",
        "    - Includes logic for creating job-specific subdirectories on the UNC share (now optional via `CreateJobNameSubdirectory`).", # Updated sub-point
        "    - Implements basic count-based remote retention on the UNC target.",
        "  - `Operations.psm1` (v1.15.0): Orchestrates the transfer loop, dynamically loads providers, calls `Invoke-PoShBackupTargetTransfer`, handles local staged archive deletion, updates report data.",
        "  - Reporting Modules Updated:",
        "    - `ReportingHtml.psm1` (v1.9.1): Added 'Remote Target Transfers' section. Corrected HTML encoder syntax.",
        "    - `ReportingTxt.psm1` (v1.2.0): Added 'REMOTE TARGET TRANSFERS' section.",
        "    - `ReportingCsv.psm1` (v1.2.0): Generates `JobName_TargetTransfers_Timestamp.csv`.",
        "    - `ReportingMd.psm1` (v1.3.0): Added 'Remote Target Transfers' table.",
        "    - `ReportingXml.psm1` (v1.2.0): `TargetTransfers` data included automatically.",
        "  - `PoSh-Backup.ps1` (v1.10.0): Synopsis, description, version updated.",
        "  - `README.md`: Updated to explain the new Backup Target feature, configuration (including `CreateJobNameSubdirectory`), and usage.",
        "  - `AIState.template.psd1`: Watchlist updated for file truncation, baseline verification, and syntax issues.", # Updated this file
        "--- Previous Work (Selected Highlights) ---", # Condensed previous work for brevity
        "Network Share Handling Improvements (`Operations.psm1` pre-v1.15.0, `Config\Default.psd1` pre-v1.3.0).",
        "Retention Policy Confirmation logic (`RetentionManager.psm1`, etc.).",
        "HTML Report VSS field updates and general interactivity enhancements (`ReportingHtml.psm1` pre-v1.9.0).",
        "General stability and PSSA compliance efforts.",
        "Bundler Script (Generate-ProjectBundleForAI.ps1 v$($BundlerScriptVersion)) is stable.", # Bundler version
        "Overall project status: Core local backup functionality stable. New Backup Target feature (UNC) implemented. PSSA clean. Pester tests non-functional."
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
#endregion
