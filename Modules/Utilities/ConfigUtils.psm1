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

Export-ModuleMember -Function Get-ConfigValue
