# PoSh-Backup\PSScriptAnalyzerSettings.psd1
@{
    # Rules to exclude entirely for this project due to design choices or persistent issues with targeted suppression in IDE/bundler.
    # JC: We're being heavy handed here as for some reason inline suppressions aren't working; this needs to be fixed in the future... somehow!
    ExcludeRules = @(
        'PSAvoidUsingPlainTextForPassword',    # For $TempPasswordFile in Operations.psm1 (path, not password)
        'PSUseCIMToolingForWin32Namespace',    # For Get-WmiObject Win32_ShadowCopy in Operations.psm1
        'PSUseApprovedVerbs',                  # For Validate-AgainstSchemaRecursiveInternal & other potential internal helpers
        'PSUseDeclaredVarsMoreThanAssignments',# For $Logger params & other potential false positives if attribute/comment fails
        'PSAvoidUsingInvokeExpression',        # For the bundler's -TestConfig capture method
        'PSAvoidUsingWriteHost'                # For utility scripts' direct console feedback & specific PoSh-Backup.ps1 uses
    )

    # Severity level to report. Default is Warning.
    Severity = @('Error', 'Warning')
}
