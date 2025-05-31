<#
.SYNOPSIS
    Packages the PoSh-Backup project for distribution. It auto-generates 'Meta\Version.psd1'
    by parsing 'PoSh-Backup.ps1', creates a ZIP archive, and then generates a
    'version_manifest.psd1' file.
.DESCRIPTION
    This script performs the following actions:
    1. Parses 'PoSh-Backup.ps1' to extract the current version number.
    2. Auto-generates 'Meta\Version.psd1' using the extracted version, current date,
       and predefined project metadata.
    3. Creates a ZIP archive of the PoSh-Backup project directory using 7-Zip.
       - Excludes specified files and folders not intended for distribution.
       - The ZIP file is named 'PoSh-Backup-v<Version>.zip'.
    4. Calculates the SHA256 checksum of the generated ZIP file.
    5. Generates a 'version_manifest.psd1' file containing details of the new package.
.PARAMETER ProjectRoot
    The root directory of the PoSh-Backup project to package.
    Defaults to the parent directory of this script's location (assuming this script is in 'Meta').
.PARAMETER OutputDirectory
    The directory where the generated ZIP package and version_manifest.psd1 will be saved.
    Defaults to a 'Releases' subdirectory within the ProjectRoot.
.PARAMETER SevenZipPath
    Optional. The full path to the 7z.exe executable.
    If not provided, the script will attempt to find it in common locations or the system PATH.
.PARAMETER ReleaseNotesUrlTemplate
    A string template for the Release Notes URL. Use '{0}' as a placeholder for the version string.
    Default: "https://github.com/BootBlock/PoSh-Backup/releases/tag/v{0}"
.PARAMETER DownloadUrlTemplate
    A string template for the Download URL of the ZIP package. Use '{0}' as a placeholder for the version string.
    Default: "https://github.com/BootBlock/PoSh-Backup/archive/refs/tags/v{0}.zip"
.PARAMETER UpdateSeverity
    The severity to record in the version_manifest.psd1 (e.g., "Optional", "Recommended", "Critical").
    Default: "Recommended"
.PARAMETER UpdateMessage
    A custom message to include in the version_manifest.psd1.
    Default: "Please review the release notes for details on changes in this version."
.EXAMPLE
    .\Meta\Package-PoShBackupRelease.ps1
    Parses PoSh-Backup.ps1 for version, generates Meta\Version.psd1, packages the project,
    and saves output to '.\Releases\'.

.EXAMPLE
    .\Meta\Package-PoShBackupRelease.ps1 -OutputDirectory "C:\MyBuilds"
.NOTES
    Requires 7-Zip to be installed and accessible.
    The version number should be correctly set in 'PoSh-Backup.ps1' (e.g., "Version: 1.15.0").
