# Modules\ScriptModes\PreFlightChecker\RemoteTargetChecker.psm1
<#
.SYNOPSIS
    A sub-module for PreFlightChecker.psm1. Handles validation of remote target connectivity.
.DESCRIPTION
    This module provides the 'Test-PreFlightRemoteTarget' function, which iterates through all
    remote targets configured for a backup job. For each target, it dynamically loads the
    appropriate provider module (e.g., UNC.Target.psm1, SFTP.Target.psm1) and invokes that
    provider's specific 'Test-PoShBackupTargetConnectivity' function.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    01-Jul-2025
    LastModified:   01-Jul-2025
    Purpose:        To isolate the remote target pre-flight check logic.
    Prerequisites:  PowerShell 5.1+.
#>

function Test-PreFlightRemoteTarget {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveConfig,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour) & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour }
    $checkSuccess = $true
    $scriptRootForPaths = $EffectiveConfig.GlobalConfigRef['_PoShBackup_PSScriptRoot']

    & $LocalWriteLog -Message "`n  4. Checking Remote Target Connectivity..." -Level "HEADING"
    if ($EffectiveConfig.ResolvedTargetInstances.Count -gt 0) {
        foreach ($targetInstance in $EffectiveConfig.ResolvedTargetInstances) {
            $targetName = $targetInstance._TargetInstanceName_
            $targetType = $targetInstance.Type

            & $LocalWriteLog -Message "    - Testing Target '$targetName' (Type: $targetType)..." -Level "NONE"

            $providerModuleName = "$targetType.Target.psm1"
            $providerModulePath = Join-Path -Path $scriptRootForPaths -ChildPath "Modules\Targets\$providerModuleName"
            $testFunctionName = "Test-PoShBackupTargetConnectivity"

            if (-not (Test-Path -LiteralPath $providerModulePath -PathType Leaf)) {
                & $LocalWriteLog -Message "      - [FAIL] Target provider module '$providerModuleName' not found." -Level "ERROR"
                $checkSuccess = $false
                continue
            }
            try {
                $providerModule = Import-Module -Name $providerModulePath -Force -PassThru -ErrorAction Stop
                $testFunctionCmd = Get-Command -Name $testFunctionName -Module $providerModule.Name -ErrorAction SilentlyContinue

                if (-not $testFunctionCmd) {
                    & $LocalWriteLog -Message "      - [INFO] No automated connectivity test is available for the '$targetType' provider." -Level "INFO"
                    continue
                }

                $testParams = @{
                    TargetSpecificSettings = $targetInstance.TargetSpecificSettings
                    Logger                 = $Logger
                    PSCmdlet               = $PSCmdletInstance
                }
                if ($targetInstance.ContainsKey('CredentialsSecretName') -and $testFunctionCmd.Parameters.ContainsKey('CredentialsSecretName')) {
                    $testParams.CredentialsSecretName = $targetInstance.CredentialsSecretName
                }

                $testResult = & $testFunctionCmd @testParams

                if ($null -ne $testResult -and $testResult -is [hashtable] -and $testResult.ContainsKey('Success') -and $testResult.Success) {
                    & $LocalWriteLog -Message "      - [PASS] Connectivity test successful. Details: $($testResult.Message)" -Level "SUCCESS"
                }
                else {
                    $errorMessage = if ($null -ne $testResult -and $testResult.ContainsKey('Message')) { $testResult.Message } else { "The connectivity test returned an unexpected result." }
                    & $LocalWriteLog -Message "      - [FAIL] Connectivity test failed. Details: $errorMessage" -Level "ERROR"
                    $checkSuccess = $false
                }
            }
            catch {
                & $LocalWriteLog -Message "    - [FAIL] Target '$targetName': An error occurred while trying to run its connectivity test. Error: $($_.Exception.Message)" -Level "ERROR"
                $checkSuccess = $false
            }
        }
    }
    else {
        & $LocalWriteLog -Message "    - [INFO] No remote targets are configured for this job." -Level "INFO"
    }

    return $checkSuccess
}

Export-ModuleMember -Function Test-PreFlightRemoteTarget
