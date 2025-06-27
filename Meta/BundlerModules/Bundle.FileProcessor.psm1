<#
.SYNOPSIS
    Handles the processing of individual files for the AI project bundler.
    This includes reading file content, determining language hints, and extracting
    module synopses and PowerShell dependencies.

.DESCRIPTION
    This module encapsulates the logic for taking a file, reading its content,
    formatting it for the bundle, and extracting relevant metadata like its
    synopsis (for PowerShell modules/scripts) and any #Requires -Module statements.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.1 # Added placeholder for missing PowerShell synopses.
    DateCreated:    17-May-2025
    LastModified:   18-May-2025
    Purpose:        File processing utilities for the AI project bundler.
#>

# --- Module-Scoped Variables ---
$Script:FileProcessor_FileExtensionToLanguageMap = @{
    ".ps1"    = "powershell"; ".psm1"   = "powershell"; ".psd1"   = "powershell"
    ".css"    = "css";        ".html"   = "html";       ".js"     = "javascript"
    ".json"   = "json";       ".xml"    = "xml";        ".md"     = "markdown"
    ".txt"    = "text";       ".yml"    = "yaml";       ".yaml"   = "yaml"
    ".ini"    = "ini";        ".conf"   = "plaintext";  ".config" = "xml"
    ".sh"     = "shell";      ".bash"   = "bash";       ".py"     = "python"
    ".cs"     = "csharp";     ".c"      = "c";          ".cpp"    = "cpp"; ".h" = "c"
    ".java"   = "java";       ".rb"     = "ruby";       ".php"    = "php"
    ".go"     = "go";         ".swift"  = "swift";      ".kt"     = "kotlin"
    ".sql"    = "sql"
}

$Script:SynopsisMissingPlaceholder = "POWERSHELL_SYNOPSIS_MISSING_OR_UNPARSABLE"
# --- End Module-Scoped Variables ---


# --- Exported Functions ---

function Add-FileToBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$FileObject,
        [Parameter(Mandatory)]
        [string]$RootPathForRelativeCalculations,
        [Parameter(Mandatory)]
        [System.Text.StringBuilder]$BundleBuilder # StringBuilder to append the file's bundle representation
    )

    $currentRelativePath = $FileObject.FullName.Substring($RootPathForRelativeCalculations.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $fileExtLower = $FileObject.Extension.ToLowerInvariant()

    $currentLanguageHint = if ($Script:FileProcessor_FileExtensionToLanguageMap.ContainsKey($fileExtLower)) {
        $Script:FileProcessor_FileExtensionToLanguageMap[$fileExtLower]
    } else {
        "text"
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
        # Fallback if Get-Content with -Encoding UTF8 returns null but $LASTEXITCODE is non-zero (can happen with some files/systems)
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
        $null = $BundleBuilder.AppendLine("(Error reading file '$($FileObject.FullName)': $($_.Exception.Message))")
    }
    $null = $BundleBuilder.AppendLine("--- FILE_END ---")
    $null = $BundleBuilder.AppendLine("") # Add a blank line after each file block for readability

    # Initialise return data
    $extractedSynopsis = $null
    $extractedDependencies = [System.Collections.Generic.List[string]]::new()

    # Extract synopsis and dependencies if it's a PowerShell script/module
    if ($FileObject.Extension -in ".ps1", ".psm1") {
        if (-not [string]::IsNullOrEmpty($fileContent)) {
            # Synopsis Extraction
            try {
                $synopsisMatch = [regex]::Match($fileContent, '(?s)\.SYNOPSIS\s*(.*?)(?=\r?\n\s*\.(?:DESCRIPTION|EXAMPLE|PARAMETER|NOTES|LINK)|<#|$)')
                if ($synopsisMatch.Success) {
                    $synopsisText = $synopsisMatch.Groups[1].Value.Trim() -replace '\s*\r?\n\s*', ' ' -replace '\s{2,}', ' '
                    if ($synopsisText.Length -gt 200) { $synopsisText = $synopsisText.Substring(0, 197) + "..." }
                    if (-not [string]::IsNullOrWhiteSpace($synopsisText)) {
                        $extractedSynopsis = $synopsisText
                    } else {
                        $extractedSynopsis = $Script:SynopsisMissingPlaceholder # Synopsis block found but empty
                    }
                } else {
                    $extractedSynopsis = $Script:SynopsisMissingPlaceholder # No .SYNOPSIS block found
                }
            } catch {
                Write-Warning "Bundler FileProcessor: Error parsing synopsis for '$currentRelativePath': $($_.Exception.Message)"
                $extractedSynopsis = $Script:SynopsisMissingPlaceholder # Error during parsing
            }

            # PowerShell Dependency Extraction (#Requires -Module)
            try {
                $regexPatternForRequires = '(?im)^\s*#Requires\s+-Module\s+(?:@{ModuleName\s*=\s*)?["'']?([a-zA-Z0-9._-]+)["'']?'
                $requiresMatches = [regex]::Matches($fileContent, $regexPatternForRequires)

                if ($requiresMatches.Count -gt 0) {
                    foreach ($reqMatch in $requiresMatches) {
                        if ($reqMatch.Groups[1].Success) {
                            $moduleName = $reqMatch.Groups[1].Value
                            $extractedDependencies.Add($moduleName)
                        }
                    }
                }
            } catch {
                Write-Warning "Bundler FileProcessor: Error parsing #Requires for '$currentRelativePath': $($_.Exception.Message)"
            }
        } else {
            # File is .ps1 or .psm1, but content is empty or unreadable
            $extractedSynopsis = $Script:SynopsisMissingPlaceholder
        }
    }

    return @{
        Synopsis     = $extractedSynopsis # Will be populated for PS files (real or placeholder), null otherwise
        Dependencies = $extractedDependencies.ToArray() 
    }
}

Export-ModuleMember -Function Add-FileToBundle
