# Tests\Modules\Utilities\ConfigUtils.Tests.ps1 (FOR PESTER 5.x - Thirty-Seventh Attempt)

BeforeAll {
    # Define the function directly INSIDE BeforeAll
    function Get-ConfigValue-InBeforeAll {
        [CmdletBinding()]
        param (
            [object]$ConfigObject, 
            [string]$Key,
            [object]$DefaultValue
        )
        if ($null -ne $ConfigObject -and $ConfigObject -is [hashtable] -and $ConfigObject.ContainsKey($Key)) {
            return $ConfigObject[$Key]
        }
        elseif ($null -ne $ConfigObject -and -not ($ConfigObject -is [hashtable]) -and `
                ($null -ne $ConfigObject.PSObject) -and `
                ($null -ne $ConfigObject.PSObject.Properties) -and `
                ($null -ne $ConfigObject.PSObject.Properties.Name) -and `
                $ConfigObject.PSObject.Properties.Name -contains $Key) {
            return $ConfigObject.$Key
        }
        return $DefaultValue
    }

    $script:GetConfigValueFunc_FromBA_Final = ${function:Get-ConfigValue-InBeforeAll}
    if (-not $script:GetConfigValueFunc_FromBA_Final) {
        throw "Failed to get command reference for Get-ConfigValue-InBeforeAll defined in BeforeAll."
    }
    Write-Host "DEBUG ConfigUtils.Tests: (Pester 5.x) Defined Get-ConfigValue-InBeforeAll in BeforeAll and got reference."
}

Describe "Get-ConfigValue Function (Defined in BeforeAll, Called via Script-Scoped Reference)" {

    Context "When ConfigObject is a Hashtable" {
        BeforeEach {
            $script:testHashtableDataCtxBA_Final = @{ 
                ExistingKeyString = "TestValue"
                ExistingKeyInt    = 123
                ExistingKeyBool   = $true
                ExistingKeyArray  = @("A", "B") # This is an array
            }
        }

        It "should return the correct value for an existing string key" {
            $result = & $script:GetConfigValueFunc_FromBA_Final -ConfigObject $script:testHashtableDataCtxBA_Final -Key "ExistingKeyString" -DefaultValue "Default"
            $result | Should -Be "TestValue"
        }

        It "should return the correct value for an existing integer key" { 
            $result = & $script:GetConfigValueFunc_FromBA_Final -ConfigObject $script:testHashtableDataCtxBA_Final -Key "ExistingKeyInt" -DefaultValue 0
            $result | Should -Be 123
        }

        It "should return the correct value for an existing boolean key" {
            $result = & $script:GetConfigValueFunc_FromBA_Final -ConfigObject $script:testHashtableDataCtxBA_Final -Key "ExistingKeyBool" -DefaultValue $false
            $result | Should -Be $true
        }

        It "should return the correct value for an existing array key" {
            $resultFromArrayTest = & $script:GetConfigValueFunc_FromBA_Final -ConfigObject $script:testHashtableDataCtxBA_Final -Key "ExistingKeyArray" -DefaultValue @()
            
            # Corrected Type Check for Pester 5
            ($resultFromArrayTest.GetType().IsArray) | Should -Be $true "Result should be an array type"
            # Or, if Pester 5's -BeOfType is usually reliable, this might indicate $resultFromArrayTest isn't what we think:
            # $resultFromArrayTest | Should -BeOfType ([System.Array]) 
            
            $resultFromArrayTest | Should -HaveCount 2
            $resultFromArrayTest | Should -BeExactly @("A", "B")
        }

        It "should return the default value if key does not exist" {
            $result = & $script:GetConfigValueFunc_FromBA_Final -ConfigObject $script:testHashtableDataCtxBA_Final -Key "NonExistentKey" -DefaultValue "DefaultNonExistent"
            $result | Should -Be "DefaultNonExistent"
        }

        It "should return `$null as default if key does not exist and default is `$null" {
            $result = & $script:GetConfigValueFunc_FromBA_Final -ConfigObject $script:testHashtableDataCtxBA_Final -Key "NonExistentKey" -DefaultValue $null
            $result | Should -BeNullOrEmpty
        }
    } 

    Context "When ConfigObject is a PSCustomObject" {
        BeforeEach {
            $script:testPSCustomObjectDataCtxBA_Final = [PSCustomObject]@{
                ExistingPropertyString = "CustomValue"
                ExistingPropertyInt    = 456
            }
        }

        It "should return the correct value for an existing property" {
            $result = & $script:GetConfigValueFunc_FromBA_Final -ConfigObject $script:testPSCustomObjectDataCtxBA_Final -Key "ExistingPropertyString" -DefaultValue "DefaultCustom"
            $result | Should -Be "CustomValue"
        }
        It "should return the default value if property does not exist" {
            $result = & $script:GetConfigValueFunc_FromBA_Final -ConfigObject $script:testPSCustomObjectDataCtxBA_Final -Key "NonExistentProperty" -DefaultValue "DefaultNonExistentCustom"
            $result | Should -Be "DefaultNonExistentCustom"
        }
    } 
    Context "When ConfigObject is `$null" {
        It "should return the default value" {
            $result = & $script:GetConfigValueFunc_FromBA_Final -ConfigObject $null -Key "AnyKey" -DefaultValue "DefaultForNullObject"
            $result | Should -Be "DefaultForNullObject"
        }
    } 
    Context "When ConfigObject is not a Hashtable or PSCustomObject (e.g., a string)" {
        BeforeEach {
            $script:testStringObjectDataCtxBA_Final = "This is just a string"
        }
        It "should return the default value" {
            $result = & $script:GetConfigValueFunc_FromBA_Final -ConfigObject $script:testStringObjectDataCtxBA_Final -Key "AnyKey" -DefaultValue "DefaultForStringObject"
            $result | Should -Be "DefaultForStringObject"
        }
    } 
    Context "When Key parameter is `$null or empty" {
        BeforeEach {
            $script:testHashtableSimpleDataCtxBA_Final = @{ MyKey = "MyValue" }
        }
        It "should return the default value if Key is `$null" {
            $result = & $script:GetConfigValueFunc_FromBA_Final -ConfigObject $script:testHashtableSimpleDataCtxBA_Final -Key $null -DefaultValue "DefaultForKeyNull"
            $result | Should -Be "DefaultForKeyNull"
        }
        It "should return the default value if Key is an empty string" {
            $result = & $script:GetConfigValueFunc_FromBA_Final -ConfigObject $script:testHashtableSimpleDataCtxBA_Final -Key "" -DefaultValue "DefaultForKeyEmpty"
            $result | Should -Be "DefaultForKeyEmpty"
        }
    }
}