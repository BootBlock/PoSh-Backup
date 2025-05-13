#Requires -Modules Pester

# --- CRITICAL DIAGNOSTIC (Top Level) ---
Write-Host "--------------------------------------------------------------------"
Write-Host "Pester Version Check within Minimal.Operations.Tests.ps1 (TOP LEVEL):"
Get-Module Pester -ListAvailable | ForEach-Object { Write-Host "Available: $($_.Version) at $($_.Path)" }
$loadedPester = Get-Module Pester -ErrorAction SilentlyContinue
if ($loadedPester) {
    Write-Host "Currently Loaded Pester: $($loadedPester.Version) from $($loadedPester.Path)"
} else {
    Write-Warning "Pester module is NOT currently loaded at start of Minimal.Operations.Tests.ps1"
    try {
        Import-Module Pester -RequiredVersion 5.7.1 -Force -ErrorAction Stop
        $loadedPester = Get-Module Pester
        Write-Host "Newly Loaded Pester: $($loadedPester.Version) from $($loadedPester.Path)"
    } catch {
        Write-Error "Failed to explicitly load Pester 5.7.1. Error: $($_.Exception.Message)"
    }
}
Write-Host "Details for Get-Command Remove-Mock (TOP LEVEL):"
Get-Command Remove-Mock -ErrorAction SilentlyContinue | Format-List Name, ModuleName, Version, Path, CommandType -Force
Write-Host "--------------------------------------------------------------------"

Describe "Pester Internal Command Resolution Test" {
    It "Should find Pester's Remove-Mock command using Get-Command within an It block" {
        Write-Host "--- INSIDE TEST: Get-Command Remove-Mock ---"
        $CommandInfo = Get-Command Remove-Mock -ErrorAction SilentlyContinue
        $CommandInfo | Should -Not -BeNull "Get-Command Remove-Mock should find the command"
        if ($CommandInfo) {
            Write-Host "Found Remove-Mock: Module '$($CommandInfo.ModuleName)', Version '$($CommandInfo.Version)'"
            $CommandInfo.ModuleName | Should -Be "Pester"
            ($CommandInfo.Module.Version.ToString()) | Should -Be "5.7.1"
        }
    }

    It "Should find Pester's Mock command using Get-Command within an It block" {
        Write-Host "--- INSIDE TEST: Get-Command Mock ---"
        $CommandInfo = Get-Command Mock -ErrorAction SilentlyContinue
        $CommandInfo | Should -Not -BeNull "Get-Command Mock should find the command"
        if ($CommandInfo) {
            Write-Host "Found Mock: Module '$($CommandInfo.ModuleName)', Version '$($CommandInfo.Version)'"
            $CommandInfo.ModuleName | Should -Be "Pester"
        }
    }

    It "Should find Pester's Should command using Get-Command within an It block" {
        Write-Host "--- INSIDE TEST: Get-Command Should ---"
        $CommandInfo = Get-Command Should -ErrorAction SilentlyContinue
        $CommandInfo | Should -Not -BeNull "Get-Command Should should find the command"
        if ($CommandInfo) {
            Write-Host "Found Should: Module '$($CommandInfo.ModuleName)', Version '$($CommandInfo.Version)'"
            $CommandInfo.ModuleName | Should -Be "Pester"
        }
    }

    It "Should be able to execute a simple Mock and Remove-Mock cycle if commands are found" {
        $gcmRemoveMock = Get-Command Remove-Mock -ErrorAction SilentlyContinue
        $gcmMock = Get-Command Mock -ErrorAction SilentlyContinue

        if ($gcmRemoveMock -and $gcmMock) {
            Write-Host "Proceeding with Mock/Remove-Mock cycle test."
            Mock Get-Date { return [datetime]"2000-01-01" } -Verifiable # Pester v5 specific
            (Get-Date).Year | Should -Be 2000
            Mock Get-Date | Should -HaveBeenCalled # Pester v5 specific
            Remove-Mock Get-Date
            (Get-Date).Year | Should -Not -Be 2000
        } else {
            Skip "Skipping Mock/Remove-Mock cycle because core Pester commands were not found."
        }
    }
}