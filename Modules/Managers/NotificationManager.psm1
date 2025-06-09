# Modules\Managers/NotificationManager.psm1
<#
.SYNOPSIS
    Manages the sending of notifications for PoSh-Backup jobs and sets via multiple providers (e.g., Email, Webhook).
.DESCRIPTION
    This module provides the functionality to send notifications based on the
    completion status of a backup job or set. It uses pre-defined notification profiles
    from the main configuration, which specify a provider type (like "Email" or "Webhook")
    and the settings for that provider.

    The main exported function, 'Invoke-PoShBackupNotification', acts as a dispatcher:
    - It determines the notification profile to use based on the effective configuration.
    - It inspects the profile's 'Type' and calls the appropriate internal function
      (e.g., for sending an email or posting to a webhook).
    - For the "Email" provider, it constructs and sends an email via SMTP, retrieving
      credentials from PowerShell SecretManagement if configured.
    - For the "Webhook" provider, it populates a user-defined body template with job data
      and sends it to a webhook URL (also retrieved from SecretManagement).
    - It includes robust error handling and simulation mode support for all providers.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.0 # Refactored to a generic provider-based notification system.
    DateCreated:    09-Jun-2025
    LastModified:   09-Jun-2025
    Purpose:        To handle all notification logic for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    Requires the 'Microsoft.PowerShell.SecretManagement' module to be installed
                    and a vault configured if using secrets for credentials/URLs.
#>

#region --- Private Helper: Get Secret from Vault ---
function Get-SecretFromVaultInternal-Notify {
    param(
        [string]$SecretName,
        [string]$VaultName, # Optional
        [scriptblock]$Logger,
        [string]$SecretPurposeForLog = "Notification Credential"
    )

    # PSSA Appeasement: Use the Logger parameter
    & $Logger -Message "NotificationManager/Get-SecretFromVaultInternal-Notify: Logger active for secret '$SecretName', purpose '$SecretPurposeForLog'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }

    if ([string]::IsNullOrWhiteSpace($SecretName)) {
        & $LocalWriteLog -Message ("  - GetSecret: SecretName not provided for {0}. Cannot retrieve." -f $SecretPurposeForLog) -Level "DEBUG"
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
        $secretObject = Get-Secret @getSecretParams
        if ($null -ne $secretObject) {
            & $LocalWriteLog -Message ("  - GetSecret: Successfully retrieved secret object '{0}' for {1}." -f $SecretName, $SecretPurposeForLog) -Level "DEBUG"
            # Return the entire secret object, let the caller decide how to handle it (PSCredential, string, etc.)
            return $secretObject
        }
    }
    catch {
        & $LocalWriteLog -Message ("[ERROR] GetSecret: Failed to retrieve secret '{0}' for {1}. Error: {2}" -f $SecretName, $SecretPurposeForLog, $_.Exception.Message) -Level "ERROR"
    }
    return $null
}
#endregion

