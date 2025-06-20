# Modules\Targets\WebDAV.Target.psm1
<#
.SYNOPSIS
    PoSh-Backup Target Provider for WebDAV (Web Distributed Authoring and Versioning).
    Handles transferring backup archives to WebDAV servers, managing remote retention,
    and supporting credential-based authentication via PowerShell SecretManagement.

.DESCRIPTION
    This module implements the PoSh-Backup target provider interface for WebDAV destinations.
    The core function, 'Invoke-PoShBackupTargetTransfer', is called by the main PoSh-Backup
    operations module when a backup job is configured to use a target of type "WebDAV".

    The provider performs the following actions:
    - Parses WebDAV-specific settings from the TargetInstanceConfiguration, including the
      WebDAV server URL, remote base path, and credential secret name.
    - Retrieves credentials (expected as a PSCredential object) from PowerShell SecretManagement.
    - Establishes a connection and ensures the remote target directory (and job-specific
      subdirectory, if configured) exists, creating it if necessary using MKCOL requests.
    - Uploads the local backup archive file to the WebDAV server using PUT requests.
    - If 'RemoteRetentionSettings' (e.g., 'KeepCount') are defined, it applies a count-based
      retention policy. This involves listing files using PROPFIND and deleting old files
      using DELETE requests.
    - Supports simulation mode for all WebDAV operations.
    - Returns a detailed status hashtable for each file transfer attempt.

    A function, 'Invoke-PoShBackupWebDAVTargetSettingsValidation', validates the entire target configuration.
    A new function, 'Test-PoShBackupTargetConnectivity', validates the WebDAV connection and path.

.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        0.4.0 # Updated validation function to receive entire target instance.
    DateCreated:    05-Jun-2025
    LastModified:   21-Jun-2025
    Purpose:        WebDAV Target Provider for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
                    PowerShell SecretManagement configured if using secrets for credentials.
                    The user/account running PoSh-Backup must have appropriate network access
                    to the WebDAV server and R/W/Delete permissions on the target remote path.
#>

#region --- Private Helper: Format Bytes ---
function Format-BytesInternal-WebDAV {
    param(
        [Parameter(Mandatory = $true)]
        [long]$Bytes
    )
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    else { return "$Bytes Bytes" }
}
#endregion

#region --- Private Helper: Get PSCredential from Secret ---
function Get-PSCredentialFromSecretInternal-WebDAV {
    param(
        [string]$SecretName,
        [string]$VaultName, # Optional
        [scriptblock]$Logger,
        [string]$SecretPurposeForLog = "WebDAV Credential"
    )

    # PSSA Appeasement: Use the Logger parameter
    & $Logger -Message "WebDAV.Target/Get-PSCredentialFromSecretInternal-WebDAV: Logger active for secret '$SecretName', purpose '$SecretPurposeForLog'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }

    if ([string]::IsNullOrWhiteSpace($SecretName)) {
        & $LocalWriteLog -Message ("  - GetPSCredentialSecret: SecretName not provided for {0}. Cannot retrieve." -f $SecretPurposeForLog) -Level "DEBUG"
        return $null
    }
    if (-not (Get-Command Get-Secret -ErrorAction SilentlyContinue)) {
        $errorMessageText = "GetPSCredentialSecret: PowerShell SecretManagement module (Get-Secret cmdlet) not found. Cannot retrieve '{0}' for {1}." -f $SecretName, $SecretPurposeForLog
        & $LocalWriteLog -Message "[ERROR] $errorMessageText" -Level "ERROR"
        throw "PowerShell SecretManagement module not found."
    }
    try {
        $getSecretParams = @{ Name = $SecretName; ErrorAction = 'Stop' }
        if (-not [string]::IsNullOrWhiteSpace($VaultName)) {
            $getSecretParams.Vault = $VaultName
        }
        $secretValue = Get-Secret @getSecretParams
        if ($null -ne $secretValue) {
            & $LocalWriteLog -Message ("  - GetPSCredentialSecret: Successfully retrieved secret object '{0}' for {1}." -f $SecretName, $SecretPurposeForLog) -Level "DEBUG"
            if ($secretValue.Secret -is [System.Management.Automation.PSCredential]) {
                & $LocalWriteLog -Message ("  - GetPSCredentialSecret: Secret '{0}' is a PSCredential object." -f $SecretName) -Level "DEBUG"
                return $secretValue.Secret
            }
            else {
                & $LocalWriteLog -Message ("[WARNING] GetPSCredentialSecret: Secret '{0}' for {1} was retrieved but is not a PSCredential object. Type: {2}." -f $SecretName, $SecretPurposeForLog, $secretValue.Secret.GetType().FullName) -Level "WARNING"
                return $null
            }
        }
    }
    catch {
        $userFriendlyError = "Failed to retrieve secret '{0}' for {1}. This can often happen if the Secret Vault is locked. Try running `Unlock-SecretStore` before executing the script." -f $SecretName, $SecretPurposeForLog
        & $LocalWriteLog -Message "[ERROR] $userFriendlyError" -Level "ERROR"
        & $LocalWriteLog -Message "  - Underlying SecretManagement Error: $($_.Exception.Message)" -Level "DEBUG"
    }
    return $null
}
#endregion

