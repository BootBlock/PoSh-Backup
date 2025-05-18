<#
.SYNOPSIS
    Handles the execution of external tools like PSScriptAnalyzer and the
    PoSh-Backup script's -TestConfig mode for the AI project bundler.

.DESCRIPTION
    This module encapsulates the logic for invoking external tools or specific
    modes of the main project script, capturing their output for inclusion in the
    AI bundle. This keeps the main bundler script cleaner and more focused on
    orchestration.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    17-May-2025
    LastModified:   17-May-2025
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
                        # If the excluded folder is "Meta", ensure we are not accidentally excluding bundler modules if they are meant to be analyzed
                        # (though typically Meta itself is excluded from general project analysis)
                        if ($excludedDirName -eq "Meta" -and ($null -ne $BundlerPSScriptRoot) -and $_.DirectoryName -eq (Join-Path -Path $BundlerPSScriptRoot -ChildPath "BundlerModules")) {
                             # Do not exclude bundler modules if Meta is in ExcludedFoldersForPSSA but we still want them analyzed
                             # This scenario might need refinement based on how PSSA is called for the bundler itself vs the project
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


function Get-BundlerTestConfigOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot_FullPath
    )
    $testConfigOutputBuilder = [System.Text.StringBuilder]::new()
    $fullPathToPoShBackupScript = Join-Path -Path $ProjectRoot_FullPath -ChildPath "PoSh-Backup.ps1"

    if (-not (Test-Path -LiteralPath $fullPathToPoShBackupScript -PathType Leaf)) {
        $null = $testConfigOutputBuilder.AppendLine("(PoSh-Backup.ps1 not found at '$fullPathToPoShBackupScript'. Cannot run -TestConfig.)")
        return $testConfigOutputBuilder.ToString()
    }

    try {
        Write-Host "Running 'PoSh-Backup.ps1 -TestConfig' (this may take a moment)..." -ForegroundColor Yellow

        $oldErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue" # Important for Invoke-Expression to not halt the bundler on script errors
        $testConfigOutput = ""
        $LASTEXITCODE = 0 # Reset before call

        Push-Location (Split-Path -Path $fullPathToPoShBackupScript -Parent)
        try {
            # Use *>&1 to capture all streams.
            $invokeCommand = ". `"$fullPathToPoShBackupScript`" -TestConfig *>&1"
            $testConfigOutput = Invoke-Expression $invokeCommand | Out-String
        }
        catch {
            # Capture exception from Invoke-Expression itself
            $testConfigOutput = "INVOKE-EXPRESSION FAILED: $($_.Exception.ToString())`n$($_.ScriptStackTrace)"
            if ($Error.Count -gt 0) { # Check for script-level errors that Invoke-Expression might have swallowed
                $testConfigOutput += "`nLAST SCRIPT ERROR: $($Error[0].ToString())`n$($Error[0].ScriptStackTrace)"
            }
        }
        finally {
            Pop-Location
            $ErrorActionPreference = $oldErrorActionPreference
        }

        # Check LASTEXITCODE after Invoke-Expression.
        # Some script errors inside the invoked script might not set LASTEXITCODE if not explicitly exiting with a code.
        if ($LASTEXITCODE -ne 0 -and -not ([string]::IsNullOrWhiteSpace($testConfigOutput))) {
             $null = $testConfigOutputBuilder.AppendLine("(PoSh-Backup.ps1 -TestConfig exited with code $LASTEXITCODE. Output/Error follows.)")
        } elseif ($LASTEXITCODE -ne 0) {
             $null = $testConfigOutputBuilder.AppendLine("(PoSh-Backup.ps1 -TestConfig exited with code $LASTEXITCODE. No specific output captured.)")
        }
        # Handle case where TestConfig might run "successfully" (exit 0) but still produce no output.
        if ([string]::IsNullOrWhiteSpace($testConfigOutput) -and $LASTEXITCODE -eq 0){
            $null = $testConfigOutputBuilder.AppendLine("(PoSh-Backup.ps1 -TestConfig ran successfully but produced no console output.)")
        } else {
            $null = $testConfigOutputBuilder.AppendLine($testConfigOutput.TrimEnd())
        }

    } catch {
        $null = $testConfigOutputBuilder.AppendLine("(Bundler.ExternalTools error trying to run PoSh-Backup.ps1 -TestConfig: $($_.Exception.ToString()))")
    }
    return $testConfigOutputBuilder.ToString()
}

Export-ModuleMember -Function Invoke-BundlerScriptAnalyzer, Get-BundlerTestConfigOutput
