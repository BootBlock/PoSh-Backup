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
    Version:        1.1.4 # Gemini being bad at remembering anything
    DateCreated:    17-May-2025
    LastModified:   22-May-2025
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
        # Return a minimal error state or re-throw, depending on desired bundler robustness
        return @{
            error                  = "Failed to load AIState.template.psd1"
            details                = $_.Exception.Message
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
        }
        catch {
            Write-Warning "Bundler StateAndAssembly: Could not process AutoDetectedPsDependencies. Defaulting to empty list for AI State. Type was: $($AutoDetectedPsDependencies.GetType().FullName)"
        }
    }
    # Ensure external_dependencies key exists before trying to access its subkey
    if (-not $aiState.ContainsKey('external_dependencies')) { $aiState.external_dependencies = @{} }
    $aiState.external_dependencies.powershell_modules = $psModulesForState 

    # Dynamically construct the conversation summary
    # Reflects state AFTER the current session's changes for Backup Targets
    # Version of THIS Bundle.StateAndAssembly.psm1 module
    $thisModuleVersion = "1.1.3" # Version of THIS Bundle.StateAndAssembly.psm1 module
    
        $currentConversationSummary = @(
        "Development of a comprehensive PowerShell file backup solution (PoSh-Backup.ps1 v1.10.1).", # Updated version
        "Modular design: Core modules, Reporting sub-modules, Config files, and Meta/ (bundler).",
        "AI State structure is loaded from 'Meta\\AIState.template.psd1' and dynamically populated by Bundle.StateAndAssembly.psm1 (v$($thisModuleVersion)).", # Uses the updated $thisModuleVersion
        "--- Major New Feature: Post-Run System Actions (Shutdown, Restart, etc.) ---",
        "  - Goal: Allow PoSh-Backup to perform system state changes after job/set completion.",
        "  - New Module (`Modules\\SystemStateManager.psm1` v1.0.0):",
        "    - Created to handle system state changes (Shutdown, Restart, Hibernate, LogOff, Sleep, Lock).",
        "    - Includes `Invoke-SystemStateAction` function.",
        "    - Supports delayed execution with a cancellable console countdown.",
        "    - Checks for hibernation support before attempting hibernate.",
        "    - Handles simulation mode for all actions.",
        "  - Configuration (`Config\\Default.psd1` v1.3.4):",
        "    - Added global `PostRunActionDefaults` section.",
        "    - Added `PostRunAction` hashtable to `BackupLocations` (job-level) and `BackupSets` (set-level).",
        "    - Settings include `Enabled`, `Action`, `DelaySeconds`, `TriggerOnStatus` (SUCCESS, WARNINGS, FAILURE, ANY), `ForceAction`.",
        "  - Schema Validation (`Modules\\PoShBackupValidator.psm1` v1.3.4):",
        "    - Updated schema to validate new `PostRunAction` settings at global, job, and set levels.",
        "  - Config Management (`Modules\\ConfigManager.psm1` v1.1.3):",
        "    - `Get-PoShBackupJobEffectiveConfiguration` now resolves `PostRunAction` for jobs.",
        "    - `Get-JobsToProcess` now resolves `PostRunAction` for sets.",
        "  - Main Script (`PoSh-Backup.ps1` v1.10.1):", # Updated version
        "    - Imports and uses `SystemStateManager.psm1`.",
        "    - Added CLI parameters for `PostRunAction` overrides.",
        "    - Implements logic to determine and execute the effective `PostRunAction` after all other operations.",
        "    - Handles simulation and test config modes for post-run actions.",
        "  - Documentation (`README.md`): Updated to explain the new Post-Run System Action feature, configuration, and CLI parameters.",
        "--- Previous Major Feature: Backup Targets (Expanded) ---", 
        "  - Goal: Allow backups to be sent to remote locations via an extensible provider model.",
        "  - Configuration (Default.psd1 v1.3.3):",
        "    - Added global BackupTargets section to define named remote target instances.",
        "    - In BackupLocations (job definitions): Renamed RetentionCount to LocalRetentionCount, added TargetNames (array), DeleteLocalArchiveAfterSuccessfulTransfer (boolean).",
        "    - For UNC targets, added CreateJobNameSubdirectory (boolean, default $false) to TargetSpecificSettings.",
        "    - Example added for new 'Replicate' target type, allowing multiple destinations per target instance, each with optional subdirectories and retention.",
        "    - Advanced Schema Validation now enabled by default.",
        "  - ConfigManager.psm1 (v1.1.2):", # This was the version before PostRunAction changes
        "    - Basic validation for TargetSpecificSettings made more flexible to support array types (for 'Replicate').",
        "  - PoShBackupValidator.psm1 (v1.3.3):", # This was the version before PostRunAction changes
        "    - Schema for BackupTargets.DynamicKeySchema.Schema.TargetSpecificSettings changed Type to 'object'.",
        "    - ValidateScript for BackupTargets now correctly handles type validation for 'UNC' (hashtable) and 'Replicate' (array) TargetSpecificSettings.",
        "  - Target Provider (Modules\\\\Targets\\\\UNC.Target.psm1 v1.1.2):",
        "    - Created to handle transfers to UNC paths.",
        "    - Implements Invoke-PoShBackupTargetTransfer function.",
        "    - Includes logic for creating job-specific subdirectories on the UNC share (now optional via CreateJobNameSubdirectory).",
        "    - Implements basic count-based remote retention on the UNC target.",
        "    - Now accepts and logs additional local archive metadata (size, creation time, password status).",
        "    - Implemented robust Initialize-RemotePathInternal helper for iterative UNC parent directory creation.",
        "    - Addressed PSSA warning for PSUseApprovedVerbs by renaming helper function.",
        "  - NEW Target Provider (Modules\\\\Targets\\\\Replicate.Target.psm1 v1.0.2):",
        "    - Created to handle replication of an archive to multiple destinations (local or UNC paths).",
        "    - Each destination within the 'Replicate' target's TargetSpecificSettings (an array) can have its own Path, CreateJobNameSubdirectory, and RetentionSettings (supporting KeepCount).",
        "    - Implements Invoke-PoShBackupTargetTransfer to manage all configured replications and returns detailed results for each.",
        "    - Accepts and logs additional local archive metadata.",
        "    - Addressed PSSA warning for unused Logger parameter.",
        "  - Operations.psm1 (v1.17.1):", # Assuming this version is correct from previous work
        "    - Orchestrates the transfer loop, dynamically loads providers, calls Invoke-PoShBackupTargetTransfer.",
        "    - Passes additional local archive metadata (size, creation time, password status) to target providers.",
        "    - Logs detailed ReplicationDetails if returned by providers like 'Replicate'.",
        "    - Handles local staged archive deletion, updates report data.",
        "  - Utils.psm1 (v1.11.3):",
        "    - Corrected $LocalWriteLog wrapper logic to properly handle empty ForegroundColour parameters, resolving console color warnings for ERROR level.",
        "    - Added enhanced diagnostics to Write-LogMessage's safety checks for color resolution.",
        "  - PoSh-Backup.ps1 (v1.10.0 - for Backup Targets):", # This refers to the version when Backup Targets was added
        "    - Ensured $Global:ColourHeading is defined.",
        "    - Explicitly added 'ERROR' key to $Global:StatusToColourMap to fix console color warnings.",
        "  - Reporting Modules Updated (previously for UNC, now generic for TargetTransfers):",
        "    - ReportingHtml.psm1 (v1.9.1): Added 'Remote Target Transfers' section. Corrected HTML encoder syntax.",
        "    - ReportingTxt.psm1 (v1.2.0): Added 'REMOTE TARGET TRANSFERS' section.",
        "    - ReportingCsv.psm1 (v1.2.0): Generates JobName_TargetTransfers_Timestamp.csv.",
        "    - ReportingMd.psm1 (v1.3.0): Added 'Remote Target Transfers' table.",
        "    - ReportingXml.psm1 (v1.2.0): TargetTransfers data included automatically.",
        "  - README.md: Updated to explain the new 'Replicate' target provider and its configuration (before PostRunAction updates).",
        "  - AIState.template.psd1: Watchlist updated for file integrity failures, PSSA issues, path creation, logging colors, PostRunAction logic, and new executable dependencies.",
        "--- Previous Work (Selected Highlights) ---",
        "Network Share Handling Improvements (Operations.psm1 pre-v1.15.0, Config\\Default.psd1 pre-v1.3.0).",
        "Retention Policy Confirmation logic (RetentionManager.psm1, etc.).",
        "HTML Report VSS field updates and general interactivity enhancements (ReportingHtml.psm1 pre-v1.9.0).",
        "General stability and PSSA compliance efforts.",
        "Bundler Script (Generate-ProjectBundleForAI.ps1 v$($BundlerScriptVersion)) is stable.", # Bundler version placeholder
        "Overall project status: Core local backup stable. Backup Target feature significantly expanded. New Post-Run System Action feature added. Logging and validation improved. PSSA clean. Pester tests non-functional." # MODIFIED
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

    # 1. Header
    $null = $finalOutputBuilder.Append($HeaderContent)

    # 2. AI State
    $null = $finalOutputBuilder.AppendLine("--- AI_STATE_START ---")
    $null = $finalOutputBuilder.AppendLine('```json')
    if ($null -ne $AIStateHashtable) {
        $null = $finalOutputBuilder.AppendLine(($AIStateHashtable | ConvertTo-Json -Depth 10 -Compress)) # Added -Compress
    }
    else {
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
