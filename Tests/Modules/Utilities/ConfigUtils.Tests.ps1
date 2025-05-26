# Tests\Modules\Utilities\ConfigUtils.Tests.ps1 (Pester 5 - Testing IMPORTED Utils\Get-ConfigValue - Attempt 2)

BeforeAll {
    $UtilitiesDir = $PSScriptRoot
    $ModulesTestsDir = (Get-Item -LiteralPath $UtilitiesDir).Parent.FullName
    $TestsDir = (Get-Item -LiteralPath $ModulesTestsDir).Parent.FullName
    $ProjectRoot = (Get-Item -LiteralPath $TestsDir).Parent.FullName

    # Path to the Utils.psm1 facade module
    $script:UtilsModulePath_ImportTest_Again = Join-Path -Path $ProjectRoot -ChildPath "Modules\Utils.psm1"

    try {
        Import-Module -Name $script:UtilsModulePath_ImportTest_Again -Force -ErrorAction Stop
        #Write-Host "DEBUG ConfigUtils.Tests: (Pester 5.x) Successfully IMPORTED Utils.psm1: '$($script:UtilsModulePath_ImportTest_Again)'."
        
        # Get a reference to the imported and re-exported function
        $script:GetConfigValue_FromUtilsModule_Again = Get-Command Utils\Get-ConfigValue -ErrorAction Stop
        if (-not $script:GetConfigValue_FromUtilsModule_Again) {
            throw "Failed to get command reference for Utils\Get-ConfigValue after importing Utils.psm1."
        }
        #Write-Host "DEBUG ConfigUtils.Tests: (Pester 5.x) Got reference to Utils\Get-ConfigValue. Type: $($script:GetConfigValue_FromUtilsModule_Again.GetType().FullName)"

    } catch {
        Write-Error "FATAL ERROR in BeforeAll: Failed to import Utils.psm1 or get command reference. Error: $($_.Exception.Message)"
        throw "Module import or command reference failed, cannot proceed with tests."
    }
}

Describe "Get-ConfigValue Function (from IMPORTED Utils.psm1 module - Attempt 2)" {

    Context "When ConfigObject is a Hashtable" {
        BeforeEach {
            # Ensure test data is fresh for each test
            $script:testHashtableDataImp_Again = @{ 
                ExistingKeyString = "TestValue"
                ExistingKeyInt    = 123
                ExistingKeyBool   = $true
                ExistingKeyArray  = @("A", "B")
            }
        }

        It "should return the correct value for an existing string key" {
            $result = & $script:GetConfigValue_FromUtilsModule_Again -ConfigObject $script:testHashtableDataImp_Again -Key "ExistingKeyString" -DefaultValue "Default"
            $result | Should -Be "TestValue"
        }

        It "should return the correct value for an existing integer key" { 
            $result = & $script:GetConfigValue_FromUtilsModule_Again -ConfigObject $script:testHashtableDataImp_Again -Key "ExistingKeyInt" -DefaultValue 0
            $result | Should -Be 123
        }

        It "should return the correct value for an existing boolean key" {
            $result = & $script:GetConfigValue_FromUtilsModule_Again -ConfigObject $script:testHashtableDataImp_Again -Key "ExistingKeyBool" -DefaultValue $false
            $result | Should -Be $true
        }

        It "should return the correct value for an existing array key" {
            $result = & $script:GetConfigValue_FromUtilsModule_Again -ConfigObject $script:testHashtableDataImp_Again -Key "ExistingKeyArray" -DefaultValue @()
            ($result.GetType().IsArray) | Should -Be $true "Result should be an array type"
            $result | Should -HaveCount 2
            $result | Should -BeExactly @("A", "B")
        }

        It "should return the default value if key does not exist" {
            $result = & $script:GetConfigValue_FromUtilsModule_Again -ConfigObject $script:testHashtableDataImp_Again -Key "NonExistentKey" -DefaultValue "DefaultNonExistent"
            $result | Should -Be "DefaultNonExistent"
        }

        It "should return `$null as default if key does not exist and default is `$null" {
            $result = & $script:GetConfigValue_FromUtilsModule_Again -ConfigObject $script:testHashtableDataImp_Again -Key "NonExistentKey" -DefaultValue $null
            $result | Should -BeNullOrEmpty
        }
    } 

    Context "When ConfigObject is a PSCustomObject" {
        BeforeEach {
            $script:testPSCustomObjectDataImp_Again = [PSCustomObject]@{
                ExistingPropertyString = "CustomValue"
                ExistingPropertyInt    = 456
            }
        }

        It "should return the correct value for an existing property" {
            $result = & $script:GetConfigValue_FromUtilsModule_Again -ConfigObject $script:testPSCustomObjectDataImp_Again -Key "ExistingPropertyString" -DefaultValue "DefaultCustom"
            $result | Should -Be "CustomValue"
        }
        It "should return the default value if property does not exist" {
            $result = & $script:GetConfigValue_FromUtilsModule_Again -ConfigObject $script:testPSCustomObjectDataImp_Again -Key "NonExistentProperty" -DefaultValue "DefaultNonExistentCustom"
            $result | Should -Be "DefaultNonExistentCustom"
        }
    } 
    Context "When ConfigObject is `$null" {
        It "should return the default value" {
            $result = & $script:GetConfigValue_FromUtilsModule_Again -ConfigObject $null -Key "AnyKey" -DefaultValue "DefaultForNullObject"
            $result | Should -Be "DefaultForNullObject"
        }
    } 
    Context "When ConfigObject is not a Hashtable or PSCustomObject (e.g., a string)" {
        BeforeEach {
            $script:testStringObjectDataImp_Again = "This is just a string"
        }
        It "should return the default value" {
            $result = & $script:GetConfigValue_FromUtilsModule_Again -ConfigObject $script:testStringObjectDataImp_Again -Key "AnyKey" -DefaultValue "DefaultForStringObject"
            $result | Should -Be "DefaultForStringObject"
        }
    } 
    Context "When Key parameter is `$null or empty" {
        BeforeEach {
            $script:testHashtableSimpleDataImp_Again = @{ MyKey = "MyValue" }
        }
        It "should return the default value if Key is `$null" {
            $result = & $script:GetConfigValue_FromUtilsModule_Again -ConfigObject $script:testHashtableSimpleDataImp_Again -Key $null -DefaultValue "DefaultForKeyNull"
            $result | Should -Be "DefaultForKeyNull"
        }
        It "should return the default value if Key is an empty string" {
            $result = & $script:GetConfigValue_FromUtilsModule_Again -ConfigObject $script:testHashtableSimpleDataImp_Again -Key "" -DefaultValue "DefaultForKeyEmpty"
            $result | Should -Be "DefaultForKeyEmpty"
        }
    }
}
