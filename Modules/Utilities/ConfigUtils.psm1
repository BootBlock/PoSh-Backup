# Modules\Utilities\ConfigUtils.psm1
<#
.SYNOPSIS
    Provides utility functions for safely retrieving values from PoSh-Backup
    configuration hashtables.
.DESCRIPTION
    This module contains the Get-ConfigValue function, which is used to access
    keys within configuration hashtables (typically loaded from .psd1 files),
    providing a default value if the key is not found or if the configuration
    object itself is null or not a hashtable. This helps prevent errors from
    missing configuration keys and simplifies default value handling.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    25-May-2025
    LastModified:   25-May-2025
    Purpose:        Configuration value retrieval utility for PoSh-Backup.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Helper Function Get-ConfigValue ---
<#
.SYNOPSIS
    Retrieves a value from a configuration object by key, returning a default value if the key is not found.
.DESCRIPTION
    This function safely accesses a value from a hashtable or PSObject using the specified key.
    If the key does not exist or the configuration object is null or unsuitable, it returns the provided default value.
.PARAMETER ConfigObject
    The configuration object (hashtable or PSObject) to retrieve the value from.
.PARAMETER Key
    The key or property name to look up in the configuration object.
.PARAMETER DefaultValue
    The value to return if the key is not found or the configuration object is unsuitable.
.EXAMPLE
    $value = Get-ConfigValue -ConfigObject $config -Key 'Path' -DefaultValue 'C:\Default'
.NOTES
    Author: Joe Cox/AI Assistant
#>
function Get-ConfigValue {
    [CmdletBinding()]
    param (
        [object]$ConfigObject, # Can be a hashtable or any object with properties
        [string]$Key,
        [object]$DefaultValue  # The value to return if the key is not found or object is unsuitable
    )

    # Check if ConfigObject is a hashtable and contains the key
    if ($null -ne $ConfigObject -and $ConfigObject -is [hashtable] -and $ConfigObject.ContainsKey($Key)) {
        return $ConfigObject[$Key]
    }
    # Check if ConfigObject is a PSObject (like from Import-Csv) and has the property
    # This also handles cases where $ConfigObject might be a PSCustomObject
    elseif ($null -ne $ConfigObject -and -not ($ConfigObject -is [hashtable]) -and `
            ($null -ne $ConfigObject.PSObject) -and `
            ($null -ne $ConfigObject.PSObject.Properties) -and `
            ($null -ne $ConfigObject.PSObject.Properties.Name) -and `
            $ConfigObject.PSObject.Properties.Name -contains $Key) {
        return $ConfigObject.$Key
    }

    # If key not found or ConfigObject is unsuitable, return the default value
    return $DefaultValue
}
#endregion

#region --- Helper Function Get-RequiredConfigValue ---
function Get-RequiredConfigValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$JobConfig,
        [Parameter(Mandatory)]
        [hashtable]$GlobalConfig,
        [Parameter(Mandatory)]
        [string]$JobKey,
        [Parameter(Mandatory)]
        [string]$GlobalKey
    )

    $jobValue = Get-ConfigValue -ConfigObject $JobConfig -Key $JobKey -DefaultValue $null
    if ($null -ne $jobValue) {
        return $jobValue
    }
    $globalValue = Get-ConfigValue -ConfigObject $GlobalConfig -Key $GlobalKey -DefaultValue $null
    if ($null -ne $globalValue) {
        return $globalValue
    }
    throw "Configuration Error: A required setting is missing. The key '$JobKey' was not found in the job's configuration, and the corresponding default key '$GlobalKey' was not found in Default.psd1 or User.psd1. The script cannot proceed without this setting."
}
#endregion

#region --- Environment Variable Expansion ---
function Expand-EnvironmentVariablesInConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$ConfigObject,
        [Parameter(Mandatory = $true)]
        [string[]]$KeysToExpand,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Logger
    )

    & $Logger -Message "ConfigUtils/Expand-EnvironmentVariablesInConfig: Beginning expansion for $($KeysToExpand.Count) specified keys." -Level "DEBUG"

    foreach ($key in $KeysToExpand) {
        if ($ConfigObject.ContainsKey($key)) {
            $value = $ConfigObject[$key]
            if ($value -is [string]) {
                $ConfigObject[$key] = [System.Environment]::ExpandEnvironmentVariables($value)
            }
            elseif ($value -is [array]) {
                $expandedArray = for ($i = 0; $i -lt $value.Count; $i++) {
                    if ($value[$i] -is [string]) {
                        [System.Environment]::ExpandEnvironmentVariables($value[$i])
                    }
                    else {
                        $value[$i] # Return non-string items as-is
                    }
                }
                $ConfigObject[$key] = $expandedArray
            }
        }
    }
    return $ConfigObject
}
#endregion

Export-ModuleMember -Function Get-ConfigValue, Expand-EnvironmentVariablesInConfig, Get-RequiredConfigValue
