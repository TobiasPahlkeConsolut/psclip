<#
.SYNOPSIS
    Adds the clipboard manager to the Start menu and optionally to autostart - or removes it.

.DESCRIPTION
    Creates a "Clipboard Manager" shortcut in the Start menu and, with -Autostart, a second one
    in the Startup folder, then starts the manager. The shortcuts run ClipboardManager.ps1 from
    this folder through 'conhost.exe --headless', so no console window appears. (With Windows
    Terminal as the default terminal, 'powershell -WindowStyle Hidden' would leave an empty
    terminal window open.)

    The settings go to settings.ini in this folder, where psclip reads them and saves the changes
    made in its tray menu - edit it with any text editor. A new settings.ini gets the installer's
    defaults, which differ from those of ClipboardManager.ps1 in three settings: a memory limit of
    500MB, the popup at the text cursor, and "Keep pinned entries" on. When updating from a version
    whose shortcuts passed the settings themselves, those settings move into the new settings.ini.
    An existing settings.ini keeps its settings; only the settings given here change in it.

    Nothing is copied: keep this folder where it is, or run Install.ps1 again after moving it.
    If psclip is already running, you are asked before it is restarted (its history would be lost).

.PARAMETER Autostart
    Also start the manager when you sign in to Windows. Without it, an existing autostart
    shortcut is removed.

.PARAMETER Hotkey
    Written to settings.ini, e.g. 'Ctrl+Alt+V'. Checked before anything is changed.

.PARAMETER MaxMemory
    Written to settings.ini: memory the history may use, 100MB, 500MB (default here) or 1GB.

.PARAMETER Theme
    Written to settings.ini: Dark (default), Light or Auto.

.PARAMETER Size
    Written to settings.ini: popup size S, M (default) or L.

.PARAMETER OpenAt
    Written to settings.ini: where the hotkey opens the popup, Mouse or TextCursor (default here).

.PARAMETER Preview
    Written to settings.ini: open the popup with the preview (F3) shown.

.PARAMETER KeepAwake
    Written to settings.ini: "Keep awake" switched on.

.PARAMETER KeepAwakeSeconds
    Written to settings.ini: idle seconds before "Keep awake" presses F15 (default 30).

.PARAMETER KeepPinned
    Written to settings.ini: "Keep pinned entries" switched on - pinned entries are saved encrypted
    to pinned.dat in this folder and survive restarts. On by default here; -KeepPinned:$false
    switches it off.

.PARAMETER Force
    Restart a running psclip without asking.

.PARAMETER Uninstall
    Stops a running instance and removes both shortcuts (settings.ini and pinned.dat stay in this folder).

.EXAMPLE
    .\Install.ps1 -Autostart

.EXAMPLE
    .\Install.ps1 -Autostart -Hotkey 'Ctrl+Alt+V' -Theme Light -Size L -KeepAwake

.EXAMPLE
    .\Install.ps1 -MaxMemory 100MB -OpenAt Mouse -KeepPinned:$false

    ClipboardManager.ps1's own defaults instead of the installer's: no pinned entries are saved.

.EXAMPLE
    .\Install.ps1 -Uninstall

.NOTES
    Run it without administrator rights, best with the execution policy bypassed for this one call - it
    then works with any execution policy and for downloaded files (it unblocks psclip's files):
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Autostart
    The shortcuts start the manager the same way, with -ExecutionPolicy Bypass for that process only.
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
$settingsFile = Join-Path $PSScriptRoot 'settings.ini'   # psclip's (Get-SettingsFilePath)

# Where the installer's defaults differ from ClipboardManager.ps1's (which stays minimal when run by itself)
$InstallDefaults = @{ MaxMemory = '500MB'; OpenAt = 'TextCursor'; KeepPinned = $true }

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

    [DllImport("shell32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CommandLineToArgvW(string commandLine, out int count);

    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr memory);

    // Splits a command line exactly like the started program receives its arguments.
    public static string[] SplitArguments(string commandLine)
    {
        int count;
        IntPtr argv = CommandLineToArgvW(commandLine, out count);
        if (argv == IntPtr.Zero) return new string[0];
        try
        {
            string[] result = new string[count];
            for (int i = 0; i < count; i++)
                result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size));
            return result;
        }
        finally
        {
            LocalFree(argv);
        }
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
    # Command line of the shortcuts: conhost --headless powershell.exe ... -File ClipboardManager.ps1 - no settings:
    # psclip reads them from settings.ini (given on the command line, they would win over its tray menu).
    $arguments = @('--headless', $powershellExe, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $managerScript)
    ($arguments | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' '
}

function Get-GivenSettings {
    # The settings given to Install.ps1 ($PSBoundParameters): its parameters except its own and the common ones.
    param([System.Collections.IDictionary]$Bound)

    $given = @{}
    foreach ($name in $Bound.Keys) {
        $own = @('Autostart', 'Force', 'Uninstall') -contains $name
        if ($own -or [System.Management.Automation.PSCmdlet]::CommonParameters.Contains($name)) { continue }
        $given[$name] = $Bound[$name]
    }
    $given
}

function Get-InstallSettings {
    # The settings of a new settings.ini: psclip's defaults; over them the installer's ($InstallDefaults) - or, when
    # an older shortcut passed settings, those instead (the user's choice, also a switch it left out); over all
    # that, the given ones (also -KeepPinned:$false).
    param(
        [System.Collections.IDictionary]$Defaults,
        [System.Collections.IDictionary]$Shortcut,
        [System.Collections.IDictionary]$Given
    )

    $base = if ($null -ne $Shortcut) { $Shortcut } else { $InstallDefaults }
    $settings = @{}
    foreach ($source in $Defaults, $base, $Given) {
        foreach ($name in $source.Keys) { $settings[$name] = $source[$name] }
    }
    $settings
}

function Read-ShortcutArguments {
    # The arguments of an existing shortcut, or $null.
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $shell = New-Object -ComObject WScript.Shell
    try {
        $shell.CreateShortcut($Path).Arguments
    }
    finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

function ConvertFrom-ShortcutArguments {
    # The settings a shortcut of an older Install.ps1 passes after "-File ClipboardManager.ps1" (a switch: $true),
    # or $null when it passes none.
    param([string]$Arguments, [string[]]$Names, [string[]]$Switches)

    if (-not $Arguments) { return $null }
    $tokens = [InstallNative]::SplitArguments("conhost.exe $Arguments")
    $file = [array]::IndexOf($tokens, '-File')
    if ($file -lt 0) { return $null }
    $settings = @{}
    for ($i = $file + 2; $i -lt $tokens.Count; $i++) {
        if (-not $tokens[$i].StartsWith('-')) { continue }
        $name = @($Names) -eq $tokens[$i].Substring(1)   # -eq ignores case
        if ($name.Count -eq 0) { continue }   # e.g. -MaxItems of even older versions
        if (@($Switches) -contains $name[0]) {
            $settings[$name[0]] = $true
        }
        elseif ($i + 1 -lt $tokens.Count) {
            $i++
            $settings[$name[0]] = $tokens[$i]
        }
    }
    if ($settings.Count -eq 0) { return $null }
    $settings
}

function Write-InstallSettings {
    # settings.ini for psclip started by the shortcuts; returns the settings now in it. A new file gets every
    # setting (Get-InstallSettings). An existing one keeps the user's settings - from the tray menu or an editor -
    # and its comments; only the given settings change.
    param([string]$Path, [System.Collections.IDictionary]$Given, [string]$ShortcutArguments)

    . $managerScript   # its settings functions; inside this function, its variables stay out of Install.ps1
    $values = @{}
    foreach ($name in $Given.Keys) {
        $values[$name] = ConvertFrom-SettingText $name (ConvertTo-SettingText $Given[$name])
    }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $lines = @(Read-SettingsLines $Path)
        foreach ($name in $values.Keys) {
            $lines = @(Set-SettingLine $lines $name (ConvertTo-SettingText $values[$name]))
        }
        if ($values.Count -gt 0) { Write-SettingsLines $Path $lines }
    }
    else {
        $switches = @($SettingDefinitions.Keys | Where-Object { $SettingDefinitions[$_].Type -eq 'Switch' })
        $shortcut = ConvertFrom-ShortcutArguments -Arguments $ShortcutArguments -Names @($SettingDefinitions.Keys) `
            -Switches $switches
        $defaults = Get-ParameterSettings   # ClipboardManager.ps1's defaults, from the dot-sourcing above
        $settings = Get-InstallSettings -Defaults $defaults -Shortcut $shortcut -Given $values
        foreach ($name in @($settings.Keys)) {
            try {
                $settings[$name] = ConvertFrom-SettingText $name (ConvertTo-SettingText $settings[$name])
            }
            catch {
                # Only a value from the old shortcut can be invalid - and psclip did not start with it either.
                Write-Warning "Not taken over from the old shortcut: $($_.Exception.Message)"
                $settings[$name] = ConvertFrom-SettingText $name (ConvertTo-SettingText $defaults[$name])
            }
        }
        Write-SettingsLines $Path (New-SettingsLines $settings)
    }
    (Read-SettingsFile $Path).Values
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
    # Saved pinned entries that psclip would not load at its start (KeepPinned = false in settings.ini).
    param([string]$Folder, [bool]$KeepPinned)

    $file = Join-Path $Folder 'pinned.dat'
    if ($KeepPinned -or -not (Test-Path -LiteralPath $file)) { return }
    'pinned.dat holds saved pinned entries, but with KeepPinned = false (settings.ini) psclip does not load them ' +
        "at start - only when 'Keep pinned entries' is switched on in its tray menu. -KeepPinned switches it on."
}

function Confirm-Restart {
    # $true to restart a running psclip: -Force, or the user's answer.
    param([string]$Question, [switch]$Force)

    if ($Force) { return $true }
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
    $ownFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -File |
        Where-Object { $_.Name -like 'pinned*.dat*' -or $_.Name -like 'settings*.ini' })
    if ($ownFiles.Count -gt 0) {
        Write-Host ("psclip's settings and saved pinned entries are still in this folder (" +
            (($ownFiles | ForEach-Object { $_.Name }) -join ', ') + '); they go with it when you delete it.')
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

# Before the shortcuts are replaced: settings that an older version's shortcut passed move into a new settings.ini.
$oldArguments = Read-ShortcutArguments $startMenuShortcut
if ($null -eq $oldArguments) { $oldArguments = Read-ShortcutArguments $autostartShortcut }
$settings = Write-InstallSettings -Path $settingsFile -Given (Get-GivenSettings $PSBoundParameters) `
    -ShortcutArguments $oldArguments
Write-Host "Settings: $settingsFile (psclip's tray menu changes them too)"

$shortcutArguments = Get-ShortcutArguments
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

$pinnedWarning = Get-UnloadedPinnedWarning $PSScriptRoot ([bool]$settings['KeepPinned'])
if ($pinnedWarning) { Write-Warning $pinnedWarning }

$runningId = Get-ManagerProcessId
if ($runningId -ne 0) {
    $question = 'psclip is running. Restart it now so that this version and its settings apply? Its history ' +
        "will be lost - and its pinned entries too, unless 'Keep pinned entries' is on in its tray menu."
    if (-not (Confirm-Restart -Question $question -Force:$Force)) {
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
