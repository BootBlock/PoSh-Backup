# Modules\Managers/NotificationManager.psm1
<#
.SYNOPSIS
    Manages the sending of notifications for PoSh-Backup jobs and sets via multiple providers (e.g., Email, Webhook, Desktop).
.DESCRIPTION
    This module provides the functionality to send notifications based on the
    completion status of a backup job or set. It uses pre-defined notification profiles
    from the main configuration, which specify a provider type (like "Email", "Webhook", or "Desktop")
    and the settings for that provider.

    The main exported function, 'Invoke-PoShBackupNotification', acts as a dispatcher:
    - It determines the notification profile to use based on the effective configuration.
    - It inspects the profile's 'Type' and calls the appropriate internal function.
    - For the "Email" provider, it constructs and sends an email via SMTP.
    - For the "Webhook" provider, it populates a user-defined body template and sends it to a webhook URL.
    - For the "Desktop" provider, it uses a version-aware approach:
        - On PowerShell 7+, it uses the 'BurntToast' module.
        - On Windows PowerShell 5.1, it uses native WinRT APIs loaded via System.Type::GetType() to avoid parser bugs.
    - It includes robust error handling and simulation mode support for all providers.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.4.1 # Definitive Fix: Implemented version-aware logic for Desktop notifications (Native for PS5.1, BurntToast for PS7+).
    DateCreated:    09-Jun-2025
    LastModified:   19-Jun-2025
    Purpose:        To handle all notification logic for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    The 'Microsoft.PowerShell.SecretManagement' module is required if using secrets for credentials/URLs.
                    The 'BurntToast' module is required for the "Desktop" notification provider when running on PowerShell 7+.
#>

#region --- Private Helper: C# Shortcut Helper via Add-Type ---
# This helper provides a reliable, dependency-free way to set the AppUserModelID on a shortcut.
# It is compiled in memory the first time it's needed.
$Script:ShortcutHelperType = $null
function Get-ShortcutHelperTypeInternal {
    if ($null -ne $Script:ShortcutHelperType) {
        return $Script:ShortcutHelperType
    }

    $cSharpSource = @"
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

// Define COM interfaces required for IPropertyStore
[ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPropertyStore {
    void GetCount([Out] out uint cProps);
    void GetAt([In] uint iProp, out PropertyKey pkey);
    void GetValue([In] ref PropertyKey key, [Out] out PropVariant pv);
    void SetValue([In] ref PropertyKey key, [In] ref PropVariant propvar);
    void Commit();
}

[ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IShellLinkW {
    void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszFile, int cchMaxPath, [In, Out] ref WIN32_FIND_DATAW pfd, uint fFlags);
    void GetIDList(out IntPtr ppidl);
    void SetIDList(IntPtr pidl);
    void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszName, int cchMaxName);
    void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
    void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszDir, int cchMaxPath);
    void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
    void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszArgs, int cchMaxPath);
    void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
    void GetHotkey(out ushort pwHotkey);
    void SetHotkey(ushort wHotkey);
    void GetShowCmd(out int piShowCmd);
    void SetShowCmd(int iShowCmd);
    void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszIconPath, int cchIconPath, out int piIcon);
    void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
    void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
    void Resolve(IntPtr hwnd, uint fFlags);
    void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
}

[StructLayout(LayoutKind.Sequential)]
public struct PropertyKey {
    public Guid fmtid;
    public uint pid;
}

[StructLayout(LayoutKind.Explicit)]
public struct PropVariant {
    [FieldOffset(0)] public ushort vt;
    [FieldOffset(8)] public IntPtr pszVal;
    [FieldOffset(8)] public System.Runtime.InteropServices.ComTypes.FILETIME filetime;
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct WIN32_FIND_DATAW {
    public uint dwFileAttributes;
    public System.Runtime.InteropServices.ComTypes.FILETIME ftCreationTime;
    public System.Runtime.InteropServices.ComTypes.FILETIME ftLastAccessTime;
    public System.Runtime.InteropServices.ComTypes.FILETIME ftLastWriteTime;
    public uint nFileSizeHigh;
    public uint nFileSizeLow;
    public uint dwReserved0;
    public uint dwReserved1;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
    public string cFileName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)]
    public string cAlternateFileName;
}

public static class ShortcutHelper {
    private static readonly Guid IPropertyStoreGUID = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");

