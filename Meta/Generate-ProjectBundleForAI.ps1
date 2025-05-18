<#
.SYNOPSIS
    Consolidates project files, including itself and its own modules, into a single text bundle file for AI ingestion.
.DESCRIPTION
    This script orchestrates the bundling of project files for AI ingestion.
    It leverages several sub-modules located in 'Meta\BundlerModules\' for specific tasks:
    - 'Bundle.Utils.psm1': Handles version extraction and project structure overview.
    - 'Bundle.FileProcessor.psm1': Handles individual file reading, language hinting, synopsis/dependency extraction.
    - 'Bundle.ExternalTools.psm1': Handles PSScriptAnalyzer execution and PoSh-Backup -TestConfig output.
    - 'Bundle.StateAndAssembly.psm1': Handles AI State block generation and final assembly of all bundle content.
    - 'Bundle.ProjectScanner.psm1': Handles the main iteration over project files, applying exclusions.

    The script first adds itself and its sub-modules to the bundle. Then, it invokes
    'Bundle.ProjectScanner.psm1' to process the main project files. Finally, it assembles
    all collected information and generated content into 'PoSh-Backup-AI-Bundle.txt'.
.PARAMETER ProjectRoot
    The root directory of the project to bundle. Defaults to the parent directory of this script's location.
    Must be a valid, existing directory.
.PARAMETER ExcludedFolders
    An array of folder names (relative to ProjectRoot) to exclude from bundling by the ProjectScanner module.
    Note: 'Meta\BundlerModules' is always included by this main script.
.PARAMETER ExcludedFileExtensions
    An array of file extensions (including the dot, e.g., ".log") to exclude by the ProjectScanner module.
.PARAMETER NoRunScriptAnalyzer
    A switch parameter. If present, PSScriptAnalyzer will NOT be run.
.PARAMETER DoNotIncludeTestConfigOutput
    A switch parameter. If present, 'PoSh-Backup.ps1 -TestConfig' will NOT be run.
.EXAMPLE
    .\Meta\Generate-ProjectBundleForAI.ps1
    Generates 'PoSh-Backup-AI-Bundle.txt', including PSScriptAnalyzer and -TestConfig output by default.

.EXAMPLE
    .\Meta\Generate-ProjectBundleForAI.ps1 -NoRunScriptAnalyzer -DoNotIncludeTestConfigOutput
    Generates 'PoSh-Backup-AI-Bundle.txt', skipping PSScriptAnalyzer and -TestConfig output.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.24.0 # Modularized project file scanning logic.
    DateCreated:    15-May-2025
    LastModified:   17-May-2025
#>

param (
    [ValidateScript({
        if (-not (Test-Path -LiteralPath $_ -PathType Container)) {
            throw "ProjectRoot '$_' not found or is not a directory."
        }
        return $true
    })]
    [string]$ProjectRoot_FullPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,

    [string[]]$ExcludedFolders = @(".git", "Reports", "Logs", "Meta", "Tests"),
    [string[]]$ExcludedFileExtensions = @(".zip", ".7z", ".exe", ".dll", ".pdb", ".iso", ".bak", ".tmp", ".log", ".rar", ".tar", ".gz", ".cab", ".msi"),
    [switch]$NoRunScriptAnalyzer,
    [switch]$DoNotIncludeTestConfigOutput
)

# --- Script-Scoped Variables ---
$script:autoDetectedModuleDescriptions = @{}
$script:autoDetectedPsDependencies = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
# --- End Script-Scoped Variables ---

# --- Bundler Module Imports ---
try {
    $bundlerModulesPath = Join-Path -Path $PSScriptRoot -ChildPath "BundlerModules"
    Import-Module -Name (Join-Path -Path $bundlerModulesPath -ChildPath "Bundle.Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $bundlerModulesPath -ChildPath "Bundle.FileProcessor.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $bundlerModulesPath -ChildPath "Bundle.ExternalTools.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $bundlerModulesPath -ChildPath "Bundle.StateAndAssembly.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $bundlerModulesPath -ChildPath "Bundle.ProjectScanner.psm1") -Force -ErrorAction Stop
    Write-Verbose "Bundler utility modules loaded."
} catch {
    Write-Error "FATAL: Failed to import required bundler script modules from '$bundlerModulesPath'. Error: $($_.Exception.Message)"
    exit 11
}
# --- End Bundler Module Imports ---


