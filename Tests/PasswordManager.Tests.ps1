# Tests\PasswordManager.Tests.ps1
#Requires -Modules Pester
using module Pester

$TestScriptFile = $MyInvocation.MyCommand.Definition
$TestScriptDirectory = Split-Path -Path $TestScriptFile -Parent
$ProjectRoot = Split-Path -Path $TestScriptDirectory -Parent
$ModulesRoot = Join-Path -Path $ProjectRoot -ChildPath "Modules"

Import-Module (Join-Path -Path $TestScriptDirectory -ChildPath "TestHelpers.psm1") -Force
Import-Module (Join-Path -Path $ModulesRoot -ChildPath "Utils.psm1") -Force
Import-Module (Join-Path -Path $ModulesRoot -ChildPath "PasswordManager.psm1") -Force

BeforeAll {
    Initialize-PoShBackupTestGlobals
}

Describe "PasswordManager Module - Get-PoShBackupArchivePassword" {

    Context "Method: None" {
        It "Should return null password if ArchivePasswordMethod is None and UsePassword is false" {
            $testJobName = "PM_None_1_NoUsePass" # Unique for clarity
            $testJobConfig = @{ ArchivePasswordMethod = "None"; UsePassword = $false }
            Mock Get-ConfigValue -MockWith { param($ConfigObject, $Key, $DefaultValue)
                if ($ConfigObject -eq $testJobConfig -and $testJobConfig.ContainsKey($Key)) { return $testJobConfig[$Key] }
                return $DefaultValue
            }
            $result = Get-PoShBackupArchivePassword -JobConfigForPassword $testJobConfig -JobName $testJobName -Logger ${function:Write-LogMessage}
            $result.PlainTextPassword | Should -BeNullOrEmpty
            $result.PasswordSource | Should -Be "None (Not Configured)"
        }

        It "Should default to INTERACTIVE if UsePassword is true and Method is None, and return password" {
            $testJobName = "PM_None_2_UsePassInteractive"
            $testJobConfig = @{ ArchivePasswordMethod = "None"; UsePassword = $true; CredentialUserNameHint = "user_none_interactive" }
            Mock Get-ConfigValue -MockWith { param($ConfigObject, $Key, $DefaultValue)
                # This mock needs to respond correctly for *all* Get-ConfigValue calls within the SUT for this scenario
                if ($ConfigObject -eq $testJobConfig) {
                    if ($Key -eq "ArchivePasswordMethod") { return "None" } # Initial state
                    if ($Key -eq "UsePassword") { return $true }
                    if ($Key -eq "CredentialUserNameHint") { return $testJobConfig.CredentialUserNameHint }
                }
                return $DefaultValue # Fallback if not specifically handled
            }
            Mock Get-Credential { return [pscredential]::new($testJobConfig.CredentialUserNameHint, ("securepass" | ConvertTo-SecureString -AsPlainText -Force)) }

            $result = Get-PoShBackupArchivePassword -JobConfigForPassword $testJobConfig -JobName $testJobName -Logger ${function:Write-LogMessage}
            $result.PlainTextPassword | Should -Be "securepass"
            $result.PasswordSource | Should -Be "Interactive (Get-Credential)"
            Should -Invoke Get-Credential -Exactly 1
        }
    }

    Context "Method: Interactive" {
        It "Should prompt for password and return it" {
            $testJobName = "PM_Interactive_1_Prompt"
            $testJobConfig = @{ ArchivePasswordMethod = "Interactive"; CredentialUserNameHint = "backup_interactive_prompt" }
            Mock Get-ConfigValue -MockWith { param($CO, $K, $DV) if ($CO -eq $testJobConfig -and $testJobConfig.ContainsKey($K)) { return $testJobConfig[$K] } else { return $DV } }
            Mock Get-Credential { return [pscredential]::new($testJobConfig.CredentialUserNameHint, ("interactivePass" | ConvertTo-SecureString -AsPlainText -Force)) }

            $result = Get-PoShBackupArchivePassword -JobConfigForPassword $testJobConfig -JobName $testJobName -Logger ${function:Write-LogMessage}
            $result.PlainTextPassword | Should -Be "interactivePass"
            $result.PasswordSource | Should -Be "Interactive (Get-Credential)"
            Should -Invoke Get-Credential -Exactly 1
        }

        It "Should throw if Get-Credential is cancelled" {
            $testJobName = "PM_Interactive_2_Cancel"
            $testJobConfig = @{ ArchivePasswordMethod = "Interactive"; CredentialUserNameHint = "canceluser_interactive_throw" }
            Mock Get-ConfigValue -MockWith { param($CO, $K, $DV) if ($CO -eq $testJobConfig -and $testJobConfig.ContainsKey($K)) { return $testJobConfig[$K] } else { return $DV } }
            Mock Get-Credential { return $null } # Simulate cancellation

            { Get-PoShBackupArchivePassword -JobConfigForPassword $testJobConfig -JobName $testJobName -Logger ${function:Write-LogMessage} } | Should -Throw "Password entry cancelled for job '$testJobName'."
            Should -Invoke Get-Credential -Exactly 1 # Get-Credential is called, then SUT throws
        }

        It "Should return simulated password in SimulateMode" {
            $testJobName = "PM_Interactive_3_Sim"
            $testJobConfig = @{ ArchivePasswordMethod = "Interactive" } # Hint not strictly needed for sim path
            Mock Get-ConfigValue -MockWith { param($CO, $K, $DV) if ($CO -eq $testJobConfig -and $testJobConfig.ContainsKey($K)) { return $testJobConfig[$K] } else { return $DV } }
            Mock Get-Credential { throw "Get-Credential should NOT have been called in SimulateMode!" }

            $result = Get-PoShBackupArchivePassword -JobConfigForPassword $testJobConfig -JobName $testJobName -Logger ${function:Write-LogMessage} -IsSimulateMode
            $result.PlainTextPassword | Should -Be "SimulatedPasswordInteractive123!"
            Should -Invoke Get-Credential -Exactly 0
        }
    }

    Context "Method: SecretManagement" {
        # Variables defined at Context level are available to It blocks if not redefined locally
        $ctxJobName = "PM_SM_Ctx"
        $ctxSecretName = "MyBackupPass_SMCtx_Test"
        $ctxVaultName = "MyVault_SMCtx_Test" # Can be empty/null
        $ctxJobConfig = @{
            ArchivePasswordMethod = "SecretManagement"
            ArchivePasswordSecretName = $ctxSecretName
            ArchivePasswordVaultName = $ctxVaultName
        }
        BeforeEach {
            # This mock applies to all 'It' blocks in this context
            Mock Get-ConfigValue -MockWith {param($CO, $K, $DV) if ($CO -eq $ctxJobConfig -and $ctxJobConfig.ContainsKey($K)){return $ctxJobConfig[$K]}else{return $DV}}
            # Mock Get-Command to say Get-Secret is available, each 'It' block will mock Get-Secret behavior
            Mock -CommandName Get-Command -ParameterFilter { $PSBoundParameters.Name -eq 'Get-Secret' } -MockWith { return $true }
        }

        It "Should retrieve password from SecretManagement (SecureString)" {
            Mock Get-Secret -MockWith { # Mock Get-Secret for this specific test
                param($NameParam, $VaultParam)
                if ($NameParam -eq $ctxSecretName -and ($VaultParam -eq $ctxVaultName -or ($null -eq $VaultParam -and [string]::IsNullOrWhiteSpace($ctxVaultName)) )) {
                    return [pscustomobject]@{ Secret = ("sm_password" | ConvertTo-SecureString -AsPlainText -Force) }
                }
            }
            $result = Get-PoShBackupArchivePassword -JobConfigForPassword $ctxJobConfig -JobName $ctxJobName -Logger ${function:Write-LogMessage}
            $result.PlainTextPassword | Should -Be "sm_password"
            Should -Invoke Get-Secret -Exactly 1 -ParameterFilter { $_.Name -eq $ctxSecretName -and ($_.Vault -eq $ctxVaultName -or ($null -eq $_.Vault -and [string]::IsNullOrWhiteSpace($ctxVaultName))) }
        }

        It "Should retrieve password from SecretManagement (PlainText)" {
            Mock Get-Secret -MockWith {
                param($NameParam, $VaultParam)
                if ($NameParam -eq $ctxSecretName -and ($VaultParam -eq $ctxVaultName -or ($null -eq $VaultParam -and [string]::IsNullOrWhiteSpace($ctxVaultName)) )) {
                    return [pscustomobject]@{ Secret = "sm_plain_password" }
                }
            }
            $result = Get-PoShBackupArchivePassword -JobConfigForPassword $ctxJobConfig -JobName $ctxJobName -Logger ${function:Write-LogMessage}
            $result.PlainTextPassword | Should -Be "sm_plain_password"
            Should -Invoke Get-Secret -Exactly 1
        }

        It "Should throw if secret not found" {
            Mock Get-Secret -MockWith { return $null } # Get-Secret called, but returns null
            { Get-PoShBackupArchivePassword -JobConfigForPassword $ctxJobConfig -JobName $ctxJobName -Logger ${function:Write-LogMessage} } | Should -Throw "Secret '$ctxSecretName' not found or Get-Secret returned null."
            Should -Invoke Get-Secret -Exactly 1
        }

        It "Should throw if SecretManagement module not available" {
            Mock -CommandName Get-Command -ParameterFilter { $PSBoundParameters.Name -eq 'Get-Secret' } -MockWith { return $null } # Override BeforeEach mock
            { Get-PoShBackupArchivePassword -JobConfigForPassword $ctxJobConfig -JobName $ctxJobName -Logger ${function:Write-LogMessage} } | Should -Throw "PowerShell SecretManagement module is not available"
            Should -Invoke Get-Secret -Exactly 0
        }
    }

    Context "Method: SecureStringFile" {
        It "Should retrieve password from SecureStringFile" {
            $testJobName = "PM_SSF_1_Retrieve"
            $filePathForTest = (Join-Path $Global:TestTempDir "securepass_ssf1_retrieve.clixml")
            $testJobConfig = @{ ArchivePasswordMethod = "SecureStringFile"; ArchivePasswordSecureStringPath = $filePathForTest }
            Mock Get-ConfigValue -MockWith {param($CO, $K, $DV) if ($CO -eq $testJobConfig -and $testJobConfig.ContainsKey($K)){return $testJobConfig[$K]}else{return $DV}}
            $securePassword = "file_password" | ConvertTo-SecureString -AsPlainText -Force
            Mock Test-Path -MockWith { param($LiteralPathValue) Write-Verbose "Mock Test-Path (SSF1): Path='$LiteralPathValue', Expecting='$filePathForTest'"; $LiteralPathValue -eq $filePathForTest }
            Mock Import-Clixml -MockWith { param($LiteralPathValue) if ($LiteralPathValue -eq $filePathForTest) { return $securePassword } }

            $result = Get-PoShBackupArchivePassword -JobConfigForPassword $testJobConfig -JobName $testJobName -Logger ${function:Write-LogMessage}
            $result.PlainTextPassword | Should -Be "file_password"
            Should -Invoke Import-Clixml -Exactly 1
            Should -Invoke Test-Path -Exactly 1 -ParameterFilter { $_.LiteralPathValue -eq $filePathForTest }
        }

        It "Should throw if file not found" {
            $testJobName = "PM_SSF_2_NotFound"
            $filePathForTest = (Join-Path $Global:TestTempDir "securepass_ssf2_nonexist.clixml")
            $testJobConfig = @{ ArchivePasswordMethod = "SecureStringFile"; ArchivePasswordSecureStringPath = $filePathForTest }
            Mock Get-ConfigValue -MockWith {param($CO, $K, $DV) if ($CO -eq $testJobConfig -and $testJobConfig.ContainsKey($K)){return $testJobConfig[$K]}else{return $DV}}
            Mock Test-Path -MockWith { $false }
            { Get-PoShBackupArchivePassword -JobConfigForPassword $testJobConfig -JobName $testJobName -Logger ${function:Write-LogMessage} } | Should -Throw "SecureStringFile '$filePathForTest' not found for job '$testJobName'."
            Should -Invoke Test-Path -Exactly 1 -ParameterFilter { $_.LiteralPathValue -eq $filePathForTest }
            Should -Invoke Import-Clixml -Exactly 0
        }
    }

    Context "Method: PlainText" {
        It "Should return plain text password from config" {
            $testJobName = "PM_PT_1_Return"
            $testJobConfig = @{ ArchivePasswordMethod = "PlainText"; ArchivePasswordPlainText = "PlainPassword123" }
            Mock Get-ConfigValue -MockWith {param($CO, $K, $DV) if ($CO -eq $testJobConfig -and $testJobConfig.ContainsKey($K)){return $testJobConfig[$K]}else{return $DV}}
            $result = Get-PoShBackupArchivePassword -JobConfigForPassword $testJobConfig -JobName $testJobName -Logger ${function:Write-LogMessage}
            $result.PlainTextPassword | Should -Be "PlainPassword123"
        }

        It "Should throw if plain text password is not configured" {
            $testJobName = "PM_PT_2_Throw"
            $testJobConfig = @{ ArchivePasswordMethod = "PlainText"; ArchivePasswordPlainText = "" }
            Mock Get-ConfigValue -MockWith {param($CO, $K, $DV) if ($CO -eq $testJobConfig -and $testJobConfig.ContainsKey($K)){return $testJobConfig[$K]}else{return $DV}}
            { Get-PoShBackupArchivePassword -JobConfigForPassword $testJobConfig -JobName $testJobName -Logger ${function:Write-LogMessage} } | Should -Throw "ArchivePasswordPlainText is empty or not defined for job '$testJobName'."
        }
    }
}
