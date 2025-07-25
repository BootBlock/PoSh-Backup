# Modules\ConfigManagement\ConfigLoader\MergeUtil.psm1
<#
.SYNOPSIS
    Sub-module for ConfigLoader. Provides utility for deep merging hashtables.
.DESCRIPTION
    This module contains the 'Merge-DeepHashtable' function, which is used to
    recursively merge two hashtables. This is primarily used for overlaying
    user configuration onto default configuration settings.
.NOTES
    Author:         Joe Cox/AI Assistant
    Version:        1.0.0
    DateCreated:    29-May-2025
    LastModified:   29-May-2025
    Purpose:        Hashtable merging utility for ConfigLoader.
    Prerequisites:  PowerShell 5.1+.
#>

#region --- Exported Function: Merge-DeepHashtable ---
function Merge-DeepHashtable {
<#
.SYNOPSIS
    Recursively merges two hashtables, overlaying the override onto the base.
.DESCRIPTION
    Takes a base hashtable and an override hashtable, and returns a new hashtable
    that is the result of a deep merge. Nested hashtables are merged recursively.
.PARAMETER Base
    The base hashtable to merge into.
.PARAMETER Override
    The hashtable whose values will override or extend the base.
.EXAMPLE
    $merged = Merge-DeepHashtable -Base $defaultConfig -Override $userConfig
    Returns a merged hashtable with userConfig values overlaid on defaultConfig.
.NOTES
    Used for configuration merging in ConfigLoader.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Base,
        [Parameter(Mandatory)]
        [hashtable]$Override
    )

    $merged = $Base.Clone() # Start with a clone of the base hashtable

    foreach ($key in $Override.Keys) {
        if ($merged.ContainsKey($key) -and $merged[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) {
            # If key exists in both and both values are hashtables, recurse
            $merged[$key] = Merge-DeepHashtable -Base $merged[$key] -Override $Override[$key]
        }
        else {
            # Otherwise, the override value replaces or adds the key
            $merged[$key] = $Override[$key]
        }
    }
    return $merged
}
#endregion

Export-ModuleMember -Function Merge-DeepHashtable
