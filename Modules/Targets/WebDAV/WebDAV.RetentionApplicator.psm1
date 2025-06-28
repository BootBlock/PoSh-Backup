# Modules\Targets\WebDAV\WebDAV.RetentionApplicator.psm1
<#
.SYNOPSIS
    A sub-module for WebDAV.Target.psm1. Handles the remote retention policy.
.DESCRIPTION
    This module provides the 'Invoke-WebDAVRetentionPolicy' function. It is responsible for
    applying a count-based retention policy to a remote WebDAV destination. It lists the
    directory contents using PROPFIND, groups files into backup instances, and deletes
    the oldest instances using DELETE requests to meet the configured retention count.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    28-Jun-2025
    LastModified:   28-Jun-2025
    Purpose:        To isolate the WebDAV remote retention logic.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Module Dependencies ---
# $PSScriptRoot here is Modules\Targets\WebDAV
try {
    Import-Module -Name (Join-Path $PSScriptRoot "..\..\Utilities\RetentionUtils.psm1") -Force -ErrorAction Stop
}
catch {
    Write-Error "WebDAV.RetentionApplicator.psm1 FATAL: Could not import dependent module. Error: $($_.Exception.Message)"
    throw
}
#endregion

function Invoke-WebDAVRetentionPolicy {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$RetentionSettings,
        [Parameter(Mandatory = $true)]
        [string]$BaseWebDAVUrl,
        [Parameter(Mandatory = $true)]
        [string]$RemoteJobDirectoryRelative,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory = $true)]
        [int]$RequestTimeoutSec,
        [Parameter(Mandatory = $true)]
        [string]$ArchiveBaseName,
        [Parameter(Mandatory = $true)]
        [string]$ArchiveExtension,
        [Parameter(Mandatory = $true)]
        [string]$ArchiveDateFormat,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    & $Logger -Message "WebDAV.RetentionApplicator: Logger active." -Level "DEBUG" -ErrorAction SilentlyContinue
    $LocalWriteLog = { param([string]$Message, [string]$Level = "INFO") & $Logger -Message $Message -Level $Level }

    $keepCount = $RetentionSettings.KeepCount
    $remoteDirectoryUrl = ($BaseWebDAVUrl.TrimEnd("/") + "/" + $RemoteJobDirectoryRelative.TrimStart("/")).TrimEnd("/")
    & $LocalWriteLog -Message ("  - WebDAV.RetentionApplicator: Applying remote retention (KeepCount: {0}) in URL '{1}'." -f $keepCount, $remoteDirectoryUrl) -Level "INFO"

    try {
        $propfindBody = '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:getlastmodified/></d:prop></d:propfind>'
        $propfindResponseXml = Invoke-WebRequest -Uri $remoteDirectoryUrl -Method "PROPFIND" -Credential $Credential -Headers @{"Depth" = "1" } -Body $propfindBody -ContentType "application/xml" -TimeoutSec $RequestTimeoutSec -ErrorAction Stop
        
        [xml]$xmlDoc = $propfindResponseXml.Content
        $ns = @{ d = "DAV:" }
        $responses = Select-Xml -Xml $xmlDoc -Namespace $ns -XPath "//d:response[not(d:propstat/d:prop/d:resourcetype/d:collection)]"

        $fileObjectListForGrouping = $responses | ForEach-Object {
            $node = $_.Node
            $href = $node.SelectSingleNode("d:href", $ns).InnerText
            $lastModified = $node.SelectSingleNode("d:propstat/d:prop/d:getlastmodified", $ns).InnerText
            [PSCustomObject]@{
                Name           = (Split-Path -Path $href -Leaf)
                SortTime       = [datetime]::Parse($lastModified, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
                OriginalObject = $_.Node
            }
        }
        
        $remoteInstances = Group-BackupInstancesByTimestamp -FileObjectList $fileObjectListForGrouping `
            -ArchiveBaseName $ArchiveBaseName `
            -ArchiveDateFormat $ArchiveDateFormat `
            -PrimaryArchiveExtension $ArchiveExtension `
            -Logger $Logger

        if ($remoteInstances.Count -gt $keepCount) {
            $sortedInstances = $remoteInstances.GetEnumerator() | Sort-Object { $_.Value.SortTime } -Descending
            $instancesToDelete = $sortedInstances | Select-Object -Skip $keepCount
            & $LocalWriteLog -Message ("    - WebDAV.RetentionApplicator: Found {0} remote instances. Will delete files for {1} older instance(s)." -f $remoteInstances.Count, $instancesToDelete.Count) -Level "DEBUG"

            foreach ($instanceEntry in $instancesToDelete) {
                & $LocalWriteLog "      - WebDAV.RetentionApplicator: Preparing to delete instance '$($instanceEntry.Name)' (SortTime: $($instanceEntry.Value.SortTime))." -Level "WARNING"
                foreach ($webDAVObjectContainer in $instanceEntry.Value.Files) {
                    $webDAVNodeToDelete = $webDAVObjectContainer.OriginalObject
                    $fileToDeleteUrl = ($BaseWebDAVUrl.TrimEnd("/") + $webDAVNodeToDelete.SelectSingleNode("d:href", $ns).InnerText).TrimEnd("/")
                    
                    if (-not $PSCmdletInstance.ShouldProcess($fileToDeleteUrl, "Delete Remote WebDAV File (Retention)")) {
                        & $LocalWriteLog ("        - Deletion of '{0}' skipped by user." -f $fileToDeleteUrl) -Level "WARNING"; continue
                    }
                    
                    & $LocalWriteLog -Message ("        - Deleting: '{0}'" -f $fileToDeleteUrl) -Level "WARNING"
                    try {
                        Invoke-WebRequest -Uri $fileToDeleteUrl -Method "DELETE" -Credential $Credential -TimeoutSec $RequestTimeoutSec -ErrorAction Stop | Out-Null
                        & $LocalWriteLog "          - Status: DELETED" -Level "SUCCESS"
                    } catch {
                        $deleteErrorMsg = "Failed to delete remote WebDAV file '$fileToDeleteUrl'. Error: $($_.Exception.Message)"
                        if ($_.Exception.Response) { $deleteErrorMsg += " Status: $($_.Exception.Response.StatusCode) $($_.Exception.Response.StatusDescription)" }
                        & $LocalWriteLog "          - Status: FAILED! $deleteErrorMsg" -Level "ERROR"
                    }
                }
            }
        } else { & $LocalWriteLog ("    - WebDAV.RetentionApplicator: No old instances to delete based on retention count {0} (Found: {1})." -f $keepCount, $remoteInstances.Count) -Level "DEBUG" }
    } catch {
        & $LocalWriteLog -Message "[WARNING] WebDAV.RetentionApplicator: Error during remote retention execution: $($_.Exception.Message)" -Level "WARNING"
    }
}

Export-ModuleMember -Function Invoke-WebDAVRetentionPolicy
