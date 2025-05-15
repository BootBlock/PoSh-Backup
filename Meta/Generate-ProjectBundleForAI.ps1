<#
.SYNOPSIS
    Consolidates project files, including itself, into a single text bundle file for AI ingestion.
.DESCRIPTION
    This script iterates through files in the project root and its subdirectories (excluding specified folders and file types),
    and outputs their relative paths and contents into a text file named 'ProjectBundle-YYYYMMDD_HHMMSS.txt'.
    It also explicitly includes its own source code in the bundle.
    The bundle includes a project structure overview, AI-readable state with auto-detected module descriptions,
    PowerShell dependencies, and by default includes both PSScriptAnalyzer summary (can be disabled with -NoRunScriptAnalyzer)
    and the output of PoSh-Backup.ps1 -TestConfig (can be disabled with -DoNotIncludeTestConfigOutput).
    It will use a PSScriptAnalyzerSettings.psd1 file from the project root if present, and include its content in the bundle.
    The displayed project root path in the bundle is an anonymized version (just the root folder name).
.PARAMETER ProjectRoot
    The root directory of the project to bundle. Defaults to the parent directory of this script's location.
.PARAMETER OutputFileNameBase
    The base name for the output bundle file. A timestamp will be appended. Defaults to 'ProjectBundle'.
.PARAMETER ExcludedFolders
    An array of folder names (relative to ProjectRoot) to exclude from bundling.
.PARAMETER ExcludedFileExtensions
    An array of file extensions (including the dot, e.g., ".log") to exclude.
.PARAMETER NoRunScriptAnalyzer
    A switch parameter. If present, PSScriptAnalyzer will NOT be run, and its summary will be excluded from the bundle.
    By default (if this switch is omitted), the script attempts to run PSScriptAnalyzer.
.PARAMETER DoNotIncludeTestConfigOutput
    A switch parameter. If present, the script will NOT run 'PoSh-Backup.ps1 -TestConfig'
    and its output will be excluded from the bundle. By default, the TestConfig output is included.
.EXAMPLE
    .\Generate-ProjectBundleForAI.ps1
    Generates 'ProjectBundle-YYYYMMDD_HHMMSS.txt' in the Meta folder, showing progress messages.
    Includes PSScriptAnalyzer results (using PSScriptAnalyzerSettings.psd1 if found, and including its content)
    AND PoSh-Backup.ps1 -TestConfig output by default.

.EXAMPLE
    .\Generate-ProjectBundleForAI.ps1 -NoRunScriptAnalyzer -DoNotIncludeTestConfigOutput
    Generates the bundle, showing progress, but skips PSScriptAnalyzer AND PoSh-Backup.ps1 -TestConfig output.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.15.11 # Version from user's provided file
    DateCreated:    15-May-2025
    LastModified:   15-May-2025 # Updated by AI based on user request
#>

param (
    [string]$ProjectRoot_FullPath = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$OutputFileNameBase = "ProjectBundle",
    [string[]]$ExcludedFolders = @(".git", "Reports", "Logs", "Meta", "Tests"), # Added "Tests" to excluded by default
    [string[]]$ExcludedFileExtensions = @(".zip", ".7z", ".exe", ".dll", ".pdb", ".iso", ".bak", ".tmp", ".log", ".rar", ".tar", ".gz", ".cab", ".msi"),
    [switch]$NoRunScriptAnalyzer,
    [switch]$DoNotIncludeTestConfigOutput
)

# --- Helper Functions ---
function Get-ScriptVersionFromContent {
    param([string]$ScriptContent, [string]$ScriptNameForWarning = "script")
    $versionString = "N/A"
    try {
        if ([string]::IsNullOrWhiteSpace($ScriptContent)) {
            Write-Warning "Bundler: Script content provided to Get-ScriptVersionFromContent for '$ScriptNameForWarning' is empty."
            return "N/A (Empty Content)"
        }
        $regexV1 = '(?s)\.NOTES(?:.|\s)*?Version:\s*([0-9]+\.[0-9]+(?:\.[0-9]+)?(?:\.[0-9]+)?.*?)(?:\r?\n|\s*\(|<#)'
        $regexV2 = '(?im)^\s*Version:\s*([0-9]+\.[0-9]+(?:\.[0-9]+)?(?:\.[0-9]+)?.*?)(\s*\(|$)'
        $regexV3 = '(?im)Script Version:\s*v?([0-9]+\.[0-9]+(\.[0-9]+)?(\.[0-9]+)?.*?)\b'

        $match = [regex]::Match($ScriptContent, $regexV2)
        if ($match.Success) {
            $versionString = $match.Groups[1].Value.Trim()
        } else {
            $match = [regex]::Match($ScriptContent, $regexV1)
            if ($match.Success) {
                $versionString = $match.Groups[1].Value.Trim()
            } else {
                $match = [regex]::Match($ScriptContent, $regexV3)
                if ($match.Success) {
                    $versionString = "v" + $match.Groups[1].Value.Trim()
                } else {
                    Write-Warning "Bundler: Could not automatically determine version for '$ScriptNameForWarning' using any regex."
                }
            }
        }
    } catch { Write-Warning "Bundler: Error parsing version for '$ScriptNameForWarning': $($_.Exception.Message)" }
    return $versionString
}

