# Modules\ScriptModes\PreFlightChecker\DestinationPathChecker.psm1
<#
.SYNOPSIS
    A sub-module for PreFlightChecker.psm1. Handles validation of destination paths.
.DESCRIPTION
    This module provides the 'Test-PreFlightDestinationPath' function, which verifies that
    the local destination/staging directory for a backup job exists and that the script
    has the necessary permissions to write files to it.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    01-Jul-2025
    LastModified:   01-Jul-2025
    Purpose:        To isolate the destination path pre-flight check logic.
    Prerequisites:  PowerShell 5.1+.
#>

function Test-PreFlightDestinationPath {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveConfig,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "DestinationPathChecker: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO", [string]$ForegroundColour) & $Logger -Message $Message -Level $Level -ForegroundColour $ForegroundColour }
    $checkSuccess = $true

    & $LocalWriteLog -Message "`n  2. Checking Local Destination/Staging Path..." -Level "HEADING"
    $destDir = $EffectiveConfig.DestinationDir

    if ([string]::IsNullOrWhiteSpace($destDir)) {
        & $LocalWriteLog -Message "    - [FAIL] Destination directory is not defined for this job." -Level "ERROR"
        & $LocalWriteLog -Message "      ADVICE: Ensure 'DestinationDir' or 'DefaultDestinationDir' is set in your configuration." -Level "ADVICE"
        return $false # This is a hard failure
    }

    if (Test-Path -LiteralPath $destDir -PathType Container) {
        & $LocalWriteLog -Message "    - [PASS] Destination directory exists: '$destDir'" -Level "SUCCESS"
        $tempFile = Join-Path -Path $destDir -ChildPath "posh-backup-write-test-$([guid]::NewGuid()).tmp"
        try {
            "test" | Set-Content -LiteralPath $tempFile -ErrorAction Stop
            & $LocalWriteLog -Message "    - [PASS] Write permissions are confirmed for '$destDir'." -Level "SUCCESS"
        }
        catch {
            & $LocalWriteLog -Message "    - [FAIL] Write permissions are NOT available for '$destDir'. Error: $($_.Exception.Message)" -Level "ERROR"
            & $LocalWriteLog -Message "      ADVICE: Check the folder permissions for the user account running this script. The account needs 'Modify' rights on this directory." -Level "ADVICE"
            $checkSuccess = $false
        }
        finally {
            if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }
        }
    }
    else {
        & $LocalWriteLog -Message "    - [FAIL] Destination directory does not exist: '$destDir'" -Level "ERROR"
        & $LocalWriteLog -Message "      ADVICE: Please ensure this directory is created, or that the parent directory exists and you have permissions to create it." -Level "ADVICE"
        $checkSuccess = $false
    }

    return $checkSuccess
}

Export-ModuleMember -Function Test-PreFlightDestinationPath
