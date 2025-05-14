# PowerShell Module: PoShBackupValidator.psm1
# Description: Provides advanced schema-based validation for PoSh-Backup configuration files.
# Version: 1.0

#region --- Module-Scoped Schema Definition ---
$Script:PoShBackup_ConfigSchema = @{
    # Top-level keys
    SevenZipPath                    = @{ Type = 'string'; Required = $true; ValidateScript = { Test-Path -LiteralPath $_ -PathType Leaf } } 
    DefaultDestinationDir           = @{ Type = 'string'; Required = $false }
    HideSevenZipOutput              = @{ Type = 'boolean'; Required = $false }
    PauseBeforeExit                 = @{ Type = 'string'; Required = $false; AllowedValues = @("Always", "Never", "OnFailure", "OnWarning", "OnFailureOrWarning", "True", "False") } 
    EnableFileLogging               = @{ Type = 'boolean'; Required = $false }
    LogDirectory                    = @{ Type = 'string'; Required = $false } 
    ReportGeneratorType = @{ 
        Type = 'string_or_array'; # MODIFIED TO ALLOW ARRAY
        Required = $false; 
        AllowedValues = @("HTML", "CSV", "JSON", "XML", "TXT", "MD", "None") 
    }
    HtmlReportDirectory             = @{ Type = 'string'; Required = $false }
    CsvReportDirectory              = @{ Type = 'string'; Required = $false }
    JsonReportDirectory             = @{ Type = 'string'; Required = $false }
    XmlReportDirectory              = @{ Type = 'string'; Required = $false }
    TxtReportDirectory              = @{ Type = 'string'; Required = $false }
    MdReportDirectory               = @{ Type = 'string'; Required = $false }
    HtmlReportTitlePrefix           = @{ Type = 'string'; Required = $false }
    HtmlReportLogoPath              = @{ Type = 'string'; Required = $false }
    HtmlReportCustomCssPath         = @{ Type = 'string'; Required = $false }
    HtmlReportCompanyName           = @{ Type = 'string'; Required = $false }
    HtmlReportTheme                 = @{ Type = 'string'; Required = $false } 
    HtmlReportOverrideCssVariables  = @{ Type = 'hashtable'; Required = $false }
    HtmlReportShowSummary           = @{ Type = 'boolean'; Required = $false }
    HtmlReportShowConfiguration     = @{ Type = 'boolean'; Required = $false }
    HtmlReportShowHooks             = @{ Type = 'boolean'; Required = $false }
    HtmlReportShowLogEntries        = @{ Type = 'boolean'; Required = $false }
    EnableVSS                       = @{ Type = 'boolean'; Required = $false }
    DefaultVSSContextOption         = @{ Type = 'string'; Required = $false; AllowedValues = @("Persistent", "Persistent NoWriters", "Volatile NoWriters") }
    VSSMetadataCachePath            = @{ Type = 'string'; Required = $false } 
    VSSPollingTimeoutSeconds        = @{ Type = 'int'; Required = $false; Min = 1; Max = 3600 }
    VSSPollingIntervalSeconds       = @{ Type = 'int'; Required = $false; Min = 1; Max = 600 }
    EnableRetries                   = @{ Type = 'boolean'; Required = $false }
    MaxRetryAttempts                = @{ Type = 'int'; Required = $false; Min = 0 }
    RetryDelaySeconds               = @{ Type = 'int'; Required = $false; Min = 0 }
    DefaultSevenZipProcessPriority  = @{ Type = 'string'; Required = $false; AllowedValues = @("Idle", "BelowNormal", "Normal", "AboveNormal", "High") }
    MinimumRequiredFreeSpaceGB      = @{ Type = 'int'; Required = $false; Min = 0 } 
    ExitOnLowSpaceIfBelowMinimum    = @{ Type = 'boolean'; Required = $false }
    DefaultTestArchiveAfterCreation = @{ Type = 'boolean'; Required = $false }
    DefaultArchiveDateFormat        = @{ Type = 'string'; Required = $false } 
    DefaultThreadCount              = @{ Type = 'int'; Required = $false; Min = 0 }
    DefaultArchiveType              = @{ Type = 'string'; Required = $false }
    DefaultArchiveExtension         = @{ Type = 'string'; Required = $false } 
    DefaultCompressionLevel         = @{ Type = 'string'; Required = $false }
    DefaultCompressionMethod        = @{ Type = 'string'; Required = $false }
    DefaultDictionarySize           = @{ Type = 'string'; Required = $false }
    DefaultWordSize                 = @{ Type = 'string'; Required = $false }
    DefaultSolidBlockSize           = @{ Type = 'string'; Required = $false }
    DefaultCompressOpenFiles        = @{ Type = 'boolean'; Required = $false }
    DefaultScriptExcludeRecycleBin  = @{ Type = 'string'; Required = $false }
    DefaultScriptExcludeSysVolInfo  = @{ Type = 'string'; Required = $false }
    EnableAdvancedSchemaValidation  = @{ Type = 'boolean'; Required = $false } # Schema to validate itself!
    _PoShBackup_PSScriptRoot        = @{ Type = 'string'; Required = $false }

    BackupLocations = @{
        Type = 'hashtable'
        Required = $true 
        Schema = @{ 
            Path                    = @{ Type = 'string_or_array'; Required = $true } 
            Name                    = @{ Type = 'string'; Required = $true }
            DestinationDir          = @{ Type = 'string'; Required = $false }
            RetentionCount          = @{ Type = 'int'; Required = $false; Min = 0 }
            DeleteToRecycleBin      = @{ Type = 'boolean'; Required = $false }
            UsePassword             = @{ Type = 'boolean'; Required = $false }
            CredentialUserNameHint  = @{ Type = 'string'; Required = $false }
            EnableVSS               = @{ Type = 'boolean'; Required = $false }
            VSSContextOption        = @{ Type = 'string'; Required = $false; AllowedValues = @("Persistent", "Persistent NoWriters", "Volatile NoWriters") }
            SevenZipProcessPriority = @{ Type = 'string'; Required = $false; AllowedValues = @("Idle", "BelowNormal", "Normal", "AboveNormal", "High") }
            ReportGeneratorType     = @{ Type = 'string_or_array'; Required = $false; AllowedValues = @("HTML", "CSV", "JSON", "XML", "TXT", "MD", "None") }
            ArchiveType             = @{ Type = 'string'; Required = $false }
            ArchiveExtension        = @{ Type = 'string'; Required = $false } 
            ArchiveDateFormat       = @{ Type = 'string'; Required = $false } 
            ThreadsToUse            = @{ Type = 'int'; Required = $false; Min = 0 }
            CompressionLevel        = @{ Type = 'string'; Required = $false }
            CompressionMethod       = @{ Type = 'string'; Required = $false }
            DictionarySize          = @{ Type = 'string'; Required = $false }
            WordSize                = @{ Type = 'string'; Required = $false }
            SolidBlockSize          = @{ Type = 'string'; Required = $false }
            CompressOpenFiles       = @{ Type = 'boolean'; Required = $false }
            AdditionalExclusions    = @{ Type = 'array'; Required = $false }
            MinimumRequiredFreeSpaceGB   = @{ Type = 'int'; Required = $false; Min = 0 }
            ExitOnLowSpaceIfBelowMinimum = @{ Type = 'boolean'; Required = $false }
            TestArchiveAfterCreation     = @{ Type = 'boolean'; Required = $false }
            HtmlReportDirectory          = @{ Type = 'string'; Required = $false }
            CsvReportDirectory           = @{ Type = 'string'; Required = $false }
            JsonReportDirectory          = @{ Type = 'string'; Required = $false }
            XmlReportDirectory           = @{ Type = 'string'; Required = $false }
            TxtReportDirectory           = @{ Type = 'string'; Required = $false }
            MdReportDirectory            = @{ Type = 'string'; Required = $false } 
            HtmlReportTheme              = @{ Type = 'string'; Required = $false }
            HtmlReportTitlePrefix        = @{ Type = 'string'; Required = $false }
            HtmlReportLogoPath           = @{ Type = 'string'; Required = $false }
            HtmlReportCustomCssPath      = @{ Type = 'string'; Required = $false }
            HtmlReportCompanyName        = @{ Type = 'string'; Required = $false }
            HtmlReportOverrideCssVariables = @{ Type = 'hashtable'; Required = $false }
            HtmlReportShowSummary        = @{ Type = 'boolean'; Required = $false }
            HtmlReportShowConfiguration  = @{ Type = 'boolean'; Required = $false }
            HtmlReportShowHooks          = @{ Type = 'boolean'; Required = $false }
            HtmlReportShowLogEntries     = @{ Type = 'boolean'; Required = $false }
            PreBackupScriptPath          = @{ Type = 'string'; Required = $false }
            PostBackupScriptOnSuccessPath= @{ Type = 'string'; Required = $false }
            PostBackupScriptOnFailurePath= @{ Type = 'string'; Required = $false }
            PostBackupScriptAlwaysPath   = @{ Type = 'string'; Required = $false }
        }
    }
    BackupSets = @{
        Type = 'hashtable'
        Required = $false 
        Schema = @{ 
            JobNames     = @{ Type = 'array'; Required = $true } 
            OnErrorInJob = @{ Type = 'string'; Required = $false; AllowedValues = @("StopSet", "ContinueSet") }
        }
    }
}
#endregion