$script:autoDetectedModuleDescriptions = @{}
$script:autoDetectedPsDependencies = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

function Add-FileToBundle {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$FileObject,
        [Parameter(Mandatory)]
        [string]$RootPathForRelativeCalculations,
        [Parameter(Mandatory)]
        [System.Text.StringBuilder]$BundleBuilder
    )

    $currentRelativePath = $FileObject.FullName.Substring($RootPathForRelativeCalculations.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $currentLanguageHint = ""
    switch ($FileObject.Extension.ToLowerInvariant()) {
        ".ps1"  { $currentLanguageHint = "powershell" }
        ".psm1" { $currentLanguageHint = "powershell" }
        ".psd1" { $currentLanguageHint = "powershell" }
        ".css"  { $currentLanguageHint = "css" }
        ".html" { $currentLanguageHint = "html" }
        ".js"   { $currentLanguageHint = "javascript" }
        ".json" { $currentLanguageHint = "json" }
        ".xml"  { $currentLanguageHint = "xml" }
        ".md"   { $currentLanguageHint = "markdown" }
        ".txt"  { $currentLanguageHint = "text" }
        ".yml"  { $currentLanguageHint = "yaml" }; ".yaml" { $currentLanguageHint = "yaml" }
        ".ini"  { $currentLanguageHint = "ini" };  ".conf" { $currentLanguageHint = "plaintext" }
        ".config" { $currentLanguageHint = "xml" }; ".sh"   { $currentLanguageHint = "shell" }
        ".bash" { $currentLanguageHint = "bash" };  ".py"   { $currentLanguageHint = "python" }
        ".cs"   { $currentLanguageHint = "csharp" }; ".c"    { $currentLanguageHint = "c" }
        ".cpp"  { $currentLanguageHint = "cpp" };  ".h"    { $currentLanguageHint = "c" }
        ".java" { $currentLanguageHint = "java" };  ".rb"   { $currentLanguageHint = "ruby" }
        ".php"  { $currentLanguageHint = "php" };   ".go"   { $currentLanguageHint = "go" }
        ".swift"{ $currentLanguageHint = "swift" }; ".kt"   { $currentLanguageHint = "kotlin" }
        ".sql"  { $currentLanguageHint = "sql" }
        default { $currentLanguageHint = "text" }
    }

    $null = $BundleBuilder.AppendLine("--- FILE_START ---")
    $null = $BundleBuilder.AppendLine("Path: $currentRelativePath")
    $null = $BundleBuilder.AppendLine("Language: $currentLanguageHint")
    $null = $BundleBuilder.AppendLine("Last Modified: $($FileObject.LastWriteTime)")
    $null = $BundleBuilder.AppendLine("Size: $($FileObject.Length) bytes")
    $null = $BundleBuilder.AppendLine("--- FILE_CONTENT ---")

    $fileContent = ""
    try {
        $fileContent = Get-Content -LiteralPath $FileObject.FullName -Raw -Encoding UTF8 -ErrorAction Stop
        if ($null -eq $fileContent -and $LASTEXITCODE -ne 0) {
            $fileContent = Get-Content -LiteralPath $FileObject.FullName -Raw -ErrorAction SilentlyContinue
        }

        if ([string]::IsNullOrWhiteSpace($fileContent) -and $FileObject.Length -gt 0 -and $LASTEXITCODE -ne 0) {
             $null = $BundleBuilder.AppendLine("(Could not read content as text or file is binary. Size: $($FileObject.Length) bytes)")
        } elseif ([string]::IsNullOrWhiteSpace($fileContent)) {
            $null = $BundleBuilder.AppendLine("(This file is empty or contains only whitespace)")
        } else {
            $null = $BundleBuilder.AppendLine(('```' + $currentLanguageHint))
            $null = $BundleBuilder.AppendLine($fileContent)
            $null = $BundleBuilder.AppendLine('```')
        }
    } catch {
        $null = $BundleBuilder.AppendLine("(Error reading file: $($_.Exception.Message))")
    }

    if ($FileObject.Extension -in ".ps1", ".psm1" -and -not [string]::IsNullOrEmpty($fileContent)) {
        try {
            $synopsisMatch = [regex]::Match($fileContent, '(?s)\.SYNOPSIS\s*(.*?)(?=\r?\n\s*\.(?:DESCRIPTION|EXAMPLE|PARAMETER|NOTES|LINK)|<#|$)')
            if ($synopsisMatch.Success) {
                $synopsisText = $synopsisMatch.Groups[1].Value.Trim() -replace '\s*\r?\n\s*', ' ' -replace '\s{2,}', ' '
                if ($synopsisText.Length -gt 200) { $synopsisText = $synopsisText.Substring(0, 197) + "..." }
                if (-not [string]::IsNullOrWhiteSpace($synopsisText)) {
                    $script:autoDetectedModuleDescriptions[$currentRelativePath] = $synopsisText
                }
            }
        } catch {
            Write-Warning "Error parsing synopsis for '$currentRelativePath': $($_.Exception.Message)"
        }

        try {
            $regexPatternForRequires = '(?im)^\s*#Requires\s+-Module\s+(?:@{ModuleName\s*=\s*)?["'']?([a-zA-Z0-9._-]+)["'']?'
            $requiresMatches = [regex]::Matches($fileContent, $regexPatternForRequires)

            if ($requiresMatches.Count -gt 0) {
                Write-Verbose "Found #Requires -Module in $($FileObject.Name):"
                foreach ($reqMatch in $requiresMatches) {
                    if ($reqMatch.Groups[1].Success) {
                        $moduleName = $reqMatch.Groups[1].Value
                        Write-Verbose "  - Adding '$moduleName' to dependencies."
                        $null = $script:autoDetectedPsDependencies.Add($moduleName)
                    }
                }
            }
        } catch {
            Write-Warning "Error parsing #Requires for '$currentRelativePath': $($_.Exception.Message)"
        }
    }

    $null = $BundleBuilder.AppendLine("--- FILE_END ---")
    $null = $BundleBuilder.AppendLine("")
}
# --- End Helper Functions ---