#region --- Private Helper: Send Email Notification ---
function Send-EmailNotificationInternal {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)] [hashtable]$EmailProviderSettings,
        [Parameter(Mandatory = $true)] [hashtable]$NotificationSettings,
        [Parameter(Mandatory = $true)] [hashtable]$JobReportData,
        [Parameter(Mandatory = $true)] [scriptblock]$Logger,
        [Parameter(Mandatory = $true)] [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCmdlet]$PSCmdlet,
        [Parameter(Mandatory = $false)] [string]$CurrentSetName
    )
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    
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
    if (-not [string]::IsNullOrWhiteSpace($EmailProviderSettings.CredentialSecretName)) {
        try {
            $secretObject = Get-SecretFromVaultInternal-Notify -SecretName $EmailProviderSettings.CredentialSecretName -VaultName $EmailProviderSettings.CredentialVaultName -Logger $Logger -SecretPurposeForLog "SMTP Credential"
            if ($null -ne $secretObject -and $secretObject.Secret -is [System.Management.Automation.PSCredential]) {
                $smtpCredential = $secretObject.Secret
            } elseif ($null -ne $secretObject) {
                throw "Retrieved secret '$($EmailProviderSettings.CredentialSecretName)' is not a PSCredential object as required for email."
            } else {
                throw "Retrieved credential was null."
            }
        } catch {
            & $LocalWriteLog -Message "NotificationManager: Failed to get SMTP credentials from secret '$($EmailProviderSettings.CredentialSecretName)'. Email cannot be sent. Error: $($_.Exception.Message)" -Level "ERROR"
            return
        }
    }

    $sendMailParams = @{
        From       = $EmailProviderSettings.FromAddress
        To         = $NotificationSettings.ToAddress
        Subject    = $subject
        Body       = $body
        SmtpServer = $EmailProviderSettings.SMTPServer
        ErrorAction = 'Stop'
    }
    if ($EmailProviderSettings.ContainsKey('SMTPPort')) { $sendMailParams.Port = $EmailProviderSettings.SMTPPort }
    if ($EmailProviderSettings.ContainsKey('EnableSsl') -and $EmailProviderSettings.EnableSsl -eq $true) { $sendMailParams.UseSsl = $true }
    if ($null -ne $smtpCredential) { $sendMailParams.Credential = $smtpCredential }

    $shouldProcessTarget = "SMTP Server: $($sendMailParams.SmtpServer), To: $($sendMailParams.To -join ', ')"
    if (-not $PSCmdlet.ShouldProcess($shouldProcessTarget, "Send Email Notification")) {
        & $LocalWriteLog -Message "NotificationManager: Email notification for job '$($JobReportData.JobName)' skipped by user (ShouldProcess)." -Level "WARNING"
        return
    }

    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: NotificationManager: Would send email notification for job '$($JobReportData.JobName)'." -Level "SIMULATE"
        & $LocalWriteLog -Message "  - To: $($sendMailParams.To -join ', ')" -Level "SIMULATE"
        & $LocalWriteLog -Message "  - Subject: $($sendMailParams.Subject)" -Level "SIMULATE"
        return
    }

    # Send Email
    & $LocalWriteLog -Message "NotificationManager: Sending email notification for job '$($JobReportData.JobName)'..." -Level "INFO"
    try {
        Send-MailMessage @sendMailParams
        & $LocalWriteLog -Message "NotificationManager: Email notification sent successfully to '$($sendMailParams.To -join ', ')'." -Level "SUCCESS"
    } catch {
        & $LocalWriteLog -Message "NotificationManager: FAILED to send email notification. Error: $($_.Exception.Message)" -Level "ERROR"
    }
}
#endregion

