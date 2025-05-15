# Tests\Utils.Tests.ps1
#Requires -Modules Pester
using module Pester

$TestScriptFile = $MyInvocation.MyCommand.Definition
$TestScriptDirectory = Split-Path -Path $TestScriptFile -Parent
$ProjectRoot = Split-Path -Path $TestScriptDirectory -Parent
$ModulesRoot = Join-Path -Path $ProjectRoot -ChildPath "Modules"

Import-Module (Join-Path -Path $TestScriptDirectory -ChildPath "TestHelpers.psm1") -Force
Import-Module (Join-Path -Path $ModulesRoot -ChildPath "Utils.psm1") -Force

BeforeAll {
    Initialize-PoShBackupTestGlobals
    # $Global:TestTempDir is created by Initialize-PoShBackupTestGlobals
    # EnsureTestDirectory is now exported by TestHelpers.psm1
}
AfterAll {
    if (Test-Path $Global:TestTempDir -PathType Container) {
        Remove-Item $Global:TestTempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "Utils Module - Get-ConfigValue" {
    It "Should return value if key exists" {
        $config = @{ MyKey = "MyValue" }
        Get-ConfigValue -ConfigObject $config -Key "MyKey" -DefaultValue "Default" | Should -Be "MyValue"
    }
    It "Should return default value if key does not exist" {
        $config = @{ OtherKey = "OtherValue" }
        Get-ConfigValue -ConfigObject $config -Key "MyKey" -DefaultValue "Default" | Should -Be "Default"
    }
    It "Should return default value if ConfigObject is null" {
        Get-ConfigValue -ConfigObject $null -Key "AnyKey" -DefaultValue "NullConfigDefault" | Should -Be "NullConfigDefault"
    }
    It "Should handle boolean values correctly" {
        $config = @{ BoolKey = $true }
        Get-ConfigValue -ConfigObject $config -Key "BoolKey" -DefaultValue $false | Should -Be $true
        Get-ConfigValue -ConfigObject $config -Key "MissingBoolKey" -DefaultValue $false | Should -Be $false
    }
}

Describe "Utils Module - Write-LogMessage" {
    BeforeEach {
        $Global:GlobalJobLogEntries = [System.Collections.Generic.List[object]]::new()
        $Global:GlobalEnableFileLogging = $false
        $Global:GlobalLogFile = $null
        # Mocks for Write-Host and Add-Content are defined here for this Describe's scope and are verifiable
        Mock Write-Host -MockWith { param($Object, $ForegroundColor, $NoNewline) Write-Verbose "Write-LogMessage Test - Write-Host Mock: Obj='$Object', FG='$ForegroundColor', NoNL=$NoNewline"} -Verifiable
        Mock Add-Content -MockWith { param($Path, $Value) Write-Verbose "Write-LogMessage Test - Add-Content Mock: Path='$Path', Value='$Value'"} -Verifiable
    }
    # AfterEach is generally not needed for mocks in BeforeEach in Pester v5 as they are auto-cleaned

    It "Should add entry to GlobalJobLogEntries" {
        Write-LogMessage -Message "Test log entry" -Level "INFO"
        $Global:GlobalJobLogEntries.Count | Should -Be 1
        $Global:GlobalJobLogEntries[0].Message | Should -Be "Test log entry"
    }

    It "Should call Write-Host with appropriate color for known level" {
        Write-LogMessage -Message "Error message" -Level "ERROR"
        Should -Invoke Write-Host -Exactly 1 -ParameterFilter { $PSBoundParameters.Object -eq "Error message" -and $PSBoundParameters.ForegroundColor -eq $Global:ColourError }
    }

    It "Should call Write-Host with default color for unknown level" {
        Write-LogMessage -Message "Unknown level message" -Level "MY_CUSTOM_LEVEL"
        Should -Invoke Write-Host -Exactly 1 -ParameterFilter { $PSBoundParameters.Object -eq "Unknown level message" -and $PSBoundParameters.ForegroundColor -eq $Global:ColourInfo }
    }

    It "Should call Add-Content if file logging is enabled" {
        $Global:GlobalEnableFileLogging = $true
        $Global:GlobalLogFile = (Join-Path $Global:TestTempDir "FileLogTest_Call.log") # Use helper path
        Write-LogMessage -Message "File log test" -Level "INFO"
        Should -Invoke Add-Content -Exactly 1 -ParameterFilter {
            $PSBoundParameters.Path -eq $Global:GlobalLogFile -and $PSBoundParameters.Value -match "\[INFO\s*\] File log test"
        }
    }

    It "Should NOT call Add-Content if file logging is disabled" {
        $Global:GlobalEnableFileLogging = $false
        Write-LogMessage -Message "No file log test" -Level "INFO"
        Should -Invoke Add-Content -Exactly 0
    }

    It "Should NOT call Add-Content if Level is 'NONE'" {
        $Global:GlobalEnableFileLogging = $true
        $Global:GlobalLogFile = (Join-Path $Global:TestTempDir "FileLogTest_None.log")
        Write-LogMessage -Message "No file log for NONE level" -Level "NONE"
        Should -Invoke Add-Content -Exactly 0
    }
}

Describe "Utils Module - Import-AppConfiguration (Basic Scenarios)" {
    BeforeEach {
        Mock Write-LogMessage {} # Suppress SUT's logging for these specific tests
        # REMOVED Get-Mock | Remove-Mock calls. Mocks defined in each 'It' block.
    }

    It "Should load a specified valid config file" {
        $testConfigFile = (Join-Path $Global:TestTempDir "custom_valid_iac.psd1")
        $mock7zPath = "C:\mocked_iac_valid\7z.exe"
        $vssCachePathForTest = (Join-Path $Global:TestTempDir "vss_cache_valid.cab")
        EnsureTestDirectory (Split-Path $vssCachePathForTest -Parent)

        # Mock Test-Path to be very specific for this test's needs
        Mock Test-Path -MockWith { param($PathValueParam, $PathTypeParam)
            if ($PathValueParam -eq $testConfigFile -and $PathTypeParam -eq "Leaf") { Write-Verbose "Test-Path Mock (Valid IAC): Matched config file '$PathValueParam'"; return $true }
            if ($PathValueParam -eq $mock7zPath -and $PathTypeParam -eq "Leaf") { Write-Verbose "Test-Path Mock (Valid IAC): Matched 7z path '$PathValueParam'"; return $true }
            if ($PathValueParam -eq (Split-Path $vssCachePathForTest -Parent) -and $PathTypeParam -eq "Container"){ Write-Verbose "Test-Path Mock (Valid IAC): Matched VSS Cache Parent '$PathValueParam'"; return $true}
            Write-Verbose "Test-Path Mock (Valid IAC): NO MATCH for Path='$PathValueParam', Type='$PathTypeParam'"; return $false # Default to false
        }
        $mockConfigContent = @{
            SevenZipPath = $mock7zPath; DefaultArchiveDateFormat="yyyy-MM-dd"; DefaultArchiveExtension=".7z";
            VSSMetadataCachePath = $vssCachePathForTest; EnableAdvancedSchemaValidation = $false
        }
        Mock Import-PowerShellDataFile -MockWith { param($LiteralPath) if ($LiteralPath -eq $testConfigFile) { return $mockConfigContent } }

        $result = Import-AppConfiguration -UserSpecifiedPath $testConfigFile -MainScriptPSScriptRoot "C:\scripts_iac_valid_root"
        $result.IsValid | Should -Be $true
    }

    It "Should fail if specified config file not found" {
        $testConfigFile = (Join-Path $Global:TestTempDir "nonexistent_iac.psd1")
        Mock Test-Path -MockWith { param($PathValue, $PathType)
            if ($PathValue -eq $testConfigFile) { Write-Verbose "Test-Path Mock (Non-Existent): Returning \$false for '$PathValue'"; return $false }
            # To prevent other "file not found" errors from interfering, let other paths pass if SUT checks them
            if ($PathValue -match "7z.exe") { return $true }
            if ($PathValue -match "vss_cache") { EnsureTestDirectory (Split-Path $PathValue -Parent); return $true }
            return $false
        }
        $result = Import-AppConfiguration -UserSpecifiedPath $testConfigFile -MainScriptPSScriptRoot "C:\scripts_iac_nonexist_root"
        $result.IsValid | Should -Be $false
        $result.ErrorMessage | Should -Match "Configuration file not found"
        # Separate assertion for mock call
        Should -Invoke Test-Path -AtLeast 1 -ParameterFilter { $PSBoundParameters.PathValue -eq $testConfigFile }
    }

    It "Should attempt to load Default.psd1 if no ConfigFile specified" {
        $scriptRootForTest = (Join-Path $Global:TestTempDir "scripts_default_load_iac_root")
        EnsureTestDirectory (Join-Path $scriptRootForTest "Config")
        $defaultConfigPath = Join-Path $scriptRootForTest "Config\Default.psd1"
        $userConfigPath = Join-Path $scriptRootForTest "Config\User.psd1"
        $mock7zPath = "C:\Default7z_load_iac\7z.exe"
        $vssCachePathForTest = (Join-Path $Global:TestTempDir "vss_cache_default_load.cab")
        EnsureTestDirectory (Split-Path $vssCachePathForTest -Parent)
        $mockConfigContent = @{ SevenZipPath = $mock7zPath; DefaultArchiveDateFormat="yyyy-MM-dd"; DefaultArchiveExtension=".7z"; VSSMetadataCachePath = $vssCachePathForTest; EnableAdvancedSchemaValidation = $false }

        Mock Test-Path -MockWith { param($PathValue, $PathType)
            if ($PathValue -eq $defaultConfigPath -and $PathType -eq "Leaf") { return $true }
            if ($PathValue -eq $mock7zPath -and $PathType -eq "Leaf") { return $true }
            if ($PathValue -eq $userConfigPath -and $PathType -eq "Leaf") { return $false } # User.psd1 not found
            if ($PathValue -eq (Split-Path $vssCachePathForTest -Parent) -and $PathType -eq "Container"){ return $true}
            return $false
        }
        Mock Import-PowerShellDataFile -MockWith { param($LiteralPath) if ($LiteralPath -eq $defaultConfigPath) { return $mockConfigContent } }

        $result = Import-AppConfiguration -MainScriptPSScriptRoot $scriptRootForTest
        $result.IsValid | Should -Be $true
        $result.Configuration.SevenZipPath | Should -Be $mock7zPath
    }

    It "Should merge User.psd1 over Default.psd1 if both exist" {
        $scriptRootForTest = (Join-Path $Global:TestTempDir "testing_merge_config_iac_root")
        EnsureTestDirectory (Join-Path $scriptRootForTest "Config")
        $defaultConfigPath = Join-Path $scriptRootForTest "Config\Default.psd1"
        $userConfigPath = Join-Path $scriptRootForTest "Config\User.psd1"
        $default7z = "C:\Default7z_merge_iac\7z.exe"; $user7z = "C:\User7z_merge_iac\7z.exe"
        $vssCacheUser = (Join-Path $Global:TestTempDir "vss_cache_user_merge_iac.cab")
        EnsureTestDirectory (Split-Path $vssCacheUser -Parent)

        $defaultContent = @{ SevenZipPath = $default7z; DefaultDestinationDir = "D:\Default"; DefaultArchiveDateFormat="yyyy-MM-dd"; DefaultArchiveExtension=".7z"; VSSMetadataCachePath = (Join-Path $Global:TestTempDir "vss_cache_default_merge.cab"); EnableAdvancedSchemaValidation = $false }
        $userContent    = @{ SevenZipPath = $user7z; CustomUserSetting = "UserValue"; VSSMetadataCachePath = $vssCacheUser }

        Mock Test-Path -MockWith { param($PathValue, $PathType)
            if (($PathValue -eq $defaultConfigPath -or $PathValue -eq $userConfigPath) -and $PathType -eq "Leaf") { return $true }
            if ($PathValue -eq $user7z -and $PathType -eq "Leaf") { return $true } # User's 7z path is valid
            if ($PathValue -eq (Split-Path $vssCacheUser -Parent) -and $PathType -eq "Container"){ return $true}
            return $false
        }
        Mock Import-PowerShellDataFile -MockWith { param($LiteralPath)
            if ($LiteralPath -eq $defaultConfigPath) { return $defaultContent }
            if ($LiteralPath -eq $userConfigPath) { return $userContent }
            return $null
        }
        $result = Import-AppConfiguration -MainScriptPSScriptRoot $scriptRootForTest
        $result.IsValid | Should -Be $true
        $result.Configuration.SevenZipPath | Should -Be $user7z
        $result.UserConfigLoaded | Should -Be $true
    }

    It "Should use Find-SevenZipExecutable (mocked via script flag) if SevenZipPath is empty" {
        $scriptRootForTest = (Join-Path $Global:TestTempDir "scripts_find7z_empty_iac_flag_root")
        EnsureTestDirectory (Join-Path $scriptRootForTest "Config") # Ensure "Config" subdir exists for Join-Path to Default.psd1
        $defaultConfigPath = Join-Path $scriptRootForTest "Config\Default.psd1"
        $userConfigPath = Join-Path $scriptRootForTest "Config\User.psd1"
        $vssCacheForTest = (Join-Path $Global:TestTempDir "vss_cache_find7z_flag_test_iac.cab")
        EnsureTestDirectory (Split-Path $vssCacheForTest -Parent)
        $mockConfigContent = @{ SevenZipPath = ""; DefaultArchiveDateFormat="yyyy-MM-dd"; DefaultArchiveExtension=".7z"; VSSMetadataCachePath = $vssCacheForTest; EnableAdvancedSchemaValidation = $false }
        $script:FindSevenZipExecutable_WasCalled_In_UtilsTest = $false # Flag specific to this test

        Mock Test-Path -MockWith { param($PathValue, $PathType)
             if ($PathValue -eq $defaultConfigPath -and $PathType -eq "Leaf") { return $true }
             if ($PathValue -eq $userConfigPath -and $PathType -eq "Leaf") { return $false } # User file not found
             if ([string]::IsNullOrEmpty($PathValue)) { return $false } # For the empty SevenZipPath test by Test-Path
             if ($PathValue -eq (Split-Path $vssCacheForTest -Parent) -and $PathType -eq "Container"){ return $true}
             return $false # Default other paths to false for this specific scenario
        }
        Mock Import-PowerShellDataFile -MockWith { param($lp) if($lp -eq $defaultConfigPath) {return $mockConfigContent } }
        # Mock Find-SevenZipExecutable in the current (test script's) scope.
        # Utils.psm1 functions, when imported via Import-Module -Force, might resolve to this mock.
        Mock Find-SevenZipExecutable -MockWith { $script:FindSevenZipExecutable_WasCalled_In_UtilsTest = $true; return "C:\AutoDetected_From_Direct_GlobalMock\7z.exe" }

        $result = Import-AppConfiguration -MainScriptPSScriptRoot $scriptRootForTest

        $script:FindSevenZipExecutable_WasCalled_In_UtilsTest | Should -Be $true
        $result.Configuration.SevenZipPath | Should -Be "C:\AutoDetected_From_Direct_GlobalMock\7z.exe"
        $result.IsValid | Should -Be $true
        Remove-Variable script:FindSevenZipExecutable_WasCalled_In_UtilsTest -ErrorAction SilentlyContinue
    }
}

Describe "Utils Module - Get-JobsToProcess" {
    BeforeEach { Mock Write-LogMessage {} }
    It "Should return specified set's jobs and correct StopSetOnErrorPolicy" { $currentMockConfig = @{ BackupLocations = @{ JobA = @{ Name = "JobA Details"}; JobB = @{ Name = "JobB Details"} }; BackupSets = @{ Set1 = @{ JobNames = @("JobA", "JobB"); OnErrorInJob = "StopSet" } } }; $result = Get-JobsToProcess -Config $currentMockConfig -SpecifiedSetName "Set1"; $result.Success | Should -Be $true; ($result.JobsToRun -is [System.Collections.Generic.List[string]]) | Should -Be $true; $result.JobsToRun | Should -BeExactly @("JobA", "JobB"); $result.SetName | Should -Be "Set1"; $result.StopSetOnErrorPolicy | Should -Be $true }
    It "Should correctly interpret ContinueSet policy" { $currentMockConfig = @{ BackupLocations = @{ JobC = @{ Name = "JobC Details"} }; BackupSets = @{ SetContinue = @{ JobNames = @("JobC"); OnErrorInJob = "ContinueSet" } } }; $result = Get-JobsToProcess -Config $currentMockConfig -SpecifiedSetName "SetContinue"; $result.Success | Should -Be $true; $result.StopSetOnErrorPolicy | Should -Be $false }
    It "Should return specified job name" { $currentMockConfig = @{ BackupLocations = @{ JobA = @{ Name = "JobA Details"}; JobB = @{ Name = "JobB Details"} }; BackupSets = @{} }; $result = Get-JobsToProcess -Config $currentMockConfig -SpecifiedJobName "JobA"; $result.Success | Should -Be $true; ($result.JobsToRun -is [System.Collections.Generic.List[string]]) | Should -Be $true; $result.JobsToRun | Should -BeExactly @("JobA") }
    It "Should fail if specified set not found" { $currentMockConfig = @{ BackupLocations = @{}; BackupSets = @{ RealSet = @{JobNames=@("FakeJob")} } }; $result = Get-JobsToProcess -Config $currentMockConfig -SpecifiedSetName "NonExistentSet"; $result.Success | Should -Be $false; $result.ErrorMessage | Should -Match "not found" }
    It "Should fail if specified job not found" { $currentMockConfig = @{ BackupLocations = @{ RealJob = @{}}; BackupSets = @{} }; $result = Get-JobsToProcess -Config $currentMockConfig -SpecifiedJobName "NonExistentJob"; $result.Success | Should -Be $false; $result.ErrorMessage | Should -Match "not found" }
    It "Should fail if no job/set specified and multiple jobs exist" { $currentMockConfig = @{ BackupLocations = @{ JobA = @{}; JobB = @{} }; BackupSets = @{} }; $result = Get-JobsToProcess -Config $currentMockConfig; $result.Success | Should -Be $false; $result.ErrorMessage | Should -Match "No BackupLocationName or RunSet specified" }
    It "Should auto-select single job if no job/set specified and only one job exists" { $singleJobConfig = @{ BackupLocations = @{ SingleJob = @{ Name = "SJ Details"} }; BackupSets = @{} }; $result = Get-JobsToProcess -Config $singleJobConfig; $result.Success | Should -Be $true; ($result.JobsToRun -is [System.Collections.Generic.List[string]]) | Should -Be $true; $result.JobsToRun | Should -BeExactly @("SingleJob") }
    It "Should fail if set has no job names" { $currentMockConfig = @{ BackupLocations = @{}; BackupSets = @{ EmptySet = @{ JobNames = @() } } }; $result = Get-JobsToProcess -Config $currentMockConfig -SpecifiedSetName "EmptySet"; $result.Success | Should -Be $false; $result.ErrorMessage | Should -Match "no valid 'JobNames' defined" }
}
