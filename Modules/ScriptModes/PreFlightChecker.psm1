# Modules\ScriptModes\PreFlightChecker.psm1
<#
.SYNOPSIS
    Contains the core logic for performing pre-flight environmental checks for PoSh-Backup jobs.
.DESCRIPTION
    This module is a sub-component of Diagnostics.psm1. Its main function,
    Invoke-PoShBackupPreFlightCheck, iterates through a given list of backup jobs and performs
    a series of validation checks to ensure the environment is ready for a successful backup.

    The checks performed for each job include:
    - Source Path Readability: Verifies that all configured source paths exist and are accessible.
    - Destination Path Writability: Verifies that the local destination/staging directory exists
      and that the script has permissions to write to it.
    - Remote Target Connectivity: For each configured remote target, it invokes the target's
      own connectivity test function (e.g., Test-PoShBackupTargetConnectivity).
    - Hook Script Existence: Verifies that any configured pre- or post-backup hook scripts exist at
      their specified paths.

    The results of all checks are printed to the console in a structured report.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.1 # Fixed missing ConfigManager dependency.
    DateCreated:    20-Jun-2025
    LastModified:   20-Jun-2025
    Purpose:        To contain the core pre-flight check logic.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\ScriptModes\
try {
    # Utils is needed for Get-ConfigValue
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Modules\Utils.psm1") -Force -ErrorAction Stop
    # NEW: Import ConfigManager to get the effective config builder function
    Import-Module -Name (Join-Path $PSScriptRoot "..\Core\ConfigManager.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Warning "ScriptModes\PreFlightChecker.psm1: Could not import required modules. Error: $($_.Exception.Message)"
}
#endregion

function Invoke-PoShBackupPreFlightCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$JobsToCheck,
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,
        [Parameter(Mandatory = $true)]
        [hashtable]$CliOverrideSettings,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
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

    $overallSuccess = $true
    $scriptRootForPaths = $Configuration['_PoShBackup_PSScriptRoot']

    foreach ($jobName in $JobsToCheck) {
        if (-not $Configuration.BackupLocations.ContainsKey($jobName)) {
            & $LocalWriteLog -Message "Pre-Flight Check for job '$jobName' SKIPPED as it was not found in the configuration." -Level "WARNING"
            continue
        }

        $jobConfig = $Configuration.BackupLocations[$jobName]
        if ((Get-ConfigValue -ConfigObject $jobConfig -Key 'Enabled' -DefaultValue $true) -ne $true) {
            & $LocalWriteLog -Message "Pre-Flight Check for job '$jobName' SKIPPED as it is disabled in the configuration." -Level "INFO"
            continue
        }

        Write-ConsoleBanner -NameText "Pre-Flight Check For Job" -ValueText $jobName -CenterText -PrependNewLine

        try {
            # Get effective config to ensure all paths and settings are resolved
            $dummyReportDataRef = [ref]@{ JobName = $jobName }
            $effectiveConfigParams = @{
                JobConfig        = $jobConfig
                GlobalConfig     = $Configuration
                CliOverrides     = $CliOverrideSettings
                JobReportDataRef = $dummyReportDataRef
                Logger           = $Logger
            }
            $effectiveConfig = Get-PoShBackupJobEffectiveConfiguration @effectiveConfigParams
            $jobHadFailure = $false

            # 1. Check Source Paths
            & $LocalWriteLog -Message "`n  1. Checking Source Paths..." -Level "HEADING"
            if ($effectiveConfig.SourceIsVMName -eq $true) {
                # Special handling for Hyper-V VM backups
                $vmName = ($effectiveConfig.OriginalSourcePath | Select-Object -First 1)
                & $LocalWriteLog -Message "    - This is a VM backup job. Checking for VM existence..." -Level "DEBUG"
                if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
                    & $LocalWriteLog -Message "    - [PASS] Source VM is accessible: '$vmName'" -Level "SUCCESS"
                }
                else {
                    & $LocalWriteLog -Message "    - [FAIL] Source VM not found or Hyper-V module unavailable: '$vmName'" -Level "ERROR"
                    $jobHadFailure = $true
                }
                $subPaths = @($effectiveConfig.OriginalSourcePath | Select-Object -Skip 1)
                if ($subPaths.Count -gt 0) {
                    & $LocalWriteLog -Message "    - [INFO] Sub-paths within the VM will not be checked during pre-flight." -Level "INFO"
                }
            }
            else {
                # Standard file/folder path checking
                $sourcePaths = if ($effectiveConfig.OriginalSourcePath -is [array]) { $effectiveConfig.OriginalSourcePath } else { @($effectiveConfig.OriginalSourcePath) }
                foreach ($path in $sourcePaths) {
                    if (Test-Path -Path $path) {
                        & $LocalWriteLog -Message "    - [PASS] Source path is accessible: '$path'" -Level "SUCCESS"
                    }
                    else {
                        & $LocalWriteLog -Message "    - [FAIL] Source path not found or inaccessible: '$path'" -Level "ERROR"
                        $jobHadFailure = $true
                    }
                }
            }

            # 2. Check Destination Path
            & $LocalWriteLog -Message "`n  2. Checking Local Destination/Staging Path..." -Level "HEADING"
            $destDir = $effectiveConfig.DestinationDir
            if ([string]::IsNullOrWhiteSpace($destDir)) {
                & $LocalWriteLog -Message "    - [FAIL] Destination directory is not defined for this job." -Level "ERROR"
                $jobHadFailure = $true
            }
            else {
                if (Test-Path -LiteralPath $destDir -PathType Container) {
                    & $LocalWriteLog -Message "    - [PASS] Destination directory exists: '$destDir'" -Level "SUCCESS"
                    $tempFile = Join-Path -Path $destDir -ChildPath "posh-backup-write-test-$([guid]::NewGuid()).tmp"
                    try {
                        "test" | Set-Content -LiteralPath $tempFile -ErrorAction Stop
                        & $LocalWriteLog -Message "    - [PASS] Write permissions are confirmed for '$destDir'." -Level "SUCCESS"
                    }
                    catch {
                        & $LocalWriteLog -Message "    - [FAIL] Write permissions are NOT available for '$destDir'. Error: $($_.Exception.Message)" -Level "ERROR"
                        $jobHadFailure = $true
                    }
                    finally {
                        if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }
                    }
                }
                else {
                    & $LocalWriteLog -Message "    - [FAIL] Destination directory does not exist: '$destDir'" -Level "ERROR"
                    $jobHadFailure = $true
                }
            }

            # 3. Check Hook Scripts
            & $LocalWriteLog -Message "`n  3. Checking Hook Script Paths..." -Level "HEADING"
            $hookScripts = @{
                PreBackupScriptPath           = $effectiveConfig.PreBackupScriptPath
                PostLocalArchiveScriptPath    = $effectiveConfig.PostLocalArchiveScriptPath
                PostBackupScriptOnSuccessPath = $effectiveConfig.PostBackupScriptOnSuccessPath
                PostBackupScriptOnFailurePath = $effectiveConfig.PostBackupScriptOnFailurePath
                PostBackupScriptAlwaysPath    = $effectiveConfig.PostBackupScriptAlwaysPath
            }
            $hooksFound = $false
            foreach ($hook in $hookScripts.GetEnumerator()) {
                if (-not [string]::IsNullOrWhiteSpace($hook.Value)) {
                    $hooksFound = $true
                    if (Test-Path -LiteralPath $hook.Value -PathType Leaf) {
                        & $LocalWriteLog -Message "    - [PASS] Hook script '$($hook.Name)' found at: '$($hook.Value)'" -Level "SUCCESS"
                    }
                    else {
                        & $LocalWriteLog -Message "    - [FAIL] Hook script '$($hook.Name)' not found at: '$($hook.Value)'" -Level "ERROR"
                        $jobHadFailure = $true
                    }
                }
            }
            if (-not $hooksFound) { & $LocalWriteLog -Message "    - [INFO] No hook scripts are configured for this job." -Level "INFO" }


            # 4. Check Remote Targets
            & $LocalWriteLog -Message "`n  4. Checking Remote Target Connectivity..." -Level "HEADING"
            if ($effectiveConfig.ResolvedTargetInstances.Count -gt 0) {
                foreach ($targetInstance in $effectiveConfig.ResolvedTargetInstances) {
                    $targetName = $targetInstance._TargetInstanceName_
                    $targetType = $targetInstance.Type
                    $providerModuleName = "$targetType.Target.psm1"
                    $providerModulePath = Join-Path -Path $scriptRootForPaths -ChildPath "Modules\Targets\$providerModuleName"
                    $testFunctionName = "Test-PoShBackupTargetConnectivity"
                    
                    if (-not (Test-Path -LiteralPath $providerModulePath -PathType Leaf)) {
                        & $LocalWriteLog -Message "    - [FAIL] Target '$targetName': Provider module '$providerModuleName' not found." -Level "ERROR"
                        $jobHadFailure = $true
                        continue
                    }
                    try {
                        $providerModule = Import-Module -Name $providerModulePath -Force -PassThru -ErrorAction Stop
                        $testFunctionCmd = Get-Command -Name $testFunctionName -Module $providerModule.Name -ErrorAction SilentlyContinue

                        if (-not $testFunctionCmd) {
                            & $LocalWriteLog -Message "    - [INFO] Target '$targetName' (Type: $targetType): No automated connectivity test is available for this provider." -Level "INFO"
                            continue
                        }
                        
                        & $LocalWriteLog -Message "    - Testing Target '$targetName' (Type: $targetType)..." -Level "NONE"
                        $testParams = @{
                            TargetSpecificSettings = $targetInstance.TargetSpecificSettings
                            Logger                 = $Logger
                            PSCmdlet               = $PSCmdletInstance
                        }
                        # Pass credentials if the target provider's test function supports it
                        if ($targetInstance.ContainsKey('CredentialsSecretName') -and $testFunctionCmd.Parameters.ContainsKey('CredentialsSecretName')) {
                            $testParams.CredentialsSecretName = $targetInstance.CredentialsSecretName
                        }

                        $testResult = & $testFunctionCmd @testParams
                        if ($testResult.Success) {
                            & $LocalWriteLog -Message "      - [PASS] Connectivity test successful. Details: $($testResult.Message)" -Level "SUCCESS"
                        }
                        else {
                            & $LocalWriteLog -Message "      - [FAIL] Connectivity test failed. Details: $($testResult.Message)" -Level "ERROR"
                            $jobHadFailure = $true
                        }
                    }
                    catch {
                        & $LocalWriteLog -Message "    - [FAIL] Target '$targetName': An error occurred while trying to run its connectivity test. Error: $($_.Exception.Message)" -Level "ERROR"
                        $jobHadFailure = $true
                    }
                }
            }
            else {
                & $LocalWriteLog -Message "    - [INFO] No remote targets are configured for this job." -Level "INFO"
            }

            # Final status for this job
            if ($jobHadFailure) {
                $overallSuccess = $false
                & $LocalWriteLog -Message "`n[FAIL] Pre-Flight Check for job '$jobName' completed with one or more failures." -Level "ERROR"
            }
            else {
                & $LocalWriteLog -Message "`n[PASS] Pre-Flight Check for job '$jobName' completed successfully." -Level "SUCCESS"
            }

        }
        catch {
            & $LocalWriteLog -Message "[FATAL] An unexpected error occurred during pre-flight check for job '$jobName'. Error: $($_.Exception.Message)" -Level "ERROR"
            $overallSuccess = $false
        }
    }

    return $overallSuccess
}

Export-ModuleMember -Function Invoke-PoShBackupPreFlightCheck
