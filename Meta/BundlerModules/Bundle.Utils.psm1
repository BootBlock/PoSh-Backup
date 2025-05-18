<#
.SYNOPSIS
    Provides utility functions for the Generate-ProjectBundleForAI.ps1 script.
    This includes version extraction from script content and generation of the
    project structure overview.

.DESCRIPTION
    This module consolidates utility functions used by the main bundler script
    (Generate-ProjectBundleForAI.ps1) to keep the main script more focused on
    orchestration.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    17-May-2025
    LastModified:   17-May-2025
    Purpose:        Utility functions for the AI project bundler.
#>

# --- Exported Functions ---

function Get-ScriptVersionFromContent {
    [CmdletBinding()]
    param(
        [string]$ScriptContent,
        [string]$ScriptNameForWarning = "script"
    )
    $versionString = "N/A"
    try {
        if ([string]::IsNullOrWhiteSpace($ScriptContent)) {
            Write-Warning "Bundler Util: Script content provided to Get-ScriptVersionFromContent for '$ScriptNameForWarning' is empty."
            return "N/A (Empty Content)"
        }
        # Regex to find version in .NOTES (e.g., Version: 1.2.3)
        $regexV1 = '(?s)\.NOTES(?:.|\s)*?Version:\s*([0-9]+\.[0-9]+(?:\.[0-9]+)?(?:\.[0-9]+)?.*?)(?:\r?\n|\s*\(|<#)'
        # Regex to find version in a simple "Version: X.Y.Z" line (case-insensitive, multiline)
        $regexV2 = '(?im)^\s*Version:\s*([0-9]+\.[0-9]+(?:\.[0-9]+)?(?:\.[0-9]+)?.*?)(\s*\(|$)'
        # Regex to find version like "Script Version: vX.Y.Z" (case-insensitive, multiline)
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
                    $versionString = "v" + $match.Groups[1].Value.Trim() # Add 'v' prefix if found with this regex
                } else {
                    Write-Warning "Bundler Util: Could not automatically determine version for '$ScriptNameForWarning' using any regex."
                }
            }
        }
    } catch {
        Write-Warning "Bundler Util: Error parsing version for '$ScriptNameForWarning': $($_.Exception.Message)"
    }
    return $versionString
}

function Get-ProjectStructureOverviewContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot_FullPath,
        [Parameter(Mandatory)]
        [string]$ProjectRoot_DisplayName,
        [Parameter(Mandatory=$false)] # Optional, if bundler output file needs to be explicitly skipped by name
        [string]$BundlerOutputFilePath = $null
    )
    $structureBuilder = [System.Text.StringBuilder]::new()
    $null = $structureBuilder.AppendLine("Location: $ProjectRoot_DisplayName (Root of the project)")
    $null = $structureBuilder.AppendLine("(Note: Log files in 'Logs/' and specific report file types in 'Reports/' are excluded from this overview section.)")
    $null = $structureBuilder.AppendLine("")
    try {
        Get-ChildItem -Path $ProjectRoot_FullPath -Depth 0 | Sort-Object PSIsContainer -Descending | ForEach-Object {
            $item = $_
            if ($item.PSIsContainer) {
                $null = $structureBuilder.AppendLine("  |- $($item.Name)/")

                $childItems = Get-ChildItem -Path $item.FullName -Depth 0 -ErrorAction SilentlyContinue

                # Specific handling for common project folders to keep overview concise
                if ($item.Name -eq "Logs") { # Exclude .log files specifically
                    $childItems = $childItems | Where-Object { $_.PSIsContainer -or ($_.Name -notlike "*.log") }
                } elseif ($item.Name -eq "Reports") { # Exclude common report file types
                    $reportFileExtensionsToExcludeInOverview = @(".html", ".csv", ".json", ".xml", ".txt", ".md")
                    $childItems = $childItems | Where-Object { $_.PSIsContainer -or ($_.Extension.ToLowerInvariant() -notin $reportFileExtensionsToExcludeInOverview) }
                } elseif ($item.Name -eq "Meta") { # Show BundlerModules and the main bundler script
                     $childItems = $childItems | Where-Object { $_.Name -eq "Generate-ProjectBundleForAI.ps1" -or $_.Name -eq "BundlerModules" -or $_.PSIsContainer}
                } elseif ($item.Name -eq "Tests") { # Indicate content exclusion
                    $null = $structureBuilder.AppendLine("  |  |- ... (Content excluded by bundler settings)")
                    $childItems = @() # Prevent listing individual test files
                }


                $childItems | Sort-Object PSIsContainer -Descending | ForEach-Object {
                    $childItem = $_
                    if ($childItem.PSIsContainer) {
                        if ($item.Name -eq "Meta" -and $childItem.Name -eq "BundlerModules") {
                             $null = $structureBuilder.AppendLine("  |  |- $($childItem.Name)/ ...") # Show BundlerModules specifically
                        } elseif ($item.Name -notin @("Config", "Modules")) { # For other top-level folders, just show "..."
                            $null = $structureBuilder.AppendLine("  |  |- $($childItem.Name)/ ...")
                        } else { # For Config and Modules, list direct children
                            $null = $structureBuilder.AppendLine("  |  |- $($childItem.Name)/ ...") # Keep as "..." for now, can be expanded if needed by AI
                        }
                    } else {
                        $null = $structureBuilder.AppendLine("  |  |- $($childItem.Name)")
                    }
                }
            } else {
                # Explicitly skip the bundler output file from the root listing if path is provided
                if (($null -eq $BundlerOutputFilePath) -or ($item.FullName -ne $BundlerOutputFilePath)) {
                    $null = $structureBuilder.AppendLine("  |- $($item.Name)")
                }
            }
        }
    } catch {
        $null = $structureBuilder.AppendLine("  (Error generating structure overview: $($_.Exception.Message))")
    }
    return $structureBuilder.ToString()
}


Export-ModuleMember -Function Get-ScriptVersionFromContent, Get-ProjectStructureOverviewContent