    public static void SetAppId(string shortcutPath, string appId) {
        IShellLinkW link = (IShellLinkW)new ShellLink();
        IPersistFile file = (IPersistFile)link;
        file.Load(shortcutPath, 0);

        IPropertyStore propStore = (IPropertyStore)link;
        PropertyKey appUserModelIdKey = new PropertyKey {
            fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"),
            pid = 5
        };

        PropVariant propVar = new PropVariant();
        propVar.vt = (ushort)VarEnum.VT_LPWSTR;
        propVar.pszVal = Marshal.StringToCoTaskMemUni(appId);

        propStore.SetValue(ref appUserModelIdKey, ref propVar);
        propStore.Commit();
        Marshal.FreeCoTaskMem(propVar.pszVal);

        file.Save(shortcutPath, true);
    }

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    private class ShellLink { }
}
"@
    try {
        Add-Type -TypeDefinition $cSharpSource -ErrorAction Stop
        $Script:ShortcutHelperType = [ShortcutHelper]
    }
    catch {
        # This will be handled by the calling function.
        throw "Failed to compile the C# helper for shortcut management. Desktop notifications will not work. Error: $($_.Exception.Message)"
    }
    return $Script:ShortcutHelperType
}
#endregion

#region --- Private Helper: Get Secret from Vault ---
function Get-SecretFromVaultInternal-Notify {
    param(
        [string]$SecretName,
        [string]$VaultName, # Optional
        [scriptblock]$Logger,
        [string]$SecretPurposeForLog = "Notification Credential"
    )

    # PSScriptAnalyzer Appeasement: Use the Logger parameter
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
        if (-not [string]::IsNullOrWhiteSpace($VaultName)) { $getSecretParams.Vault = $VaultName }
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

#region --- Private Helper: Register AppID for Toasts ---
function Register-PoshBackupAppId {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PSScriptRoot,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )

    & $Logger -Message "NotificationManager/Register-PoshBackupAppId: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    $appId = "BootBlock.PoSh-Backup"
    $startMenuPath = Join-Path -Path $env:APPDATA -ChildPath "Microsoft\Windows\Start Menu\Programs"
    $shortcutPath = Join-Path -Path $startMenuPath -ChildPath "PoSh-Backup.lnk"
    $mainScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "PoSh-Backup.ps1"

    if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
        # Future enhancement: Could check if the AppID on the existing shortcut is correct.
        & $LocalWriteLog -Message "NotificationManager/Register-PoshBackupAppId: Shortcut already exists at '$shortcutPath'. Assuming AppID is registered." -Level "DEBUG"
        return $appId
    }

    & $LocalWriteLog -Message "NotificationManager/Register-PoshBackupAppId: One-time setup for Desktop Notifications required." -Level "INFO"

    if (-not $PSCmdlet.ShouldProcess($shortcutPath, "Create Start Menu shortcut to register application for notifications")) {
        & $LocalWriteLog -Message "NotificationManager/Register-PoshBackupAppId: Shortcut creation skipped by user. Desktop notifications will not be sent." -Level "WARNING"
        return $null
    }

    try {
        if (-not (Test-Path -LiteralPath $startMenuPath -PathType Container)) {
            New-Item -Path $startMenuPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }

        # Step 1: Create the basic shortcut file
        $wshShell = New-Object -ComObject WScript.Shell
        $shortcut = $wshShell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = "powershell.exe"
        $shortcut.Arguments = "-NoProfile -File `"$mainScriptPath`""
        $shortcut.IconLocation = "powershell.exe,0"
        $shortcut.Description = "Launch PoSh-Backup. This shortcut is required for desktop notifications."
        $shortcut.WorkingDirectory = $PSScriptRoot
        $shortcut.Save()

        # Step 2: Set the AppUserModelID using the compiled C# helper
        $helper = Get-ShortcutHelperTypeInternal
        if ($null -eq $helper) {
            throw "Could not get the compiled C# shortcut helper."
        }

        $helper::SetAppId($shortcutPath, $appId)

        & $LocalWriteLog -Message "NotificationManager/Register-PoshBackupAppId: Shortcut with AppID '$appId' created successfully at '$shortcutPath'." -Level "SUCCESS"
        return $appId
    }
    catch {
        & $LocalWriteLog -Message "NotificationManager/Register-PoshBackupAppId: FAILED to create shortcut for notifications. Error: $($_.Exception.Message)" -Level "ERROR"
        return $null
    }
}
#endregion

#region --- Private Helper: Send Desktop Notification ---
function Send-DesktopNotificationInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [hashtable]$ProviderSettings,
        [Parameter(Mandatory = $true)] [hashtable]$NotificationSettings,
        [Parameter(Mandatory = $true)] [hashtable]$JobReportData,
        [Parameter(Mandatory = $true)] [hashtable]$GlobalConfig,
        [Parameter(Mandatory = $true)] [scriptblock]$Logger,
        [Parameter(Mandatory = $true)] [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCmdlet]$PSCmdlet
    )
    & $Logger -Message "NotificationManager/Send-DesktopNotificationInternal: Logger active for job '$($JobReportData.JobName)'." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    # PSSA Appeasement
    $null = $ProviderSettings
    $null = $NotificationSettings

    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: NotificationManager: Would display a desktop toast notification for job '$($JobReportData.JobName)'." -Level "SIMULATE"
        return
    }

    # --- Register AppID (one-time setup) ---
    $appId = Register-PoshBackupAppId -PSScriptRoot $GlobalConfig['_PoShBackup_PSScriptRoot'] -Logger $Logger -PSCmdlet $PSCmdlet
    if ([string]::IsNullOrWhiteSpace($appId)) {
        & $LocalWriteLog -Message "NotificationManager: Could not register AppID for notifications. Aborting desktop notification." -Level "WARNING"
        return
    }

    # --- Branch logic for PS5.1 vs PS7+ ---
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        # --- PowerShell 7+ Method: Use BurntToast ---
        if (-not (Get-Command New-BurntToastNotification -ErrorAction SilentlyContinue)) {
            & $LocalWriteLog -Message "NotificationManager: FAILED to send desktop notification. The required 'BurntToast' module is not available for PowerShell 7+." -Level "ERROR"
            return
        }
        try {
            $title = "PoSh-Backup: $($JobReportData.JobName)"
            $status = $JobReportData.OverallStatus

            # Safely determine the duration string
            $durationString = ""
            if ($JobReportData.TotalDuration -is [System.TimeSpan]) {
                $durationString = "Duration: " + $JobReportData.TotalDuration.ToString('g').Split('.')[0]
            }
            else {
                $durationString = "Duration: " + $JobReportData.TotalDuration
            }

            $message = "Status: $status`n$durationString"

            $toastParams = @{ Text = $title, $message }
            New-BurntToastNotification @toastParams
            & $LocalWriteLog -Message "NotificationManager: Desktop notification sent for job '$($JobReportData.JobName)' via BurntToast." -Level "SUCCESS"
        }
        catch {
            & $LocalWriteLog -Message "NotificationManager: FAILED to send desktop notification via BurntToast. Error: $($_.Exception.Message)" -Level "ERROR"
        }
    }
    else {
        # --- Windows PowerShell 5.1 Method: Use Native APIs via robust type loading ---
        try {
            # --- Load required WinRT assemblies using the reliable GetType() method ---
            $toastManagerType = [System.Type]::GetType("Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, Version=255.255.255.255, Culture=neutral, PublicKeyToken=null, ContentType=WindowsRuntime", $true)
            $xmlDocType = [System.Type]::GetType("Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, Version=255.255.255.255, Culture=neutral, PublicKeyToken=null, ContentType=WindowsRuntime", $true)
            $toastNotificationType = [System.Type]::GetType("Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, Version=255.255.255.255, Culture=neutral, PublicKeyToken=null, ContentType=WindowsRuntime", $true)

            # Construct the XML payload
            $jobName = $JobReportData.JobName; $status = $JobReportData.OverallStatus
            $message = "Duration: $($JobReportData.TotalDuration.ToString('g').Split('.')[0])"
            if ($status -ne "SUCCESS" -and -not [string]::IsNullOrWhiteSpace($JobReportData.ErrorMessage)) {
                $message = "Error: $($JobReportData.ErrorMessage.Split([Environment]::NewLine)[0])"
            }
            $xmlPayload = @"
<toast>
    <visual>
        <binding template="ToastGeneric">
            <text>PoSh-Backup: $jobName</text>
            <text>Status: $status</text>
            <text>$message</text>
        </binding>
    </visual>
</toast>
"@
            $xmlDoc = [Activator]::CreateInstance($xmlDocType)
            $xmlDoc.LoadXml($xmlPayload)

            $toast = [Activator]::CreateInstance($toastNotificationType, $xmlDoc)
            $notifier = $toastManagerType::CreateToastNotifier($appId)
            $notifier.Show($toast)
            & $LocalWriteLog -Message "NotificationManager: Desktop notification sent for job '$jobName' via native APIs." -Level "SUCCESS"
        }
        catch {
            $errorMessage = "FAILED to send desktop notification. Required Windows Notification APIs could not be loaded or used."
            & $LocalWriteLog -Message "NotificationManager: $errorMessage" -Level "ERROR"
            & $LocalWriteLog -Message "  - Common Cause: This can occur on non-desktop editions of Windows (like Server Core), a 32-bit PowerShell session, or if the OS installation is missing components." -Level "ERROR"
            & $LocalWriteLog -Message "  - Underlying Error: $($_.Exception.Message)" -Level "DEBUG"
        }
    }
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
    
    & $Logger -Message "NotificationManager/Send-DesktopNotificationInternal: Logger active for job '$($JobReportData.JobName)'." -Level "DEBUG" -ErrorAction SilentlyContinue
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
            }
            elseif ($null -ne $secretObject) {
                throw "Retrieved secret '$($EmailProviderSettings.CredentialSecretName)' is not a PSCredential object as required for email."
            }
            else {
                throw "Retrieved credential was null."
            }
        }
        catch {
            & $LocalWriteLog -Message "NotificationManager: Failed to get SMTP credentials from secret '$($EmailProviderSettings.CredentialSecretName)'. Email cannot be sent. Error: $($_.Exception.Message)" -Level "ERROR"
            return
        }
    }

    $sendMailParams = @{
        From = $EmailProviderSettings.FromAddress; To = $NotificationSettings.ToAddress; Subject = $subject
        Body = $body; SmtpServer = $EmailProviderSettings.SMTPServer; ErrorAction = 'Stop'
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

    & $LocalWriteLog -Message "NotificationManager: Sending email notification for job '$($JobReportData.JobName)'..." -Level "INFO"
    try { Send-MailMessage @sendMailParams; & $LocalWriteLog -Message "NotificationManager: Email notification sent successfully to '$($sendMailParams.To -join ', ')'." -Level "SUCCESS" }
    catch { & $LocalWriteLog -Message "NotificationManager: FAILED to send email notification. Error: $($_.Exception.Message)" -Level "ERROR" }
}
#endregion

