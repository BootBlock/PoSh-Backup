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
    Version:        1.1.5 # Updated conversation summary for Checksum feature.
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
        # Return a minimal error state or re-throw, depending on desired bundler robustness
        return @{
            error                  = "Failed to load AIState.template.psd1"
            details                = $_.Exception.Message
            bundle_generation_time = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }

    # Populate/Overwrite dynamic fields in the loaded template
    $aiState.bundle_generation_time = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $aiState.main_script_poSh_backup_version = $PoShBackupVersion # e.g., "1.11.0"
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
    # Version of THIS Bundle.StateAndAssembly.psm1 module
    $thisModuleVersion = "1.1.5" 
    
        $currentConversationSummary = @(
        "Development of a comprehensive PowerShell file backup solution (PoSh-Backup.ps1 v1.11.0).", # Updated version
        "Modular design: Core modules, Reporting sub-modules, Config files, and Meta/ (bundler).",
        "AI State structure is loaded from 'Meta\\AIState.template.psd1' and dynamically populated by Bundle.StateAndAssembly.psm1 (v$($thisModuleVersion)).", 
        "--- NEW Major Feature: Archive Checksum Generation & Verification ---",
        "  - Goal: Enhance archive integrity with optional checksums.",
        "  - Configuration (`Config\\Default.psd1` v1.3.6):",
        "    - Added global defaults: `DefaultGenerateArchiveChecksum`, `DefaultChecksumAlgorithm`, `DefaultVerifyArchiveChecksumOnTest`.",
        "    - Added job-level settings: `GenerateArchiveChecksum`, `ChecksumAlgorithm`, `VerifyArchiveChecksumOnTest`.",
        "  - Schema Validation (`Modules\\PoShBackupValidator.psm1` v1.3.6):",
        "    - Updated schema to validate new checksum settings at global and job levels.",
        "  - Utility Function (`Modules\\Utils.psm1` v1.12.0):",
        "    - Added `Get-PoshBackupFileHash` function using `Get-FileHash` for checksum calculation.",
        "  - Operations (`Modules\\Operations.psm1` v1.18.6):",
        "    - Logic to generate checksum file (e.g., `archive.7z.sha256`) after local archive creation if enabled.",
        "    - Logic to verify checksum against archive content during archive testing if enabled.",
        "    - Checksum details (value, algorithm, file path, verification status) added to report data.",
        "  - Config Management (`Modules\\ConfigManager.psm1` v1.1.5):",
        "    - `Get-PoShBackupJobEffectiveConfiguration` now resolves checksum settings for jobs.",
        "  - Reporting Modules Updated (v1.9.2 for HTML, v1.2.2 for TXT/CSV, v1.3.2 for MD, v1.1.4 for JSON, v1.2.2 for XML):",
        "    - HTML, TXT, MD, CSV reports now display checksum information in the summary section.",
        "    - JSON and XML reports implicitly include checksum data as part of the main report object.",
        "  - Main Script (`PoSh-Backup.ps1` v1.11.0):",
        "    - Synopsis and description updated to reflect the new checksum feature.",
        "  - Documentation (`README.md`): Updated to explain the new Checksum feature, configuration, and impact on archive testing.",
        "--- Previous Major Feature: Post-Run System Actions (Shutdown, Restart, etc.) ---",
        "  - Goal: Allow PoSh-Backup to perform system state changes after job/set completion.",
        "  - New Module (`Modules\\SystemStateManager.psm1` v1.0.2):",
        "    - Created to handle system state changes (Shutdown, Restart, Hibernate, LogOff, Sleep, Lock).",
        "    - Includes `Invoke-SystemStateAction` function.",
        "    - Supports delayed execution with a cancellable console countdown.",
        "    - Checks for hibernation support before attempting hibernate.",
        "    - Handles simulation mode for all actions.",
        "  - Configuration (`Config\\Default.psd1` v1.3.5):", # Version before checksum
        "    - Added global `PostRunActionDefaults` section.",
        "    - Added `PostRunAction` hashtable to `BackupLocations` (job-level) and `BackupSets` (set-level).",
        "    - Settings include `Enabled`, `Action`, `DelaySeconds`, `TriggerOnStatus` (SUCCESS, WARNINGS, FAILURE, ANY), `ForceAction`.",
        "  - Schema Validation (`Modules\\PoShBackupValidator.psm1` v1.3.5):", # Version before checksum
        "    - Updated schema to validate new `PostRunAction` settings at global, job, and set levels.",
        "  - Config Management (`Modules\\ConfigManager.psm1` v1.1.4):", # Version before checksum
        "    - `Get-PoShBackupJobEffectiveConfiguration` now resolves `PostRunAction` for jobs.",
        "    - `Get-JobsToProcess` now resolves `PostRunAction` for sets.",
        "  - Main Script (`PoSh-Backup.ps1` v1.10.1):", # Version before checksum
        "    - Imports and uses `SystemStateManager.psm1`.",
        "    - Added CLI parameters for `PostRunAction` overrides.",
        "    - Implements logic to determine and execute the effective `PostRunAction` after all other operations.",
        "    - Handles simulation and test config modes for post-run actions.",
        "  - Documentation (`README.md`): Updated to explain the Post-Run System Action feature (before checksum updates).",
        "--- Previous Major Feature: Backup Targets (Expanded) ---", 
        "  - Goal: Allow backups to be sent to remote locations via an extensible provider model.",
        "  - Configuration (Default.psd1 v1.3.3):", # Version before PostRunAction & Checksum
        "    - Added global BackupTargets section to define named remote target instances.",
        "    - In BackupLocations (job definitions): Renamed RetentionCount to LocalRetentionCount, added TargetNames (array), DeleteLocalArchiveAfterSuccessfulTransfer (boolean).",
        "    - For UNC targets, added CreateJobNameSubdirectory (boolean, default $false) to TargetSpecificSettings.",
        "    - Example added for new 'Replicate' target type, allowing multiple destinations per target instance, each with optional subdirectories and retention.",
        "    - Advanced Schema Validation now enabled by default.",
        "  - ConfigManager.psm1 (v1.1.2):", 
        "    - Basic validation for TargetSpecificSettings made more flexible to support array types (for 'Replicate').",
        "  - PoShBackupValidator.psm1 (v1.3.3):", 
        "    - Schema for BackupTargets.DynamicKeySchema.Schema.TargetSpecificSettings changed Type to 'object'.",
        "    - ValidateScript for BackupTargets now correctly handles type validation for 'UNC' (hashtable) and 'Replicate' (array) TargetSpecificSettings.",
        "  - Target Provider (Modules\\\\Targets\\\\UNC.Target.psm1 v1.1.2):",
        "    - Implements Invoke-PoShBackupTargetTransfer function.",
        "  - NEW Target Provider (Modules\\\\Targets\\\\Replicate.Target.psm1 v1.0.2):",
        "    - Implements Invoke-PoShBackupTargetTransfer to manage all configured replications.",
        "  - NEW Target Provider (Modules\\\\Targets\\\\SFTP.Target.psm1 v1.0.2):",
        "    - Implements Invoke-PoShBackupTargetTransfer for SFTP transfers.",
        "  - Operations.psm1 (v1.17.3):", # Version before PostRunAction & Checksum
        "    - Orchestrates the transfer loop, dynamically loads providers, calls Invoke-PoShBackupTargetTransfer.",
        "  - Utils.psm1 (v1.11.3):", # Version before checksum
        "    - Corrected $LocalWriteLog wrapper logic.",
        "  - PoSh-Backup.ps1 (v1.10.0 - for Backup Targets):", 
        "    - Ensured $Global:ColourHeading is defined.",
        "  - Reporting Modules Updated (generic for TargetTransfers):",
        "    - ReportingHtml.psm1 (v1.9.1), ReportingTxt.psm1 (v1.2.0), ReportingCsv.psm1 (v1.2.0), ReportingMd.psm1 (v1.3.0), ReportingXml.psm1 (v1.2.0).",
        "  - README.md: Updated to explain 'Replicate' and 'SFTP' target providers (before PostRunAction & Checksum updates).",
        "  - AIState.template.psd1: Watchlist updated for file integrity, PSSA issues, path creation, logging colors, PostRunAction logic, SFTP dependencies.",
        "--- Previous Work (Selected Highlights) ---",
        "Network Share Handling Improvements.",
        "Retention Policy Confirmation logic.",
        "HTML Report VSS field updates and general interactivity enhancements.",
        "General stability and PSSA compliance efforts.",
        "Bundler Script (Generate-ProjectBundleForAI.ps1 v$($BundlerScriptVersion)) is stable.", 
        "Overall project status: Core local backup stable. Backup Target feature significantly expanded. Post-Run System Action feature added. New Checksum feature added. Logging and validation improved. PSSA clean (SFTP suppressions noted). Pester tests non-functional."
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
        $null = $finalOutputBuilder.AppendLine(($AIStateHashtable | ConvertTo-Json -Depth 10 -Compress)) 
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