#>
param(
    [Parameter(Mandatory=$false)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,

    [Parameter(Mandatory=$false)]
    [string]$OutputDirectory,

    [Parameter(Mandatory=$false)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$SevenZipPathOverride,

    [Parameter(Mandatory=$false)]
    [string]$ReleaseNotesUrlTemplate = "https://github.com/BootBlock/PoSh-Backup/releases/tag/v{0}",

    [Parameter(Mandatory=$false)]
    [string]$DownloadUrlTemplate = "https://github.com/BootBlock/PoSh-Backup/archive/refs/tags/v{0}.zip",

    [Parameter(Mandatory=$false)]
    [ValidateSet("Optional", "Recommended", "Critical")]
    [string]$UpdateSeverity = "Recommended",

    [Parameter(Mandatory=$false)]
    [string]$UpdateMessage = "Please review the release notes for details on changes in this version."
)

Write-Host "--- PoSh-Backup Release Packager ---" -ForegroundColor Yellow

# --- Function to Extract Version from Script Content ---
function Get-ScriptVersionFromContentInternal {
    param(
        [string]$ScriptContent,
        [string]$ScriptNameForWarning = "script"
    )
    $versionString = $null # Default to null if not found
    try {
        if ([string]::IsNullOrWhiteSpace($ScriptContent)) {
            Write-Warning "Get-ScriptVersionFromContentInternal: Script content provided for '$ScriptNameForWarning' is empty."
            return $null
        }
        # Regexes in order of preference / commonness
        $regexV2 = '(?im)^\s*Version:\s*([0-9]+\.[0-9]+(?:\.[0-9]+)?(?:\.[0-9]+)?)\b' # Match only version numbers
        $regexV4 = '(?im)^\s*#\s*Version\s*:?\s*([0-9]+\.[0-9]+(?:\.[0-9]+){0,2}(?:\.[0-9]+)?)\b'
        $regexV1 = '(?s)\.NOTES(?:.|\s)*?Version:\s*([0-9]+\.[0-9]+(?:\.[0-9]+)?(?:\.[0-9]+)?)\b'
        $regexV3 = '(?im)Script Version:\s*v?([0-9]+\.[0-9]+(\.[0-9]+)?(\.[0-9]+)?)\b'

        $match = [regex]::Match($ScriptContent, $regexV2)
        if ($match.Success) {
            $versionString = $match.Groups[1].Value.Trim()
        } else {
            $match = [regex]::Match($ScriptContent, $regexV4)
            if ($match.Success) {
                $versionString = $match.Groups[1].Value.Trim()
            } else {
                $match = [regex]::Match($ScriptContent, $regexV1)
                if ($match.Success) {
                    $versionString = $match.Groups[1].Value.Trim()
                } else {
                    $match = [regex]::Match($ScriptContent, $regexV3)
                    if ($match.Success) {
                        $versionString = $match.Groups[1].Value.Trim() # Don't add 'v' here, just the number
                    } else {
                        Write-Warning "Get-ScriptVersionFromContentInternal: Could not automatically determine version for '$ScriptNameForWarning' using any regex."
                    }
                }
            }
        }
    } catch {
        Write-Warning "Get-ScriptVersionFromContentInternal: Error parsing version for '$ScriptNameForWarning': $($_.Exception.Message)"
    }
    return $versionString
}

# --- Validate Project Root ---
if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    Write-Error "ProjectRoot '$ProjectRoot' not found or is not a directory."
    exit 1
}
Write-Host "Project Root: $ProjectRoot"

# --- Determine and Validate Output Directory ---
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path -Path $ProjectRoot -ChildPath "Releases"
}
if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    Write-Host "Output directory '$OutputDirectory' does not exist. Creating it..."
    try {
        New-Item -Path $OutputDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Error "Failed to create output directory '$OutputDirectory'. Error: $($_.Exception.Message)"
        exit 1
    }
}
Write-Host "Output Directory: $OutputDirectory"

