# Tests\Reporting.Tests.ps1
#Requires -Modules Pester

# Determine the path to the Modules directory relative to this test script
$TestScriptDirectory = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$ModulesDirectory = Join-Path -Path $TestScriptDirectory -ChildPath "..\Modules"
$UtilsModulePath = Join-Path -Path $ModulesDirectory -ChildPath "Utils.psm1"
$ReportingModulePath = Join-Path -Path $ModulesDirectory -ChildPath "Reporting.psm1"

Import-Module $UtilsModulePath -Force 
Import-Module $ReportingModulePath -Force 

Describe "Reporting Module - ConvertTo-SafeHtml (via alias)" {
    Context "When System.Web is available (or fallback is used)" { 
        It "should encode HTML special characters correctly" {
            # String with special characters for testing
            $inputText = "<script>&'`"test" # CORRECTED: SINGLE backtick ` before "
            # Expected output after HTML encoding
            $expectedText = "<script>&'`"test" # CORRECTED: SINGLE backtick ` before " 
            
            $result = ConvertTo-SafeHtml -Text $inputText
            $result | Should -Be $expectedText
        } 
    } 

    Context "When System.Web is NOT available (forcing manual encoding path via mock)" {
        BeforeAll {
            Mock Add-Type -ModuleName Reporting.Tests.ps1 { 
                param($AssemblyName) 
                if ($AssemblyName -eq "System.Web") {
                    throw "Mocked Add-Type: System.Web cannot be loaded for this test context"
                }
            }
            Import-Module $ReportingModulePath -Force 
        }
        
        AfterAll {
            Remove-Mock -CommandName Add-Type -ModuleName Reporting.Tests.ps1 
            Import-Module $ReportingModulePath -Force 
        }

        It "should use manual encoding for HTML special characters" {
            $inputText = "<script>&'`"test" # CORRECTED: SINGLE backtick ` before "
            $expectedText = "<script>&'`"test" # CORRECTED: SINGLE backtick ` before "
            $result = ConvertTo-SafeHtml -Text $inputText
            $result | Should -Be $expectedText
        }

        It "should handle null input gracefully with manual encoding" {
            $result = ConvertTo-SafeHtml -Text $null
            $result | Should -Be ""
        }
    } 
} 

Describe "Reporting Module - Invoke-HtmlReport" {
    Mock Get-ConfigValue -ModuleName Reporting.Tests.ps1 { param($ConfigObject, $Key, $DefaultValue, $JobNameForError) return $DefaultValue } 
    Mock Write-LogMessage -ModuleName Reporting.Tests.ps1 { } 
    Mock Set-Content -ModuleName Reporting.Tests.ps1 { }
    
    $mockModuleBase = Join-Path -Path (Split-Path -Path $MyInvocation.MyCommand.Definition -Parent) -ChildPath "..\Modules"
    Mock Get-Content -ModuleName Reporting.Tests.ps1 -ParameterFilter { $LiteralPath -eq (Join-Path $mockModuleBase "Themes\Base.css") } { return "/* Base CSS Mock */" }
    Mock Get-Content -ModuleName Reporting.Tests.ps1 -ParameterFilter { $LiteralPath -eq (Join-Path $mockModuleBase "Themes\Default.css") } { return "/* Default Theme CSS Mock */" }
    
    $testReportDir = Join-Path -Path $env:TEMP -ChildPath "PesterTestReports_$(Get-Random)" 
    $jobName = "TestReportJob"
    $globalConfig = @{ HtmlReportTitlePrefix = "Test Report"; HtmlReportTheme = "Default" } 
    $jobConfig = @{} 

    BeforeEach {
        $script:CapturedHtmlParams = $null 
        Mock ConvertTo-Html -ModuleName Pester { 
            param($Head, $Body, $Title)
            $script:CapturedHtmlParams = @{ Head = $Head; Body = $Body; Title = $Title }
            return "<html><body>Report Mock Content</body></html>" 
        }
        if (-not (Test-Path $testReportDir -PathType Container)) {
            New-Item -Path $testReportDir -ItemType Directory -Force | Out-Null
        }
    }
    AfterEach {
        Remove-Variable script:CapturedHtmlParams -ErrorAction SilentlyContinue
        if (Test-Path $testReportDir -PathType Container) {
            Remove-Item -Path $testReportDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Mock -CommandName Get-ConfigValue -ModuleName Reporting.Tests.ps1 -ErrorAction SilentlyContinue
    }

    It "should generate basic HTML structure when called with log entries" {
        $reportData = [ordered]@{
            JobName = $jobName
            OverallStatus = "SUCCESS"
            ScriptStartTime = Get-Date
            ScriptEndTime = (Get-Date).AddMinutes(5)
            TotalDuration = New-TimeSpan -Minutes 5
            LogEntries = @([pscustomobject]@{Timestamp="ts";Level="INFO";Message="<msg>";Colour="Green"}) 
        }
        Invoke-HtmlReport -ReportDirectory $testReportDir -JobName $jobName -ReportData $reportData -GlobalConfig $globalConfig -JobConfig $jobConfig
        
        Mock Set-Content | Should -HaveBeenCalled -Times 1
        $script:CapturedHtmlParams | Should -Not -BeNull
        ($script:CapturedHtmlParams.Title | Out-String) | Should -Match (ConvertTo-SafeHtml $jobName) 
        ($script:CapturedHtmlParams.Body | Out-String) | Should -Match "<h2>Summary</h2>"
        ($script:CapturedHtmlParams.Body | Out-String) | Should -Match "<h2>Detailed Log</h2>"
        ($script:CapturedHtmlParams.Body | Out-String) | Should -Match (ConvertTo-SafeHtml "<msg>") 
    }

    It "should not show configuration section if HtmlReportShowConfiguration is false" {
         $globalConfigLocal = $globalConfig.Clone() 
         
         Mock Get-ConfigValue -ModuleName Reporting.Tests.ps1 -MockWith {
            param($ConfigObject, $Key, $DefaultValue)
            if ($Key -eq 'HtmlReportShowConfiguration') { return $false }
            if ($Key -eq 'HtmlReportTheme') { return "Default" } 
            if ($Key -eq 'HtmlReportTitlePrefix') { return "Test Report"}
            if ($Key -eq 'HtmlReportCompanyName') { return "PoSh Backup"}
            if ($Key -eq 'HtmlReportShowSummary') { return $true } 
            if ($Key -eq 'HtmlReportShowHooks') { return $true }
            if ($Key -eq 'HtmlReportShowLogEntries') { return $true }
            return $DefaultValue 
         }

         $reportData = [ordered]@{ 
            JobName = $jobName; 
            OverallStatus = "SUCCESS"; 
            JobConfiguration = @{ Setting1 = "Val1"}; 
            LogEntries = @() 
         }
         
         Invoke-HtmlReport -ReportDirectory $testReportDir -JobName $jobName -ReportData $reportData -GlobalConfig $globalConfigLocal -JobConfig $jobConfig

         ($script:CapturedHtmlParams.Body | Out-String) | Should -Not -Match "<h2>Configuration Used"
    }
} 