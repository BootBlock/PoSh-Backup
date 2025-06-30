# Modules\ScriptModes\Diagnostics\PackageExporter.psm1
<#
.SYNOPSIS
    A sub-module for Diagnostics.psm1. Handles the `-ExportDiagnosticPackage` script mode.
.DESCRIPTION
    This module contains the logic for gathering system information, sanitised configuration files,
    recent logs, and permissions reports into a single ZIP package for troubleshooting.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    26-Jun-2025
    LastModified:   26-Jun-2025
    Purpose:        To handle the -ExportDiagnosticPackage diagnostic mode.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\ScriptModes\Diagnostics
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Managers\7ZipManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Utilities\StringUtils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Utilities\SystemUtils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Warning "ScriptModes\Diagnostics\PackageExporter.psm1: Could not import required modules. Error: $($_.Exception.Message)"
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
    
    # PSSA Appeasement
    & $Logger -Message "PackageExporter/Compare-PoShBackupConfigsInternal: Logger active for path '$PathPrefix'." -Level "DEBUG" -ErrorAction SilentlyContinue

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

function Invoke-ExportDiagnosticPackage {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        [Parameter(Mandatory = $true)]
        [string]$PSScriptRoot,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )
    & $Logger -Message "Diagnostics/PackageExporter: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue
    
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    & $LocalWriteLog -Message "`n--- Exporting Diagnostic Package ---" -Level "HEADING"

    if (-not $PSCmdletInstance.ShouldProcess($OutputPath, "Create Diagnostic Package")) {
        & $LocalWriteLog -Message "Diagnostic package creation skipped by user." -Level "WARNING"
        return
    }

    $tempDir = Join-Path -Path $env:TEMP -ChildPath "PoShBackup_Diag_$(Get-Random)"
    try {
        & $LocalWriteLog -Message "  - Creating temporary directory: '$tempDir'" -Level "INFO"
        New-Item -Path $tempDir -ItemType Directory -Force -ErrorAction Stop | Out-Null

        # 1. Gather System Information
        & $LocalWriteLog -Message "  - Gathering system information..." -Level "INFO"
        $systemInfo = [System.Text.StringBuilder]::new()
        $null = $systemInfo.AppendLine("PoSh-Backup Diagnostic Information")
        $null = $systemInfo.AppendLine("Generated on: $(Get-Date -Format 'o')")
        $null = $systemInfo.AppendLine(("-" * 40))

        $mainScriptVersion = Get-ScriptVersionFromContent -ScriptContent (Get-Content (Join-Path $PSScriptRoot "PoSh-Backup.ps1") -Raw)
        $null = $systemInfo.AppendLine("PoSh-Backup Version: $mainScriptVersion")
        $null = $systemInfo.AppendLine("PowerShell Version : $($PSVersionTable.PSVersion)")
        $null = $systemInfo.AppendLine("OS Version         : $((Get-CimInstance Win32_OperatingSystem).Caption)")
        $null = $systemInfo.AppendLine("Culture            : $((Get-Culture).Name)")
        $null = $systemInfo.AppendLine("Execution Policy   : $(Get-ExecutionPolicy)")
        $null = $systemInfo.AppendLine("Admin Rights       : $(Test-AdminPrivilege -Logger $Logger)")
        $null = $systemInfo.AppendLine(("-" * 40))

        $discoveryResult = Find-SevenZipExecutable -Logger $Logger
        $sevenZipPathForDiag = $discoveryResult.FoundPath
        if ($sevenZipPathForDiag) {
            $sevenZipVersionInfo = (& $sevenZipPathForDiag | Select-Object -First 2) -join " "
            $null = $systemInfo.AppendLine("7-Zip Path    : $sevenZipPathForDiag")
            $null = $systemInfo.AppendLine("7-Zip Version : $sevenZipVersionInfo")
        }
        else {
            $null = $systemInfo.AppendLine("7-Zip Info    : Not found or configured.")
        }
        $null = $systemInfo.AppendLine(("-" * 40))

        $null = $systemInfo.AppendLine("External PowerShell Module Status:")
        $poshSshModule = Get-Module -Name Posh-SSH -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
        $secretMgmtModule = Get-Module -Name Microsoft.PowerShell.SecretManagement -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
        $null = $systemInfo.AppendLine(" - Posh-SSH: $(if($poshSshModule){"v$($poshSshModule.Version) found at $($poshSshModule.Path)"}else{'<not found>'})")
        $null = $systemInfo.AppendLine(" - SecretManagement: $(if($secretMgmtModule){"v$($secretMgmtModule.Version) found"}else{'<not found>'})")
        try {
            $vaults = Get-SecretVault -ErrorAction SilentlyContinue
            if ($vaults) {
                $vaults | ForEach-Object { $null = $systemInfo.AppendLine("   - Vault Found: Name '$($_.Name)', Module '$($_.ModuleName)', Default: $($_.DefaultVault)") }
            } else { $null = $systemInfo.AppendLine("   - Vaults: No secret vaults found or registered.") }
        } catch { $null = $systemInfo.AppendLine("   - Vaults: Error checking for vaults: $($_.Exception.Message)") }

        $null = $systemInfo.AppendLine(("-" * 40))
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

        $null = $systemInfo.AppendLine(("-" * 40))
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

        # 2. Copy and Sanitise Configuration Files
        & $LocalWriteLog -Message "  - Copying and sanitising configuration files..." -Level "INFO"
        $configSourceDir = Resolve-PoShBackupPath -PathToResolve "Config" -ScriptRoot $PSScriptRoot
        if (Test-Path -LiteralPath $configSourceDir -PathType Container) {
            $configDestDir = Join-Path -Path $tempDir -ChildPath "Config"
            New-Item -Path $configDestDir -ItemType Directory -Force | Out-Null
            $defaultConfigPath = Join-Path -Path $configSourceDir -ChildPath "Default.psd1"
            $userConfigPath = Join-Path -Path $configSourceDir -ChildPath "User.psd1"
            $pssaSettingsPath = Join-Path -Path $PSScriptRoot -ChildPath "PSScriptAnalyzerSettings.psd1"

            if ((Test-Path $defaultConfigPath) -and (Test-Path $userConfigPath)) {
                & $LocalWriteLog -Message "    - Generating human-readable configuration diff..." -Level "DEBUG"
                try {
                    $defaultData = Import-PowerShellDataFile -LiteralPath $defaultConfigPath
                    $userData = Import-PowerShellDataFile -LiteralPath $userConfigPath
                    $diffOutput = Compare-PoShBackupConfigsInternal -UserConfig $userData -DefaultConfig $defaultData -Logger $Logger
                    if ($diffOutput.Count -eq 0) {
                        "No differences found between Default.psd1 and User.psd1." | Set-Content -Path (Join-Path $configDestDir "UserConfig.diff.txt") -Encoding UTF8
                    } else {
                        ("User.psd1 Overrides and Additions:" + [Environment]::NewLine + ("-" * 40)) + [Environment]::NewLine + ($diffOutput -join [Environment]::NewLine) | Set-Content -Path (Join-Path $configDestDir "UserConfig.diff.txt") -Encoding UTF8
                    }
                } catch { "Error generating config diff: $($_.Exception.Message)" | Set-Content -Path (Join-Path $configDestDir "UserConfig.diff.txt") -Encoding UTF8 }
            }

            $configFilesToCopy = @{ ($defaultConfigPath) = "Default.psd1"; ($userConfigPath) = "User.psd1"; ($pssaSettingsPath) = "PSScriptAnalyzerSettings.psd1" }
            $sensitiveKeyPatterns = @('Password', 'SecretName', 'Credential', 'WebhookUrl')

            foreach ($sourcePath in $configFilesToCopy.Keys) {
                if (Test-Path -LiteralPath $sourcePath) {
                    $destFileName = $configFilesToCopy[$sourcePath]
                    $destPath = Join-Path -Path $configDestDir -ChildPath $destFileName
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
        }
        else { & $LocalWriteLog -Message "    - [INFO] 'Config' directory not found. Configuration files will not be included in the package." -Level "INFO" }

        # 3. Gather Recent Logs
        & $LocalWriteLog -Message "  - Gathering recent log files..." -Level "INFO"
        $logSourceDir = Resolve-PoShBackupPath -PathToResolve "Logs" -ScriptRoot $PSScriptRoot
        if (Test-Path -LiteralPath $logSourceDir -PathType Container) {
            $logDestDir = Join-Path -Path $tempDir -ChildPath "Logs"
            New-Item -Path $logDestDir -ItemType Directory -Force | Out-Null
            Get-ChildItem -Path $logSourceDir -Filter "*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 10 | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination $logDestDir
            }
            & $LocalWriteLog -Message "    - Copied up to 10 most recent log files." -Level "DEBUG"
        }
        else { & $LocalWriteLog -Message "    - [INFO] 'Logs' directory not found. Log files will not be included in the package." -Level "INFO" }

        # 4. Permissions/ACLs Report
        & $LocalWriteLog -Message "  - Gathering permissions report..." -Level "INFO"
        $aclReport = [System.Text.StringBuilder]::new()
        $pathsToAclCheck = @($PSScriptRoot, (Join-Path $PSScriptRoot "Config"), (Join-Path $PSScriptRoot "Modules"), (Join-Path $PSScriptRoot "Logs"), (Join-Path $PSScriptRoot "Reports"))
        try {
            $configForAcl = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot "Config\Default.psd1")
            if (Test-Path (Join-Path $PSScriptRoot "Config\User.psd1")) {
                $userConfigForAcl = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot "Config\User.psd1")
                $userConfigForAcl.GetEnumerator() | ForEach-Object { $configForAcl[$_.Name] = $_.Value }
            }
            if ($configForAcl.DefaultDestinationDir) { $pathsToAclCheck += $configForAcl.DefaultDestinationDir }
            if ($configForAcl.BackupLocations) { $configForAcl.BackupLocations.Values | ForEach-Object { if ($_.DestinationDir) { $pathsToAclCheck += $_.DestinationDir } } }
        }
        catch { & $LocalWriteLog -Message "  - Diagnostic ACL Check: Could not load config to find destination paths. Error: $($_.Exception.Message)" -Level "DEBUG" }

        foreach ($path in ($pathsToAclCheck | Select-Object -Unique)) {
            $null = $aclReport.AppendLine(("=" * 60)); $null = $aclReport.AppendLine("ACL for: $path"); $null = $aclReport.AppendLine(("=" * 60))
            if (Test-Path -LiteralPath $path) {
                try { $aclOutput = (Get-Acl -LiteralPath $path | Format-List | Out-String).Trim(); $null = $aclReport.AppendLine($aclOutput) }
                catch { $null = $aclReport.AppendLine("ERROR retrieving ACL: $($_.Exception.Message)") }
            }
            else { $null = $aclReport.AppendLine("Path does not exist.") }
            $null = $aclReport.AppendLine()
        }
        $aclReport.ToString() | Set-Content -Path (Join-Path $tempDir "Permissions.acl.txt") -Encoding UTF8

        # 5. Create ZIP Package
        & $LocalWriteLog -Message "  - Compressing diagnostic files to '$OutputPath'..." -Level "INFO"
        Compress-Archive -Path "$tempDir\*" -DestinationPath $OutputPath -Force -ErrorAction Stop
        & $LocalWriteLog -Message "  - Diagnostic package created successfully." -Level "SUCCESS"

    }
    catch { & $LocalWriteLog -Message "[ERROR] Failed to create diagnostic package. Error: $($_.Exception.Message)" -Level "ERROR" }
    finally {
        if (Test-Path -LiteralPath $tempDir) {
            & $LocalWriteLog -Message "  - Cleaning up temporary directory..." -Level "DEBUG"
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Export-ModuleMember -Function Invoke-ExportDiagnosticPackage
