# Tests\Operations.Tests.ps1
#Requires -Modules Pester

# Determine paths
$TestScriptFile = $MyInvocation.MyCommand.Definition
$TestScriptDirectory = Split-Path -Path $TestScriptFile -Parent 
$ProjectRoot = Split-Path -Path $TestScriptDirectory -Parent   
$ModulesRoot = Join-Path -Path $ProjectRoot -ChildPath "Modules" 

$UtilsModulePath = Join-Path -Path $ModulesRoot -ChildPath "Utils.psm1"
$OperationsModulePath = Join-Path -Path $ModulesRoot -ChildPath "Operations.psm1"
$TestHelpersModulePath = Join-Path -Path $TestScriptDirectory -ChildPath "TestHelpers.psm1" 

# --- CRITICAL DIAGNOSTIC ---
# (Keep this as is from the previous version)
Write-Host "--------------------------------------------------------------------"
Write-Host "Pester Version Check within Operations.Tests.ps1 (TOP LEVEL):"
# ... (rest of diagnostic block) ...
Write-Host "--------------------------------------------------------------------"

Import-Module $UtilsModulePath -Force
if (Test-Path $TestHelpersModulePath) { Import-Module $TestHelpersModulePath -Force }

. $OperationsModulePath
Import-Module $OperationsModulePath -Force 

BeforeAll {
    Write-Verbose "Executing BeforeAll in Operations.Tests.ps1"
    $Global:ColourInfo = "Cyan"; $Global:ColourSuccess = "Green"; $Global:ColourWarning = "Yellow";
    $Global:ColourError = "Red"; $Global:ColourDebug = "Grey"; $Global:ColourSimulate = "Magenta";
    $Global:ColourAdmin = "Orange"; $Global:ColourValue = "DarkYellow"; $Global:ColourHeading = "White";
    $Global:GlobalEnableFileLogging = $false; $Global:GlobalLogFile = $null;
    $Global:GlobalJobLogEntries = [System.Collections.Generic.List[object]]::new()
    $Global:GlobalJobHookScriptData = [System.Collections.Generic.List[object]]::new()
    
    Mock Write-LogMessage { param($Message) Write-Verbose "Mocked Write-LogMessage: $Message" } 
    Mock Start-Sleep { param($Seconds) Write-Verbose "Mocked Start-Sleep for $Seconds seconds" } 
    Mock Test-AdminPrivileges { return $true } 
    
    if (Get-Command 'Invoke-VisualBasicDeleteFile' -ErrorAction SilentlyContinue) {
        Mock Invoke-VisualBasicDeleteFile { Write-Verbose "Mocked Invoke-VisualBasicDeleteFile called." }
    } else {
        Write-Warning "Test Setup Warning: Invoke-VisualBasicDeleteFile wrapper not found."
    }
}

AfterAll {
    Write-Verbose "Executing AfterAll in Operations.Tests.ps1"
    Remove-Mock Write-LogMessage -ErrorAction SilentlyContinue
    Remove-Mock Start-Sleep -ErrorAction SilentlyContinue
    Remove-Mock Test-AdminPrivileges -ErrorAction SilentlyContinue
    if (Get-Command 'Invoke-VisualBasicDeleteFile' -ErrorAction SilentlyContinue) {
        Remove-Mock Invoke-VisualBasicDeleteFile -ErrorAction SilentlyContinue
    }
}

Describe "Basic Pester v5 and Module Function Access Test" {
    It "Should find Get-PoShBackupJobEffectiveConfiguration after dot-sourcing" {
        $CommandInfo = Get-Command Get-PoShBackupJobEffectiveConfiguration -ErrorAction SilentlyContinue
        $CommandInfo | Should -Not -BeNull
        if ($CommandInfo) { $CommandInfo.ModuleName | Should -BeNullOrEmpty }
    }
    It "Should find Pester's Remove-Mock command" {
        $CommandInfo = Get-Command Remove-Mock -ErrorAction SilentlyContinue
        $CommandInfo | Should -Not -BeNull
        if ($CommandInfo) { $CommandInfo.ModuleName | Should -Be "Pester" }
    }
}

Describe "Operations Module - Get-PoShBackupJobEffectiveConfiguration (Focus on Path Error)" {
    $cliOverridesEmpty = @{}
    $mockJobReportData = [ordered]@{ JobName = "TestJob" } 
    $mockJobReportDataRef = [ref]$mockJobReportData

    It "should process VSSMetadataCachePath correctly" {
        $jobConfigMinimal = @{ Path = "C:\Source1"; Name = "Job1" }
        # Provide only the VSSMetadataCachePath in global config to isolate
        $globalConfigMinimalVSS = @{
            VSSMetadataCachePath = "%TEMP%\posh_backup_test_cache.cab"
            # Add other minimal defaults required by Get-ConfigValue calls within the tested function
            DefaultArchiveDateFormat = "yyyy-MM-dd" 
            DefaultArchiveExtension = ".7z"
            DefaultArchiveType = "-t7z"
            DefaultSevenZipProcessPriority = "Normal"
            HideSevenZipOutput = $true
            DefaultThreadCount = 0
            DefaultVSSContextOption = "Persistent NoWriters"
            EnableVSS = $false
            VSSPollingTimeoutSeconds = 10
            VSSPollingIntervalSeconds = 1
            # ... etc for any key Get-ConfigValue is called for in Get-PoShBackupJobEffectiveConfiguration
        }

        $effectiveConfig = $null
        { 
            $effectiveConfig = Get-PoShBackupJobEffectiveConfiguration `
                -JobConfig $jobConfigMinimal `
                -GlobalConfig $globalConfigMinimalVSS `
                -CliOverrides $cliOverridesEmpty `
                -PSScriptRootForPaths "C:\scripts" `
                -JobReportDataRef $mockJobReportDataRef 
        } | Should -Not -Throw
        
        $effectiveConfig | Should -Not -BeNull
        $expectedCachePath = [System.Environment]::ExpandEnvironmentVariables("%TEMP%\posh_backup_test_cache.cab")
        $effectiveConfig.VSSMetadataCachePath | Should -Be $expectedCachePath
    }
}

# Temporarily comment out other Describe blocks to isolate the current error
<# 
Describe "Operations Module - Get-PoShBackup7ZipArguments" {
    # ... tests ...
}

Describe "Operations Module - Invoke-7ZipOperation" {
    # ... tests ...
}

Describe "Operations Module - Invoke-BackupRetentionPolicy" {
    # ... tests ...
}
#>