# --- Main Script Setup ---
$shouldRunScriptAnalyzer = -not $NoRunScriptAnalyzer.IsPresent
$shouldIncludeTestConfigOutput = -not $DoNotIncludeTestConfigOutput.IsPresent

$ProjectRoot_DisplayName = (Get-Item -LiteralPath $ProjectRoot_FullPath).Name
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$outputFilePath = Join-Path -Path $PSScriptRoot -ChildPath "$($OutputFileNameBase)-$($timestamp).txt"

Write-Host "Starting project file bundling process..."
Write-Host "Actual Project Root (for script execution): $ProjectRoot_FullPath"
Write-Host "Displayed Project Root (in bundle): $ProjectRoot_DisplayName"
Write-Host "Run PSScriptAnalyzer: $($shouldRunScriptAnalyzer)"
Write-Host "Include PoSh-Backup -TestConfig output: $($shouldIncludeTestConfigOutput)"
Write-Host "Output File: $outputFilePath"

$headerContentBuilder = [System.Text.StringBuilder]::new()
$null = $headerContentBuilder.AppendLine("Hello AI Assistant!")
$null = $headerContentBuilder.AppendLine("")
$null = $headerContentBuilder.AppendLine("This bundle contains the current state of our PowerShell backup project ('PoSh-Backup').")
$null = $headerContentBuilder.AppendLine("It is designed to allow us to seamlessly continue our previous conversation in a new chat session.")
$null = $headerContentBuilder.AppendLine("")
$null = $headerContentBuilder.AppendLine("Please review the AI State, Project Structure Overview, and then the bundled files.")
$null = $headerContentBuilder.AppendLine("After you've processed this, the user will provide specific instructions, context for what we last worked on, and outline the next task for our current session.")
$null = $headerContentBuilder.AppendLine("")

$fileContentBuilder = [System.Text.StringBuilder]::new()
# --- End Main Script Setup ---


