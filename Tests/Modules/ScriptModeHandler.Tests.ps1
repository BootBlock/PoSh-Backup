# Pester tests for ScriptModeHandler.psm1
Describe 'ScriptModeHandler.psm1' {
    BeforeAll {
        $modulePathRaw = Join-Path $PSScriptRoot '..\..\Modules\ScriptModeHandler.psm1'
        try {
            $modulePath = (Resolve-Path $modulePathRaw).Path
        } catch {
            throw "Could not resolve module path: $modulePathRaw"
        }
        if (-not (Test-Path $modulePath)) {
            throw "Module file not found at $modulePath"
        }
        Get-Module | Where-Object { $_.Path -eq $modulePath } | ForEach-Object { Remove-Module $_.Name -Force }
        Import-Module $modulePath -Force
        $script:importedModule = Get-Module | Where-Object { $_.Path -eq $modulePath }
    }
    It 'Should import without error' {
        $script:importedModule | Should -Not -BeNullOrEmpty
    }
    $exportedFunctions = @('Invoke-PoShBackupScriptMode')
    foreach ($func in $exportedFunctions) {
        It "Should export $func" -TestCases @{ FuncName = $func } {
            param($FuncName)
            $script:importedModule.ExportedCommands.Keys | Should -Contain $FuncName
        }
    }
    It 'Invoke-PoShBackupScriptMode returns $false if no mode switches are set' {
        $logger = { }
        $params = @{
            ListBackupLocationsSwitch = $false
            ListBackupSetsSwitch = $false
            TestConfigSwitch = $false
            PreFlightCheckSwitch = $false
            RunVerificationJobsSwitch = $false
            CheckForUpdateSwitch = $false
            VersionSwitch = $false
            CliOverrideSettingsInternal = @{
            }
            Configuration = @{
            }
            ActualConfigFile = 'dummy.psd1'
            ConfigLoadResult = @{
            }
            Logger = $logger
        }
        $result = Invoke-PoShBackupScriptMode @params
        $result | Should -BeFalse
    }
}