#region --- Private Helper: Ensure WebDAV Remote Path Exists (MKCOL) ---
function Initialize-WebDAVRemotePathInternal {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)]
        [string]$BaseWebDAVUrl,
        [Parameter(Mandatory)]
        [string]$RelativePathToEnsure,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory)]
        [int]$RequestTimeoutSec,
        [Parameter(Mandatory)]
        [scriptblock]$Logger,
        [Parameter(Mandatory)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCmdlet]$PSCmdletInstance
    )

    # PSSA Appeasement: Use the Logger parameter
    & $Logger -Message "WebDAV.Target/Initialize-WebDAVRemotePathInternal: Logger active. Ensuring path '$RelativePathToEnsure' on '$BaseWebDAVUrl'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }

    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: WebDAV.Target: Would check/create remote directory structure for '$RelativePathToEnsure' under '$BaseWebDAVUrl'." -Level "SIMULATE"
        return @{ Success = $true }
    }

    $pathSegments = $RelativePathToEnsure.Trim("/").Split("/") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $currentRelativePathForMkcol = ""

    foreach ($segment in $pathSegments) {
        $currentRelativePathForMkcol += "/$segment"
        $currentSegmentUrl = ($BaseWebDAVUrl.TrimEnd("/") + $currentRelativePathForMkcol).TrimEnd("/")

        if (-not $PSCmdletInstance.ShouldProcess($currentSegmentUrl, "Check/Create WebDAV Collection")) {
            return @{ Success = $false; ErrorMessage = "WebDAV collection creation for '$currentSegmentUrl' skipped by user." }
        }

        try {
            & $LocalWriteLog -Message "  - WebDAV.Target: Attempting PROPFIND for '$currentSegmentUrl' (Depth 0) to check existence." -Level "DEBUG"
            Invoke-WebRequest -Uri $currentSegmentUrl -Method "PROPFIND" -Credential $Credential -Headers @{"Depth" = "0" } -TimeoutSec $RequestTimeoutSec -ErrorAction SilentlyContinue -OutNull
            if ($? -and ($Error.Count -eq 0)) {
                # $? is true if last command succeeded (no terminating error) AND $Error is clear for this specific command
                & $LocalWriteLog -Message "    - WebDAV.Target: PROPFIND for '$currentSegmentUrl' succeeded (HTTP 207 or similar). Collection likely exists." -Level "DEBUG"
                continue # Assume collection exists
            }
            elseif ($Error[0].Exception.Response -and $Error[0].Exception.Response.StatusCode -eq 404) {
                & $LocalWriteLog -Message "    - WebDAV.Target: PROPFIND for '$currentSegmentUrl' returned 404 (Not Found). Attempting MKCOL." -Level "DEBUG"
                Clear-Error # Clear the 404 error before attempting MKCOL
            }
            else {
                # Some other error with PROPFIND, or $? was false. Log it but still try MKCOL.

                $propfindStatusMsg = "N/A"
                if ($Error[0].Exception.Response) {
                    $propfindStatusMsg = $Error[0].Exception.Response.StatusCode
                }
                $propfindErrorMsg = "N/A"
                if ($Error[0]) {
                    $propfindErrorMsg = $Error[0].ToString()
                }
                & $LocalWriteLog -Message "[DEBUG] WebDAV.Target: PROPFIND for '$currentSegmentUrl' did not definitively confirm existence (Status: $propfindStatusMsg, Error: $propfindErrorMsg). Attempting MKCOL." -Level "DEBUG"

                Clear-Error
            }
        }
        catch {
            & $LocalWriteLog -Message "[DEBUG] WebDAV.Target: Unexpected error during PROPFIND for '$currentSegmentUrl': $($_.Exception.Message). Attempting MKCOL." -Level "DEBUG"
        }

        try {
            & $LocalWriteLog -Message "  - WebDAV.Target: Attempting MKCOL for '$currentSegmentUrl'." -Level "DEBUG"
            Invoke-WebRequest -Uri $currentSegmentUrl -Method "MKCOL" -Credential $Credential -TimeoutSec $RequestTimeoutSec -ErrorAction Stop -OutNull
            & $LocalWriteLog -Message "    - WebDAV.Target: MKCOL successful for '$currentSegmentUrl'." -Level "DEBUG"
        }
        catch {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode -eq 405) {
                # 405 Method Not Allowed often means it exists
                & $LocalWriteLog -Message "    - WebDAV.Target: MKCOL returned 405 (Method Not Allowed) for '$currentSegmentUrl', assuming collection already exists." -Level "DEBUG"
            }
            else {
                $errorMessage = "Failed to create WebDAV collection '$currentSegmentUrl'. Error: $($_.Exception.Message)"
                if ($_.Exception.Response) { $errorMessage += " Status: $($_.Exception.Response.StatusCode) $($_.Exception.Response.StatusDescription)" }
                & $LocalWriteLog -Message "[ERROR] WebDAV.Target: $errorMessage" -Level "ERROR"
                return @{ Success = $false; ErrorMessage = $errorMessage }
            }
        }
    }
    return @{ Success = $true }
}
#endregion

