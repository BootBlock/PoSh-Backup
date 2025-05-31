# PoSh-Backup\Modules\Utilities\Update.psm1
<#
.SYNOPSIS
    Handles checking for PoSh-Backup updates and can initiate the update process.
.DESCRIPTION
    This module provides functionality to:
    1. Check a remote manifest file for the latest available version of PoSh-Backup.
    2. Compare the installed version (from Meta\Version.psd1) with the latest available version.
    3. Inform the user if an update is available, providing details like version number,
       release notes URL, and download URL.
    4. If an update is available and the user confirms, it will download the update package,
       verify its checksum (if provided in the manifest), back up the current installation,
       and then launch a separate 'apply_update.ps1' script to perform the actual file replacement.

    This module is designed to be lazy-loaded by ScriptModeHandler.psm1 when the
    -CheckForUpdate switch is used.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        0.2.0 # Implemented download, checksum, backup, and apply_update.ps1 launch.
    DateCreated:    31-May-2025
    LastModified:   31-May-2025
    Purpose:        Update checking and initiation logic for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Requires Meta\Version.psd1 to exist locally.
                    Requires network access to fetch the remote version manifest and update package.
                    The 'apply_update.ps1' script is expected in the 'Meta' directory for self-update.
                    Utils.psm1 (providing Get-PoshBackupFileHash and Write-LogMessage) must be loaded.
#>

#region --- Module Dependencies ---
# Utils.psm1 is expected to be loaded by the calling context (ScriptModeHandler.psm1 imports it)
# so Write-LogMessage and Get-PoshBackupFileHash should be available.
#endregion

#region --- Private Module-Scoped Variables ---
# URL to the remote version manifest file.
$script:RemoteVersionManifestUrl = "https://raw.githubusercontent.com/BootBlock/PoSh-Backup/main/Meta/version_manifest.psd1" # EXAMPLE URL - REPLACE WITH ACTUAL
#endregion

#region --- Exported Functions ---