# --- Main Processing Logic ---
try {
    if (-not (Test-Path -LiteralPath $ProjectRoot_FullPath -PathType Container)) {
        $errorMessage = "Project root '$ProjectRoot_FullPath' not found or is not a directory."
        Write-Error $errorMessage
        $null = $headerContentBuilder.Insert(0, "ERROR: $errorMessage`r`n")
        ($headerContentBuilder.ToString() + $fileContentBuilder.ToString()) | Set-Content -Path $outputFilePath -Encoding UTF8 -Force -ErrorAction SilentlyContinue
        exit 1
    }

    $thisScriptFileObject = Get-Item -LiteralPath $PSCommandPath
    Write-Verbose "Explicitly adding bundler script: $($thisScriptFileObject.FullName)"
    Add-FileToBundle -FileObject $thisScriptFileObject `
                     -RootPathForRelativeCalculations $ProjectRoot_FullPath `
                     -BundleBuilder $fileContentBuilder

    Get-ChildItem -Path $ProjectRoot_FullPath -Recurse -File -Depth 10 -ErrorAction SilentlyContinue | ForEach-Object {
        $file = $_
        if ($file.FullName -eq $thisScriptFileObject.FullName) { return }

        $normalizedProjectRootForCalc = (Resolve-Path $ProjectRoot_FullPath).Path
        $normalizedFilePath = $file.FullName
        $currentRelativePath = $normalizedFilePath.Substring($normalizedProjectRootForCalc.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)

        $isExcludedFolder = $false
        foreach ($excludedDir in $ExcludedFolders) {
            $normalizedExcludedDir = $excludedDir.TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
            if ($currentRelativePath -like "$normalizedExcludedDir\*" -or $currentRelativePath -eq $normalizedExcludedDir) {
                $isExcludedFolder = $true; break
            }
        }
        if ($isExcludedFolder) { Write-Verbose "Skipping (excluded folder): $currentRelativePath"; return }
        if ($ExcludedFileExtensions -contains $file.Extension.ToLowerInvariant()) { Write-Verbose "Skipping (excluded extension): $currentRelativePath"; return }

        Add-FileToBundle -FileObject $file `
                         -RootPathForRelativeCalculations $normalizedProjectRootForCalc `
                         -BundleBuilder $fileContentBuilder
    }
}
catch {
    $errorMessage = "An unexpected error occurred during file processing: $($_.Exception.ToString())"
    Write-Error $errorMessage
    $null = $fileContentBuilder.AppendLine("ERROR: $errorMessage")
}
finally {
    $mainPoShBackupScriptPath = Join-Path -Path $ProjectRoot_FullPath -ChildPath "PoSh-Backup.ps1"
    $mainPoShBackupScriptFileObject = Get-Item -LiteralPath $mainPoShBackupScriptPath -ErrorAction SilentlyContinue
    $poShBackupVersion = "N/A"
    if ($mainPoShBackupScriptFileObject) {
        $poShBackupVersion = Get-ScriptVersionFromContent -ScriptContent (Get-Content -LiteralPath $mainPoShBackupScriptFileObject.FullName -Raw -ErrorAction SilentlyContinue) -ScriptNameForWarning "PoSh-Backup.ps1"
    } else {
        Write-Warning "Bundler: Main script PoSh-Backup.ps1 not found at '$mainPoShBackupScriptPath' for version extraction."
    }

    $thisBundlerScriptFileObject = Get-Item -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue
    $bundlerScriptVersion = "1.15.11" # Version as per user's provided file, AI does not change this unless instructed to update *this script*
    if ($thisBundlerScriptFileObject) {
        $readBundlerVersion = Get-ScriptVersionFromContent -ScriptContent (Get-Content -LiteralPath $thisBundlerScriptFileObject.FullName -Raw -ErrorAction SilentlyContinue) -ScriptNameForWarning $thisBundlerScriptFileObject.Name
        if ($readBundlerVersion -ne $bundlerScriptVersion -and $readBundlerVersion -ne "N/A" -and $readBundlerVersion -notlike "N/A (*" -and $PSCommandPath -ne $MyInvocation.MyCommand.Path) {
             Write-Verbose "Bundler: Read version '$readBundlerVersion' from current disk file, but AI State will use '$bundlerScriptVersion' for this generation."
        }
    } else {
         Write-Warning "Bundler: Could not get bundler script file object for version extraction. Using manually set version '$bundlerScriptVersion' for AI State."
    }

    # AI STATE BLOCK - Updated by AI as requested
    $aiState = @{
        project_name = "PoSh Backup Solution";
        project_root_folder_name = $ProjectRoot_DisplayName;
        bundle_generation_time = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"); # AI_UPDATE: Updated time
        main_script_poSh_backup_version = $poShBackupVersion; # Read from PoSh-Backup.ps1
        bundler_script_version = $bundlerScriptVersion; # Matches script version

        conversation_summary = @(
            "Development of a comprehensive PowerShell file backup solution (PoSh-Backup.ps1).",
            "Modular design: Modules/ (Utils, Operations, PasswordManager, Reporting orchestrator), Modules/Reporting/ (format-specific), Config/ (Default.psd1, User.psd1, Themes/), Meta/ (bundler).",
            "Reporting: Multi-format (HTML, CSV, JSON, XML, TXT, MD). HTML reports feature theming, log filtering, sim banner.",
            "Core Features: Early 7-Zip check (auto-detection), VSS, retries, hooks, flexible password management.",
            "Validation: Optional schema-based configuration validation (PoShBackupValidator.psm1).",
            "Bundler Improvements: Regex for version extraction refined; PoSh-Backup.ps1 -TestConfig output included by default; PSSA uses settings file; bundler's own PSSA warnings addressed (Write-Host to Write-Verbose/Output, Invoke-Expression suppression).",
            "PSScriptAnalyzer: Iteratively addressed warnings in production code through direct fixes and by updating PSScriptAnalyzerSettings.psd1 to globally exclude specific rules. Removed corresponding in-line/attribute suppressions from code.",
            "Pester Tests: Attempted to create/debug Pester tests for Utils.psm1 and PasswordManager.psm1. Encountered significant and persistent issues with Pester environment setup, cmdlet availability (Get-Mock, Remove-Mock), mock scoping, and test logic. These tests are currently non-functional and were excluded from this bundle generation."
        ); # AI_UPDATE: Added note about Pester test issues
        module_descriptions = $script:autoDetectedModuleDescriptions; # Auto-detected
        external_dependencies = @{
            powershell_modules = ($script:autoDetectedPsDependencies | Sort-Object -Unique); # Auto-detected, currently null
            executables = @(
                "7z.exe (7-Zip command-line tool - path configurable or auto-detected)"
            )
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
            "SCOPE: Double-check variable scopes when helper functions modify collections intended for wider use (prefer passing by ref or using script scope explicitly and carefully, e.g., `$script:varName`).",
            "STRUCTURE: Respect the modular design (Utils, Operations, PasswordManager, Reporting orchestrator, Reporting sub-modules).",
            "BRACES/PARENS: Meticulously check for balanced curly braces `{}`, parentheses `()`, and square brackets `[]` in all generated code, especially in complex `if/try/catch/finally` blocks and `param()` blocks.",
            "PSSA: Bundler's `Invoke-ScriptAnalyzer` summary may not perfectly reflect all suppressions (from PSScriptAnalyzerSettings.psd1 or in-line attributes/comments). Trust VS Code's PSSA feedback (when configured with the settings file) more for true suppression status.",
            "PESTER (SESSION): Current Pester tests are non-functional. Significant issues encountered with Pester v5 environment, cmdlet availability (Get-Mock/Remove-Mock were not exported by Pester 5.7.1), mock scoping, and test logic that could not be resolved during the session. Further Pester work will require a reset or a different diagnostic approach."
        ); # AI_UPDATE: Added specific Pester watch item
        ai_bundler_update_instructions = @{
            purpose = "Instructions for AI on how to regenerate the content of this `$aiState hashtable within the Generate-ProjectBundleForAI.ps1 script when requested by the user.";
            when_to_update = "Only when the user explicitly asks to 'update the bundler script's AI state'.";
            fields_to_update_by_ai = @(
                "conversation_summary: Refine based on newly implemented and stable features reflected in the code. Focus on *what is currently in the code*.",
                "module_descriptions: AI should verify/update this based on current file synopses if major changes occur to files or new modules are added/removed (auto-detected by bundler).",
                "external_dependencies.powershell_modules: AI should verify this list if new #Requires statements are added/removed from scripts (auto-detected by bundler).",
                "main_script_poSh_backup_version: AI should update this if it modifies PoSh-Backup.ps1's version information (auto-read by this bundler).",
                "bundler_script_version: AI should update this if it modifies this bundler script's version information (auto-read by this bundler).",
                "ai_development_watch_list: AI should review this list. If new persistent common errors or important reminders have emerged during the session, AI should suggest or include updates to this list when asked to update the bundler state."
            );
            fields_to_be_updated_by_user = @(
                "external_dependencies.executables (if new external tools are added - AI cannot auto-detect this reliably)"
            );
            output_format_for_ai = "Provide the updated `$aiState block as a complete PowerShell hashtable string, ready for copy-pasting directly into Generate-ProjectBundleForAI.ps1, replacing the existing `$aiState = @{ ... }` block. Ensure strings are correctly quoted and arrays use PowerShell syntax, e.g., `@('item1', 'item2')`.";
            example_of_ai_provided_block_start = "`$aiState = @{";
            example_of_ai_provided_block_end = "}";
            reminder_for_ai = "When asked to update this state, proactively consider if any recent challenges or frequent corrections should be added to the 'ai_development_watch_list'."
        }
    }
    # END AI STATE BLOCK

    # Assemble the final output in order
    $finalOutputBuilder = [System.Text.StringBuilder]::new()
    $null = $finalOutputBuilder.Append($headerContentBuilder.ToString())

    $null = $finalOutputBuilder.AppendLine("--- AI_STATE_START ---")
    $null = $finalOutputBuilder.AppendLine('```json')
    $null = $finalOutputBuilder.AppendLine(($aiState | ConvertTo-Json -Depth 10))
    $null = $finalOutputBuilder.AppendLine('```')
    $null = $finalOutputBuilder.AppendLine("--- AI_STATE_END ---")
    $null = $finalOutputBuilder.AppendLine("")

    $null = $finalOutputBuilder.AppendLine("--- PROJECT_STRUCTURE_OVERVIEW ---")
    $null = $finalOutputBuilder.AppendLine("Location: $ProjectRoot_DisplayName (Root of the project)")
    $null = $finalOutputBuilder.AppendLine("(Note: Log files in 'Logs/' and specific report file types in 'Reports/' are excluded from this overview section.)")
    $null = $finalOutputBuilder.AppendLine("")
    try {
        Get-ChildItem -Path $ProjectRoot_FullPath -Depth 0 | Sort-Object PSIsContainer -Descending | ForEach-Object {
            $item = $_
            if ($item.PSIsContainer) {
                $null = $finalOutputBuilder.AppendLine("  |- $($item.Name)/")

                $childItems = Get-ChildItem -Path $item.FullName -Depth 0 -ErrorAction SilentlyContinue

                if ($item.Name -eq "Logs") {
                    $childItems = $childItems | Where-Object { $_.PSIsContainer -or ($_.Name -notlike "*.log") }
                } elseif ($item.Name -eq "Reports") {
                    $reportFileExtensionsToExcludeInOverview = @(".html", ".csv", ".json", ".xml", ".txt", ".md")
                    $childItems = $childItems | Where-Object { $_.PSIsContainer -or ($_.Extension.ToLowerInvariant() -notin $reportFileExtensionsToExcludeInOverview) }
                } elseif ($item.Name -eq "Meta" -and $item.FullName -eq $PSScriptRoot) {
                     $childItems = $childItems | Where-Object { $_.Name -eq ($OutputFileNameBase + "-" + $timestamp + ".txt") -or $_.Name -eq "Generate-ProjectBundleForAI.ps1" -or $_.PSIsContainer}
                } elseif ($item.Name -eq "Tests") { # AI_UPDATE: Ensure "Tests" children are represented as "..." if Tests folder is excluded at top level
                    $null = $finalOutputBuilder.AppendLine("  |  |- ... (Content excluded by bundler settings)")
                    $childItems = @() # Don't list children if parent is excluded
                }


                $childItems | Sort-Object PSIsContainer -Descending | ForEach-Object {
                    $childItem = $_
                    if ($childItem.PSIsContainer) {
                        $null = $finalOutputBuilder.AppendLine("  |  |- $($childItem.Name)/ ...")
                    } else {
                        $null = $finalOutputBuilder.AppendLine("  |  |- $($childItem.Name)")
                    }
                }
            } else {
                $null = $finalOutputBuilder.AppendLine("  |- $($item.Name)")
            }
        }
    } catch {
        $null = $finalOutputBuilder.AppendLine("  (Error generating structure overview: $($_.Exception.Message))")
    }
    $null = $finalOutputBuilder.AppendLine("--- END_PROJECT_STRUCTURE_OVERVIEW ---")
    $null = $finalOutputBuilder.AppendLine("")

    if ($shouldIncludeTestConfigOutput) {
        $null = $finalOutputBuilder.AppendLine("--- POSH_BACKUP_TESTCONFIG_OUTPUT_START ---")
        $fullPathToPoShBackupScript = Join-Path -Path $ProjectRoot_FullPath -ChildPath "PoSh-Backup.ps1"
        if (Test-Path -LiteralPath $fullPathToPoShBackupScript -PathType Leaf) {
            try {
                Write-Host "Running 'PoSh-Backup.ps1 -TestConfig' (this may take a moment)..." -ForegroundColor Yellow

                $oldErrorActionPreference = $ErrorActionPreference
                $ErrorActionPreference = "Continue"
                $testConfigOutput = ""
                $LASTEXITCODE = 0

                Push-Location (Split-Path -Path $fullPathToPoShBackupScript -Parent)
                try {
                    $invokeCommand = ". `"$fullPathToPoShBackupScript`" -TestConfig *>&1"
                    $testConfigOutput = Invoke-Expression $invokeCommand | Out-String
                }
                catch {
                    $testConfigOutput = "INVOKE-EXPRESSION FAILED: $($_.Exception.ToString())`n$($_.ScriptStackTrace)"
                    if ($Error.Count -gt 0) {
                        $testConfigOutput += "`nLAST SCRIPT ERROR: $($Error[0].ToString())`n$($Error[0].ScriptStackTrace)"
                    }
                }
                finally {
                    Pop-Location
                    $ErrorActionPreference = $oldErrorActionPreference
                }

                if ($LASTEXITCODE -ne 0 -and -not ([string]::IsNullOrWhiteSpace($testConfigOutput))) {
                     $null = $finalOutputBuilder.AppendLine("(PoSh-Backup.ps1 -TestConfig exited with code $LASTEXITCODE. Output/Error follows.)")
                } elseif ($LASTEXITCODE -ne 0) {
                     $null = $finalOutputBuilder.AppendLine("(PoSh-Backup.ps1 -TestConfig exited with code $LASTEXITCODE. No specific output captured.)")
                }

                if ([string]::IsNullOrWhiteSpace($testConfigOutput) -and $LASTEXITCODE -eq 0){
                    $null = $finalOutputBuilder.AppendLine("(PoSh-Backup.ps1 -TestConfig ran successfully but produced no console output.)")
                } else {
                    $null = $finalOutputBuilder.AppendLine($testConfigOutput.TrimEnd())
                }

            } catch {
                $null = $finalOutputBuilder.AppendLine("(Bundler error trying to run PoSh-Backup.ps1 -TestConfig: $($_.Exception.ToString()))")
            }
        } else {
            $null = $finalOutputBuilder.AppendLine("(PoSh-Backup.ps1 not found at '$fullPathToPoShBackupScript'. Cannot run -TestConfig.)")
        }
        $null = $finalOutputBuilder.AppendLine("--- POSH_BACKUP_TESTCONFIG_OUTPUT_END ---")
        $null = $finalOutputBuilder.AppendLine("")
    }

    $analyzerSettingsPath = Join-Path -Path $ProjectRoot_FullPath -ChildPath "PSScriptAnalyzerSettings.psd1"
    if ($shouldRunScriptAnalyzer -and (Test-Path -LiteralPath $analyzerSettingsPath -PathType Leaf)) {
        $null = $finalOutputBuilder.AppendLine("--- PSSCRIPTANALYZER_SETTINGS_FILE_CONTENT_START ---")
        $null = $finalOutputBuilder.AppendLine("Path: PSScriptAnalyzerSettings.psd1 (Project Root)")
        $null = $finalOutputBuilder.AppendLine("--- FILE_CONTENT ---")
        $null = $finalOutputBuilder.AppendLine('```powershell')
        try {
            $settingsContent = Get-Content -LiteralPath $analyzerSettingsPath -Raw -ErrorAction Stop
            $null = $finalOutputBuilder.AppendLine($settingsContent)
        } catch {
            $null = $finalOutputBuilder.AppendLine("(Error reading PSScriptAnalyzerSettings.psd1: $($_.Exception.Message))")
        }
        $null = $finalOutputBuilder.AppendLine('```')
        $null = $finalOutputBuilder.AppendLine("--- PSSCRIPTANALYZER_SETTINGS_FILE_CONTENT_END ---")
        $null = $finalOutputBuilder.AppendLine("")
    }

    if ($shouldRunScriptAnalyzer) {
        $null = $finalOutputBuilder.AppendLine("--- PS_SCRIPT_ANALYZER_SUMMARY ---")
        if (Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue) {
            try {
                Write-Host "Running PSScriptAnalyzer (this may take a moment)..." -ForegroundColor Yellow
                $scriptFilesToAnalyze = Get-ChildItem -Path $ProjectRoot_FullPath -Recurse -Include *.ps1, *.psm1 |
                    Where-Object {
                        $isExcluded = $false
                        foreach($excludedDirName in $ExcludedFolders) { # $ExcludedFolders already updated to include "Tests"
                            $fullExcludedPath = Join-Path -Path $ProjectRoot_FullPath -ChildPath $excludedDirName
                            if ($_.FullName.StartsWith($fullExcludedPath, [System.StringComparison]::OrdinalIgnoreCase)) { $isExcluded = $true; break }
                        }
                        -not $isExcluded
                    }

                if ($scriptFilesToAnalyze.Count -gt 0) {
                    $allAnalyzerResultsList = [System.Collections.Generic.List[object]]::new()
                    foreach ($scriptFile in $scriptFilesToAnalyze) {
                        Write-Verbose "Analyzing $($scriptFile.FullName)..."
                        $invokeAnalyzerParams = @{
                            Path = $scriptFile.FullName
                            Severity = @('Error', 'Warning')
                            ErrorAction = 'SilentlyContinue'
                        }
                        if (Test-Path -LiteralPath $analyzerSettingsPath -PathType Leaf) {
                            $invokeAnalyzerParams.Settings = $analyzerSettingsPath
                            Write-Verbose "   (Using PSScriptAnalyzer settings from: $analyzerSettingsPath)"
                        } else {
                            Write-Verbose "   (PSScriptAnalyzerSettings.psd1 not found at project root. Using default PSSA rules.)"
                        }
                        $analyzerResultsForFile = Invoke-ScriptAnalyzer @invokeAnalyzerParams

                        if ($null -ne $analyzerResultsForFile) {
                            if ($analyzerResultsForFile -is [System.Array] -or $analyzerResultsForFile -is [System.Collections.ICollection]) {
                                $allAnalyzerResultsList.AddRange($analyzerResultsForFile)
                            } else {
                                $allAnalyzerResultsList.Add($analyzerResultsForFile)
                            }
                        }
                    }

                    if ($allAnalyzerResultsList.Count -gt 0) {
                        $null = $finalOutputBuilder.AppendLine("Found $($allAnalyzerResultsList.Count) issues (Errors/Warnings):")
                        $formattedResults = $allAnalyzerResultsList | Select-Object Severity, Message, ScriptName, Line, Column | Format-Table -AutoSize | Out-String -Width 120
                        $null = $finalOutputBuilder.AppendLine($formattedResults)
                    } else {
                        $null = $finalOutputBuilder.AppendLine("(No PSScriptAnalyzer errors or warnings found in .ps1/.psm1 files after applying settings.)")
                    }
                } else {
                    $null = $finalOutputBuilder.AppendLine("(No .ps1 or .psm1 files found to analyze in project scope after exclusions.)")
                }
            } catch {
                $null = $finalOutputBuilder.AppendLine("(Error running PSScriptAnalyzer: $($_.Exception.Message))")
            }
        } else {
            $null = $finalOutputBuilder.AppendLine("(PSScriptAnalyzer module not found. To use this feature, install it: Install-Module PSScriptAnalyzer)")
        }
        $null = $finalOutputBuilder.AppendLine("--- END_PS_SCRIPT_ANALYZER_SUMMARY ---")
        $null = $finalOutputBuilder.AppendLine("")
    }

    $null = $finalOutputBuilder.Append($fileContentBuilder.ToString())

    $null = $finalOutputBuilder.AppendLine("-----------------------------------")
    $null = $finalOutputBuilder.AppendLine("--- END OF PROJECT FILE BUNDLE ---")

    try {
        $finalOutputBuilder.ToString() | Set-Content -Path $outputFilePath -Encoding UTF8 -Force
        Write-Output "Project bundle successfully written to: $outputFilePath"
    } catch {
        Write-Error "Failed to write project bundle to file '$outputFilePath'. Error: $($_.Exception.Message)"
    }
}
