# Tests\TestHelpers.psm1
# This module can contain helper functions or common setup for Pester tests.

# Example: Function to create a mock file object
function New-MockFile {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$FullName,
        [datetime]$CreationTime = (Get-Date),
        [long]$Length = 1024
    )
    return [PSCustomObject]@{
        Name           = $Name
        FullName       = $FullName
        CreationTime   = $CreationTime
        Length         = $Length
        PSIsContainer  = $false
        # Add other properties Get-ChildItem might return if your code uses them
    }
}

Export-ModuleMember -Function New-MockFile
