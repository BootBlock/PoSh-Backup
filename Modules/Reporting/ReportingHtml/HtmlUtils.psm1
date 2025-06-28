# Modules\Reporting\ReportingHtml\HtmlUtils.psm1
<#
.SYNOPSIS
    A common utility sub-module for the ReportingHtml group. Provides shared functions.
.DESCRIPTION
    This module provides common helper functions, primarily for safe HTML encoding,
    that can be used by other modules in the ReportingHtml sub-directory.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.3
    DateCreated:    28-Jun-2025
    LastModified:   28-Jun-2025
    Purpose:        To provide shared utilities for HTML report generation.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- HTML Encode Helper Function Definition & Setup ---
$Script:PoshBackup_ReportingHtml_UseSystemWebHtmlEncode = $false
try {
    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
    $httpUtilityType = try { [System.Type]::GetType("System.Web.HttpUtility, System.Web, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a", $false) } catch { $null }
    if ($null -ne $httpUtilityType) { $Script:PoshBackup_ReportingHtml_UseSystemWebHtmlEncode = $true }
}
catch {
    # This catch block now correctly handles the error from Add-Type.
    Write-Warning "HtmlUtils: Could not load the System.Web assembly. HTML encoding will use a slower, manual fallback method. Error: $($_.Exception.Message)"
}

Function ConvertTo-PoshBackupSafeHtmlInternal {
    [CmdletBinding()] param([Parameter(Mandatory = $false, ValueFromPipeline=$true)][string]$Text)
    process {
        if ($null -eq $Text) { return '' }
        if ($Script:PoshBackup_ReportingHtml_UseSystemWebHtmlEncode) {
            try {
                return [System.Web.HttpUtility]::HtmlEncode($Text)
            }
            catch {
                Write-Warning "HtmlUtils: System.Web.HttpUtility.HtmlEncode failed. Reverting to manual sanitisation. Error: $($_.Exception.Message)"
                return $Text -replace '&', '&' -replace '<', '<' -replace '>', '>' -replace '"', '"' -replace "'", '&#39;'
            }
        }
        else {
            return $Text -replace '&', '&' -replace '<', '<' -replace '>', '>' -replace '"', '"' -replace "'", '&#39;'
        }
    }
}
Set-Alias -Name ConvertTo-SafeHtml -Value ConvertTo-PoshBackupSafeHtmlInternal -Scope Script -ErrorAction SilentlyContinue -Force
#endregion

Export-ModuleMember -Function ConvertTo-PoshBackupSafeHtmlInternal -Alias ConvertTo-SafeHtml
