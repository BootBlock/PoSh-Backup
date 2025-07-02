# Modules\Core\JobOrchestrator\PostJobProcessor.psm1
<#
.SYNOPSIS
    A sub-module for JobOrchestrator. Handles all post-job processing tasks.
.DESCRIPTION
    This module provides the 'Invoke-PoShBackupPostJobProcessing' function. It is
    responsible for orchestrating all actions that occur after a single job has
    run or been skipped.

    This includes:
    - Triggering the generation of all configured report formats (HTML, CSV, etc.).
    - Sending notifications (Email, Webhook, etc.) based on the job's final status.
    - Applying the log file retention policy for the completed job.

    This module now lazy-loads its dependencies (Reporting, Notification, and Log managers)
    to improve overall script startup performance.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.1.1 # FIX: Corrected call to Invoke-PoShBackupLogRetention.
    DateCreated:    26-Jun-2025
    LastModified:   02-Jul-2025
    Purpose:        To centralise all post-job processing tasks.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Core\JobOrchestrator
try {
    # Only import what is universally needed by this module itself.
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "JobOrchestrator\PostJobProcessor.psm1 FATAL: Could not import Utils.psm1. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Invoke-PoShBackupPostJobProcessing {
    [CmdletBinding()]
    param(
        # The name of the job being processed.
        [Parameter(Mandatory = $true)]
        [string]$JobName,

        # The effective configuration for this job, used to find report/log settings.
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveJobConfig,

        # The complete, loaded global configuration.
        [Parameter(Mandatory = $true)]
        [hashtable]$GlobalConfig,

        # The final report data object for the job.
        [Parameter(Mandatory = $true)]
        [hashtable]$JobReportData,

        # A switch indicating if the run was a simulation.
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,

        # A scriptblock reference to the main Write-LogMessage function.
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,

        # A reference to the calling cmdlet's $PSCmdlet automatic variable.
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet,

        # The name of the set this job is part of, if any.
        [Parameter(Mandatory = $false)]
        [string]$CurrentSetName
    )

    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }
    & $LocalWriteLog -Message "PostJobProcessor: Starting post-job processing for '$JobName'." -Level "DEBUG"

    # --- 1. Report Generation ---
    if ($EffectiveJobConfig.ReportGeneratorType -ne "None") {
        if ($IsSimulateMode.IsPresent) {
            & $LocalWriteLog -Message "SIMULATE: Report generation for job '$JobName' would be performed for type(s): $($EffectiveJobConfig.ReportGeneratorType -join ', ')." -Level "SIMULATE"
        }
        else {
            try {
                Import-Module -Name (Join-Path -Path $PSScriptRoot "..\..\Reporting.psm1") -Force -ErrorAction Stop

                $defaultReportsDir = Join-Path -Path $GlobalConfig['_PoShBackup_PSScriptRoot'] -ChildPath "Reports"
                # Ensure base reports directory exists
                if (-not (Test-Path -LiteralPath $defaultReportsDir -PathType Container)) {
                    try { New-Item -Path $defaultReportsDir -ItemType Directory -Force -ErrorAction Stop | Out-Null }
                    catch { & $LocalWriteLog -Message "[WARNING] Failed to create default reports directory '$defaultReportsDir'. Report generation may fail. Error: $($_.Exception.Message)" -Level "WARNING" }
                }

                Invoke-ReportGenerator -ReportDirectory $defaultReportsDir `
                    -JobName $JobName `
                    -ReportData $JobReportData `
                    -GlobalConfig $GlobalConfig `
                    -JobConfig $EffectiveJobConfig.GlobalConfigRef.BackupLocations[$JobName] `
                    -Logger $Logger
            }
            catch {
                & $LocalWriteLog -Message "[ERROR] PostJobProcessor: Could not load or execute the Reporting facade. Report generation skipped. Error: $($_.Exception.Message)" -Level "ERROR"
            }
        }
    }

    # --- 2. Notification ---
    try {
        Import-Module -Name (Join-Path -Path $PSScriptRoot "..\..\Managers\NotificationManager.psm1") -Force -ErrorAction Stop

        Invoke-PoShBackupNotification -EffectiveNotificationSettings $EffectiveJobConfig.NotificationSettings `
            -GlobalConfig $GlobalConfig `
            -JobReportData $JobReportData `
            -Logger $Logger `
            -IsSimulateMode:$IsSimulateMode `
            -PSCmdlet $PSCmdlet `
            -CurrentSetName $CurrentSetName
    }
    catch {
        & $LocalWriteLog -Message "[ERROR] PostJobProcessor: Could not load or execute the NotificationManager facade. Notifications skipped. Error: $($_.Exception.Message)" -Level "ERROR"
    }

    # --- 3. Log File Retention ---
    if ($Global:GlobalEnableFileLogging -and (-not [string]::IsNullOrWhiteSpace($Global:GlobalLogDirectory))) {
        try {
            Import-Module -Name (Join-Path -Path $PSScriptRoot "..\..\Managers\LogManager.psm1") -Force -ErrorAction Stop

            Invoke-PoShBackupLogRetention -LogDirectory $Global:GlobalLogDirectory `
                -JobNamePattern $JobName `
                -RetentionCount $EffectiveJobConfig.LogRetentionCount `
                -CompressOldLogs $EffectiveJobConfig.CompressOldLogs `
                -OldLogCompressionFormat $EffectiveJobConfig.OldLogCompressionFormat `
                -Logger $Logger `
                -IsSimulateMode:$IsSimulateMode `
                -PSCmdletInstance $PSCmdlet
        }
        catch {
            $advice = "ADVICE: This indicates a problem loading a core component. Ensure 'Modules\Managers\LogManager.psm1' and its sub-modules exist and are not corrupted."
            & $LocalWriteLog -Message "[ERROR] PostJobProcessor: Could not load or execute the LogManager facade. Log retention skipped. Error: $($_.Exception.Message)" -Level "ERROR"
            & $LocalWriteLog -Message $advice -Level "ADVICE"
        }
    }
}

Export-ModuleMember -Function Invoke-PoShBackupPostJobProcessing
