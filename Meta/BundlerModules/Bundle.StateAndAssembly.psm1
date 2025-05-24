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
    Version:        1.1.8 # Updated conversation summary for PSSA fixes post-refactoring.
    DateCreated:    17-May-2025
    LastModified:   24-May-2025
    Purpose:        AI State generation and final bundle assembly for the AI project bundler.
#>

# Explicitly import Utils.psm1 from the parent Meta directory to ensure Get-ScriptVersionFromContent is available
# $PSScriptRoot here is Meta\BundlerModules
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Modules\Utils.psm1") -Force -ErrorAction Stop -WarningAction SilentlyContinue
}
catch {
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
    }
    catch {
        Write-Error "FATAL (Bundler StateAndAssembly): Could not load AI State template from '$aiStateTemplatePath'. Error: $($_.Exception.Message)"
        return @{
            error                  = "Failed to load AIState.template.psd1"
            details                = $_.Exception.Message
            bundle_generation_time = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }

    $aiState.bundle_generation_time = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $aiState.main_script_poSh_backup_version = $PoShBackupVersion
    $aiState.bundler_script_version = $BundlerScriptVersion
    $aiState.project_root_folder_name = $ProjectRoot_DisplayName
    $aiState.module_descriptions = $AutoDetectedModuleDescriptions
    
    $psModulesForState = @()
    if ($null -ne $AutoDetectedPsDependencies) {
        try {
            $psModulesForState = @($AutoDetectedPsDependencies | Sort-Object -Unique)
        }
        catch {
            Write-Warning "Bundler StateAndAssembly: Could not process AutoDetectedPsDependencies. Defaulting to empty list for AI State. Type was: $($AutoDetectedPsDependencies.GetType().FullName)"
        }
    }
    if (-not $aiState.ContainsKey('external_dependencies')) { $aiState.external_dependencies = @{} }
    $aiState.external_dependencies.powershell_modules = $psModulesForState

    $thisModuleVersion = "1.1.8" # Updated version of this specific module
    
    # This $currentConversationSummary should match the one in AIState.template.psd1
    $currentConversationSummary = @(
        "Development of a comprehensive PowerShell file backup solution (PoSh-Backup.ps1 v$($PoShBackupVersion)).",
        "Modular design: Core modules, Reporting sub-modules (including new `Modules\\Reporting\\Assets` directory for HTML report assets), Config files, and Meta/ (bundler).",
        "AI State structure is loaded from 'Meta\\AIState.template.psd1' and dynamically populated by Bundle.StateAndAssembly.psm1 (v$($thisModuleVersion)).",
        "--- Further Modularisation of PoSh-Backup.ps1 and ReportingHtml.psm1 (Current Session) ---",
        "  - Goal: Reduce size of larger script files for AI efficiency and improve maintainability.",
        "  - `PoSh-Backup.ps1` (v1.11.4 -> v$($PoShBackupVersion)) refactored:", # Use dynamic PoShBackupVersion
        "    - Logic for `-ListBackupLocations`, `-ListBackupSets`, and `-TestConfig` modes moved to a new module.",
        "    - New module: `Modules\\ScriptModeHandler.psm1` (v1.0.0) created to handle these informational modes, which calls `exit` internally.",
        "    - This significantly reduced the line count of `PoSh-Backup.ps1` (approx. -90 lines).",
        "  - `Modules\\Reporting\\ReportingHtml.psm1` (v1.9.2 -> v1.9.10) refactored in two stages:", 
        "    - Stage 1: Client-side JavaScript externalised to `Modules\\Reporting\\Assets\\ReportingHtml.Client.js`.",
        "    - Stage 2: Static HTML structure aggressively externalised to `Modules\\Reporting\\Assets\\ReportingHtml.template.html`.",
        "    - `ReportingHtml.psm1` now primarily handles data processing and injection into the HTML template, significantly reducing its line count.",
        "  - PSSA warning for unused Logger parameter in `ReportingHtml.psm1` (v1.9.10) addressed by adding a direct call to the logger.",
        "  - Console blank line issue during HTML report generation investigated and resolved by refactoring internal logger helper in `ReportingHtml.psm1` and removing temporary diagnostic lines.",
        "--- Major Refactoring: Modularisation of Operations.psm1 and ConfigManager.psm1 (Previous Session) ---",
        "  - Goal: Improve maintainability, readability, and testability of large modules.",
        "  - `Operations.psm1` (v1.18.6 -> v1.19.3) refactored:",
        "    - Now acts as an orchestrator for job lifecycle stages.",
        "    - New sub-module: `Modules\\Operations\\LocalArchiveProcessor.psm1` (v1.0.2) created.",
        "    - New sub-module: `Modules\\Operations\\RemoteTransferOrchestrator.psm1` (v1.0.1) created.",
        "  - `ConfigManager.psm1` (v1.1.5 -> v1.2.0) refactored:",
        "    - Now acts as a facade for configuration management functions.",
        "    - New sub-module: `Modules\\ConfigManagement\\ConfigLoader.psm1` (v1.0.0) created.",
        "    - New sub-module: `Modules\\ConfigManagement\\JobResolver.psm1` (v1.0.1) created.",
        "    - New sub-module: `Modules\\ConfigManagement\\EffectiveConfigBuilder.psm1` (v1.0.1) created.",
        "  - All refactoring changes tested successfully by the user.", # This line was in the initial bundle's summary for this section
        "  - PSScriptAnalyzer issues (unused loggers, cmdlet naming, empty catch block) addressed in the new and refactored modules.", # This line was in the initial bundle's summary for this section
        "  - `SFTP.Target.psm1` updated to v1.0.3 with inline PSSA suppressions for `ConvertTo-SecureString`.", # This line was in the initial bundle's summary for this section
        "--- Previous Major Feature: Archive Checksum Generation & Verification ---",
        "  - Goal: Enhance archive integrity with optional checksums.",
        "  - Configuration (`Config\\Default.psd1` v1.3.6): Added global and job-level checksum settings.",
        "  - Schema Validation (`Modules\\PoShBackupValidator.psm1` v1.3.6): Updated for checksum settings.",
        "  - Utility Function (`Modules\\Utils.psm1` v1.12.0): Added `Get-PoshBackupFileHash`.",
        "  - Operations (`Modules\\Operations.psm1` v1.18.6 - before refactor): Implemented checksum logic.", # From initial bundle
        "  - Config Management (`Modules\\ConfigManager.psm1` v1.1.5 - before refactor): Resolved checksum settings.", # From initial bundle
        "  - Reporting Modules: Updated to display checksum information.", # From initial bundle
        "  - Main Script (`PoSh-Backup.ps1` v1.11.0 - for checksums, current v$($PoShBackupVersion)): Synopsis updated.", # From initial bundle, updated current version
        "  - Documentation (`README.md`): Updated for Checksum feature.", # From initial bundle
        "--- Previous Major Feature: Post-Run System Actions (Shutdown, Restart, etc.) ---",
        "  - Goal: Allow PoSh-Backup to perform system state changes after job/set completion.",
        "  - New Module (`Modules\\SystemStateManager.psm1` v1.0.2).",
        "  - Configuration (`Config\\Default.psd1` v1.3.5): Added PostRunAction settings.", # From initial bundle
        "  - Schema Validation (`Modules\\PoShBackupValidator.psm1` v1.3.5): Updated.", # From initial bundle
        "  - Config Management (`Modules\\ConfigManager.psm1` v1.1.4 - before checksums & major refactor): Updated.", # From initial bundle
        "  - Main Script (`PoSh-Backup.ps1` v1.10.1 - for PostRunAction): Updated.", # From initial bundle
        "  - Documentation (`README.md`): Updated.", # From initial bundle
        "--- Previous Major Feature: Backup Targets (Expanded) ---",
        "  - Goal: Allow backups to be sent to remote locations via an extensible provider model.",
        "  - Configuration (Default.psd1 v1.3.3): Added `BackupTargets`, `TargetNames`, etc.", # From initial bundle
        "  - Target Providers: `UNC.Target.psm1` (v1.1.2), `Replicate.Target.psm1` (v1.0.2), `SFTP.Target.psm1` (v1.0.3).", # Updated SFTP version, removed comment for brevity here
        "  - Operations.psm1 (v1.17.3 - before PostRunAction, Checksum, & major refactor): Orchestrated target transfers.", # From initial bundle
        "  - Reporting Modules: Updated for `TargetTransfers` data.", # From initial bundle
        "  - README.md: Updated for 'Replicate' and 'SFTP' target providers.", # From initial bundle
        "--- Previous Work (Selected Highlights) ---",
        "Network Share Handling Improvements, Retention Policy Confirmation, HTML Report Enhancements, PSSA compliance.",
        "Bundler Script (Generate-ProjectBundleForAI.ps1 v$($BundlerScriptVersion)) is stable.",
        "Overall project status: Core local backup stable. Remote targets, Post-Run Actions, Checksums features added. Major refactorings completed. `PoSh-Backup.ps1` and `ReportingHtml.psm1` significantly reduced in size. PSSA summary expected to be clean except for known SFTP `ConvertTo-SecureString` items and the `Operations.psm1` empty catch block anomaly. Pester tests non-functional."
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
        [Parameter(Mandatory = $false)]
        [string]$AnalyzerSettingsFileContent,
        [Parameter(Mandatory = $false)]
        [string]$PSSASummaryOutputContent,
        [Parameter(Mandatory)]
        [string]$BundledFilesContent
    )

    $finalOutputBuilder = [System.Text.StringBuilder]::new()

    $null = $finalOutputBuilder.Append($HeaderContent)
    $null = $finalOutputBuilder.AppendLine("--- AI_STATE_START ---")
    $null = $finalOutputBuilder.AppendLine('```json')
    if ($null -ne $AIStateHashtable) {
        $null = $finalOutputBuilder.AppendLine(($AIStateHashtable | ConvertTo-Json -Depth 10 -Compress))
    }
    else {
        $null = $finalOutputBuilder.AppendLine("(AI State Hashtable was null and could not be converted to JSON)")
    }
    $null = $finalOutputBuilder.AppendLine('```')
    $null = $finalOutputBuilder.AppendLine("--- AI_STATE_END ---")
    $null = $finalOutputBuilder.AppendLine("")

    $null = $finalOutputBuilder.AppendLine("--- PROJECT_STRUCTURE_OVERVIEW ---")
    $null = $finalOutputBuilder.AppendLine($ProjectStructureContent)
    $null = $finalOutputBuilder.AppendLine("--- END_PROJECT_STRUCTURE_OVERVIEW ---")
    $null = $finalOutputBuilder.AppendLine("")

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

    if (-not [string]::IsNullOrWhiteSpace($PSSASummaryOutputContent)) {
        $null = $finalOutputBuilder.AppendLine("--- PS_SCRIPT_ANALYZER_SUMMARY ---")
        $null = $finalOutputBuilder.AppendLine($PSSASummaryOutputContent)
        $null = $finalOutputBuilder.AppendLine("--- END_PS_SCRIPT_ANALYZER_SUMMARY ---")
        $null = $finalOutputBuilder.AppendLine("")
    }

    $null = $finalOutputBuilder.Append($BundledFilesContent)
    $null = $finalOutputBuilder.AppendLine("-----------------------------------")
    $null = $finalOutputBuilder.AppendLine("--- END OF PROJECT FILE BUNDLE ---")

    return $finalOutputBuilder.ToString()
}

Export-ModuleMember -Function Get-BundlerAIState, Format-AIBundleContent
#endregion
