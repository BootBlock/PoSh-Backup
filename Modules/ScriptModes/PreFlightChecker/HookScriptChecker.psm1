# Modules\ScriptModes\PreFlightChecker\HookScriptChecker.psm1
<#
.SYNOPSIS
    A sub-module for PreFlightChecker.psm1. Handles validation of hook script paths.
.DESCRIPTION
    This module provides the 'Test-PreFlightHookScript' function, which verifies that any
    pre- or post-backup hook scripts configured for a backup job exist at their specified paths.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    01-Jul-2025
    LastModified:   01-Jul-2025
    Purpose:        To isolate the hook script path pre-flight check logic.
    Prerequisites:  PowerShell 5.1+.
#>

function Test-PreFlightHookScript {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveConfig,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "HookScriptChecker: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour) & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour }
    $checkSuccess = $true

    & $LocalWriteLog -Message "`n  3. Checking Hook Script Paths..." -Level "HEADING"
    $hookScripts = @{
        PreBackupScriptPath           = $EffectiveConfig.PreBackupScriptPath
        PostLocalArchiveScriptPath    = $EffectiveConfig.PostLocalArchiveScriptPath
        PostBackupScriptOnSuccessPath = $EffectiveConfig.PostBackupScriptOnSuccessPath
        PostBackupScriptOnFailurePath = $EffectiveConfig.PostBackupScriptOnFailurePath
        PostBackupScriptAlwaysPath    = $EffectiveConfig.PostBackupScriptAlwaysPath
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
                $adviceMessage = "ADVICE: Ensure the file path is correct in your configuration and the script file exists."
                & $LocalWriteLog -Message "      $adviceMessage" -Level "ADVICE"
                $checkSuccess = $false
            }
        }
    }

    if (-not $hooksFound) {
        & $LocalWriteLog -Message "    - [INFO] No hook scripts are configured for this job." -Level "INFO"
    }

    return $checkSuccess
}

Export-ModuleMember -Function Test-PreFlightHookScript