#region --- Private Helper: Group Remote WebDAV Backup Instances ---
function Group-RemoteWebDAVBackupInstancesInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseWebDAVUrl, # e.g. https://server/dav
        [Parameter(Mandatory = $true)]
        [string]$RemoteDirectoryToList, # Relative path from BaseWebDAVUrl, e.g., /backups/jobname
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory = $true)]
        [int]$RequestTimeoutSec,
        [Parameter(Mandatory = $true)]
        [string]$BaseNameToMatch, # e.g., "JobName [DateStamp]"
        [Parameter(Mandatory = $true)]
        [string]$PrimaryArchiveExtension, # e.g., ".7z"
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    # PSSA Appeasement and initial log entry:
    & $Logger -Message "WebDAV.Target/Group-RemoteWebDAVBackupInstancesInternal: Logger active. Listing '$RemoteDirectoryToList' on '$BaseWebDAVUrl' for base '$BaseNameToMatch', primary ext '$PrimaryArchiveExtension'." -Level "DEBUG" -ErrorAction SilentlyContinue

    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "DEBUG") & $Logger -Message $MessageParam -Level $LevelParam }

    $instances = @{}
    $fullDirectoryUrl = ($BaseWebDAVUrl.TrimEnd("/") + "/" + $RemoteDirectoryToList.TrimStart("/")).TrimEnd("/")

    try {
        $propfindBody = '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:getlastmodified/><d:getcontentlength/><d:resourcetype/></d:prop></d:propfind>'
        $propfindResponseXml = Invoke-WebRequest -Uri $fullDirectoryUrl -Method "PROPFIND" -Credential $Credential -Headers @{"Depth" = "1" } -Body $propfindBody -ContentType "application/xml" -TimeoutSec $RequestTimeoutSec -ErrorAction Stop

        if ($null -eq $propfindResponseXml -or [string]::IsNullOrWhiteSpace($propfindResponseXml.Content)) {
            & $LocalWriteLog -Message "WebDAV.Target/GroupHelper: PROPFIND response for '$fullDirectoryUrl' was empty." -Level "WARNING"
            return $instances
        }

        [xml]$xmlDoc = $propfindResponseXml.Content
        $ns = @{ d = "DAV:" } # Define the DAV namespace. [3, 4]

        # Select all 'response' elements for items within the directory (not the directory itself)
        $responses = Select-Xml -Xml $xmlDoc -Namespace $ns -XPath "//d:response[not(d:propstat/d:prop/d:resourcetype/d:collection)]/d:propstat/d:prop" # Select props of files only

        if ($null -eq $responses) {
            & $LocalWriteLog -Message "WebDAV.Target/GroupHelper: No file resources found in PROPFIND response for '$fullDirectoryUrl'."
            return $instances
        }

        foreach ($responseNode in $responses) {
            $propNode = $responseNode.Node # This is the <d:prop> element
            $hrefNode = $propNode.ParentNode.ParentNode.SelectSingleNode("d:href", $xmlDoc.NameTable) # Go up to <d:response> then find <d:href>
            $fileNameRaw = $hrefNode.InnerText.TrimEnd("/")
            $fileName = Split-Path -Path $fileNameRaw -Leaf # Extract just the filename

            $lastModifiedNode = $propNode.SelectSingleNode("d:getlastmodified", $xmlDoc.NameTable)
            $fileSortTime = [datetime]::MinValue
            if ($null -ne $lastModifiedNode -and -not [string]::IsNullOrWhiteSpace($lastModifiedNode.InnerText)) {
                try { $fileSortTime = [datetime]::Parse($lastModifiedNode.InnerText, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) } # WebDAV dates are typically GMT/UTC. [2]
                catch { & $LocalWriteLog -Message "WebDAV.Target/GroupHelper: Could not parse getlastmodified '$($lastModifiedNode.InnerText)' for '$fileName'. Error: $($_.Exception.Message)" -Level "WARNING" }
            }

            $contentLengthNode = $propNode.SelectSingleNode("d:getcontentlength", $xmlDoc.NameTable)
            $fileSize = 0
            if ($null -ne $contentLengthNode -and -not [string]::IsNullOrWhiteSpace($contentLengthNode.InnerText)) {
                try {
                    $fileSize = [long]$contentLengthNode.InnerText
                }
                catch {
                    & $LocalWriteLog -Message "[DEBUG] WebDAV.Target: Non-critical exception during PROPFIND for '$currentSegmentUrl' (will attempt MKCOL anyway). Error: $($_.Exception.ToString())" -Level "DEBUG"
                }
            }

            $instanceKey = $null
            $literalBase = [regex]::Escape($BaseNameToMatch)
            $literalExt = [regex]::Escape($PrimaryArchiveExtension)

            $splitVolumePattern = "^($literalBase$literalExt)\.(\d{3,})$"
            $splitManifestPattern = "^($literalBase$literalExt)\.manifest\.[a-zA-Z0-9]+$"
            $singleFilePattern = "^($literalBase$literalExt)$"
            $sfxFilePattern = "^($literalBase\.[a-zA-Z0-9]+)$"
            $sfxManifestPattern = "^($literalBase\.[a-zA-Z0-9]+)\.manifest\.[a-zA-Z0-9]+$"

            if ($fileName -match $splitVolumePattern) { $instanceKey = $Matches[1] }
            elseif ($fileName -match $splitManifestPattern) { $instanceKey = $Matches[1] }
            elseif ($fileName -match $sfxManifestPattern) { $instanceKey = $Matches[1] }
            elseif ($fileName -match $singleFilePattern) { $instanceKey = $Matches[1] }
            elseif ($fileName -match $sfxFilePattern) { $instanceKey = $Matches[1] }
            else {
                if ($fileName.StartsWith($BaseNameToMatch)) {
                    $basePlusExtMatch = $fileName -match "^($literalBase(\.[^.\s]+)?)"
                    if ($basePlusExtMatch) {
                        $potentialKey = $Matches[1]
                        if ($fileName -match ([regex]::Escape($potentialKey) + "\.\d{3,}") -or `
                                $fileName -match ([regex]::Escape($potentialKey) + "\.manifest\.[a-zA-Z0-9]+$") -or `
                                $fileName -eq $potentialKey) {
                            $instanceKey = $potentialKey
                        }
                    }
                }
            }

            if ($null -eq $instanceKey) {
                & $LocalWriteLog -Message "WebDAV.Target/GroupHelper: Could not determine instance key for remote file '$fileName'. Base: '$BaseNameToMatch', PrimaryExt: '$PrimaryArchiveExtension'. Skipping." -Level "VERBOSE"
                continue
            }

            if (-not $instances.ContainsKey($instanceKey)) {
                $instances[$instanceKey] = @{ SortTime = $fileSortTime; Files = [System.Collections.Generic.List[object]]::new() }
            }
            # Store a custom object with name and sort time for each file, as we don't have full FileInfo
            $instances[$instanceKey].Files.Add(@{ Name = $fileName; SortTime = $fileSortTime; FullHref = $hrefNode.InnerText; Size = $fileSize })

            if ($fileName -match "$literalExt\.001$") {
                if ($fileSortTime -lt $instances[$instanceKey].SortTime) { $instances[$instanceKey].SortTime = $fileSortTime }
            }
        }

        foreach ($keyToRefine in $instances.Keys) {
            if ($instances[$keyToRefine].Files.Count -gt 0) {
                $firstVolumeFileObj = $instances[$keyToRefine].Files | Where-Object { $_.Name -match ([regex]::Escape($keyToRefine) + "\.001$") } | Sort-Object SortTime | Select-Object -First 1
                if (-not $firstVolumeFileObj -and $keyToRefine.EndsWith($PrimaryArchiveExtension)) {
                    $firstVolumeFileObj = $instances[$keyToRefine].Files | Where-Object { $_.Name -eq $keyToRefine } | Sort-Object SortTime | Select-Object -First 1
                }
                if ($firstVolumeFileObj -and $firstVolumeFileObj.SortTime -lt $instances[$keyToRefine].SortTime) {
                    $instances[$keyToRefine].SortTime = $firstVolumeFileObj.SortTime
                }
                elseif (-not $firstVolumeFileObj) {
                    # If no .001 or direct match, use earliest file in group
                    $earliestFileInGroup = $instances[$keyToRefine].Files | Sort-Object SortTime | Select-Object -First 1
                    if ($earliestFileInGroup -and $earliestFileInGroup.SortTime -lt $instances[$keyToRefine].SortTime) {
                        $instances[$keyToRefine].SortTime = $earliestFileInGroup.SortTime
                    }
                }
            }
        }

    }
    catch {
        & $LocalWriteLog -Message "WebDAV.Target/GroupHelper: Error listing or processing files from '$fullDirectoryUrl'. Error: $($_.Exception.Message)" -Level "ERROR"
        if ($_.Exception.Response) { & $LocalWriteLog -Message "  Status: $($_.Exception.Response.StatusCode) $($_.Exception.Response.StatusDescription)" -Level "ERROR" }
    }
    & $LocalWriteLog -Message "WebDAV.Target/GroupHelper: Found $($instances.Keys.Count) distinct instances in '$RemoteDirectoryToList' for base '$BaseNameToMatch'."
    return $instances
}
#endregion

