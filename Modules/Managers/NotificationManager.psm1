# Modules\Managers/NotificationManager.psm1
<#
.SYNOPSIS
    Manages the sending of email notifications for PoSh-Backup jobs and sets.
.DESCRIPTION
    This module provides the functionality to send email notifications based on the
    completion status of a backup job or set. It uses pre-defined email server profiles
    from the main configuration and securely retrieves credentials from PowerShell's
    SecretManagement.

    The main exported function, 'Send-PoShBackupEmailNotification', handles:
    - Checking if the job/set status matches the configured notification triggers.
    - Retrieving the correct email profile and its settings.
    - Securely fetching SMTP credentials.
    - Constructing a clear and concise email subject and body with job details.
    - Sending the email using Send-MailMessage.
    - Robust error handling and simulation mode support.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    09-Jun-2025
    LastModified:   09-Jun-2025
    Purpose:        To handle all email notification logic for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Requires the 'Microsoft.PowerShell.SecretManagement' module to be installed
                    and a vault configured if using SMTP authentication.
#>

#region --- Private Helper: Get PSCredential from Secret ---
function Get-PSCredentialFromSecretInternal-Notify {
    param(
        [string]$SecretName,
        [string]$VaultName, # Optional
        [scriptblock]$Logger,
        [string]$SecretPurposeForLog = "SMTP Credential"
    )

    # PSSA Appeasement: Use the Logger parameter
    & $Logger -Message "NotificationManager/Get-PSCredentialFromSecretInternal-Notify: Logger active for secret '$SecretName', purpose '$SecretPurposeForLog'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }

    if ([string]::IsNullOrWhiteSpace($SecretName)) {
        & $LocalWriteLog -Message ("  - GetPSCredentialSecret: SecretName not provided for {0}. Cannot retrieve." -f $SecretPurposeForLog) -Level "DEBUG"
        return $null
    }
    if (-not (Get-Command Get-Secret -ErrorAction SilentlyContinue)) {
        throw "PowerShell SecretManagement module (Get-Secret cmdlet) not found. Cannot retrieve '$SecretName' for $SecretPurposeForLog."
    }
    try {
        $getSecretParams = @{ Name = $SecretName; ErrorAction = 'Stop' }
        if (-not [string]::IsNullOrWhiteSpace($VaultName)) {
            $getSecretParams.Vault = $VaultName
        }
        $secretValue = Get-Secret @getSecretParams
        if ($null -ne $secretValue) {
            if ($secretValue.Secret -is [System.Management.Automation.PSCredential]) {
                & $LocalWriteLog -Message ("  - GetPSCredentialSecret: Successfully retrieved PSCredential object for secret '{0}'." -f $SecretName) -Level "DEBUG"
                return $secretValue.Secret
            }
            else {
                throw "Secret '$SecretName' was retrieved but is not a PSCredential object. Type found: $($secretValue.Secret.GetType().FullName)."
            }
        }
    }
    catch {
        throw "Failed to retrieve secret '$SecretName' for $SecretPurposeForLog. Error: $($_.Exception.Message)"
    }
    return $null
}
#endregion

