# Modules\ScriptModeHandler.psm1
<#
.SYNOPSIS
    Handles informational and utility script modes for PoSh-Backup, such as listing
    or extracting archive contents, managing pins, testing the configuration, or
    managing the maintenance mode flag file.
.DESCRIPTION
    This module provides a function, Invoke-PoShBackupScriptMode, which checks if PoSh-Backup
    was invoked with a non-backup parameter like -ListArchiveContents, -ExtractFromArchive,
    -PinBackup, -TestConfig, -RunVerificationJobs, -GetEffectiveConfig, -ExportDiagnosticPackage, or -Maintenance.
    If one of these modes is active, this module takes over, performs the requested action,
    and then exits the script. This keeps the main PoSh-Backup.psm1 script cleaner by
    offloading this mode-specific logic. The -TestConfig mode now also resolves and displays
    the effective post-run system action. The -ExportDiagnosticPackage mode now includes
    disk space, configuration diff, and permissions reports.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.12.0 # Added Disk, Config Diff, and ACL reports to Diagnostic Package.
    DateCreated:    24-May-2025
    LastModified:   14-Jun-2025
    Purpose:        To handle informational and utility script execution modes for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Requires a logger function passed via the -Logger parameter.
                    Requires various Manager and Core modules for specific modes.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\