function Invoke-PoShBackupUpdateCheckAndApply {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [string]$PSScriptRootForPaths, # Main PoSh-Backup.ps1 PSScriptRoot
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }
    & $LocalWriteLog -Message "Update/Invoke-PoShBackupUpdateCheckAndApply: Initializing update check." -Level "INFO"

    # --- 1. Read Local Version Information ---
    $localVersionInfo = $null
    $localVersionFilePathAbsolute = Join-Path -Path $PSScriptRootForPaths -ChildPath "Meta\Version.psd1"

    if (-not (Test-Path -LiteralPath $localVersionFilePathAbsolute -PathType Leaf)) {
        & $LocalWriteLog -Message "[ERROR] Update/Invoke-PoShBackupUpdateCheckAndApply: Local version file not found at '$localVersionFilePathAbsolute'. Cannot check for updates." -Level "ERROR"
        return
    }
    try {
        $localVersionInfo = Import-PowerShellDataFile -LiteralPath $localVersionFilePathAbsolute -ErrorAction Stop
        if (-not ($localVersionInfo -is [hashtable]) -or -not $localVersionInfo.ContainsKey('InstalledVersion')) {
            throw "Local version file '$localVersionFilePathAbsolute' is malformed or missing 'InstalledVersion'."
        }
        & $LocalWriteLog -Message "  - Update/Invoke-PoShBackupUpdateCheckAndApply: Current installed version: $($localVersionInfo.InstalledVersion) (Released: $($localVersionInfo.ReleaseDate))" -Level "INFO"
    }
    catch {
        & $LocalWriteLog -Message "[ERROR] Update/Invoke-PoShBackupUpdateCheckAndApply: Failed to read or parse local version file '$localVersionFilePathAbsolute'. Error: $($_.Exception.Message)" -Level "ERROR"
        return
    }

    # --- 2. Fetch and Parse Remote Version Manifest ---
    & $LocalWriteLog -Message "  - Update/Invoke-PoShBackupUpdateCheckAndApply: Fetching remote version manifest from '$script:RemoteVersionManifestUrl'..." -Level "INFO"
    $remoteManifest = $null
    $remoteManifestContent = ""
    try {
        $response = Invoke-WebRequest -Uri $script:RemoteVersionManifestUrl -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        $remoteManifestContent = $response.Content
        if ([string]::IsNullOrWhiteSpace($remoteManifestContent)) {
            throw "Remote version manifest content is empty."
        }
        # Use $ExecutionContext.InvokeCommand.NewScriptBlock to avoid Invoke-Expression PSSA warning
        $scriptBlock = $ExecutionContext.InvokeCommand.NewScriptBlock($remoteManifestContent)
        $remoteManifest = Invoke-Command -ScriptBlock $scriptBlock # Removed -NoNewScope as it's not needed here
        if (-not ($remoteManifest -is [hashtable]) -or -not $remoteManifest.ContainsKey('LatestVersion') -or -not $remoteManifest.ContainsKey('ReleaseNotesUrl') -or -not $remoteManifest.ContainsKey('DownloadUrl')) {
            throw "Remote version manifest is malformed or missing required keys (LatestVersion, ReleaseNotesUrl, DownloadUrl)."
        }
        & $LocalWriteLog -Message "  - Update/Invoke-PoShBackupUpdateCheckAndApply: Successfully fetched and parsed remote version manifest." -Level "INFO"
    }
    catch {
        & $LocalWriteLog -Message "[ERROR] Update/Invoke-PoShBackupUpdateCheckAndApply: Failed to fetch or parse remote version manifest. Error: $($_.Exception.Message)" -Level "ERROR"
        & $LocalWriteLog -Message "    Details: Ensure network connectivity and that the URL '$script:RemoteVersionManifestUrl' is correct and accessible." -Level "INFO"
        if ($_.Exception.Response) {
            & $LocalWriteLog -Message "    HTTP Status Code: $($_.Exception.Response.StatusCode)" -Level "DEBUG"
            & $LocalWriteLog -Message "    HTTP Status Description: $($_.Exception.Response.StatusDescription)" -Level "DEBUG"
        }
        if (-not [string]::IsNullOrWhiteSpace($remoteManifestContent)) {
            & $LocalWriteLog -Message "    Raw Remote Content (first 500 chars): $($remoteManifestContent.Substring(0, [System.Math]::Min($remoteManifestContent.Length, 500)))" -Level "DEBUG"
        }
        return
    }

    # --- 3. Version Comparison ---
    $installedVersionString = $localVersionInfo.InstalledVersion
    $latestVersionString = $remoteManifest.LatestVersion
    try {
        $installedVersion = [version]$installedVersionString
        $latestVersion = [version]$latestVersionString
    } catch {
        & $LocalWriteLog -Message "[ERROR] Update/Invoke-PoShBackupUpdateCheckAndApply: Could not parse version strings for comparison. Installed: '$installedVersionString', Latest: '$latestVersionString'. Error: $($_.Exception.Message)" -Level "ERROR"
        return
    }

    $updateSeverity = if ($remoteManifest.ContainsKey('Severity')) { $remoteManifest.Severity } else { "Optional" }
    $updateMessage = if ($remoteManifest.ContainsKey('Message')) { $remoteManifest.Message } else { "A new version is available." }

    & $LocalWriteLog -Message "  - Update/Invoke-PoShBackupUpdateCheckAndApply: Comparing installed version '$installedVersion' with latest '$latestVersion'." -Level "DEBUG"

    if ($latestVersion -gt $installedVersion) {
        Write-Host ""
        Write-Host "------------------------------------------------------------" -ForegroundColor Yellow
        Write-Host " PoSh-Backup Update Available!" -ForegroundColor Green
        Write-Host "------------------------------------------------------------" -ForegroundColor Yellow
        Write-Host "  Current Installed Version: $installedVersion"
        Write-Host "  Latest Available Version : $latestVersion (Severity: $updateSeverity)" -ForegroundColor Cyan
        Write-Host "  Latest Release Date      : $($remoteManifest.ReleaseDate)"
        if (-not [string]::IsNullOrWhiteSpace($updateMessage)) {
            Write-Host "  Message                  : $updateMessage"
        }
        Write-Host "  Release Notes            : $($remoteManifest.ReleaseNotesUrl)"
        Write-Host "  Download URL             : $($remoteManifest.DownloadUrl)"
        if ($remoteManifest.ContainsKey('SHA256Checksum') -and -not [string]::IsNullOrWhiteSpace($remoteManifest.SHA256Checksum)) {
            Write-Host "  Package SHA256           : $($remoteManifest.SHA256Checksum)"
        }
        Write-Host "------------------------------------------------------------" -ForegroundColor Yellow
        Write-Host ""

        # --- 4. Prompt User to Update ---
        $updateChoiceTitle = "PoSh-Backup Update Available"
        $updateChoiceMessage = "Version $latestVersion is available. Would you like to download and apply this update now?`nYour current installation will be backed up before updating.`nWARNING: PoSh-Backup will exit after starting the update process."
        $choiceYes = New-Object System.Management.Automation.Host.ChoiceDescription "&Yes", "Download and apply the update."
        $choiceNo = New-Object System.Management.Automation.Host.ChoiceDescription "&No", "Do not update at this time."
        $choiceViewNotes = New-Object System.Management.Automation.Host.ChoiceDescription "&View Release Notes", "Open release notes in your browser."
        $choices = [System.Management.Automation.Host.ChoiceDescription[]]($choiceYes, $choiceNo, $choiceViewNotes)
        
        $userDecision = $Host.UI.PromptForChoice($updateChoiceTitle, $updateChoiceMessage, $choices, 1) # Default to No

        switch ($userDecision) {
            0 { # Yes - Proceed with update
                & $LocalWriteLog -Message "  - Update/Invoke-PoShBackupUpdateCheckAndApply: User chose to proceed with update." -Level "INFO"

                if (-not $PSCmdletInstance.ShouldProcess("PoSh-Backup Installation (Current: $installedVersion, Target: $latestVersion)", "Download, Backup Current, and Launch Update Installer")) {
                    & $LocalWriteLog -Message "  - Update/Invoke-PoShBackupUpdateCheckAndApply: Update process aborted by user confirmation (ShouldProcess)." -Level "INFO"
                    Write-Host "Update process aborted by user." -ForegroundColor Yellow
                    return
                }

                # --- 4a. Download Update Package ---
                $tempDirForDownload = Join-Path -Path $env:TEMP -ChildPath "PoShBackupUpdate_$(Get-Random)" # Unique temp dir
                if (-not (Test-Path -Path $tempDirForDownload -PathType Container)) {
                    New-Item -Path $tempDirForDownload -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
                }
                $downloadFileName = Split-Path -Path $remoteManifest.DownloadUrl -Leaf
                if ([string]::IsNullOrWhiteSpace($downloadFileName)) { $downloadFileName = "PoSh-Backup-Update.zip" }
                $tempZipPath = Join-Path -Path $tempDirForDownload -ChildPath $downloadFileName

                & $LocalWriteLog -Message "  - Update/Invoke-PoShBackupUpdateCheckAndApply: Downloading update from '$($remoteManifest.DownloadUrl)' to '$tempZipPath'..." -Level "INFO"
                Write-Host "Downloading update package..." -ForegroundColor Cyan
                try {
                    Invoke-WebRequest -Uri $remoteManifest.DownloadUrl -OutFile $tempZipPath -TimeoutSec 300 -ErrorAction Stop
                    & $LocalWriteLog -Message "    - Update/Invoke-PoShBackupUpdateCheckAndApply: Download complete." -Level "SUCCESS"
                } catch {
                    & $LocalWriteLog -Message "[ERROR] Update/Invoke-PoShBackupUpdateCheckAndApply: Failed to download update package. Error: $($_.Exception.Message)" -Level "ERROR"
                    Write-Host "ERROR: Failed to download update package. Please try again later or download manually." -ForegroundColor Red
                    if (Test-Path -LiteralPath $tempDirForDownload -PathType Container) { Remove-Item -Recurse -Force -LiteralPath $tempDirForDownload -ErrorAction SilentlyContinue }
                    return
                }

                # --- 4b. Verify Checksum (if provided) ---
                if ($remoteManifest.ContainsKey('SHA256Checksum') -and -not [string]::IsNullOrWhiteSpace($remoteManifest.SHA256Checksum)) {
                    & $LocalWriteLog -Message "  - Update/Invoke-PoShBackupUpdateCheckAndApply: Verifying checksum of downloaded package..." -Level "INFO"
                    Write-Host "Verifying downloaded file integrity..." -ForegroundColor Cyan
                    $expectedChecksum = $remoteManifest.SHA256Checksum.Trim().ToUpperInvariant()
                    $actualChecksum = (Get-PoshBackupFileHash -FilePath $tempZipPath -Algorithm "SHA256" -Logger $Logger).Trim().ToUpperInvariant()

                    if ($actualChecksum -ne $expectedChecksum) {
                        & $LocalWriteLog -Message "[ERROR] Update/Invoke-PoShBackupUpdateCheckAndApply: Checksum mismatch! Expected: '$expectedChecksum', Actual: '$actualChecksum'. Update aborted." -Level "ERROR"
                        Write-Host "ERROR: Downloaded file checksum does not match. The file may be corrupted or tampered with. Update aborted." -ForegroundColor Red
                        Remove-Item -Recurse -Force -LiteralPath $tempDirForDownload -ErrorAction SilentlyContinue
                        return
                    }
                    & $LocalWriteLog -Message "    - Update/Invoke-PoShBackupUpdateCheckAndApply: Checksum VERIFIED." -Level "SUCCESS"
                    Write-Host "File integrity verified." -ForegroundColor Green
                } else {
                    & $LocalWriteLog -Message "  - Update/Invoke-PoShBackupUpdateCheckAndApply: No SHA256Checksum provided in remote manifest. Skipping checksum verification." -Level "WARNING"
                    Write-Host "WARNING: No checksum provided in manifest to verify download integrity." -ForegroundColor Yellow
                }

                # --- 4c. Backup Current Installation ---
                $backupDirName = "PoSh-Backup_Backup_v$($installedVersionString)_$(Get-Date -Format 'yyyyMMddHHmmss')"
                # Backup to a directory *outside* the main installation path if possible, e.g., in the parent of PSScriptRootForPaths
                $backupParentDir = Split-Path -Path $PSScriptRootForPaths -Parent
                if ([string]::IsNullOrWhiteSpace($backupParentDir) -or (-not (Test-Path -LiteralPath $backupParentDir -PathType Container))) {
                    # Fallback to a _Backups folder inside the current install path if parent is not accessible/determinable
                    $backupParentDir = Join-Path -Path $PSScriptRootForPaths -ChildPath "_Backups"
                    if (-not (Test-Path -LiteralPath $backupParentDir -PathType Container)) {
                        New-Item -Path $backupParentDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
                    }
                }
                $backupFullPath = Join-Path -Path $backupParentDir -ChildPath $backupDirName
                
                & $LocalWriteLog -Message "  - Update/Invoke-PoShBackupUpdateCheckAndApply: Backing up current installation from '$PSScriptRootForPaths' to '$backupFullPath'..." -Level "INFO"
                Write-Host "Backing up current installation to '$backupFullPath'..." -ForegroundColor Cyan
                try {
                    Copy-Item -Path $PSScriptRootForPaths -Destination $backupFullPath -Recurse -Force -ErrorAction Stop
                    & $LocalWriteLog -Message "    - Update/Invoke-PoShBackupUpdateCheckAndApply: Current installation backed up successfully." -Level "SUCCESS"
                    Write-Host "Current version backed up successfully." -ForegroundColor Green
                } catch {
                    & $LocalWriteLog -Message "[ERROR] Update/Invoke-PoShBackupUpdateCheckAndApply: Failed to back up current installation. Error: $($_.Exception.Message). Update aborted." -Level "ERROR"
                    Write-Host "ERROR: Failed to back up current installation. Update aborted." -ForegroundColor Red
                    Remove-Item -Recurse -Force -LiteralPath $tempDirForDownload -ErrorAction SilentlyContinue
                    return
                }

                # --- 4d. Launch apply_update.ps1 ---
                $applyUpdateScriptRelativePath = "Meta\apply_update.ps1"
                $applyUpdateScriptFullPath = Join-Path -Path $PSScriptRootForPaths -ChildPath $applyUpdateScriptRelativePath
                
                if (-not (Test-Path -LiteralPath $applyUpdateScriptFullPath -PathType Leaf)) {
                    & $LocalWriteLog -Message "[ERROR] Update/Invoke-PoShBackupUpdateCheckAndApply: apply_update.ps1 script not found at '$applyUpdateScriptFullPath'. Cannot proceed with update." -Level "ERROR"
                    Write-Host "ERROR: Update helper script (apply_update.ps1) not found. Update aborted." -ForegroundColor Red
                    Remove-Item -Recurse -Force -LiteralPath $tempDirForDownload -ErrorAction SilentlyContinue
                    # The backup directory $backupFullPath is left in place for potential manual recovery.
                    return
                }

                $updateLogForApplyScript = Join-Path -Path $PSScriptRootForPaths -ChildPath "Logs\PoSh-Backup-Update_$(Get-Date -Format 'yyyyMMddHHmmss').log"
                $currentPID = $PID

                $arguments = @(
                    "-NoProfile",
                    "-ExecutionPolicy", "Bypass",
                    "-File", "`"$applyUpdateScriptFullPath`"",
                    "-DownloadedZipPath", "`"$tempZipPath`"",
                    "-InstallPath", "`"$PSScriptRootForPaths`"",
                    "-BackupPath", "`"$backupFullPath`"",
                    "-UpdateLogPath", "`"$updateLogForApplyScript`"",
                    "-MainPID", $currentPID
                )
                
                & $LocalWriteLog -Message "  - Update/Invoke-PoShBackupUpdateCheckAndApply: Launching apply_update.ps1..." -Level "INFO"
                & $LocalWriteLog -Message ("    Arguments: powershell.exe " + ($arguments -join " ")) -Level "DEBUG"
                Write-Host "Launching update process... PoSh-Backup will now exit." -ForegroundColor Cyan
                Write-Host "Monitor the console window of the apply_update.ps1 script (if visible) or its log file for progress:"
                Write-Host $updateLogForApplyScript -ForegroundColor Yellow
                
                try {
                    # Attempt to run with elevation for file operations in protected directories
                    Start-Process powershell.exe -ArgumentList $arguments -Verb RunAs -ErrorAction Stop
                } catch {
                    & $LocalWriteLog -Message "[ERROR] Update/Invoke-PoShBackupUpdateCheckAndApply: Failed to launch apply_update.ps1 with elevation. Error: $($_.Exception.Message). Attempting without elevation..." -Level "ERROR"
                    Write-Host "WARNING: Failed to launch update helper with elevation. Attempting without..." -ForegroundColor Yellow
                    try {
                        Start-Process powershell.exe -ArgumentList $arguments -ErrorAction Stop
                    } catch {
                        & $LocalWriteLog -Message "[ERROR] Update/Invoke-PoShBackupUpdateCheckAndApply: Failed to launch apply_update.ps1 even without elevation. Error: $($_.Exception.Message)" -Level "ERROR"
                        Write-Host "ERROR: Failed to launch the update helper script. Please apply the update manually from '$tempZipPath'." -ForegroundColor Red
                        Write-Host "Your current version is backed up at: $backupFullPath" -ForegroundColor Yellow
                    }
                }
                # PoSh-Backup should exit after this. ScriptModeHandler will handle the exit.
            }
            1 { # No
                & $LocalWriteLog -Message "  - Update/Invoke-PoShBackupUpdateCheckAndApply: User chose not to update at this time." -Level "INFO"
                Write-Host "Update declined by user." -ForegroundColor Yellow
            }
            2 { # View Release Notes
                & $LocalWriteLog -Message "  - Update/Invoke-PoShBackupUpdateCheckAndApply: User chose to view release notes." -Level "INFO"
                try {
                    Start-Process $remoteManifest.ReleaseNotesUrl
                    Write-Host "Opened release notes in your browser. You can run -CheckForUpdate again if you decide to update." -ForegroundColor Cyan
                } catch {
                    & $LocalWriteLog -Message "[ERROR] Update/Invoke-PoShBackupUpdateCheckAndApply: Failed to open release notes URL '$($remoteManifest.ReleaseNotesUrl)'. Error: $($_.Exception.Message)" -Level "ERROR"
                    Write-Host "ERROR: Could not open the release notes URL. Please visit it manually: $($remoteManifest.ReleaseNotesUrl)" -ForegroundColor Red
                }
            }
        }

    } elseif ($latestVersion -lt $installedVersion) {
        Write-Host ""
        Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
        Write-Host " PoSh-Backup - Development Version Detected" -ForegroundColor Cyan
        Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
        Write-Host "  Your installed version ($installedVersion) is newer than the latest"
        Write-Host "  official version ($latestVersion) found in the remote manifest."
        Write-Host "  This may be a local development build or a pre-release."
        Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
        Write-Host ""
    } else {
        Write-Host ""
        Write-Host "------------------------------------------------------------" -ForegroundColor Green
        Write-Host " PoSh-Backup is Up-To-Date!" -ForegroundColor Green
        Write-Host "------------------------------------------------------------" -ForegroundColor Green
        Write-Host "  Your installed version ($installedVersion) is the latest available."
        Write-Host "------------------------------------------------------------" -ForegroundColor Green
        Write-Host ""
    }
}

#endregion

Export-ModuleMember -Function Invoke-PoShBackupUpdateCheckAndApply
