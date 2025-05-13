# Tests\Utils.Tests.ps1
#Requires -Modules Pester

# Determine paths
$TestScriptFile = $MyInvocation.MyCommand.Definition
$TestScriptDirectory = Split-Path -Path $TestScriptFile -Parent 
$ProjectRoot = Split-Path -Path $TestScriptDirectory -Parent   
$ModulesRoot = Join-Path -Path $ProjectRoot -ChildPath "Modules" 
$UtilsModulePath = Join-Path -Path $ModulesRoot -ChildPath "Utils.psm1"

# Dot-source the Utils module to make its non-exported functions available (if any were non-exported, though all in Utils are typically exported)
# And import it normally. For Utils.psm1, all functions are usually exported, so Import-Module might be enough.
# However, dot-sourcing first is a safe pattern if you're unsure or if that changes.
Write-Verbose "Dot-sourcing Utils module from $UtilsModulePath"
. $UtilsModulePath
Write-Verbose "Importing Utils module from $UtilsModulePath"
Import-Module $UtilsModulePath -Force 

BeforeAll {
    Write-Verbose "Executing BeforeAll in Utils.Tests.ps1"
    # Initialize Global Colour Variables expected by Write-LogMessage
    $Global:ColourInfo = "Cyan"; $Global:ColourSuccess = "Green"; $Global:ColourWarning = "Yellow";
    $Global:ColourError = "Red"; $Global:ColourDebug = "Grey"; $Global:ColourSimulate = "Magenta";
    $Global:ColourAdmin = "Orange"; $Global:ColourValue = "DarkYellow"; $Global:ColourHeading = "White";

    # Initialize other globals that might be touched by functions under test
    $Global:GlobalEnableFileLogging = $false # Default for tests, can be overridden per test
    $Global:GlobalLogFile = $null
    $Global:GlobalJobLogEntries = $null # Write-LogMessage will check if it's a list
    $Global:GlobalJobHookScriptData = $null # For Invoke-HookScript
}

AfterAll {
    Write-Verbose "Executing AfterAll in Utils.Tests.ps1"
    # Clean up any mocks defined at the Describe or Context level if needed,
    # but Pester v5 generally handles scoping well.
    # Global mocks would be removed here if set in BeforeAll for the whole file.
}

Describe "Utils Module - Get-ConfigValue" {
    Context "When key exists in hashtable" {
        $config = @{ MyKey = "MyValue"; OtherKey = 123 }
        It "should return the correct value" {
            $result = Get-ConfigValue -ConfigObject $config -Key "MyKey" -DefaultValue "Default"
            $result | Should -Be "MyValue"
        }
    }

    Context "When key does not exist in hashtable" {
        $config = @{ OtherKey = 123 }
        It "should return the default value" {
            $result = Get-ConfigValue -ConfigObject $config -Key "NonExistentKey" -DefaultValue "Default"
            $result | Should -Be "Default"
        }
    }

    Context "When ConfigObject is null" {
        It "should return the default value" {
            $result = Get-ConfigValue -ConfigObject $null -Key "AnyKey" -DefaultValue "NullConfigDefault"
            $result | Should -Be "NullConfigDefault"
        }
    }
}

Describe "Utils Module - Write-LogMessage" {
    Mock Write-Host # Suppress actual console output during these tests
    Mock Add-Content # Suppress file writing for these tests

    BeforeEach {
        # Reset/Setup globals for each test to ensure isolation
        $Global:GlobalJobLogEntries = [System.Collections.Generic.List[object]]::new()
        $Global:GlobalEnableFileLogging = $false # Default to no file logging
        $Global:GlobalLogFile = $null
    }
    AfterEach {
        # It's good practice to remove mocks defined in BeforeEach if they could conflict
        Remove-Mock Write-Host -ErrorAction SilentlyContinue
        Remove-Mock Add-Content -ErrorAction SilentlyContinue
    }

    It "should add entry to GlobalJobLogEntries if it's a valid list" {
        Write-LogMessage -Message "Test HTML Log" -Level "HTML_TEST"
        $Global:GlobalJobLogEntries.Count | Should -Be 1
        $Global:GlobalJobLogEntries[0].Message | Should -Be "Test HTML Log"
        $Global:GlobalJobLogEntries[0].Level | Should -Be "HTML_TEST"
    }

    It "should attempt to write to console with correct parameters" {
        Write-LogMessage -Message "Console Test" -ForegroundColour "Green"
        Mock Write-Host | Should -HaveBeenCalled -Exactly 1 -WithParameters @{ ForegroundColor = "Green"; Message = "Console Test" }
    }

    Context "File Logging" {
        BeforeEach { # Specific setup for this context
            $Global:GlobalEnableFileLogging = $true
            $Global:GlobalLogFile = "C:\temp\PesterTestDummy.log" # Mock path
            # Mock Test-Path for this log file to simulate its existence if needed by Add-Content's parent dir check (not directly by Add-Content)
            # However, Add-Content itself will fail if the directory for the file doesn't exist.
            # For a true unit test of Add-Content call, we just check if it's called.
        }

        It "should attempt to Add-Content if file logging is enabled and path is set" {
            Write-LogMessage -Message "File Log Test" -Level "F_INFO"
            Mock Add-Content | Should -HaveBeenCalled -Exactly 1 
            # More detailed check for parameters:
            (Get-MockCall -Command Add-Content -LastCall).Parameters.Path | Should -Be $Global:GlobalLogFile
            (Get-MockCall -Command Add-Content -LastCall).Parameters.Value | Should -Match "\[F_INFO\] File Log Test"
        }

        It "should not attempt to Add-Content if Level is NONE" {
             Write-LogMessage -Message "No File Log Test" -Level "NONE"
             Mock Add-Content | Should -Not -HaveBeenCalled
        }
    }
}

Describe "Utils Module - Import-AppConfiguration" {
    # Mock Get-Date for consistent date formatting tests if any part of Import-AppConfiguration uses it (it doesn't currently)
    # Mock Write-LogMessage as it's called internally by Import-AppConfiguration
    BeforeEach {
        Mock Write-LogMessage { }
    }
    AfterEach {
        Remove-Mock Write-LogMessage -ErrorAction SilentlyContinue
        Remove-Mock Test-Path -ErrorAction SilentlyContinue
        Remove-Mock Import-PowerShellDataFile -ErrorAction SilentlyContinue
    }
    
    Context "Valid minimal configuration" {
        $mockConfigData = @{
            SevenZipPath = "C:\7z\7z.exe"
            BackupLocations = @{ Job1 = @{ Path = "C:\Src"; Name = "Job1Backup" } }
            DefaultArchiveDateFormat = "yyyy-MM-dd" # Add required validatable fields
            DefaultArchiveExtension = ".7z"
        }
        Mock Import-PowerShellDataFile { param($LiteralPath) return $mockConfigData }
        Mock Test-Path -MockWith { param($PathValue, $PathType) # Renamed $Path to $PathValue
            if ($PathValue -eq "C:\fake\config.psd1") { return $true }
            if ($PathValue -eq "C:\7z\7z.exe" -and $PathType -eq "Leaf") { return $true }
            return $false # Default to false for other paths to avoid unexpected true
        }

        It "should return IsValid = $true and the configuration object" {
            $result = Import-AppConfiguration -UserSpecifiedPath "C:\fake\config.psd1" -MainScriptPSScriptRoot "C:\scriptroot"
            $result.IsValid | Should -Be $true
            $result.Configuration | Should -BeOfType ([hashtable])
            $result.Configuration.SevenZipPath | Should -Be "C:\7z\7z.exe"
        }
    }

    Context "Missing SevenZipPath" {
        $mockConfigData = @{ 
            BackupLocations = @{ Job1 = @{ Path = "C:\Src"; Name = "Job1Backup" }};
            DefaultArchiveDateFormat = "yyyy-MM-dd"; # Add required validatable fields
            DefaultArchiveExtension = ".7z"
        }
        Mock Import-PowerShellDataFile { param($LiteralPath) return $mockConfigData }
        Mock Test-Path -MockWith { param($PathValue, $PathType)
            if ($PathValue -eq "C:\fake\config.psd1") { return $true }
            return $false 
        }
        
        It "should return IsValid = $false" {
            $result = Import-AppConfiguration -UserSpecifiedPath "C:\fake\config.psd1" -MainScriptPSScriptRoot "C:\scriptroot"
            $result.IsValid | Should -Be $false
            # In Pester v5, ErrorMessage might be an array of strings or a single string.
            # If it's an array of strings (from $validationMessages.Add), join them for -Match or check individual elements.
            ($result.ErrorMessage | Out-String) | Should -Match "SevenZipPath.*missing"
        }
    }
    
    Context "Invalid DefaultArchiveDateFormat" {
        $mockConfigData = @{
            SevenZipPath = "C:\7z\7z.exe"
            DefaultArchiveDateFormat = "INVALID_FORMAT" # This will fail Get-Date -Format
            DefaultArchiveExtension = ".7z"
            BackupLocations = @{ Job1 = @{ Path = "C:\Src"; Name = "Job1Backup" }}
        }
        Mock Import-PowerShellDataFile { param($LiteralPath) return $mockConfigData }
        Mock Test-Path -MockWith { param($PathValue, $PathType)
            if ($PathValue -eq "C:\fake\config.psd1") { return $true }
            if ($PathValue -eq "C:\7z\7z.exe" -and $PathType -eq "Leaf") { return $true }
            return $false 
        }
        
        It "should return IsValid = $false and mention date format" {
            $result = Import-AppConfiguration -UserSpecifiedPath "C:\fake\config.psd1" -MainScriptPSScriptRoot "C:\scriptroot"
            $result.IsValid | Should -Be $false
            ($result.ErrorMessage | Out-String) | Should -Match "Configuration validation failed" 
            # To check for specific message:
            # $validationMessages = #... how Import-AppConfiguration returns them
            # $validationMessages | Should -ContainMatch "DefaultArchiveDateFormat.*not a valid date format"
        }
    }
    # Add more tests for other validation rules (BackupLocations structure, BackupSets, VSSMetadataCachePath, ArchiveExtension)
}

# Add Describe blocks for:
# Test-AdminPrivileges (simple, no mocks needed, just checks current state)
# Invoke-HookScript (mock Start-Process for powershell.exe, Test-Path for script existence)
# Get-ArchiveSizeFormatted (mock Get-Item, Test-Path)
# Get-JobsToProcess (provide various mock $Config objects)
