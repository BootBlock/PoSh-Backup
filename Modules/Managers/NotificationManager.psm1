# Modules\Managers\NotificationManager.psm1
<#
.SYNOPSIS
    Manages the sending of notifications for PoSh-Backup jobs and sets via multiple providers.
    This module now acts as a facade, lazy-loading and dispatching calls to provider-specific sub-modules.
.DESCRIPTION
    This module provides the functionality to send notifications based on the
    completion status of a backup job or set. It uses pre-defined notification profiles
    from the main configuration, which specify a provider type (like "Email", "Webhook", or "Desktop").

    The main exported function, 'Invoke-PoShBackupNotification', acts as a dispatcher:
    - It determines the notification profile to use based on the effective configuration.
    - It inspects the profile's 'Type' and lazy-loads the appropriate provider sub-module.
    - It then calls the provider's 'Invoke-*Notification' function to handle the specific delivery logic.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        2.1.0 # Refactored to lazy-load provider sub-modules.
    DateCreated:    09-Jun-2025
    LastModified:   02-Jul-2025
    Purpose:        To orchestrate and delegate all notification logic for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
#>

# No eager module imports are needed here. They will be lazy-loaded.

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
    & $LocalWriteLog -Message "NotificationManager (Facade): Initialising notification process for job '$($JobReportData.JobName)'." -Level "DEBUG"

    if ($EffectiveNotificationSettings.Enabled -ne $true) {
        & $LocalWriteLog -Message "NotificationManager (Facade): Notification for job '$($JobReportData.JobName)' will not be sent (disabled in effective settings)." -Level "DEBUG"
        return
    }

    $triggerStatuses = @($EffectiveNotificationSettings.TriggerOnStatus | ForEach-Object { $_.ToUpperInvariant() })
    $finalStatus = $JobReportData.OverallStatus.ToUpperInvariant()

    if (-not ($triggerStatuses -contains "ANY" -or $finalStatus -in $triggerStatuses)) {
        & $LocalWriteLog -Message "NotificationManager (Facade): Notification for job '$($JobReportData.JobName)' will not be sent. Status '$finalStatus' does not match trigger statuses: $($triggerStatuses -join ', ')." -Level "INFO"
        return
    }

    $profileName = $EffectiveNotificationSettings.ProfileName
    if ([string]::IsNullOrWhiteSpace($profileName)) {
        & $LocalWriteLog -Message "NotificationManager (Facade): Cannot send notification for job '$($JobReportData.JobName)'. 'ProfileName' is not specified in the effective NotificationSettings." -Level "ERROR"; return
    }

    $notificationProfile = $GlobalConfig.NotificationProfiles[$profileName]
    if ($null -eq $notificationProfile) {
        & $LocalWriteLog -Message "NotificationManager (Facade): Cannot send notification for job '$($JobReportData.JobName)'. Notification profile '$profileName' not found in global NotificationProfiles." -Level "ERROR"; return
    }

    $providerType = $notificationProfile.Type
    $providerSettings = $notificationProfile.ProviderSettings
    & $LocalWriteLog -Message "NotificationManager (Facade): Dispatching notification for job '$($JobReportData.JobName)' using profile '$profileName' (Type: '$providerType')." -Level "INFO"

    $providerParams = @{
        ProviderSettings     = $providerSettings
        NotificationSettings = $EffectiveNotificationSettings
        JobReportData        = $JobReportData
        GlobalConfig         = $GlobalConfig
        Logger               = $Logger
        IsSimulateMode       = $IsSimulateMode.IsPresent
        PSCmdlet             = $PSCmdlet
        CurrentSetName       = $CurrentSetName
    }

    try {
        switch ($providerType.ToLowerInvariant()) {
            'email' {
                Import-Module -Name (Join-Path $PSScriptRoot "NotificationManager\Email.Provider.psm1") -Force -ErrorAction Stop
                Invoke-EmailNotification @providerParams
            }
            'webhook' {
                Import-Module -Name (Join-Path $PSScriptRoot "NotificationManager\Webhook.Provider.psm1") -Force -ErrorAction Stop
                Invoke-WebhookNotification @providerParams
            }
            'desktop' {
                Import-Module -Name (Join-Path $PSScriptRoot "NotificationManager\Desktop.Provider.psm1") -Force -ErrorAction Stop
                Invoke-DesktopNotification @providerParams
            }
            default {
                & $LocalWriteLog -Message "NotificationManager (Facade): Unknown notification provider type '$providerType' for profile '$profileName'. Cannot send notification." -Level "ERROR"
            }
        }
    }
    catch {
        $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Managers\NotificationManager\' and its sub-modules exist and are not corrupted."
        & $LocalWriteLog -Message "[ERROR] NotificationManager (Facade): Could not load or execute the '$providerType' provider module. Notification skipped. Error: $($_.Exception.Message)" -Level "ERROR"
        & $LocalWriteLog -Message $advice -Level "ADVICE"
    }
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupNotification
