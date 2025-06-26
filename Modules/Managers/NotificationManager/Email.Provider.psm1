# Modules\Managers\NotificationManager\Email.Provider.psm1
<#
.SYNOPSIS
    A provider sub-module for the NotificationManager facade. Handles sending email notifications.
.DESCRIPTION
    This module contains the 'Invoke-EmailNotification' function, which is responsible
    for constructing and sending an email via SMTP based on the provided settings. It retrieves
    credentials securely via the common secret handler and replaces placeholders in the
    subject line with job-specific data.
.NOTES
    Author:         AI Assistant
    Version:        1.0.1 # Fixed missing GlobalConfig parameter.
    DateCreated:    26-Jun-2025
    LastModified:   26-Jun-2025
    Purpose:        Email provider for the NotificationManager.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Managers\NotificationManager
try {
    Import-Module -Name (Join-Path $PSScriptRoot "Common.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "NotificationManager\Email.Provider.psm1 FATAL: Could not import a dependent module. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Invoke-EmailNotification {
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
    $null = $GlobalConfig # PSSA Appeasement

    # Construct Email Subject
    $setNameForSubject = if ([string]::IsNullOrWhiteSpace($CurrentSetName)) { '(None)' } else { $CurrentSetName }
    $subject = $NotificationSettings.Subject -replace '\{JobName\}', $JobReportData.JobName `
        -replace '\{SetName\}', $setNameForSubject `
        -replace '\{Status\}', $JobReportData.OverallStatus `
        -replace '\{Date\}', (Get-Date -Format 'yyyy-MM-dd') `
        -replace '\{Time\}', (Get-Date -Format 'HH:mm:ss') `
        -replace '\{ComputerName\}', $env:COMPUTERNAME

    # Construct Email Body
    $setNameForBody = if ([string]::IsNullOrWhiteSpace($CurrentSetName)) { 'N/A' } else { $CurrentSetName }
    $errorMessageForBody = if ([string]::IsNullOrWhiteSpace($JobReportData.ErrorMessage)) { 'None' } else { $JobReportData.ErrorMessage }
    $body = @"
PoSh-Backup Notification

This is an automated notification for backup job '$($JobReportData.JobName)'.

Run Details:
- Job Name: $($JobReportData.JobName)
- Set Name: $($setNameForBody)
- Computer: $($env:COMPUTERNAME)
- Start Time: $($JobReportData.ScriptStartTime)
- End Time: $($JobReportData.ScriptEndTime)
- Duration: $($JobReportData.TotalDuration)

Result:
- Overall Status: $($JobReportData.OverallStatus)
- Archive Path: $($JobReportData.FinalArchivePath)
- Archive Size: $($JobReportData.ArchiveSizeFormatted)
- Error Message: $($errorMessageForBody)

$($JobReportData.TargetTransfers.Count) remote transfer(s) attempted.
$($JobReportData.HookScripts.Count) hook script(s) executed.

--
This is an automated message from the PoSh-Backup script.
"@

    # Prepare to Send
    $smtpCredential = $null
    if (-not [string]::IsNullOrWhiteSpace($ProviderSettings.CredentialSecretName)) {
        try {
            $secretObject = Get-PoShBackupNotificationSecret -SecretName $ProviderSettings.CredentialSecretName -VaultName $ProviderSettings.CredentialVaultName -Logger $Logger -SecretPurposeForLog "SMTP Credential"
            if ($null -ne $secretObject -and $secretObject.Secret -is [System.Management.Automation.PSCredential]) {
                $smtpCredential = $secretObject.Secret
            }
            elseif ($null -ne $secretObject) {
                throw "Retrieved secret '$($ProviderSettings.CredentialSecretName)' is not a PSCredential object as required for email."
            }
            else {
                throw "Retrieved credential was null."
            }
        }
        catch {
            & $LocalWriteLog -Message "Email.Provider: Failed to get SMTP credentials from secret '$($ProviderSettings.CredentialSecretName)'. Email cannot be sent. Error: $($_.Exception.Message)" -Level "ERROR"
            return
        }
    }

    $sendMailParams = @{
        From = $ProviderSettings.FromAddress; To = $NotificationSettings.ToAddress; Subject = $subject
        Body = $body; SmtpServer = $ProviderSettings.SMTPServer; ErrorAction = 'Stop'
    }
    if ($ProviderSettings.ContainsKey('SMTPPort')) { $sendMailParams.Port = $ProviderSettings.SMTPPort }
    if ($ProviderSettings.ContainsKey('EnableSsl') -and $ProviderSettings.EnableSsl -eq $true) { $sendMailParams.UseSsl = $true }
    if ($null -ne $smtpCredential) { $sendMailParams.Credential = $smtpCredential }

    $shouldProcessTarget = "SMTP Server: $($sendMailParams.SmtpServer), To: $($sendMailParams.To -join ', ')"
    if (-not $PSCmdlet.ShouldProcess($shouldProcessTarget, "Send Email Notification")) {
        & $LocalWriteLog -Message "Email.Provider: Email notification for job '$($JobReportData.JobName)' skipped by user (ShouldProcess)." -Level "WARNING"
        return
    }

    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: Email.Provider: Would send email notification for job '$($JobReportData.JobName)'." -Level "SIMULATE"
        & $LocalWriteLog -Message "  - To: $($sendMailParams.To -join ', ')" -Level "SIMULATE"
        & $LocalWriteLog -Message "  - Subject: $($sendMailParams.Subject)" -Level "SIMULATE"
        return
    }

    & $LocalWriteLog -Message "Email.Provider: Sending email notification for job '$($JobReportData.JobName)'..." -Level "INFO"
    try { Send-MailMessage @sendMailParams; & $LocalWriteLog -Message "Email.Provider: Email notification sent successfully to '$($sendMailParams.To -join ', ')'." -Level "SUCCESS" }
    catch { & $LocalWriteLog -Message "Email.Provider: FAILED to send email notification. Error: $($_.Exception.Message)" -Level "ERROR" }
}

Export-ModuleMember -Function Invoke-EmailNotification
