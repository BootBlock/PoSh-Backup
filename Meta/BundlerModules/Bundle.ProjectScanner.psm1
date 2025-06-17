# Meta\BundlerModules\Bundle.ProjectScanner.psm1
<#
.SYNOPSIS
    Scans the project directory for files to be included in the AI bundle,
    applying exclusion rules and processing each valid file.

.DESCRIPTION
    This module is responsible for the main iteration over project files.
    It uses Get-ChildItem to find files, applies various exclusion criteria
    (e.g., configured excluded folders/extensions, avoiding the bundler's own
    files if already processed, excluding Config\User*.psd1 files), and then calls functions from
    Bundle.FileProcessor.psm1 to process each eligible file and extract metadata.
    It aggregates the extracted metadata (module descriptions and PowerShell dependencies)
    and returns it.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.2 # Added exclusion for Config\User*.psd1 files.
    DateCreated:    17-May-2025
    LastModified:   29-May-2025
    Purpose:        Project file scanning and processing orchestration for the AI project bundler.
    DependsOn:      Bundle.FileProcessor.psm1 (for Add-FileToBundle)
#>

# --- Exported Functions ---

function Invoke-BundlerProjectScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot_FullPath,
        [Parameter(Mandatory)]
        [string]$NormalizedProjectRootForCalculations,
        [Parameter(Mandatory)]
        [string]$OutputFilePath,
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$ThisScriptFileObject, # Main bundler script file object
        [Parameter(Mandatory)]
        [string]$BundlerModulesDir, # Path to Meta\BundlerModules
        [Parameter(Mandatory)]
        [string[]]$ExcludedFolders,
        [Parameter(Mandatory)]
        [string[]]$ExcludedFileExtensions,
        [Parameter(Mandatory)]
        [System.Text.StringBuilder]$FileContentBuilder, # Used by Add-FileToBundle
        [Parameter(Mandatory=$false)]
        [string[]]$MetaFilesToExcludeExplicitly = @()
    )

    $collectedModuleDescriptions = @{}
    $collectedPsDependencies = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    Write-Verbose "Bundler ProjectScanner: Starting scan of project files in '$ProjectRoot_FullPath'..."
    Get-ChildItem -Path $ProjectRoot_FullPath -Recurse -File -Depth 10 -ErrorAction SilentlyContinue | ForEach-Object {
        $file = $_

        # Exclusion checks
        if ($file.FullName -eq $ThisScriptFileObject.FullName) {
            Write-Verbose "Bundler ProjectScanner: Skipping main bundler script (should have been added explicitly): $($file.FullName)"; return
        }
        if (($null -ne $BundlerModulesDir) -and ($file.DirectoryName -eq $BundlerModulesDir) -and $file.Extension -eq ".psm1") {
            Write-Verbose "Bundler ProjectScanner: Skipping bundler module (should have been added explicitly): $($file.FullName)"; return
        }
        if ($file.FullName -eq $OutputFilePath) {
            Write-Verbose "Bundler ProjectScanner: Skipping previous output bundle file: $($file.FullName)"; return
        }

        # Skip other explicitly provided meta files (like AIState.template.psd1)
        if ($null -ne $MetaFilesToExcludeExplicitly -and $MetaFilesToExcludeExplicitly.Count -gt 0) {
            foreach ($metaFileToSkipPath in $MetaFilesToExcludeExplicitly) {
                if ($file.FullName -eq $metaFileToSkipPath) {
                    Write-Verbose "Bundler ProjectScanner: Skipping explicitly provided meta file (already added): $($file.FullName)"; return
                }
            }
        }

        # --- EXCLUSION: Skip Config\User*.psd1 files ---
        $normalizedRelativePathForConfigCheck = $file.FullName.Substring($NormalizedProjectRootForCalculations.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        if ($normalizedRelativePathForConfigCheck.StartsWith("Config" + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -and $file.Name -like "User*.psd1") {
            Write-Verbose "Bundler ProjectScanner: Skipping user configuration file in Config folder: $normalizedRelativePathForConfigCheck"
            return # Skips the current file and moves to the next in the ForEach-Object loop
        }

        $currentRelativePath = $file.FullName.Substring($NormalizedProjectRootForCalculations.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)

        $isExcludedFolder = $false
        foreach ($excludedDir in $ExcludedFolders) {
            $normalizedExcludedDir = $excludedDir.TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
            if ($currentRelativePath -like "$normalizedExcludedDir\*" -or $currentRelativePath -eq $normalizedExcludedDir) {
                $isExcludedFolder = $true; break
            }
        }
        if ($isExcludedFolder) {
            Write-Verbose "Bundler ProjectScanner: Skipping file in excluded folder '$($file.Directory.Name)': $currentRelativePath"; return
        }

        if ($ExcludedFileExtensions -contains $file.Extension.ToLowerInvariant()) {
            Write-Verbose "Bundler ProjectScanner: Skipping file due to excluded extension ('$($file.Extension)'): $currentRelativePath"; return
        }

        Write-Verbose "Bundler ProjectScanner: Adding file to bundle: $currentRelativePath"

        $fileProcessingResult = Add-FileToBundle -FileObject $file `
                                                 -RootPathForRelativeCalculations $NormalizedProjectRootForCalculations `
                                                 -BundleBuilder $FileContentBuilder

        if ($null -ne $fileProcessingResult) {
            if (-not [string]::IsNullOrWhiteSpace($fileProcessingResult.Synopsis)) {
                $collectedModuleDescriptions[$currentRelativePath] = $fileProcessingResult.Synopsis
            }
            if ($null -ne $fileProcessingResult.Dependencies -and $fileProcessingResult.Dependencies.Count -gt 0) {
                foreach ($dep in $fileProcessingResult.Dependencies) {
                    $null = $collectedPsDependencies.Add($dep)
                }
            }
        }
    }
    Write-Verbose "Bundler ProjectScanner: Finished scanning project files."

    return @{
        ModuleDescriptions = $collectedModuleDescriptions
        PsDependencies     = $collectedPsDependencies
    }
}

Export-ModuleMember -Function Invoke-BundlerProjectScan
