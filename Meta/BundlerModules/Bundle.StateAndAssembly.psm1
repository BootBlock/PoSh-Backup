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
    Version:        1.1.13 # 7-Zip CPU affinity
    DateCreated:    17-May-2025
    LastModified:   25-May-2025
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

    $thisModuleVersion = "1.1.13" # Updated version of this specific module
    
    $currentConversationSummary = @(
        "Development of a comprehensive PowerShell file backup solution (PoSh-Backup.ps1 v$($PoShBackupVersion)).", # PoSh-Backup version will be 1.13.0
        "Modular design: Core modules (now including Modules\\Core\\), Reporting sub-modules (including Modules\\Reporting\\Assets), ConfigManagement sub-modules (including Modules\\ConfigManagement\\Assets), Utilities sub-modules (Modules\\Utilities\\), Config files, and Meta/ (bundler).",
        "AI State structure is loaded from 'Meta\\AIState.template.psd1' and dynamically populated by Bundle.StateAndAssembly.psm1 (v$($thisModuleVersion)).",
        "--- Feature: Self-Extracting Archives (SFX) (Current Session) ---",
        "  - Goal: Option to create self-extracting archives (.exe) for easier restoration, with user-selectable SFX module type.",
        "  - Stage 1 (Basic SFX):",
        "    - `Config\\Default.psd1` (v1.3.8 -> v1.3.9): Added global `DefaultCreateSFX` and job-level `CreateSFX` settings.",
        "    - `Modules\\ConfigManagement\\Assets\\ConfigSchema.psd1`: Updated for `DefaultCreateSFX` and `CreateSFX`.",
        "    - `Modules\\ConfigManagement\\EffectiveConfigBuilder.psm1` (v1.0.1 -> v1.0.2): Modified to resolve `CreateSFX` and force `.exe` extension if true, storing original extension as `InternalArchiveExtension`.",
        "    - `Modules\\7ZipManager.psm1` (v1.0.6 -> v1.0.7): Modified `Get-PoShBackup7ZipArgument` to add `-sfx` switch if `CreateSFX` is true.",
        "    - `Modules\\Operations\\LocalArchiveProcessor.psm1` (v1.0.3 -> v1.0.4): Ensured `JobArchiveExtension` (which could be `.exe`) is used for archive naming.",
        "    - `README.md`: Updated with SFX feature details and configuration examples.",
        "  - Stage 2 (SFX Module Option - Current Session Segment):",
        "    - `Config\\Default.psd1` (v1.3.9 -> v1.4.0): Added global `DefaultSFXModule` and job-level `SFXModule` settings (options: Console, GUI, Installer).",
        "    - `Modules\\ConfigManagement\\Assets\\ConfigSchema.psd1`: Updated for `DefaultSFXModule` and `SFXModule` with allowed values.",
        "    - `Modules\\ConfigManagement\\EffectiveConfigBuilder.psm1` (v1.0.2 -> v1.0.3): Modified to resolve `SFXModule` setting.",
        "    - `Modules\\7ZipManager.psm1` (v1.0.7 -> v1.0.8): Modified `Get-PoShBackup7ZipArgument` to use the resolved `SFXModule` to select the appropriate `-sfx[module_name.sfx]` switch.",
        "    - `Modules\\Operations\\LocalArchiveProcessor.psm1` (v1.0.4 -> v1.0.5): Added `SFXModule` to report data.",
        "    - `README.md`: Updated to describe `SFXModule` options and examples.",
        "  - All changes tested successfully by the user.",
        "--- Refactoring of PoSh-Backup.ps1 and Core Modules (Previous Session Segment) ---",
        "  - Goal: Further modularise PoSh-Backup.ps1 by extracting its main job processing loop.",
        "  - New subdirectory `Modules\\Core\\` created.",
        "  - New module `Modules\\Core\\JobOrchestrator.psm1` (v1.0.1) created to handle the main job/set processing loop.",
        "  - `Modules\\ConfigManager.psm1` (v1.2.0 -> v1.2.1) moved to `Modules\\Core\\ConfigManager.psm1`; internal paths updated.",
        "  - `Modules\\Operations.psm1` (v1.19.5 -> v1.20.0) moved to `Modules\\Core\\Operations.psm1`; internal paths updated.",
        "  - `PoSh-Backup.ps1` (v1.11.5 -> v1.12.1) significantly refactored:",
        "    - Main job processing loop delegated to `Invoke-PoShBackupRun` in `JobOrchestrator.psm1`.",
        "    - Imports updated for modules now in `Modules\\Core\\`.",
        "    - Workaround implemented (local re-import of `Utils.psm1`) to address module scoping issue where `Utils.psm1` commands became unavailable after returning from `JobOrchestrator.psm1`.",
        "  - All changes tested successfully by the user.",
        "--- Refactoring of Utils.psm1 (Previous Session Segment) ---",
        "  - Goal: Improve organisation and maintainability of utility functions.",
        "  - `Modules\\Utils.psm1` (v1.12.0 -> v1.13.3) refactored into a facade module.",
        "  - New subdirectory `Modules\\Utilities\\` created.",
        "  - New utility sub-modules created:",
        "    - `Modules\\Utilities\\Logging.psm1` (v1.0.0): Contains `Write-LogMessage`.",
        "    - `Modules\\Utilities\\ConfigUtils.psm1` (v1.0.0): Contains `Get-ConfigValue`.",
        "    - `Modules\\Utilities\\SystemUtils.psm1` (v1.0.0): Contains `Test-AdminPrivilege`, `Test-DestinationFreeSpace`.",
        "    - `Modules\\Utilities\\FileUtils.psm1` (v1.0.0): Contains `Get-ArchiveSizeFormatted`, `Get-PoshBackupFileHash`.",
        "  - `Modules\\Utils.psm1` now imports and re-exports functions from these sub-modules.",
        "  - Terminology for `DestinationDir` clarified in `Config\\Default.psd1`, `README.md`, `Operations.psm1`, and `LocalArchiveProcessor.psm1` to reflect its dual role (final destination vs. local staging area).",
        "  - PSSA 'empty catch block' warning in `Operations.psm1` addressed by adding a debug log message.",
        "  - All changes tested successfully by the user.",
        "--- Further Modularisation of PoSh-Backup.ps1 and ReportingHtml.psm1 (Previous Session) ---",
        "  - Goal: Reduce size of larger script files for AI efficiency and improve maintainability.",
        "  - `PoSh-Backup.ps1` (v1.11.4 -> v1.11.5 - before Core refactor) refactored:",
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
        "  - `Operations.psm1` (v1.18.6 -> v1.19.5 - before move to Core) refactored:",
        "    - Now acts as an orchestrator for job lifecycle stages.",
        "    - New sub-module: `Modules\\Operations\\LocalArchiveProcessor.psm1` (v1.0.3) created.",
        "    - New sub-module: `Modules\\Operations\\RemoteTransferOrchestrator.psm1` (v1.0.1) created.",
        "  - `ConfigManager.psm1` (v1.1.5 -> v1.2.0 - before move to Core) refactored:",
        "    - Now acts as a facade for configuration management functions.",
        "    - New sub-module: `Modules\\ConfigManagement\\ConfigLoader.psm1` (v1.0.0) created.",
        "    - New sub-module: `Modules\\ConfigManagement\\JobResolver.psm1` (v1.0.1) created.",
        "    - New sub-module: `Modules\\ConfigManagement\\EffectiveConfigBuilder.psm1` (v1.0.1) created.",
        "  - All refactoring changes tested successfully by the user.",
        "  - PSScriptAnalyzer issues (unused loggers, cmdlet naming, empty catch block) addressed in the new and refactored modules.",
        "  - `SFTP.Target.psm1` updated to v1.0.3 with inline PSSA suppressions for `ConvertTo-SecureString`.",
        "--- Previous Major Feature: Archive Checksum Generation & Verification ---",
        "  - Goal: Enhance archive integrity with optional checksums.",
        "  - Configuration (`Config\\Default.psd1` v1.3.8): Added global and job-level checksum settings.",
        "  - Schema Validation (`Modules\\PoShBackupValidator.psm1` v1.5.2): Updated for checksum settings.",
        "  - Utility Function (`Modules\\Utils.psm1` v1.13.0 - before refactor, current v1.13.3): Added `Get-PoshBackupFileHash`.",
        "  - Operations (`Modules\\Operations.psm1` v1.18.6 - before refactor): Implemented checksum logic.",
        "  - Config Management (`Modules\\ConfigManager.psm1` v1.1.5 - before refactor): Resolved checksum settings.",
        "  - Reporting Modules: Updated to display checksum information.",
        "  - Main Script (`PoSh-Backup.ps1` v1.11.0 - for checksums): Synopsis updated.",
        "  - Documentation (`README.md`): Updated for Checksum feature.",
        "--- Previous Major Feature: Post-Run System Actions (Shutdown, Restart, etc.) ---",
        "  - Goal: Allow PoSh-Backup to perform system state changes after job/set completion.",
        "  - New Module (`Modules\\SystemStateManager.psm1` v1.0.2).",
        "  - Configuration (`Config\\Default.psd1` v1.3.8 - before checksums & DestinationDir clarification): Added PostRunAction settings.",
        "  - Schema Validation (`Modules\\PoShBackupValidator.psm1` v1.3.5 - before checksums & schema externalisation): Updated.",
        "  - Config Management (`Modules\\ConfigManager.psm1` v1.1.4 - before checksums & major refactor): Updated.",
        "  - Main Script (`PoSh-Backup.ps1` v1.10.1 - for PostRunAction): Updated.",
        "  - Documentation (`README.md`): Updated.",
        "--- Previous Major Feature: Backup Targets (Expanded) ---",
        "  - Goal: Allow backups to be sent to remote locations via an extensible provider model.",
        "  - Configuration (Default.psd1 v1.3.3 - before PostRunAction, Checksums, DestinationDir clarification): Added `BackupTargets`, `TargetNames`, etc.",
        "  - Target Providers: `UNC.Target.psm1` (v1.1.2), `Replicate.Target.psm1` (v1.0.1), `SFTP.Target.psm1` (v1.0.3).",
        "  - Operations.psm1 (v1.17.3 - before PostRunAction, Checksum, & major refactor): Orchestrated target transfers.",
        "  - Reporting Modules: Updated for `TargetTransfers` data.",
        "  - README.md: Updated for 'Replicate' and 'SFTP' target providers.",
        "--- Previous Work (Selected Highlights) ---",
        "Network Share Handling Improvements, Retention Policy Confirmation, HTML Report Enhancements, PSSA compliance.",
        "Bundler Script (Generate-ProjectBundleForAI.ps1 v$($BundlerScriptVersion)) is stable.",
        "Overall project status: Core local backup stable. Remote targets, Post-Run Actions, Checksums, SFX (with module choice) features added. Extensive refactorings completed (ConfigManager, Operations, PoSh-Backup.ps1, ReportingHtml.psm1, PoShBackupValidator.psm1, Utils.psm1). PSSA summary expected to be clean except for known SFTP ConvertTo-SecureString items. Pester tests non-functional."
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
