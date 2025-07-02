# Modules\Targets\GCS\GCS.DependencyChecker.psm1
<#
.SYNOPSIS
    A sub-module for GCS.Target.psm1. Checks for the gcloud CLI dependency.
.DESCRIPTION
    This module provides the 'Test-GcsCliDependency' function, which verifies that the
    'gcloud' command-line tool is installed and available in the system's PATH. This is a
    critical prerequisite for all other GCS operations.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.2 # Added comment-based help and ADVICE logging.
    DateCreated:    02-Jul-2025
    LastModified:   02-Jul-2025
    Purpose:        To isolate the gcloud CLI dependency check.
    Prerequisites:  PowerShell 5.1+.
#>

function Test-GcsCliDependency {
<#
.SYNOPSIS
    Verifies that the 'gcloud' command-line tool is installed and accessible.
.DESCRIPTION
    This function checks for the presence of 'gcloud.cmd' or 'gcloud' in the system's
    PATH. It is a fundamental prerequisite for any operations involving the Google Cloud
    Storage target provider.
.PARAMETER Logger
    A mandatory scriptblock reference to the main 'Write-LogMessage' function, used for
    logging the outcome and providing advice.
.OUTPUTS
    A hashtable with a 'Success' key (boolean) and an 'ErrorMessage' key (string) if
    the check fails.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    # PSSA Appeasement: Use the Logger parameter directly.
    & $Logger -Message "GCS.DependencyChecker: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue

    if (Get-Command gcloud -ErrorAction SilentlyContinue) {
        return @{ Success = $true }
    }
    else {
        $errorMessage = "The 'gcloud' CLI is not installed or not in the system PATH."
        $adviceMessage = "ADVICE: Please install the Google Cloud SDK and ensure its bin directory is included in your system's PATH environment variable to use the GCS target provider."
        & $Logger -Message $errorMessage -Level "ERROR"
        & $Logger -Message $adviceMessage -Level "ADVICE"
        return @{ Success = $false; ErrorMessage = $errorMessage }
    }
}

Export-ModuleMember -Function Test-GcsCliDependency
