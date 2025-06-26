# Modules\Managers\VerificationManager\SandboxManager.psm1
<#
.SYNOPSIS
    A sub-module for VerificationManager. Manages the verification sandbox directory.
.DESCRIPTION
    This module provides functions to prepare and clean up the temporary "sandbox"
    directory used for restoring archives during a verification job.
    - 'Initialize-VerificationSandbox' ensures the directory exists and is empty,
      respecting the 'OnDirtySandbox' policy from the configuration.
    - 'Clear-VerificationSandbox' is a simple wrapper for robustly deleting the
      contents of the sandbox after a verification check is complete.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    25-Jun-2025
    LastModified:   25-Jun-2025
    Purpose:        To prepare and clean up the verification sandbox directory.
    Prerequisites:  PowerShell 5.1+.
#>

function Initialize-VerificationSandbox {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([bool])]
    param(
        # The full path to the sandbox directory.
        [Parameter(Mandatory = $true)]
        [string]$SandboxPath,

        # The policy for handling a non-empty sandbox ('Fail' or 'CleanAndContinue').
        [Parameter(Mandatory = $true)]
        [string]$OnDirtySandbox,

        # A scriptblock reference to the main Write-LogMessage function.
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,

        # A reference to the calling cmdlet's $PSCmdlet automatic variable.
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    & $Logger -Message "VerificationManager/SandboxManager: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    if (-not (Test-Path -LiteralPath $SandboxPath)) {
        & $LocalWriteLog -Message "  - Sandbox path '$SandboxPath' does not exist. Attempting to create." -Level "INFO"
        if (-not $PSCmdletInstance.ShouldProcess($SandboxPath, "Create Sandbox Directory")) {
            & $LocalWriteLog -Message "    - Sandbox creation skipped by user. Verification cannot proceed." -Level "WARNING"
            return $false
        }
        try {
            New-Item -Path $SandboxPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
            & $LocalWriteLog -Message "    - Sandbox directory created successfully." -Level "SUCCESS"
        } catch {
            & $LocalWriteLog -Message "    - Failed to create sandbox directory. Error: $($_.Exception.Message)" -Level "ERROR"
            return $false
        }
    }

    # Use a direct check for items instead of Get-ChildItem | Measure-Object for performance
    if ((Get-ChildItem -LiteralPath $SandboxPath -Force -ErrorAction SilentlyContinue | Select-Object -First 1).Count -gt 0) {
        & $LocalWriteLog -Message "  - Sandbox path '$SandboxPath' is not empty." -Level "WARNING"
        if ($OnDirtySandbox -eq 'Fail') {
            & $LocalWriteLog -Message "    - 'OnDirtySandbox' is set to 'Fail'. Aborting verification." -Level "ERROR"
            return $false
        }
        else { # CleanAndContinue
            & $LocalWriteLog -Message "    - 'OnDirtySandbox' is set to 'CleanAndContinue'. Attempting to clear sandbox." -Level "INFO"
            if (-not $PSCmdletInstance.ShouldProcess($SandboxPath, "Clear Sandbox Directory Contents")) {
                & $LocalWriteLog -Message "    - Sandbox cleaning skipped by user. Verification cannot proceed." -Level "WARNING"
                return $false
            }
            Clear-VerificationSandbox -SandboxPath $SandboxPath -Logger $Logger
        }
    }
    return $true
}

function Clear-VerificationSandbox {
    [CmdletBinding()]
    param(
        # The full path to the sandbox directory to clear.
        [Parameter(Mandatory = $true)]
        [string]$SandboxPath,

        # A scriptblock reference to the main Write-LogMessage function.
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )
    
    & $Logger -Message "VerificationManager/SandboxManager/Clear-VerificationSandbox: Logger active for path '$SandboxPath'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    if (Test-Path -LiteralPath $SandboxPath -PathType Container) {
        & $LocalWriteLog -Message "  - Cleaning up sandbox directory '$SandboxPath'." -Level "INFO"
        try {
             Get-ChildItem -LiteralPath $SandboxPath -Force | Remove-Item -Recurse -Force -ErrorAction Stop
             & $LocalWriteLog -Message "    - Sandbox cleared successfully." -Level "SUCCESS"
        } catch {
             & $LocalWriteLog -Message "    - Failed to clean up sandbox. Manual cleanup may be required. Error: $($_.Exception.Message)" -Level "ERROR"
             # This doesn't throw, as cleanup is a best-effort action. The error is logged.
        }
    }
}


Export-ModuleMember -Function Initialize-VerificationSandbox, Clear-VerificationSandbox
