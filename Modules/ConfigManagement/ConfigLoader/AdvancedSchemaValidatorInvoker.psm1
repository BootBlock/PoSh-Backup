# Modules\ConfigManagement\ConfigLoader\AdvancedSchemaValidatorInvoker.psm1
<#
.SYNOPSIS
    Sub-module for ConfigLoader. Handles the conditional invocation of advanced
    schema validation using PoShBackupValidator.psm1.
.DESCRIPTION
    This module contains the 'Invoke-AdvancedSchemaValidationIfEnabled' function.
    It checks if advanced schema validation is enabled in the configuration. If so,
    it attempts to import 'PoShBackupValidator.psm1' and then calls its
    'Invoke-PoShBackupConfigValidation' function to perform detailed schema checks.
    Any validation messages are added to the provided list.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    29-May-2025
    LastModified:   29-May-2025
    Purpose:        Advanced schema validation invocation logic for ConfigLoader.
    Prerequisites:  PowerShell 5.1+.
                    Relies on Utils.psm1 (for Get-ConfigValue).
                    PoShBackupValidator.psm1 must be available in the main Modules directory.
#>

# Explicitly import Utils.psm1 from the main Modules directory.
# $PSScriptRoot here is Modules\ConfigManagement\ConfigLoader.
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\..\Modules\Utils.psm1") -Force -ErrorAction Stop
    # PoShBackupValidator.psm1 is imported conditionally by this module.
}
catch {
    Write-Error "AdvancedSchemaValidatorInvoker.psm1 (ConfigLoader submodule) FATAL: Could not import dependent module Utils.psm1. Error: $($_.Exception.Message)"
    throw
}

#region --- Advanced Schema Validation Invoker Function ---
function Invoke-AdvancedSchemaValidationIfEnabled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration,
        [Parameter(Mandatory = $true)]
        [ref]$ValidationMessagesListRef, # To add error/warning messages
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [string]$MainScriptPSScriptRoot, # Needed to locate PoShBackupValidator.psm1
        [Parameter(Mandatory = $false)]
        [bool]$IsTestConfigMode = $false # For context-specific logging
    )

    & $Logger -Message "ConfigLoader/AdvancedSchemaValidatorInvoker/Invoke-AdvancedSchemaValidationIfEnabled: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = {
        param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour)
        if (-not [string]::IsNullOrWhiteSpace($ForegroundColour)) {
            & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour
        } else {
            & $Logger -Message $Message -Level $Level
        }
    }

    $enableAdvancedValidation = Get-ConfigValue -ConfigObject $Configuration -Key 'EnableAdvancedSchemaValidation' -DefaultValue $false

    if ($enableAdvancedValidation -eq $true) {
        & $LocalWriteLog -Message "[INFO] ConfigLoader/AdvancedSchemaValidatorInvoker: Advanced Schema Validation enabled. Attempting PoShBackupValidator module..." -Level "INFO"
        $validatorModulePath = Join-Path -Path $MainScriptPSScriptRoot -ChildPath "Modules\PoShBackupValidator.psm1"

        if (-not (Test-Path -LiteralPath $validatorModulePath -PathType Leaf)) {
            & $LocalWriteLog -Message "[WARNING] ConfigLoader/AdvancedSchemaValidatorInvoker: PoShBackupValidator.psm1 not found at '$validatorModulePath'. Advanced schema validation skipped." -Level "WARNING"
            $ValidationMessagesListRef.Value.Add("ConfigLoader/AdvancedSchemaValidatorInvoker: Advanced validation enabled, but PoShBackupValidator.psm1 not found at '$validatorModulePath'.")
            return
        }

        try {
            Import-Module -Name $validatorModulePath -Force -ErrorAction Stop
            & $LocalWriteLog -Message "  - ConfigLoader/AdvancedSchemaValidatorInvoker: PoShBackupValidator module loaded. Performing schema validation..." -Level "DEBUG"

            $validatorParams = @{
                ConfigurationToValidate = $Configuration
                ValidationMessagesListRef = $ValidationMessagesListRef # Pass the ref object directly
            }
            # Check if the loaded Invoke-PoShBackupConfigValidation accepts -Logger
            $validatorCmd = Get-Command Invoke-PoShBackupConfigValidation -Module (Get-Module -Name PoShBackupValidator) -ErrorAction SilentlyContinue
            if ($null -ne $validatorCmd -and $validatorCmd.Parameters.ContainsKey('Logger')) {
                $validatorParams.Logger = $Logger
            }

            Invoke-PoShBackupConfigValidation @validatorParams

            if ($IsTestConfigMode -and $ValidationMessagesListRef.Value.Count -eq 0) {
                # This specific log might be redundant if Invoke-PoShBackupConfigValidation logs its own success.
                # However, keeping it for clarity from the invoker's perspective.
                & $LocalWriteLog -Message "[SUCCESS] ConfigLoader/AdvancedSchemaValidatorInvoker: Advanced schema validation completed (no new schema errors found by validator)." -Level "CONFIG_TEST"
            }
            elseif ($ValidationMessagesListRef.Value.Count -gt 0) {
                # This message might also be redundant if the validator itself logs errors.
                # The key is that $ValidationMessagesListRef is populated.
                & $LocalWriteLog -Message "[WARNING] ConfigLoader/AdvancedSchemaValidatorInvoker: Advanced schema validation reported issues (see detailed messages)." -Level "WARNING"
            }
        }
        catch {
            $errMsg = "ConfigLoader/AdvancedSchemaValidatorInvoker: Could not load/execute PoShBackupValidator. Advanced schema validation skipped. Error: $($_.Exception.Message)"
            & $LocalWriteLog -Message "[WARNING] $errMsg" -Level "WARNING"
            $ValidationMessagesListRef.Value.Add($errMsg)
        }
    }
    else {
        if ($IsTestConfigMode) {
            & $LocalWriteLog -Message "[INFO] ConfigLoader/AdvancedSchemaValidatorInvoker: Advanced Schema Validation disabled ('EnableAdvancedSchemaValidation' is `$false or missing)." -Level "INFO"
        }
    }
}
#endregion

Export-ModuleMember -Function Invoke-AdvancedSchemaValidationIfEnabled