#region --- WebDAV Target Connectivity Test Function ---
function Test-PoShBackupTargetConnectivity {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$TargetSpecificSettings,
        [Parameter(Mandatory = $false)]
        [string]$CredentialsSecretName, # For WebDAV, this is in TargetSpecificSettings
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )
    # PSSA Appeasement: Use the parameter for logging context.
    & $Logger -Message "  - WebDAV.Target: Testing connectivity with secret name hint: '$CredentialsSecretName'." -Level "DEBUG" -ErrorAction SilentlyContinue
    
    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }
    
    $webDAVUrl = $TargetSpecificSettings.WebDAVUrl
    $secretName = $TargetSpecificSettings.CredentialsSecretName
    
    & $LocalWriteLog -Message "  - WebDAV Target: Testing connectivity to URL '$webDAVUrl'..." -Level "INFO"

    if (-not $PSCmdlet.ShouldProcess($webDAVUrl, "Test WebDAV Connection (PROPFIND)")) {
        return @{ Success = $false; Message = "WebDAV connection test skipped by user." }
    }

    $credential = Get-PSCredentialFromSecretInternal-WebDAV -SecretName $secretName -Logger $Logger
    if ($null -eq $credential) {
        return @{ Success = $false; Message = "Failed to retrieve PSCredential from secret '$secretName'." }
    }

    try {
        $timeout = if ($TargetSpecificSettings.ContainsKey('RequestTimeoutSec')) { $TargetSpecificSettings.RequestTimeoutSec } else { 30 }
        $headers = @{"Depth" = "0" }
        Invoke-WebRequest -Uri $webDAVUrl -Method "PROPFIND" -Credential $credential -Headers $headers -TimeoutSec $timeout -ErrorAction Stop -OutNull
        
        $successMessage = "Successfully connected to '$webDAVUrl' and received a valid response."
        & $LocalWriteLog -Message "    - SUCCESS: $successMessage" -Level "SUCCESS"
        return @{ Success = $true; Message = $successMessage }

    }
    catch {
        $errorMessage = "Failed to connect or get a valid response from '$webDAVUrl'. Error: $($_.Exception.Message)"
        if ($_.Exception.Response) { $errorMessage += " Status: $($_.Exception.Response.StatusCode) $($_.Exception.Response.StatusDescription)" }
        & $LocalWriteLog -Message "    - FAILED: $errorMessage" -Level "ERROR"
        return @{ Success = $false; Message = $errorMessage }
    }
}
#endregion

