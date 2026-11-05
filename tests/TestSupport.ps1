<#
.SYNOPSIS
    Window helpers shared by the end-to-end test and the docs screenshot script.

.DESCRIPTION
    Dot-source it. The functions expect these variables in the calling script: $manager (the
    psclip test process), $target (the test's own window), $hostWindow, $popup, $searchBox,
    $currentHotkeyKeys, $results and $OutputDirectory. Real keystrokes are only sent after
    checking that the expected window is in the foreground.
#>

using namespace System.Windows.Forms

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
if (-not ('TestNative' -as [type])) {
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

    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);

    // The (first) edit control that is - or is not - read-only: the filter box vs. the preview.
    public static IntPtr EditBox(IntPtr parent, bool readOnly)
    {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(parent, delegate (IntPtr hwnd, IntPtr unused)
        {
            StringBuilder name = new StringBuilder(256);
            GetClassName(hwnd, name, name.Capacity);
            if (name.ToString().IndexOf("EDIT", StringComparison.OrdinalIgnoreCase) < 0) return true;
            bool isReadOnly = (GetWindowLong(hwnd, -16 /* GWL_STYLE */) & 0x0800 /* ES_READONLY */) != 0;
            if (isReadOnly != readOnly) return true;
            found = hwnd;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Point { public int X, Y; }

    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Point point);
    [DllImport("user32.dll")] static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extraInfo);

    // Drags with the real mouse from the middle of the window by deltaY pixels - only if that
    // point is really on the window (nothing else gets clicked). Puts the cursor back afterwards.
    // Returns false if it did not drag.
    public static bool DragWindow(IntPtr hwnd, int deltaY)
    {
        Point original;
        GetCursorPos(out original);
        Rect rect;
        GetWindowRect(hwnd, out rect);
        Point start = new Point();
        start.X = (rect.Left + rect.Right) / 2;
        start.Y = (rect.Top + rect.Bottom) / 2;
        try
        {
            SetCursorPos(start.X, start.Y);
            System.Threading.Thread.Sleep(50);
            if (WindowFromPoint(start) != hwnd) return false;

            mouse_event(0x0002 /* LEFTDOWN */, 0, 0, 0, UIntPtr.Zero);
            System.Threading.Thread.Sleep(50);
            for (int step = 1; step <= 8; step++)
            {
                SetCursorPos(start.X, start.Y + deltaY * step / 8);
                System.Threading.Thread.Sleep(25);
            }
            mouse_event(0x0004 /* LEFTUP */, 0, 0, 0, UIntPtr.Zero);
            System.Threading.Thread.Sleep(50);
            return true;
        }
        finally
        {
            SetCursorPos(original.X, original.Y);
        }
    }

    public static IntPtr ChildByTitle(IntPtr parent, string title)
    {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(parent, delegate (IntPtr hwnd, IntPtr unused)
        {
            if (TitleOf(hwnd) != title) return true;
            found = hwnd;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    // Selects characters in an edit control and copies them to the clipboard (EM_SETSEL, WM_COPY).
    public static void CopyTextRange(IntPtr edit, int start, int end)
    {
        SendMessage(edit, 0x00B1, new IntPtr(start), new IntPtr(end));
        SendMessage(edit, 0x0301, IntPtr.Zero, IntPtr.Zero);
    }

    // Texts of all child windows whose class contains classPart (e.g. the labels: "STATIC").
    public static List<string> ChildTexts(IntPtr parent, string classPart)
    {
        List<string> texts = new List<string>();
        EnumChildWindows(parent, delegate (IntPtr hwnd, IntPtr unused)
        {
            StringBuilder name = new StringBuilder(256);
            GetClassName(hwnd, name, name.Capacity);
            if (name.ToString().IndexOf(classPart, StringComparison.OrdinalIgnoreCase) >= 0) texts.Add(TextOf(hwnd));
            return true;
        }, IntPtr.Zero);
        return texts;
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
}

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

    Wait-Milliseconds 300   # a window that just appeared may not have painted itself yet (white)
    $rect = [TestNative]::RectOf($Window)
    $bitmap = [System.Drawing.Bitmap]::new(1, 1)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($rect.Right - 40, $rect.Bottom - 80, 0, 0, [System.Drawing.Size]::new(1, 1))
    $graphics.Dispose()
    $brightness = [int]($bitmap.GetPixel(0, 0).GetBrightness() * 255)
    $bitmap.Dispose()
    $brightness
}

function Get-WindowHeight {
    param([IntPtr]$Window)
    $rect = [TestNative]::RectOf($Window)
    $rect.Bottom - $rect.Top
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
