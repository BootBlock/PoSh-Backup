# Modules\Managers\NotificationManager\Webhook.Provider.psm1
<#
.SYNOPSIS
    A provider sub-module for the NotificationManager facade. Handles sending webhook notifications.
.DESCRIPTION
    This module contains the 'Invoke-WebhookNotification' function, which is responsible
    for constructing a JSON payload from a user-defined template and sending it to a
    configured webhook URL. It retrieves the webhook URL securely via the common secret
    handler and replaces placeholders in the body template with job-specific data.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.1 # Fixed missing GlobalConfig parameter.
    DateCreated:    26-Jun-2025
    LastModified:   26-Jun-2025
    Purpose:        Webhook provider for the NotificationManager.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers\NotificationManager
try {
    Import-Module -Name (Join-Path $PSScriptRoot "Common.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "NotificationManager\Webhook.Provider.psm1 FATAL: Could not import a dependent module. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Invoke-WebhookNotification {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)] [hashtable]$ProviderSettings,
        [Parameter(Mandatory = $true)] [hashtable]$NotificationSettings,
        [Parameter(Mandatory = $true)] [hashtable]$JobReportData,
        [Parameter(Mandatory = $true)] [hashtable]$GlobalConfig, # NEW: Added missing parameter
        [Parameter(Mandatory = $true)] [scriptblock]$Logger,
        [Parameter(Mandatory = $true)] [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCmdlet]$PSCmdlet,
        [Parameter(Mandatory = $false)] [string]$CurrentSetName
    )

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    $null = $NotificationSettings.Enabled, $GlobalConfig # PSSA Appeasement

    $webhookUrlSecret = Get-PoShBackupNotificationSecret -SecretName $ProviderSettings.WebhookUrlSecretName -VaultName $ProviderSettings.WebhookUrlVaultName -Logger $Logger -SecretPurposeForLog "Webhook URL"
    $webhookUrl = $null
    
    if ($null -ne $webhookUrlSecret) {
        if ($webhookUrlSecret.Secret -is [System.Security.SecureString]) {
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($webhookUrlSecret.Secret)
            $webhookUrl = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        else { $webhookUrl = $webhookUrlSecret.Secret.ToString() }
    }

    if ([string]::IsNullOrWhiteSpace($webhookUrl)) {
        & $LocalWriteLog -Message "Webhook.Provider: 'WebhookUrlSecretName' is not defined or the secret could not be retrieved. Cannot send notification." -Level "ERROR"; return
    }

    $bodyTemplate = $ProviderSettings.BodyTemplate
    $setNameForBody = if ([string]::IsNullOrWhiteSpace($CurrentSetName)) { 'N/A' } else { $CurrentSetName }
    $errorMessageForBody = if ([string]::IsNullOrWhiteSpace($JobReportData.ErrorMessage)) { 'None' } else { $JobReportData.ErrorMessage }
    
    # Helper to escape JSON string values
    $jsonEscape = { param($str) $str -replace '\\', '\\' -replace '"', '\"' -replace '`', '\`' }
    
    $finalBody = $bodyTemplate -replace '\{JobName\}', ($jsonEscape.Invoke($JobReportData.JobName)) `
        -replace '\{SetName\}', ($jsonEscape.Invoke($setNameForBody)) `
        -replace '\{Status\}', ($jsonEscape.Invoke($JobReportData.OverallStatus)) `
        -replace '\{Date\}', ($jsonEscape.Invoke((Get-Date -Format 'yyyy-MM-dd'))) `
        -replace '\{Time\}', ($jsonEscape.Invoke((Get-Date -Format 'HH:mm:ss'))) `
        -replace '\{StartTime\}', ($jsonEscape.Invoke(($JobReportData.ScriptStartTime | Get-Date -Format 'o'))) `
        -replace '\{Duration\}', ($jsonEscape.Invoke(($JobReportData.TotalDuration.ToString()))) `
        -replace '\{ComputerName\}', ($jsonEscape.Invoke($env:COMPUTERNAME)) `
        -replace '\{ArchivePath\}', ($jsonEscape.Invoke(($JobReportData.FinalArchivePath | Out-String).Trim())) `
        -replace '\{ArchiveSize\}', ($jsonEscape.Invoke(($JobReportData.ArchiveSizeFormatted | Out-String).Trim())) `
        -replace '\{ErrorMessage\}', ($jsonEscape.Invoke(($errorMessageForBody | Out-String).Trim() -replace '\r?\n', '\n'))

    $iwrParams = @{
        Uri = $webhookUrl; Method = if ($ProviderSettings.ContainsKey('Method')) { $ProviderSettings.Method } else { 'POST' }
        Body = $finalBody; ContentType = 'application/json'; ErrorAction = 'Stop'
    }
    if ($ProviderSettings.ContainsKey('Headers') -and $ProviderSettings.Headers -is [hashtable]) {
        $iwrParams.Headers = $ProviderSettings.Headers
    }

    if (-not $PSCmdlet.ShouldProcess($webhookUrl, "Send Webhook Notification")) {
        & $LocalWriteLog -Message "Webhook.Provider: Webhook notification for job '$($JobReportData.JobName)' skipped by user (ShouldProcess)." -Level "WARNING"; return
    }

    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: Webhook.Provider: Would send Webhook notification for job '$($JobReportData.JobName)'." -Level "SIMULATE"
        & $LocalWriteLog -Message "  - URI: $webhookUrl" -Level "SIMULATE"; & $LocalWriteLog -Message "  - Method: $($iwrParams.Method)" -Level "SIMULATE"; & $LocalWriteLog -Message "  - Body: $($iwrParams.Body)" -Level "SIMULATE"
        return
    }

    & $LocalWriteLog -Message "Webhook.Provider: Sending Webhook notification for job '$($JobReportData.JobName)'..." -Level "INFO"
    try { Invoke-WebRequest @iwrParams | Out-Null; & $LocalWriteLog -Message "Webhook.Provider: Webhook notification sent successfully to '$webhookUrl'." -Level "SUCCESS" }
    catch { & $LocalWriteLog -Message "Webhook.Provider: FAILED to send Webhook notification. Error: $($_.Exception.Message)" -Level "ERROR"; if ($_.Exception.Response) { & $LocalWriteLog -Message "  - Status: $($_.Exception.Response.StatusCode) $($_.Exception.Response.StatusDescription)" -Level "ERROR" } }
}

Export-ModuleMember -Function Invoke-WebhookNotification
