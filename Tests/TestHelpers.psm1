# Tests\TestHelpers.psm1
#Requires -Modules Pester
using module Pester # Ensure Pester's cmdlets are available when this module's functions are called

Import-Module Pester -ErrorAction SilentlyContinue # Fallback import

function Initialize-PoShBackupTestGlobals {
    param (
        [switch]$EnableFileLogging = $false,
        [string]$TestLogFile = $null
    )

    # --- Standard Color Variables ---
    $Global:ColourInfo      = "Cyan"
    $Global:ColourSuccess   = "Green"
    $Global:ColourWarning   = "Yellow"
    $Global:ColourError     = "Red"
    $Global:ColourDebug     = "Gray"
    $Global:ColourValue     = "DarkYellow"
    $Global:ColourHeading   = "White"
    $Global:ColourSimulate  = "Magenta"
    $Global:ColourAdmin     = "Orange"

    # --- Status to Color Map ---
    $Global:StatusToColourMap = @{
        "SUCCESS"           = $Global:ColourSuccess
        "WARNINGS"          = $Global:ColourWarning
        "FAILURE"           = $Global:ColourError
        "SIMULATED_COMPLETE"= $Global:ColourSimulate
        "INFO"              = $Global:ColourInfo
        "DEBUG"             = $Global:ColourDebug
        "VSS"               = $Global:ColourAdmin
        "HOOK"              = $Global:ColourDebug
        "CONFIG_TEST"       = $Global:ColourSimulate
        "HEADING"           = $Global:ColourHeading
        "NONE"              = "Gray" # Default Console Foreground
        "DEFAULT"           = $Global:ColourInfo
    }

    # --- Logging Globals ---
    $Global:GlobalEnableFileLogging             = $EnableFileLogging.IsPresent
    $Global:GlobalLogFile                       = if ($EnableFileLogging.IsPresent -and (-not [string]::IsNullOrWhiteSpace($TestLogFile))) { $TestLogFile } else { $null }
    $Global:GlobalLogDirectory                  = $null
    $Global:GlobalJobLogEntries                 = [System.Collections.Generic.List[object]]::new()
    $Global:GlobalJobHookScriptData             = [System.Collections.Generic.List[object]]::new()
    
    # Test Temp Directory (Used by Utils.Tests.ps1 for log file paths etc.)
    $Global:TestTempDir = Join-Path $env:TEMP "PesterPoShBackupTests"
    # Ensure it exists when globals are initialized for tests that might use it immediately
    if (-not (Test-Path $Global:TestTempDir -PathType Container)) {
        New-Item $Global:TestTempDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    }


    # Mocks defined here will be active for the scope where Initialize-PoShBackupTestGlobals is called.
    # These are general mocks for common cmdlets to prevent actual system interaction during tests.
    Mock Write-Host { } -ErrorAction SilentlyContinue
    Mock Add-Content { } -ErrorAction SilentlyContinue 
    Mock Set-Content { } -ErrorAction SilentlyContinue
    Mock Export-Csv { } -ErrorAction SilentlyContinue
    Mock ConvertTo-Json { return "{}" } -ErrorAction SilentlyContinue
    Mock Export-Clixml { } -ErrorAction SilentlyContinue
    Mock ConvertTo-Html { return "<html></html>" } -ErrorAction SilentlyContinue
}

function New-MockConfigObject {
    param (
        [hashtable]$Overrides = @{}
    )
    $mockPSScriptRoot = "C:\MockProjectRoot" # Default fallback
    try {
        if ($MyInvocation.MyCommand.ScriptBlock.File) {
            $testHelpersPath = $MyInvocation.MyCommand.ScriptBlock.File
            $mockPSScriptRoot = (Split-Path (Split-Path -Path $testHelpersPath -Parent) -Parent) 
        }
    } catch { /* Ignore errors if path cannot be determined, use default */ }

    $defaultGlobalConfig = @{
        _PoShBackup_PSScriptRoot        = $mockPSScriptRoot
        SevenZipPath                    = "C:\Program Files\7-Zip\7z.exe"
        DefaultDestinationDir           = "D:\TestBackups"
        HideSevenZipOutput              = $true
        PauseBeforeExit                 = "Never"
        EnableAdvancedSchemaValidation  = $false
        EnableFileLogging               = $false
        LogDirectory                    = ".\TestLogs" 
        ReportGeneratorType             = "HTML"
        HtmlReportDirectory             = ".\TestReports\HTML"
        CsvReportDirectory              = ".\TestReports\CSV"
        JsonReportDirectory             = ".\TestReports\JSON"
        XmlReportDirectory              = ".\TestReports\XML"
        TxtReportDirectory              = ".\TestReports\TXT"
        MdReportDirectory               = ".\TestReports\MD"
        HtmlReportTheme                 = "Light"
        DefaultArchiveDateFormat        = "yyyy-MM-dd"
        DefaultArchiveExtension         = ".7z"
        BackupLocations                 = @{}
        BackupSets                      = @{}
        VSSMetadataCachePath            = (Join-Path $Global:TestTempDir "default_vss_cache.cab")
        DefaultVSSContextOption         = "Persistent NoWriters"
        VSSPollingTimeoutSeconds        = 120
        VSSPollingIntervalSeconds       = 5
        EnableRetries                   = $true
        MaxRetryAttempts                = 3
        RetryDelaySeconds               = 60
        DefaultSevenZipProcessPriority  = "Normal"
        MinimumRequiredFreeSpaceGB      = 0
        ExitOnLowSpaceIfBelowMinimum    = $false
        DefaultTestArchiveAfterCreation = $false
        DefaultThreadCount              = 0
        DefaultArchiveType              = "-t7z"
        DefaultCompressionLevel         = "-mx=5"
        DefaultCompressionMethod        = "-m0=LZMA2"
        DefaultDictionarySize           = "-md=64m"
        DefaultWordSize                 = "-mfb=32"
        DefaultSolidBlockSize           = "-ms=4g"
        DefaultCompressOpenFiles        = $true
        DefaultScriptExcludeRecycleBin  = '-x!$RECYCLE.BIN'
        DefaultScriptExcludeSysVolInfo  = '-x!System Volume Information'
    }
    return Merge-DeepHashtable -Base $defaultGlobalConfig -Override $Overrides
}

function New-MockJobConfigObject {
    param (
        [string]$JobName = "TestJob",
        [hashtable]$Overrides = @{}
    )
    $defaultJobConfig = @{
        Path                    = "C:\TestSource\$($JobName)"
        Name                    = $JobName 
        RetentionCount          = 3
        ArchivePasswordMethod   = "None"
        DestinationDir          = $null 
        DeleteToRecycleBin      = $false
        EnableVSS               = $false
        ReportGeneratorType     = "HTML"
    }
    return Merge-DeepHashtable -Base $defaultJobConfig -Override $Overrides
}

function Merge-DeepHashtable {
    param(
        [Parameter(Mandatory)] [hashtable]$Base,
        [Parameter(Mandatory)] [hashtable]$Override
    )
    $merged = $Base.Clone()
    foreach ($key in $Override.Keys) {
        if ($merged.ContainsKey($key) -and $merged[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) {
            $merged[$key] = Merge-DeepHashtable -Base $merged[$key] -Override $Override[$key]
        } else {
            $merged[$key] = $Override[$key]
        }
    }
    return $merged
}

function EnsureTestDirectory { param([string]$Path)
    if (-not (Test-Path $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

Export-ModuleMember -Function Initialize-PoShBackupTestGlobals, New-MockConfigObject, New-MockJobConfigObject, Merge-DeepHashtable, EnsureTestDirectory