#region --- Private Helper: Send Webhook Notification ---
function Send-WebhookNotificationInternal {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)] [hashtable]$WebhookProviderSettings,
        [Parameter(Mandatory = $true)] [hashtable]$NotificationSettings,
        [Parameter(Mandatory = $true)] [hashtable]$JobReportData,
        [Parameter(Mandatory = $true)] [scriptblock]$Logger,
        [Parameter(Mandatory = $true)] [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCmdlet]$PSCmdlet,
        [Parameter(Mandatory = $false)] [string]$CurrentSetName
    )
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    $null = $NotificationSettings.Enabled # PSSA Appeasement

    $webhookUrl = $null
    if (-not [string]::IsNullOrWhiteSpace($WebhookProviderSettings.WebhookUrlSecretName)) {
        try {
            $secretObject = Get-SecretFromVaultInternal-Notify -SecretName $WebhookProviderSettings.WebhookUrlSecretName -VaultName $WebhookProviderSettings.WebhookUrlVaultName -Logger $Logger -SecretPurposeForLog "Webhook URL"
            if ($null -ne $secretObject) {
                if ($secretObject.Secret -is [System.Security.SecureString]) {
                    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretObject.Secret)
                    $webhookUrl = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                }
                else { $webhookUrl = $secretObject.Secret.ToString() }
            }
            if ([string]::IsNullOrWhiteSpace($webhookUrl)) { throw "Retrieved secret was null or empty." }
        }
        catch { & $LocalWriteLog -Message "NotificationManager: Failed to get Webhook URL from secret '$($WebhookProviderSettings.WebhookUrlSecretName)'. Webhook cannot be sent. Error: $($_.Exception.Message)" -Level "ERROR"; return }
    }
    else { & $LocalWriteLog -Message "NotificationManager: 'WebhookUrlSecretName' is not defined in the Webhook provider settings. Cannot send notification." -Level "ERROR"; return }

    $bodyTemplate = $WebhookProviderSettings.BodyTemplate
    $setNameForBody = if ([string]::IsNullOrWhiteSpace($CurrentSetName)) { 'N/A' } else { $CurrentSetName }
    $errorMessageForBody = if ([string]::IsNullOrWhiteSpace($JobReportData.ErrorMessage)) { 'None' } else { $JobReportData.ErrorMessage }
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
        Uri = $webhookUrl; Method = if ($WebhookProviderSettings.ContainsKey('Method')) { $WebhookProviderSettings.Method } else { 'POST' }
        Body = $finalBody; ContentType = 'application/json'; ErrorAction = 'Stop'
    }
    if ($WebhookProviderSettings.ContainsKey('Headers') -and $WebhookProviderSettings.Headers -is [hashtable]) {
        $iwrParams.Headers = $WebhookProviderSettings.Headers
    }

    if (-not $PSCmdlet.ShouldProcess($webhookUrl, "Send Webhook Notification")) {
        & $LocalWriteLog -Message "NotificationManager: Webhook notification for job '$($JobReportData.JobName)' skipped by user (ShouldProcess)." -Level "WARNING"; return
    }

    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: NotificationManager: Would send Webhook notification for job '$($JobReportData.JobName)'." -Level "SIMULATE"
        & $LocalWriteLog -Message "  - URI: $webhookUrl" -Level "SIMULATE"; & $LocalWriteLog -Message "  - Method: $($iwrParams.Method)" -Level "SIMULATE"; & $LocalWriteLog -Message "  - Body: $($iwrParams.Body)" -Level "SIMULATE"
        return
    }

    & $LocalWriteLog -Message "NotificationManager: Sending Webhook notification for job '$($JobReportData.JobName)'..." -Level "INFO"
    try { Invoke-WebRequest @iwrParams | Out-Null; & $LocalWriteLog -Message "NotificationManager: Webhook notification sent successfully to '$webhookUrl'." -Level "SUCCESS" }
    catch { & $LocalWriteLog -Message "NotificationManager: FAILED to send Webhook notification. Error: $($_.Exception.Message)" -Level "ERROR"; if ($_.Exception.Response) { & $LocalWriteLog -Message "  - Status: $($_.Exception.Response.StatusCode) $($_.Exception.Response.StatusDescription)" -Level "ERROR" } }
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

    $profileName = $EffectiveNotificationSettings.ProfileName
    if ([string]::IsNullOrWhiteSpace($profileName)) {
        & $LocalWriteLog -Message "NotificationManager: Cannot send notification for job '$($JobReportData.JobName)'. 'ProfileName' is not specified in the effective NotificationSettings." -Level "ERROR"; return
    }
    $notificationProfile = $GlobalConfig.NotificationProfiles[$profileName]
    if ($null -eq $notificationProfile) {
        & $LocalWriteLog -Message "NotificationManager: Cannot send notification for job '$($JobReportData.JobName)'. Notification profile '$profileName' not found in global NotificationProfiles." -Level "ERROR"; return
    }

    $providerType = $notificationProfile.Type; $providerSettings = $notificationProfile.ProviderSettings
    & $LocalWriteLog -Message "NotificationManager: Dispatching notification for job '$($JobReportData.JobName)' using profile '$profileName' (Type: '$providerType')." -Level "INFO"

    switch ($providerType.ToLowerInvariant()) {
        'email' {
            Send-EmailNotificationInternal -EmailProviderSettings $providerSettings -NotificationSettings $EffectiveNotificationSettings -JobReportData $JobReportData -Logger $Logger -IsSimulateMode:$IsSimulateMode -PSCmdlet $PSCmdlet -CurrentSetName $CurrentSetName
        }
        'webhook' {
            Send-WebhookNotificationInternal -WebhookProviderSettings $providerSettings -NotificationSettings $EffectiveNotificationSettings -JobReportData $JobReportData -Logger $Logger -IsSimulateMode:$IsSimulateMode -PSCmdlet $PSCmdlet -CurrentSetName $CurrentSetName
        }
        'desktop' {
            Send-DesktopNotificationInternal -ProviderSettings $providerSettings -NotificationSettings $EffectiveNotificationSettings -JobReportData $JobReportData -GlobalConfig $GlobalConfig -Logger $Logger -IsSimulateMode:$IsSimulateMode -PSCmdlet $PSCmdlet
        }
        default {
            & $LocalWriteLog -Message "NotificationManager: Unknown notification provider type '$providerType' for profile '$profileName'. Cannot send notification." -Level "ERROR"
        }
    }
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupNotification
