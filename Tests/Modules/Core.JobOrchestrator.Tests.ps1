# Pester tests for Core/JobOrchestrator.psm1
Describe 'Core/JobOrchestrator.psm1' {
    BeforeAll {
        $PSScriptRoot = $PSScriptRoot
        $modulePathRaw = Join-Path $PSScriptRoot '..\..\Modules\Core\JobOrchestrator.psm1'
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
        Set-Variable -Name 'modulePath' -Value $modulePath -Scope Global
    }
    It 'Should import without error' {
        $importedModule = Get-Module | Where-Object { $_.Path -eq $global:modulePath }
        $importedModule | Should -Not -BeNullOrEmpty
    }
    It 'Should export Invoke-PoShBackupRun' {
        $importedModule = Get-Module | Where-Object { $_.Path -eq $global:modulePath }
        (Get-Command Invoke-PoShBackupRun -Module $importedModule.Name) | Should -Not -BeNullOrEmpty
    }
    # Add more tests for each exported function as needed
}
