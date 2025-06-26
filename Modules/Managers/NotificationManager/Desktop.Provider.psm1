# Modules\Managers\NotificationManager\Desktop.Provider.psm1
<#
.SYNOPSIS
    A provider sub-module for the NotificationManager facade. Handles sending native desktop (toast) notifications.
.DESCRIPTION
    This module contains the 'Invoke-DesktopNotification' function and all its required helpers
    for displaying native Windows toast notifications.

    It uses a version-aware approach:
    - On PowerShell 7+, it uses the 'BurntToast' module.
    - On Windows PowerShell 5.1, it uses native WinRT APIs loaded via System.Type::GetType() to avoid parser bugs.

    To enable notifications, it performs a one-time setup to create a shortcut for PoSh-Backup in the
    Start Menu, which registers the necessary Application User Model ID (AppID) with Windows.
    This process is handled by a compiled-in-memory C# helper for maximum reliability.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.1 # Fixed missing CurrentSetName parameter.
    DateCreated:    26-Jun-2025
    LastModified:   26-Jun-2025
    Purpose:        Desktop (toast) notification provider for the NotificationManager.
    Prerequisites:  PowerShell 5.1+.
                    For PowerShell 7+, the 'BurntToast' module is required.
#>

#region --- Private Helper: C# Shortcut Helper via Add-Type ---
# This helper provides a reliable, dependency-free way to set the AppUserModelID on a shortcut.
# It is compiled in memory the first time it's needed.
$Script:DesktopProvider_ShortcutHelperType = $null
function Get-ShortcutHelperTypeInternal {
    if ($null -ne $Script:DesktopProvider_ShortcutHelperType) {
        return $Script:DesktopProvider_ShortcutHelperType
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
        $Script:DesktopProvider_ShortcutHelperType = [ShortcutHelper]
    }
    catch {
        throw "Failed to compile the C# helper for shortcut management. Desktop notifications will not work. Error: $($_.Exception.Message)"
    }
    return $Script:DesktopProvider_ShortcutHelperType
}
#endregion