# --- Main Script Setup ---
$shouldRunScriptAnalyzer = -not $NoRunScriptAnalyzer.IsPresent
$shouldIncludeTestConfigOutput = -not $DoNotIncludeTestConfigOutput.IsPresent

$ProjectRoot_DisplayName = (Get-Item -LiteralPath $ProjectRoot_FullPath).Name
$outputFilePath = Join-Path -Path $ProjectRoot_FullPath -ChildPath "PoSh-Backup-AI-Bundle.txt"

$normalizedProjectRootForCalculations = (Resolve-Path $ProjectRoot_FullPath).Path

Write-Host "Starting project file bundling process..."
Write-Host "Actual Project Root (for script execution): $ProjectRoot_FullPath"
Write-Host "Displayed Project Root (in bundle): $ProjectRoot_DisplayName"
Write-Host "Run PSScriptAnalyzer: $($shouldRunScriptAnalyzer)"
Write-Host "Include PoSh-Backup -TestConfig output: $($shouldIncludeTestConfigOutput)"
Write-Host "Output File: $outputFilePath (will be overwritten)"
Write-Verbose "Normalized project root for path calculations: $normalizedProjectRootForCalculations"

$headerContentBuilder = [System.Text.StringBuilder]::new()
$null = $headerContentBuilder.AppendLine("Hello AI Assistant!")
$null = $headerContentBuilder.AppendLine("")
$null = $headerContentBuilder.AppendLine("This bundle contains the current state of our PowerShell backup project ('PoSh-Backup').")
$null = $headerContentBuilder.AppendLine("It is designed to allow us to seamlessly continue our previous conversation in a new chat session.")
$null = $headerContentBuilder.AppendLine("")
$null = $headerContentBuilder.AppendLine("Please review the AI State, Project Structure Overview, and then the bundled files.")
$null = $headerContentBuilder.AppendLine("After you've processed this, the user will provide specific instructions, context for what we last worked on, and outline the next task for our current session.")
$null = $headerContentBuilder.AppendLine("")

$fileContentBuilder = [System.Text.StringBuilder]::new() # Populated by Add-FileToBundle calls
# --- End Main Script Setup ---