#region --- WebDAV Target Settings Validation Function ---
function Invoke-PoShBackupWebDAVTargetSettingsValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$TargetInstanceConfiguration, # CHANGED
        [Parameter(Mandatory = $true)]
        [string]$TargetInstanceName,
        [Parameter(Mandatory = $true)]
        [ref]$ValidationMessagesListRef,
        [Parameter(Mandatory = $false)]
        [scriptblock]$Logger
    )

    # PSSA Appeasement: Use the Logger parameter
    & $Logger -Message "WebDAV.Target/Invoke-PoShBackupWebDAVTargetSettingsValidation: Logger active for '$TargetInstanceName'." -Level "DEBUG" -ErrorAction SilentlyContinue

    # --- NEW: Extract settings from the main instance configuration ---
    $TargetSpecificSettings = $TargetInstanceConfiguration.TargetSpecificSettings
    $RemoteRetentionSettings = $TargetInstanceConfiguration.RemoteRetentionSettings
    # --- END NEW ---

    $fullPathToSettings = "Configuration.BackupTargets.$TargetInstanceName.TargetSpecificSettings"
    $fullPathToRetentionSettings = "Configuration.BackupTargets.$TargetInstanceName.RemoteRetentionSettings"

    if (-not ($TargetSpecificSettings -is [hashtable])) {
        $ValidationMessagesListRef.Value.Add("WebDAV Target '$TargetInstanceName': 'TargetSpecificSettings' must be a Hashtable, but found type '$($TargetSpecificSettings.GetType().Name)'. Path: '$fullPathToSettings'.")
        return
    }

    if (-not $TargetSpecificSettings.ContainsKey('WebDAVUrl') -or -not ($TargetSpecificSettings.WebDAVUrl -is [string]) -or [string]::IsNullOrWhiteSpace($TargetSpecificSettings.WebDAVUrl)) {
        $ValidationMessagesListRef.Value.Add("WebDAV Target '$TargetInstanceName': 'WebDAVUrl' in 'TargetSpecificSettings' is missing, not a string, or empty. Path: '$fullPathToSettings.WebDAVUrl'.")
    }
    else {
        try {
            [System.Uri]$TargetSpecificSettings.WebDAVUrl | Out-Null
            if (-not ($TargetSpecificSettings.WebDAVUrl -match "^https?://")) {
                $ValidationMessagesListRef.Value.Add("WebDAV Target '$TargetInstanceName': 'WebDAVUrl' ('$($TargetSpecificSettings.WebDAVUrl)') must be a valid HTTP or HTTPS URL. Path: '$fullPathToSettings.WebDAVUrl'.")
            }
        }
        catch {
            $ValidationMessagesListRef.Value.Add("WebDAV Target '$TargetInstanceName': 'WebDAVUrl' ('$($TargetSpecificSettings.WebDAVUrl)') is not a valid URI. Error: $($_.Exception.Message). Path: '$fullPathToSettings.WebDAVUrl'.")
        }
    }

    if (-not $TargetSpecificSettings.ContainsKey('CredentialsSecretName') -or -not ($TargetSpecificSettings.CredentialsSecretName -is [string]) -or [string]::IsNullOrWhiteSpace($TargetSpecificSettings.CredentialsSecretName)) {
        $ValidationMessagesListRef.Value.Add("WebDAV Target '$TargetInstanceName': 'CredentialsSecretName' in 'TargetSpecificSettings' is missing, not a string, or empty. This secret should store a PSCredential object. Path: '$fullPathToSettings.CredentialsSecretName'.")
    }

    if ($TargetSpecificSettings.ContainsKey('RemotePath') -and (-not ($TargetSpecificSettings.RemotePath -is [string]))) {
        $ValidationMessagesListRef.Value.Add("WebDAV Target '$TargetInstanceName': 'RemotePath' in 'TargetSpecificSettings' must be a string if defined. Path: '$fullPathToSettings.RemotePath'.")
    }

    if ($TargetSpecificSettings.ContainsKey('CreateJobNameSubdirectory') -and -not ($TargetSpecificSettings.CreateJobNameSubdirectory -is [boolean])) {
        $ValidationMessagesListRef.Value.Add("WebDAV Target '$TargetInstanceName': 'CreateJobNameSubdirectory' in 'TargetSpecificSettings' must be a boolean (`$true` or `$false`) if defined. Path: '$fullPathToSettings.CreateJobNameSubdirectory'.")
    }

    if ($TargetSpecificSettings.ContainsKey('RequestTimeoutSec') -and (-not ($TargetSpecificSettings.RequestTimeoutSec -is [int] -and $TargetSpecificSettings.RequestTimeoutSec -gt 0))) {
        $ValidationMessagesListRef.Value.Add("WebDAV Target '$TargetInstanceName': 'RequestTimeoutSec' in 'TargetSpecificSettings' must be a positive integer if defined. Path: '$fullPathToSettings.RequestTimeoutSec'.")
    }

    if ($null -ne $RemoteRetentionSettings) {
        if (-not ($RemoteRetentionSettings -is [hashtable])) {
            $ValidationMessagesListRef.Value.Add("WebDAV Target '$TargetInstanceName': 'RemoteRetentionSettings' must be a Hashtable if defined. Path: '$fullPathToRetentionSettings'.")
        }
        elseif ($RemoteRetentionSettings.ContainsKey('KeepCount')) {
            if (-not ($RemoteRetentionSettings.KeepCount -is [int]) -or $RemoteRetentionSettings.KeepCount -le 0) {
                $ValidationMessagesListRef.Value.Add("WebDAV Target '$TargetInstanceName': 'RemoteRetentionSettings.KeepCount' must be an integer greater than 0 if defined. Path: '$fullPathToRetentionSettings.KeepCount'.")
            }
        }
    }
}
#endregion

