<#
.SYNOPSIS
    Builds the release ZIP: dist\psclip-<version>.zip with the files a user needs.

.DESCRIPTION
    The version comes from ClipboardManager.ps1 ($PsClipVersion). The ZIP holds one folder, psclip, with
    ClipboardManager.ps1, Install.ps1, src\, docs\ (the README's pictures), README.md, CHANGELOG.md and LICENSE - not
    the tests and the files for developers. The folder name has no version: extracting a newer ZIP over the old
    folder updates psclip and keeps a saved pinned.dat.

    Entry names use '/', as the ZIP format requires (Compress-Archive in Windows PowerShell 5.1 writes '\').

.PARAMETER OutputDirectory
    Where the ZIP is written (default: dist in the repository, ignored by git).

.EXAMPLE
    .\tools\New-ReleaseZip.ps1
#>

[CmdletBinding()]
param(
    [string]$OutputDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = Split-Path $PSScriptRoot -Parent

function Get-PsClipVersion {
    # The version set in ClipboardManager.ps1 ($PsClipVersion = '1.2.3').
    param([string]$Root)

    $script = [IO.File]::ReadAllText((Join-Path $Root 'ClipboardManager.ps1'))
    $match = [regex]::Match($script, "(?m)^\`$PsClipVersion = '(\d+\.\d+\.\d+)'")
    if (-not $match.Success) { throw 'No $PsClipVersion found in ClipboardManager.ps1.' }
    $match.Groups[1].Value
}

function Get-ReleaseFiles {
    # The files for users, relative to the repository, with '\'.
    param([string]$Root)

    'ClipboardManager.ps1', 'Install.ps1', 'README.md', 'CHANGELOG.md', 'LICENSE'
    foreach ($folder in 'src', 'docs') {
        Get-ChildItem -LiteralPath (Join-Path $Root $folder) -File | Sort-Object Name |
            ForEach-Object { "$folder\$($_.Name)" }
    }
}

function New-ReleaseZip {
    # Writes the ZIP and returns its path.
    param([string]$Root, [string]$Destination)

    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $version = Get-PsClipVersion $Root
    [void](New-Item -ItemType Directory -Force -Path $Destination)
    $zipPath = Join-Path $Destination "psclip-$version.zip"
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath }

    $archive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ReleaseFiles $Root) {
            $source = Join-Path $Root $file
            if (-not (Test-Path -LiteralPath $source)) { throw "Missing release file: $file" }
            $entryName = 'psclip/' + ($file -replace '\\', '/')
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $source, $entryName,
                [System.IO.Compression.CompressionLevel]::Optimal)
        }
    }
    finally {
        $archive.Dispose()
    }
    $zipPath
}

# Dot-sourced (unit tests): only load the functions.
if ($MyInvocation.InvocationName -eq '.') { return }

if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repository 'dist' }
$zip = New-ReleaseZip -Root $repository -Destination $OutputDirectory
Write-Host "Release ZIP: $zip ($([int]((Get-Item -LiteralPath $zip).Length / 1KB)) KB)"