#region --- Private Helper: Register AppID for Toasts ---
function Register-PoshBackupAppIdInternal {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PSScriptRoot,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )

    & $Logger -Message "Desktop.Provider/Register-PoshBackupAppIdInternal: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    $appId = "BootBlock.PoSh-Backup"
    $startMenuPath = Join-Path -Path $env:APPDATA -ChildPath "Microsoft\Windows\Start Menu\Programs"
    $shortcutPath = Join-Path -Path $startMenuPath -ChildPath "PoSh-Backup.lnk"
    $mainScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "PoSh-Backup.ps1"

    if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
        & $LocalWriteLog -Message "Desktop.Provider: Shortcut already exists at '$shortcutPath'. Assuming AppID is registered." -Level "DEBUG"
        return $appId
    }

    & $LocalWriteLog -Message "Desktop.Provider: One-time setup for Desktop Notifications required." -Level "INFO"

    if (-not $PSCmdlet.ShouldProcess($shortcutPath, "Create Start Menu shortcut to register application for notifications")) {
        & $LocalWriteLog -Message "Desktop.Provider: Shortcut creation skipped by user. Desktop notifications will not be sent." -Level "WARNING"
        return $null
    }

    try {
        if (-not (Test-Path -LiteralPath $startMenuPath -PathType Container)) {
            New-Item -Path $startMenuPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }

        $wshShell = New-Object -ComObject WScript.Shell
        $shortcut = $wshShell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = "powershell.exe"
        $shortcut.Arguments = "-NoProfile -File `"$mainScriptPath`""
        $shortcut.IconLocation = "powershell.exe,0"
        $shortcut.Description = "Launch PoSh-Backup. This shortcut is required for desktop notifications."
        $shortcut.WorkingDirectory = $PSScriptRoot
        $shortcut.Save()

        $helper = Get-ShortcutHelperTypeInternal
        if ($null -eq $helper) { throw "Could not get the compiled C# shortcut helper." }
        $helper::SetAppId($shortcutPath, $appId)

        & $LocalWriteLog -Message "Desktop.Provider: Shortcut with AppID '$appId' created successfully at '$shortcutPath'." -Level "SUCCESS"
        return $appId
    }
    catch {
        & $LocalWriteLog -Message "Desktop.Provider: FAILED to create shortcut for notifications. Error: $($_.Exception.Message)" -Level "ERROR"
        return $null
    }
}
#endregion

#region --- Exported Function ---
function Invoke-DesktopNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [hashtable]$ProviderSettings,
        [Parameter(Mandatory = $true)] [hashtable]$NotificationSettings,
        [Parameter(Mandatory = $true)] [hashtable]$JobReportData,
        [Parameter(Mandatory = $true)] [hashtable]$GlobalConfig,
        [Parameter(Mandatory = $true)] [scriptblock]$Logger,
        [Parameter(Mandatory = $true)] [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCmdlet]$PSCmdlet,
        [Parameter(Mandatory = $false)] [string]$CurrentSetName # NEW: Added missing parameter to match the calling signature.
    )

    $null = $CurrentSetName # PSSA Appeasement for unused parameter.
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    $null = $ProviderSettings, $NotificationSettings # PSSA Appeasement

    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: Desktop.Provider: Would display a desktop toast notification for job '$($JobReportData.JobName)'." -Level "SIMULATE"
        return
    }

    $appId = Register-PoshBackupAppIdInternal -PSScriptRoot $GlobalConfig['_PoShBackup_PSScriptRoot'] -Logger $Logger -PSCmdlet $PSCmdlet
    if ([string]::IsNullOrWhiteSpace($appId)) {
        & $LocalWriteLog -Message "Desktop.Provider: Could not register AppID for notifications. Aborting desktop notification." -Level "WARNING"
        return
    }

    if ($PSVersionTable.PSVersion.Major -ge 6) {
        if (-not (Get-Command New-BurntToastNotification -ErrorAction SilentlyContinue)) {
            & $LocalWriteLog -Message "Desktop.Provider: FAILED to send desktop notification. The required 'BurntToast' module is not available for PowerShell 7+." -Level "ERROR"
            return
        }
        try {
            $title = "PoSh-Backup: $($JobReportData.JobName)"
            $status = $JobReportData.OverallStatus
            $durationString = "Duration: " + ($JobReportData.TotalDuration.ToString('g').Split('.')[0] -replace '^0:')
            $message = "Status: $status`n$durationString"

            $toastParams = @{ Text = $title, $message }
            New-BurntToastNotification @toastParams
            & $LocalWriteLog -Message "Desktop.Provider: Desktop notification sent for job '$($JobReportData.JobName)' via BurntToast." -Level "SUCCESS"
        }
        catch {
            & $LocalWriteLog -Message "Desktop.Provider: FAILED to send desktop notification via BurntToast. Error: $($_.Exception.Message)" -Level "ERROR"
        }
    }
    else {
        try {
            $toastManagerType = [System.Type]::GetType("Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, Version=255.255.255.255, Culture=neutral, PublicKeyToken=null, ContentType=WindowsRuntime", $true)
            $xmlDocType = [System.Type]::GetType("Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, Version=255.255.255.255, Culture=neutral, PublicKeyToken=null, ContentType=WindowsRuntime", $true)
            $toastNotificationType = [System.Type]::GetType("Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, Version=255.255.255.255, Culture=neutral, PublicKeyToken=null, ContentType=WindowsRuntime", $true)

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
            & $LocalWriteLog -Message "Desktop.Provider: Desktop notification sent for job '$jobName' via native APIs." -Level "SUCCESS"
        }
        catch {
            $errorMessage = "FAILED to send desktop notification. Required Windows Notification APIs could not be loaded or used."
            & $LocalWriteLog -Message "Desktop.Provider: $errorMessage" -Level "ERROR"
            & $LocalWriteLog -Message "  - Common Cause: This can occur on non-desktop editions of Windows (like Server Core), a 32-bit PowerShell session, or if the OS installation is missing components." -Level "ERROR"
            & $LocalWriteLog -Message "  - Underlying Error: $($_.Exception.Message)" -Level "DEBUG"
        }
    }
}
#endregion

Export-ModuleMember -Function Invoke-DesktopNotification
