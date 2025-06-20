# Modules\Utilities\ArgumentCompleters.psm1
<#
.SYNOPSIS
    Provides argument completer functions for PoSh-Backup's command-line parameters.
.DESCRIPTION
    This module contains functions designed to be used with PowerShell's [ArgumentCompleter]
    attribute. It silently loads the PoSh-Backup configuration to provide dynamic,
    context-aware tab completion for parameters like -BackupLocationName and -RunSet.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.2.1 # Added completer for -VerificationJobName.
    DateCreated:    15-Jun-2025
    LastModified:   20-Jun-2025
    Purpose:        To provide CLI tab-completion for PoSh-Backup parameters.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Private Helper: Load Config for Completion ---
function Get-PoShBackupConfigForCompletionInternal {
    param(
        [string]$CommandPath
    )
    # This is a lightweight, silent config loader specifically for argument completion.
    # It does not log or perform validation.
    try {
        $scriptRoot = Split-Path -Path $CommandPath -Parent
        if ([string]::IsNullOrWhiteSpace($scriptRoot)) { return $null }

        $defaultConfigPath = Join-Path -Path $scriptRoot -ChildPath "Config\Default.psd1"
        $userConfigPath = Join-Path -Path $scriptRoot -ChildPath "Config\User.psd1"

        if (-not (Test-Path -LiteralPath $defaultConfigPath -PathType Leaf)) { return $null }

        $baseConfig = Import-PowerShellDataFile -LiteralPath $defaultConfigPath
        if (Test-Path -LiteralPath $userConfigPath -PathType Leaf) {
            $userConfig = Import-PowerShellDataFile -LiteralPath $userConfigPath
            if ($null -ne $userConfig -and $userConfig -is [hashtable]) {
                # Simple overwrite, no deep merge needed for just getting top-level keys.
                $userConfig.GetEnumerator() | ForEach-Object { $baseConfig[$_.Name] = $_.Value }
            }
        }
        return $baseConfig
    }
    catch {
        # Silently fail, completion just won't work.
        return $null
    }
}
#endregion

#region --- Exported Completer Functions ---
function Get-PoShBackupJobNameCompletion {
    [CmdletBinding()]
    param(
        [string]$commandName,
        [string]$parameterName,
        [string]$wordToComplete,
        [System.Management.Automation.Language.CommandAst]$commandAst,
        [hashtable]$fakeBoundParameters
    )

    # Acknowledge unused parameters required by the ArgumentCompleter signature to satisfy PSScriptAnalyzer.
    $null = $commandName
    $null = $parameterName
    $null = $fakeBoundParameters

    $config = Get-PoShBackupConfigForCompletionInternal -CommandPath $commandAst.CommandElements[0].Value
    if ($null -eq $config -or -not ($config.BackupLocations -is [hashtable])) { return }

    $jobNames = $config.BackupLocations.Keys
    $matchingJobs = $jobNames | Where-Object { $_ -like "$wordToComplete*" } | Sort-Object

    foreach ($job in $matchingJobs) {
        $toolTip = "Backup job defined in configuration."
        [System.Management.Automation.CompletionResult]::new("'$job'", $job, 'ParameterValue', $toolTip)
    }
}

function Get-PoShBackupSetNameCompletion {
    [CmdletBinding()]
    param(
        [string]$commandName,
        [string]$parameterName,
        [string]$wordToComplete,
        [System.Management.Automation.Language.CommandAst]$commandAst,
        [hashtable]$fakeBoundParameters
    )

    # Acknowledge unused parameters required by the ArgumentCompleter signature to satisfy PSScriptAnalyzer.
    $null = $commandName
    $null = $parameterName
    $null = $fakeBoundParameters

    $config = Get-PoShBackupConfigForCompletionInternal -CommandPath $commandAst.CommandElements[0].Value
    if ($null -eq $config -or -not ($config.BackupSets -is [hashtable])) { return }

    $setNames = $config.BackupSets.Keys
    $matchingSets = $setNames | Where-Object { $_ -like "$wordToComplete*" } | Sort-Object

    foreach ($set in $matchingSets) {
        $toolTip = "Backup set defined in configuration."
        [System.Management.Automation.CompletionResult]::new("'$set'", $set, 'ParameterValue', $toolTip)
    }
}

function Get-PoShBackupTargetNameCompletion {
    [CmdletBinding()]
    param(
        [string]$commandName,
        [string]$parameterName,
        [string]$wordToComplete,
        [System.Management.Automation.Language.CommandAst]$commandAst,
        [hashtable]$fakeBoundParameters
    )

    # Acknowledge unused parameters required by the ArgumentCompleter signature.
    $null = $commandName
    $null = $parameterName
    $null = $fakeBoundParameters

    $config = Get-PoShBackupConfigForCompletionInternal -CommandPath $commandAst.CommandElements[0].Value
    if ($null -eq $config -or -not ($config.BackupTargets -is [hashtable])) { return }

    $targetNames = $config.BackupTargets.Keys
    $matchingTargets = $targetNames | Where-Object { $_ -like "$wordToComplete*" } | Sort-Object

    foreach ($target in $matchingTargets) {
        $toolTip = "Backup Target defined in configuration."
        [System.Management.Automation.CompletionResult]::new("'$target'", $target, 'ParameterValue', $toolTip)
    }
}
#endregion

function Get-PoShBackupVerificationJobNameCompletion {
    [CmdletBinding()]
    param(
        [string]$commandName,
        [string]$parameterName,
        [string]$wordToComplete,
        [System.Management.Automation.Language.CommandAst]$commandAst,
        [hashtable]$fakeBoundParameters
    )

    # Acknowledge unused parameters
    $null = $commandName, $parameterName, $fakeBoundParameters

    $config = Get-PoShBackupConfigForCompletionInternal -CommandPath $commandAst.CommandElements[0].Value
    if ($null -eq $config -or -not ($config.VerificationJobs -is [hashtable])) { return }

    $vjobNames = $config.VerificationJobs.Keys
    $matchingVJobs = $vjobNames | Where-Object { $_ -like "$wordToComplete*" } | Sort-Object

    foreach ($vjob in $matchingVJobs) {
        $toolTip = "Verification job defined in configuration."
        [System.Management.Automation.CompletionResult]::new("'$vjob'", $vjob, 'ParameterValue', $toolTip)
    }
}

Export-ModuleMember -Function Get-PoShBackupJobNameCompletion, Get-PoShBackupSetNameCompletion, Get-PoShBackupTargetNameCompletion, Get-PoShBackupVerificationJobNameCompletion
