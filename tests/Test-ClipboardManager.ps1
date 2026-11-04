<#
.SYNOPSIS
    End-to-end test of ClipboardManager.ps1 on the real desktop.

.DESCRIPTION
    Starts the clipboard manager in a background process and drives it with window messages
    and real keystrokes: clipboard capture, de-duplication, private content, popup, filter,
    pinning, pasting into another window, popup size, the tray menu (window size, hotkey
    dialog, dark mode, keep awake) and graceful shutdown.

    The test briefly opens windows and sends key presses - do not type, click or move the mouse
    while it runs (about 45 seconds). Real keystrokes are only sent after checking that the expected window
    is in the foreground. The clipboard (text, image, file list) is saved before and restored afterwards.

    It starts its own instance (-InstanceName PsClipboardManagerTest, its own hotkey) and only ever
    talks to and closes that process, so a psclip you are using keeps running. That psclip does
    record what the test copies: entries starting with "psclip test:".

    Screenshots of the popup, the tray menu and the hotkey dialog are written to
    -OutputDirectory, together with the manager's log.

.PARAMETER Theme
    Theme the manager is started with (the screenshots show it; the test switches it once).

.PARAMETER OutputDirectory
    Where logs and screenshots go.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ClipboardManager.ps1 -Theme Light
#>

using namespace System.Windows.Forms

