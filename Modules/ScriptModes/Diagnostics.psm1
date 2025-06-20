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
    - -TestBackupTarget
    - -PreFlightCheck
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.3.0 # Added -PreFlightCheck logic.
    DateCreated:    15-Jun-2025
    LastModified:   20-Jun-2025
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
    Import-Module -Name (Join-Path -Path $PSScriptRoot "..\..\Modules\Managers\JobDependencyManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path -Path $PSScriptRoot "..\..\Modules\Utilities\ConsoleDisplayUtils.psm1") -Force -ErrorAction Stop
    # NEW: Import the PreFlightChecker module
    Import-Module -Name (Join-Path -Path $PSScriptRoot "PreFlightChecker.psm1") -Force -ErrorAction Stop
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

#region --- Private Helper: Format Dependency Graph ---
function Format-DependencyGraphInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$DependencyMap
    )

    $outputLines = [System.Collections.Generic.List[string]]::new()
    if ($DependencyMap.Count -eq 0) {
        $outputLines.Add("    No jobs defined.")
        return $outputLines
    }

    $allJobs = $DependencyMap.Keys
    $allDependencies = @($DependencyMap.Values | ForEach-Object { $_ }) | Select-Object -Unique

    if ($allDependencies.Count -eq 0) {
        $outputLines.Add("    No job dependencies are defined in the configuration.")
        return $outputLines
    }

    $topLevelJobs = $allJobs | Where-Object { $_ -notin $allDependencies } | Sort-Object
    $processedJobs = @{}

    # Recursive helper function
    function Write-DependencyNode {
        param(
            [string]$JobName,
            [int]$IndentLevel,
            [hashtable]$Map,
            [hashtable]$Processed,
            [ref]$OutputListRef
        )

        $indent = "    " + ("  " * $IndentLevel)
        $arrow = if ($IndentLevel -gt 0) { "└─ " } else { "" }
        $line = "$indent$arrow$JobName"

        if ($Processed.ContainsKey($JobName)) {
            $OutputListRef.Value.Add("$line (see above)")
            return
        }

        $OutputListRef.Value.Add($line)
        $Processed[$JobName] = $true

        if ($Map.ContainsKey($JobName)) {
            $dependencies = $Map[$JobName]
            foreach ($dep in $dependencies) {
                Write-DependencyNode -JobName $dep -IndentLevel ($IndentLevel + 1) -Map $Map -Processed $Processed -OutputListRef $OutputListRef
            }
        }
    }

    foreach ($job in $topLevelJobs) {
        Write-DependencyNode -JobName $job -IndentLevel 0 -Map $DependencyMap -Processed $processedJobs -OutputListRef ([ref]$outputLines)
    }

    $remainingJobs = $allJobs | Where-Object { -not $processedJobs.ContainsKey($_) } | Sort-Object
    if ($remainingJobs.Count -gt 0) {
        $outputLines.Add("")
        $outputLines.Add("    (Jobs involved in cycles or that are only dependencies)")
        foreach ($job in $remainingJobs) {
            Write-DependencyNode -JobName $job -IndentLevel 0 -Map $DependencyMap -Processed $processedJobs -OutputListRef ([ref]$outputLines)
        }
    }
    
    return $outputLines
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
        $null = $systemInfo.AppendLine(("-" * 40))

        $mainScriptVersion = Get-ScriptVersionFromContent -ScriptContent (Get-Content (Join-Path $PSScriptRoot "PoSh-Backup.ps1") -Raw)
        $null = $systemInfo.AppendLine("PoSh-Backup Version: $mainScriptVersion")
        $null = $systemInfo.AppendLine("PowerShell Version : $($PSVersionTable.PSVersion)")
        $null = $systemInfo.AppendLine("OS Version         : $((Get-CimInstance Win32_OperatingSystem).Caption)")
        $null = $systemInfo.AppendLine("Culture            : $((Get-Culture).Name)")
        $null = $systemInfo.AppendLine("Execution Policy   : $(Get-ExecutionPolicy)")
        $null = $systemInfo.AppendLine("Admin Rights       : $(Test-AdminPrivilege -Logger $Logger)")
        $null = $systemInfo.AppendLine(("-" * 40))

        $sevenZipPathForDiag = Find-SevenZipExecutable -Logger $Logger
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
            }
            else {
                $null = $systemInfo.AppendLine("   - Vaults: No secret vaults found or registered.")
            }
        }
        catch { $null = $systemInfo.AppendLine("   - Vaults: Error checking for vaults: $($_.Exception.Message)") }

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
        }
        catch { $null = $systemInfo.AppendLine(" - Error gathering disk space information: $($_.Exception.Message)") }

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
                }
                else {
                    ("User.psd1 Overrides and Additions:" + [Environment]::NewLine + ("-" * 40)) + [Environment]::NewLine + ($diffOutput -join [Environment]::NewLine) | Set-Content -Path (Join-Path $configDir "UserConfig.diff.txt") -Encoding UTF8
                }
            }
            catch {
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
        }
        catch {
            & $LocalWriteLog -Message "  - Diagnostic ACL Check: Could not load config to find destination paths. Error: $($_.Exception.Message)" -Level "DEBUG"
        }

        foreach ($path in ($pathsToAclCheck | Select-Object -Unique)) {
            $null = $aclReport.AppendLine(("=" * 60))
            $null = $aclReport.AppendLine("ACL for: $path")
            $null = $aclReport.AppendLine(("=" * 60))
            if (Test-Path -LiteralPath $path) {
                try {
                    $aclOutput = (Get-Acl -LiteralPath $path | Format-List | Out-String).Trim()
                    $null = $aclReport.AppendLine($aclOutput)
                }
                catch {
                    $null = $aclReport.AppendLine("ERROR retrieving ACL: $($_.Exception.Message)")
                }
            }
            else {
                $null = $aclReport.AppendLine("Path does not exist.")
            }
            $null = $aclReport.AppendLine()
        }
        $aclReport.ToString() | Set-Content -Path (Join-Path $tempDir "Permissions.acl.txt") -Encoding UTF8

        # --- 5. Create ZIP Package ---
        & $LocalWriteLog -Message "  - Compressing diagnostic files to '$OutputPath'..." -Level "INFO"
        Compress-Archive -Path "$tempDir\*" -DestinationPath $OutputPath -Force -ErrorAction Stop
        & $LocalWriteLog -Message "  - Diagnostic package created successfully." -Level "SUCCESS"

    }
    catch {
        & $LocalWriteLog -Message "[ERROR] Failed to create diagnostic package. Error: $($_.Exception.Message)" -Level "ERROR"
    }
    finally {
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
        [Parameter(Mandatory = $true)]
        [bool]$PreFlightCheckSwitch,
        [Parameter(Mandatory = $false)]
        [string]$GetEffectiveConfigJobName,
        [Parameter(Mandatory = $false)]
        [string]$ExportDiagnosticPackagePath,
        [Parameter(Mandatory = $false)]
        [string]$TestBackupTarget,
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
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance,
        [Parameter(Mandatory = $false)]
        [string]$BackupLocationNameForScope,
        [Parameter(Mandatory = $false)]
        [string]$RunSetForScope
    )
    
    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        }
        else {
            & $Logger -Message $Message -Level $Level
        }
    }

    if ($PreFlightCheckSwitch) {
        & $LocalWriteLog -Message "`n--- Pre-Flight Check Mode ---" -Level "HEADING"
        $jobsToRun = @()
        if (-not [string]::IsNullOrWhiteSpace($BackupLocationNameForScope)) {
            $jobsToRun = @($BackupLocationNameForScope)
        }
        elseif (-not [string]::IsNullOrWhiteSpace($RunSetForScope)) {
            if ($Configuration.BackupSets.ContainsKey($RunSetForScope)) {
                $jobsToRun = @($Configuration.BackupSets[$RunSetForScope].JobNames)
            }
            else {
                & $LocalWriteLog -Message "  - ERROR: Specified set '$RunSetForScope' not found in configuration." -Level "ERROR"
            }
        }
        else {
            & $LocalWriteLog -Message "  - Checking all enabled backup jobs defined in the configuration..." -Level "INFO"
            $jobsToRun = @($Configuration.BackupLocations.Keys)
        }
        
        if ($jobsToRun.Count -gt 0) {
            $checkResult = Invoke-PoShBackupPreFlightCheck -JobsToCheck $jobsToRun `
                -Configuration $Configuration `
                -CliOverrideSettings $CliOverrideSettingsInternal `
                -Logger $Logger `
                -PSCmdletInstance $PSCmdletInstance
            
            & $LocalWriteLog -Message "`n--- Pre-Flight Check Finished ---" -Level "HEADING"
            $finalStatus = if ($checkResult) { "SUCCESS" } else { "FAILURE" }
            & $LocalWriteLog -Message "Overall Pre-Flight Check Status: $finalStatus" -Level $finalStatus
        }
        return $true # Mode handled
    }

    if (-not [string]::IsNullOrWhiteSpace($TestBackupTarget)) {
        & $LocalWriteLog -Message "`n--- Backup Target Health Check Mode ---" -Level "HEADING"
        if (-not ($Configuration.BackupTargets -is [hashtable] -and $Configuration.BackupTargets.ContainsKey($TestBackupTarget))) {
            & $LocalWriteLog -Message "  - ERROR: The specified target '$TestBackupTarget' was not found in the configuration." -Level "ERROR"
            return $true # Handled (with an error)
        }
        $targetConfig = $Configuration.BackupTargets[$TestBackupTarget]
        $targetType = $targetConfig.Type
        & $LocalWriteLog -Message "  - Testing Target: '$TestBackupTarget' (Type: $targetType)" -Level "INFO"

        $providerModuleName = "$targetType.Target.psm1"
        $providerModulePath = Join-Path -Path $Configuration['_PoShBackup_PSScriptRoot'] -ChildPath "Modules\Targets\$providerModuleName"
        $testFunctionName = "Test-PoShBackupTargetConnectivity"

        if (-not (Test-Path -LiteralPath $providerModulePath -PathType Leaf)) {
            & $LocalWriteLog -Message "  - ERROR: Cannot test target. The provider module '$providerModuleName' was not found at '$providerModulePath'." -Level "ERROR"
            return $true
        }
        
        try {
            $providerModule = Import-Module -Name $providerModulePath -Force -PassThru -ErrorAction Stop
            $testFunctionCmd = Get-Command -Name $testFunctionName -Module $providerModule.Name -ErrorAction SilentlyContinue

            if (-not $testFunctionCmd) {
                & $LocalWriteLog -Message "  - INFO: The '$targetType' target provider does not support an automated health check." -Level "INFO"
                return $true
            }

            $testParams = @{
                TargetSpecificSettings = $targetConfig.TargetSpecificSettings
                Logger                 = $Logger
                PSCmdlet               = $PSCmdletInstance
            }
            if ($targetConfig.ContainsKey('CredentialsSecretName') -and $testFunctionCmd.Parameters.ContainsKey('CredentialsSecretName')) {
                $testParams.CredentialsSecretName = $targetConfig.CredentialsSecretName
            }

            & $LocalWriteLog -Message "  - Invoking health check..." -Level "DEBUG"
            $testResult = & $testFunctionCmd @testParams
            
            if ($null -ne $testResult -and $testResult -is [hashtable] -and $testResult.ContainsKey('Success')) {
                if ($testResult.Success) {
                    & $LocalWriteLog -Message "  - RESULT: SUCCESS" -Level "SUCCESS"
                    if (-not [string]::IsNullOrWhiteSpace($testResult.Message)) {
                        & $LocalWriteLog -Message "    - Details: $($testResult.Message)" -Level "INFO"
                    }
                }
                else {
                    & $LocalWriteLog -Message "  - RESULT: FAILED" -Level "ERROR"
                    if (-not [string]::IsNullOrWhiteSpace($testResult.Message)) {
                        & $LocalWriteLog -Message "    - Details: $($testResult.Message)" -Level "ERROR"
                    }
                }
            }
            else {
                & $LocalWriteLog -Message "  - RESULT: UNKNOWN. The health check function did not return a valid result object." -Level "WARNING"
            }
        }
        catch {
            & $LocalWriteLog -Message "  - ERROR: An exception occurred while trying to test target '$TestBackupTarget'. Error: $($_.Exception.Message)" -Level "ERROR"
        }
        
        & $LocalWriteLog -Message "`n--- Health Check Finished ---" -Level "HEADING"
        return $true # Mode was handled
    }

    if (-not [string]::IsNullOrWhiteSpace($ExportDiagnosticPackagePath)) {
        Invoke-ExportDiagnosticPackageInternal -OutputPath $ExportDiagnosticPackagePath `
            -PSScriptRoot $Configuration['_PoShBackup_PSScriptRoot'] `
            -Logger $Logger `
            -PSCmdlet $PSCmdletInstance
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($GetEffectiveConfigJobName)) {
        Write-ConsoleBanner -NameText "Effective Configuration For Job" -ValueText $GetEffectiveConfigJobName -CenterText -PrependNewLine
        Write-Host
        if (-not $Configuration.BackupLocations.ContainsKey($GetEffectiveConfigJobName)) {
            & $LocalWriteLog -Message "  - ERROR: The specified job name '$GetEffectiveConfigJobName' was not found in the configuration." -Level "ERROR"
            return $true # Handled
        }
        try {
            $jobConfigForReport = $Configuration.BackupLocations[$GetEffectiveConfigJobName]
            $dummyReportDataRef = [ref]@{ JobName = $GetEffectiveConfigJobName }

            $effectiveConfigParams = @{
                JobConfig        = $jobConfigForReport
                GlobalConfig     = $Configuration
                CliOverrides     = $CliOverrideSettingsInternal
                JobReportDataRef = $dummyReportDataRef
                Logger           = $Logger
            }
            $effectiveConfigResult = Get-PoShBackupJobEffectiveConfiguration @effectiveConfigParams
            Write-Host

            foreach ($key in ($effectiveConfigResult.Keys | Sort-Object)) {
                # Skip the GlobalConfigRef as it's huge and not useful for display here
                if ($key -eq 'GlobalConfigRef') { continue }
            
                $value = $effectiveConfigResult[$key]
                $valueDisplay = if ($value -is [array]) {
                    "@($($value -join ', '))"
                }
                elseif ($value -is [hashtable]) {
                    # Simple display for hashtables, could be expanded if needed
                    "(Hashtable with $($value.Count) keys)"
                }
                else {
                    $value
                }
                Write-NameValue -name $key -value $valueDisplay -namePadding 42
            }

        }
        catch {
            & $LocalWriteLog -Message "[FATAL] ScriptModes/Diagnostics: An error occurred while resolving the effective configuration for job '$GetEffectiveConfigJobName'. Error: $($_.Exception.Message)" -Level "ERROR"
        }
        Write-ConsoleBanner -NameText "End of Effective Configuration" -BorderForegroundColor "White" -CenterText -PrependNewLine -AppendNewLine
        return $true
    }

    if ($TestConfigSwitch) {
        Write-ConsoleBanner -NameText "Configuration Test Mode" -ValueText "Summary" -CenterText -PrependNewLine

        & $LocalWriteLog -Message "  Configuration file(s) loaded and validated successfully from:" -Level "SUCCESS"
        & $LocalWriteLog -Message "    $($ActualConfigFile)" -Level "SUCCESS"
        if ($ConfigLoadResult.UserConfigLoaded) {
            & $LocalWriteLog -Message "          (User overrides from '$($ConfigLoadResult.UserConfigPath)')" -Level "INFO"
        }

        Write-ConsoleBanner -NameText "Key Global Settings" -BannerWidth 78 -CenterText -PrependNewLine
        $sevenZipPathDisplay = if ($Configuration.ContainsKey('SevenZipPath')) { $Configuration.SevenZipPath } else { 'N/A' }
        Write-NameValue "7-Zip Path                " $sevenZipPathDisplay
        $defaultDestDirDisplay = if ($Configuration.ContainsKey('DefaultDestinationDir')) { $Configuration.DefaultDestinationDir } else { 'N/A' }
        Write-NameValue "Default Staging Dir       " $defaultDestDirDisplay
        $delLocalArchiveDisplay = if ($Configuration.ContainsKey('DeleteLocalArchiveAfterSuccessfulTransfer')) { $Configuration.DeleteLocalArchiveAfterSuccessfulTransfer } else { '$true (default)' }
        Write-NameValue "Delete Local Post Transfer" $delLocalArchiveDisplay
        $logDirDisplay = if ($Configuration.ContainsKey('LogDirectory')) { $Configuration.LogDirectory } else { 'N/A (File Logging Disabled)' }
        Write-NameValue "Log Directory             " $logDirDisplay
        $vssEnabledDisplayGlobal = if ($Configuration.ContainsKey('EnableVSS')) { $Configuration.EnableVSS } else { $false }
        Write-NameValue "Default VSS Enabled       " $vssEnabledDisplayGlobal
        $treatWarningsAsSuccessDisplayGlobal = if ($Configuration.ContainsKey('TreatSevenZipWarningsAsSuccess')) { $Configuration.TreatSevenZipWarningsAsSuccess } else { $false }
        Write-NameValue "Treat 7-Zip Warns as OK   " $treatWarningsAsSuccessDisplayGlobal

        if ($Configuration.ContainsKey('BackupTargets') -and $Configuration.BackupTargets -is [hashtable] -and $Configuration.BackupTargets.Count -gt 0) {
            Write-ConsoleBanner -NameText "Defined Backup Targets" -BannerWidth 78 -CenterText -PrependNewLine
            foreach ($targetNameKey in ($Configuration.BackupTargets.Keys | Sort-Object)) {
                $targetConfType = $Configuration.BackupTargets[$targetNameKey].Type
                Write-NameValue "  Target" "$targetNameKey (Type: $targetConfType)"
            }
        }

        if ($Configuration.BackupLocations -is [hashtable] -and $Configuration.BackupLocations.Count -gt 0) {
            Write-ConsoleBanner -NameText "Defined Backup Jobs" -BannerWidth 78 -CenterText -PrependNewLine
            foreach ($jobNameKey in ($Configuration.BackupLocations.Keys | Sort-Object)) {
                $jobConf = $Configuration.BackupLocations[$jobNameKey]
                $isEnabled = Get-ConfigValue -ConfigObject $jobConf -Key 'Enabled' -DefaultValue $true
                $jobNameColor = if ($isEnabled) { $Global:ColourSuccess } else { $Global:ColourError }
                & $LocalWriteLog -Message ("`n  Job: {0}" -f $jobNameKey) -Level "NONE" -ForegroundColour $jobNameColor
                $sourcePathsDisplay = if ($jobConf.Path -is [array]) { $jobConf.Path -join "; " } else { $jobConf.Path }; & $LocalWriteLog -Message ("    Source(s)      : {0}" -f $sourcePathsDisplay) -Level "NONE"
                if ($jobConf.ContainsKey('TargetNames') -and $jobConf.TargetNames -is [array] -and $jobConf.TargetNames.Count -gt 0) { & $LocalWriteLog -Message ("    Remote Targets : {0}" -f ($jobConf.TargetNames -join ", ")) -Level "NONE" }
                $dependsOn = @(Get-ConfigValue -ConfigObject $jobConf -Key 'DependsOnJobs' -DefaultValue @()); if ($dependsOn.Count -gt 0) { & $LocalWriteLog -Message ("    Depends On     : {0}" -f ($dependsOn -join ", ")) -Level "NONE" }
            }
        }

        if ($Configuration.BackupSets -is [hashtable] -and $Configuration.BackupSets.Count -gt 0) {
            Write-ConsoleBanner -NameText "Defined Backup Sets" -BannerWidth 78 -CenterText -PrependNewLine
            foreach ($setNameKey in ($Configuration.BackupSets.Keys | Sort-Object)) {
                $setConf = $Configuration.BackupSets[$setNameKey]
                & $LocalWriteLog -Message ("`n  Set: {0}" -f $setNameKey) -Level "NONE"
                $jobsInSetDisplay = if ($setConf.JobNames -is [array]) { $setConf.JobNames -join ", " } else { "None listed" }; & $LocalWriteLog -Message ("    Jobs in Set: {0}" -f $jobsInSetDisplay) -Level "NONE"
            }
        }

        Write-ConsoleBanner -NameText "Job Dependency Graph" -BannerWidth 78 -CenterText -PrependNewLine
        try {
            if (Get-Command Get-PoShBackupJobDependencyMap -ErrorAction SilentlyContinue) {
                $dependencyMapData = Get-PoShBackupJobDependencyMap -AllBackupLocations $Configuration.BackupLocations
                $graphLines = Format-DependencyGraphInternal -DependencyMap $dependencyMapData
                foreach ($line in $graphLines) { & $LocalWriteLog -Message $line -Level "NONE" }
            }
            else { & $LocalWriteLog -Message "    (Could not generate graph: Get-PoShBackupJobDependencyMap function not found.)" -Level "NONE" }
        }
        catch { & $LocalWriteLog -Message "    (An error occurred while generating the dependency graph: $($_.Exception.Message))" -Level "NONE" }

        if (Get-Command Invoke-PoShBackupPostRunActionHandler -ErrorAction SilentlyContinue) {
            Write-ConsoleBanner -NameText "Effective Post-Run Action" -BannerWidth 78 -CenterText -PrependNewLine
            $postRunResolution = Invoke-PoShBackupPostRunActionHandler -OverallStatus "SIMULATED_COMPLETE" `
                -CliOverrideSettings $CliOverrideSettingsInternal -SetSpecificPostRunAction $null -JobSpecificPostRunActionForNonSet $null `
                -GlobalConfig $Configuration -IsSimulateMode $true -TestConfigIsPresent $true `
                -Logger $Logger -ResolveOnly
            if ($null -ne $postRunResolution) {
                Write-NameValue "Action" $postRunResolution.Action
                Write-NameValue "Source" $postRunResolution.Source
                if ($postRunResolution.Action -ne 'None') {
                    Write-NameValue "Trigger On" $postRunResolution.TriggerOnStatus
                    Write-NameValue "Delay (seconds)" $postRunResolution.DelaySeconds
                    Write-NameValue "Force Action" $postRunResolution.ForceAction
                }
            }
        }
        else {
            Write-ConsoleBanner -NameText "Effective Post-Run Action" -BannerWidth 78 -CenterText -PrependNewLine
            & $LocalWriteLog -Message "    (Could not be determined as PostRunActionOrchestrator was not available)" -Level "NONE"
        }

        $validationMessages = $ConfigLoadResult.ValidationMessages
        if ($null -eq $validationMessages -or $validationMessages.Count -eq 0) {
            & $LocalWriteLog -Message "`n[SUCCESS] All configuration checks passed." -Level "SUCCESS"
        }
    
        Write-ConsoleBanner -NameText "Configuration Test Mode Finished" -BorderForegroundColor "White" -CenterText -PrependNewLine -AppendNewLine
        return $true
    }
    
    return $false # No diagnostic mode was handled
}

Export-ModuleMember -Function Invoke-PoShBackupDiagnosticMode
