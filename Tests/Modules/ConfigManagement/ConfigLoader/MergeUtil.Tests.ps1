# Tests\Modules\ConfigManagement\ConfigLoader\MergeUtil.Tests.ps1

# Pester tests for Merge-DeepHashtable
# Covers flat, nested, type, edge, and immutability scenarios

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePath = Join-Path $here '..\..\..\..\Modules\ConfigManagement\ConfigLoader\MergeUtil.psm1'
Import-Module $modulePath -Force

Describe 'Merge-DeepHashtable' {
    Context 'Flat hashtables' {
        It 'merges two flat hashtables with no overlap' {
            $base = @{a=1; b=2}
            $override = @{c=3; d=4}
            $result = Merge-DeepHashtable -Base $base -Override $override
            $result | Should -BeOfType hashtable
            $result.Keys.Count | Should -Be 4
            $result['a'] | Should -Be 1
            $result['b'] | Should -Be 2
            $result['c'] | Should -Be 3
            $result['d'] | Should -Be 4
        }
        It 'merges two flat hashtables with overlap (override wins)' {
            $base = @{a=1; b=2}
            $override = @{b=99; c=3}
            $result = Merge-DeepHashtable -Base $base -Override $override
            $result['a'] | Should -Be 1
            $result['b'] | Should -Be 99
            $result['c'] | Should -Be 3
        }
    }
    Context 'Nested hashtables' {
        It 'recursively merges nested hashtables' {
            $base = @{a=1; b=@{x=10; y=20}}
            $override = @{b=@{y=99; z=30}}
            $result = Merge-DeepHashtable -Base $base -Override $override
            $result['a'] | Should -Be 1
            $result['b']['x'] | Should -Be 10
            $result['b']['y'] | Should -Be 99
            $result['b']['z'] | Should -Be 30
        }
        It 'overrides with scalar if override is not a hashtable' {
            $base = @{a=1; b=@{x=10}}
            $override = @{b=42}
            $result = Merge-DeepHashtable -Base $base -Override $override
            $result['b'] | Should -Be 42
        }
        It 'overrides with hashtable if base is not a hashtable' {
            $base = @{a=1; b=42}
            $override = @{b=@{x=10}}
            $result = Merge-DeepHashtable -Base $base -Override $override
            $result['b']['x'] | Should -Be 10
        }
    }
    Context 'Array and type handling' {
        It 'overrides arrays, does not merge them' {
            $base = @{a=@(1,2,3)}
            $override = @{a=@(4,5)}
            $result = Merge-DeepHashtable -Base $base -Override $override
            $result['a'] | Should -Be @(4,5)
        }
        It 'overrides scalar with array' {
            $base = @{a=1}
            $override = @{a=@(2,3)}
            $result = Merge-DeepHashtable -Base $base -Override $override
            $result['a'] | Should -Be @(2,3)
        }
    }
    Context 'Edge cases' {
        It 'returns a clone of base if override is empty' {
            $base = @{a=1; b=2}
            $override = @{}
            $result = Merge-DeepHashtable -Base $base -Override $override
            $result | Should -BeOfType hashtable
            $result.Keys.Count | Should -Be $base.Keys.Count
            foreach ($k in $base.Keys) { $result[$k] | Should -Be $base[$k] }
        }
        It 'returns a clone of override if base is empty' {
            $base = @{}
            $override = @{a=1; b=2}
            $result = Merge-DeepHashtable -Base $base -Override $override
            $result | Should -BeOfType hashtable
            $result.Keys.Count | Should -Be $override.Keys.Count
            foreach ($k in $override.Keys) { $result[$k] | Should -Be $override[$k] }
        }
        It 'returns empty hashtable if both are empty' {
            $base = @{}
            $override = @{}
            $result = Merge-DeepHashtable -Base $base -Override $override
            $result.Keys.Count | Should -Be 0
        }
    }
    Context 'Immutability' {
        It 'does not mutate the original base or override' {
            $base = @{a=1; b=@{x=10}}
            $override = @{b=@{y=20}}
            $baseCopy = $base.Clone()
            $overrideCopy = $override.Clone()
            $result = Merge-DeepHashtable -Base $base -Override $override
            $base.Keys.Count | Should -Be $baseCopy.Keys.Count
            foreach ($k in $base.Keys) { $base[$k] | Should -Be $baseCopy[$k] }
            $override.Keys.Count | Should -Be $overrideCopy.Keys.Count
            foreach ($k in $override.Keys) { $override[$k] | Should -Be $overrideCopy[$k] }
        }
    }
}
