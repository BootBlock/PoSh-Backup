<#
.SYNOPSIS
    Consolidates project files, including itself and its own modules, into a single text bundle file for AI ingestion.
.DESCRIPTION
    This script orchestrates the bundling of project files for AI ingestion.
    It leverages several sub-modules located in 'Meta\BundlerModules\' for specific tasks:
    - 'Bundle.Utils.psm1': Handles version extraction and project structure overview.
    - 'Bundle.FileProcessor.psm1': Handles individual file reading, language hinting, synopsis/dependency extraction.
    - 'Bundle.ExternalTools.psm1': Handles PSScriptAnalyzer execution.
    - 'Bundle.StateAndAssembly.psm1': Handles AI State block generation (loading from 'Meta\AIState.template.psd1')
                                     and final assembly of all bundle content.
    - 'Bundle.ProjectScanner.psm1': Handles the main iteration over project files, applying exclusions.

    The script first adds itself, its sub-modules, and 'Meta\AIState.template.psd1' to the bundle.
    Then, it invokes 'Bundle.ProjectScanner.psm1' to process the main project files.
    Finally, it assembles all collected information and generated content into 'PoSh-Backup-AI-Bundle.txt'.
.PARAMETER ProjectRoot
    The root directory of the project to bundle. Defaults to the parent directory of this script's location.
    Must be a valid, existing directory.
.PARAMETER ExcludedFolders
    An array of folder names (relative to ProjectRoot) to exclude from bundling by the ProjectScanner module.
    Note: 'Meta\BundlerModules' and 'Meta\AIState.template.psd1' are always included by this main script.
.PARAMETER ExcludedFileExtensions
    An array of file extensions (including the dot, e.g., ".log") to exclude by the ProjectScanner module.
.PARAMETER NoRunScriptAnalyzer
    A switch parameter. If present, PSScriptAnalyzer will NOT be run.
.EXAMPLE
    .\Meta\Generate-ProjectBundleForAI.ps1
    Generates 'PoSh-Backup-AI-Bundle.txt', including PSScriptAnalyzer output by default.

.EXAMPLE
    .\Meta\Generate-ProjectBundleForAI.ps1 -NoRunScriptAnalyzer
    Generates 'PoSh-Backup-AI-Bundle.txt', skipping PSScriptAnalyzer output.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.25.2 # Updated for new AI state items and checksum feature summary.
    DateCreated:    15-May-2025
    LastModified:   24-May-2025
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
    [switch]$NoRunScriptAnalyzer
)

