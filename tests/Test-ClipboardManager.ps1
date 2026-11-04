<#
.SYNOPSIS
    End-to-end test of ClipboardManager.ps1 on the real desktop.

.DESCRIPTION
    Starts the clipboard manager in a background process and drives it with window messages
    and a few real keystrokes: clipboard capture, de-duplication, private content, popup,
    filter, pinning, pasting into another window, changing the hotkey via the tray menu and
    graceful shutdown.

    The test briefly opens windows and sends key presses - do not type or click while it runs
    (about 20 seconds). Real keystrokes are only sent after checking that the expected window
    is in the foreground. The clipboard text is saved before and restored afterwards.

    Screenshots of the popup, the tray menu and the hotkey dialog are written to
    -OutputDirectory, together with the manager's log.

.PARAMETER Theme
    Theme the manager is started with (the screenshots show it).

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
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr hwnd);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extraInfo);
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint threadId, ref GuiThreadInfo info);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
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

function Send-PostedKey {
    param([IntPtr]$Window, [int]$VirtualKey)
    [void][TestNative]::PostMessage($Window, [TestNative]::WM_KEYDOWN, [IntPtr]$VirtualKey, [IntPtr]::Zero)
}

#endregion

[void][TestNative]::SetProcessDPIAware()
$managerScript = (Resolve-Path (Join-Path $PSScriptRoot '..\ClipboardManager.ps1')).Path
[void](New-Item -ItemType Directory -Force -Path $OutputDirectory)
$log = Join-Path $OutputDirectory 'manager.log'
$errorLog = Join-Path $OutputDirectory 'manager.err.log'
$savedClipboard = Get-Clipboard -Raw

