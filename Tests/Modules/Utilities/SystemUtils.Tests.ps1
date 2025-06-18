# PoSh-Backup\Tests\Modules\Utilities\SystemUtils.Tests.ps1
#
# Pester test script for functions in Modules\Utilities\SystemUtils.psm1
# This test uses the "local function copy" pattern established in previous tests.
# The logic for the functions under test is copied into this file, and then
# system cmdlets or .NET methods are mocked to control test outcomes.

# --- Function Logic Copied from SystemUtils.psm1 ---
# This section contains local copies of the functions to be tested.
# MODIFIED: Removed internal $LocalWriteLog helper and renamed $Logger param.

function Test-AdminPrivilege-Local {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$LoggerScriptBlock,
        # NEW parameter for dependency injection during testing
        [object]$InjectedPrincipal = $null
    )

    $isAdmin = $false # Default to false
    try {
        # Use injected principal for test, otherwise get the real one
        $principal = if ($null -ne $InjectedPrincipal) {
            $InjectedPrincipal
        } else {
            $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            New-Object System.Security.Principal.WindowsPrincipal($identity)
        }

        $isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($isAdmin) {
            & $LoggerScriptBlock -Message "  - Admin Check: Script is running with Administrator privileges." -Level "DEBUG"
        }
        else {
            & $LoggerScriptBlock -Message "  - Admin Check: Script is NOT running with Administrator privileges. VSS functionality will be unavailable." -Level "DEBUG"
        }
    }
    catch {
        & $LoggerScriptBlock -Message "[WARNING] SystemUtils/Test-AdminPrivilege: Error checking admin privileges. Assuming not admin. Error: $($_.Exception.Message)" -Level "WARNING"
        $isAdmin = $false
    }
    return $isAdmin
}

function Test-DestinationFreeSpace-Local {
    [CmdletBinding()]
    param(
        [string]$DestDir,
        [int]$MinRequiredGB,
        [bool]$ExitOnLow,
        [switch]$IsSimulateMode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$LoggerScriptBlock
    )
    if ($MinRequiredGB -le 0) { return $true }
    & $LoggerScriptBlock -Message "`n[INFO] SystemUtils: Checking destination free space for '$DestDir'..." -Level "INFO"
    & $LoggerScriptBlock -Message "   - Minimum free space required: $MinRequiredGB GB" -Level "INFO"
    if ($IsSimulateMode.IsPresent) {
        & $LoggerScriptBlock -Message "SIMULATE: SystemUtils: Would check free space on '$DestDir'. Assuming sufficient space." -Level SIMULATE
        return $true
    }
    try {
        if (-not (Test-Path -LiteralPath $DestDir -PathType Container)) {
            & $LoggerScriptBlock -Message "[WARNING] SystemUtils: Destination directory '$DestDir' for free space check not found. Skipping." -Level WARNING
            return $true
        }
        $driveLetter = (Get-Item -LiteralPath $DestDir).PSDrive.Name
        $destDrive = Get-PSDrive -Name $driveLetter -ErrorAction Stop
        $freeSpaceGB = [math]::Round($destDrive.Free / 1GB, 2)
        & $LoggerScriptBlock -Message "   - SystemUtils: Available free space on drive $($destDrive.Name) (hosting '$DestDir'): $freeSpaceGB GB" -Level "INFO"
        if ($freeSpaceGB -lt $MinRequiredGB) {
            & $LoggerScriptBlock -Message "[WARNING] SystemUtils: Low disk space on destination. Available: $freeSpaceGB GB, Required: $MinRequiredGB GB." -Level WARNING
            if ($ExitOnLow) {
                & $LoggerScriptBlock -Message "FATAL: SystemUtils: Exiting job due to insufficient free disk space (ExitOnLowSpaceIfBelowMinimum is true)." -Level ERROR
                return $false
            }
        }
        else {
            & $LoggerScriptBlock -Message "   - SystemUtils: Free space check: OK (Available: $freeSpaceGB GB, Required: $MinRequiredGB GB)" -Level SUCCESS
        }
    }
    catch {
        & $LoggerScriptBlock -Message "[WARNING] SystemUtils: Could not determine free space for destination '$DestDir'. Check skipped. Error: $($_.Exception.Message)" -Level WARNING
    }
    return $true
}


# --- Dummy Logger ---
# This function exists so it can be found by the local functions. Pester's `Mock`
# will replace its implementation during the tests.
function Write-LogMessage { param($Message, $Level, $ForegroundColour, $NoTimestampToLogFile) }
# --- End of Copied Logic ---


Describe 'System Utility Functions' {
    BeforeAll {
        # Dot-source this test script to make the local functions and dummy logger available
        . $PSCommandPath

        # Get references to the local functions to be tested.
        $script:TestAdminPrivilege_FuncRef = Get-Command Test-AdminPrivilege-Local
        $script:TestDestinationFreeSpace_FuncRef = Get-Command Test-DestinationFreeSpace-Local
    }

    BeforeEach {
        # Mock the logger function for all tests in this block.
        Mock Write-LogMessage -Verifiable
    }

    Context 'Test-AdminPrivilege' {
        Context 'When running with Administrator privileges' {
            It 'should return $true' {
                $mockPrincipal = [pscustomobject]@{ IsInRole = { param($role) return $true } }
                $result = & $script:TestAdminPrivilege_FuncRef -LoggerScriptBlock ${function:Write-LogMessage} -InjectedPrincipal $mockPrincipal
                $result | Should -BeTrue
            }
            It 'should call the logger with the correct message' {
                $mockPrincipal = [pscustomobject]@{ IsInRole = { param($role) return $true } }
                & $script:TestAdminPrivilege_FuncRef -LoggerScriptBlock ${function:Write-LogMessage} -InjectedPrincipal $mockPrincipal | Out-Null
                Should -Invoke 'Write-LogMessage' -Times 1 -ParameterFilter {
                    $_.Message -like "*running with Administrator privileges*" -and $_.Level -eq 'DEBUG'
                }
            }
        }

        Context 'When running without Administrator privileges' {
            It 'should return $false' {
                $mockPrincipal = [pscustomobject]@{ IsInRole = { param($role) return $false } }
                $result = & $script:TestAdminPrivilege_FuncRef -LoggerScriptBlock ${function:Write-LogMessage} -InjectedPrincipal $mockPrincipal
                $result | Should -BeFalse
            }
             It 'should log a debug message indicating no admin rights' {
                $mockPrincipal = [pscustomobject]@{ IsInRole = { param($role) return $false } }
                & $script:TestAdminPrivilege_FuncRef -LoggerScriptBlock ${function:Write-LogMessage} -InjectedPrincipal $mockPrincipal | Out-Null
                Should -Invoke 'Write-LogMessage' -Times 1 -ParameterFilter {
                    $_.Message -like "*NOT running with Administrator privileges*" -and $_.Level -eq 'DEBUG'
                }
            }
        }
    } # End Context Test-AdminPrivilege

    Context 'Test-DestinationFreeSpace' {
        $testPath = 'C:\Temp'

        Context 'when MinRequiredGB is zero' {
            It 'should return $true immediately without logging space details' {
                $result = & $script:TestDestinationFreeSpace_FuncRef -DestDir $testPath -MinRequiredGB 0 -LoggerScriptBlock ${function:Write-LogMessage}
                $result | Should -BeTrue
                Should -Not -Invoke 'Write-LogMessage' -ParameterFilter { $_.Message -like "*Available free space*" }
            }
        }

        Context 'when in Simulate Mode' {
            It 'should return $true and log a simulation message' {
                $result = & $script:TestDestinationFreeSpace_FuncRef -DestDir $testPath -MinRequiredGB 10 -IsSimulateMode -LoggerScriptBlock ${function:Write-LogMessage}
                $result | Should -BeTrue
                Should -Invoke 'Write-LogMessage' -Times 1 -ParameterFilter {
                    $_.Message -like "SIMULATE:*" -and $_.Level -eq 'SIMULATE'
                }
            }
        }

        Context 'when destination path does not exist' {
            BeforeEach {
                Mock Test-Path -MockWith { return $false } -Verifiable
            }
            It 'should return $true and log a warning' {
                $result = & $script:TestDestinationFreeSpace_FuncRef -DestDir $testPath -MinRequiredGB 10 -LoggerScriptBlock ${function:Write-LogMessage}
                $result | Should -BeTrue
                Should -Invoke 'Write-LogMessage' -Times 1 -ParameterFilter {
                    $_.Message -like "*not found. Skipping.*" -and $_.Level -eq 'WARNING'
                }
            }
        }

        Context 'with a valid path' {
            BeforeEach {
                Mock Test-Path -MockWith { return $true } -Verifiable
                Mock Get-Item -MockWith { [pscustomobject]@{ PSDrive = [pscustomobject]@{ Name = 'C' } } } -Verifiable
            }
            Context 'and sufficient free space' {
                BeforeEach {
                    Mock Get-PSDrive -MockWith { [pscustomobject]@{ Name = 'C'; Free = 20GB } } -Verifiable
                }
                It 'should return $true' {
                    $result = & $script:TestDestinationFreeSpace_FuncRef -DestDir $testPath -MinRequiredGB 10 -LoggerScriptBlock ${function:Write-LogMessage}
                    $result | Should -BeTrue
                }
                It 'should log a SUCCESS message' {
                     & $script:TestDestinationFreeSpace_FuncRef -DestDir $testPath -MinRequiredGB 10 -LoggerScriptBlock ${function:Write-LogMessage} | Out-Null
                     Should -Invoke 'Write-LogMessage' -Times 1 -ParameterFilter { $_.Level -eq 'SUCCESS' }
                }
            }
            Context 'and insufficient free space with ExitOnLow=$false' {
                BeforeEach {
                    Mock Get-PSDrive -MockWith { [pscustomobject]@{ Name = 'C'; Free = 5GB } } -Verifiable
                }
                 It 'should return $true' {
                    $result = & $script:TestDestinationFreeSpace_FuncRef -DestDir $testPath -MinRequiredGB 10 -ExitOnLow:$false -LoggerScriptBlock ${function:Write-LogMessage}
                    $result | Should -BeTrue
                }
                It 'should log a WARNING message' {
                     & $script:TestDestinationFreeSpace_FuncRef -DestDir $testPath -MinRequiredGB 10 -ExitOnLow:$false -LoggerScriptBlock ${function:Write-LogMessage} | Out-Null
                     Should -Invoke 'Write-LogMessage' -Times 1 -ParameterFilter { $_.Message -like "*Low disk space*" -and $_.Level -eq 'WARNING' }
                }
            }

            Context 'and insufficient free space with ExitOnLow=$true' {
                 BeforeEach {
                    Mock Get-PSDrive -MockWith { [pscustomobject]@{ Name = 'C'; Free = 5GB } } -Verifiable
                }
                 It 'should return $false' {
                    $result = & $script:TestDestinationFreeSpace_FuncRef -DestDir $testPath -MinRequiredGB 10 -ExitOnLow:$true -LoggerScriptBlock ${function:Write-LogMessage}
                    $result | Should -BeFalse
                }
                It 'should log an ERROR message' {
                     & $script:TestDestinationFreeSpace_FuncRef -DestDir $testPath -MinRequiredGB 10 -ExitOnLow:$true -LoggerScriptBlock ${function:Write-LogMessage} | Out-Null
                     Should -Invoke 'Write-LogMessage' -Times 1 -ParameterFilter { $_.Message -like "*FATAL*" -and $_.Level -eq 'ERROR' }
                }
            }

            Context 'and an error occurs during drive check' {
                BeforeEach {
                    Mock Get-PSDrive -MockWith { throw "Disk not ready" } -Verifiable
                }
                It 'should return $true' {
                    $result = & $script:TestDestinationFreeSpace_FuncRef -DestDir $testPath -MinRequiredGB 10 -LoggerScriptBlock ${function:Write-LogMessage}
                    $result | Should -BeTrue
                }
                It 'should log a WARNING about the failure' {
                     & $script:TestDestinationFreeSpace_FuncRef -DestDir $testPath -MinRequiredGB 10 -LoggerScriptBlock ${function:Write-LogMessage} | Out-Null
                     Should -Invoke 'Write-LogMessage' -Times 1 -ParameterFilter { $_.Message -like "*Could not determine free space*" -and $_.Level -eq 'WARNING' }
                }
            }
        }
    } # End Context Test-DestinationFreeSpace
}
