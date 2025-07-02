# Modules\ScriptModes\PreFlightChecker.psm1
<#
.SYNOPSIS
    Acts as a facade to orchestrate pre-flight environmental checks for PoSh-Backup jobs.
.DESCRIPTION
    This module is a sub-component of Diagnostics.psm1. Its main function,
    Invoke-PoShBackupPreFlightCheck, iterates through a given list of backup jobs and performs
    a series of validation checks by lazy-loading and calling specialised sub-modules for each task:
    - SourcePathChecker.psm1
    - DestinationPathChecker.psm1
    - HookScriptChecker.psm1
    - RemoteTargetChecker.psm1

    The results of all checks are aggregated to provide a final pass/fail status for each job.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.1.0 # Refactored to lazy-load sub-modules.
    DateCreated:    20-Jun-2025
    LastModified:   02-Jul-2025
    Purpose:        To orchestrate the core pre-flight check logic.
    Prerequisites:  PowerShell 5.1+.
#>

# No eager module imports are needed here. They will be lazy-loaded.

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

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour) & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour }
    $overallSuccess = $true
    $preFlightSubModulePath = Join-Path -Path $PSScriptRoot -ChildPath "PreFlightChecker"

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
            # Core modules are needed to resolve the effective config first.
            Import-Module -Name (Join-Path $PSScriptRoot "..\Core\ConfigManager.psm1") -Force -ErrorAction Stop

            $dummyReportDataRef = [ref]@{ JobName = $jobName }
            $effectiveConfig = Get-PoShBackupJobEffectiveConfiguration -JobConfig $jobConfig -GlobalConfig $Configuration -CliOverrides $CliOverrideSettings -JobReportDataRef $dummyReportDataRef -Logger $Logger

            # --- Orchestrate calls to sub-module checkers with lazy loading ---
            try {
                Import-Module -Name (Join-Path $preFlightSubModulePath "SourcePathChecker.psm1") -Force -ErrorAction Stop
                if (-not (Test-PreFlightSourcePath -EffectiveConfig $effectiveConfig -Logger $Logger)) { $jobHadFailure = $true }
            } catch { throw "Failed to load SourcePathChecker module. Error: $($_.Exception.Message)" }

            try {
                Import-Module -Name (Join-Path $preFlightSubModulePath "DestinationPathChecker.psm1") -Force -ErrorAction Stop
                if (-not (Test-PreFlightDestinationPath -EffectiveConfig $effectiveConfig -Logger $Logger)) { $jobHadFailure = $true }
            } catch { throw "Failed to load DestinationPathChecker module. Error: $($_.Exception.Message)" }

            try {
                Import-Module -Name (Join-Path $preFlightSubModulePath "HookScriptChecker.psm1") -Force -ErrorAction Stop
                if (-not (Test-PreFlightHookScript -EffectiveConfig $effectiveConfig -Logger $Logger)) { $jobHadFailure = $true }
            } catch { throw "Failed to load HookScriptChecker module. Error: $($_.Exception.Message)" }

            try {
                Import-Module -Name (Join-Path $preFlightSubModulePath "RemoteTargetChecker.psm1") -Force -ErrorAction Stop
                if (-not (Test-PreFlightRemoteTarget -EffectiveConfig $effectiveConfig -Logger $Logger -PSCmdletInstance $PSCmdletInstance)) { $jobHadFailure = $true }
            } catch { throw "Failed to load RemoteTargetChecker module. Error: $($_.Exception.Message)" }

            # Final status for this job
            if ($jobHadFailure) {
                $overallSuccess = $false
                & $LocalWriteLog "`n[FAIL] Pre-Flight Check for job '$jobName' completed with one or more failures." "ERROR"
            }
            else {
                & $LocalWriteLog "`n[PASS] Pre-Flight Check for job '$jobName' completed successfully." "SUCCESS"
            }
        }
        catch {
            & $LocalWriteLog -Message "[FATAL] An unexpected error occurred during pre-flight check for job '$jobName'. Error: $($_.Exception.Message)" -Level "ERROR"
            & $LocalWriteLog -Message "ADVICE: This may be due to a missing core module (like ConfigManager) or a sub-module in 'Modules\ScriptModes\PreFlightChecker\'." -Level "ADVICE"
            $overallSuccess = $false
        }
    }

    return $overallSuccess
}


Export-ModuleMember -Function Invoke-PoShBackupPreFlightCheck
