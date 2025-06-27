# Modules\Operations\JobPreProcessor\CredentialAndHookHandler.psm1
<#
.SYNOPSIS
    A sub-module for JobPreProcessor.psm1. Handles password retrieval and hook execution.
.DESCRIPTION
    This module provides the 'Invoke-PoShBackupCredentialAndHookHandling' function. It is
    responsible for preparatory actions that do not modify backup paths. Specifically, it
    calls the PasswordManager to retrieve the archive password and then calls the HookManager
    to execute any configured pre-backup hook scripts.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    26-Jun-2025
    LastModified:   26-Jun-2025
    Purpose:        To isolate password and pre-backup hook logic.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Operations\JobPreProcessor
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Managers\PasswordManager.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Managers\HookManager.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "CredentialAndHookHandler.psm1 FATAL: Could not import a dependent module. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Invoke-PoShBackupCredentialAndHookHandling {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$JobName,
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $true)]
        [ref]$JobReportDataRef,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [string]$ActualConfigFile
    )

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    & $LocalWriteLog -Message "CredentialAndHookHandler: Initialising for job '$JobName'." -Level "DEBUG"
    
    $reportData = $JobReportDataRef.Value
    $plainTextPasswordForJob = $null

    # --- 1. Password Retrieval ---
    $isPasswordRequiredOrConfigured = ($EffectiveJobConfig.ArchivePasswordMethod.ToString().ToUpperInvariant() -ne "NONE") -or $EffectiveJobConfig.UsePassword
    $EffectiveJobConfig.PasswordInUseFor7Zip = $false

    if ($isPasswordRequiredOrConfigured) {
        $passwordParams = @{
            JobConfigForPassword = $EffectiveJobConfig; JobName = $JobName
            GlobalConfig         = $EffectiveJobConfig.GlobalConfigRef # Pass the global config
            IsSimulateMode       = $IsSimulateMode.IsPresent; Logger = $Logger
        }
        $passwordResult = Get-PoShBackupArchivePassword @passwordParams
        $reportData.PasswordSource = $passwordResult.PasswordSource

        if ($null -ne $passwordResult -and (-not [string]::IsNullOrWhiteSpace($passwordResult.PlainTextPassword))) {
            $plainTextPasswordForJob = $passwordResult.PlainTextPassword
            $EffectiveJobConfig.PasswordInUseFor7Zip = $true
        }
        elseif ($isPasswordRequiredOrConfigured -and $EffectiveJobConfig.ArchivePasswordMethod.ToString().ToUpperInvariant() -ne "NONE" -and (-not $IsSimulateMode.IsPresent)) {
            throw "Password was required for job '$JobName' via method '$($EffectiveJobConfig.ArchivePasswordMethod)' but was not provided or was cancelled."
        }
    }
    elseif ($EffectiveJobConfig.ArchivePasswordMethod.ToString().ToUpperInvariant() -eq "NONE") {
        $reportData.PasswordSource = "None (Explicitly Configured)"; $EffectiveJobConfig.PasswordInUseFor7Zip = $false
    }
    
    # --- 2. Pre-Backup Hook Execution ---
    Invoke-PoShBackupHook -ScriptPath $EffectiveJobConfig.PreBackupScriptPath -HookType "PreBackup" `
        -HookParameters @{ JobName = $JobName; Status = "PreBackup"; ConfigFile = $ActualConfigFile; SimulateMode = $IsSimulateMode.IsPresent } `
        -IsSimulateMode:$IsSimulateMode -Logger $Logger

    return @{
        Success                 = $true
        PlainTextPasswordToClear = $plainTextPasswordForJob
    }
}

Export-ModuleMember -Function Invoke-PoShBackupCredentialAndHookHandling
