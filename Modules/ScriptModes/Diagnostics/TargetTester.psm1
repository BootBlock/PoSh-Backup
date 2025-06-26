# Modules\ScriptModes\Diagnostics\TargetTester.psm1
<#
.SYNOPSIS
    A sub-module for Diagnostics.psm1. Handles the `-TestBackupTarget` script mode.
.DESCRIPTION
    This module contains the logic for initiating a connectivity and settings health check
    for a specific remote backup target defined in the configuration. It dynamically loads
    the appropriate target provider module and calls its connectivity test function if it exists.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    26-Jun-2025
    LastModified:   26-Jun-2025
    Purpose:        To handle the -TestBackupTarget diagnostic mode.
    Prerequisites:  PowerShell 5.1+.
#>

# $PSScriptRoot here is Modules\ScriptModes\Diagnostics
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Utils.psm1") -Force -ErrorAction Stop
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Utilities\ConsoleDisplayUtils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Warning "ScriptModes\Diagnostics\TargetTester.psm1: Could not import required modules. Error: $($_.Exception.Message)"
}

function Invoke-PoShBackupTargetTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetName,
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    & $Logger -Message "Diagnostics/TargetTester: Logger active for target '$TargetName'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    Write-ConsoleBanner -NameText "Backup Target Health Check Mode" -CenterText -PrependNewLine

    if (-not ($Configuration.BackupTargets -is [hashtable] -and $Configuration.BackupTargets.ContainsKey($TargetName))) {
        & $LocalWriteLog -Message "  - ERROR: The specified target '$TargetName' was not found in the configuration." -Level "ERROR"
        return
    }

    $targetConfig = $Configuration.BackupTargets[$TargetName]
    $targetType = $targetConfig.Type
    & $LocalWriteLog -Message "  - Testing Target: '$TargetName' (Type: $targetType)" -Level "INFO"

    $providerModuleName = "$targetType.Target.psm1"
    $scriptRootForPaths = $Configuration['_PoShBackup_PSScriptRoot']
    $providerModulePath = Join-Path -Path $scriptRootForPaths -ChildPath "Modules\Targets\$providerModuleName"
    $testFunctionName = "Test-PoShBackupTargetConnectivity"

    if (-not (Test-Path -LiteralPath $providerModulePath -PathType Leaf)) {
        & $LocalWriteLog -Message "  - ERROR: Cannot test target. The provider module '$providerModuleName' was not found at '$providerModulePath'." -Level "ERROR"
        return
    }
    
    try {
        $providerModule = Import-Module -Name $providerModulePath -Force -PassThru -ErrorAction Stop
        $testFunctionCmd = Get-Command -Name $testFunctionName -Module $providerModule.Name -ErrorAction SilentlyContinue

        if (-not $testFunctionCmd) {
            & $LocalWriteLog -Message "  - INFO: The '$targetType' target provider does not support an automated health check." -Level "INFO"
            return
        }

        & $LocalWriteLog -Message "  - Invoking health check..." -Level "DEBUG"
        
        $testParams = @{
            TargetSpecificSettings = $targetConfig.TargetSpecificSettings
            Logger                 = $Logger
            PSCmdlet               = $PSCmdletInstance
        }
        # Pass credentials if the target provider's test function supports it
        if ($targetConfig.ContainsKey('CredentialsSecretName') -and $testFunctionCmd.Parameters.ContainsKey('CredentialsSecretName')) {
            $testParams.CredentialsSecretName = $targetConfig.CredentialsSecretName
        }

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
        & $LocalWriteLog -Message "  - ERROR: An exception occurred while trying to test target '$TargetName'. Error: $($_.Exception.Message)" -Level "ERROR"
    }
    
    & $LocalWriteLog -Message "`n--- Health Check Finished ---" -Level "HEADING"
}

Export-ModuleMember -Function Invoke-PoShBackupTargetTest
