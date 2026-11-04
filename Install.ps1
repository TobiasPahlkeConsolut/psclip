<#
.SYNOPSIS
    Adds the clipboard manager to the Start menu and optionally to autostart - or removes it.

.DESCRIPTION
    Creates a "Clipboard Manager" shortcut in the Start menu and, with -Autostart, a second one
    in the Startup folder, then (re)starts the manager. The shortcuts run ClipboardManager.ps1
    from this folder through 'conhost.exe --headless', so no console window appears. (With
    Windows Terminal as the default terminal, 'powershell -WindowStyle Hidden' would leave an
    empty terminal window open.)

    Nothing is copied: keep this folder where it is, or run Install.ps1 again after moving it.
    Running it again replaces the shortcuts, so it is also the way to change the settings.

.PARAMETER Autostart
    Also start the manager when you sign in to Windows. Without it, an existing autostart
    shortcut is removed.

.PARAMETER Hotkey
    Passed on to ClipboardManager.ps1, e.g. 'Ctrl+Alt+V'.

.PARAMETER MaxItems
    Passed on to ClipboardManager.ps1.

.PARAMETER Theme
    Passed on to ClipboardManager.ps1: Dark (default), Light or Auto.

.PARAMETER Size
    Passed on to ClipboardManager.ps1: popup size S, M (default) or L.

.PARAMETER Uninstall
    Stops a running instance and removes both shortcuts.

.EXAMPLE
    .\Install.ps1 -Autostart

.EXAMPLE
    .\Install.ps1 -Autostart -Hotkey 'Ctrl+Alt+V' -Theme Light -Size L

.EXAMPLE
    .\Install.ps1 -Uninstall

.NOTES
    If the execution policy does not allow local scripts, run it as
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Autostart
    The shortcuts always start the manager with -ExecutionPolicy Bypass (for that process only).
#>

[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')]
    [switch]$Autostart,

    [Parameter(ParameterSetName = 'Install')]
    [string]$Hotkey,

    [Parameter(ParameterSetName = 'Install')]
    [ValidateRange(1, 100000)]
    [int]$MaxItems,

    [Parameter(ParameterSetName = 'Install')]
    [ValidateSet('Dark', 'Light', 'Auto')]
    [string]$Theme,

    [Parameter(ParameterSetName = 'Install')]
    [ValidateSet('S', 'M', 'L')]
    [string]$Size,

    [Parameter(ParameterSetName = 'Uninstall', Mandatory)]
    [switch]$Uninstall
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$managerScript = Join-Path $PSScriptRoot 'ClipboardManager.ps1'
$powershellExe = Join-Path $PSHOME 'powershell.exe'
$shortcutName = 'Clipboard Manager.lnk'
$startMenuShortcut = Join-Path ([Environment]::GetFolderPath('Programs')) $shortcutName
$autostartShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) $shortcutName
$hostWindowTitle = 'PsClipboardManager'   # hidden window of a running instance

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

function Get-ManagerWindow {
    [InstallNative]::FindWindow([NullString]::Value, $hostWindowTitle)
}

function Stop-ClipboardManager {
    # Asks a running instance to exit; returns $true if one was running.
    $window = Get-ManagerWindow
    if ($window -eq [IntPtr]::Zero) { return $false }

    $process = Get-Process -Id ([InstallNative]::ProcessOf($window))
    [void][InstallNative]::PostMessage($window, 0x0010 <# WM_CLOSE #>, [IntPtr]::Zero, [IntPtr]::Zero)
    if (-not $process.WaitForExit(5000)) {
        Write-Warning 'The running clipboard manager did not exit. Close it via its tray icon.'
    }
    return $true
}

function Wait-ClipboardManager {
    # Returns $true once a running instance is found (max. 15 s).
    for ($i = 0; $i -lt 60; $i++) {
        if ((Get-ManagerWindow) -ne [IntPtr]::Zero) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function New-Shortcut {
    param([string]$Path, [string]$Arguments)

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $shortcut.Arguments = $Arguments
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.IconLocation = "$powershellExe,0"
    $shortcut.Description = 'Clipboard history (in memory only)'
    $shortcut.Save()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
}

if ($Uninstall) {
    if (Stop-ClipboardManager) { Write-Host 'Stopped the running clipboard manager.' }
    foreach ($path in $startMenuShortcut, $autostartShortcut) {
        if (Test-Path $path) {
            Remove-Item $path
            Write-Host "Removed $path"
        }
    }
    return
}

if (-not (Test-Path $managerScript)) {
    throw "ClipboardManager.ps1 was not found next to Install.ps1 ($managerScript)."
}
Unblock-File $managerScript   # downloaded files are marked as coming from the internet

$managerArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$managerScript`"")
if ($PSBoundParameters.ContainsKey('Hotkey')) { $managerArguments += '-Hotkey', "`"$Hotkey`"" }
if ($PSBoundParameters.ContainsKey('MaxItems')) { $managerArguments += '-MaxItems', $MaxItems }
if ($PSBoundParameters.ContainsKey('Theme')) { $managerArguments += '-Theme', $Theme }
if ($PSBoundParameters.ContainsKey('Size')) { $managerArguments += '-Size', $Size }
$shortcutArguments = (@('--headless', "`"$powershellExe`"") + $managerArguments) -join ' '

New-Shortcut -Path $startMenuShortcut -Arguments $shortcutArguments
Write-Host "Start menu shortcut: $startMenuShortcut"

if ($Autostart) {
    New-Shortcut -Path $autostartShortcut -Arguments $shortcutArguments
    Write-Host "Autostart shortcut:  $autostartShortcut"
}
elseif (Test-Path $autostartShortcut) {
    Remove-Item $autostartShortcut
    Write-Host 'Removed the autostart shortcut (use -Autostart to keep it).'
}

if (Stop-ClipboardManager) { Write-Host 'Stopped the running instance to apply the new settings.' }
Start-Process -FilePath $startMenuShortcut

if (Wait-ClipboardManager) {
    Write-Host 'The clipboard manager is running - look for its icon in the notification area of the taskbar.'
}
else {
    Write-Warning ("The clipboard manager did not start. Run it in a console to see the error:`n" +
        "  & `"$powershellExe`" $($managerArguments -join ' ')")
}
