# PoSh-Backup\Meta\apply_update.ps1
# Standalone script to apply a PoSh-Backup update.
# This script is launched by Update.psm1 after downloading and backing up.
# It should have no dependencies on PoSh-Backup modules.
# The visual console output will be manually improved in a later version as AI/Gemini blows.
param(
    [Parameter(Mandatory=$true)][string]$DownloadedZipPath,
    [Parameter(Mandatory=$true)][string]$InstallPath,       # e.g., D:\Scripts\PoSh-Backup
    [Parameter(Mandatory=$true)][string]$BackupPath,        # e.g., D:\Scripts\PoSh-Backup_Backup_v1.14.6_20250531120000
    [Parameter(Mandatory=$false)][string]$UpdateLogPath = (Join-Path $InstallPath "Logs\PoSh-Backup-Update.log"),
    [Parameter(Mandatory=$false)][int]$MainPID = 0
)

function Write-UpdateLog {
    param ([string]$Message)
    $logLine = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
    try {
        Out-File -FilePath $UpdateLogPath -Append -InputObject $logLine -Encoding UTF8
    } catch {
        Write-Warning "Failed to write to update log: $UpdateLogPath. Error: $($_.Exception.Message)"
    }
    Write-Host $logLine # Also output to console for immediate feedback
}

# Ensure Logs directory exists for the update log itself
$GlobalUpdateLogDir = Split-Path -Path $UpdateLogPath -Parent
if (-not (Test-Path -Path $GlobalUpdateLogDir -PathType Container)) {
    try {
        New-Item -Path $GlobalUpdateLogDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "Failed to create directory for update log: $GlobalUpdateLogDir. Error: $($_.Exception.Message)"
        # Continue without file logging if directory creation fails, console logging will still occur.
        $UpdateLogPath = $null # Disable file logging
    }
}


Write-UpdateLog "--- PoSh-Backup Update Process Started ---"
Write-UpdateLog "Source ZIP: $DownloadedZipPath"
Write-UpdateLog "Install Path: $InstallPath"
Write-UpdateLog "Backup of Old Version Path: $BackupPath"
Write-UpdateLog "Update Log Path: $(if ($UpdateLogPath) {$UpdateLogPath} else {'Console Only'})"
Write-UpdateLog "Main PoSh-Backup PID (to wait for if > 0): $MainPID"

# Ensure the main PoSh-Backup process has exited
if ($MainPID -gt 0) {
    Write-UpdateLog "Waiting for main PoSh-Backup process (PID: $MainPID) to exit..."
    $mainProcess = Get-Process -Id $MainPID -ErrorAction SilentlyContinue
    if ($mainProcess) {
        if (-not (Wait-Process -Id $MainPID -Timeout 30 -ErrorAction SilentlyContinue)) {
            Write-UpdateLog "WARNING: Main PoSh-Backup process (PID: $MainPID) did not exit in 30 seconds. Proceeding with update, but this might cause issues if files are locked."
        } else {
            Write-UpdateLog "Main PoSh-Backup process (PID: $MainPID) has exited."
        }
    } else {
        Write-UpdateLog "Main PoSh-Backup process (PID: $MainPID) was not found. Assuming it has already exited."
    }
}

$ErrorEncountered = $false
$TempExtractDir = Join-Path -Path $InstallPath -ChildPath "_UpdateTemp_NewVersion"

try {
    # 1. Create/Clean temporary extraction directory
    Write-UpdateLog "Creating/Cleaning temporary extraction directory: $TempExtractDir"
    if (Test-Path $TempExtractDir) {
        Write-UpdateLog "INFO: Temporary extraction directory already exists. Removing it."
        Remove-Item -Path $TempExtractDir -Recurse -Force -ErrorAction Stop
    }
    New-Item -Path $TempExtractDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
    Write-UpdateLog "Temporary extraction directory created/cleaned."

    # 2. Extract the new version
    Write-UpdateLog "Extracting new version from '$DownloadedZipPath' to '$TempExtractDir'..."
    Expand-Archive -LiteralPath $DownloadedZipPath -DestinationPath $TempExtractDir -Force -ErrorAction Stop
    Write-UpdateLog "Extraction complete."

    # 3. Identify the root folder within the ZIP (e.g., PoSh-Backup-main or PoSh-Backup-1.15.0)
    $extractedItems = Get-ChildItem -Path $TempExtractDir
    $SourceDirInZip = ""
    if ($extractedItems.Count -eq 1 -and $extractedItems[0].PSIsContainer) {
        $SourceDirInZip = $extractedItems[0].FullName
        Write-UpdateLog "Identified single root folder in ZIP: '$($extractedItems[0].Name)'"
    } else {
        $SourceDirInZip = $TempExtractDir # Assume files are directly in TempExtractDir
        Write-UpdateLog "WARN: Could not identify a single root folder in ZIP, or multiple items found. Assuming new files are directly in '$TempExtractDir'."
    }
    Write-UpdateLog "Source directory for new files: $SourceDirInZip"

    # 4. PRESERVE USER CONFIGURATION (Temporary Backup of User's Config)
    $UserConfigBackupTemp = Join-Path -Path $InstallPath -ChildPath "_UpdateTemp_UserConfigBackupFromOldVersion"
    $OriginalConfigPathInOldVersionBackup = Join-Path -Path $BackupPath -ChildPath "Config" # Config dir from the *full backup*

    if (Test-Path -Path $OriginalConfigPathInOldVersionBackup -PathType Container) {
        Write-UpdateLog "Temporarily backing up user's 'Config' directory from '$OriginalConfigPathInOldVersionBackup' to '$UserConfigBackupTemp'..."
        if (Test-Path $UserConfigBackupTemp) {
            Remove-Item -Path $UserConfigBackupTemp -Recurse -Force -ErrorAction Stop
        }
        Copy-Item -Path $OriginalConfigPathInOldVersionBackup -Destination $UserConfigBackupTemp -Recurse -Force -ErrorAction Stop
        Write-UpdateLog "User's 'Config' directory temporarily backed up from old version's backup."
    } else {
        Write-UpdateLog "WARNING: Original 'Config' directory not found in the main backup at '$OriginalConfigPathInOldVersionBackup'. Cannot preserve user-specific config files if they existed."
    }

    # 5. Delete specific items from the main installation path ($InstallPath)
    #    This includes the entire old 'Config' folder, as the new one will be copied from the package,
    #    and then user files will be merged back.
    $itemsToDelete = @(
        "Modules", "Meta", "Config", # Key application folders, including Config
        "PoSh-Backup.ps1",
        "PSScriptAnalyzerSettings.psd1",
        "README.md",
        ".gitignore"
        # DO NOT add "Logs", "Reports", or the main backup folder (e.g., "_Backups")
    )
    Write-UpdateLog "Deleting old application files and folders (including 'Config') from '$InstallPath'..."
    foreach ($item in $itemsToDelete) {
        $itemPath = Join-Path -Path $InstallPath -ChildPath $item
        if (Test-Path -Path $itemPath) {
            Write-UpdateLog "  Deleting: $itemPath"
            Remove-Item -Path $itemPath -Recurse -Force -ErrorAction Stop
        } else {
            Write-UpdateLog "  INFO: Skipping deletion (item not found): $itemPath"
        }
    }

    # 6. Copy new files from $SourceDirInZip to $InstallPath
    #    This will copy the new 'Config' folder (with the new Default.psd1 and default themes)
    Write-UpdateLog "Copying new version files (including new 'Config' directory) from '$SourceDirInZip' to '$InstallPath'..."
    Get-ChildItem -Path $SourceDirInZip -Force | ForEach-Object {
        $destinationPath = Join-Path -Path $InstallPath -ChildPath $_.Name
        Write-UpdateLog "  Copying '$($_.FullName)' to '$destinationPath'"
        Copy-Item -Path $_.FullName -Destination $destinationPath -Recurse -Force -ErrorAction Stop
    }
    Write-UpdateLog "New version files copied."

    # 7. RESTORE USER-SPECIFIC CONFIGURATION ITEMS
    $NewInstallConfigPath = Join-Path -Path $InstallPath -ChildPath "Config" # Path to the Config dir from the new package

    if (Test-Path -Path $UserConfigBackupTemp -PathType Container) {
        Write-UpdateLog "Restoring user-specific configuration items from '$UserConfigBackupTemp' to '$NewInstallConfigPath'..."
        Write-UpdateLog "  (This will preserve user files like User.psd1, custom themes, etc., while keeping the new Default.psd1 from the update package)"

        Get-ChildItem -Path $UserConfigBackupTemp -Force | ForEach-Object {
            $itemFromUserBackup = $_
            if ($itemFromUserBackup.Name -eq "Default.psd1") {
                Write-UpdateLog "  Skipping 'Default.psd1' from user backup (the new version's Default.psd1 will be used)."
                continue # Skip Default.psd1 from user's backup
            }

            $destinationItemPath = Join-Path -Path $NewInstallConfigPath -ChildPath $itemFromUserBackup.Name
            Write-UpdateLog "  Restoring '$($itemFromUserBackup.Name)' from user backup to '$destinationItemPath'..."
            Copy-Item -Path $itemFromUserBackup.FullName -Destination $destinationItemPath -Recurse -Force -ErrorAction Stop
        }
        Write-UpdateLog "User-specific configuration items restored."
    } else {
        Write-UpdateLog "INFO: No temporary backup of user's old 'Config' directory found at '$UserConfigBackupTemp'. No user-specific config items to restore beyond what the new package provides."
    }

    Write-UpdateLog "Update process completed successfully!"
    Write-Host ""
    Write-Host "PoSh-Backup has been updated. Please review the update log for details:" -ForegroundColor Green
    if ($UpdateLogPath) { Write-Host $UpdateLogPath -ForegroundColor Green }
    Write-Host "It's recommended to restart your PowerShell session before running the new version." -ForegroundColor Yellow

} catch {
    $ErrorEncountered = $true
    Write-UpdateLog "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-UpdateLog "ERROR during update process: $($_.Exception.Message)"
    Write-UpdateLog "ScriptStackTrace: $($_.ScriptStackTrace)"
    Write-UpdateLog "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-UpdateLog "The update failed. Your original version was backed up to: $BackupPath"
    Write-UpdateLog "You may need to manually restore it or re-download PoSh-Backup."

    Write-Host ""
    Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
    Write-Host "PoSh-Backup UPDATE FAILED!" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Your original version was backed up to: $BackupPath" -ForegroundColor Yellow
    if ($UpdateLogPath) { Write-Host "Please review the update log for details: $UpdateLogPath" -ForegroundColor Yellow }
    Write-Host "You may need to manually restore your previous version from the backup." -ForegroundColor Yellow
    Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
} finally {
    # 8. Cleanup temporary files
    Write-UpdateLog "Cleaning up temporary files..."
    if (Test-Path $TempExtractDir) {
        Write-UpdateLog "  Deleting temporary extraction directory: $TempExtractDir"
        Remove-Item -Path $TempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $UserConfigBackupTemp) {
        Write-UpdateLog "  Deleting temporary user config backup from old version: $UserConfigBackupTemp"
        Remove-Item -Path $UserConfigBackupTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not $ErrorEncountered) { # Only delete the downloaded ZIP if the update was successful
        if (Test-Path $DownloadedZipPath) {
            Write-UpdateLog "  Deleting downloaded update package: $DownloadedZipPath"
            Remove-Item -Path $DownloadedZipPath -Force -ErrorAction SilentlyContinue
        }
    } else {
        if (Test-Path $DownloadedZipPath) { # Check again, as it might not exist if download failed
            Write-UpdateLog "INFO: Downloaded update package '$DownloadedZipPath' was NOT deleted due to an error during the update process."
        }
    }
    Write-UpdateLog "Cleanup complete."
    Write-UpdateLog "--- PoSh-Backup Update Process Finished ---"
}