[CmdletBinding()]
param(
    [ValidateSet('Light', 'Dark')]
    [string]$Theme = 'Dark',

    [string]$OutputDirectory = (Join-Path $env:TEMP 'ClipboardManagerTests')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class TestNative
{
    public const int WM_SETTEXT = 0x000C;
    public const int WM_CLOSE = 0x0010;
    public const int WM_KEYDOWN = 0x0100;
    public const int WM_CHAR = 0x0102;
    public const int WM_RBUTTONUP = 0x0205;
    public const int WM_HOTKEY = 0x0312;
    public const int WM_TRAYMOUSEMESSAGE = 0x0800;   // WinForms NotifyIcon callback message
    const int WM_GETTEXT = 0x000D;
    const int LB_GETTEXT = 0x0189;
    const int LB_GETTEXTLEN = 0x018A;
    const int LB_GETCOUNT = 0x018B;

    delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    struct GuiThreadInfo
    {
        public int Size, Flags;
        public IntPtr Active, Focus, Capture, MenuOwner, MoveSize, Caret;
        public Rect CaretRect;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int processId);
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hwnd, int id);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint mapType);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr hwnd);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extraInfo);
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint threadId, ref GuiThreadInfo info);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hwnd, out Rect rect);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out Rect value, int size);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wParam, StringBuilder lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wParam, string lParam);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam);

    public static uint ProcessOf(IntPtr hwnd)
    {
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        return pid;
    }

    // Visible frame of the window, without the invisible resize borders (DWMWA_EXTENDED_FRAME_BOUNDS)
    public static Rect RectOf(IntPtr hwnd)
    {
        Rect rect;
        if (DwmGetWindowAttribute(hwnd, 9, out rect, Marshal.SizeOf(typeof(Rect))) != 0)
            GetWindowRect(hwnd, out rect);
        return rect;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct LastInputInfo { public uint Size, Time; }

    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LastInputInfo info);

    // Milliseconds since the last mouse or keyboard input in this session (synthetic input counts too)
    public static int IdleMilliseconds()
    {
        LastInputInfo info = new LastInputInfo();
        info.Size = (uint)Marshal.SizeOf(info);
        GetLastInputInfo(ref info);
        return (int)unchecked((uint)Environment.TickCount - info.Time);
    }

    public static int ClientHeightOf(IntPtr hwnd)
    {
        Rect rect;
        GetClientRect(hwnd, out rect);
        return rect.Bottom - rect.Top;
    }

    public static string TitleOf(IntPtr hwnd)
    {
        StringBuilder text = new StringBuilder(256);
        GetWindowText(hwnd, text, text.Capacity);
        return text.ToString();
    }

    public static IntPtr FocusOf(IntPtr hwnd)
    {
        uint pid;
        GuiThreadInfo info = new GuiThreadInfo();
        info.Size = Marshal.SizeOf(info);
        GetGUIThreadInfo(GetWindowThreadProcessId(hwnd, out pid), ref info);
        return info.Focus;
    }

    public static List<IntPtr> TopLevelWindowsOf(int processId)
    {
        List<IntPtr> windows = new List<IntPtr>();
        EnumWindows(delegate (IntPtr hwnd, IntPtr unused)
        {
            if (ProcessOf(hwnd) == processId) windows.Add(hwnd);
            return true;
        }, IntPtr.Zero);
        return windows;
    }

    public static IntPtr ChildByClass(IntPtr parent, string classPart)
    {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(parent, delegate (IntPtr hwnd, IntPtr unused)
        {
            StringBuilder name = new StringBuilder(256);
            GetClassName(hwnd, name, name.Capacity);
            if (name.ToString().IndexOf(classPart, StringComparison.OrdinalIgnoreCase) < 0) return true;
            found = hwnd;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    public static string[] ListBoxItems(IntPtr listBox)
    {
        int count = (int)SendMessage(listBox, LB_GETCOUNT, IntPtr.Zero, IntPtr.Zero);
        string[] items = new string[Math.Max(count, 0)];
        for (int i = 0; i < items.Length; i++)
        {
            int length = (int)SendMessage(listBox, LB_GETTEXTLEN, new IntPtr(i), IntPtr.Zero);
            StringBuilder text = new StringBuilder(length + 1);
            SendMessage(listBox, LB_GETTEXT, new IntPtr(i), text);
            items[i] = text.ToString();
        }
        return items;
    }

    public static string TextOf(IntPtr hwnd)
    {
        StringBuilder text = new StringBuilder(1024);
        SendMessage(hwnd, WM_GETTEXT, new IntPtr(text.Capacity), text);
        return text.ToString();
    }

    public static void SetText(IntPtr hwnd, string text)
    {
        SendMessage(hwnd, WM_SETTEXT, IntPtr.Zero, text);
    }

    public static bool Activate(IntPtr hwnd)
    {
        uint unused;
        uint foregroundThread = GetWindowThreadProcessId(GetForegroundWindow(), out unused);
        uint thisThread = GetCurrentThreadId();
        bool attached = foregroundThread != thisThread && AttachThreadInput(thisThread, foregroundThread, true);
        BringWindowToTop(hwnd);
        SetForegroundWindow(hwnd);
        if (attached) AttachThreadInput(thisThread, foregroundThread, false);
        return GetForegroundWindow() == hwnd;
    }

    // Presses the keys in order and releases them in reverse order (real keyboard input).
    public static void PressKeys(params byte[] keys)
    {
        foreach (byte key in keys) keybd_event(key, 0, 0, UIntPtr.Zero);
        for (int i = keys.Length - 1; i >= 0; i--) keybd_event(keys[i], 0, 2, UIntPtr.Zero);
    }
}
'@

#region Helpers

$results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param([string]$Step, [bool]$Passed, [string]$Detail = '')

    $results.Add([pscustomobject]@{
        Result = if ($Passed) { 'PASS' } else { 'FAIL' }
        Step   = $Step
        Detail = $Detail
    })
}

function Wait-Until {
    # Polls the condition while keeping this process's windows responsive.
    param([scriptblock]$Condition, [int]$TimeoutMs = 3000)

    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMs) {
        [Application]::DoEvents()
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds 25
    }
    return [bool](& $Condition)
}

function Wait-Milliseconds {
    param([int]$Milliseconds)
    [void](Wait-Until { $false } $Milliseconds)
}

function Test-Foreground {
    param([IntPtr]$Window)
    [TestNative]::GetForegroundWindow() -eq $Window
}

function Test-HotkeyFree {
    param([uint32]$Modifiers, [uint32]$VirtualKey)

    if (-not [TestNative]::RegisterHotKey([IntPtr]::Zero, 99, $Modifiers, $VirtualKey)) { return $false }
    [void][TestNative]::UnregisterHotKey([IntPtr]::Zero, 99)
    return $true
}

function Save-WindowImage {
    param([IntPtr]$Window, [string]$Name)

    $rect = [TestNative]::RectOf($Window)
    $bitmap = [System.Drawing.Bitmap]::new($rect.Right - $rect.Left, $rect.Bottom - $rect.Top)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
    $graphics.Dispose()
    $bitmap.Save((Join-Path $OutputDirectory $Name))
    $bitmap.Dispose()
}

function Get-WindowBrightness {
    # Brightness (0-255) of a point in the lower right of the popup, inside the empty list area.
    param([IntPtr]$Window)

    $rect = [TestNative]::RectOf($Window)
    $bitmap = [System.Drawing.Bitmap]::new(1, 1)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($rect.Right - 40, $rect.Bottom - 80, 0, 0, [System.Drawing.Size]::new(1, 1))
    $graphics.Dispose()
    $brightness = [int]($bitmap.GetPixel(0, 0).GetBrightness() * 255)
    $bitmap.Dispose()
    $brightness
}

function Send-PostedKey {
    param([IntPtr]$Window, [int]$VirtualKey)
    [void][TestNative]::PostMessage($Window, [TestNative]::WM_KEYDOWN, [IntPtr]$VirtualKey, [IntPtr]::Zero)
}

function Show-TestPopup {
    # Opens the popup with the hotkey; returns $true once the popup is in the foreground.
    if ([TestNative]::IsWindowVisible($popup)) { Hide-TestPopup }   # the hotkey toggles the popup
    if (Test-Foreground $target.Handle) {
        # Press it for real while the test window is in front, like a user: Windows then lets
        # psclip take the foreground (a posted WM_HOTKEY does not).
        [TestNative]::PressKeys([byte[]]($script:currentHotkeyKeys))
    }
    else {
        [void][TestNative]::AllowSetForegroundWindow($manager.Id)
        [void][TestNative]::PostMessage($hostWindow, [TestNative]::WM_HOTKEY, [IntPtr]1, [IntPtr]::Zero)
    }
    Wait-Until { [TestNative]::IsWindowVisible($popup) -and (Test-Foreground $popup) }
}

function Hide-TestPopup {
    # Esc, with WM_CLOSE (which only hides the popup) as fallback so later steps start clean.
    Send-PostedKey $searchBox 0x1B
    if (Wait-Until { -not [TestNative]::IsWindowVisible($popup) } 1500) { return }
    Write-Warning 'Esc did not hide the popup - hiding it with WM_CLOSE.'
    [void][TestNative]::PostMessage($popup, [TestNative]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
    [void](Wait-Until { -not [TestNative]::IsWindowVisible($popup) })
}

function Open-TrayMenu {
    # Right-clicks the tray icon via its callback message; $true once the menu has the foreground.
    if (-not [TestNative]::Activate($target.Handle)) { return $false }
    [void][TestNative]::AllowSetForegroundWindow($manager.Id)
    foreach ($window in [TestNative]::TopLevelWindowsOf($manager.Id)) {
        if ([TestNative]::TitleOf($window) -eq '') {   # the NotifyIcon's hidden window has no title
            [void][TestNative]::PostMessage($window, [TestNative]::WM_TRAYMOUSEMESSAGE, [IntPtr]::Zero,
                [IntPtr][TestNative]::WM_RBUTTONUP)
        }
    }
    $open = Wait-Until { [TestNative]::ProcessOf([TestNative]::GetForegroundWindow()) -eq $manager.Id } 2000
    if ($open) { Wait-Milliseconds 300 }
    return $open
}

function Send-MenuKeys {
    # Real key presses for the tray menu - each one only while the manager owns the foreground.
    param([byte[]]$Keys)

    foreach ($key in $Keys) {
        if ([TestNative]::ProcessOf([TestNative]::GetForegroundWindow()) -ne $manager.Id) { return $false }
        [TestNative]::PressKeys($key)
        Wait-Milliseconds 100
    }
    return $true
}

function Measure-MaxIdle {
    # Longest time without input (as Windows counts it) during the given period, in ms.
    param([int]$Milliseconds)

    $longest = 0
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $Milliseconds) {
        [Application]::DoEvents()
        $longest = [Math]::Max($longest, [TestNative]::IdleMilliseconds())
        Start-Sleep -Milliseconds 100
    }
    $longest
}

function Save-MenuImages {
    param([string]$Name)

    $index = 0
    foreach ($window in [TestNative]::TopLevelWindowsOf($manager.Id)) {
        if ([TestNative]::IsWindowVisible($window) -and $window -ne $popup) {
            $index++
            Save-WindowImage $window "$Name-$index.png"
        }
    }
}

function Find-ManagerWindow {
    # Top-level window of the test instance with this title - never one of another psclip.
    param([string]$Title)

    foreach ($window in [TestNative]::TopLevelWindowsOf($manager.Id)) {
        if ([TestNative]::TitleOf($window) -eq $Title) { return $window }
    }
    [IntPtr]::Zero
}

function Save-Clipboard {
    # Text, image, file list and whether the content was marked private.
    $saved = @{ Text = $null; Image = $null; Files = $null; Private = $false }
    $data = [Clipboard]::GetDataObject()
    if ($null -eq $data) { return $saved }

    if ($data.GetDataPresent([DataFormats]::UnicodeText)) { $saved.Text = [string]$data.GetData([DataFormats]::UnicodeText) }
    if ($data.GetDataPresent([DataFormats]::Bitmap)) { $saved.Image = [Clipboard]::GetImage() }
    if ($data.GetDataPresent([DataFormats]::FileDrop)) { $saved.Files = [Clipboard]::GetFileDropList() }
    $saved.Private = $data.GetDataPresent('ExcludeClipboardContentFromMonitorProcessing') -or
        $data.GetDataPresent('CanIncludeInClipboardHistory')
    $saved
}

function Restore-Clipboard {
    param([hashtable]$Saved)

    $data = [DataObject]::new()
    $hasContent = $false
    if ($Saved.Text) {
        $data.SetText($Saved.Text)
        $hasContent = $true
    }
    if ($Saved.Image) {
        $data.SetImage($Saved.Image)
        $hasContent = $true
    }
    if ($Saved.Files -and $Saved.Files.Count -gt 0) {
        $data.SetFileDropList($Saved.Files)
        $hasContent = $true
    }
    if (-not $hasContent) {
        [Clipboard]::Clear()
        return
    }
    if ($Saved.Private) {
        # Keep it out of clipboard histories again (Win+V, cloud clipboard, psclip itself).
        foreach ($format in 'ExcludeClipboardContentFromMonitorProcessing', 'CanIncludeInClipboardHistory', 'CanUploadToCloudClipboard') {
            $data.SetData($format, $false, [System.IO.MemoryStream]::new([byte[]](0, 0, 0, 0)))
        }
    }
    [Clipboard]::SetDataObject($data, $true)
}

#endregion

$keyDown = 0x28
$keyUp = 0x26
$keyRight = 0x27
$keyEnter = 0x0D
$keepAwakeSeconds = 2   # short, so that the keep-awake step takes seconds instead of minutes

# The test instance: own name (mutex, hidden window) and own hotkey, so it runs next to a psclip in use.
$instanceName = 'PsClipboardManagerTest'
$testHotkey = @{ Text = 'Ctrl+Alt+Shift+F8'; Modifiers = 0x7; VirtualKey = 0x77 }
$currentHotkeyKeys = 0x11, 0x12, 0x10, 0x77   # Ctrl, Alt, Shift, F8 - changed by the hotkey dialog step

[void][TestNative]::SetProcessDPIAware()
$screen = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$scale = $screen.DpiX / 96.0
$screen.Dispose()

if ([TestNative]::FindWindow([NullString]::Value, $instanceName) -ne [IntPtr]::Zero) {
    throw "A test instance ($instanceName) is still running - close it first."
}
if (-not (Test-HotkeyFree $testHotkey.Modifiers $testHotkey.VirtualKey)) {
    throw "The test hotkey $($testHotkey.Text) is used by another program."
}

$managerScript = (Resolve-Path (Join-Path $PSScriptRoot '..\ClipboardManager.ps1')).Path
[void](New-Item -ItemType Directory -Force -Path $OutputDirectory)
$log = Join-Path $OutputDirectory 'manager.log'
$errorLog = Join-Path $OutputDirectory 'manager.err.log'
$savedClipboard = Save-Clipboard

Set-Clipboard -Value 'psclip test: initial entry'
$manager = Start-Process powershell.exe -NoNewWindow -PassThru `
    -RedirectStandardOutput $log -RedirectStandardError $errorLog `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$managerScript`"", '-Theme', $Theme,
    '-KeepAwakeSeconds', $keepAwakeSeconds, '-InstanceName', $instanceName, '-Hotkey', $testHotkey.Text, '-Verbose'

# The window the popup pastes into - a rich text box, to see whether formatting arrives
$target = [Form]::new()
$target.Text = 'Paste target (test)'
$target.TopMost = $true
$target.Size = [System.Drawing.Size]::new(400, 200)
$targetBox = [RichTextBox]::new()
$targetBox.Dock = 'Fill'
$target.Controls.Add($targetBox)

try {
    # --- start ---
    # Case-sensitive: "...already running." from an instance that exits must not count.
    $started = Wait-Until { (Test-Path $log) -and ((Get-Content $log -Raw) -cmatch 'Running \(PID') } 15000
    Add-Result 'Manager starts' $started
    if (-not $started) { throw "The manager did not start, see $log and $errorLog" }
    $hostWindow = Find-ManagerWindow $instanceName
    $popup = Find-ManagerWindow 'Clipboard history'
    Add-Result "Hotkey $($testHotkey.Text) registered" (-not (Test-HotkeyFree $testHotkey.Modifiers $testHotkey.VirtualKey))

    # --- clipboard capture ---
    foreach ($text in 'psclip test: alpha', "psclip test: beta line one`r`nline two", 'psclip test: gamma & <special> chars', 'psclip test: alpha') {
        Set-Clipboard -Value $text
        Wait-Milliseconds 300
    }
    $private = [DataObject]::new()
    $private.SetText('SECRET-PASSWORD')
    $private.SetData('ExcludeClipboardContentFromMonitorProcessing', $false, [System.IO.MemoryStream]::new([byte[]](0, 0, 0, 0)))
    [Clipboard]::SetDataObject($private, $true)
    Wait-Milliseconds 400

    $logText = Get-Content $log -Raw
    $count = ([regex]::Matches($logText, '(\d+) entries in history') | Select-Object -Last 1).Groups[1].Value
    Add-Result 'Entries recorded, re-copied entry not duplicated' ($count -eq '4') "history count $count, expected 4"
    Add-Result 'Content marked as private is ignored' ($logText -match 'marked as private')

    # --- popup ---
    $target.Show()
    Wait-Milliseconds 300
    if (-not [TestNative]::Activate($target.Handle)) { throw 'Could not bring the test window to the foreground.' }
    [void]$targetBox.Focus()

    $popupShown = Show-TestPopup
    Add-Result 'Hotkey opens the popup in the foreground' $popupShown
    if (-not $popupShown) { throw 'The popup did not come to the foreground.' }

    $listBox = [TestNative]::ChildByClass($popup, 'LISTBOX')
    # By class, not by asking for the focus: right after the popup appears, the focus may still
    # be on the list for a moment.
    $searchBox = [TestNative]::ChildByClass($popup, 'EDIT')
    $expected = "psclip test: alpha|psclip test: gamma & <special> chars|" +
        "psclip test: beta line one $([char]0x21B5) line two|psclip test: initial entry"
    $items = [TestNative]::ListBoxItems($listBox) -join '|'
    Add-Result 'Popup lists entries newest first' ($items -eq $expected) $items
    Save-WindowImage $popup "popup-$Theme.png"

    # --- filter ---
    foreach ($char in 'gam'.ToCharArray()) {
        [void][TestNative]::PostMessage($searchBox, [TestNative]::WM_CHAR, [IntPtr][int]$char, [IntPtr]::Zero)
    }
    Wait-Milliseconds 300
    $items = @([TestNative]::ListBoxItems($listBox))
    Add-Result 'Filter text narrows the list' ($items.Count -eq 1 -and $items[0] -like '*gamma*') ($items -join '|')
    [TestNative]::SetText($searchBox, '')
    Wait-Milliseconds 200

    # --- pin (real Ctrl+P) ---
    Send-PostedKey $searchBox $keyDown
    Send-PostedKey $searchBox $keyDown   # -> 'beta'
    Wait-Milliseconds 200
    if (Test-Foreground $popup) {
        [TestNative]::PressKeys(0x11, 0x50)   # Ctrl+P
        Wait-Milliseconds 400
        $items = @([TestNative]::ListBoxItems($listBox))
        Add-Result 'Ctrl+P pins the entry to the top' ($items[0] -like '*beta*') ($items -join '|')
        Save-WindowImage $popup "popup-pinned-$Theme.png"
    }
    else {
        Add-Result 'Ctrl+P pins the entry to the top' $false 'not run: popup lost the foreground'
    }

    # --- paste into the previous window ---
    Send-PostedKey $searchBox $keyDown   # -> 'alpha' (below the pinned entry)
    Wait-Milliseconds 200
    Send-PostedKey $searchBox $keyEnter
    $pasted = Wait-Until { $targetBox.Text -eq 'psclip test: alpha' }
    Add-Result 'Enter pastes into the previously active window' $pasted "target text: '$($targetBox.Text)'"

    # --- formatting: Enter pastes with formatting, Shift+Enter as plain text ---
    $boldText = 'psclip test: bold'
    $formatted = [DataObject]::new()
    $formatted.SetText($boldText)
    $formatted.SetData([DataFormats]::Rtf, '{\rtf1\ansi{\b ' + $boldText + '}}')
    [Clipboard]::SetDataObject($formatted, $true)
    Wait-Milliseconds 400

    $pastes = @{}
    foreach ($mode in 'formatted', 'plain', 'formatted again') {
        $targetBox.Clear()
        if ([TestNative]::Activate($target.Handle) -and (Show-TestPopup)) {
            Send-PostedKey $searchBox $keyDown   # the entry below the pinned one
            Wait-Milliseconds 200
            if ($mode -ne 'plain') {
                Send-PostedKey $searchBox $keyEnter
            }
            elseif (Test-Foreground $popup) {
                [TestNative]::PressKeys(0x10, $keyEnter)   # real Shift+Enter: the popup reads the Shift state
            }
            [void](Wait-Until { $targetBox.Text -eq $boldText })
        }
        $pastes[$mode] = [pscustomobject]@{
            Text = $targetBox.Text
            Bold = $targetBox.Rtf -cmatch '\\b[ \\]'   # RTF bold control word
        }
    }
    Add-Result 'Enter pastes with formatting' ($pastes.formatted.Text -eq $boldText -and $pastes.formatted.Bold) `
        "text '$($pastes.formatted.Text)', bold: $($pastes.formatted.Bold)"
    Add-Result 'Shift+Enter pastes plain text' ($pastes.plain.Text -eq $boldText -and -not $pastes.plain.Bold) `
        "text '$($pastes.plain.Text)', bold: $($pastes.plain.Bold)"
    Add-Result 'A plain paste keeps the stored formatting' ($pastes.'formatted again'.Bold) `
        "bold: $($pastes.'formatted again'.Bold)"

    # --- popup size: medium by default, manual resizing is reset on the next opening ---
    $mediumHeight = [int](360 * $scale)
    $openedHeight = $resizedHeight = $reopenedHeight = -1
    if (Show-TestPopup) {
        $openedHeight = [TestNative]::ClientHeightOf($popup)
        $outer = [TestNative]::RectOf($popup)
        $noMoveNoZOrderNoActivate = 0x16
        [void][TestNative]::SetWindowPos($popup, [IntPtr]::Zero, 0, 0,
            $outer.Right - $outer.Left + 150, $outer.Bottom - $outer.Top + 150, $noMoveNoZOrderNoActivate)
        Wait-Milliseconds 200
        $resizedHeight = [TestNative]::ClientHeightOf($popup)
        Hide-TestPopup
        if (Show-TestPopup) {
            $reopenedHeight = [TestNative]::ClientHeightOf($popup)
            Hide-TestPopup
        }
    }
    Add-Result 'Popup opens at the medium size' ($openedHeight -eq $mediumHeight) "client height $openedHeight, expected $mediumHeight"
    Add-Result 'Manual resizing is reset on the next opening' ($resizedHeight -gt $openedHeight -and $reopenedHeight -eq $openedHeight) `
        "resized $resizedHeight, reopened $reopenedHeight"

    # --- tray menu: Window size > Large ---
    $largeHeight = [int](540 * $scale)
    $sizeChanged = $false
    if ((Open-TrayMenu) -and (Send-MenuKeys $keyDown, $keyDown, $keyDown, $keyDown, $keyDown, $keyRight)) {
        Wait-Milliseconds 300
        Save-MenuImages "tray-menu-$Theme"
        $sizeChanged = Send-MenuKeys $keyUp, $keyEnter   # Up wraps around to the last item, Large
    }
    $openedHeight = -1
    if ($sizeChanged -and (Show-TestPopup)) {
        $openedHeight = [TestNative]::ClientHeightOf($popup)
        Hide-TestPopup
    }
    Add-Result 'Tray menu: window size Large' ($openedHeight -eq $largeHeight) "client height $openedHeight, expected $largeHeight"

    # --- tray menu: Change hotkey dialog ---
    $dialog = [IntPtr]::Zero
    $dialogShown = $false
    if ((Open-TrayMenu) -and (Send-MenuKeys $keyDown, $keyDown, $keyDown, $keyEnter)) {
        $dialogShown = Wait-Until {
            $script:dialog = Find-ManagerWindow 'Change hotkey'
            $script:dialog -ne [IntPtr]::Zero -and (Test-Foreground $script:dialog)
        }
    }
    Add-Result 'Tray menu opens the hotkey dialog' $dialogShown
    if ($dialogShown) {
        Wait-Milliseconds 200
        Save-WindowImage $dialog "hotkey-dialog-$Theme.png"

        $current = [TestNative]::TextOf([TestNative]::FocusOf($dialog))
        Add-Result 'Dialog shows the current hotkey' ($current -eq $testHotkey.Text) $current

        if (Test-Foreground $dialog) {
            [TestNative]::PressKeys(0x11, 0x12, 0x10, 0x78)   # Ctrl+Alt+Shift+F9
            Wait-Milliseconds 300
        }
        $shown = [TestNative]::TextOf([TestNative]::FocusOf($dialog))
        Add-Result 'Dialog shows the pressed combination' ($shown -eq 'Ctrl+Alt+Shift+F9') $shown
        if (Test-Foreground $dialog) { [TestNative]::PressKeys($keyEnter) }   # OK
        [void](Wait-Until { -not [TestNative]::IsWindowVisible($dialog) })

        $newTaken = -not (Test-HotkeyFree 0x7 0x78)
        $oldFree = Test-HotkeyFree $testHotkey.Modifiers $testHotkey.VirtualKey
        if ($newTaken) { $script:currentHotkeyKeys = 0x11, 0x12, 0x10, 0x78 }   # Ctrl, Alt, Shift, F9
        Add-Result 'New hotkey registered, old one released' ($newTaken -and $oldFree) "new taken: $newTaken, old free: $oldFree"
    }

    # --- tray menu: Dark mode switches the theme ---
    $before = $after = -1
    if (Show-TestPopup) {
        $before = Get-WindowBrightness $popup
        Hide-TestPopup
    }
    if ((Open-TrayMenu) -and (Send-MenuKeys $keyDown, $keyDown, $keyDown, $keyDown, $keyEnter)) {
        Wait-Milliseconds 300
        if (Show-TestPopup) {
            $after = Get-WindowBrightness $popup
            Save-WindowImage $popup "popup-switched-from-$Theme.png"
            Hide-TestPopup
        }
    }
    $isDark = { param($brightness) $brightness -ge 0 -and $brightness -lt 100 }
    $isLight = { param($brightness) $brightness -gt 150 }
    $switched = if ($Theme -eq 'Dark') { (& $isDark $before) -and (& $isLight $after) } else { (& $isLight $before) -and (& $isDark $after) }
    Add-Result 'Tray menu: dark mode switches the theme' $switched "brightness before $before, after $after"

    # --- tray menu: Keep awake (presses F15 after $keepAwakeSeconds s without input) ---
    $keepAwakeItem = @($keyDown) * 6 + $keyEnter   # 6x Down -> Keep awake
    $idleOn = $idleOff = -1
    if ((Open-TrayMenu) -and (Send-MenuKeys $keepAwakeItem)) {
        $idleOn = Measure-MaxIdle 6000
        if ((Open-TrayMenu) -and (Send-MenuKeys $keepAwakeItem)) {
            $idleOff = Measure-MaxIdle 5500
        }
    }
    # On: the idle time never gets much beyond the limit (checked every second).
    # Off: it keeps growing for the whole measuring time.
    $limit = $keepAwakeSeconds * 1000
    Add-Result 'Tray menu: keep awake prevents idle time' ($idleOn -ge 0 -and $idleOn -lt $limit + 1800) `
        "longest idle $idleOn ms, limit $limit ms"
    Add-Result 'Keep awake can be switched off again' ($idleOff -gt $limit + 2500) "longest idle $idleOff ms"
}
finally {
    $target.Dispose()
    # Only the test instance's own window - never another psclip.
    $hostWindow = Find-ManagerWindow $instanceName
    if ($hostWindow -ne [IntPtr]::Zero) {
        [void][TestNative]::PostMessage($hostWindow, [TestNative]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
    }
    $exited = $manager.WaitForExit(5000)
    Add-Result 'Graceful shutdown via WM_CLOSE' $exited
    if (-not $exited) { Stop-Process -Id $manager.Id -Force }

    Restore-Clipboard $savedClipboard
    $results | Format-Table -AutoSize -Wrap | Out-String -Width 160 | Write-Host
    Write-Host "Logs and screenshots: $OutputDirectory"
}

if ($results | Where-Object Result -eq 'FAIL') { exit 1 }