#region --- Private Helper: Send Webhook Notification ---
function Send-WebhookNotificationInternal {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)] [hashtable]$WebhookProviderSettings,
        [Parameter(Mandatory = $true)] [hashtable]$NotificationSettings, # For context, though not directly used for webhook params
        [Parameter(Mandatory = $true)] [hashtable]$JobReportData,
        [Parameter(Mandatory = $true)] [scriptblock]$Logger,
        [Parameter(Mandatory = $true)] [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCmdlet]$PSCmdlet,
        [Parameter(Mandatory = $false)] [string]$CurrentSetName
    )
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    # PSSA Appeasement
    $null = $NotificationSettings.Enabled

    # Get Webhook URL from secret
    $webhookUrl = $null
    if (-not [string]::IsNullOrWhiteSpace($WebhookProviderSettings.WebhookUrlSecretName)) {
        try {
            $secretObject = Get-SecretFromVaultInternal-Notify -SecretName $WebhookProviderSettings.WebhookUrlSecretName -VaultName $WebhookProviderSettings.WebhookUrlVaultName -Logger $Logger -SecretPurposeForLog "Webhook URL"
            if ($null -ne $secretObject) {
                if ($secretObject.Secret -is [System.Security.SecureString]) {
                    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretObject.Secret)
                    $webhookUrl = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                } else {
                    $webhookUrl = $secretObject.Secret.ToString()
                }
            }
            if ([string]::IsNullOrWhiteSpace($webhookUrl)) { throw "Retrieved secret was null or empty." }
        } catch {
            & $LocalWriteLog -Message "NotificationManager: Failed to get Webhook URL from secret '$($WebhookProviderSettings.WebhookUrlSecretName)'. Webhook cannot be sent. Error: $($_.Exception.Message)" -Level "ERROR"
            return
        }
    } else {
        & $LocalWriteLog -Message "NotificationManager: 'WebhookUrlSecretName' is not defined in the Webhook provider settings. Cannot send notification." -Level "ERROR"
        return
    }

    # Populate Body Template
    $bodyTemplate = $WebhookProviderSettings.BodyTemplate
    $setNameForBody = if ([string]::IsNullOrWhiteSpace($CurrentSetName)) { 'N/A' } else { $CurrentSetName }
    $errorMessageForBody = if ([string]::IsNullOrWhiteSpace($JobReportData.ErrorMessage)) { 'None' } else { $JobReportData.ErrorMessage }
    
    # Escape characters that are special in JSON strings (like quotes, backslashes, newlines) before replacing
    $finalBody = $bodyTemplate -replace '\{JobName\}', ($JobReportData.JobName -replace '"', '\"') `
        -replace '\{SetName\}', ($setNameForBody -replace '"', '\"') `
        -replace '\{Status\}', ($JobReportData.OverallStatus -replace '"', '\"') `
        -replace '\{Date\}', ((Get-Date -Format 'yyyy-MM-dd') -replace '"', '\"') `
        -replace '\{Time\}', ((Get-Date -Format 'HH:mm:ss') -replace '"', '\"') `
        -replace '\{StartTime\}', (($JobReportData.ScriptStartTime | Get-Date -Format 'o') -replace '"', '\"') `
        -replace '\{Duration\}', (($JobReportData.TotalDuration.ToString()) -replace '"', '\"') `
        -replace '\{ComputerName\}', ($env:COMPUTERNAME -replace '"', '\"') `
        -replace '\{ArchivePath\}', (($JobReportData.FinalArchivePath | Out-String).Trim() -replace '\\', '\\' -replace '"', '\"') `
        -replace '\{ArchiveSize\}', (($JobReportData.ArchiveSizeFormatted | Out-String).Trim() -replace '"', '\"') `
        -replace '\{ErrorMessage\}', (($errorMessageForBody | Out-String).Trim() -replace '\\', '\\' -replace '"', '\"' -replace '\r?\n', '\n')

    $iwrParams = @{
        Uri         = $webhookUrl
        Method      = if ($WebhookProviderSettings.ContainsKey('Method')) { $WebhookProviderSettings.Method } else { 'POST' }
        Body        = $finalBody
        ContentType = 'application/json'
        ErrorAction = 'Stop'
    }
    if ($WebhookProviderSettings.ContainsKey('Headers') -and $WebhookProviderSettings.Headers -is [hashtable]) {
        $iwrParams.Headers = $WebhookProviderSettings.Headers
    }

    if (-not $PSCmdlet.ShouldProcess($webhookUrl, "Send Webhook Notification")) {
        & $LocalWriteLog -Message "NotificationManager: Webhook notification for job '$($JobReportData.JobName)' skipped by user (ShouldProcess)." -Level "WARNING"
        return
    }

    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: NotificationManager: Would send Webhook notification for job '$($JobReportData.JobName)'." -Level "SIMULATE"
        & $LocalWriteLog -Message "  - URI: $webhookUrl" -Level "SIMULATE"
        & $LocalWriteLog -Message "  - Method: $($iwrParams.Method)" -Level "SIMULATE"
        & $LocalWriteLog -Message "  - Body: $($iwrParams.Body)" -Level "SIMULATE"
        return
    }

    # Send Webhook
    & $LocalWriteLog -Message "NotificationManager: Sending Webhook notification for job '$($JobReportData.JobName)'..." -Level "INFO"
    try {
        Invoke-WebRequest @iwrParams | Out-Null
        & $LocalWriteLog -Message "NotificationManager: Webhook notification sent successfully to '$webhookUrl'." -Level "SUCCESS"
    } catch {
        & $LocalWriteLog -Message "NotificationManager: FAILED to send Webhook notification. Error: $($_.Exception.Message)" -Level "ERROR"
        if ($_.Exception.Response) { & $LocalWriteLog -Message "  - Status: $($_.Exception.Response.StatusCode) $($_.Exception.Response.StatusDescription)" -Level "ERROR" }
    }
}
#endregion