# --- Find 7-Zip ---
$sevenZipExe = $SevenZipPathOverride
if ([string]::IsNullOrWhiteSpace($sevenZipExe)) {
    Write-Host "Attempting to find 7z.exe..."
    $commonPaths = @(
        (Join-Path -Path $env:ProgramFiles -ChildPath "7-Zip\7z.exe"),
        (Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath "7-Zip\7z.exe")
    )
    foreach ($pathAttempt in $commonPaths) {
        if (Test-Path -LiteralPath $pathAttempt -PathType Leaf) {
            $sevenZipExe = $pathAttempt
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($sevenZipExe)) {
        try {
            $sevenZipExe = (Get-Command 7z.exe -ErrorAction SilentlyContinue).Source
        } catch {}
    }
}
if ([string]::IsNullOrWhiteSpace($sevenZipExe) -or -not (Test-Path -LiteralPath $sevenZipExe -PathType Leaf)) {
    Write-Error "7z.exe not found. Please install 7-Zip and ensure it's in your PATH, or provide the path using -SevenZipPath parameter."
    exit 1
}
Write-Host "Using 7-Zip: $sevenZipExe"

# --- Extract Version from PoSh-Backup.ps1 and Generate Meta\Version.psd1 ---
$mainScriptPath = Join-Path -Path $ProjectRoot -ChildPath "PoSh-Backup.ps1"
if (-not (Test-Path -LiteralPath $mainScriptPath -PathType Leaf)) {
    Write-Error "Main script 'PoSh-Backup.ps1' not found in ProjectRoot '$ProjectRoot'."
    exit 1
}
$mainScriptContent = Get-Content -LiteralPath $mainScriptPath -Raw
$extractedVersion = Get-ScriptVersionFromContentInternal -ScriptContent $mainScriptContent -ScriptNameForWarning "PoSh-Backup.ps1"

if ([string]::IsNullOrWhiteSpace($extractedVersion)) {
    Write-Error "Failed to extract version number from '$mainScriptPath'. Ensure 'Version: X.Y.Z' is present in the script's comment block."
    exit 1
}

$currentReleaseDateForFile = Get-Date -Format "yyyy-MM-dd"
$localVersionFilePath = Join-Path -Path $ProjectRoot -ChildPath "Meta\Version.psd1"

Write-Host "Auto-generating '$localVersionFilePath' with Version: $extractedVersion, Release Date: $currentReleaseDateForFile"

$versionFileData = @"
# PoSh-Backup\Meta\Version.psd1
#
# Stores metadata about the currently installed version of PoSh-Backup.
# This file is updated when a new version is installed or by the packager.
#
@{
    InstalledVersion = "$extractedVersion"    # Current version of PoSh-Backup.ps1
    ReleaseDate      = "$currentReleaseDateForFile" # Release date of this version (YYYY-MM-DD)
    ProjectUrl       = "https://github.com/BootBlock/PoSh-Backup" # Where PoSh Backup lives, innit.
    DistributionType = "Zip"        # How this version was likely distributed (e.g., "Zip", "GitClone")
                                    # This might inform future update strategies.
    UpdateStrategy   = "ReplaceFolder" # Default strategy the apply_update.ps1 might use. Temporary, unused.
}
"@

try {
    Set-Content -Path $localVersionFilePath -Value $versionFileData -Encoding UTF8 -Force -ErrorAction Stop
    Write-Host "'$localVersionFilePath' generated successfully." -ForegroundColor Green
} catch {
    Write-Error "Failed to write '$localVersionFilePath'. Error: $($_.Exception.Message)"
    exit 1
}

# --- Prepare for Packaging ---
$zipFileName = "PoSh-Backup-v$($extractedVersion).zip" # Use extracted version
$zipFileFullPath = Join-Path -Path $OutputDirectory -ChildPath $zipFileName

$tempExclusionFile = Join-Path -Path $OutputDirectory -ChildPath "temp_exclude_list.txt"

$exclusionPatterns = @(
    "Config\User*.psd1",       # Excludes User*.psd1 files within the Config folder
    "Logs\",                   # Exclude Logs directory and its contents
    "Reports\",                # Exclude Reports directory and its contents
    "_Backups\",               # Exclude _Backups directory and its contents
    "_UpdateTemp*\",           # Exclude folders starting with _UpdateTemp
    ".git\",                   # Exclude .git directory
    ".gitignore",              # Exclude the .gitignore file at the root.
    "*.bak",                   # Exclude all .bak files anywhere.
    "*.tmp",                   # Exclude all .tmp files anywhere.
    "*~",                      # Exclude all files ending with ~ anywhere.
    "Meta\Package-PoShBackupRelease.ps1",
    "Meta\*_manifest.psd1",
    $zipFileName               # Exclude the release distribution archive itself
)

# Add exclusion for the Releases folder if it's inside the ProjectRoot
if ($OutputDirectory.StartsWith($ProjectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    $releasesFolderName = Split-Path -Path $OutputDirectory -Leaf
    # Ensure this path is relative to ProjectRoot for the exclusion list
    $exclusionPatterns += "$($releasesFolderName)\"
}


$exclusionPatterns | Set-Content -Path $tempExclusionFile -Encoding UTF8
Write-Host "Temporary exclusion list created at '$tempExclusionFile'"

# --- Create ZIP Package ---
Write-Host "Creating ZIP package: $zipFileFullPath ..."
if (Test-Path -LiteralPath $zipFileFullPath) {
    Write-Warning "Output ZIP file '$zipFileFullPath' already exists. It will be overwritten."
    Remove-Item -LiteralPath $zipFileFullPath -Force
}

# $sevenZipArguments = @(
#     "a",
#     "-tzip",
#     "-mx=9",
#     "`"$zipFileFullPath`"",
#     "`"$($ProjectRoot)\*`"",
#     "-xr!`"$tempExclusionFile`""
# )

$sevenZipArguments = @(
    "a",
    "-tzip",
    "-mx=9",
    "-r", # Recursive
    "`"$zipFileFullPath`"",
    "`"$($ProjectRoot)\*`"", # Source
    "-xr@`"$tempExclusionFile`""
)

Write-Host "Running 7-Zip command: `"$sevenZipExe`" $($sevenZipArguments -join ' ')"
try {
    Start-Process -FilePath $sevenZipExe -ArgumentList $sevenZipArguments -Wait -NoNewWindow -ErrorAction Stop
    if (Test-Path -LiteralPath $zipFileFullPath) {
        Write-Host "Successfully created ZIP package: $zipFileFullPath" -ForegroundColor Green
    } else {
        throw "ZIP file was not created after 7-Zip process."
    }
} catch {
    Write-Error "Failed to create ZIP package. Error: $($_.Exception.Message)"
    Remove-Item -LiteralPath $tempExclusionFile -Force -ErrorAction SilentlyContinue
    exit 1
}

# --- Generate Checksum for ZIP ---
Write-Host "Generating SHA256 checksum for '$zipFileFullPath'..."
$zipFileHash = ""
try {
    $zipFileHash = (Get-FileHash -Path $zipFileFullPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
    Write-Host "SHA256 Checksum: $zipFileHash"
} catch {
    Write-Error "Failed to generate SHA256 checksum for ZIP file. Error: $($_.Exception.Message)"
    Remove-Item -LiteralPath $tempExclusionFile -Force -ErrorAction SilentlyContinue
    exit 1
}

# --- Generate version_manifest.psd1 ---
$manifestFilePath = Join-Path -Path $OutputDirectory -ChildPath "version_manifest.psd1"
Write-Host "Generating version manifest file: $manifestFilePath ..."

$releaseNotesUrl = $ReleaseNotesUrlTemplate -f $extractedVersion
$downloadUrl = $DownloadUrlTemplate -f $extractedVersion

$manifestData = @{
    LatestVersion   = $extractedVersion
    ReleaseDate     = $currentReleaseDateForFile # Use the date we set in Meta\Version.psd1
    ReleaseNotesUrl = $releaseNotesUrl
    DownloadUrl     = $downloadUrl
    SHA256Checksum  = $zipFileHash
    Severity        = $UpdateSeverity
    Message         = $UpdateMessage
}


# Prepare the message string carefully for PSD1 format
$escapedMessageForPsd1 = if (-not [string]::IsNullOrWhiteSpace($manifestData.Message)) {
    # For PSD1, strings should be single-quoted. If the message contains single quotes, they need to be doubled.
    "'" + ($manifestData.Message -replace "'", "''") + "'"
} else {
    "''" # Represent as an empty string literal in PSD1
}

$manifestContent = @"
# PoSh-Backup Remote Version Manifest
# Generated: $(Get-Date)
#
# This file provides information about the latest official release of PoSh-Backup.
# It is fetched by the -CheckForUpdate feature.
#
@{
    LatestVersion   = '$($manifestData.LatestVersion)'
    ReleaseDate     = '$($manifestData.ReleaseDate)'
    ReleaseNotesUrl = '$($manifestData.ReleaseNotesUrl)'
    DownloadUrl     = '$($manifestData.DownloadUrl)'
    SHA256Checksum  = '$($manifestData.SHA256Checksum)'
    Severity        = '$($manifestData.Severity)'
    Message         = $escapedMessageForPsd1 # Use the pre-formatted string
}
"@

# Using an expandable here-string with direct variable insertion for simplicity now.

try {
    Set-Content -Path $manifestFilePath -Value $manifestContent -Encoding UTF8 -Force -ErrorAction Stop
    Write-Host "Successfully generated version manifest: $manifestFilePath" -ForegroundColor Green
} catch {
    Write-Error "Failed to generate version manifest file. Error: $($_.Exception.Message)"
    Remove-Item -LiteralPath $tempExclusionFile -Force -ErrorAction SilentlyContinue
    exit 1
}

# --- Cleanup ---
Write-Host "Cleaning up temporary exclusion list file..."
Remove-Item -LiteralPath $tempExclusionFile -Force -ErrorAction SilentlyContinue

Write-Host "--- Packaging Complete ---" -ForegroundColor Yellow
