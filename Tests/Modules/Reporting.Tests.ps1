# Pester tests for Reporting.psm1
Describe 'Reporting.psm1' {
    BeforeAll {
        $modulePathRaw = Join-Path $PSScriptRoot '..\..\Modules\Reporting.psm1'
        try {
            $modulePath = (Resolve-Path $modulePathRaw).Path
        } catch {
            throw "Could not resolve module path: $modulePathRaw"
        }
        if (-Not (Test-Path $modulePath)) {
            throw "Module file not found at $modulePath"
        }
        Get-Module | Where-Object { $_.Path -eq $modulePath } | ForEach-Object { Remove-Module $_.Name -Force }
        Import-Module $modulePath -Force
        $script:importedModule = Get-Module | Where-Object { $_.Path -eq $modulePath }
    }
    It 'Should import without error' {
        $script:importedModule | Should -Not -BeNullOrEmpty
    }
    $exportedFunctions = @(
        'Invoke-ReportGenerator',
        'Invoke-SetSummaryReportGenerator'
    )
    foreach ($func in $exportedFunctions) {
        It "Should export $func" -TestCases @{ FuncName = $func } {
            param($FuncName)
            $script:importedModule.ExportedCommands.Keys | Should -Contain $FuncName
        }
    }

    It 'Invoke-ReportGenerator throws if missing required parameters' {
        { Invoke-ReportGenerator } | Should -Throw
    }
    It 'Invoke-SetSummaryReportGenerator throws if missing required parameters' {
        { Invoke-SetSummaryReportGenerator } | Should -Throw
    }
    It 'Invoke-ReportGenerator handles NONE report type gracefully' {
        $logger = { param($Message, $Level) }
        $result = Invoke-ReportGenerator -ReportDirectory 'Reports' -JobName 'TestJob' -ReportData @{} -GlobalConfig @{ _PoShBackup_PSScriptRoot = $PSScriptRoot } -JobConfig @{ ReportGeneratorType = 'NONE' } -Logger $logger
        $result | Should -BeNullOrEmpty
    }
    It 'Invoke-SetSummaryReportGenerator returns null if module not found' {
        $logger = { param($Message, $Level) }
        $result = Invoke-SetSummaryReportGenerator -SetReportData @{ SetName = 'TestSet' } -GlobalConfig @{ _PoShBackup_PSScriptRoot = $PSScriptRoot } -Logger $logger
        $result | Should -BeNullOrEmpty
    }
}
