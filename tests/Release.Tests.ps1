<#
.SYNOPSIS
    Unit tests of the release: version consistency and tools\New-ReleaseZip.ps1 - only reads the repository.

.DESCRIPTION
    Run them with .\tests\Invoke-UnitTests.ps1 (Pester 3.4 syntax, works with Pester 4 too).
#>

$repository = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repository 'tools\New-ReleaseZip.ps1')

Describe 'Version' {
    $version = Get-PsClipVersion $repository

    It 'is set in ClipboardManager.ps1' {
        $version | Should Match '^\d+\.\d+\.\d+$'
    }

    It 'is the same in the help (.NOTES) and the newest released CHANGELOG.md section' {
        $help = [IO.File]::ReadAllText((Join-Path $repository 'ClipboardManager.ps1'))
        $help | Should Match "(?m)^    psclip $([regex]::Escape($version)) - "
        $changelog = [IO.File]::ReadAllLines((Join-Path $repository 'CHANGELOG.md'))
        # "## Unreleased" collects the changes for the next version
        $newest = @($changelog | Where-Object { $_ -like '## *' -and $_ -ne '## Unreleased' })[0]
        $newest | Should Match "^## $([regex]::Escape($version)) - \d{4}-\d{2}-\d{2}$"
    }
}

Describe 'New-ReleaseZip' {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zipPath = New-ReleaseZip -Root $repository -Destination $TestDrive
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    $names = @($archive.Entries | ForEach-Object { $_.FullName })
    $archive.Dispose()

    It 'is named after the version' {
        Split-Path -Leaf $zipPath | Should BeExactly "psclip-$(Get-PsClipVersion $repository).zip"
    }

    It 'holds the app, the installer and every part file in one psclip folder' {
        $names -contains 'psclip/ClipboardManager.ps1' | Should Be $true
        $names -contains 'psclip/Install.ps1' | Should Be $true
        $names -contains 'psclip/LICENSE' | Should Be $true
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repository 'src') -File) {
            "$($file.Name) $($names -contains "psclip/src/$($file.Name)")" | Should BeExactly "$($file.Name) True"
        }
        @($names | Where-Object { $_ -notlike 'psclip/*' }).Count | Should Be 0
    }

    It 'leaves out tests, developer files and personal data' {
        @($names | Where-Object { $_ -match '/tests/|/tools/|/dist/|AGENTS|CLAUDE|/pinned[^/]*\.dat|/\.git' }).Count |
            Should Be 0
    }

    It "uses '/' in entry names, as the ZIP format requires" {
        @($names | Where-Object { $_.Contains('\') }).Count | Should Be 0
    }
}