#region --- Exported Function ---
function Invoke-PoShBackupNotification {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)] [hashtable]$EffectiveNotificationSettings,
        [Parameter(Mandatory = $true)] [hashtable]$GlobalConfig,
        [Parameter(Mandatory = $true)] [hashtable]$JobReportData,
        [Parameter(Mandatory = $true)] [scriptblock]$Logger,
        [Parameter(Mandatory = $true)] [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCmdlet]$PSCmdlet,
        [Parameter(Mandatory = $false)] [string]$CurrentSetName
    )

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    & $LocalWriteLog -Message "NotificationManager: Initialising notification process for job '$($JobReportData.JobName)'." -Level "DEBUG"

    # --- 1. Check if notification is enabled and should be sent based on status ---
    if ($EffectiveNotificationSettings.Enabled -ne $true) {
        & $LocalWriteLog -Message "NotificationManager: Notification for job '$($JobReportData.JobName)' will not be sent (disabled in effective settings)." -Level "DEBUG"
        return
    }
    $triggerStatuses = @($EffectiveNotificationSettings.TriggerOnStatus | ForEach-Object { $_.ToUpperInvariant() })
    $finalStatus = $JobReportData.OverallStatus.ToUpperInvariant()
    if (-not ($triggerStatuses -contains "ANY" -or $finalStatus -in $triggerStatuses)) {
        & $LocalWriteLog -Message "NotificationManager: Notification for job '$($JobReportData.JobName)' will not be sent. Status '$finalStatus' does not match trigger statuses: $($triggerStatuses -join ', ')." -Level "INFO"
        return
    }

    # --- 2. Get Profile and dispatch to correct provider ---
    $profileName = $EffectiveNotificationSettings.ProfileName
    if ([string]::IsNullOrWhiteSpace($profileName)) {
        & $LocalWriteLog -Message "NotificationManager: Cannot send notification for job '$($JobReportData.JobName)'. 'ProfileName' is not specified in the effective NotificationSettings." -Level "ERROR"
        return
    }
    $notificationProfile = $GlobalConfig.NotificationProfiles[$profileName]
    if ($null -eq $notificationProfile) {
        & $LocalWriteLog -Message "NotificationManager: Cannot send notification for job '$($JobReportData.JobName)'. Notification profile '$profileName' not found in global NotificationProfiles." -Level "ERROR"
        return
    }

    $providerType = $notificationProfile.Type
    $providerSettings = $notificationProfile.ProviderSettings

    & $LocalWriteLog -Message "NotificationManager: Dispatching notification for job '$($JobReportData.JobName)' using profile '$profileName' (Type: '$providerType')." -Level "INFO"

    switch ($providerType.ToLowerInvariant()) {
        'email' {
            Send-EmailNotificationInternal -EmailProviderSettings $providerSettings `
                -NotificationSettings $EffectiveNotificationSettings `
                -JobReportData $JobReportData `
                -Logger $Logger `
                -IsSimulateMode:$IsSimulateMode `
                -PSCmdlet $PSCmdlet `
                -CurrentSetName $CurrentSetName
        }
        'webhook' {
            Send-WebhookNotificationInternal -WebhookProviderSettings $providerSettings `
                -NotificationSettings $EffectiveNotificationSettings `
                -JobReportData $JobReportData `
                -Logger $Logger `
                -IsSimulateMode:$IsSimulateMode `
                -PSCmdlet $PSCmdlet `
                -CurrentSetName $CurrentSetName
        }
        default {
            & $LocalWriteLog -Message "NotificationManager: Unknown notification provider type '$providerType' for profile '$profileName'. Cannot send notification." -Level "ERROR"
        }
    }
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupNotification
