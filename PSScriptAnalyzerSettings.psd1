# PSScriptAnalyzer settings for psclip: tools\Invoke-Lint.ps1 uses them, and so does VS Code's PowerShell extension
# (it reads this file from the workspace folder). All other default rules apply; single findings that are
# intended are suppressed in the code with a SuppressMessageAttribute and a justification.
@{
    ExcludeRules = @(
        # -WhatIf/-Confirm for every Set-/Remove-/New- function: these are the internal functions of a tray app,
        # called by its own event handlers - nobody could pass -WhatIf to them.
        'PSUseShouldProcessForStateChangingFunctions'

        # WinForms event handlers declare (source, e) to reach e; the unused source is not a mistake.
        'PSReviewUnusedParameter'

        # Names like Get-ShortcutArguments or Add-Entries say what the functions return or take.
        'PSUseSingularNouns'

        # Install.ps1 and the tools talk to the user in the console - what Write-Host is for (in Windows
        # PowerShell 5.1 it writes to the information stream, so it can still be redirected).
        'PSAvoidUsingWriteHost'
    )
}