Set-Clipboard -Value 'initial entry'
$manager = Start-Process powershell.exe -NoNewWindow -PassThru `
    -RedirectStandardOutput $log -RedirectStandardError $errorLog `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$managerScript`"", '-Theme', $Theme, '-Verbose'

# The window the popup pastes into
$target = [Form]::new()
$target.Text = 'Paste target (test)'
$target.TopMost = $true
$target.Size = [System.Drawing.Size]::new(400, 200)
$targetBox = [TextBox]::new()
$targetBox.Multiline = $true
$targetBox.Dock = 'Fill'
$target.Controls.Add($targetBox)

try {
    # --- start ---
    $started = Wait-Until { (Test-Path $log) -and ((Get-Content $log -Raw) -match 'Running') } 15000
    Add-Result 'Manager starts' $started
    if (-not $started) { throw "The manager did not start, see $errorLog" }
    $hostWindow = [TestNative]::FindWindow([NullString]::Value, 'PsClipboardManager')
    Add-Result 'Hotkey Ctrl+Shift+V registered' (-not (Test-HotkeyFree 0x6 0x56))

    # --- clipboard capture ---
    foreach ($text in 'alpha test entry', "beta line one`r`nline two", 'gamma & <special> chars', 'alpha test entry') {
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

    [void][TestNative]::PostMessage($hostWindow, [TestNative]::WM_HOTKEY, [IntPtr]1, [IntPtr]::Zero)
    $popup = [TestNative]::FindWindow([NullString]::Value, 'Clipboard history')
    $popupShown = Wait-Until { Test-Foreground $popup }
    Add-Result 'Hotkey opens the popup in the foreground' $popupShown
    if (-not $popupShown) { throw 'The popup did not come to the foreground.' }

    $listBox = [TestNative]::ChildByClass($popup, 'LISTBOX')
    $searchBox = [TestNative]::FocusOf($popup)
    $expected = "alpha test entry|gamma & <special> chars|beta line one $([char]0x21B5) line two|initial entry"
    $items = [TestNative]::ListBoxItems($listBox) -join '|'
    Add-Result 'Popup lists entries newest first' ($items -eq $expected) $items
    Save-WindowImage $popup "popup-$Theme.png"

    # --- filter ---
    foreach ($char in 'gam'.ToCharArray()) {
        [void][TestNative]::PostMessage($searchBox, [TestNative]::WM_CHAR, [IntPtr][int]$char, [IntPtr]::Zero)
    }
    Wait-Milliseconds 300
    $items = @([TestNative]::ListBoxItems($listBox))
    Add-Result 'Filter text narrows the list' ($items.Count -eq 1 -and $items[0] -like 'gamma*') ($items -join '|')
    [TestNative]::SetText($searchBox, '')
    Wait-Milliseconds 200

    # --- pin (real Ctrl+P) ---
    Send-PostedKey $searchBox 0x28   # Down
    Send-PostedKey $searchBox 0x28   # Down -> 'beta'
    Wait-Milliseconds 200
    if (Test-Foreground $popup) {
        [TestNative]::PressKeys(0x11, 0x50)   # Ctrl+P
        Wait-Milliseconds 400
        $items = @([TestNative]::ListBoxItems($listBox))
        Add-Result 'Ctrl+P pins the entry to the top' ($items[0] -like 'beta*') ($items -join '|')
        Save-WindowImage $popup "popup-pinned-$Theme.png"
    }
    else {
        Add-Result 'Ctrl+P pins the entry to the top' $false 'not run: popup lost the foreground'
    }

    # --- paste into the previous window ---
    Send-PostedKey $searchBox 0x28   # Down -> 'alpha' (below the pinned entry)
    Wait-Milliseconds 200
    Send-PostedKey $searchBox 0x0D   # Enter
    $pasted = Wait-Until { $targetBox.Text -eq 'alpha test entry' }
    Add-Result 'Enter pastes into the previously active window' $pasted "target text: '$($targetBox.Text)'"

    # --- change the hotkey via tray menu -> dialog (real keys) ---
    $dialogDone = $false
    if ([TestNative]::Activate($target.Handle)) {
        [void][TestNative]::AllowSetForegroundWindow($manager.Id)
        foreach ($window in [TestNative]::TopLevelWindowsOf($manager.Id)) {
            if ([TestNative]::TitleOf($window) -eq '') {   # the NotifyIcon's hidden window has no title
                [void][TestNative]::PostMessage($window, [TestNative]::WM_TRAYMOUSEMESSAGE, [IntPtr]::Zero, [IntPtr][TestNative]::WM_RBUTTONUP)
            }
        }
        $menuOpen = Wait-Until { [TestNative]::ProcessOf([TestNative]::GetForegroundWindow()) -eq $manager.Id } 2000
        if ($menuOpen) {
            Wait-Milliseconds 300
            $menuWindow = [TestNative]::TopLevelWindowsOf($manager.Id) |
                Where-Object { [TestNative]::IsWindowVisible($_) -and $_ -ne $popup } |
                Select-Object -First 1
            if ($menuWindow) { Save-WindowImage $menuWindow "tray-menu-$Theme.png" }

            [TestNative]::PressKeys(0x28)   # Down -> Show history
            [TestNative]::PressKeys(0x28)   # Down -> Change hotkey...
            [TestNative]::PressKeys(0x0D)   # Enter

            $dialog = [IntPtr]::Zero
            $dialogShown = Wait-Until {
                $script:dialog = [TestNative]::FindWindow([NullString]::Value, 'Change hotkey')
                $script:dialog -ne [IntPtr]::Zero -and (Test-Foreground $script:dialog)
            }
            Add-Result 'Tray menu opens the hotkey dialog' $dialogShown
            if ($dialogShown) {
                Wait-Milliseconds 200
                Save-WindowImage $dialog "hotkey-dialog-$Theme.png"
                [TestNative]::PressKeys(0x11, 0x12, 0x10, 0x78)   # Ctrl+Alt+Shift+F9
                Wait-Milliseconds 300
                $shown = [TestNative]::TextOf([TestNative]::FocusOf($dialog))
                Add-Result 'Dialog shows the pressed combination' ($shown -eq 'Ctrl+Alt+Shift+F9') $shown
                if (Test-Foreground $dialog) { [TestNative]::PressKeys(0x0D) }   # Enter = OK
                [void](Wait-Until { -not [TestNative]::IsWindowVisible($dialog) })

                $newTaken = -not (Test-HotkeyFree 0x7 0x78)
                $oldFree = Test-HotkeyFree 0x6 0x56
                Add-Result 'New hotkey registered, old one released' ($newTaken -and $oldFree) "new taken: $newTaken, old free: $oldFree"
                $dialogDone = $true
            }
        }
    }
    if (-not $dialogDone -and -not ($results | Where-Object Step -eq 'Tray menu opens the hotkey dialog')) {
        Add-Result 'Tray menu opens the hotkey dialog' $false 'not run: could not open the tray menu in the foreground'
    }
}
finally {
    $target.Dispose()
    $hostWindow = [TestNative]::FindWindow([NullString]::Value, 'PsClipboardManager')
    if ($hostWindow -ne [IntPtr]::Zero) {
        [void][TestNative]::PostMessage($hostWindow, [TestNative]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
    }
    $exited = $manager.WaitForExit(5000)
    Add-Result 'Graceful shutdown via WM_CLOSE' $exited
    if (-not $exited) { Stop-Process -Id $manager.Id -Force }

    if ($savedClipboard) { Set-Clipboard -Value $savedClipboard } else { [Clipboard]::Clear() }
    $results | Format-Table -AutoSize -Wrap | Out-String -Width 160 | Write-Host
    Write-Host "Logs and screenshots: $OutputDirectory"
}

if ($results | Where-Object Result -eq 'FAIL') { exit 1 }