#region --- Exported Function ---
function Send-PoShBackupEmailNotification {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveEmailSettings,
        [Parameter(Mandatory = $true)]
        [hashtable]$GlobalConfig,
        [Parameter(Mandatory = $true)]
        [hashtable]$JobReportData,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet,
        [Parameter(Mandatory = $false)]
        [string]$CurrentSetName
    )

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    & $LocalWriteLog -Message "NotificationManager: Initialising email notification process for job '$($JobReportData.JobName)'." -Level "DEBUG"

    # --- 1. Check if notification should be sent based on status ---
    $triggerStatuses = @($EffectiveEmailSettings.TriggerOnStatus | ForEach-Object { $_.ToUpperInvariant() })
    $finalStatus = $JobReportData.OverallStatus.ToUpperInvariant()

    if (-not ($triggerStatuses -contains "ANY" -or $finalStatus -in $triggerStatuses)) {
        & $LocalWriteLog -Message "NotificationManager: Email notification for job '$($JobReportData.JobName)' will not be sent. Status '$finalStatus' does not match trigger statuses: $($triggerStatuses -join ', ')." -Level "INFO"
        return
    }

    # --- 2. Validate required settings ---
    if ([string]::IsNullOrWhiteSpace($EffectiveEmailSettings.ProfileName)) {
        & $LocalWriteLog -Message "NotificationManager: Cannot send email for job '$($JobReportData.JobName)'. 'ProfileName' is not specified in the EmailNotification settings." -Level "ERROR"
        return
    }
    if ($null -eq $EffectiveEmailSettings.ToAddress -or $EffectiveEmailSettings.ToAddress.Count -eq 0) {
        & $LocalWriteLog -Message "NotificationManager: Cannot send email for job '$($JobReportData.JobName)'. 'ToAddress' is not specified or is empty." -Level "ERROR"
        return
    }
    $emailProfile = $GlobalConfig.EmailProfiles[$EffectiveEmailSettings.ProfileName]
    if ($null -eq $emailProfile) {
        & $LocalWriteLog -Message "NotificationManager: Cannot send email for job '$($JobReportData.JobName)'. Email profile '$($EffectiveEmailSettings.ProfileName)' not found in global EmailProfiles." -Level "ERROR"
        return
    }

    # --- 3. Construct Email Subject ---
    $setNameForSubject = if ([string]::IsNullOrWhiteSpace($CurrentSetName)) { '(None)' } else { $CurrentSetName }

    $subject = $EffectiveEmailSettings.Subject -replace '\{JobName\}', $JobReportData.JobName `
        -replace '\{SetName\}', $setNameForSubject `
        -replace '\{Status\}', $JobReportData.OverallStatus `
        -replace '\{Date\}', (Get-Date -Format 'yyyy-MM-dd') `
        -replace '\{Time\}', (Get-Date -Format 'HH:mm:ss') `
        -replace '\{ComputerName\}', $env:COMPUTERNAME

    # --- 4. Construct Email Body ---
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

    # --- 5. Prepare to Send ---
    $smtpCredential = $null
    if (-not [string]::IsNullOrWhiteSpace($emailProfile.CredentialSecretName)) {
        try {
            $smtpCredential = Get-PSCredentialFromSecretInternal-Notify -SecretName $emailProfile.CredentialSecretName -VaultName $emailProfile.CredentialVaultName -Logger $Logger
            if ($null -eq $smtpCredential) { throw "Retrieved credential was null." }
        } catch {
            & $LocalWriteLog -Message "NotificationManager: Failed to get SMTP credentials from secret '$($emailProfile.CredentialSecretName)'. Email cannot be sent. Error: $($_.Exception.Message)" -Level "ERROR"
            return
        }
    }

    $sendMailParams = @{
        From       = $emailProfile.FromAddress
        To         = $EffectiveEmailSettings.ToAddress
        Subject    = $subject
        Body       = $body
        SmtpServer = $emailProfile.SMTPServer
        ErrorAction = 'Stop'
    }
    if ($emailProfile.ContainsKey('SMTPPort')) { $sendMailParams.Port = $emailProfile.SMTPPort }
    if ($emailProfile.ContainsKey('EnableSsl') -and $emailProfile.EnableSsl -eq $true) { $sendMailParams.UseSsl = $true }
    if ($null -ne $smtpCredential) { $sendMailParams.Credential = $smtpCredential }

    $shouldProcessTarget = "SMTP Server: $($sendMailParams.SmtpServer), To: $($sendMailParams.To -join ', ')"
    if (-not $PSCmdlet.ShouldProcess($shouldProcessTarget, "Send Email Notification")) {
        & $LocalWriteLog -Message "NotificationManager: Email notification for job '$($JobReportData.JobName)' skipped by user (ShouldProcess)." -Level "WARNING"
        return
    }

    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: NotificationManager: Would send email notification for job '$($JobReportData.JobName)'." -Level "SIMULATE"
        & $LocalWriteLog -Message "  - To: $($sendMailParams.To -join ', ')" -Level "SIMULATE"
        & $LocalWriteLog -Message "  - From: $($sendMailParams.From)" -Level "SIMULATE"
        & $LocalWriteLog -Message "  - Subject: $($sendMailParams.Subject)" -Level "SIMULATE"
        & $LocalWriteLog -Message "  - Server: $($sendMailParams.SmtpServer):$($sendMailParams.Port)" -Level "SIMULATE"
        return
    }

    # --- 6. Send Email ---
    & $LocalWriteLog -Message "NotificationManager: Sending email notification for job '$($JobReportData.JobName)'..." -Level "INFO"
    try {
        Send-MailMessage @sendMailParams
        & $LocalWriteLog -Message "NotificationManager: Email notification sent successfully to '$($sendMailParams.To -join ', ')'." -Level "SUCCESS"
    } catch {
        & $LocalWriteLog -Message "NotificationManager: FAILED to send email notification. Error: $($_.Exception.Message)" -Level "ERROR"
    }
}
#endregion

Export-ModuleMember -Function Send-PoShBackupEmailNotification
