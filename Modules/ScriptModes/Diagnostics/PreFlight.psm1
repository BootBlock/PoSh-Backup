# Modules\ScriptModes\Diagnostics\PreFlight.psm1
<#
.SYNOPSIS
    A sub-module for Diagnostics.psm1. Handles the `-PreFlightCheck` script mode.
.DESCRIPTION
    This module contains the logic for performing a pre-flight environmental check for one or
    more backup jobs. It verifies source path accessibility, destination writability, remote
    target connectivity, and hook script existence to identify potential issues before a
    real backup run is attempted.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    26-Jun-2025
    LastModified:   26-Jun-2025
    Purpose:        To handle the -PreFlightCheck diagnostic mode.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\ScriptModes\Diagnostics
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Core\ConfigManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "TargetTester.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Utilities\ConsoleDisplayUtils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Warning "ScriptModes\Diagnostics\PreFlight.psm1: Could not import required modules. Error: $($_.Exception.Message)"
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

    & $Logger -Message "Diagnostics/PreFlight: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    $overallSuccess = $true

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
        $jobHadFailure = $false

        try {
            $dummyReportDataRef = [ref]@{ JobName = $jobName }
            $effectiveConfig = Get-PoShBackupJobEffectiveConfiguration -JobConfig $jobConfig -GlobalConfig $Configuration -CliOverrides $CliOverrideSettings -JobReportDataRef $dummyReportDataRef -Logger $Logger
            
            # 1. Check Source Paths
            & $LocalWriteLog -Message "`n  1. Checking Source Paths..." -Level "HEADING"
            if ($effectiveConfig.SourceIsVMName -eq $true) {
                $vmName = ($effectiveConfig.OriginalSourcePath | Select-Object -First 1)
                & $LocalWriteLog -Message "    - This is a VM backup job. Checking for VM existence..." -Level "DEBUG"
                if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) { & $LocalWriteLog "    - [PASS] Source VM is accessible: '$vmName'" "SUCCESS" }
                else { & $LocalWriteLog "    - [FAIL] Source VM not found or Hyper-V module unavailable: '$vmName'" "ERROR"; $jobHadFailure = $true }
                if (@($effectiveConfig.OriginalSourcePath).Count -gt 1) { & $LocalWriteLog "    - [INFO] Sub-paths within the VM will not be checked during pre-flight." "INFO" }
            } else {
                $sourcePaths = if ($effectiveConfig.OriginalSourcePath -is [array]) { $effectiveConfig.OriginalSourcePath } else { @($effectiveConfig.OriginalSourcePath) }
                foreach ($path in $sourcePaths) {
                    if (Test-Path -Path $path) { & $LocalWriteLog "    - [PASS] Source path is accessible: '$path'" "SUCCESS" }
                    else { & $LocalWriteLog "    - [FAIL] Source path not found or inaccessible: '$path'" "ERROR"; $jobHadFailure = $true }
                }
            }

            # 2. Check Destination Path
            & $LocalWriteLog -Message "`n  2. Checking Local Destination/Staging Path..." -Level "HEADING"
            $destDir = $effectiveConfig.DestinationDir
            if ([string]::IsNullOrWhiteSpace($destDir)) { & $LocalWriteLog "    - [FAIL] Destination directory is not defined for this job." "ERROR"; $jobHadFailure = $true }
            else {
                if (Test-Path -LiteralPath $destDir -PathType Container) {
                    & $LocalWriteLog "    - [PASS] Destination directory exists: '$destDir'" "SUCCESS"
                    $tempFile = Join-Path -Path $destDir -ChildPath "posh-backup-write-test-$([guid]::NewGuid()).tmp"
                    try { "test" | Set-Content -LiteralPath $tempFile -ErrorAction Stop; & $LocalWriteLog "    - [PASS] Write permissions are confirmed for '$destDir'." "SUCCESS" }
                    catch { & $LocalWriteLog "    - [FAIL] Write permissions are NOT available for '$destDir'. Error: $($_.Exception.Message)" "ERROR"; $jobHadFailure = $true }
                    finally { if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue } }
                } else { & $LocalWriteLog "    - [FAIL] Destination directory does not exist: '$destDir'" "ERROR"; $jobHadFailure = $true }
            }

            # 3. Check Hook Scripts
            & $LocalWriteLog -Message "`n  3. Checking Hook Script Paths..." -Level "HEADING"
            $hookScripts = @{
                PreBackupScriptPath = $effectiveConfig.PreBackupScriptPath; PostLocalArchiveScriptPath = $effectiveConfig.PostLocalArchiveScriptPath
                PostBackupScriptOnSuccessPath = $effectiveConfig.PostBackupScriptOnSuccessPath; PostBackupScriptOnFailurePath = $effectiveConfig.PostBackupScriptOnFailurePath
                PostBackupScriptAlwaysPath = $effectiveConfig.PostBackupScriptAlwaysPath
            }
            $hooksFound = $false
            foreach ($hook in $hookScripts.GetEnumerator()) {
                if (-not [string]::IsNullOrWhiteSpace($hook.Value)) {
                    $hooksFound = $true
                    if (Test-Path -LiteralPath $hook.Value -PathType Leaf) { & $LocalWriteLog "    - [PASS] Hook script '$($hook.Name)' found at: '$($hook.Value)'" "SUCCESS" }
                    else { & $LocalWriteLog "    - [FAIL] Hook script '$($hook.Name)' not found at: '$($hook.Value)'" "ERROR"; $jobHadFailure = $true }
                }
            }
            if (-not $hooksFound) { & $LocalWriteLog "    - [INFO] No hook scripts are configured for this job." "INFO" }

            # 4. Check Remote Targets
            & $LocalWriteLog -Message "`n  4. Checking Remote Target Connectivity..." -Level "HEADING"
            if ($effectiveConfig.ResolvedTargetInstances.Count -gt 0) {
                foreach ($targetInstance in $effectiveConfig.ResolvedTargetInstances) {
                    $testResult = Invoke-PoShBackupTargetTest -TargetName $targetInstance._TargetInstanceName_ `
                        -Configuration $Configuration `
                        -Logger $Logger `
                        -PSCmdletInstance $PSCmdletInstance
                    
                    if ($null -ne $testResult -and $testResult -is [hashtable] -and $testResult.ContainsKey('Success') -and $testResult.Success -ne $true) {
                        $jobHadFailure = $true
                    }
                    elseif ($null -eq $testResult -or -not ($testResult -is [hashtable])) {
                        $jobHadFailure = $true
                    }
                }
            } else { & $LocalWriteLog "    - [INFO] No remote targets are configured for this job." "INFO" }

            if ($jobHadFailure) { $overallSuccess = $false; & $LocalWriteLog "`n[FAIL] Pre-Flight Check for job '$jobName' completed with one or more failures." "ERROR" }
            else { & $LocalWriteLog "`n[PASS] Pre-Flight Check for job '$jobName' completed successfully." "SUCCESS" }
        } catch {
            & $LocalWriteLog "[FATAL] An unexpected error occurred during pre-flight check for job '$jobName'. Error: $($_.Exception.Message)" "ERROR"
            $overallSuccess = $false
        }
    }
    return $overallSuccess
}


Export-ModuleMember -Function Invoke-PoShBackupPreFlightCheck
