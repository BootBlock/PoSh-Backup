# Modules\Targets\WebDAV\WebDAV.PathHandler.psm1
<#
.SYNOPSIS
    A sub-module for WebDAV.Target.psm1. Handles remote path validation and creation.
.DESCRIPTION
    This module provides the 'Set-WebDAVTargetPath' function. It is responsible for ensuring
    that a given path (collection) exists on the remote WebDAV server, creating the
    directory structure component-by-component using MKCOL requests if it does not exist.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    28-Jun-2025
    LastModified:   28-Jun-2025
    Purpose:        To isolate the WebDAV remote path creation logic.
    Prerequisites:  PowerShell 5.1+.
#>

function Set-WebDAVTargetPath {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$BaseWebDAVUrl,
        [Parameter(Mandatory)]
        [string]$RelativePathToEnsure,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory)]
        [int]$RequestTimeoutSec,
        [Parameter(Mandatory)]
        [scriptblock]$Logger,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    & $Logger -Message "WebDAV.PathHandler: Logger active. Ensuring path '$RelativePathToEnsure' on '$BaseWebDAVUrl'." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    $pathSegments = $RelativePathToEnsure.Trim("/").Split("/") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $currentRelativePathForMkcol = ""

    foreach ($segment in $pathSegments) {
        $currentRelativePathForMkcol += "/$segment"
        $currentSegmentUrl = ($BaseWebDAVUrl.TrimEnd("/") + $currentRelativePathForMkcol).TrimEnd("/")

        try {
            & $LocalWriteLog -Message "  - WebDAV.PathHandler: Checking existence of '$currentSegmentUrl'..." -Level "DEBUG"
            $propfindResponse = Invoke-WebRequest -Uri $currentSegmentUrl -Method "PROPFIND" -Credential $Credential -Headers @{"Depth" = "0" } -TimeoutSec $RequestTimeoutSec -ErrorAction SilentlyContinue
            if ($propfindResponse.StatusCode -eq 207) { # 207 Multi-Status is the success code for PROPFIND
                & $LocalWriteLog -Message "    - Path exists." -Level "DEBUG"
                continue # Path exists, move to next segment
            }
        }
        catch {
            # This block will be hit if Invoke-WebRequest throws an error (e.g., 404 Not Found)
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode -eq 404) {
                & $LocalWriteLog -Message "    - Path component does not exist. Attempting to create." -Level "DEBUG"
                # Proceed to MKCOL
            } else {
                # Some other unexpected error during PROPFIND. Log it and attempt MKCOL anyway.
                $errorMessage = "Unexpected error during PROPFIND for '$currentSegmentUrl'. Error: $($_.Exception.Message)"
                if ($_.Exception.Response) { $errorMessage += " Status: $($_.Exception.Response.StatusCode) $($_.Exception.Response.StatusDescription)" }
                & $LocalWriteLog -Message "[WARNING] $errorMessage" -Level "WARNING"
            }
        }
        
        # If we get here, the path likely doesn't exist, so we try to create it.
        if (-not $PSCmdletInstance.ShouldProcess($currentSegmentUrl, "Create WebDAV Collection (MKCOL)")) {
            return @{ Success = $false; ErrorMessage = "WebDAV collection creation for '$currentSegmentUrl' skipped by user." }
        }

        try {
            & $LocalWriteLog -Message "  - WebDAV.PathHandler: Sending MKCOL for '$currentSegmentUrl'." -Level "DEBUG"
            Invoke-WebRequest -Uri $currentSegmentUrl -Method "MKCOL" -Credential $Credential -TimeoutSec $requestTimeoutSec -ErrorAction Stop | Out-Null
            & $LocalWriteLog -Message "    - MKCOL successful." -Level "DEBUG"
        }
        catch {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode -eq 405) {
                # 405 Method Not Allowed can sometimes mean the collection already exists. We can treat this as a success for this step.
                & $LocalWriteLog -Message "    - MKCOL returned 405 (Method Not Allowed), assuming collection already exists." -Level "DEBUG"
            }
            else {
                $mkcolError = "Failed to create WebDAV collection '$currentSegmentUrl'. Error: $($_.Exception.Message)"
                if ($_.Exception.Response) { $mkcolError += " Status: $($_.Exception.Response.StatusCode) $($_.Exception.Response.StatusDescription)" }
                return @{ Success = $false; ErrorMessage = $mkcolError }
            }
        }
    }
    return @{ Success = $true }
}

Export-ModuleMember -Function Set-WebDAVTargetPath