# --- Main Processing Logic ---
try {
    if (-not (Test-Path -LiteralPath $ProjectRoot_FullPath -PathType Container)) {
        $errorMessage = "Project root '$ProjectRoot_FullPath' not found or is not a directory (post-parameter validation check)."
        Write-Error $errorMessage
        Remove-Item -LiteralPath $outputFilePath -Force -ErrorAction SilentlyContinue # Attempt to clear partial bundle
        ($headerContentBuilder.ToString() + $fileContentBuilder.ToString()) | Set-Content -Path $outputFilePath -Encoding UTF8 -Force -ErrorAction SilentlyContinue
        exit 1
    }

    # Local helper to process a single file (typically bundler & its modules) and update script-scoped collections
    $UpdateMetadataFromProcessingResult = {
        param($FileObjectParam, $ProcessingResult)
        if ($null -ne $ProcessingResult) {
            if (-not [string]::IsNullOrWhiteSpace($ProcessingResult.Synopsis)) {
                $currentRelPath = $FileObjectParam.FullName.Substring($normalizedProjectRootForCalculations.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
                $script:autoDetectedModuleDescriptions[$currentRelPath] = $ProcessingResult.Synopsis
            }
            if ($null -ne $ProcessingResult.Dependencies -and $ProcessingResult.Dependencies.Count -gt 0) {
                foreach ($dep in $ProcessingResult.Dependencies) {
                    $null = $script:autoDetectedPsDependencies.Add($dep)
                }
            }
        }
    }

    # 1. Add the bundler script itself
    $thisScriptFileObject = Get-Item -LiteralPath $PSCommandPath
    Write-Verbose "Explicitly adding bundler script itself to bundle: $($thisScriptFileObject.FullName)"
    $bundlerScriptProcessingResult = Add-FileToBundle -FileObject $thisScriptFileObject `
                                                      -RootPathForRelativeCalculations $normalizedProjectRootForCalculations `
                                                      -BundleBuilder $fileContentBuilder
    & $UpdateMetadataFromProcessingResult -FileObjectParam $thisScriptFileObject -ProcessingResult $bundlerScriptProcessingResult


    # 2. Add the bundler's own modules from Meta\BundlerModules
    $bundlerModulesDir = Join-Path -Path $PSScriptRoot -ChildPath "BundlerModules"
    if (Test-Path -LiteralPath $bundlerModulesDir -PathType Container) {
        Write-Verbose "Adding bundler's own modules from '$bundlerModulesDir'..."
        Get-ChildItem -Path $bundlerModulesDir -Filter *.psm1 -File -ErrorAction SilentlyContinue | ForEach-Object {
            $bundlerModuleFile = $_
            Write-Verbose "Adding bundler module to bundle: $($bundlerModuleFile.Name)"
            $moduleProcessingResult = Add-FileToBundle -FileObject $bundlerModuleFile `
                                                       -RootPathForRelativeCalculations $normalizedProjectRootForCalculations `
                                                       -BundleBuilder $fileContentBuilder
            & $UpdateMetadataFromProcessingResult -FileObjectParam $bundlerModuleFile -ProcessingResult $moduleProcessingResult
        }
    } else {
        Write-Warning "Bundler modules directory '$bundlerModulesDir' not found. Bundler's own modules will not be included in the bundle."
    }

    # 3. Scan and add project files using Bundle.ProjectScanner.psm1
    # This is where the main loop over project files happens.
    $projectScanResult = Invoke-BundlerProjectScan -ProjectRoot_FullPath $ProjectRoot_FullPath `
                                                   -NormalizedProjectRootForCalculations $normalizedProjectRootForCalculations `
                                                   -OutputFilePath $outputFilePath `
                                                   -ThisScriptFileObject $thisScriptFileObject `
                                                   -BundlerModulesDir $bundlerModulesDir `
                                                   -ExcludedFolders $ExcludedFolders `
                                                   -ExcludedFileExtensions $ExcludedFileExtensions `
                                                   -FileContentBuilder $fileContentBuilder
    
    # Merge metadata collected by ProjectScanner into the script-scoped collections
    if ($null -ne $projectScanResult) {
        if ($null -ne $projectScanResult.ModuleDescriptions) {
            $projectScanResult.ModuleDescriptions.GetEnumerator() | ForEach-Object {
                $script:autoDetectedModuleDescriptions[$_.Name] = $_.Value
            }
        }
        if ($null -ne $projectScanResult.PsDependencies) {
            $projectScanResult.PsDependencies | ForEach-Object { # HashSet is enumerable
                $null = $script:autoDetectedPsDependencies.Add($_)
            }
        }
    }
    Write-Verbose "Finished all file processing and metadata collection."
}
catch {
    $errorMessage = "An unexpected error occurred during file processing: $($_.Exception.ToString())"
    Write-Error $errorMessage
    $null = $fileContentBuilder.AppendLine("ERROR: $errorMessage") # Add error to the content builder just in case
}
finally {
    # --- Retrieve Versions ---
    Write-Verbose "Reading PoSh-Backup.ps1 for version information..."
    $mainPoShBackupScriptPath = Join-Path -Path $ProjectRoot_FullPath -ChildPath "PoSh-Backup.ps1"
    $mainPoShBackupScriptFileObject = Get-Item -LiteralPath $mainPoShBackupScriptPath -ErrorAction SilentlyContinue
    $poShBackupVersion = "N/A"
    if ($mainPoShBackupScriptFileObject) {
        $poShBackupVersion = Get-ScriptVersionFromContent -ScriptContent (Get-Content -LiteralPath $mainPoShBackupScriptFileObject.FullName -Raw -ErrorAction SilentlyContinue) -ScriptNameForWarning "PoSh-Backup.ps1"
    } else {
        Write-Warning "Bundler: Main script PoSh-Backup.ps1 not found at '$mainPoShBackupScriptPath' for version extraction."
    }

    Write-Verbose "Reading bundler script for its own version information..."
    $thisBundlerScriptFileObjectForVersion = Get-Item -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue # Renamed to avoid conflict
    $bundlerScriptVersionForState = "1.24.0" # Version of THIS script, to be embedded in AI State
    if ($thisBundlerScriptFileObjectForVersion) {
        $readBundlerVersion = Get-ScriptVersionFromContent -ScriptContent (Get-Content -LiteralPath $thisBundlerScriptFileObjectForVersion.FullName -Raw -ErrorAction SilentlyContinue) -ScriptNameForWarning $thisBundlerScriptFileObjectForVersion.Name
        if ($readBundlerVersion -ne $bundlerScriptVersionForState -and $readBundlerVersion -ne "N/A" -and $readBundlerVersion -notlike "N/A (*" ) {
             Write-Verbose "Bundler: Read version '$readBundlerVersion' from current disk file's CBH ($($thisBundlerScriptFileObjectForVersion.Name)), but AI State will use hardcoded version '$bundlerScriptVersionForState' for this generation. Ensure CBH is updated to '$bundlerScriptVersionForState'."
        }
    } else {
         Write-Warning "Bundler: Could not get bundler script file object ('$($PSCommandPath)') for version extraction. Using manually set version '$bundlerScriptVersionForState' for AI State."
    }

    # --- Generate AI State ---
    # The $aiState block itself is now defined within Get-BundlerAIState in Bundle.StateAndAssembly.psm1
    # This call retrieves the fully constructed $aiState hashtable.
    # The conversation_summary within Get-BundlerAIState will need to be manually updated by the AI when it's asked to update the bundler state.
    $updatedConversationSummary = @( 
        "Development of a comprehensive PowerShell file backup solution (PoSh-Backup.ps1).",
        "Modular design: PoSh-Backup core modules (Utils, Operations, PasswordManager, Reporting orchestrator, 7ZipManager, VssManager, RetentionManager), Reporting sub-modules, Config files, and Meta/ (bundler).",
        "PoSh-Backup Core Features:",
        "  - Added -SkipUserConfigCreation switch to PoSh-Backup.ps1 (v1.9.5).",
        "  - Created 'Modules\7ZipManager.psm1' (v1.0.0) to centralize 7-Zip interactions (PoSh-Backup v1.9.6).",
        "  - Created 'Modules\VssManager.psm1' (v1.0.0) to centralize VSS interactions (PoSh-Backup v1.9.7).",
        "  - Created 'Modules\RetentionManager.psm1' (v1.0.0) to centralize retention policy logic (PoSh-Backup v1.9.8).",
        "  - Updated Utils.psm1, Operations.psm1 to reflect moved functions.",
        "Bundler Script (Generate-ProjectBundleForAI.ps1) Modularization:",
        "  - Version updated to 1.24.0 to reflect its own extensive modularization.",
        "  - Created 'Meta\BundlerModules\Bundle.Utils.psm1'.",
        "  - Created 'Meta\BundlerModules\Bundle.FileProcessor.psm1'.",
        "  - Created 'Meta\BundlerModules\Bundle.ExternalTools.psm1'.",
        "  - Created 'Meta\BundlerModules\Bundle.StateAndAssembly.psm1' (v1.0.4).",
        "  - Created 'Meta\BundlerModules\Bundle.ProjectScanner.psm1'.",
        "  - Main bundler script now primarily orchestrates calls to these sub-modules.",
        "General project status: Reporting, Hooks, Password Management are key features. PSSA clean. Pester tests non-functional."
    )

    $aiStateHashtable = Get-BundlerAIState -ProjectRoot_DisplayName $ProjectRoot_DisplayName `
                                           -PoShBackupVersion $poShBackupVersion `
                                           -BundlerScriptVersion $bundlerScriptVersionForState `
                                           -AutoDetectedModuleDescriptions $script:autoDetectedModuleDescriptions `
                                           -AutoDetectedPsDependencies $script:autoDetectedPsDependencies # Pass the HashSet directly
    
    # Override the conversation summary with the fresh one from this session
    $aiStateHashtable.conversation_summary = $updatedConversationSummary
                                           
    # --- Get Project Structure Overview ---
    $projectStructureContentString = Get-ProjectStructureOverviewContent -ProjectRoot_FullPath $ProjectRoot_FullPath `
                                                                         -ProjectRoot_DisplayName $ProjectRoot_DisplayName `
                                                                         -BundlerOutputFilePath $outputFilePath
    
    # --- Get TestConfig Output ---
    $testConfigResultOutputString = ""
    if ($shouldIncludeTestConfigOutput) {
        $testConfigResultOutputString = Get-BundlerTestConfigOutput -ProjectRoot_FullPath $ProjectRoot_FullPath
    }

    # --- Get PSScriptAnalyzerSettings.psd1 Content ---
    $analyzerSettingsPath = Join-Path -Path $ProjectRoot_FullPath -ChildPath "PSScriptAnalyzerSettings.psd1"
    $analyzerSettingsFileContentString = ""
    if ($shouldRunScriptAnalyzer -and (Test-Path -LiteralPath $analyzerSettingsPath -PathType Leaf)) {
        try {
            $analyzerSettingsFileContentString = Get-Content -LiteralPath $analyzerSettingsPath -Raw -ErrorAction Stop
        } catch {
            $analyzerSettingsFileContentString = "(Bundler Main: Error reading PSScriptAnalyzerSettings.psd1: $($_.Exception.Message))"
        }
    }

    # --- Get PSScriptAnalyzer Summary ---
    $pssaResultOutputString = ""
    if ($shouldRunScriptAnalyzer) {
        $pssaResultOutputString = Invoke-BundlerScriptAnalyzer -ProjectRoot_FullPath $ProjectRoot_FullPath `
                                                               -ExcludedFoldersForPSSA $ExcludedFolders `
                                                               -AnalyzerSettingsPath $analyzerSettingsPath `
                                                               -BundlerOutputFilePath $outputFilePath `
                                                               -BundlerPSScriptRoot $PSScriptRoot
    }
    
    # --- Assemble Final Bundle ---
    Write-Verbose "Assembling final output bundle (via Bundle.StateAndAssembly.psm1)..."
    $finalBundleString = Format-AIBundleContent -HeaderContent $headerContentBuilder.ToString() `
                                                  -AIStateHashtable $aiStateHashtable `
                                                  -ProjectStructureContent $projectStructureContentString `
                                                  -TestConfigOutputContent $testConfigResultOutputString `
                                                  -AnalyzerSettingsFileContent $analyzerSettingsFileContentString `
                                                  -PSSASummaryOutputContent $pssaResultOutputString `
                                                  -BundledFilesContent $fileContentBuilder.ToString()
    try {
        Write-Verbose "Writing final bundle to: $outputFilePath"
        Remove-Item -LiteralPath $outputFilePath -Force -ErrorAction SilentlyContinue # Ensure overwrite
        $finalBundleString | Set-Content -Path $outputFilePath -Encoding UTF8 -Force
        Write-Output "Project bundle successfully written to: $outputFilePath"
    } catch {
        Write-Error "Failed to write project bundle to file '$outputFilePath'. Error: $($_.Exception.Message)"
    }
}