#region --- Private Validation Logic ---
function Validate-AgainstSchemaRecursiveInternal { # Renamed to avoid conflict if module not removed
    param(
        [Parameter(Mandatory)]
        [object]$ConfigObject,
        [Parameter(Mandatory)]
        [hashtable]$Schema,
        [Parameter(Mandatory)]
        [ref]$ValidationMessages,
        [string]$CurrentPath = "Config"
    )

    if (-not ($ConfigObject -is [hashtable])) {
        $ValidationMessages.Value.Add("'$CurrentPath' is expected to be a Hashtable, but found type '$($ConfigObject.GetType().Name)'.")
        return
    }

    foreach ($schemaKey in $Schema.Keys) {
        $keyDefinition = $Schema[$schemaKey]
        $fullKeyPath = "$CurrentPath.$schemaKey"

        if (-not $ConfigObject.ContainsKey($schemaKey)) {
            if ($keyDefinition.Required -eq $true) {
                $ValidationMessages.Value.Add("Required key '$fullKeyPath' is missing.")
            }
            continue
        }

        $configValue = $ConfigObject[$schemaKey]
        $expectedType = $keyDefinition.Type.ToLowerInvariant()
        $actualType = if ($null -eq $configValue) { "null" } else { $configValue.GetType().Name.ToLowerInvariant() }
        
        $typeMatch = $false
        switch ($expectedType) {
            "string"           { if ($configValue -is [string]) { $typeMatch = $true } }
            "boolean"          { if ($configValue -is [bool]) { $typeMatch = $true } }
            "int"              { if ($configValue -is [int]) { $typeMatch = $true } }
            "hashtable"        { if ($configValue -is [hashtable]) { $typeMatch = $true } }
            "array"            { if ($configValue -is [array]) { $typeMatch = $true } }
            "string_or_array"  { if (($configValue -is [string]) -or ($configValue -is [array])) { $typeMatch = $true } }
            default            { $ValidationMessages.Value.Add("Unknown expected type '$($keyDefinition.Type)' in schema for '$fullKeyPath'."); continue }
        }

        if (-not $typeMatch) {
            $ValidationMessages.Value.Add("Type mismatch for '$fullKeyPath'. Expected '$($keyDefinition.Type)', found '$($configValue.GetType().Name)'.")
            continue 
        }

        if ($keyDefinition.ContainsKey("AllowedValues") -and $configValue -is [string]) {
            $allowed = $keyDefinition.AllowedValues | ForEach-Object { $_.ToString().ToLowerInvariant() }
            if ($configValue.ToString().ToLowerInvariant() -notin $allowed) {
                $ValidationMessages.Value.Add("Invalid value for '$fullKeyPath': '$configValue'. Allowed values (case-insensitive): $($keyDefinition.AllowedValues -join ', ').")
            }
        }
        if ($expectedType -eq "int") {
            if ($keyDefinition.ContainsKey("Min") -and $configValue -lt $keyDefinition.Min) {
                $ValidationMessages.Value.Add("Value for '$fullKeyPath' ($configValue) is less than minimum allowed ($($keyDefinition.Min)).")
            }
            if ($keyDefinition.ContainsKey("Max") -and $configValue -gt $keyDefinition.Max) {
                $ValidationMessages.Value.Add("Value for '$fullKeyPath' ($configValue) is greater than maximum allowed ($($keyDefinition.Max)).")
            }
        }

        if ($configValue -is [hashtable] -and $keyDefinition.ContainsKey("Schema")) {
            foreach ($itemKey in $configValue.Keys) {
                $itemValue = $configValue[$itemKey]
                Validate-AgainstSchemaRecursiveInternal -ConfigObject $itemValue -Schema $keyDefinition.Schema -ValidationMessages $ValidationMessages -CurrentPath "$fullKeyPath.$itemKey"
            }
        }
    }

    $allowUnknownKeys = $false 
    if (-not $allowUnknownKeys) {
        foreach ($configKey in $ConfigObject.Keys) {
            if (-not $Schema.ContainsKey($configKey)) {
                if ($configKey -ne '_PoShBackup_PSScriptRoot') {
                     $ValidationMessages.Value.Add("Unknown key '$CurrentPath.$configKey' found in configuration. Check for typos or if it's supported.")
                }
            }
        }
    }
}
#endregion

#region --- Exported Functions ---
function Invoke-PoShBackupConfigValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ConfigurationToValidate,

        [Parameter(Mandatory)]
        [ref]$ValidationMessagesListRef # Pass the list by reference to collect messages
    )

    # Use the $Script:PoShBackup_ConfigSchema defined in this module
    Validate-AgainstSchemaRecursiveInternal -ConfigObject $ConfigurationToValidate -Schema $Script:PoShBackup_ConfigSchema -ValidationMessages $ValidationMessagesListRef -CurrentPath "Configuration"
    
    # The function doesn't return true/false, it populates the $ValidationMessagesListRef
    # The caller will check if the list is empty.
}

Export-ModuleMember -Function Invoke-PoShBackupConfigValidation
#endregion