#region --- WebDAV Target Transfer Function ---
function Invoke-PoShBackupTargetTransfer {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalArchivePath,
        [Parameter(Mandatory = $true)]
        [hashtable]$TargetInstanceConfiguration,
        [Parameter(Mandatory = $true)]
        [string]$JobName,
        [Parameter(Mandatory = $true)]
        [string]$ArchiveFileName,
        [Parameter(Mandatory = $true)]
        [string]$ArchiveBaseName,
        [Parameter(Mandatory = $true)]
        [string]$ArchiveExtension,
        [Parameter(Mandatory = $true)]
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger,
        [Parameter(Mandatory = $true)]
        [hashtable]$EffectiveJobConfig,
        [Parameter(Mandatory = $true)]
        [long]$LocalArchiveSizeBytes,
        [Parameter(Mandatory = $true)]
        [datetime]$LocalArchiveCreationTimestamp,
        [Parameter(Mandatory = $true)]
        [bool]$PasswordInUse,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCmdlet]$PSCmdlet
    )

    # PSSA Appeasement: Use the Logger and other parameters
    if ($PSBoundParameters.ContainsKey('Logger') -and $null -ne $Logger) {
        & $Logger -Message ("WebDAV.Target/Invoke-PoShBackupTargetTransfer: Logger active for Job '{0}', Target '{1}', File '{2}'." -f $JobName, $TargetInstanceConfiguration._TargetInstanceName_, $ArchiveFileName) -Level "DEBUG" -ErrorAction SilentlyContinue
        
        # Ensure these parameters are used in a way PSSA recognizes
        $contextMessage = "  - WebDAV.Target Context (PSSA): Job='{0}', CreationTS='{1}', PwdInUse='{2}'." -f $EffectiveJobConfig.JobName, $LocalArchiveCreationTimestamp, $PasswordInUse
        & $Logger -Message $contextMessage -Level "DEBUG" -ErrorAction SilentlyContinue
    }

    $LocalWriteLog = { param([string]$MessageParam, [string]$LevelParam = "INFO") & $Logger -Message $MessageParam -Level $LevelParam }
    $targetNameForLog = $TargetInstanceConfiguration._TargetInstanceName_
    & $LocalWriteLog -Message ("`n[INFO] WebDAV Target: Starting transfer for Job '{0}' to Target '{1}', File '{2}'." -f $JobName, $targetNameForLog, $ArchiveFileName) -Level "INFO"

    $result = @{
        Success          = $false
        RemotePath       = $null
        ErrorMessage     = $null
        TransferSize     = 0
        TransferDuration = New-TimeSpan
    }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $webDAVSettings = $TargetInstanceConfiguration.TargetSpecificSettings
    $webDAVUrlBase = $webDAVSettings.WebDAVUrl.TrimEnd("/")
    $credentialSecretName = $webDAVSettings.CredentialsSecretName
    $credentialVaultName = $webDAVSettings.CredentialsVaultName
    $remotePathRelative = ($webDAVSettings.RemotePath -replace "^/+", "").TrimEnd("/")
    $createJobSubDir = if ($webDAVSettings.ContainsKey('CreateJobNameSubdirectory')) { $webDAVSettings.CreateJobNameSubdirectory } else { $false }
    $requestTimeoutSec = if ($webDAVSettings.ContainsKey('RequestTimeoutSec')) { $webDAVSettings.RequestTimeoutSec } else { 120 }

    if ([string]::IsNullOrWhiteSpace($webDAVUrlBase) -or [string]::IsNullOrWhiteSpace($credentialSecretName)) {
        $result.ErrorMessage = "WebDAV Target '$targetNameForLog': WebDAVUrl or CredentialsSecretName is missing."
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"; $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed; return $result
    }

    $credential = Get-PSCredentialFromSecretInternal-WebDAV -SecretName $credentialSecretName -VaultName $credentialVaultName -Logger $Logger
    if ($null -eq $credential) {
        $result.ErrorMessage = "WebDAV Target '$targetNameForLog': Failed to retrieve PSCredential from secret '$credentialSecretName'."
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"; $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed; return $result
    }

    $remoteFinalRelativeDirForJob = if ($createJobSubDir) { "$remotePathRelative/$JobName".TrimStart("/") } else { $remotePathRelative }
    $remoteFinalRelativeDirForJob = $remoteFinalRelativeDirForJob.TrimStart("/")

    $fullRemoteArchivePath = ($webDAVUrlBase + "/" + $remoteFinalRelativeDirForJob.TrimStart("/") + "/" + $ArchiveFileName).TrimEnd("/")
    $result.RemotePath = $fullRemoteArchivePath

    & $LocalWriteLog -Message ("  - WebDAV Target '{0}': Base URL '{1}', Relative Path for Job '{2}'." -f $targetNameForLog, $webDAVUrlBase, $remoteFinalRelativeDirForJob) -Level "DEBUG"
    & $LocalWriteLog -Message ("    - Full Remote Archive Destination URL: '{0}'" -f $fullRemoteArchivePath) -Level "DEBUG"

    if ($IsSimulateMode.IsPresent) {
        & $LocalWriteLog -Message "SIMULATE: WebDAV.Target '$targetNameForLog': Would connect to '$webDAVUrlBase' with retrieved credentials." -Level "SIMULATE"
        & $LocalWriteLog -Message "SIMULATE: WebDAV.Target '$targetNameForLog': Would ensure remote directory structure for relative path '$remoteFinalRelativeDirForJob' exists." -Level "SIMULATE"
        & $LocalWriteLog -Message "SIMULATE: WebDAV.Target '$targetNameForLog': Would upload '$LocalArchivePath' to '$fullRemoteArchivePath'." -Level "SIMULATE"
        $result.Success = $true; $result.TransferSize = $LocalArchiveSizeBytes
        if ($TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings') -and $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -gt 0) {
            & $LocalWriteLog -Message ("SIMULATE: WebDAV.Target '{0}': Would apply remote retention (KeepCount: {1}) in relative path '{2}'." -f $targetNameForLog, $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount, $remoteFinalRelativeDirForJob) -Level "SIMULATE"
        }
        $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed; return $result
    }

    if (-not $PSCmdlet.ShouldProcess($fullRemoteArchivePath, "Transfer Archive via WebDAV")) {
        $result.ErrorMessage = "WebDAV Target '$targetNameForLog': Transfer to '$fullRemoteArchivePath' skipped by user (ShouldProcess)."
        & $LocalWriteLog -Message "[WARNING] $($result.ErrorMessage)" -Level "WARNING"; $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed; return $result
    }

    try {
        $ensurePathResult = Initialize-WebDAVRemotePathInternal -BaseWebDAVUrl $webDAVUrlBase -RelativePathToEnsure $remoteFinalRelativeDirForJob -Credential $credential -RequestTimeoutSec $requestTimeoutSec -Logger $Logger -IsSimulateMode:$IsSimulateMode -PSCmdletInstance $PSCmdlet
        if (-not $ensurePathResult.Success) { throw ("Failed to ensure WebDAV remote directory structure. Error: " + $ensurePathResult.ErrorMessage) }

        & $LocalWriteLog -Message ("  - WebDAV Target '{0}': Uploading '{1}' to '{2}'..." -f $targetNameForLog, $LocalArchivePath, $fullRemoteArchivePath) -Level "INFO"
        Invoke-WebRequest -Uri $fullRemoteArchivePath -Method Put -InFile $LocalArchivePath -Credential $credential -ContentType "application/octet-stream" -TimeoutSec $requestTimeoutSec -ErrorAction Stop
        $result.Success = $true; $result.TransferSize = $LocalArchiveSizeBytes
        & $LocalWriteLog -Message ("    - WebDAV Target '{0}': File uploaded successfully." -f $targetNameForLog) -Level "SUCCESS"

        if ($TargetInstanceConfiguration.ContainsKey('RemoteRetentionSettings') -and `
                $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -is [int] -and `
                $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount -gt 0) {
            $remoteKeepCount = $TargetInstanceConfiguration.RemoteRetentionSettings.KeepCount
            & $LocalWriteLog -Message ("  - WebDAV Target '{0}': Applying remote retention (KeepCount: {1}) in relative path '{2}'." -f $targetNameForLog, $remoteKeepCount, $remoteFinalRelativeDirForJob) -Level "INFO"

            $remoteInstances = Group-RemoteWebDAVBackupInstancesInternal -BaseWebDAVUrl $webDAVUrlBase `
                -RemoteDirectoryToList $remoteFinalRelativeDirForJob `
                -Credential $credential `
                -RequestTimeoutSec $requestTimeoutSec `
                -BaseNameToMatch $ArchiveBaseName `
                -PrimaryArchiveExtension $ArchiveExtension `
                -Logger $Logger

            if ($remoteInstances.Count -gt $remoteKeepCount) {
                $sortedInstances = $remoteInstances.GetEnumerator() | Sort-Object { $_.Value.SortTime } -Descending
                $instancesToDelete = $sortedInstances | Select-Object -Skip $remoteKeepCount
                & $LocalWriteLog -Message ("    - WebDAV Target '{0}': Found {1} remote instances. Will delete files for {2} older instance(s)." -f $targetNameForLog, $remoteInstances.Count, $instancesToDelete.Count) -Level "INFO"

                foreach ($instanceEntry in $instancesToDelete) {
                    $instanceKeyToDelete = $instanceEntry.Name
                    & $LocalWriteLog -Message "      - WebDAV Target '{0}': Preparing to delete instance files for '$instanceKeyToDelete' (SortTime: $($instanceEntry.Value.SortTime))." -Level "WARNING"
                    foreach ($remoteFileObjInInstance in $instanceEntry.Value.Files) {
                        $fileToDeleteUrl = ($webDAVUrlBase.TrimEnd("/") + $remoteFileObjInInstance.FullHref).TrimEnd("/") # FullHref from PROPFIND
                        if (-not $PSCmdlet.ShouldProcess($fileToDeleteUrl, "Delete Remote WebDAV File/Part (Retention)")) {
                            & $LocalWriteLog -Message ("        - Deletion of '{0}' skipped by user." -f $fileToDeleteUrl) -Level "WARNING"; continue
                        }
                        & $LocalWriteLog -Message ("        - Deleting: '{0}' (Original SortTime: $($remoteFileObjInInstance.SortTime))" -f $fileToDeleteUrl) -Level "WARNING"
                        try {
                            Invoke-WebRequest -Uri $fileToDeleteUrl -Method "DELETE" -Credential $credential -TimeoutSec $requestTimeoutSec -ErrorAction Stop
                            & $LocalWriteLog "          - Status: DELETED (Remote WebDAV Retention)" -Level "SUCCESS"
                        }
                        catch {
                            $deleteErrorMsg = "Failed to delete remote WebDAV file '$fileToDeleteUrl'. Error: $($_.Exception.Message)"
                            if ($_.Exception.Response) { $deleteErrorMsg += " Status: $($_.Exception.Response.StatusCode) $($_.Exception.Response.StatusDescription)" }
                            & $LocalWriteLog "          - Status: FAILED! $deleteErrorMsg" -Level "ERROR"
                            if ([string]::IsNullOrWhiteSpace($result.ErrorMessage)) { $result.ErrorMessage = $deleteErrorMsg }
                            else { $result.ErrorMessage += "; $deleteErrorMsg" }
                        }
                    }
                }
            }
            else { & $LocalWriteLog ("    - WebDAV Target '{0}': No old instances to delete based on retention count {1} (Found: $($remoteInstances.Count))." -f $targetNameForLog, $remoteKeepCount) -Level "INFO" }
        }

    }
    catch {
        $result.ErrorMessage = "WebDAV Target '$targetNameForLog': Operation failed. Error: $($_.Exception.Message)"
        if ($_.Exception.Response) { $result.ErrorMessage += " Status: $($_.Exception.Response.StatusCode) $($_.Exception.Response.StatusDescription)" }
        & $LocalWriteLog -Message "[ERROR] $($result.ErrorMessage)" -Level "ERROR"; $result.Success = $false
    }

    $stopwatch.Stop(); $result.TransferDuration = $stopwatch.Elapsed
    & $LocalWriteLog -Message ("[INFO] WebDAV Target: Finished transfer attempt for Job '{0}' to Target '{1}', File '{2}'. Success: {3}." -f $JobName, $targetNameForLog, $ArchiveFileName, $result.Success) -Level "INFO"
    return $result
}
#endregion

Export-ModuleMember -Function Invoke-PoShBackupTargetTransfer, Invoke-PoShBackupWebDAVTargetSettingsValidation, Test-PoShBackupTargetConnectivity
