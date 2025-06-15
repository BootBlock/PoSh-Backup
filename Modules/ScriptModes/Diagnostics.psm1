# Modules\ScriptModes\Diagnostics.psm1
<#
.SYNOPSIS
    Handles diagnostic script modes for PoSh-Backup, such as testing the configuration,
    getting a job's effective configuration, and exporting a diagnostic package.
.DESCRIPTION
    This module is a sub-component of ScriptModeHandler.psm1. It encapsulates the logic
    for the following command-line switches:
    - -TestConfig
    - -GetEffectiveConfig
    - -ExportDiagnosticPackage
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.1 # Added missing 7ZipManager import for Find-SevenZipExecutable.
    DateCreated:    15-Jun-2025
    LastModified:   15-Jun-2025
    Purpose:        To handle diagnostic script execution modes for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\ScriptModes\
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Modules\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot "..\..\Modules\Managers\7ZipManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot "..\..\Modules\Core\ConfigManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot "..\..\Modules\Core\PostRunActionOrchestrator.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Warning "ScriptModes\Diagnostics.psm1: Could not import a manager module. Specific modes may be unavailable. Error: $($_.Exception.Message)"
}
#endregion

#region --- Private Helper: Compare Configs for Diff ---
function Compare-PoShBackupConfigsInternal {
    [OutputType([System.Collections.Generic.List[string]])]
    param(
        [hashtable]$UserConfig,
        [hashtable]$DefaultConfig,
        [string]$PathPrefix = "",
        [scriptblock]$Logger
    )
    
    $differences = [System.Collections.Generic.List[string]]::new()

    foreach ($key in $UserConfig.Keys) {
        $currentPath = if ([string]::IsNullOrWhiteSpace($PathPrefix)) { $key } else { "$PathPrefix.$key" }
        $userValue = $UserConfig[$key]

        if (-not $DefaultConfig.ContainsKey($key)) {
            $differences.Add(" + Added: $currentPath = '$userValue'")
            continue
        }

        $defaultValue = $DefaultConfig[$key]

        if (($userValue -is [hashtable]) -and ($defaultValue -is [hashtable])) {
            $recursiveDiffs = Compare-PoShBackupConfigsInternal -UserConfig $userValue -DefaultConfig $defaultValue -PathPrefix $currentPath -Logger $Logger
            if ($null -ne $recursiveDiffs -and $recursiveDiffs.Count -gt 0) {
                foreach ($diffItem in $recursiveDiffs) {
                    $differences.Add($diffItem)
                }
            }
        }
        else {
            $diff = Compare-Object -ReferenceObject $defaultValue -DifferenceObject $userValue
            if ($null -ne $diff) {
                $defaultDisplay = if ($defaultValue -is [array]) { "'@($($defaultValue -join ', '))'" } else { "'$defaultValue'" }
                $userDisplay = if ($userValue -is [array]) { "'@($($userValue -join ', '))'" } else { "'$userValue'" }
                $diffString = " ~ Modified: $currentPath | Default: $defaultDisplay -> User: $userDisplay"
                $differences.Add($diffString)
            }
        }
    }

    return $differences
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
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )
    & $Logger -Message "ScriptModes/Diagnostics/Invoke-ExportDiagnosticPackageInternal: Logger parameter active." -Level "DEBUG" -ErrorAction SilentlyContinue

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

        $sevenZipPathForDiag = Find-SevenZipExecutable -Logger $Logger
        if ($sevenZipPathForDiag) {
            $sevenZipVersionInfo = (& $sevenZipPathForDiag | Select-Object -First 2) -join " "
            $null = $systemInfo.AppendLine("7-Zip Path    : $sevenZipPathForDiag")
            $null = $systemInfo.AppendLine("7-Zip Version : $sevenZipVersionInfo")
        } else {
            $null = $systemInfo.AppendLine("7-Zip Info    : Not found or configured.")
        }
        $null = $systemInfo.AppendLine(("-"*40))

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
            $null = $systemInfo.AppendLine(" - $($relativePath.PadRight(76)) $versionString")
        }

        $null = $systemInfo.AppendLine(("-"*40))
        $null = $systemInfo.AppendLine("Disk Space Report:")
        try {
            Get-PSDrive -PSProvider FileSystem | ForEach-Object {
                if ($_.Root -match "^[A-Z]:\\$") {
                    $drive = $_
                    $totalSizeGB = [math]::Round(($drive.Used + $drive.Free) / 1GB, 2)
                    $freeSpaceGB = [math]::Round($drive.Free / 1GB, 2)
                    $percentFree = if ($totalSizeGB -gt 0) { [math]::Round(($freeSpaceGB / $totalSizeGB) * 100, 2) } else { 0 }
                    $null = $systemInfo.AppendLine(" - Drive $($drive.Name): Total: $($totalSizeGB) GB, Free: $($freeSpaceGB) GB ($($percentFree)%)")
                }
            }
        } catch { $null = $systemInfo.AppendLine(" - Error gathering disk space information: $($_.Exception.Message)") }

        $systemInfo.ToString() | Set-Content -Path (Join-Path $tempDir "SystemInfo.txt") -Encoding UTF8

        # --- 2. Copy and Sanitize Configuration Files ---
        & $LocalWriteLog -Message "  - Copying and sanitizing configuration files..." -Level "INFO"
        $configDir = Join-Path -Path $tempDir -ChildPath "Config"
        New-Item -Path $configDir -ItemType Directory -Force | Out-Null
        $defaultConfigPath = Join-Path -Path $PSScriptRoot -ChildPath "Config\Default.psd1"
        $userConfigPath = Join-Path -Path $PSScriptRoot -ChildPath "Config\User.psd1"
        $pssaSettingsPath = Join-Path -Path $PSScriptRoot -ChildPath "PSScriptAnalyzerSettings.psd1"

        if ((Test-Path $defaultConfigPath) -and (Test-Path $userConfigPath)) {
            & $LocalWriteLog -Message "    - Generating human-readable configuration diff..." -Level "DEBUG"
            try {
                $defaultData = Import-PowerShellDataFile -LiteralPath $defaultConfigPath
                $userData = Import-PowerShellDataFile -LiteralPath $userConfigPath
                $diffOutput = Compare-PoShBackupConfigsInternal -UserConfig $userData -DefaultConfig $defaultData -Logger $Logger
                if ($diffOutput.Count -eq 0) {
                    "No differences found between Default.psd1 and User.psd1." | Set-Content -Path (Join-Path $configDir "UserConfig.diff.txt") -Encoding UTF8
                } else {
                    ("User.psd1 Overrides and Additions:" + [Environment]::NewLine + ("-"*40)) + [Environment]::NewLine + ($diffOutput -join [Environment]::NewLine) | Set-Content -Path (Join-Path $configDir "UserConfig.diff.txt") -Encoding UTF8
                }
            } catch {
                "Error generating config diff: $($_.Exception.Message)" | Set-Content -Path (Join-Path $configDir "UserConfig.diff.txt") -Encoding UTF8
            }
        }

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
                & $LocalWriteLog -Message "    - Copied and sanitized '$destFileName'." -Level "DEBUG"
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

        # --- 4. Permissions/ACLs Report ---
        & $LocalWriteLog -Message "  - Gathering permissions report..." -Level "INFO"
        $aclReport = [System.Text.StringBuilder]::new()
        $pathsToAclCheck = @(
            $PSScriptRoot,
            (Join-Path $PSScriptRoot "Config"),
            (Join-Path $PSScriptRoot "Modules"),
            (Join-Path $PSScriptRoot "Logs"),
            (Join-Path $PSScriptRoot "Reports")
        )
        try {
            $configForAcl = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot "Config\Default.psd1")
            if (Test-Path (Join-Path $PSScriptRoot "Config\User.psd1")) {
                $userConfigForAcl = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot "Config\User.psd1")
                $userConfigForAcl.GetEnumerator() | ForEach-Object { $configForAcl[$_.Name] = $_.Value }
            }
            if ($configForAcl.DefaultDestinationDir) { $pathsToAclCheck += $configForAcl.DefaultDestinationDir }
            if ($configForAcl.BackupLocations) { $configForAcl.BackupLocations.Values | ForEach-Object { if ($_.DestinationDir) { $pathsToAclCheck += $_.DestinationDir } } }
        } catch {
            & $LocalWriteLog -Message "  - Diagnostic ACL Check: Could not load config to find destination paths. Error: $($_.Exception.Message)" -Level "DEBUG"
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

        # --- 5. Create ZIP Package ---
        & $LocalWriteLog -Message "  - Compressing diagnostic files to '$OutputPath'..." -Level "INFO"
        Compress-Archive -Path "$tempDir\*" -DestinationPath $OutputPath -Force -ErrorAction Stop
        & $LocalWriteLog -Message "  - Diagnostic package created successfully." -Level "SUCCESS"

    } catch {
        & $LocalWriteLog -Message "[ERROR] Failed to create diagnostic package. Error: $($_.Exception.Message)" -Level "ERROR"
    } finally {
        # --- 6. Cleanup ---
        if (Test-Path -LiteralPath $tempDir) {
            & $LocalWriteLog -Message "  - Cleaning up temporary directory..." -Level "DEBUG"
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
#endregion

function Invoke-PoShBackupDiagnosticMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$TestConfigSwitch,
        [Parameter(Mandatory = $false)]
        [string]$GetEffectiveConfigJobName,
        [Parameter(Mandatory = $false)]
        [string]$ExportDiagnosticPackagePath,
        [Parameter(Mandatory = $true)]
        [hashtable]$CliOverrideSettingsInternal,
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,
        [Parameter(Mandatory = $true)]
        [string]$ActualConfigFile,
        [Parameter(Mandatory = $true)]
        [hashtable]$ConfigLoadResult,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
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

    if (-not [string]::IsNullOrWhiteSpace($ExportDiagnosticPackagePath)) {
        Invoke-ExportDiagnosticPackageInternal -OutputPath $ExportDiagnosticPackagePath `
            -PSScriptRoot $Configuration['_PoShBackup_PSScriptRoot'] `
            -Logger $Logger `
            -PSCmdlet $PSCmdletInstance
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($GetEffectiveConfigJobName)) {
        & $LocalWriteLog -Message "`n--- Get Effective Job Configuration Mode ---" -Level "HEADING"
        if (-not $Configuration.BackupLocations.ContainsKey($GetEffectiveConfigJobName)) {
            & $LocalWriteLog -Message "  - ERROR: The specified job name '$GetEffectiveConfigJobName' was not found in the configuration." -Level "ERROR"
            return $true # Handled
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
            & $LocalWriteLog -Message "[FATAL] ScriptModes/Diagnostics: An error occurred while resolving the effective configuration for job '$GetEffectiveConfigJobName'. Error: $($_.Exception.Message)" -Level "ERROR"
        }
        return $true
    }

    if ($TestConfigSwitch) {
        & $LocalWriteLog -Message "`n[INFO] --- Configuration Test Mode Summary ---" -Level "CONFIG_TEST"
        & $LocalWriteLog -Message "[SUCCESS] Configuration file(s) loaded and validated successfully from '$($ActualConfigFile)'" -Level "CONFIG_TEST"
        if ($ConfigLoadResult.UserConfigLoaded) {
            & $LocalWriteLog -Message "          (User overrides from '$($ConfigLoadResult.UserConfigPath)')" -Level "CONFIG_TEST"
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
        } else { & $LocalWriteLog -Message "`n  --- Defined Backup Targets ---`n    <none defined>" -Level "CONFIG_TEST" }

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
        return $true
    }
    
    return $false # No diagnostic mode was handled
}

Export-ModuleMember -Function Invoke-PoShBackupDiagnosticMode
