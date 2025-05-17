# PoSh-Backup\PSScriptAnalyzerSettings.psd1
@{
    # Rules to exclude entirely for this project due to design choices or persistent issues with targeted suppression in IDE/bundler.
    ExcludeRules = @(
        'PSAvoidUsingPlainTextForPassword',    # For $TempPasswordFile in Operations.psm1 (path, not password)
        # 'PSUseCIMToolingForWin32Namespace',  # REMOVED: WMI usage in Operations.psm1 was changed to CIM.
        'PSUseApprovedVerbs',                  # For Validate-AgainstSchemaRecursiveInternal & other potential internal helpers
        # 'PSUseDeclaredVarsMoreThanAssignments',# REMOVED: Unused logger parameters addressed by defensive calls in code.
        'PSAvoidUsingInvokeExpression',        # For the bundler's -TestConfig capture method
        'PSAvoidUsingWriteHost',               # For utility scripts' direct console feedback & specific PoSh-Backup.ps1 uses
        'PSAvoidGlobalVars'                    # For intentional global variable usage (e.g., $Global:ColourInfo, $Global:StatusToColourMap)
    )

    # Severity level to report. Default is Warning.
    Severity = @('Error', 'Warning')
}
