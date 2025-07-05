# Pester tests for Utils.psm1
Describe 'Utils.psm1' {
    BeforeAll {
        $modulePathRaw = Join-Path $PSScriptRoot '..\..\Modules\Utils.psm1'
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
        # Store for use in tests
        Set-Variable -Name 'modulePath' -Value $modulePath -Scope Global
        $script:importedModule = Get-Module | Where-Object { $_.Path -eq $modulePath }
    }
    It 'Should import without error' {
        $script:importedModule | Should -Not -BeNullOrEmpty
    }
    $exportedFunctions = @(
        'Get-ConfigValue','Get-RequiredConfigValue','Expand-EnvironmentVariablesInConfig','Write-ConsoleBanner','Write-NameValue','Start-CancellableCountdown','Get-PoShBackupSecret','Get-ArchiveSizeFormatted','Format-FileSize','Get-PoshBackupFileHash','Resolve-PoShBackupPath','Group-BackupInstancesByTimestamp','Get-ScriptVersionFromContent','Test-AdminPrivilege','Test-DestinationFreeSpace','Test-HibernateEnabled','Write-LogMessage','Invoke-PoShBackupUpdateCheckAndApply'
    ) | Where-Object { $_ }
    foreach ($func in $exportedFunctions) {
        It "Should export $func" -TestCases @{ FuncName = $func } {
            param($FuncName)
            $script:importedModule.ExportedCommands.Keys | Should -Contain $FuncName
        }
    }
    It 'Should export Get-ConfigValue' {
        $importedModule = Get-Module | Where-Object { $_.Path -eq $global:modulePath }
        (Get-Command Get-ConfigValue -Module $importedModule.Name) | Should -Not -BeNullOrEmpty
    }
    It 'Get-ConfigValue returns value for existing key' {
        $result = Get-ConfigValue -ConfigObject @{ Foo = 'Bar' } -Key 'Foo' -DefaultValue 'Default'
        $result | Should -Be 'Bar'
    }
    It 'Get-ConfigValue returns default for missing key' {
        $result = Get-ConfigValue -ConfigObject @{ Foo = 'Bar' } -Key 'Missing' -DefaultValue 'Default'
        $result | Should -Be 'Default'
    }
    It 'Get-ConfigValue returns $null for missing key and no default' {
        $result = Get-ConfigValue -ConfigObject @{ Foo = 'Bar' } -Key 'Missing'
        $result | Should -BeNullOrEmpty
    }
    It 'Get-ConfigValue handles empty hashtable' {
        $result = Get-ConfigValue -ConfigObject @{} -Key 'AnyKey' -DefaultValue 'Default'
        $result | Should -Be 'Default'
    }
    It 'Get-ConfigValue handles $null ConfigObject' {
        $result = Get-ConfigValue -ConfigObject $null -Key 'AnyKey' -DefaultValue 'Default'
        $result | Should -Be 'Default'
    }
    It 'Format-FileSize formats bytes as KB, MB, GB' {
        (Format-FileSize -Bytes 1023) | Should -Be '1023 Bytes'
        (Format-FileSize -Bytes 2048) | Should -Match '2.00 KB'
        (Format-FileSize -Bytes 5MB) | Should -Match '5.00 MB'
        (Format-FileSize -Bytes 3GB) | Should -Match '3.00 GB'
    }
    # Add more tests for each exported function as needed
}
