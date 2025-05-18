<#
.SYNOPSIS
    Handles the execution of external tools like PSScriptAnalyzer for the AI project bundler.

.DESCRIPTION
    This module encapsulates the logic for invoking PSScriptAnalyzer, capturing its output
    for inclusion in the AI bundle. This keeps the main bundler script cleaner and
    more focused on orchestration.
    The PoSh-Backup -TestConfig output capture has been removed due to reliability issues.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Removed Get-BundlerTestConfigOutput function.
    DateCreated:    17-May-2025
    LastModified:   18-May-2025
    Purpose:        External tool execution utilities for the AI project bundler.
#>

# --- Exported Functions ---

function Invoke-BundlerScriptAnalyzer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot_FullPath,
        [Parameter(Mandatory)]
        [string[]]$ExcludedFoldersForPSSA, # Specifically for PSSA's scope, not the general bundler exclusion
        [Parameter(Mandatory)]
        [string]$AnalyzerSettingsPath, # Full path to PSScriptAnalyzerSettings.psd1
        [Parameter(Mandatory=$false)]
        [string]$BundlerOutputFilePath = $null, # Path to the bundle output file itself, to exclude from PSSA
        [Parameter(Mandatory=$false)]
        [string]$BundlerPSScriptRoot = $null # PSScriptRoot of the main bundler, to help exclude Meta if needed
    )

    $pssaOutputBuilder = [System.Text.StringBuilder]::new()

    if (-not (Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue)) {
        $null = $pssaOutputBuilder.AppendLine("(PSScriptAnalyzer module not found. To use this feature, install it: Install-Module PSScriptAnalyzer)")
        return $pssaOutputBuilder.ToString()
    }

    try {
        Write-Host "Running PSScriptAnalyzer (this may take a moment)..." -ForegroundColor Yellow
        
        $scriptFilesToAnalyze = Get-ChildItem -Path $ProjectRoot_FullPath -Recurse -Include *.ps1, *.psm1 |
            Where-Object {
                if (($null -ne $BundlerOutputFilePath) -and ($_.FullName -eq $BundlerOutputFilePath)) { return $false } # Skip the bundle output file

                $isExcluded = $false
                foreach($excludedDirName in $ExcludedFoldersForPSSA) {
                    $fullExcludedPath = Join-Path -Path $ProjectRoot_FullPath -ChildPath $excludedDirName
                    if ($_.FullName.StartsWith($fullExcludedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                        if ($excludedDirName -eq "Meta" -and ($null -ne $BundlerPSScriptRoot) -and $_.DirectoryName -eq (Join-Path -Path $BundlerPSScriptRoot -ChildPath "BundlerModules")) {
                             # Bundler modules are typically in Meta\BundlerModules. If "Meta" is excluded from PSSA for the main project,
                             # but we are running PSSA for the bundler itself, this logic might need care.
                             # However, Invoke-BundlerScriptAnalyzer is usually called for the main project, where excluding all of Meta is common.
                        } else {
                            $isExcluded = $true; break
                        }
                    }
                }
                -not $isExcluded
            }

        if ($scriptFilesToAnalyze.Count -gt 0) {
            $allAnalyzerResultsList = [System.Collections.Generic.List[object]]::new()
            foreach ($scriptFile in $scriptFilesToAnalyze) {
                Write-Verbose "Bundler PSSA: Analyzing $($scriptFile.FullName)..."
                $invokeAnalyzerParams = @{
                    Path = $scriptFile.FullName
                    Severity = @('Error', 'Warning')
                    ErrorAction = 'SilentlyContinue'
                }
                if (Test-Path -LiteralPath $AnalyzerSettingsPath -PathType Leaf) {
                    $invokeAnalyzerParams.Settings = $AnalyzerSettingsPath
                    Write-Verbose "Bundler PSSA:   (Using PSScriptAnalyzer settings from: $AnalyzerSettingsPath)"
                } else {
                    Write-Verbose "Bundler PSSA:   (PSScriptAnalyzerSettings.psd1 not found at project root. Using default PSSA rules.)"
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
                $null = $pssaOutputBuilder.AppendLine("Found $($allAnalyzerResultsList.Count) issues (Errors/Warnings):")
                $formattedResults = $allAnalyzerResultsList | Select-Object Severity, Message, ScriptName, Line, Column | Format-Table -AutoSize | Out-String -Width 250
                $null = $pssaOutputBuilder.AppendLine($formattedResults)
            } else {
                $null = $pssaOutputBuilder.AppendLine("(No PSScriptAnalyzer errors or warnings found in .ps1/.psm1 files after applying settings.)")
            }
        } else {
            $null = $pssaOutputBuilder.AppendLine("(No .ps1 or .psm1 files found to analyze in project scope after exclusions.)")
        }
    } catch {
        $null = $pssaOutputBuilder.AppendLine("(Error running PSScriptAnalyzer via Bundler.ExternalTools: $($_.Exception.Message))")
    }
    return $pssaOutputBuilder.ToString()
}

# Get-BundlerTestConfigOutput function has been removed.

Export-ModuleMember -Function Invoke-BundlerScriptAnalyzer
