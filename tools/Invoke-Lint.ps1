<#
.SYNOPSIS
    Checks the PowerShell code with PSScriptAnalyzer and the rules in PSScriptAnalyzerSettings.psd1.

.DESCRIPTION
    Installs nothing: it uses an installed PSScriptAnalyzer module, or else the copy that comes with VS Code's
    PowerShell extension (ms-vscode.powershell). Either is loaded only if all its files are validly signed by
    Microsoft. Prints the findings; exit code 0 means none.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Invoke-Lint.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = Split-Path $PSScriptRoot -Parent

function Find-ScriptAnalyzer {
    # PSScriptAnalyzer.psd1 of an installed module, else of the newest copy in VS Code's PowerShell extension.
    $installed = Get-Module -ListAvailable PSScriptAnalyzer | Sort-Object Version -Descending | Select-Object -First 1
    if ($null -ne $installed) { return $installed.Path }

    $extensions = Join-Path $env:USERPROFILE '.vscode\extensions'
    if (-not (Test-Path -LiteralPath $extensions)) { return $null }
    $powershellExtensions = Get-ChildItem -LiteralPath $extensions -Directory -Filter 'ms-vscode.powershell-*'
    $manifests = foreach ($extension in $powershellExtensions) {
        $modules = Join-Path $extension.FullName 'modules\PSScriptAnalyzer'
        if (Test-Path -LiteralPath $modules) {
            Get-ChildItem -LiteralPath $modules -Recurse -Filter 'PSScriptAnalyzer.psd1'
        }
    }
    # Import-PowerShellDataFile only reads the manifest, it runs nothing.
    $manifests | Sort-Object { [version](Import-PowerShellDataFile $_.FullName).ModuleVersion } -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

function Assert-MicrosoftSigned {
    # Throws unless every code and manifest file of the module is validly signed by Microsoft.
    param([string]$Manifest)

    $folder = Split-Path $Manifest -Parent
    foreach ($file in Get-ChildItem -Path $folder -Recurse -File -Include *.dll, *.psd1, *.psm1, *.ps1, *.ps1xml) {
        $signature = Get-AuthenticodeSignature -FilePath $file.FullName
        $byMicrosoft = $null -ne $signature.SignerCertificate -and
            $signature.SignerCertificate.Subject -match '(^|, )O=Microsoft Corporation(,|$)'
        if ($signature.Status -ne 'Valid' -or -not $byMicrosoft) {
            throw "Not loaded: $($file.FullName) is not validly signed by Microsoft ($($signature.Status))."
        }
    }
}

$manifest = Find-ScriptAnalyzer
if (-not $manifest) {
    throw ("PSScriptAnalyzer was not found. It comes with VS Code's PowerShell extension (ms-vscode.powershell); " +
        'nothing is installed by this script.')
}
Assert-MicrosoftSigned $manifest
Import-Module $manifest
$version = (Get-Module PSScriptAnalyzer).Version

$settings = Join-Path $repository 'PSScriptAnalyzerSettings.psd1'
$findings = @(Invoke-ScriptAnalyzer -Path $repository -Recurse -Settings $settings)
foreach ($finding in $findings | Sort-Object ScriptName, Line) {
    Write-Host ("{0}:{1}  {2}  {3}" -f $finding.ScriptName, $finding.Line, $finding.RuleName, $finding.Message)
}
Write-Host "PSScriptAnalyzer $version ($manifest): $($findings.Count) findings"
if ($findings.Count -gt 0) { exit 1 }