try {
    Import-Module -Name (Join-Path $PSScriptRoot "Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Managers\PinManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Managers\PasswordManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Managers\7ZipManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Core\ConfigManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Core\PostRunActionOrchestrator.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Warning "ScriptModeHandler.psm1: Could not import a manager module. Specific modes may be unavailable. Error: $($_.Exception.Message)"
}
#endregion

#region --- Private Helper: Export Diagnostic Package ---
function Invoke-ExportDiagnosticPackageInternal {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        [Parameter(Mandatory = $true)]
        [string]$PSScriptRoot,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )
    & $Logger -Message "ScriptModeHandler/Invoke-ExportDiagnosticPackageInternal: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    & $LocalWriteLog -Message "`n--- Exporting Diagnostic Package ---" -Level "HEADING"

    if (-not $PSCmdlet.ShouldProcess($OutputPath, "Create Diagnostic Package")) {
        & $LocalWriteLog -Message "Diagnostic package creation skipped by user." -Level "WARNING"
        return
    }

    $tempDir = Join-Path -Path $env:TEMP -ChildPath "PoShBackup_Diag_$(Get-Random)"
    try {
        & $LocalWriteLog -Message "  - Creating temporary directory: '$tempDir'" -Level "INFO"
        New-Item -Path $tempDir -ItemType Directory -Force -ErrorAction Stop | Out-Null

        # --- 1. Gather System Information ---
        & $LocalWriteLog -Message "  - Gathering system information..." -Level "INFO"
        $systemInfo = [System.Text.StringBuilder]::new()
        $null = $systemInfo.AppendLine("PoSh-Backup Diagnostic Information")
        $null = $systemInfo.AppendLine("Generated on: $(Get-Date -Format 'o')")
        $null = $systemInfo.AppendLine(("-"*40))

        $mainScriptVersion = Get-ScriptVersionFromContent -ScriptContent (Get-Content (Join-Path $PSScriptRoot "PoSh-Backup.ps1") -Raw)
        $null = $systemInfo.AppendLine("PoSh-Backup Version: $mainScriptVersion")
        $null = $systemInfo.AppendLine("PowerShell Version : $($PSVersionTable.PSVersion)")
        $null = $systemInfo.AppendLine("OS Version         : $((Get-CimInstance Win32_OperatingSystem).Caption)")
        $null = $systemInfo.AppendLine("Culture            : $((Get-Culture).Name)")
        $null = $systemInfo.AppendLine("Execution Policy   : $(Get-ExecutionPolicy)")
        $null = $systemInfo.AppendLine("Admin Rights       : $(Test-AdminPrivilege -Logger $Logger)")
        $null = $systemInfo.AppendLine(("-"*40))

        # 7-Zip Info
        $sevenZipPathForDiag = Find-SevenZipExecutable -Logger $Logger
        if ($sevenZipPathForDiag) {
            $sevenZipVersionInfo = (& $sevenZipPathForDiag | Select-Object -First 2) -join " "
            $null = $systemInfo.AppendLine("7-Zip Path    : $sevenZipPathForDiag")
            $null = $systemInfo.AppendLine("7-Zip Version : $sevenZipVersionInfo")
        } else {
            $null = $systemInfo.AppendLine("7-Zip Info    : <not found or configured>")
        }
        $null = $systemInfo.AppendLine(("-"*40))

        # External Module Info
        $null = $systemInfo.AppendLine("External PowerShell Module Status:")
        $poshSshModule = Get-Module -Name Posh-SSH -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
        $secretMgmtModule = Get-Module -Name Microsoft.PowerShell.SecretManagement -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
        $null = $systemInfo.AppendLine(" - Posh-SSH: $(if($poshSshModule){"v$($poshSshModule.Version) found at $($poshSshModule.Path)"}else{'<not found>'})")
        $null = $systemInfo.AppendLine(" - SecretManagement: $(if($secretMgmtModule){"v$($secretMgmtModule.Version) found"}else{'<not found>'})")
        try {
            $vaults = Get-SecretVault -ErrorAction SilentlyContinue
            if ($vaults) {
                $vaults | ForEach-Object { $null = $systemInfo.AppendLine("   - Vault Found: Name '$($_.Name)', Module '$($_.ModuleName)', Default: $($_.DefaultVault)") }
            } else {
                $null = $systemInfo.AppendLine("   - Vaults: No secret vaults found or registered.")
            }
        } catch { $null = $systemInfo.AppendLine("   - Vaults: Error checking for vaults: $($_.Exception.Message)") }

        $null = $systemInfo.AppendLine(("-"*40))

        # Internal Module Info
        $null = $systemInfo.AppendLine("PoSh-Backup Project File Versions:")
        $rootUri = [uri]($PSScriptRoot + [System.IO.Path]::DirectorySeparatorChar)
        Get-ChildItem -Path $PSScriptRoot -Include "*.psm1", "*.ps1" -Recurse -Exclude "Tests\*" | Sort-Object FullName | ForEach-Object {
            $file = $_
            $fileContentForVersion = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
            $version = Get-ScriptVersionFromContent -ScriptContent $fileContentForVersion -ScriptNameForWarning $file.Name
            $fileUri = [uri]$file.FullName
            $relativePathUri = $rootUri.MakeRelativeUri($fileUri)
            $relativePath = [uri]::UnescapeDataString($relativePathUri.ToString()).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            $versionString = if ($version -eq "N/A" -or $version -like "N/A (*") { "<no version>" } else { "v$version" }
            $null = $systemInfo.AppendLine(" - $($relativePath.PadRight(75)) $versionString")
        }

        # --- NEW: Disk Space Report ---
        $null = $systemInfo.AppendLine(("-"*40))
        $null = $systemInfo.AppendLine("Disk Space Report:")
        try {
            Get-PSDrive -PSProvider FileSystem | ForEach-Object {
                if ($_.Root -match "^[A-Z]:\\$") { # Only check fixed local drives
                    $drive = $_
                    $totalSizeGB = [math]::Round(($drive.Used + $drive.Free) / 1GB, 2)
                    $freeSpaceGB = [math]::Round($drive.Free / 1GB, 2)
                    $percentFree = if ($totalSizeGB -gt 0) { [math]::Round(($freeSpaceGB / $totalSizeGB) * 100, 2) } else { 0 }
                    $null = $systemInfo.AppendLine(" - Drive $($drive.Name): Total: $($totalSizeGB) GB, Free: $($freeSpaceGB) GB ($($percentFree)%)")
                }
            }
        } catch { $null = $systemInfo.AppendLine(" - Error gathering disk space information: $($_.Exception.Message)") }
        # --- END NEW ---

        $systemInfo.ToString() | Set-Content -Path (Join-Path $tempDir "SystemInfo.txt") -Encoding UTF8

        # --- 2. Copy and Sanitise Configuration Files ---
        & $LocalWriteLog -Message "  - Copying and sanitising configuration files..." -Level "INFO"
        $configDir = Join-Path -Path $tempDir -ChildPath "Config"
        New-Item -Path $configDir -ItemType Directory -Force | Out-Null
        $defaultConfigPath = Join-Path -Path $PSScriptRoot -ChildPath "Config\Default.psd1"
        $userConfigPath = Join-Path -Path $PSScriptRoot -ChildPath "Config\User.psd1"
        $pssaSettingsPath = Join-Path -Path $PSScriptRoot -ChildPath "PSScriptAnalyzerSettings.psd1"

        # --- NEW: Configuration Diff ---
        if ((Test-Path $defaultConfigPath) -and (Test-Path $userConfigPath)) {
            & $LocalWriteLog -Message "    - Generating configuration diff..." -Level "DEBUG"
            try {
                # A simple text-based diff is sufficient and safe
                $diffOutput = Compare-Object -ReferenceObject (Get-Content $defaultConfigPath) -DifferenceObject (Get-Content $userConfigPath) | Format-List | Out-String
                if ([string]::IsNullOrWhiteSpace($diffOutput)) { $diffOutput = "No differences found between Default.psd1 and User.psd1." }
                else { $diffOutput = "Differences between Default.psd1 (<=) and User.psd1 (=>):`n`n" + $diffOutput }
                $diffOutput | Set-Content -Path (Join-Path $configDir "UserConfig.diff.txt") -Encoding UTF8
            } catch {
                "Error generating config diff: $($_.Exception.Message)" | Set-Content -Path (Join-Path $configDir "UserConfig.diff.txt") -Encoding UTF8
            }
        }
        # --- END NEW ---

        $configFilesToCopy = @{ ($defaultConfigPath) = "Default.psd1"; ($userConfigPath) = "User.psd1"; ($pssaSettingsPath) = "PSScriptAnalyzerSettings.psd1" }
        $sensitiveKeyPatterns = @('Password', 'SecretName', 'Credential', 'WebhookUrl')

        foreach ($sourcePath in $configFilesToCopy.Keys) {
            if (Test-Path -LiteralPath $sourcePath) {
                $destFileName = $configFilesToCopy[$sourcePath]
                $destPath = Join-Path -Path $configDir -ChildPath $destFileName
                Copy-Item -LiteralPath $sourcePath -Destination $destPath

                $content = Get-Content -LiteralPath $destPath -Raw
                foreach ($pattern in $sensitiveKeyPatterns) {
                    $regex = "(?im)^(\s*${pattern}\s*=\s*)['""](.*?)['""]"
                    $replacement = "`$1'<REDACTED_VALUE_FOR_${pattern}_$(Get-Random -Minimum 1000 -Maximum 9999)>'"
                    $content = $content -replace $regex, $replacement
                }
                $content | Set-Content -LiteralPath $destPath -Encoding UTF8
                & $LocalWriteLog -Message "    - Copied and sanitised '$destFileName'." -Level "DEBUG"
            }
        }

        # --- 3. Gather Recent Logs ---
        & $LocalWriteLog -Message "  - Gathering recent log files..." -Level "INFO"
        $logSourceDir = Join-Path -Path $PSScriptRoot -ChildPath "Logs"
        $logDestDir = Join-Path -Path $tempDir -ChildPath "Logs"
        if (Test-Path -LiteralPath $logSourceDir) {
            New-Item -Path $logDestDir -ItemType Directory -Force | Out-Null
            Get-ChildItem -Path $logSourceDir -Filter "*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 10 | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination $logDestDir
            }
            & $LocalWriteLog -Message "    - Copied up to 10 most recent log files." -Level "DEBUG"
        }

        # --- NEW: Permissions/ACLs Report ---
        & $LocalWriteLog -Message "  - Gathering permissions report..." -Level "INFO"
        $aclReport = [System.Text.StringBuilder]::new()
        $pathsToAclCheck = @(
            $PSScriptRoot,
            (Join-Path $PSScriptRoot "Config"),
            (Join-Path $PSScriptRoot "Modules"),
            (Join-Path $PSScriptRoot "Logs"),
            (Join-Path $PSScriptRoot "Reports")
        )
        # Add destination directories from config
        try {
            $configForAcl = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot "Config\Default.psd1")
            if (Test-Path (Join-Path $PSScriptRoot "Config\User.psd1")) {
                $userConfigForAcl = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot "Config\User.psd1")
                # Simple merge for this purpose
                $userConfigForAcl.GetEnumerator() | ForEach-Object { $configForAcl[$_.Name] = $_.Value }
            }
            if ($configForAcl.DefaultDestinationDir) { $pathsToAclCheck += $configForAcl.DefaultDestinationDir }
            if ($configForAcl.BackupLocations) { $configForAcl.BackupLocations.Values | ForEach-Object { if ($_.DestinationDir) { $pathsToAclCheck += $_.DestinationDir } } }
        } catch {
            & $LocalWriteLog -Message "[ERROR] ScriptModeHandler: Failed to import Config\Default.psd1 (or User.psd1, dunno!). Error: $($_.Exception.Message)" -Level "ERROR"
        }

        foreach ($path in ($pathsToAclCheck | Select-Object -Unique)) {
            $null = $aclReport.AppendLine(("="*60))
            $null = $aclReport.AppendLine("ACL for: $path")
            $null = $aclReport.AppendLine(("="*60))
            if (Test-Path -LiteralPath $path) {
                try {
                    $aclOutput = (Get-Acl -LiteralPath $path | Format-List | Out-String).Trim()
                    $null = $aclReport.AppendLine($aclOutput)
                } catch {
                    $null = $aclReport.AppendLine("ERROR retrieving ACL: $($_.Exception.Message)")
                }
            } else {
                $null = $aclReport.AppendLine("Path does not exist.")
            }
            $null = $aclReport.AppendLine()
        }
        $aclReport.ToString() | Set-Content -Path (Join-Path $tempDir "Permissions.acl.txt") -Encoding UTF8
        # --- END NEW ---

        # --- 4. Create ZIP Package ---
        & $LocalWriteLog -Message "  - Compressing diagnostic files to '$OutputPath'..." -Level "INFO"
        Compress-Archive -Path "$tempDir\*" -DestinationPath $OutputPath -Force -ErrorAction Stop
        & $LocalWriteLog -Message "  - Diagnostic package created successfully." -Level "SUCCESS"

    } catch {
        & $LocalWriteLog -Message "[ERROR] Failed to create diagnostic package. Error: $($_.Exception.Message)" -Level "ERROR"
    } finally {
        # --- 5. Cleanup ---
        if (Test-Path -LiteralPath $tempDir) {
            & $LocalWriteLog -Message "  - Cleaning up temporary directory..." -Level "DEBUG"
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
#endregion

#region --- Exported Function: Invoke-PoShBackupScriptMode ---
function Invoke-PoShBackupScriptMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$ListBackupLocationsSwitch,
        [Parameter(Mandatory = $true)]
        [bool]$ListBackupSetsSwitch,
        [Parameter(Mandatory = $true)]
        [bool]$TestConfigSwitch,
        [Parameter(Mandatory = $true)]
        [bool]$RunVerificationJobsSwitch,
        [Parameter(Mandatory = $true)]
        [bool]$CheckForUpdateSwitch,
        [Parameter(Mandatory = $true)]
        [bool]$VersionSwitch,
        [Parameter(Mandatory = $false)]
        [string]$GetEffectiveConfigJobName,
        [Parameter(Mandatory = $true)]
        [hashtable]$CliOverrideSettingsInternal,
        [Parameter(Mandatory = $false)]
        [string]$ExportDiagnosticPackagePath,
        [Parameter(Mandatory = $false)]
        [Nullable[bool]]$MaintenanceSwitchValue,
        [Parameter(Mandatory = $false)]
        [string]$PinBackupPath,
        [Parameter(Mandatory = $false)]
        [string]$UnpinBackupPath,
        [Parameter(Mandatory = $false)]
        [string]$ListArchiveContentsPath,
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSScriptAnalyzer", "PSAvoidUsingPlainTextForPassword")]
        [Parameter(Mandatory = $false)]
        [string]$ArchivePasswordSecretName,
        [Parameter(Mandatory = $false)]
        [string]$ExtractFromArchivePath,
        [Parameter(Mandatory = $false)]
        [string]$ExtractToDirectoryPath,
        [Parameter(Mandatory = $false)]
        [string[]]$ItemsToExtract,
        [Parameter(Mandatory = $false)]
        [bool]$ForceExtract,
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,
        [Parameter(Mandatory = $true)]
        [string]$ActualConfigFile,
        [Parameter(Mandatory = $true)]
        [hashtable]$ConfigLoadResult,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCmdlet]$PSCmdletForUpdateCheck
    )

    # PSSA Appeasement: Directly use the Logger parameter once.
    & $Logger -Message "ScriptModeHandler/Invoke-PoShBackupScriptMode: Initializing." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ExportDiagnosticPackagePath)) {
        Invoke-ExportDiagnosticPackageInternal -OutputPath $ExportDiagnosticPackagePath `
            -PSScriptRoot $Configuration['_PoShBackup_PSScriptRoot'] `
            -Logger $Logger
        exit 0
    }

    if (-not [string]::IsNullOrWhiteSpace($GetEffectiveConfigJobName)) {
        & $LocalWriteLog -Message "`n--- Get Effective Job Configuration Mode ---" -Level "HEADING"
        if (-not $Configuration.BackupLocations.ContainsKey($GetEffectiveConfigJobName)) {
            & $LocalWriteLog -Message "  - ERROR: The specified job name '$GetEffectiveConfigJobName' was not found in the configuration." -Level "ERROR"
            exit 1
        }
        try {
            & $LocalWriteLog -Message "  - Resolving effective configuration for job: '$GetEffectiveConfigJobName'..." -Level "INFO"
            $jobConfigForReport = $Configuration.BackupLocations[$GetEffectiveConfigJobName]
            $dummyReportDataRef = [ref]@{ JobName = $GetEffectiveConfigJobName }

            $effectiveConfigParams = @{
                JobConfig                  = $jobConfigForReport
                GlobalConfig               = $Configuration
                CliOverrides               = $CliOverrideSettingsInternal
                JobReportDataRef           = $dummyReportDataRef
                Logger                     = $Logger
            }
            $effectiveConfigResult = Get-PoShBackupJobEffectiveConfiguration @effectiveConfigParams

            & $LocalWriteLog -Message "`n--- Effective Configuration for Job: '$GetEffectiveConfigJobName' ---`n" -Level "NONE"
            $effectiveConfigResult | Format-List | Out-String | ForEach-Object { & $LocalWriteLog -Message $_ -Level "NONE" }
            & $LocalWriteLog -Message "`n--- End of Effective Configuration ---" -Level "NONE"

        } catch {
            & $LocalWriteLog -Message "[FATAL] ScriptModeHandler: An error occurred while resolving the effective configuration for job '$GetEffectiveConfigJobName'. Error: $($_.Exception.Message)" -Level "ERROR"
            exit 1
        }
        exit 0
    }

    if ($RunVerificationJobsSwitch) {
        & $LocalWriteLog -Message "`n--- Automated Backup Verification Mode ---" -Level "HEADING"
        $verificationManagerPath = Join-Path -Path $PSScriptRoot -ChildPath "Managers\VerificationManager.psm1"
        try {
            if (-not (Test-Path -LiteralPath $verificationManagerPath -PathType Leaf)) {
                throw "VerificationManager.psm1 not found at '$verificationManagerPath'."
            }
            Import-Module -Name $verificationManagerPath -Force -ErrorAction Stop
            if (-not (Get-Command Invoke-PoShBackupVerification -ErrorAction SilentlyContinue)) {
                throw "Could not find the Invoke-PoShBackupVerification command after importing the module."
            }

            $verificationParams = @{
                Configuration = $Configuration
                Logger        = $Logger
                PSCmdlet      = $PSCmdletForUpdateCheck # Re-use the passed PSCmdlet object
            }
            Invoke-PoShBackupVerification @verificationParams

        } catch {
            & $LocalWriteLog -Message "[FATAL] ScriptModeHandler: Error during -RunVerificationJobs mode. Error: $($_.Exception.Message)" -Level "ERROR"
            exit 14 # Specific exit code for verification mode failure
        }
        & $LocalWriteLog -Message "`n--- Verification Run Finished ---" -Level "HEADING"
        exit 0 # Exit after running verification jobs
    }

    if ($PSBoundParameters.ContainsKey('MaintenanceSwitchValue')) {
        & $LocalWriteLog -Message "`n--- Maintenance Mode Management ---" -Level "HEADING"
        $maintenanceFilePathFromConfig = Get-ConfigValue -ConfigObject $Configuration -Key 'MaintenanceModeFilePath' -DefaultValue '.\.maintenance'
        $maintenanceFileFullPath = $maintenanceFilePathFromConfig
        $scriptRootPath = $Configuration['_PoShBackup_PSScriptRoot']

        if (-not [System.IO.Path]::IsPathRooted($maintenanceFilePathFromConfig)) {
            if ([string]::IsNullOrWhiteSpace($scriptRootPath)) {
                & $LocalWriteLog -Message "  - FAILED to resolve maintenance file path. Script root path is unknown." -Level "ERROR"
                exit 1
            }
            $maintenanceFileFullPath = Join-Path -Path $scriptRootPath -ChildPath $maintenanceFilePathFromConfig
        }

        if ($MaintenanceSwitchValue -eq $true) {
            & $LocalWriteLog -Message "ScriptModeHandler: Enabling maintenance mode by creating flag file: '$maintenanceFileFullPath'" -Level "INFO"
            if (Test-Path -LiteralPath $maintenanceFileFullPath -PathType Leaf) {
                & $LocalWriteLog -Message "  - Maintenance mode is already enabled (flag file exists)." -Level "INFO"
            } else {
                try {
                    $maintenanceFileContent = @"
#
# PoSh-Backup Maintenance Mode Flag File
#
# This file's existence  places  PoSh-Backup into maintenance mode.
# While this file exists, no new backup jobs will be started unless
# forced to via the '-ForceRunInMaintenanceMode' switch.
#
# To disable maintenance mode,  either  delete  this  file manually,
# or run:
#          .\PoSh-Backup.ps1 -Maintenance `$false
#
# Enabled On: $(Get-Date -Format 'o')
# Enabled By: $($env:USERDOMAIN)\$($env:USERNAME) on $($env:COMPUTERNAME)
#
"@
                    Set-Content -Path $maintenanceFileFullPath -Value $maintenanceFileContent -Encoding UTF8 -Force -ErrorAction Stop
                    & $LocalWriteLog -Message "  - Maintenance mode has been ENABLED." -Level "SUCCESS"
                } catch {
                    & $LocalWriteLog -Message "  - FAILED to create maintenance flag file. Error: $($_.Exception.Message)" -Level "ERROR"
                }
            }
        } else { # -Maintenance $false
            & $LocalWriteLog -Message "ScriptModeHandler: Disabling maintenance mode by removing flag file: '$maintenanceFileFullPath'" -Level "INFO"
            if (Test-Path -LiteralPath $maintenanceFileFullPath -PathType Leaf) {
                try {
                    Remove-Item -LiteralPath $maintenanceFileFullPath -Force -ErrorAction Stop
                    & $LocalWriteLog -Message "  - Maintenance mode has been DISABLED." -Level "SUCCESS"
                } catch {
                    & $LocalWriteLog -Message "  - FAILED to remove maintenance flag file. Error: $($_.Exception.Message)" -Level "ERROR"
                }
            } else {
                & $LocalWriteLog -Message "  - Maintenance mode is already disabled (flag file does not exist)." -Level "INFO"
            }
        }
        exit 0
    }

    if (-not [string]::IsNullOrWhiteSpace($ExtractFromArchivePath)) {
        & $LocalWriteLog -Message "`n--- Extract Archive Contents Mode ---" -Level "HEADING"
        if (-not (Get-Command Invoke-7ZipExtraction -ErrorAction SilentlyContinue)) {
            & $LocalWriteLog -Message "FATAL: Could not find the Invoke-7ZipExtraction command. Ensure 'Modules\Managers\7ZipManager\Extractor.psm1' is present and loaded correctly." -Level "ERROR"
            exit 15
        }
        if ([string]::IsNullOrWhiteSpace($ExtractToDirectoryPath)) {
            & $LocalWriteLog -Message "FATAL: The -ExtractToDirectory parameter is required when using -ExtractFromArchive." -Level "ERROR"
            exit 16
        }

        $plainTextPasswordForExtract = $null
        if (-not [string]::IsNullOrWhiteSpace($ArchivePasswordSecretName)) {
            if (-not (Get-Command Get-PoShBackupArchivePassword -ErrorAction SilentlyContinue)) {
                & $LocalWriteLog -Message "FATAL: Could not find Get-PoShBackupArchivePassword command. Cannot retrieve password for encrypted archive." -Level "ERROR"
                exit 15
            }
            $passwordConfig = @{ ArchivePasswordMethod = 'SecretManagement'; ArchivePasswordSecretName = $ArchivePasswordSecretName }
            $passwordResult = Get-PoShBackupArchivePassword -JobConfigForPassword $passwordConfig -JobName "Archive Extraction" -Logger $Logger
            $plainTextPasswordForExtract = $passwordResult.PlainTextPassword
        }

        $sevenZipPath = $Configuration.SevenZipPath
        $extractParams = @{
            SevenZipPathExe  = $sevenZipPath
            ArchivePath      = $ExtractFromArchivePath
            OutputDirectory  = $ExtractToDirectoryPath
            PlainTextPassword = $plainTextPasswordForExtract
            Force            = [bool]$ForceExtract
            Logger           = $Logger
            PSCmdlet         = $PSCmdletForUpdateCheck # Re-use the passed PSCmdlet for ShouldProcess
        }
        if ($null -ne $ItemsToExtract -and $ItemsToExtract.Count -gt 0) {
            $extractParams.FilesToExtract = $ItemsToExtract
        }

        $success = Invoke-7ZipExtraction @extractParams

        if ($success) {
            & $LocalWriteLog -Message "Successfully extracted archive '$ExtractFromArchivePath' to '$ExtractToDirectoryPath'." -Level "SUCCESS"
        } else {
            & $LocalWriteLog -Message "Failed to extract archive '$ExtractFromArchivePath'. Check previous errors." -Level "ERROR"
        }
        exit 0
    }

    if (-not [string]::IsNullOrWhiteSpace($ListArchiveContentsPath)) {
        & $LocalWriteLog -Message "`n--- List Archive Contents Mode ---" -Level "HEADING"
        if (-not (Get-Command Get-7ZipArchiveListing -ErrorAction SilentlyContinue)) {
            & $LocalWriteLog -Message "FATAL: Could not find the Get-7ZipArchiveListing command. Ensure 'Modules\Managers\7ZipManager\Lister.psm1' is present and loaded correctly." -Level "ERROR"
            exit 15
        }

        $plainTextPasswordForList = $null
        if (-not [string]::IsNullOrWhiteSpace($ArchivePasswordSecretName)) {
            if (-not (Get-Command Get-PoShBackupArchivePassword -ErrorAction SilentlyContinue)) {
                & $LocalWriteLog -Message "FATAL: Could not find Get-PoShBackupArchivePassword command. Cannot retrieve password for encrypted archive." -Level "ERROR"
                exit 15
            }
            $passwordConfig = @{ ArchivePasswordMethod = 'SecretManagement'; ArchivePasswordSecretName = $ArchivePasswordSecretName }
            $passwordResult = Get-PoShBackupArchivePassword -JobConfigForPassword $passwordConfig -JobName "Archive Listing" -Logger $Logger
            $plainTextPasswordForList = $passwordResult.PlainTextPassword
        }

        $sevenZipPath = $Configuration.SevenZipPath
        $listing = Get-7ZipArchiveListing -SevenZipPathExe $sevenZipPath -ArchivePath $ListArchiveContentsPath -PlainTextPassword $plainTextPasswordForList -Logger $Logger

        if ($null -ne $listing) {
            & $LocalWriteLog -Message "Contents of archive: $ListArchiveContentsPath" -Level "INFO"
            $listing | Format-Table -AutoSize
            & $LocalWriteLog -Message "Found $($listing.Count) files/folders." -Level "SUCCESS"
        } else {
            & $LocalWriteLog -Message "Failed to list contents for archive: $ListArchiveContentsPath. Check previous errors." -Level "ERROR"
        }
        exit 0
    }

    if (-not [string]::IsNullOrWhiteSpace($PinBackupPath)) {
        & $LocalWriteLog -Message "`n--- Pin Backup Archive Mode ---" -Level "HEADING"
        if (Get-Command Add-PoShBackupPin -ErrorAction SilentlyContinue) {
            Add-PoShBackupPin -Path $PinBackupPath -Logger $Logger
        } else {
            & $LocalWriteLog -Message "FATAL: Could not find the Add-PoShBackupPin command. Ensure 'Modules\Managers\PinManager.psm1' is present and loaded correctly." -Level "ERROR"
        }
        exit 0
    }

    if (-not [string]::IsNullOrWhiteSpace($UnpinBackupPath)) {
        & $LocalWriteLog -Message "`n--- Unpin Backup Archive Mode ---" -Level "HEADING"
        if (Get-Command Remove-PoShBackupPin -ErrorAction SilentlyContinue) {
            Remove-PoShBackupPin -Path $UnpinBackupPath -Logger $Logger
        } else {
            & $LocalWriteLog -Message "FATAL: Could not find the Remove-PoShBackupPin command. Ensure 'Modules\Managers\PinManager.psm1' is present and loaded correctly." -Level "ERROR"
        }
        exit 0
    }

    if ($VersionSwitch) {
        $mainScriptPathForVersion = Join-Path -Path $Configuration['_PoShBackup_PSScriptRoot'] -ChildPath "PoSh-Backup.ps1"
        $scriptVersion = "N/A"
        if (Test-Path -LiteralPath $mainScriptPathForVersion -PathType Leaf) {
            $mainScriptContent = Get-Content -LiteralPath $mainScriptPathForVersion -Raw -ErrorAction SilentlyContinue
            $regexMatch = [regex]::Match($mainScriptContent, '(?im)^\s*Version:\s*([0-9]+\.[0-9]+(?:\.[0-9]+){0,2}(?:\.[0-9]+)?)\b')
            if ($regexMatch.Success) {
                $scriptVersion = $regexMatch.Groups[1].Value.Trim()
            }
        }
        Write-Host "PoSh-Backup Version: $scriptVersion"
        exit 0
    }

    if ($CheckForUpdateSwitch) {
        & $LocalWriteLog -Message "`n--- Checking for PoSh-Backup Updates ---" -Level "HEADING"
        $updateModulePath = Join-Path -Path $PSScriptRoot -ChildPath "Utilities\Update.psm1" # Relative to ScriptModeHandler.psm1

        if (-not (Test-Path -LiteralPath $updateModulePath -PathType Leaf)) {
            & $LocalWriteLog -Message "[ERROR] ScriptModeHandler: Update module (Update.psm1) not found at '$updateModulePath'. Cannot check for updates." -Level "ERROR"
            exit 50 # Specific exit code for missing update module
        }
        try {
            Import-Module -Name $updateModulePath -Force -ErrorAction Stop
            $updateCheckParams = @{
                Logger                 = $Logger
                PSScriptRootForPaths   = $Configuration['_PoShBackup_PSScriptRoot']
                PSCmdletInstance       = $PSCmdletForUpdateCheck
            }
            Invoke-PoShBackupUpdateCheckAndApply @updateCheckParams
        }
        catch {
            & $LocalWriteLog -Message "[ERROR] ScriptModeHandler: Failed to load or execute the Update module. Error: $($_.Exception.Message)" -Level "ERROR"
            & $LocalWriteLog -Message "  Please ensure 'Modules\Utilities\Update.psm1' exists and is valid." -Level "ERROR"
        }
        & $LocalWriteLog -Message "`n--- Update Check Finished ---" -Level "HEADING"
        exit 0 # Exit after checking for updates
    }

    if ($ListBackupLocationsSwitch) {
        & $LocalWriteLog -Message "`n--- Defined Backup Locations (Jobs) from '$($ActualConfigFile)' ---" -Level "HEADING"
        if ($ConfigLoadResult.UserConfigLoaded) {
            & $LocalWriteLog -Message "    (Includes overrides from '$($ConfigLoadResult.UserConfigPath)')" -Level "INFO"
        }
        if ($Configuration.BackupLocations -is [hashtable] -and $Configuration.BackupLocations.Count -gt 0) {
            $Configuration.BackupLocations.GetEnumerator() | Sort-Object Name | ForEach-Object {
                $jobConf = $_.Value
                $jobName = $_.Name

                $isEnabled = Get-ConfigValue -ConfigObject $jobConf -Key 'Enabled' -DefaultValue $true
                $jobNameColor = if ($isEnabled) { $Global:ColourSuccess } else { $Global:ColourError }
                & $LocalWriteLog -Message ("`n  Job Name      : " + $jobName) -Level "NONE" -ForegroundColour $jobNameColor

                & $LocalWriteLog -Message ("  Enabled       : " + $isEnabled) -Level "NONE"

                if ($jobConf.Path -is [array]) {
                    if ($jobConf.Path.Count -gt 0) {
                        & $LocalWriteLog -Message ('  Source Path(s): "{0}"' -f $jobConf.Path[0]) -Level "NONE"
                        if ($jobConf.Path.Count -gt 1) {
                            $jobConf.Path | Select-Object -Skip 1 | ForEach-Object {
                                & $LocalWriteLog -Message ('                  "{0}"' -f $_) -Level "NONE"
                            }
                        }
                    } else {
                        & $LocalWriteLog -Message ("  Source Path(s): (None specified)") -Level "NONE"
                    }
                } else {
                    & $LocalWriteLog -Message ('  Source Path(s): "{0}"' -f $jobConf.Path) -Level "NONE"
                }

                $archiveNameDisplay = Get-ConfigValue -ConfigObject $jobConf -Key 'Name' -DefaultValue 'N/A (Uses Job Name)'
                & $LocalWriteLog -Message ("  Archive Name  : " + $archiveNameDisplay) -Level "NONE"

                $destDirDisplay = Get-ConfigValue -ConfigObject $jobConf -Key 'DestinationDir' -DefaultValue (Get-ConfigValue -ConfigObject $Configuration -Key 'DefaultDestinationDir' -DefaultValue 'N/A')
                & $LocalWriteLog -Message ("  Destination   : " + $destDirDisplay) -Level "NONE"

                $targetNames = @(Get-ConfigValue -ConfigObject $jobConf -Key 'TargetNames' -DefaultValue @())
                if ($targetNames.Count -gt 0) {
                    & $LocalWriteLog -Message ("  Remote Targets: " + ($targetNames -join ", ")) -Level "NONE"
                }

                $dependsOn = @(Get-ConfigValue -ConfigObject $jobConf -Key 'DependsOnJobs' -DefaultValue @())
                if ($dependsOn.Count -gt 0) {
                    & $LocalWriteLog -Message ("  Depends On    : " + ($dependsOn -join ", ")) -Level "NONE"
                }

                $scheduleConf = Get-ConfigValue -ConfigObject $jobConf -Key 'Schedule' -DefaultValue $null
                $scheduleDisplay = "Disabled"
                if ($null -ne $scheduleConf -and $scheduleConf -is [hashtable]) {
                    $scheduleEnabled = Get-ConfigValue -ConfigObject $scheduleConf -Key 'Enabled' -DefaultValue $false
                    if ($scheduleEnabled) {
                        $scheduleType = Get-ConfigValue -ConfigObject $scheduleConf -Key 'Type' -DefaultValue "N/A"
                        $scheduleTime = Get-ConfigValue -ConfigObject $scheduleConf -Key 'Time' -DefaultValue ""
                        $scheduleDisplay = "Enabled ($scheduleType"
                        if (-not [string]::IsNullOrWhiteSpace($scheduleTime)) {
                            $scheduleDisplay += " at $scheduleTime"
                        }
                        $scheduleDisplay += ")"
                    }
                }
                & $LocalWriteLog -Message ("  Schedule      : " + $scheduleDisplay) -Level "NONE"
            }
        } else {
            & $LocalWriteLog -Message "No Backup Locations are defined in the configuration." -Level "WARNING"
        }
        & $LocalWriteLog -Message "`n--- Listing Complete ---" -Level "HEADING"
        exit 0 # Exit after listing
    }

    if ($ListBackupSetsSwitch) {
        & $LocalWriteLog -Message "`n--- Defined Backup Sets from '$($ActualConfigFile)' ---" -Level "HEADING"
        if ($ConfigLoadResult.UserConfigLoaded) {
            & $LocalWriteLog -Message "    (Includes overrides from '$($ConfigLoadResult.UserConfigPath)')" -Level "INFO"
        }
        if ($Configuration.BackupSets -is [hashtable] -and $Configuration.BackupSets.Count -gt 0) {
            $Configuration.BackupSets.GetEnumerator() | Sort-Object Name | ForEach-Object {
                $setConf = $_.Value
                $setName = $_.Name
                & $LocalWriteLog -Message ("`n  Set Name     : " + $setName) -Level "NONE"

                $onErrorDisplay = Get-ConfigValue -ConfigObject $setConf -Key 'OnErrorInJob' -DefaultValue 'StopSet'
                & $LocalWriteLog -Message ("  On Error     : " + $onErrorDisplay) -Level "NONE"

                $jobsInSet = @(Get-ConfigValue -ConfigObject $setConf -Key 'JobNames' -DefaultValue @())
                if ($jobsInSet.Count -gt 0) {
                    $firstJobName = $jobsInSet[0]
                    $firstJobColor = $Global:ColourInfo # Default color
                    $firstJobDisplayName = $firstJobName
                    if ($Configuration.BackupLocations.ContainsKey($firstJobName)) {
                        $firstJobConf = $Configuration.BackupLocations[$firstJobName]
                        $isFirstJobEnabled = Get-ConfigValue -ConfigObject $firstJobConf -Key 'Enabled' -DefaultValue $true
                        $firstJobColor = if ($isFirstJobEnabled) { $Global:ColourSuccess } else { $Global:ColourError }
                    } else {
                        $firstJobDisplayName += " <not found>"
                        $firstJobColor = $Global:ColourWarning
                    }
                    & $LocalWriteLog -Message ("  Jobs in Set  : " + $firstJobDisplayName) -Level "NONE" -ForegroundColour $firstJobColor

                    if ($jobsInSet.Count -gt 1) {
                        $jobsInSet | Select-Object -Skip 1 | ForEach-Object {
                            $jobNameInSet = $_
                            $jobColor = $Global:ColourInfo # Default
                            $jobDisplayName = $jobNameInSet
                            if ($Configuration.BackupLocations.ContainsKey($jobNameInSet)) {
                                $jobConfInSet = $Configuration.BackupLocations[$jobNameInSet]
                                $isJobEnabled = Get-ConfigValue -ConfigObject $jobConfInSet -Key 'Enabled' -DefaultValue $true
                                $jobColor = if ($isJobEnabled) { $Global:ColourSuccess } else { $Global:ColourError }
                            } else {
                                $jobDisplayName += " <not found>"
                                $jobColor = $Global:ColourWarning
                            }
                            & $LocalWriteLog -Message ("                 " + $jobDisplayName) -Level "NONE" -ForegroundColour $jobColor
                        }
                    }
                } else {
                    & $LocalWriteLog -Message ("  Jobs in Set  : (None listed)") -Level "NONE"
                }
            }
        } else {
            & $LocalWriteLog -Message "No Backup Sets are defined in the configuration." -Level "WARNING"
        }
        & $LocalWriteLog -Message "`n--- Listing Complete ---" -Level "HEADING"
        exit 0 # Exit after listing
    }

    if ($TestConfigSwitch) {
        & $LocalWriteLog -Message "`n[INFO] --- Configuration Test Mode Summary ---" -Level "CONFIG_TEST"
        & $LocalWriteLog -Message "[SUCCESS] Configuration file(s) loaded and validated successfully from '$($ActualConfigFile)'" -Level "CONFIG_TEST"
        if ($ConfigLoadResult.UserConfigLoaded) {
            & $LocalWriteLog -Message "          (User overrides from '$($ConfigLoadResult.UserConfigPath)' were applied)" -Level "CONFIG_TEST"
        }
        & $LocalWriteLog -Message "`n  --- Key Global Settings ---" -Level "CONFIG_TEST"
        $sevenZipPathDisplay = if($Configuration.ContainsKey('SevenZipPath')){ $Configuration.SevenZipPath } else { 'N/A' }
        & $LocalWriteLog -Message ("    7-Zip Path              : {0}" -f $sevenZipPathDisplay) -Level "CONFIG_TEST"
        $defaultDestDirDisplay = if($Configuration.ContainsKey('DefaultDestinationDir')){ $Configuration.DefaultDestinationDir } else { 'N/A' }
        & $LocalWriteLog -Message ("    Default Staging Dir     : {0}" -f $defaultDestDirDisplay) -Level "CONFIG_TEST"
        $delLocalArchiveDisplay = if($Configuration.ContainsKey('DeleteLocalArchiveAfterSuccessfulTransfer')){ $Configuration.DeleteLocalArchiveAfterSuccessfulTransfer } else { '$true (default)' }
        & $LocalWriteLog -Message ("    Del. Local Post Transfer: {0}" -f $delLocalArchiveDisplay) -Level "CONFIG_TEST"
        $logDirDisplay = if($Configuration.ContainsKey('LogDirectory')){ $Configuration.LogDirectory } else { 'N/A (File Logging Disabled)' }
        & $LocalWriteLog -Message ("    Log Directory           : {0}" -f $logDirDisplay) -Level "CONFIG_TEST"
        $htmlReportDirDisplay = if($Configuration.ContainsKey('HtmlReportDirectory')){ $Configuration.HtmlReportDirectory } else { 'N/A' }
        & $LocalWriteLog -Message ("    Default Report Dir (HTML): {0}" -f $htmlReportDirDisplay) -Level "CONFIG_TEST"
        $vssEnabledDisplayGlobal = if($Configuration.ContainsKey('EnableVSS')){ $Configuration.EnableVSS } else { $false }
        & $LocalWriteLog -Message ("    Default VSS Enabled     : {0}" -f $vssEnabledDisplayGlobal) -Level "CONFIG_TEST"
        $retriesEnabledDisplayGlobal = if($Configuration.ContainsKey('EnableRetries')){ $Configuration.EnableRetries } else { $false }
        & $LocalWriteLog -Message ("    Default Retries Enabled : {0}" -f $retriesEnabledDisplayGlobal) -Level "CONFIG_TEST"
        $treatWarningsAsSuccessDisplayGlobal = if($Configuration.ContainsKey('TreatSevenZipWarningsAsSuccess')){ $Configuration.TreatSevenZipWarningsAsSuccess } else { $false }
        & $LocalWriteLog -Message ("    Treat 7-Zip Warns as OK : {0}" -f $treatWarningsAsSuccessDisplayGlobal) -Level "CONFIG_TEST"
        $pauseExitDisplayGlobal = if($Configuration.ContainsKey('PauseBeforeExit')){ $Configuration.PauseBeforeExit } else { 'OnFailureOrWarning' }
        & $LocalWriteLog -Message ("    Pause Before Exit       : {0}" -f $pauseExitDisplayGlobal) -Level "CONFIG_TEST"

        if ($Configuration.ContainsKey('BackupTargets') -and $Configuration.BackupTargets -is [hashtable] -and $Configuration.BackupTargets.Count -gt 0) {
            & $LocalWriteLog -Message "`n  --- Defined Backup Targets ---" -Level "CONFIG_TEST"
            foreach ($targetNameKey in ($Configuration.BackupTargets.Keys | Sort-Object)) {
                $targetConf = $Configuration.BackupTargets[$targetNameKey]
                & $LocalWriteLog -Message ("    Target: {0} (Type: {1})" -f $targetNameKey, $targetConf.Type) -Level "CONFIG_TEST"
                if ($targetConf.TargetSpecificSettings) {
                    $targetConf.TargetSpecificSettings.GetEnumerator() | ForEach-Object {
                        & $LocalWriteLog -Message ("      -> {0} : {1}" -f $_.Name, $_.Value) -Level "CONFIG_TEST"
                    }
                }
            }
        } else { & $LocalWriteLog -Message "`n  --- Defined Backup Targets ---`n    (None defined)" -Level "CONFIG_TEST" }

        if ($Configuration.BackupLocations -is [hashtable] -and $Configuration.BackupLocations.Count -gt 0) {
            & $LocalWriteLog -Message "`n  --- Defined Backup Locations (Jobs) ---" -Level "CONFIG_TEST"
            foreach ($jobNameKey in ($Configuration.BackupLocations.Keys | Sort-Object)) {
                $jobConf = $Configuration.BackupLocations[$jobNameKey]
                & $LocalWriteLog -Message ("    Job: {0}" -f $jobNameKey) -Level "CONFIG_TEST"
                $sourcePathsDisplay = if ($jobConf.Path -is [array]) { $jobConf.Path -join "; " } else { $jobConf.Path }; & $LocalWriteLog -Message ("      Source(s)    : {0}" -f $sourcePathsDisplay) -Level "CONFIG_TEST"
                $destDirDisplayJob = if ($jobConf.ContainsKey('DestinationDir')) { $jobConf.DestinationDir } elseif ($Configuration.ContainsKey('DefaultDestinationDir')) { $Configuration.DefaultDestinationDir } else { 'N/A' }; & $LocalWriteLog -Message ("      Staging Dir  : {0}" -f $destDirDisplayJob) -Level "CONFIG_TEST"
                if ($jobConf.ContainsKey('TargetNames') -and $jobConf.TargetNames -is [array] -and $jobConf.TargetNames.Count -gt 0) { & $LocalWriteLog -Message ("      Remote Targets: {0}" -f ($jobConf.TargetNames -join ", ")) -Level "CONFIG_TEST" }
                $archiveNameDisplayJob = if ($jobConf.ContainsKey('Name')) { $jobConf.Name } else { 'N/A (Uses Job Name)' }; & $LocalWriteLog -Message ("      Archive Name : {0}" -f $archiveNameDisplayJob) -Level "CONFIG_TEST"
                $vssEnabledDisplayJob = if ($jobConf.ContainsKey('EnableVSS')) { $jobConf.EnableVSS } elseif ($Configuration.ContainsKey('EnableVSS')) { $Configuration.EnableVSS } else { $false }; & $LocalWriteLog -Message ("      VSS Enabled  : {0}" -f $vssEnabledDisplayJob) -Level "CONFIG_TEST"
                $treatWarnDisplayJob = if ($jobConf.ContainsKey('TreatSevenZipWarningsAsSuccess')) { $jobConf.TreatSevenZipWarningsAsSuccess } elseif ($Configuration.ContainsKey('TreatSevenZipWarningsAsSuccess')) { $Configuration.TreatSevenZipWarningsAsSuccess } else { $false }; & $LocalWriteLog -Message ("      Treat Warn OK: {0}" -f $treatWarnDisplayJob) -Level "CONFIG_TEST"
                $retentionDisplayJob = if ($jobConf.ContainsKey('LocalRetentionCount')) { $jobConf.LocalRetentionCount } else { 'N/A' }; & $LocalWriteLog -Message ("      LocalRetain  : {0}" -f $retentionDisplayJob) -Level "CONFIG_TEST"
            }
        } else { & $LocalWriteLog -Message "`n  --- Defined Backup Locations (Jobs) ---`n    No Backup Locations defined." -Level "CONFIG_TEST" }

        if ($Configuration.BackupSets -is [hashtable] -and $Configuration.BackupSets.Count -gt 0) {
            & $LocalWriteLog -Message "`n  --- Defined Backup Sets ---" -Level "CONFIG_TEST"
            foreach ($setNameKey in ($Configuration.BackupSets.Keys | Sort-Object)) {
                $setConf = $Configuration.BackupSets[$setNameKey]
                & $LocalWriteLog -Message ("    Set: {0}" -f $setNameKey) -Level "CONFIG_TEST"
                $jobsInSetDisplay = if ($setConf.JobNames -is [array]) { $setConf.JobNames -join ", " } else { "None listed" }; & $LocalWriteLog -Message ("      Jobs in Set  : {0}" -f $jobsInSetDisplay) -Level "CONFIG_TEST"
                $onErrorDisplaySet = if ($setConf.ContainsKey('OnErrorInJob')) { $setConf.OnErrorInJob } else { 'StopSet' }; & $LocalWriteLog -Message ("      On Error     : {0}" -f $onErrorDisplaySet) -Level "CONFIG_TEST"
            }
        } else { & $LocalWriteLog -Message "`n  --- Defined Backup Sets ---`n    No Backup Sets defined." -Level "CONFIG_TEST" }

        # --- Display Effective Post-Run Action ---
        if (Get-Command Invoke-PoShBackupPostRunActionHandler -ErrorAction SilentlyContinue) {
            $postRunResolution = Invoke-PoShBackupPostRunActionHandler -OverallStatus "SIMULATED_COMPLETE" `
                -CliOverrideSettings $CliOverrideSettingsInternal `
                -SetSpecificPostRunAction $null `
                -JobSpecificPostRunActionForNonSet $null `
                -GlobalConfig $Configuration `
                -IsSimulateMode $true `
                -TestConfigIsPresent $true `
                -Logger $Logger `
                -ResolveOnly

            if ($null -ne $postRunResolution) {
                & $LocalWriteLog -Message "`n  --- Effective Post-Run Action ---" -Level "CONFIG_TEST"
                & $LocalWriteLog -Message ("    Action          : {0}" -f $postRunResolution.Action) -Level "CONFIG_TEST"
                & $LocalWriteLog -Message ("    Source          : {0}" -f $postRunResolution.Source) -Level "CONFIG_TEST"
                if ($postRunResolution.Action -ne 'None') {
                    & $LocalWriteLog -Message ("    Trigger On      : {0}" -f $postRunResolution.TriggerOnStatus) -Level "CONFIG_TEST"
                    & $LocalWriteLog -Message ("    Delay (seconds) : {0}" -f $postRunResolution.DelaySeconds) -Level "CONFIG_TEST"
                    & $LocalWriteLog -Message ("    Force Action    : {0}" -f $postRunResolution.ForceAction) -Level "CONFIG_TEST"
                }
            }
        } else {
            & $LocalWriteLog -Message "`n  --- Effective Post-Run Action ---" -Level "CONFIG_TEST"
            & $LocalWriteLog -Message "    (Could not be determined as PostRunActionOrchestrator was not available)" -Level "CONFIG_TEST"
        }

        & $LocalWriteLog -Message "`n[INFO] --- Configuration Test Mode Finished ---" -Level "CONFIG_TEST"
        exit 0
    }

    return $false # No informational mode was handled, main script should continue
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupScriptMode
