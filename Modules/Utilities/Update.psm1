# PoSh-Backup\Modules\Utilities\Update.psm1
<#
.SYNOPSIS
    Handles checking for PoSh-Backup updates and orchestrates the automated update process.
    This module now acts as a facade for its sub-modules, loading them on demand.
.DESCRIPTION
    This module provides functionality to:
    1. Check a remote manifest file for the latest available version of PoSh-Backup.
    2. Compare the installed version with the latest available version.
    3. If an update is available and the user confirms, it orchestrates the update process by
       lazy-loading and calling specialised sub-modules to handle downloading, verification,
       and backing up the current installation.
    4. Finally, it launches the standalone 'apply_update.ps1' script to perform the update.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Refactored to lazy-load sub-modules.
    DateCreated:    31-May-2025
    LastModified:   02-Jul-2025
    Purpose:        Update checking and initiation logic for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Requires Meta\Version.psd1 to exist locally.
                    Network access to fetch the remote version manifest and update package.
#>

# No eager module imports are needed here. They will be lazy-loaded.

#region --- Private Module-Scoped Variables ---
$script:RemoteVersionManifestUrl = "https://raw.githubusercontent.com/BootBlock/PoSh-Backup/main/Releases/version_manifest.psd1"
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

    # --- 1. Read Local Version Information ---
    $localVersionInfo = $null
    $localVersionFilePathAbsolute = Join-Path -Path $PSScriptRootForPaths -ChildPath "Meta\Version.psd1"
    if (-not (Test-Path -LiteralPath $localVersionFilePathAbsolute -PathType Leaf)) {
        & $LocalWriteLog -Message "[ERROR] Update Facade: Local version file not found at '$localVersionFilePathAbsolute'. Cannot check for updates." -Level "ERROR"
        return
    }
    try {
        $localVersionInfo = Import-PowerShellDataFile -LiteralPath $localVersionFilePathAbsolute -ErrorAction Stop
    } catch {
        & $LocalWriteLog -Message "[ERROR] Update Facade: Failed to read or parse local version file '$localVersionFilePathAbsolute'. Error: $($_.Exception.Message)" -Level "ERROR"
        return
    }

    # --- 2. Fetch Remote Version Manifest ---
    $remoteManifest = $null
    try {
        $response = Invoke-WebRequest -Uri $script:RemoteVersionManifestUrl -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        $scriptBlock = $ExecutionContext.InvokeCommand.NewScriptBlock($response.Content)
        $remoteManifest = Invoke-Command -ScriptBlock $scriptBlock
        if (-not ($remoteManifest -is [hashtable])) { throw "Remote manifest is malformed." }
    } catch {
        & $LocalWriteLog -Message "[ERROR] Update Facade: Failed to fetch or parse remote version manifest. Error: $($_.Exception.Message)" -Level "ERROR"
        return
    }

    # --- 3. Version Comparison & User Interaction ---
    $installedVersion = [version]$localVersionInfo.InstalledVersion
    $latestVersion = [version]$remoteManifest.LatestVersion

    if ($latestVersion -le $installedVersion) {
        Write-Host
        Write-Host "  Your installed version " -NoNewline -ForegroundColor DarkGray
        Write-Host $installedVersion -NoNewline -ForegroundColor Green
        Write-Host " is current or newer than the latest official release of " -NoNewline -ForegroundColor DarkGray
        Write-Host $latestVersion -NoNewline -ForegroundColor Red
        Write-Host "." -ForegroundColor DarkGray
        Write-Host
        return
    }

    Write-Host "An update is available! Version $latestVersion (Severity: $($remoteManifest.Severity))." -ForegroundColor Green
    Write-NameValue "Release Notes" $remoteManifest.ReleaseNotesUrl

    $choice = $Host.UI.PromptForChoice("Update Available", "Would you like to download and apply this update now?", ("&Yes","&No"), 1)

    if ($choice -ne 0) {
        & $LocalWriteLog -Message "Update declined by user." -Level "INFO"
        return
    }

    # --- 4. Orchestrate Update Process via Sub-Modules ---
    $tempDirForDownload = Join-Path -Path $env:TEMP -ChildPath "PoShBackupUpdate_$(Get-Random)"
    New-Item -Path $tempDirForDownload -ItemType Directory -Force | Out-Null

    try {
        if (-not $PSCmdletInstance.ShouldProcess("PoSh-Backup Installation (Current: $installedVersion, Target: $latestVersion)", "Download, Backup Current, and Launch Update Installer")) {
            & $LocalWriteLog -Message "Update process aborted by user confirmation (ShouldProcess)." -Level "INFO"
            Write-Host "Update process aborted by user." -ForegroundColor Yellow
            return
        }

        # 4a. Download
        $downloadResult = try {
            Import-Module -Name (Join-Path $PSScriptRootForPaths "Modules\Utilities\Update\Downloader.psm1") -Force -ErrorAction Stop
            Invoke-UpdatePackageDownload -DownloadUrl $remoteManifest.DownloadUrl -TempDirectory $tempDirForDownload -Logger $Logger
        } catch { throw "Could not load or execute the Downloader module. Error: $($_.Exception.Message)" }
        if (-not $downloadResult.Success) { throw $downloadResult.ErrorMessage }
        $tempZipPath = $downloadResult.DownloadedFilePath

        # 4b. Verify
        $verifyResult = try {
            Import-Module -Name (Join-Path $PSScriptRootForPaths "Modules\Utilities\Update\Verifier.psm1") -Force -ErrorAction Stop
            Invoke-UpdatePackageVerification -FilePath $tempZipPath -ExpectedChecksum $remoteManifest.SHA256Checksum -Logger $Logger
        } catch { throw "Could not load or execute the Verifier module. Error: $($_.Exception.Message)" }
        if (-not $verifyResult.Success) { throw $verifyResult.ErrorMessage }

        # 4c. Backup
        $backupResult = try {
            Import-Module -Name (Join-Path $PSScriptRootForPaths "Modules\Utilities\Update\BackupHandler.psm1") -Force -ErrorAction Stop
            Invoke-CurrentInstallationBackup -SourcePath $PSScriptRootForPaths -InstalledVersion $installedVersion -Logger $Logger
        } catch { throw "Could not load or execute the BackupHandler module. Error: $($_.Exception.Message)" }
        if (-not $backupResult.Success) { throw $backupResult.ErrorMessage }
        $backupFullPath = $backupResult.BackupPath

        # 4d. Launch apply_update.ps1
        $applyUpdateScriptFullPath = Join-Path -Path $PSScriptRootForPaths -ChildPath "Meta\apply_update.ps1"
        if (-not (Test-Path -LiteralPath $applyUpdateScriptFullPath -PathType Leaf)) {
            throw "Update helper script (apply_update.ps1) not found at '$applyUpdateScriptFullPath'. Cannot proceed with update."
        }

        $updateLogForApplyScript = Join-Path -Path $PSScriptRootForPaths -ChildPath "Logs\PoSh-Backup-Update_$(Get-Date -Format 'yyyyMMddHHmmss').log"
        $currentPID = $PID
        $arguments = @("-NoProfile","-ExecutionPolicy","Bypass","-File","`"$applyUpdateScriptFullPath`"","-DownloadedZipPath","`"$tempZipPath`"","-InstallPath","`"$PSScriptRootForPaths`"","-BackupPath","`"$backupFullPath`"","-UpdateLogPath","`"$updateLogForApplyScript`"","-MainPID",$currentPID)

        & $LocalWriteLog -Message "Update Facade: Launching apply_update.ps1..." -Level "INFO"
        Write-Host "Launching update process... PoSh-Backup will now exit." -ForegroundColor Cyan

        try { Start-Process powershell.exe -ArgumentList $arguments -Verb RunAs -ErrorAction Stop }
        catch {
            & $LocalWriteLog -Message "[ERROR] Failed to launch apply_update.ps1 with elevation. Error: $($_.Exception.Message). Attempting without elevation..." -Level "ERROR"
            try { Start-Process powershell.exe -ArgumentList $arguments -ErrorAction Stop }
            catch { throw ("Failed to launch the update helper script even without elevation. Please apply the update manually from '$tempZipPath'. Your current version is backed up at: $backupFullPath. Error: $($_.Exception.Message)") }
        }

        $Host.SetShouldExit(0)

    } catch {
        $advice = "ADVICE: This could be due to a network issue, disk space problem, or a missing sub-module in 'Modules\Utilities\Update'."
        & $LocalWriteLog -Message "[ERROR] Update process failed: $($_.Exception.Message)" -Level "ERROR"
        & $LocalWriteLog -Message $advice -Level "ADVICE"
        Write-Host "[ERROR] Update process failed: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        if (Test-Path -LiteralPath $tempDirForDownload -PathType Container) { Remove-Item -Recurse -Force -LiteralPath $tempDirForDownload -ErrorAction SilentlyContinue }
    }
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupUpdateCheckAndApply
