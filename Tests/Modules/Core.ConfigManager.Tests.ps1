# Pester tests for Core/ConfigManager.psm1
Describe 'Core/ConfigManager.psm1' {
    BeforeAll {
        $modulePathRaw = Join-Path $PSScriptRoot '..\..\Modules\Core\ConfigManager.psm1'
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
    $exportedFunctions = @(
        'Import-AppConfiguration',
        'Get-JobsToProcess',
        'Get-PoShBackupJobEffectiveConfiguration'
    )
    foreach ($func in $exportedFunctions) {
        It "Should export $func" -TestCases @{ FuncName = $func } {
            param($FuncName)
            $script:importedModule.ExportedCommands.Keys | Should -Contain $FuncName
        }
    }
}
