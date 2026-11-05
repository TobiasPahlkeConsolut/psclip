<#
.SYNOPSIS
    Adds the clipboard manager to the Start menu and optionally to autostart - or removes it.

.DESCRIPTION
    Creates a "Clipboard Manager" shortcut in the Start menu and, with -Autostart, a second one
    in the Startup folder, then starts the manager. The shortcuts run ClipboardManager.ps1 from
    this folder through 'conhost.exe --headless', so no console window appears. (With Windows
    Terminal as the default terminal, 'powershell -WindowStyle Hidden' would leave an empty
    terminal window open.)

    Nothing is copied: keep this folder where it is, or run Install.ps1 again after moving it.
    Running it again replaces the shortcuts, so it is also the way to change the settings. If
    psclip is already running, you are asked before it is restarted (its history would be lost).

.PARAMETER Autostart
    Also start the manager when you sign in to Windows. Without it, an existing autostart
    shortcut is removed.

.PARAMETER Hotkey
    Passed on to ClipboardManager.ps1, e.g. 'Ctrl+Alt+V'. Checked before anything is changed.

.PARAMETER MaxMemory
    Passed on to ClipboardManager.ps1: memory the history may use, 100MB (default), 500MB or 1GB.

.PARAMETER Theme
    Passed on to ClipboardManager.ps1: Dark (default), Light or Auto.

.PARAMETER Size
    Passed on to ClipboardManager.ps1: popup size S, M (default) or L.

.PARAMETER OpenAt
    Passed on to ClipboardManager.ps1: where the hotkey opens the popup, Mouse (default) or TextCursor.

.PARAMETER Preview
    Passed on to ClipboardManager.ps1: open the popup with the preview (F3) shown.

.PARAMETER KeepAwake
    Passed on to ClipboardManager.ps1: start with "Keep awake" switched on.

.PARAMETER KeepAwakeSeconds
    Passed on to ClipboardManager.ps1: idle seconds before "Keep awake" presses F15 (default 30).

.PARAMETER KeepPinned
    Passed on to ClipboardManager.ps1: start with "Keep pinned entries" switched on - pinned entries
    are saved encrypted to pinned.dat in this folder and survive restarts.

.PARAMETER Force
    Restart a running psclip without asking.

.PARAMETER Uninstall
    Stops a running instance and removes both shortcuts.

.EXAMPLE
    .\Install.ps1 -Autostart

.EXAMPLE
    .\Install.ps1 -Autostart -Hotkey 'Ctrl+Alt+V' -Theme Light -Size L -KeepAwake

.EXAMPLE
    .\Install.ps1 -Uninstall

.NOTES
    Run it without administrator rights. If the execution policy does not allow local scripts:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Autostart
    The shortcuts start the manager with -ExecutionPolicy Bypass (for that process only).
#>

#Requires -PSEdition Desktop

[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')]
    [switch]$Autostart,

    [Parameter(ParameterSetName = 'Install')]
    [string]$Hotkey,

    [Parameter(ParameterSetName = 'Install')]
    [ValidateSet('100MB', '500MB', '1GB')]
    [string]$MaxMemory,

    [Parameter(ParameterSetName = 'Install')]
    [ValidateSet('Dark', 'Light', 'Auto')]
    [string]$Theme,

    [Parameter(ParameterSetName = 'Install')]
    [ValidateSet('S', 'M', 'L')]
    [string]$Size,

    [Parameter(ParameterSetName = 'Install')]
    [ValidateSet('Mouse', 'TextCursor')]
    [string]$OpenAt,

    [Parameter(ParameterSetName = 'Install')]
    [switch]$Preview,

    [Parameter(ParameterSetName = 'Install')]
    [switch]$KeepAwake,

    [Parameter(ParameterSetName = 'Install')]
    [ValidateRange(1, 3600)]
    [int]$KeepAwakeSeconds,

    [Parameter(ParameterSetName = 'Install')]
    [switch]$KeepPinned,

    [Parameter(ParameterSetName = 'Install')]
    [switch]$Force,

    [Parameter(ParameterSetName = 'Uninstall', Mandatory)]
    [switch]$Uninstall
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$managerScript = Join-Path $PSScriptRoot 'ClipboardManager.ps1'
# Not $PSHOME: under PowerShell 7 that folder has no powershell.exe.
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$shortcutName = 'Clipboard Manager.lnk'
$startMenuShortcut = Join-Path ([Environment]::GetFolderPath('Programs')) $shortcutName
$autostartShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) $shortcutName
$hostWindowTitle = 'PsClipboardManager'   # hidden window of a running instance (its InstanceName)

if (-not ('InstallNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class InstallNative
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string className, string title);

    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

    public static int ProcessOf(IntPtr hwnd)
    {
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        return (int)pid;
    }
}
'@
}

#region Functions

function ConvertTo-CommandLineArgument {
    # Quotes an argument so that powershell.exe (CommandLineToArgvW rules) reads it back unchanged.
    param([string]$Value)

    if ($Value -and $Value -notmatch '[\s"]') { return $Value }   # backslashes are literal here
    # Inside quotes, backslashes are literal unless they come before a quote: double those.
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Get-ShortcutArguments {
    # Command line of the shortcuts: conhost --headless powershell.exe ... -File ClipboardManager.ps1 <settings>
    # $PSBoundParameters (a Dictionary) or a hashtable. ContainsKey, not Contains: the Dictionary
    # implements IDictionary.Contains only explicitly, so PowerShell cannot call it.
    param([System.Collections.IDictionary]$Settings)

    $arguments = @('--headless', $powershellExe, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $managerScript)
    foreach ($name in 'Hotkey', 'MaxMemory', 'Theme', 'Size', 'OpenAt', 'KeepAwakeSeconds') {
        if ($Settings.ContainsKey($name)) { $arguments += "-$name", [string]$Settings[$name] }
    }
    foreach ($name in 'Preview', 'KeepAwake', 'KeepPinned') {
        if ($Settings.ContainsKey($name) -and [bool]$Settings[$name]) { $arguments += "-$name" }
    }

    ($arguments | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' '
}

function Assert-Hotkey {
    # Checks the hotkey with the manager's own rules. Dot-sourcing inside this function keeps the
    # manager's variables (its parameters, ...) out of this script.
    param([string]$Text)

    . $managerScript
    $null = ConvertFrom-HotkeyText $Text
}

function Test-Elevated {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ManagerProcessId {
    # Process id of the running instance, or 0.
    $window = [InstallNative]::FindWindow([NullString]::Value, $hostWindowTitle)
    if ($window -eq [IntPtr]::Zero) { return 0 }
    [InstallNative]::ProcessOf($window)
}

function Stop-ClipboardManager {
    # Asks the running instance to exit; returns $true once none is running.
    $window = [InstallNative]::FindWindow([NullString]::Value, $hostWindowTitle)
    if ($window -eq [IntPtr]::Zero) { return $true }

    $processId = [InstallNative]::ProcessOf($window)
    [void][InstallNative]::PostMessage($window, 0x0010 <# WM_CLOSE #>, [IntPtr]::Zero, [IntPtr]::Zero)
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $true }
    return $process.WaitForExit(5000)
}

function Wait-ClipboardManager {
    # Returns $true once an instance other than ExcludeProcessId runs (max. 15 s).
    param([int]$ExcludeProcessId = 0)

    for ($i = 0; $i -lt 60; $i++) {
        $processId = Get-ManagerProcessId
        if ($processId -ne 0 -and $processId -ne $ExcludeProcessId) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function New-Shortcut {
    param([string]$Path, [string]$Arguments)

    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($Path)
        $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\conhost.exe'
        $shortcut.Arguments = $Arguments
        $shortcut.WorkingDirectory = $PSScriptRoot
        $shortcut.IconLocation = "$powershellExe,0"
        $shortcut.Description = 'Clipboard history'
        $shortcut.Save()
    }
    finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

function Get-UnloadedPinnedWarning {
    # Saved pinned entries that psclip started by the new shortcuts would not load (no -KeepPinned).
    param([string]$Folder, [bool]$KeepPinned)

    $file = Join-Path $Folder 'pinned.dat'
    if ($KeepPinned -or -not (Test-Path -LiteralPath $file)) { return }
    'pinned.dat holds saved pinned entries, but without -KeepPinned psclip does not load them at start ' +
        "(only when 'Keep pinned entries' is switched on in its tray menu). Add -KeepPinned to keep them."
}

function Confirm-Restart {
    param([string]$Question)

    try {
        return $PSCmdlet.ShouldContinue($Question, 'Restart psclip')
    }
    catch {
        return $false   # non-interactive: do not restart
    }
}

#endregion

# Dot-sourced (unit tests): only load the functions.
if ($MyInvocation.InvocationName -eq '.') { return }

if ($Uninstall) {
    if (-not (Stop-ClipboardManager)) {
        Write-Warning 'The running psclip did not exit. Exit it via its tray icon.'
    }
    foreach ($path in $startMenuShortcut, $autostartShortcut) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path
            Write-Host "Removed $path"
        }
    }
    $pinnedFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'pinned*.dat*' -File)
    if ($pinnedFiles.Count -gt 0) {
        Write-Host ('Pinned entries saved by "Keep pinned entries" are still in this folder (' +
            (($pinnedFiles | ForEach-Object { $_.Name }) -join ', ') + '); they go with it when you delete it.')
    }
    return
}

if (Test-Elevated) {
    throw ('Run Install.ps1 without administrator rights: psclip would start elevated, and with a ' +
        'separate admin account the shortcuts would end up in that account.')
}
if (-not (Test-Path -LiteralPath $managerScript)) {
    throw "ClipboardManager.ps1 was not found next to Install.ps1 ($managerScript)."
}
$partsFolder = Join-Path $PSScriptRoot 'src'
if (-not (Test-Path -LiteralPath $partsFolder)) {
    throw "The src folder was not found next to Install.ps1 ($partsFolder)."
}
# Downloaded as ZIP, the files are marked as coming from the internet.
Unblock-File -LiteralPath (@($managerScript) + @(Get-ChildItem -LiteralPath $partsFolder -File).FullName)
if ($PSBoundParameters.ContainsKey('Hotkey')) { Assert-Hotkey $Hotkey }

$shortcutArguments = Get-ShortcutArguments $PSBoundParameters
New-Shortcut -Path $startMenuShortcut -Arguments $shortcutArguments
Write-Host "Start menu shortcut: $startMenuShortcut"

if ($Autostart) {
    New-Shortcut -Path $autostartShortcut -Arguments $shortcutArguments
    Write-Host "Autostart shortcut:  $autostartShortcut"
}
elseif (Test-Path -LiteralPath $autostartShortcut) {
    Remove-Item -LiteralPath $autostartShortcut
    Write-Host 'Removed the autostart shortcut (use -Autostart to keep it).'
}

$pinnedWarning = Get-UnloadedPinnedWarning $PSScriptRoot $KeepPinned.IsPresent
if ($pinnedWarning) { Write-Warning $pinnedWarning }

$runningId = Get-ManagerProcessId
if ($runningId -ne 0) {
    $question = 'psclip is running. Restart it now so that the new settings apply? Its history will be ' +
        "lost - and its pinned entries too, unless 'Keep pinned entries' is on in its tray menu."
    if (-not ($Force -or (Confirm-Restart $question))) {
        Write-Host 'psclip keeps running with its current settings; the new ones apply the next time it starts.'
        return
    }
    if (-not (Stop-ClipboardManager)) {
        Write-Warning ('The running psclip did not exit. Exit it via its tray icon, then start ' +
            '"Clipboard Manager" from the Start menu.')
        return
    }
}

Start-Process -FilePath $startMenuShortcut
if (Wait-ClipboardManager -ExcludeProcessId $runningId) {
    Write-Host 'psclip is running - look for its icon in the notification area of the taskbar.'
}
else {
    Write-Warning ("psclip did not start. Run it in a console to see the error:`n" +
        "  & `"$powershellExe`" -NoProfile -ExecutionPolicy Bypass -File `"$managerScript`"")
}
