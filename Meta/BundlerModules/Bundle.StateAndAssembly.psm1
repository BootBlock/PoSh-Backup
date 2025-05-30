# Meta\BundlerModules\Bundle.StateAndAssembly.psm1
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
    Version:        1.1.16 # Updated conversation summary for PoSh-Backup v1.14.5, JobOrchestrator v1.1.4, and ReportingJson for Multi-Volume.
    DateCreated:    17-May-2025
    LastModified:   30-May-2025
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

    $thisModuleVersion = "1.1.16" # Updated version for this module's change

    $currentConversationSummary = @(
        "Development of a comprehensive PowerShell file backup solution (PoSh-Backup.ps1 v$($PoShBackupVersion)).", # Using dynamic version
        "Modular design: Core modules (now including Modules\\Core\\), Reporting sub-modules (including Modules\\Reporting\\Assets), ConfigManagement sub-modules (including Modules\\ConfigManagement\\Assets), Utilities sub-modules (Modules\\Utilities\\), Config files, and Meta/ (bundler).",
        "AI State structure is loaded from 'Meta\\AIState.template.psd1' and dynamically populated by Bundle.StateAndAssembly.psm1 (v$($thisModuleVersion)).", # Using this module's version
        "--- Feature: CPU Affinity/Core Limiting for 7-Zip (Completed in Previous Session Segment) ---",
        "  - Goal: Allow restricting 7-Zip to specific CPU cores for finer-grained resource control.",
        "  - `Config\\Default.psd1` (v1.4.0 -> v1.4.1): Added global `DefaultSevenZipCpuAffinity` and job-level `SevenZipCpuAffinity` settings.",
        "  - `Modules\\ConfigManagement\\Assets\\ConfigSchema.psd1`: Updated for `SevenZipCpuAffinity`.",
        "  - `Modules\\ConfigManagement\\EffectiveConfigBuilder.psm1` (v1.0.3 -> v1.0.5): Modified to resolve `SevenZipCpuAffinity` (including CLI override) and add to report data.",
        "  - `Modules\\Managers\\7ZipManager.psm1` (v1.0.8 -> v1.0.12):", # Updated version range as per loaded AI state
        "    - `Invoke-7ZipOperation` modified to accept `SevenZipCpuAffinityString`, validate against system cores, clamp values, parse (list or hex), and apply via `Start-Process`.",
        "    - Renamed internal `TempPasswordFile` parameter to `TempPassFile` to avoid PSSA warnings.",
        "  - `PoSh-Backup.ps1` (v1.12.1 -> v1.12.2): Added `-SevenZipCpuAffinityCLI` parameter and override logic.",
        "  - `README.md`: Updated with CPU Affinity feature details, configuration, and CLI override.",
        "  - All changes tested successfully by the user.",
        "--- Pester Testing - Phase 1: Utilities (Current Session Segment) ---",
        "  - Goal: Re-establish Pester testing for utility functions.",
        "  - Environment: Pester 5.7.1 confirmed as active.",
        "  - `ConfigUtils.Tests.ps1` (for `Get-ConfigValue` from imported `Utils.psm1`):",
        "    - Initial attempts to test the module function (imported or dot-sourced) failed due to parameters arriving as `$null` inside `Get-ConfigValue` when called from Pester `It` blocks.",
        "    - `InModuleScope -ArgumentList` also failed to pass arguments to its scriptblock.",
        "    - **Successful Pattern A:** `Import-Module Utils.psm1` in `BeforeAll`, then `$script:FuncRef = Get-Command Utils\Get-ConfigValue`. Test data set in `BeforeEach` with `$script:` scope. `It` blocks call `& `$script:FuncRef -Parameter `$script:testData``. All 12 tests PASSING.",
        "    - This confirms that testing functions from imported modules *can* work with correct data scoping and function referencing.",
        "  - `FileUtils.Tests.ps1` (for `Get-ArchiveSizeFormatted`, `Get-PoshBackupFileHash`):",
        "    - **Successful Pattern B (Local Logic Copy):** Functions' logic copied into test script (defined top-level). `BeforeAll` self dot-sources, then mocks `Write-LogMessage`, then gets `$script:` references to local test functions. `It` blocks call these references.",
        "    - **Logger Mocking Strategy:**",
        "      1. Dummy `Write-LogMessage` defined top-level in test script.",
        "      2. `BeforeAll` self dot-sources the test script.",
        "      3. `BeforeAll` then `Mock Write-LogMessage -MockWith { ...capture... } -Verifiable`.",
        "      4. Local test functions call `Write-LogMessage` directly (which hits the mock).",
        "      5. Assertions use `Should -Invoke Write-LogMessage -Times X -ParameterFilter {...}`.",
        "    - **`Get-FileHash` Mocking Strategy (for error handling test):**",
        "      1. Modified local copy of `Get-PoshBackupFileHash` to accept an optional `[scriptblock]`$InjectedFileHashCommand`` parameter (defaulting to `(Get-Command Get-FileHash)`).",
        "      2. Test injects a throwing scriptblock for this parameter.",
        "    - **Current Status:** All 12 tests for `FileUtils.Tests.ps1` are now passing with these strategies.",
        "  - Key Pester 5.7.1 findings for this environment (added to AI Watch List): Emphasized the 'local function copy' workaround (Pattern B) and the direct import pattern (Pattern A). Detailed successful mocking and data scoping strategies.",
        "  - Next Steps: Re-create `SystemUtils.Tests.ps1` using these established patterns.",
        "--- Feature: Multi-Volume (Split) Archives (7-Zip) (Current Session Segment) ---",
        "  - Goal: Allow creation of backup archives split into multiple volumes.",
        "  - `Config\\Default.psd1` (v1.4.5 -> v1.4.6): Added global `DefaultSplitVolumeSize` and job-level `SplitVolumeSize` (string, e.g., '100m', '4g').",
        "  - `Modules\\ConfigManagement\\Assets\\ConfigSchema.psd1`: Updated for `SplitVolumeSize` with pattern validation `(^$)|(^\\d+[kmg]$)`.",
        "  - `Modules\\ConfigManagement\\EffectiveConfigBuilder.psm1` (v1.0.8 -> v1.0.9): Resolves `SplitVolumeSize`. If active, it overrides `CreateSFX` (sets to `$false`) and logs a warning. Adds `SplitVolumeSize` to report data.",
        "  - `Modules\\Managers\\7ZipManager.psm1` (v1.1.1 -> v1.1.2): `Get-PoShBackup7ZipArgument` now adds the `-v{size}` switch if a valid `SplitVolumeSize` is in effective config.", # Version from loaded AI state
        "  - `Modules\\Core\\Operations.psm1` (v1.21.2 -> v1.21.3): Passes the correct archive extension (internal base extension if splitting, otherwise job archive extension) to `Invoke-BackupRetentionPolicy`.",
        "  - `Modules\\Managers\\RetentionManager.psm1` (v1.0.9 -> v1.1.0): Refactored `Invoke-BackupRetentionPolicy` to correctly identify and manage multi-volume archive sets as single entities for retention counting and deletion.",
        "  - Reporting modules (`ReportingCsv.psm1` v1.2.2->v1.2.3, `ReportingJson.psm1` v1.1.4 (implicitly includes new data), `ReportingXml.psm1` v1.2.2->v1.2.3, `ReportingTxt.psm1` v1.2.2->v1.2.3, `ReportingMd.psm1` v1.3.2->v1.3.3, `ReportingHtml.psm1` v1.9.10->v1.9.11) updated to reflect `SplitVolumeSize` in summaries/outputs (explicitly or implicitly).", # Adjusted ReportingJson
        "  - `PoSh-Backup.ps1` (v1.14.0 -> v1.14.1): Added `-SplitVolumeSizeCLI` parameter and integrated it into CLI override logic and logging.",
        "  - `Modules\\PoShBackupValidator.psm1` (v1.6.5 -> v1.6.6): Corrected typo in `Test-PoShBackupJobDependencyGraph` call. Schema-driven validation implicitly handles `SplitVolumeSize` via updated `ConfigSchema.psd1`.",
        "  - `README.md`: Updated with feature details, configuration, SFX interaction, and CLI override.",
        "--- Feature: Self-Extracting Archives (SFX) (Completed in a Previous Session Segment) ---",
        "  - Goal: Option to create self-extracting archives (.exe) for easier restoration, with user-selectable SFX module type.",
        "  - Stage 1 (Basic SFX):",
        "    - `Config\\Default.psd1` (v1.3.8 -> v1.3.9): Added global `DefaultCreateSFX` and job-level `CreateSFX` settings.",
        "    - `Modules\\ConfigManagement\\Assets\\ConfigSchema.psd1`: Updated for `DefaultCreateSFX` and `CreateSFX`.",
        "    - `Modules\\ConfigManagement\\EffectiveConfigBuilder.psm1` (v1.0.1 -> v1.0.2): Modified to resolve `CreateSFX` and force `.exe` extension if true, storing original extension as `InternalArchiveExtension`.",
        "    - `Modules\\Managers\\7ZipManager.psm1` (v1.0.6 -> v1.0.7): Modified `Get-PoShBackup7ZipArgument` to add `-sfx` switch if `CreateSFX` is true.", # Version from loaded AI state
        "    - `Modules\\Operations\\LocalArchiveProcessor.psm1` (v1.0.3 -> v1.0.4): Ensured `JobArchiveExtension` (which could be `.exe`) is used for archive naming.",
        "    - `README.md`: Updated with SFX feature details and configuration examples.",
        "  - Stage 2 (SFX Module Option):", # Removed "Current Session Segment" as it's completed.
        "    - `Config\\Default.psd1` (v1.3.9 -> v1.4.0): Added global `DefaultSFXModule` and job-level `SFXModule` settings (options: Console, GUI, Installer).",
        "    - `Modules\\ConfigManagement\\Assets\\ConfigSchema.psd1`: Updated for `DefaultSFXModule` and `SFXModule` with allowed values.",
        "    - `Modules\\ConfigManagement\\EffectiveConfigBuilder.psm1` (v1.0.2 -> v1.0.3): Modified to resolve `SFXModule` setting.",
        "    - `Modules\\Managers\\7ZipManager.psm1` (v1.0.7 -> v1.0.8): Modified `Get-PoShBackup7ZipArgument` to use the resolved `SFXModule` to select the appropriate `-sfx[module_name.sfx]` switch.", # Version from loaded AI state
        "    - `Modules\\Operations\\LocalArchiveProcessor.psm1` (v1.0.4 -> v1.0.5): Added `SFXModule` to report data.",
        "    - `README.md`: Updated to describe `SFXModule` options and examples.",
        "  - All changes tested successfully by the user.",
        "--- Refactoring of PoSh-Backup.ps1 and Core Modules (Previous Session Segment) ---",
        "  - Goal: Further modularise PoSh-Backup.ps1 by extracting its main job processing loop.",
        "  - New subdirectory `Modules\\Core\\` created.",
        "  - New module `Modules\\Core\\JobOrchestrator.psm1` (v1.0.1 -> v1.1.4 # Refactored job banner to use Write-ConsoleBanner.) created to handle the main job/set processing loop.", # Updated version and change
        "  - `Modules\\ConfigManager.psm1` (v1.2.0 -> v1.2.1) moved to `Modules\\Core\\ConfigManager.psm1`; internal paths updated.",
        "  - `Modules\\Operations.psm1` (v1.19.5 -> v1.20.0) moved to `Modules\\Core\\Operations.psm1`; internal paths updated.",
        "  - `PoSh-Backup.ps1` (v1.11.5 -> v1.12.1, leading to current v$($PoShBackupVersion)) significantly refactored:", # Clarified PoSh-Backup versions
        "    - Main job processing loop delegated to `Invoke-PoShBackupRun` in `JobOrchestrator.psm1`.",
        "    - Imports updated for modules now in `Modules\\Core\\`.",
        "    - Workaround implemented (local re-import of `Utils.psm1`) to address module scoping issue where `Utils.psm1` commands became unavailable after returning from `JobOrchestrator.psm1`.",
        "  - All changes tested successfully by the user.",
        "--- Refactoring of Utils.psm1 (Previous Session Segment) ---",
        "  - Goal: Improve organisation and maintainability of utility functions.",
        "  - `Modules\\Utils.psm1` (v1.12.0 -> v1.13.3, leading to current v1.15.0) refactored into a facade module.", # Updated version
        "  - New subdirectory `Modules\\Utilities\\` created.",
        "  - New utility sub-modules created:",
        "    - `Modules\\Utilities\\Logging.psm1` (v1.0.0): Contains `Write-LogMessage` (now facade points to LogManager.psm1).", # Clarified
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
        "  - `Modules\\PoShBackupValidator.psm1` (v1.3.6 -> v1.4.0, now v1.7.0 with sub-module) refactored:", # Updated version
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
        "  - Utility Function (`Modules\\Utils.psm1` v1.13.0 - before refactor, current v1.15.0): Added `Get-PoshBackupFileHash`.", # Updated version
        "  - Operations (`Modules\\Core\\Operations.psm1` v1.18.6 - before refactor): Implemented checksum logic.", # Corrected path
        "  - Config Management (`Modules\\Core\\ConfigManager.psm1` v1.1.5 - before refactor): Resolved checksum settings.", # Corrected path
        "  - Reporting Modules: Updated to display checksum information.",
        "  - Main Script (`PoSh-Backup.ps1` v1.11.0 - for checksums): Synopsis updated.",
        "  - Documentation (`README.md`): Updated for Checksum feature.",
        "--- Previous Major Feature: Post-Run System Actions (Shutdown, Restart, etc.) ---",
        "  - Goal: Allow PoSh-Backup to perform system state changes after job/set completion.",
        "  - New Module (`Modules\\Managers\\SystemStateManager.psm1` v1.0.2).", # Corrected path
        "  - Configuration (`Config\\Default.psd1` v1.3.8 - before checksums & DestinationDir clarification): Added PostRunAction settings.",
        "  - Schema Validation (`Modules\\PoShBackupValidator.psm1` v1.3.5 - before checksums & schema externalisation): Updated.",
        "  - Config Management (`Modules\\Core\\ConfigManager.psm1` v1.1.4 - before checksums & major refactor): Updated.", # Corrected path
        "  - Main Script (`PoSh-Backup.ps1` v1.10.1 - for PostRunAction): Updated.",
        "  - Documentation (`README.md`): Updated.",
        "--- Previous Major Feature: Backup Targets (Expanded) ---",
        "  - Goal: Allow backups to be sent to remote locations via an extensible provider model.",
        "  - Configuration (Default.psd1 v1.3.3 - before PostRunAction, Checksums, DestinationDir clarification): Added `BackupTargets`, `TargetNames`, etc.",
        "  - Target Providers: `UNC.Target.psm1` (v1.1.2), `Replicate.Target.psm1` (v1.0.1), `SFTP.Target.psm1` (v1.0.3).",
        "  - `Modules\\Core\\Operations.psm1` (v1.17.3 - before PostRunAction, Checksum, & major refactor): Orchestrated target transfers.", # Corrected path
        "  - Reporting Modules: Updated for `TargetTransfers` data.",
        "  - `README.md`: Updated for 'Replicate' and 'SFTP' target providers.",
        "--- Previous Work (Selected Highlights) ---",
        "Network Share Handling Improvements, Retention Policy Confirmation, HTML Report Enhancements, PSSA compliance.",
        "Bundler Script (Generate-ProjectBundleForAI.ps1 v$($BundlerScriptVersion)) is stable.", # Using dynamic version
        "Overall project status: Core local backup stable. Remote targets, Post-Run Actions, Checksums, SFX (with module choice), and multi-volume (split) archives features added. Extensive refactorings completed (ConfigManager, Operations, PoSh-Backup.ps1, ReportingHtml.psm1, PoShBackupValidator.psm1, Utils.psm1). PSSA summary now expected to show 2 known SFTP ConvertTo-SecureString items. Pester tests for utilities in progress, next is SystemUtils.Tests.ps1." # Updated PSSA and Pester status
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