try {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "..\Modules\Utilities\ConsoleDisplayUtils.psm1") -Force -ErrorAction Stop

    # We don't have access to the colour map so just use hardcoded colour values for now.
    Write-ConsoleBanner -NameText "PoSh Backup" `
        -NameForegroundColor 'Cyan' `
        -ValueText "AI Script Bundler" `
        -ValueForegroundColor 'DarkCyan' `
        -BannerWidth 78 `
        -BorderForegroundColor 'White' `
        -CenterText `
        -PrependNewLine
}
catch {
    Write-Host "[DEBUG] Couldn't import the 'ConsoleDisplayUtils.psm1' module: $($_.Exception.Message). No biggy." -ForegroundColor "Red"
}

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

    # Having to import this again here as the above Bundle.StateAndAssembly.psm1 import seems to zap ConsoleDisplayUtils.psm1 from existence?
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "..\Modules\Utilities\ConsoleDisplayUtils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $bundlerModulesPath -ChildPath "Bundle.ProjectScanner.psm1") -Force -ErrorAction Stop

    Write-Verbose "Bundler utility modules loaded."
}
catch {
    Write-Error "FATAL: Failed to import required bundler script modules from '$bundlerModulesPath'. Error: $($_.Exception.Message)"
    exit 11
}
# --- End Bundler Module Imports ---

# --- Main Script Setup ---
$shouldRunScriptAnalyzer = -not $NoRunScriptAnalyzer.IsPresent

$ProjectRoot_DisplayName = (Get-Item -LiteralPath $ProjectRoot_FullPath).Name
$outputFilePath = Join-Path -Path $ProjectRoot_FullPath -ChildPath "PoSh-Backup-AI-Bundle.txt"

$normalisedProjectRootForCalculations = (Resolve-Path $ProjectRoot_FullPath).Path

Write-Host " The purpose of this script is to bundle all aspects of  PoSh Backup together" -ForegroundColor DarkYellow
Write-Host " into a single file that can be presented to an AI for ingestion. This allows" -ForegroundColor DarkYellow
Write-Host " a new chat session to be started with the  AI;  simply paste the contents of" -ForegroundColor DarkYellow
Write-Host " the bundle into the chat window, wait for its analysis,  and  you  should be" -ForegroundColor DarkYellow
Write-Host " able to continue development as though it was the same, prior session." -ForegroundColor DarkYellow

Write-Host
Write-Host "  Starting project file bundling process..."
Write-Host
Write-NameValue "Script sxecution Project Root" $ProjectRoot_FullPath
Write-NameValue "Bundle displayed Project Root" $ProjectRoot_DisplayName
Write-NameValue "Run PSScriptAnalyzer" $shouldRunScriptAnalyzer

# Below makes things a bit visually messy, and it seems a bit redundant as this is shown at the end anyway.
#Write-NameValue "Output File" $outputFilePath

Write-Verbose "  Normalised project root for path calculations: $normalisedProjectRootForCalculations"

$headerContentBuilder = [System.Text.StringBuilder]::new()
$null = $headerContentBuilder.AppendLine("Hello AI Assistant!")
$null = $headerContentBuilder.AppendLine("")
$null = $headerContentBuilder.AppendLine("This bundle contains the current state of our PowerShell backup project ('PoSh-Backup').")
$null = $headerContentBuilder.AppendLine("It is designed to allow us to seamlessly continue our previous conversation in a new chat session.")
$null = $headerContentBuilder.AppendLine("")
$null = $headerContentBuilder.AppendLine("Please review the AI State, Project Structure Overview, and then the bundled files.")
$null = $headerContentBuilder.AppendLine("")
$null = $headerContentBuilder.AppendLine("After you've processed this, remember: Always generate one full untruncated file at a time (unless the changes are very minor, then provide instructions for the user to manually make that change), trim trailing whitespace, perform mental diffs, and provide line count differences. Ground via Google Search.")
$null = $headerContentBuilder.AppendLine("")

$fileContentBuilder = [System.Text.StringBuilder]::new()
# --- End Main Script Setup ---

# --- Main Processing Logic ---
try {
    if (-not (Test-Path -LiteralPath $ProjectRoot_FullPath -PathType Container)) {
        $errorMessage = "Project root '$ProjectRoot_FullPath' not found or is not a directory (post-parameter validation check)."
        Write-Error $errorMessage
        Remove-Item -LiteralPath $outputFilePath -Force -ErrorAction SilentlyContinue
        ($headerContentBuilder.ToString() + $fileContentBuilder.ToString()) | Set-Content -Path $outputFilePath -Encoding UTF8 -Force -ErrorAction SilentlyContinue
        exit 1
    }

    $UpdateMetadataFromProcessingResult = {
        param($FileObjectParam, $ProcessingResult)
        if ($null -ne $ProcessingResult) {
            if (-not [string]::IsNullOrWhiteSpace($ProcessingResult.Synopsis)) {
                $currentRelPath = $FileObjectParam.FullName.Substring($normalisedProjectRootForCalculations.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
                $script:autoDetectedModuleDescriptions[$currentRelPath] = $ProcessingResult.Synopsis
            }
            if ($null -ne $ProcessingResult.Dependencies -and $ProcessingResult.Dependencies.Count -gt 0) {
                foreach ($dep in $ProcessingResult.Dependencies) {
                    $null = $script:autoDetectedPsDependencies.Add($dep)
                }
            }
        }
    }

    # Add this script (Generate-ProjectBundleForAI.ps1)
    $thisScriptFileObject = Get-Item -LiteralPath $PSCommandPath
    Write-Verbose "Explicitly adding bundler script itself to bundle: $($thisScriptFileObject.FullName)"
    $bundlerScriptProcessingResult = Add-FileToBundle -FileObject $thisScriptFileObject `
        -RootPathForRelativeCalculations $normalisedProjectRootForCalculations `
        -BundleBuilder $fileContentBuilder
    & $UpdateMetadataFromProcessingResult -FileObjectParam $thisScriptFileObject -ProcessingResult $bundlerScriptProcessingResult

    # Add AIState.template.psd1 from Meta folder
    $aiStateTemplateFile = Join-Path -Path $PSScriptRoot -ChildPath "AIState.template.psd1"
    if (Test-Path -LiteralPath $aiStateTemplateFile -PathType Leaf) {
        $aiStateTemplateFileObject = Get-Item -LiteralPath $aiStateTemplateFile
        Write-Verbose "Explicitly adding AI State template to bundle: $($aiStateTemplateFileObject.FullName)"
        $aiStateTemplateProcessingResult = Add-FileToBundle -FileObject $aiStateTemplateFileObject `
            -RootPathForRelativeCalculations $normalisedProjectRootForCalculations `
            -BundleBuilder $fileContentBuilder
        & $UpdateMetadataFromProcessingResult -FileObjectParam $aiStateTemplateFileObject -ProcessingResult $aiStateTemplateProcessingResult
    }
    else {
        Write-Warning "AI State template file 'Meta\AIState.template.psd1' not found. It will not be included in the bundle."
    }

    $packagerScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "Package-PoShBackupRelease.ps1"
    if (Test-Path -LiteralPath $packagerScriptFile -PathType Leaf) {
        $packagerScriptFileObject = Get-Item -LiteralPath $packagerScriptFile
        Write-Verbose "Explicitly adding Release Packager script to bundle: $($packagerScriptFileObject.FullName)"
        $packagerProcessingResult = Add-FileToBundle -FileObject $packagerScriptFileObject `
            -RootPathForRelativeCalculations $normalisedProjectRootForCalculations `
            -BundleBuilder $fileContentBuilder
        # Update metadata if needed (e.g., if it had a synopsis we wanted in AI state, though it's a utility script)
        & $UpdateMetadataFromProcessingResult -FileObjectParam $packagerScriptFileObject -ProcessingResult $packagerProcessingResult
        # Add its path to the explicit exclusion list for ProjectScanner, so it's not processed twice
        # if "Meta" was NOT in $ExcludedFolders for some reason (though it usually is).
        # This is more of a safeguard.
        if ($null -eq $MetaFilesToExcludeExplicitly) { $MetaFilesToExcludeExplicitly = @() }
        $MetaFilesToExcludeExplicitly += $packagerScriptFileObject.FullName
    }
    else {
        Write-Warning "Release Packager script 'Meta\Package-PoShBackupRelease.ps1' not found. It will not be included in the bundle."
    }

  # --- NEW: Add Version.psd1 from Meta folder ---
    $versionMetaFile = Join-Path -Path $PSScriptRoot -ChildPath "Version.psd1"
    if (Test-Path -LiteralPath $versionMetaFile -PathType Leaf) {
        $versionMetaFileObject = Get-Item -LiteralPath $versionMetaFile
        Write-Verbose "Explicitly adding Meta Version file to bundle: $($versionMetaFileObject.FullName)"
        $versionMetaProcessingResult = Add-FileToBundle -FileObject $versionMetaFileObject `
            -RootPathForRelativeCalculations $normalisedProjectRootForCalculations `
            -BundleBuilder $fileContentBuilder
        # Version.psd1 doesn't have a synopsis, so $UpdateMetadataFromProcessingResult might not add much but is harmless
        & $UpdateMetadataFromProcessingResult -FileObjectParam $versionMetaFileObject -ProcessingResult $versionMetaProcessingResult
        if ($null -eq $MetaFilesToExcludeExplicitly) { $MetaFilesToExcludeExplicitly = @() }
        $MetaFilesToExcludeExplicitly += $versionMetaFileObject.FullName
    }
    else {
        Write-Warning "Meta Version file 'Meta\Version.psd1' not found. It will not be included in the bundle."
    }
    # --- END NEW ---

    # --- NEW: Add apply_update.ps1 from Meta folder ---
    $applyUpdateScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "apply_update.ps1"
    if (Test-Path -LiteralPath $applyUpdateScriptFile -PathType Leaf) {
        $applyUpdateScriptFileObject = Get-Item -LiteralPath $applyUpdateScriptFile
        Write-Verbose "Explicitly adding Apply Update script to bundle: $($applyUpdateScriptFileObject.FullName)"
        $applyUpdateProcessingResult = Add-FileToBundle -FileObject $applyUpdateScriptFileObject `
            -RootPathForRelativeCalculations $normalisedProjectRootForCalculations `
            -BundleBuilder $fileContentBuilder
        & $UpdateMetadataFromProcessingResult -FileObjectParam $applyUpdateScriptFileObject -ProcessingResult $applyUpdateProcessingResult
        if ($null -eq $MetaFilesToExcludeExplicitly) { $MetaFilesToExcludeExplicitly = @() }
        $MetaFilesToExcludeExplicitly += $applyUpdateScriptFileObject.FullName
    }
    else {
        Write-Warning "Apply Update script 'Meta\apply_update.ps1' not found. It will not be included in the bundle."
    }
    # --- END NEW ---

    # Add Bundler Modules
    $bundlerModulesDir = Join-Path -Path $PSScriptRoot -ChildPath "BundlerModules"
    if (Test-Path -LiteralPath $bundlerModulesDir -PathType Container) {
        Write-Verbose "Adding bundler's own modules from '$bundlerModulesDir'..."
        Get-ChildItem -Path $bundlerModulesDir -Filter *.psm1 -File -ErrorAction SilentlyContinue | ForEach-Object {
            $bundlerModuleFile = $_
            Write-Verbose "Adding bundler module to bundle: $($bundlerModuleFile.Name)"
            $moduleProcessingResult = Add-FileToBundle -FileObject $bundlerModuleFile `
                -RootPathForRelativeCalculations $normalisedProjectRootForCalculations `
                -BundleBuilder $fileContentBuilder
            & $UpdateMetadataFromProcessingResult -FileObjectParam $bundlerModuleFile -ProcessingResult $moduleProcessingResult
        }
    }
    else {
        Write-Warning "Bundler modules directory '$bundlerModulesDir' not found. Bundler's own modules will not be included in the bundle."
    }

    # Scan and add main project files
    $projectScanResult = Invoke-BundlerProjectScan -ProjectRoot_FullPath $ProjectRoot_FullPath `
        -NormalizedProjectRootForCalculations $normalisedProjectRootForCalculations `
        -OutputFilePath $outputFilePath `
        -ThisScriptFileObject $thisScriptFileObject `
        -BundlerModulesDir $bundlerModulesDir `
        -ExcludedFolders $ExcludedFolders `
        -ExcludedFileExtensions $ExcludedFileExtensions `
        -FileContentBuilder $fileContentBuilder `
        -MetaFilesToExcludeExplicitly @($aiStateTemplateFile)

    if ($null -ne $projectScanResult) {
        if ($null -ne $projectScanResult.ModuleDescriptions) {
            $projectScanResult.ModuleDescriptions.GetEnumerator() | ForEach-Object {
                $script:autoDetectedModuleDescriptions[$_.Name] = $_.Value
            }
        }
        if ($null -ne $projectScanResult.PsDependencies) {
            $projectScanResult.PsDependencies | ForEach-Object {
                $null = $script:autoDetectedPsDependencies.Add($_)
            }
        }
    }
    Write-Verbose "Finished all file processing and metadata collection."
}
catch {
    $errorMessage = "An unexpected error occurred during file processing: $($_.Exception.ToString())"
    Write-Error $errorMessage
    $null = $fileContentBuilder.AppendLine("ERROR: $errorMessage")
}
finally {
    Write-Verbose "Reading PoSh-Backup.ps1 for version information..."
    $mainPoShBackupScriptPath = Join-Path -Path $ProjectRoot_FullPath -ChildPath "PoSh-Backup.ps1"
    $mainPoShBackupScriptFileObject = Get-Item -LiteralPath $mainPoShBackupScriptPath -ErrorAction SilentlyContinue
    $poShBackupVersion = "N/A"
    if ($mainPoShBackupScriptFileObject) {
        $poShBackupVersion = Get-ScriptVersionFromContent -ScriptContent (Get-Content -LiteralPath $mainPoShBackupScriptFileObject.FullName -Raw -ErrorAction SilentlyContinue) -ScriptNameForWarning "PoSh-Backup.ps1"
    }
    else {
        Write-Warning "Bundler: Main script PoSh-Backup.ps1 not found at '$mainPoShBackupScriptPath' for version extraction."
    }

    Write-Verbose "Reading bundler script for its own version information..."
    $thisBundlerScriptFileObjectForVersion = Get-Item -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue
    $bundlerScriptVersionForState = "1.25.2" # Updated version for this change
    if ($thisBundlerScriptFileObjectForVersion) {
        $readBundlerVersion = Get-ScriptVersionFromContent -ScriptContent (Get-Content -LiteralPath $thisBundlerScriptFileObjectForVersion.FullName -Raw -ErrorAction SilentlyContinue) -ScriptNameForWarning $thisBundlerScriptFileObjectForVersion.Name
        if ($readBundlerVersion -ne $bundlerScriptVersionForState -and $readBundlerVersion -ne "N/A" -and $readBundlerVersion -notlike "N/A (*" ) {
            Write-Verbose "Bundler: Read version '$readBundlerVersion' from current disk file's CBH ($($thisBundlerScriptFileObjectForVersion.Name)), but AI State will use hardcoded version '$bundlerScriptVersionForState' for this generation. Ensure CBH is updated to '$bundlerScriptVersionForState'."
        }
    }
    else {
        Write-Warning "Bundler: Could not get bundler script file object ('$($PSCommandPath)') for version extraction. Using manually set version '$bundlerScriptVersionForState' for AI State."
    }

    $aiStateHashtable = Get-BundlerAIState -ProjectRoot_DisplayName $ProjectRoot_DisplayName `
        -PoShBackupVersion $poShBackupVersion `
        -BundlerScriptVersion $bundlerScriptVersionForState `
        -AutoDetectedModuleDescriptions $script:autoDetectedModuleDescriptions `
        -AutoDetectedPsDependencies $script:autoDetectedPsDependencies

    $projectStructureContentString = Get-ProjectStructureOverviewContent -ProjectRoot_FullPath $ProjectRoot_FullPath `
        -ProjectRoot_DisplayName $ProjectRoot_DisplayName `
        -BundlerOutputFilePath $outputFilePath

    $analyzerSettingsPath = Join-Path -Path $ProjectRoot_FullPath -ChildPath "PSScriptAnalyzerSettings.psd1"
    $analyzerSettingsFileContentString = ""
    if ($shouldRunScriptAnalyzer -and (Test-Path -LiteralPath $analyzerSettingsPath -PathType Leaf)) {
        try {
            $analyzerSettingsFileContentString = Get-Content -LiteralPath $analyzerSettingsPath -Raw -ErrorAction Stop
        }
        catch {
            $analyzerSettingsFileContentString = "(Bundler Main: Error reading PSScriptAnalyzerSettings.psd1: $($_.Exception.Message))"
        }
    }

    # Indent the output by two spaces so the "Running PSScriptAnalyzer ..." itself is indented, if the analyser is enabled.
    if ($shouldRunScriptAnalyzer) {
        Write-Host
        Write-Host "  " -NoNewline
    }

    # This var contains the PSSA warnings for the project.
    $pssaResultOutputString = ""
    if ($shouldRunScriptAnalyzer) {
        $pssaResultOutputString = Invoke-BundlerScriptAnalyzer -ProjectRoot_FullPath $ProjectRoot_FullPath `
            -ExcludedFoldersForPSSA $ExcludedFolders `
            -AnalyzerSettingsPath $analyzerSettingsPath `
            -BundlerOutputFilePath $outputFilePath `
            -BundlerPSScriptRoot $PSScriptRoot
    }

    Write-Verbose "Assembling final output bundle (via Bundle.StateAndAssembly.psm1)..."
    $finalBundleString = Format-AIBundleContent -HeaderContent $headerContentBuilder.ToString() `
        -AIStateHashtable $aiStateHashtable `
        -ProjectStructureContent $projectStructureContentString `
        -AnalyzerSettingsFileContent $analyzerSettingsFileContentString `
        -PSSASummaryOutputContent $pssaResultOutputString `
        -BundledFilesContent $fileContentBuilder.ToString()
    try {
        Write-Verbose "Writing final bundle to: $outputFilePath"
        Remove-Item -LiteralPath $outputFilePath -Force -ErrorAction SilentlyContinue
        $finalBundleString | Set-Content -Path $outputFilePath -Encoding UTF8 -Force
        Write-Host
        Write-Host "  Project bundle successfully written to:" -ForegroundColor "DarkGreen"
        Write-Host "      $($outputFilePath)" -ForegroundColor "Green"
    }
    catch {
        Write-Host
        Write-Error "  Failed to write project bundle to file '$outputFilePath'. Error: $($_.Exception.Message)"
    }

    # Write out a blank line to cap everything off.
    Write-Host
}
