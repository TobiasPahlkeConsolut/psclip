<#
.SYNOPSIS
    Minimal clipboard history manager for Windows - in memory only, plain text only.

.DESCRIPTION
    Records every text that is copied to the clipboard and keeps the most recent entries in
    memory. Nothing is ever written to disk: the history (pinned entries included) is gone
    when the script exits.

    Press the hotkey (see -Hotkey) to open the history next to the mouse cursor:

        type to filter        every word must match, case-insensitive
        Up/Down, PgUp/PgDn    move the selection
        Enter, double-click   paste the entry into the window that was active
        Ctrl+P                pin / unpin the entry; pinned entries stay on top and are never
                              dropped by MaxItems or "Clear history"
        Shift+Delete          remove the entry
        Esc                   close

    Right-click an entry for the same actions. Left-click the tray icon to open the history
    in copy-only mode; right-click it for "Clear history", the settings (hotkey, dark mode,
    window size) and "Exit". Settings changed there last until the script exits.

    Entries that the source application marks as private (password managers set the
    ExcludeClipboardContentFromMonitorProcessing / CanIncludeInClipboardHistory formats) are
    not recorded.

.PARAMETER Hotkey
    Global hotkey, e.g. 'Ctrl+Shift+V', 'Ctrl+Alt+H' or 'Ctrl+F12'. The key part is a
    System.Windows.Forms.Keys name (V, F12, Space, Oemtilde, 1, ...) or the character printed
    on the key, such as an umlaut on a German keyboard. It can also be changed from the tray
    menu; that change lasts until the script exits.

    The default, Ctrl+Oemtilde, is Ctrl+O-umlaut on a German keyboard and Ctrl+` on a US one.

.PARAMETER MaxItems
    Number of unpinned entries to keep; the oldest are dropped.

.PARAMETER Theme
    Dark (default), Light, or Auto to follow the Windows app theme (checked each time the popup
    opens). "Dark mode" in the tray menu switches between dark and light.

.PARAMETER Size
    Size of the history popup: S, M (default) or L - mostly its height. The popup opens at this
    size every time; resizing it by hand lasts until it closes. "Window size" in the tray menu
    changes it.

.EXAMPLE
    conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ClipboardManager.ps1

    Starts the manager without any console window.

.EXAMPLE
    .\ClipboardManager.ps1 -Hotkey 'Ctrl+Alt+V' -MaxItems 500 -Theme Light -Size L -Verbose

    Runs in the current console and logs what happens (never the clipboard content itself).

.NOTES
    Stop it via the tray menu (Exit). Other programs can stop it gracefully by posting WM_CLOSE
    to its hidden window titled 'PsClipboardManager'.
#>

using namespace System.Collections.Generic
using namespace System.Drawing
using namespace System.Windows.Forms

[CmdletBinding()]
param(
    [string]$Hotkey = 'Ctrl+Oemtilde',

    [ValidateRange(1, 100000)]
    [int]$MaxItems = 200,

    [ValidateSet('Dark', 'Light', 'Auto')]
    [string]$Theme = 'Dark',

    [ValidateSet('S', 'M', 'L')]
    [string]$Size = 'M'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'The clipboard requires a single-threaded apartment. Start with: powershell -STA -File ClipboardManager.ps1'
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

#region Native helpers (C#)

$nativeCode = @'
using System;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace PsClip
{
    // Hidden window that receives clipboard-change notifications and the global hotkey.
    public sealed class ClipboardHost : NativeWindow, IDisposable
    {
        const int WM_CLOSE = 0x0010;
        const int WM_HOTKEY = 0x0312;
        const int WM_CLIPBOARDUPDATE = 0x031D;
        const int HOTKEY_ID = 1;
        const uint MOD_NOREPEAT = 0x4000;

        [DllImport("user32.dll", SetLastError = true)]
        static extern bool AddClipboardFormatListener(IntPtr hwnd);

        [DllImport("user32.dll", SetLastError = true)]
        static extern bool RemoveClipboardFormatListener(IntPtr hwnd);

        [DllImport("user32.dll", SetLastError = true)]
        static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint vk);

        [DllImport("user32.dll", SetLastError = true)]
        static extern bool UnregisterHotKey(IntPtr hwnd, int id);

        bool hotkeyRegistered;

        public event EventHandler ClipboardChanged;
        public event EventHandler HotkeyPressed;
        public event EventHandler CloseRequested;   // WM_CLOSE posted by another program

        public ClipboardHost(string caption)
        {
            CreateParams cp = new CreateParams();
            cp.Caption = caption;
            CreateHandle(cp);
            if (!AddClipboardFormatListener(Handle))
                throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        // Returns false if the combination is already registered by another program.
        public bool SetHotkey(uint modifiers, uint vk)
        {
            ClearHotkey();
            hotkeyRegistered = RegisterHotKey(Handle, HOTKEY_ID, modifiers | MOD_NOREPEAT, vk);
            return hotkeyRegistered;
        }

        public void ClearHotkey()
        {
            if (hotkeyRegistered) UnregisterHotKey(Handle, HOTKEY_ID);
            hotkeyRegistered = false;
        }

        protected override void WndProc(ref Message m)
        {
            switch (m.Msg)
            {
                case WM_CLIPBOARDUPDATE:
                    Raise(ClipboardChanged);
                    return;
                case WM_HOTKEY:
                    if (m.WParam.ToInt32() == HOTKEY_ID) Raise(HotkeyPressed);
                    return;
                case WM_CLOSE:
                    Raise(CloseRequested);
                    return;
            }
            base.WndProc(ref m);
        }

        void Raise(EventHandler handler)
        {
            if (handler != null) handler(this, EventArgs.Empty);
        }

        public void Dispose()
        {
            if (Handle == IntPtr.Zero) return;
            ClearHotkey();
            RemoveClipboardFormatListener(Handle);
            DestroyHandle();
        }
    }

    // Context menu colors (the default renderer ignores BackColor for most parts).
    public sealed class MenuColors : ProfessionalColorTable
    {
        readonly Color back, hover, border;

        public MenuColors(Color back, Color hover, Color border)
        {
            this.back = back;
            this.hover = hover;
            this.border = border;
            UseSystemColors = false;
        }

        public override Color ToolStripDropDownBackground { get { return back; } }
        public override Color ImageMarginGradientBegin { get { return back; } }
        public override Color ImageMarginGradientMiddle { get { return back; } }
        public override Color ImageMarginGradientEnd { get { return back; } }
        public override Color MenuBorder { get { return border; } }
        public override Color MenuItemBorder { get { return hover; } }
        public override Color MenuItemSelected { get { return hover; } }
        public override Color MenuItemSelectedGradientBegin { get { return hover; } }
        public override Color MenuItemSelectedGradientEnd { get { return hover; } }
        public override Color SeparatorDark { get { return border; } }
        public override Color SeparatorLight { get { return border; } }
    }

    // Draws check marks and submenu arrows in the text color - the defaults are black and
    // invisible on a dark background.
    public sealed class MenuRenderer : ToolStripProfessionalRenderer
    {
        readonly Color text;

        public MenuRenderer(Color back, Color hover, Color border, Color text)
            : base(new MenuColors(back, hover, border))
        {
            this.text = text;
        }

        protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e)
        {
            Rectangle r = e.ImageRectangle;
            PointF[] points =
            {
                new PointF(r.Left + r.Width * 0.18f, r.Top + r.Height * 0.52f),
                new PointF(r.Left + r.Width * 0.40f, r.Top + r.Height * 0.74f),
                new PointF(r.Left + r.Width * 0.82f, r.Top + r.Height * 0.28f)
            };
            SmoothingMode previous = e.Graphics.SmoothingMode;
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (Pen pen = new Pen(text, Math.Max(1.5f, r.Height / 9f)))
            {
                e.Graphics.DrawLines(pen, points);
            }
            e.Graphics.SmoothingMode = previous;
        }

        protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e)
        {
            e.ArrowColor = text;
            base.OnRenderArrow(e);
        }
    }

    public static class Native
    {
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr hwnd);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
        [DllImport("user32.dll")] static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
        [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint mapType);
        [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extraInfo);
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wParam, string lParam);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern short VkKeyScan(char ch);

        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
        static extern int SetWindowTheme(IntPtr hwnd, string subAppName, string subIdList);

        public static uint GetWindowProcessId(IntPtr hwnd)
        {
            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            return pid;
        }

        public static bool IsKeyDown(int vk)
        {
            return (GetAsyncKeyState(vk) & 0x8000) != 0;
        }

        // Virtual key that types the character on the current keyboard layout (plain or with
        // Shift), or -1 - e.g. VK_OEM_3 for the O-umlaut on a German layout.
        public static int VirtualKeyOf(char ch)
        {
            short result = VkKeyScan(ch);
            if (result == -1 || ((result >> 8) & 0xFF) > 1) return -1;   // none, or needs AltGr
            return result & 0xFF;
        }

        // Character printed on the key on the current keyboard layout, or '\0' if it has none.
        public static char CharacterOf(int vk)
        {
            return (char)(MapVirtualKey((uint)vk, 2 /* MAPVK_VK_TO_CHAR */) & 0xFFFF);
        }

        // SetForegroundWindow is often refused for background processes; attaching to the
        // input queue of the current foreground thread lifts that restriction.
        public static bool ForceForeground(IntPtr hwnd)
        {
            IntPtr current = GetForegroundWindow();
            if (current == hwnd) return true;

            uint unused;
            uint foregroundThread = GetWindowThreadProcessId(current, out unused);
            uint thisThread = GetCurrentThreadId();
            bool attached = foregroundThread != 0 && foregroundThread != thisThread
                            && AttachThreadInput(thisThread, foregroundThread, true);
            try
            {
                BringWindowToTop(hwnd);
                SetForegroundWindow(hwnd);
            }
            finally
            {
                if (attached) AttachThreadInput(thisThread, foregroundThread, false);
            }
            return GetForegroundWindow() == hwnd;
        }

        // Sends Ctrl+V to the foreground window. Waits (max. 1 s) until the user has released
        // modifier keys that would otherwise turn it into e.g. Ctrl+Shift+V.
        public static void SendCtrlV()
        {
            int[] modifiers = { 0x10, 0x11, 0x12, 0x5B, 0x5C };   // Shift, Ctrl, Alt, LWin, RWin
            for (int i = 0; i < 100 && AnyKeyDown(modifiers); i++) Thread.Sleep(10);

            SendKey(0x11, false);
            SendKey(0x56, false);
            SendKey(0x56, true);
            SendKey(0x11, true);
        }

        public static void SetCueBanner(IntPtr textBox, string text)
        {
            SendMessage(textBox, 0x1501 /* EM_SETCUEBANNER */, new IntPtr(1), text);
        }

        public static void SetDarkTitleBar(IntPtr hwnd, bool dark)
        {
            int value = dark ? 1 : 0;
            // 20 = DWMWA_USE_IMMERSIVE_DARK_MODE; 19 on Windows 10 builds before 20H1
            if (DwmSetWindowAttribute(hwnd, 20, ref value, 4) != 0)
                DwmSetWindowAttribute(hwnd, 19, ref value, 4);
        }

        // Dark or light scrollbars for list controls
        public static void SetDarkControlTheme(IntPtr hwnd, bool dark)
        {
            SetWindowTheme(hwnd, dark ? "DarkMode_Explorer" : "Explorer", null);
        }

        static void SendKey(byte vk, bool up)
        {
            keybd_event(vk, (byte)MapVirtualKey(vk, 0), up ? 0x0002u : 0u, UIntPtr.Zero);
        }

        static bool AnyKeyDown(int[] keys)
        {
            foreach (int key in keys)
                if (IsKeyDown(key)) return true;
            return false;
        }
    }
}
'@

if (-not ('PsClip.Native' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition $nativeCode
}

#endregion

#region Settings

$Palettes = @{
    Dark  = @{
        Back    = [Color]::FromArgb(32, 32, 32)
        Input   = [Color]::FromArgb(45, 45, 45)
        Text    = [Color]::FromArgb(240, 240, 240)
        Muted   = [Color]::FromArgb(160, 160, 160)
        Border  = [Color]::FromArgb(64, 64, 64)
        Hover   = [Color]::FromArgb(58, 58, 58)
        SelBack = [Color]::FromArgb(0, 95, 184)
        SelText = [Color]::White
        Accent  = [Color]::FromArgb(96, 205, 255)
    }
    Light = @{
        Back    = [Color]::White
        Input   = [Color]::FromArgb(243, 243, 243)
        Text    = [Color]::FromArgb(26, 26, 26)
        Muted   = [Color]::FromArgb(110, 110, 110)
        Border  = [Color]::FromArgb(225, 225, 225)
        Hover   = [Color]::FromArgb(229, 241, 251)
        SelBack = [Color]::FromArgb(0, 120, 215)
        SelText = [Color]::White
        Accent  = [Color]::FromArgb(0, 95, 184)
    }
}

# Client size of the popup per -Size, at 100 % display scaling (mostly the height changes)
$PopupSizes = @{
    S = [Size]::new(520, 240)
    M = [Size]::new(560, 360)
    L = [Size]::new(620, 540)
}

# RegisterHotKey modifier flags
$HotkeyModifiers = @{ Alt = 0x1; Ctrl = 0x2; Control = 0x2; Shift = 0x4; Win = 0x8; Windows = 0x8 }

$EntryTextFlags = [TextFormatFlags]'VerticalCenter, EndEllipsis, SingleLine, NoPrefix'
$PinTextFlags = [TextFormatFlags]'HorizontalCenter, VerticalCenter, SingleLine, NoPrefix'
$LineBreakMark = " $([char]0x21B5) "   # shown instead of line breaks in the list

#endregion

#region Hotkey

function ConvertFrom-HotkeyText {
    # 'Ctrl+Shift+V' -> modifier flags and virtual key code for RegisterHotKey
    param([string]$Text)

    $modifiers = 0
    $key = $null
    foreach ($part in (($Text -split '\+').Trim() | Where-Object { $_ })) {
        if ($HotkeyModifiers.ContainsKey($part)) {
            $modifiers = $modifiers -bor $HotkeyModifiers[$part]
            continue
        }
        if ($null -ne $key) { throw "Hotkey '$Text' contains more than one key." }
        $key = ConvertTo-Key $part
    }
    if ($null -eq $key) { throw "Hotkey '$Text' has no key, only modifiers." }

    [pscustomobject]@{ Modifiers = [uint32]$modifiers; VirtualKey = [uint32]$key }
}

function ConvertTo-Key {
    # 'V', 'F12', 'Oemtilde', '1' or the character printed on a key (e.g. an umlaut) -> [Keys]
    param([string]$Name)

    $keyName = if ($Name -match '^\d$') { "D$Name" } else { $Name }   # '1' -> Keys.D1
    try {
        $key = [Keys]$keyName
        if ($key -ne [Keys]::None) { return $key }
    }
    catch {
        # Not a [Keys] name - maybe a character.
    }
    if ($Name.Length -eq 1) {
        $virtualKey = [PsClip.Native]::VirtualKeyOf($Name[0])
        if ($virtualKey -ge 0) { return [Keys]$virtualKey }
    }
    throw "Unknown key '$Name'. Use a System.Windows.Forms.Keys name such as V, F12 or Space, or the character on the key."
}

function Get-KeyDisplayName {
    # The character printed on OEM keys (an umlaut instead of 'Oemtilde' on a German keyboard),
    # digits without the 'D', otherwise the [Keys] name.
    param([Keys]$Key)

    $name = [string]$Key
    if ($name -match '^D\d$') { return $name.Substring(1) }
    if ($name -like 'Oem*') {
        $character = ([string][PsClip.Native]::CharacterOf([int]$Key)).ToUpper()
        # Only if it maps back to the same key; '+' would clash with the separator.
        if ($character.Length -eq 1 -and $character -ne "`0" -and $character -ne '+' -and
            [PsClip.Native]::VirtualKeyOf($character[0]) -eq [int]$Key) {
            return $character
        }
    }
    return $name
}

function Format-HotkeyText {
    # Normalized display text, e.g. 'ctrl+shift+v' -> 'Ctrl+Shift+V', 'Ctrl+Oemtilde' -> 'Ctrl+' + umlaut
    param([string]$Text)

    $spec = ConvertFrom-HotkeyText $Text
    $parts = @()
    foreach ($modifier in 'Ctrl', 'Alt', 'Shift', 'Win') {
        if ($spec.Modifiers -band $HotkeyModifiers[$modifier]) { $parts += $modifier }
    }
    $parts += Get-KeyDisplayName ([Keys]$spec.VirtualKey)
    $parts -join '+'
}

function ConvertTo-HotkeyText {
    # Builds 'Ctrl+Shift+V' from a KeyDown event; returns $null while only modifiers are pressed.
    param([KeyEventArgs]$KeyEvent)

    $modifierKeys = [Keys]::ShiftKey, [Keys]::ControlKey, [Keys]::Menu, [Keys]::LWin, [Keys]::RWin
    if ($KeyEvent.KeyCode -in $modifierKeys) { return $null }

    $parts = @()
    if ($KeyEvent.Control) { $parts += 'Ctrl' }
    if ($KeyEvent.Alt) { $parts += 'Alt' }
    if ($KeyEvent.Shift) { $parts += 'Shift' }
    if ([PsClip.Native]::IsKeyDown(0x5B) -or [PsClip.Native]::IsKeyDown(0x5C)) { $parts += 'Win' }
    $parts += Get-KeyDisplayName $KeyEvent.KeyCode
    $parts -join '+'
}

function Register-Hotkey {
    # Returns $false if the combination is already used by another program.
    param([string]$Text)

    $spec = ConvertFrom-HotkeyText $Text
    if (-not $Ui.ClipHost.SetHotkey($spec.Modifiers, $spec.VirtualKey)) { return $false }

    $State.HotkeyText = Format-HotkeyText $Text
    $State.HotkeyActive = $true
    Write-Verbose "Hotkey $Text registered."
    return $true
}

function Edit-Hotkey {
    Set-Theme (Test-DarkTheme)
    $wasActive = $State.HotkeyActive
    $Ui.ClipHost.ClearHotkey()   # so that the current combination can be pressed in the dialog
    $State.HotkeyActive = $false

    if (-not (Show-HotkeyDialog) -and $wasActive) {
        [void](Register-Hotkey $State.HotkeyText)   # cancelled: restore the previous hotkey
    }
    Update-TrayText
}

function Show-HotkeyDialog {
    # Modal dialog that captures a key combination and registers it. Returns $true on success.
    $colors = $State.Colors
    $scale = $Ui.Scale
    $pad = [int](12 * $scale)
    $gap = [int](6 * $scale)
    $width = [int](380 * $scale)

    $form = [Form]::new()
    $form.Text = 'Change hotkey'
    $form.FormBorderStyle = 'FixedToolWindow'
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.AutoScaleMode = 'None'
    $form.Font = $Ui.Font
    $form.BackColor = $colors.Back
    $form.ForeColor = $colors.Text

    $prompt = [Label]::new()
    $prompt.Text = 'Press the new key combination:'
    $prompt.AutoSize = $true
    $prompt.Location = [Point]::new($pad, $pad)

    $keyBox = [TextBox]::new()
    $keyBox.ReadOnly = $true
    $keyBox.BorderStyle = 'FixedSingle'
    $keyBox.BackColor = $colors.Input
    $keyBox.ForeColor = $colors.Text
    $keyBox.Text = $State.HotkeyText
    $keyBox.Location = [Point]::new($pad, $pad + $prompt.PreferredHeight + $gap)
    $keyBox.Width = $width - 2 * $pad

    $hint = [Label]::new()
    $hint.AutoSize = $false
    $hint.ForeColor = $colors.Muted
    $hint.Text = 'Ctrl, Alt, Shift or Win plus a key, or an F-key alone.'
    $hint.Location = [Point]::new($pad, $keyBox.Bottom + $gap)
    $hint.Size = [Size]::new($width - 2 * $pad, $Ui.Font.Height * 2)

    $buttonSize = [Size]::new([int](88 * $scale), [int](30 * $scale))
    $buttonTop = $hint.Bottom + $gap
    $cancel = New-FlatButton -Text 'Cancel' -Size $buttonSize `
        -Location ([Point]::new($width - $pad - $buttonSize.Width, $buttonTop))
    $ok = New-FlatButton -Text 'OK' -Size $buttonSize `
        -Location ([Point]::new($cancel.Left - $gap - $buttonSize.Width, $buttonTop))
    $ok.Enabled = $false
    $cancel.DialogResult = 'Cancel'

    $form.CancelButton = $cancel
    $form.ClientSize = [Size]::new($width, $buttonTop + $buttonSize.Height + $pad)
    $form.Controls.AddRange([Control[]]@($prompt, $keyBox, $hint, $ok, $cancel))

    # The handlers run during ShowDialog, while the variables of this function still exist.
    $dialog = @{ Form = $form; KeyBox = $keyBox; Hint = $hint; Ok = $ok; Pending = $null }

    $keyBox.add_PreviewKeyDown({
        param($source, $e)
        $e.IsInputKey = $true   # also capture Tab, arrows, ...
    })
    $keyBox.add_KeyDown({
        param($source, $e)
        Update-HotkeyDialog -Dialog $dialog -KeyEvent $e
    })
    $ok.add_Click({
        if (Register-Hotkey $dialog.Pending) {
            $dialog.Form.DialogResult = 'OK'
        }
        else {
            $dialog.Hint.Text = "$($dialog.Pending) is already used by another program. Try another one."
            $dialog.Ok.Enabled = $false
        }
    })
    $form.add_Shown({
        [void][PsClip.Native]::ForceForeground($dialog.Form.Handle)
        $dialog.Form.Activate()
        [void]$dialog.KeyBox.Focus()
    })

    [PsClip.Native]::SetDarkTitleBar($form.Handle, $State.IsDark)
    $result = $form.ShowDialog()
    $form.Dispose()
    return ($result -eq [DialogResult]::OK)
}

function Update-HotkeyDialog {
    # KeyDown in the hotkey dialog: shows the pressed combination, Enter applies, Esc cancels.
    param([hashtable]$Dialog, [KeyEventArgs]$KeyEvent)

    $KeyEvent.Handled = $true
    $KeyEvent.SuppressKeyPress = $true

    $text = ConvertTo-HotkeyText $KeyEvent
    if (-not $text) { return }

    if ($text -eq 'Escape') {
        $Dialog.Form.DialogResult = 'Cancel'
        return
    }
    if ($text -eq 'Return') {
        if ($Dialog.Ok.Enabled) { $Dialog.Ok.PerformClick() }
        return
    }
    if ($text -notmatch '\+' -and $text -notmatch '^F\d+$') {
        $Dialog.Hint.Text = 'Add Ctrl, Alt, Shift or Win - a plain key would block typing.'
        return
    }

    $Dialog.Pending = $text
    $Dialog.KeyBox.Text = $text
    $Dialog.Hint.Text = 'Press Enter or click OK to apply.'
    $Dialog.Ok.Enabled = $true
}

function New-FlatButton {
    param([string]$Text, [Point]$Location, [Size]$Size)

    $button = [Button]::new()
    $button.Text = $Text
    $button.Location = $Location
    $button.Size = $Size
    $button.FlatStyle = 'Flat'
    $button.BackColor = $State.Colors.Input
    $button.ForeColor = $State.Colors.Text
    $button.FlatAppearance.BorderColor = $State.Colors.Border
    $button
}

#endregion

#region Clipboard and history

function Read-ClipboardText {
    # Returns the clipboard text, or $null if there is none or the source app marked it as private.
    $data = [Clipboard]::GetDataObject()
    if ($null -eq $data) { return $null }

    if ($data.GetDataPresent('ExcludeClipboardContentFromMonitorProcessing') -or
        $data.GetDataPresent('Clipboard Viewer Ignore')) {
        Write-Verbose 'Ignored clipboard content marked as private.'
        return $null
    }
    if ($data.GetDataPresent('CanIncludeInClipboardHistory')) {
        $flag = $data.GetData('CanIncludeInClipboardHistory')
        if ($flag -is [System.IO.MemoryStream] -and $flag.Length -ge 4 -and
            [BitConverter]::ToInt32($flag.ToArray(), 0) -eq 0) {
            Write-Verbose 'Ignored clipboard content excluded from clipboard history.'
            return $null
        }
    }
    if (-not $data.GetDataPresent([DataFormats]::UnicodeText)) { return $null }

    return [string]$data.GetData([DataFormats]::UnicodeText)
}

function Receive-ClipboardChange {
    try {
        $text = Read-ClipboardText
    }
    catch {
        Write-Verbose "Could not read the clipboard: $($_.Exception.Message)"
        return
    }
    if ($null -eq $text) { return }

    Add-ClipboardEntry $text
    Update-TrayText
    if ($Ui.Form.Visible) { Update-PopupList $Ui.List.SelectedIndex }
}

function Add-ClipboardEntry {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    if ($State.Pinned.Contains($Text)) { return }   # pinned entries keep their place

    [void]$State.History.Remove($Text)              # a re-copied entry moves to the top
    $State.History.Insert(0, $Text)
    Limit-ClipboardHistory
    Write-Verbose "Recorded entry ($($Text.Length) chars); $($State.History.Count) entries in history."
}

function Remove-ClipboardEntry {
    param([string]$Text)

    if (-not $State.Pinned.Remove($Text)) {
        [void]$State.History.Remove($Text)
    }
}

function Switch-ClipboardPin {
    # Pinning appends the entry to the pinned group; unpinning moves it to the top of the history.
    param([string]$Text)

    if ($State.Pinned.Remove($Text)) {
        $State.History.Insert(0, $Text)
        Limit-ClipboardHistory
    }
    else {
        [void]$State.History.Remove($Text)
        $State.Pinned.Add($Text)
    }
}

function Limit-ClipboardHistory {
    while ($State.History.Count -gt $MaxItems) {
        $State.History.RemoveAt($State.History.Count - 1)
    }
}

function Clear-ClipboardHistory {
    $State.History.Clear()   # pinned entries stay
    Update-TrayText
    if ($Ui.Form.Visible) { Update-PopupList }
}

#endregion

#region Popup

function Show-Popup {
    # Opens the popup at the mouse cursor. With -PasteIntoActiveWindow, choosing an entry pastes
    # it into the window that was active before; otherwise the entry is only copied.
    param([switch]$PasteIntoActiveWindow)

    $State.PasteTarget = [IntPtr]::Zero
    if ($PasteIntoActiveWindow) {
        $active = [PsClip.Native]::GetForegroundWindow()
        if ($active -ne [IntPtr]::Zero -and [PsClip.Native]::GetWindowProcessId($active) -ne $PID) {
            $State.PasteTarget = $active
        }
    }

    Set-Theme (Test-DarkTheme)
    Reset-PopupSize
    if ($Ui.Search.Text) {
        $Ui.Search.Text = ''   # TextChanged refreshes the list
    }
    else {
        Update-PopupList
    }

    $form = $Ui.Form
    $cursor = [Cursor]::Position
    $area = [Screen]::FromPoint($cursor).WorkingArea
    $x = [Math]::Max($area.Left, [Math]::Min($cursor.X, $area.Right - $form.Width))
    $y = [Math]::Max($area.Top, [Math]::Min($cursor.Y, $area.Bottom - $form.Height))
    $form.Location = [Point]::new($x, $y)

    $form.Show()
    [void][PsClip.Native]::ForceForeground($form.Handle)
    $form.Activate()
    [void]$Ui.Search.Focus()
}

function Reset-PopupSize {
    # The popup always opens at the configured size; resizing it by hand lasts until it closes.
    $logicalSize = $PopupSizes[$State.PopupSize]
    $Ui.Form.ClientSize = [Size]::new(
        [int]($logicalSize.Width * $Ui.Scale),
        [int]($logicalSize.Height * $Ui.Scale))
}

function Show-PopupLater {
    # From the tray: open once the click or menu has been fully processed.
    [void]$Ui.Form.BeginInvoke([Action] { Show-Popup })
}

function Hide-Popup {
    if ($Ui.Form.Visible) { $Ui.Form.Hide() }
}

function Switch-Popup {
    if ($Ui.Form.Visible) {
        Hide-Popup
    }
    else {
        Show-Popup -PasteIntoActiveWindow
    }
}

function Update-PopupList {
    # Refills the list from the pinned entries and the history, applying the filter text.
    param([int]$SelectIndex = 0)

    $terms = $Ui.Search.Text.Split([char[]]@(' ', "`t"), [StringSplitOptions]::RemoveEmptyEntries)
    $found = [List[string]]::new()
    foreach ($entry in $State.Pinned) {
        if (Test-FilterMatch $entry $terms) { $found.Add($entry) }
    }
    $pinnedCount = $found.Count
    foreach ($entry in $State.History) {
        if (Test-FilterMatch $entry $terms) { $found.Add($entry) }
    }
    $State.Filtered = $found
    $State.FilteredPinnedCount = $pinnedCount

    $list = $Ui.List
    $list.BeginUpdate()
    $list.Items.Clear()
    foreach ($entry in $found) {
        [void]$list.Items.Add((Format-Preview $entry))
    }
    $list.EndUpdate()
    if ($found.Count -gt 0) {
        $list.SelectedIndex = [Math]::Max(0, [Math]::Min($SelectIndex, $found.Count - 1))
    }

    $action = if ($State.PasteTarget -ne [IntPtr]::Zero) { 'paste' } else { 'copy' }
    $total = $State.Pinned.Count + $State.History.Count
    $Ui.Status.Text = @(
        "$($found.Count) of $total"
        "Enter $action"
        'Ctrl+P pin'
        'Shift+Del remove'
        'Esc close'
    ) -join "   $([char]0xB7)   "
}

function Test-FilterMatch {
    # True if the entry contains every term (case-insensitive).
    param([string]$Entry, [string[]]$Terms)

    foreach ($term in $Terms) {
        if ($Entry.IndexOf($term, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    }
    return $true
}

function Format-Preview {
    # One-line preview for the list; the full text is used when pasting.
    param([string]$Text)

    $preview = $Text.Trim()
    if ($preview.Length -gt 300) { $preview = $preview.Substring(0, 300) }
    $preview = $preview -replace '\r\n?|\n', $LineBreakMark
    $preview -replace '[ \t]+', ' '
}

function Move-Selection {
    param([int]$Delta)

    $count = $Ui.List.Items.Count
    if ($count -eq 0) { return }
    $Ui.List.SelectedIndex = [Math]::Max(0, [Math]::Min($count - 1, $Ui.List.SelectedIndex + $Delta))
}

function Get-SelectedEntry {
    $index = $Ui.List.SelectedIndex
    if ($index -lt 0 -or $index -ge $State.Filtered.Count) { return $null }
    $State.Filtered[$index]
}

function Invoke-SelectedEntry {
    # Puts the selected entry on the clipboard and pastes it into the previously active window.
    $text = Get-SelectedEntry
    if ($null -eq $text) { return }

    $target = $State.PasteTarget
    Hide-Popup
    try {
        [Clipboard]::SetText($text)
    }
    catch {
        $Ui.Tray.ShowBalloonTip(5000, 'Clipboard history',
            "Could not write to the clipboard: $($_.Exception.Message)", 'Warning')
        return
    }

    # Only send Ctrl+V if the original window is really back in front - never into another one.
    if ($target -ne [IntPtr]::Zero -and
        [PsClip.Native]::IsWindow($target) -and
        [PsClip.Native]::ForceForeground($target)) {
        Start-Sleep -Milliseconds 50
        [PsClip.Native]::SendCtrlV()
    }
}

function Switch-SelectedPin {
    $text = Get-SelectedEntry
    if ($null -eq $text) { return }

    Switch-ClipboardPin $text
    Update-PopupList
    $Ui.List.SelectedIndex = $State.Filtered.IndexOf($text)
}

function Remove-SelectedEntry {
    $text = Get-SelectedEntry
    if ($null -eq $text) { return }

    $index = $Ui.List.SelectedIndex
    Remove-ClipboardEntry $text
    Update-PopupList $index
    Update-TrayText
}

function Invoke-PopupKey {
    # KeyDown of the popup (KeyPreview): navigation and actions; other keys go to the filter box.
    param([KeyEventArgs]$KeyEvent)

    $page = [Math]::Max(1, [int]($Ui.List.ClientSize.Height / $Ui.List.ItemHeight))
    $handled = $true

    # Enum constants, not strings: a string switch would compare 'Return'/'Next' with 'Enter'/'PageDown'.
    switch ($KeyEvent.KeyCode) {
        ([Keys]::Escape) { Hide-Popup }
        ([Keys]::Enter) { Invoke-SelectedEntry }
        ([Keys]::Down) { Move-Selection 1 }
        ([Keys]::Up) { Move-Selection -1 }
        ([Keys]::PageDown) { Move-Selection $page }
        ([Keys]::PageUp) { Move-Selection (-$page) }
        ([Keys]::P) {
            if ($KeyEvent.Control) { Switch-SelectedPin } else { $handled = $false }
        }
        ([Keys]::Delete) {
            if ($KeyEvent.Shift) { Remove-SelectedEntry } else { $handled = $false }
        }
        default { $handled = $false }
    }

    if ($handled) {
        $KeyEvent.Handled = $true
        $KeyEvent.SuppressKeyPress = $true
    }
}

function Write-ListItem {
    # Owner-draw handler of the list: background, pin icon, text and a line below the pinned group.
    param([DrawItemEventArgs]$DrawEvent)

    $index = $DrawEvent.Index
    if ($index -lt 0 -or $index -ge $Ui.List.Items.Count) { return }

    $colors = $State.Colors
    $graphics = $DrawEvent.Graphics
    $bounds = $DrawEvent.Bounds
    $isSelected = ($DrawEvent.State -band [DrawItemState]::Selected) -ne 0
    $isPinned = $index -lt $State.FilteredPinnedCount

    $background = if ($isSelected) { $State.Gdi.SelBack } else { $State.Gdi.Back }
    $graphics.FillRectangle($background, $bounds)

    if ($isPinned) {
        $pinBounds = [Rectangle]::new($bounds.X, $bounds.Y, $Ui.PinColumn, $bounds.Height)
        $pinColor = if ($isSelected) { $colors.SelText } else { $colors.Accent }
        [TextRenderer]::DrawText($graphics, $Ui.PinGlyph, $Ui.PinFont, $pinBounds, $pinColor, $PinTextFlags)

        $isLastPinned = $index -eq $State.FilteredPinnedCount - 1 -and $index -lt $Ui.List.Items.Count - 1
        if ($isLastPinned) {
            $y = $bounds.Bottom - 1
            $graphics.DrawLine($State.Gdi.Separator, $bounds.Left, $y, $bounds.Right, $y)
        }
    }

    $textBounds = [Rectangle]::new(
        $bounds.X + $Ui.PinColumn, $bounds.Y,
        $bounds.Width - $Ui.PinColumn - $Ui.Padding, $bounds.Height)
    $textColor = if ($isSelected) { $colors.SelText } else { $colors.Text }
    $text = [string]$Ui.List.Items[$index]
    [TextRenderer]::DrawText($graphics, $text, $DrawEvent.Font, $textBounds, $textColor, $EntryTextFlags)
}

#endregion

#region Theme

function Test-DarkTheme {
    if ($State.ThemeSetting -eq 'Dark') { return $true }
    if ($State.ThemeSetting -eq 'Light') { return $false }

    try {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        return (Get-ItemPropertyValue $key -Name AppsUseLightTheme) -eq 0
    }
    catch {
        return $false
    }
}

function Set-Theme {
    param([bool]$Dark)

    if ($State.IsDark -eq $Dark) { return }
    $State.IsDark = $Dark
    $colors = if ($Dark) { $Palettes.Dark } else { $Palettes.Light }
    $State.Colors = $colors

    foreach ($gdiObject in $State.Gdi.Values) { $gdiObject.Dispose() }
    $State.Gdi = @{
        Back      = [SolidBrush]::new($colors.Back)
        SelBack   = [SolidBrush]::new($colors.SelBack)
        Separator = [Pen]::new($colors.Border)
    }

    $Ui.Form.BackColor = $colors.Back
    $Ui.SearchPanel.BackColor = $colors.Input
    $Ui.Search.BackColor = $colors.Input
    $Ui.Search.ForeColor = $colors.Text
    $Ui.List.BackColor = $colors.Back
    $Ui.List.ForeColor = $colors.Text
    $Ui.Status.BackColor = $colors.Back
    $Ui.Status.ForeColor = $colors.Muted
    [PsClip.Native]::SetDarkTitleBar($Ui.Form.Handle, $Dark)
    [PsClip.Native]::SetDarkControlTheme($Ui.List.Handle, $Dark)

    # Submenus are separate drop-downs and need their own renderer.
    foreach ($menu in $Ui.TrayMenu, $Ui.SizeMenuItem.DropDown, $Ui.ListMenu) {
        $menu.Renderer = [PsClip.MenuRenderer]::new($colors.Back, $colors.Hover, $colors.Border, $colors.Text)
        $menu.BackColor = $colors.Back
        $menu.ForeColor = $colors.Text
    }
    $Ui.List.Invalidate()
}

function Switch-DarkMode {
    $State.ThemeSetting = if ($State.IsDark) { 'Light' } else { 'Dark' }
    Set-Theme (Test-DarkTheme)
}

#endregion

#region Window construction

function Initialize-Ui {
    [void][PsClip.Native]::SetProcessDPIAware()
    [Application]::EnableVisualStyles()
    try {
        [Application]::SetCompatibleTextRenderingDefault($false)
    }
    catch {
        # Only possible before the first window of the process; harmless when it fails.
    }
    [Application]::add_ThreadException({
        param($source, $e)
        Write-Warning "Error in event handler: $($e.Exception.Message)"
    })

    $graphics = [Graphics]::FromHwnd([IntPtr]::Zero)
    $Ui.Scale = $graphics.DpiX / 96.0
    $graphics.Dispose()

    $Ui.Font = [Font]::new('Segoe UI', 10)
    $Ui.SmallFont = [Font]::new('Segoe UI', 8.5)
    $Ui.PinFont = [Font]::new('Segoe MDL2 Assets', 9)
    $Ui.PinGlyph = [string][char]0xE718
    if ($Ui.PinFont.Name -ne 'Segoe MDL2 Assets') {
        # Icon font not installed: fall back to a plain asterisk.
        $Ui.PinFont = $Ui.Font
        $Ui.PinGlyph = '*'
    }
    $Ui.PinColumn = [int](26 * $Ui.Scale)
    $Ui.Padding = [int](8 * $Ui.Scale)
}

function New-PopupWindow {
    $scale = $Ui.Scale

    $form = [Form]::new()
    $form.Text = 'Clipboard history'
    $form.FormBorderStyle = 'SizableToolWindow'
    $form.StartPosition = 'Manual'
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.KeyPreview = $true
    $form.AutoScaleMode = 'None'
    $form.Font = $Ui.Font
    $form.MinimumSize = [Size]::new([int](300 * $scale), [int](200 * $scale))

    $search = [TextBox]::new()
    $search.Dock = 'Top'
    $search.BorderStyle = 'None'

    $searchPanel = [Panel]::new()
    $searchPanel.Dock = 'Top'
    $searchPanel.Padding = [Padding]::new($Ui.PinColumn, $Ui.Padding, $Ui.Padding, $Ui.Padding)
    $searchPanel.Height = $search.PreferredHeight + 2 * $Ui.Padding
    $searchPanel.Controls.Add($search)

    $list = [ListBox]::new()
    $list.Dock = 'Fill'
    $list.IntegralHeight = $false
    $list.BorderStyle = 'None'
    $list.DrawMode = 'OwnerDrawFixed'
    $list.ItemHeight = $Ui.Font.Height + [int](10 * $scale)
    $list.ContextMenuStrip = New-ListMenu

    $status = [Label]::new()
    $status.Dock = 'Bottom'
    $status.AutoSize = $false
    $status.Font = $Ui.SmallFont
    $status.Height = [int]($Ui.SmallFont.Height * 1.8)
    $status.TextAlign = 'MiddleLeft'
    $status.Padding = [Padding]::new([int](4 * $scale), 0, 0, 0)

    # Docking is applied in reverse order: the Fill control has to be added first.
    $form.Controls.Add($list)
    $form.Controls.Add($searchPanel)
    $form.Controls.Add($status)

    $Ui.Form = $form
    $Ui.Search = $search
    $Ui.SearchPanel = $searchPanel
    $Ui.List = $list
    $Ui.Status = $status
    Reset-PopupSize

    [void]$form.Handle   # create the window now so that BeginInvoke works before the first Show
    [PsClip.Native]::SetCueBanner($search.Handle, 'Type to filter...')

    # Event handlers run after this function has returned: use $Ui / $State, not local variables.
    $search.add_TextChanged({ Update-PopupList })
    $list.add_DrawItem({
        param($source, $e)
        Write-ListItem $e
    })
    $list.add_MouseDoubleClick({
        param($source, $e)
        if ($Ui.List.IndexFromPoint($e.Location) -ge 0) { Invoke-SelectedEntry }
    })
    $list.add_MouseDown({
        param($source, $e)
        if ($e.Button -eq 'Right') {
            # Select the entry under the mouse before the context menu opens.
            $index = $Ui.List.IndexFromPoint($e.Location)
            if ($index -ge 0) { $Ui.List.SelectedIndex = $index }
        }
    })
    $list.add_MouseUp({
        param($source, $e)
        if ($e.Button -eq 'Left') { [void]$Ui.Search.Focus() }   # keep typing going to the filter box
    })
    $form.add_KeyDown({
        param($source, $e)
        Invoke-PopupKey $e
    })
    $form.add_Deactivate({ Hide-Popup })
    $form.add_FormClosing({
        param($source, $e)
        if ($e.CloseReason -eq 'UserClosing') {
            $e.Cancel = $true   # the close button only hides the popup
            Hide-Popup
        }
    })
}

function New-ListMenu {
    $menu = [ContextMenuStrip]::new()

    $use = $menu.Items.Add('Paste')
    $use.ShortcutKeyDisplayString = 'Enter'
    $use.add_Click({ Invoke-SelectedEntry })

    $pin = $menu.Items.Add('Pin to top')
    $pin.ShortcutKeyDisplayString = 'Ctrl+P'
    $pin.add_Click({
        Switch-SelectedPin
        [void]$Ui.Search.Focus()
    })

    $remove = $menu.Items.Add('Remove')
    $remove.ShortcutKeyDisplayString = 'Shift+Del'
    $remove.add_Click({
        Remove-SelectedEntry
        [void]$Ui.Search.Focus()
    })

    $menu.add_Opening({
        param($source, $e)
        $index = $Ui.List.SelectedIndex
        if ($index -lt 0 -or $index -ge $State.Filtered.Count) {
            $e.Cancel = $true
            return
        }
        $source.Items[0].Text = if ($State.PasteTarget -ne [IntPtr]::Zero) { 'Paste' } else { 'Copy' }
        $source.Items[1].Text = if ($index -lt $State.FilteredPinnedCount) { 'Unpin' } else { 'Pin to top' }
    })

    $Ui.ListMenu = $menu
    return $menu
}

function New-TrayIcon {
    $menu = [ContextMenuStrip]::new()
    $menu.Items.Add('Show history').add_Click({ Show-PopupLater })
    $menu.Items.Add('Clear history (keeps pinned)').add_Click({ Clear-ClipboardHistory })
    [void]$menu.Items.Add([ToolStripSeparator]::new())

    $Ui.HotkeyMenuItem = $menu.Items.Add('Change hotkey...')
    $Ui.HotkeyMenuItem.add_Click({ [void]$Ui.Form.BeginInvoke([Action] { Edit-Hotkey }) })

    $Ui.DarkModeMenuItem = $menu.Items.Add('Dark mode')
    $Ui.DarkModeMenuItem.add_Click({ Switch-DarkMode })

    $Ui.SizeMenuItem = [ToolStripMenuItem]::new('Window size')
    foreach ($option in @{ Tag = 'S'; Text = 'Small' }, @{ Tag = 'M'; Text = 'Medium' }, @{ Tag = 'L'; Text = 'Large' }) {
        $item = $Ui.SizeMenuItem.DropDownItems.Add($option.Text)
        $item.Tag = $option.Tag
        $item.add_Click({
            param($source, $e)
            $State.PopupSize = $source.Tag
        })
    }
    [void]$menu.Items.Add($Ui.SizeMenuItem)

    [void]$menu.Items.Add([ToolStripSeparator]::new())
    $menu.Items.Add('Exit').add_Click({ $Ui.AppContext.ExitThread() })
    $menu.add_Opening({ Update-TrayMenu })
    $Ui.TrayMenu = $menu

    $tray = [NotifyIcon]::new()
    $tray.Icon = New-ClipboardIcon
    $tray.ContextMenuStrip = $menu
    $tray.add_MouseClick({
        param($source, $e)
        if ($e.Button -eq 'Left') { Show-PopupLater }
    })
    $Ui.Tray = $tray
}

function Update-TrayMenu {
    # Before the tray menu opens: current theme and check marks.
    Set-Theme (Test-DarkTheme)
    $Ui.DarkModeMenuItem.Checked = $State.IsDark
    foreach ($item in $Ui.SizeMenuItem.DropDownItems) {
        $item.Checked = $item.Tag -eq $State.PopupSize
    }
}

function Update-TrayText {
    $hotkeyLabel = if ($State.HotkeyActive) { $State.HotkeyText } else { 'no hotkey' }
    $Ui.HotkeyMenuItem.Text = "Change hotkey ($hotkeyLabel)..."

    $text = "Clipboard history: $($State.Pinned.Count + $State.History.Count) entries ($hotkeyLabel)"
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }   # NotifyIcon limit
    $Ui.Tray.Text = $text
}

function New-ClipboardIcon {
    # Draws a small clipboard so the tray icon is not confused with other PowerShell windows.
    $size = [SystemInformation]::SmallIconSize.Width
    $u = $size / 16.0

    $bitmap = [Bitmap]::new($size, $size)
    $graphics = [Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = 'AntiAlias'
    $board = [SolidBrush]::new([Color]::FromArgb(43, 108, 176))
    $clip = [SolidBrush]::new([Color]::FromArgb(70, 70, 70))

    $graphics.FillRectangle($board, [float](2 * $u), [float](2 * $u), [float](12 * $u), [float](14 * $u))
    $graphics.FillRectangle([Brushes]::White, [float](4 * $u), [float](5 * $u), [float](8 * $u), [float](9 * $u))
    foreach ($lineY in 7, 9.5, 12) {
        $graphics.FillRectangle($board, [float](5.5 * $u), [float]($lineY * $u), [float](5 * $u), [float]$u)
    }
    $graphics.FillRectangle($clip, [float](5 * $u), [float](0.5 * $u), [float](6 * $u), [float](3.5 * $u))

    $graphics.Dispose()
    $board.Dispose()
    $clip.Dispose()
    [Icon]::FromHandle($bitmap.GetHicon())
}

function Start-ClipboardListener {
    $Ui.ClipHost = [PsClip.ClipboardHost]::new('PsClipboardManager')
    $Ui.ClipHost.add_ClipboardChanged({ Receive-ClipboardChange })
    $Ui.ClipHost.add_HotkeyPressed({ Switch-Popup })
    $Ui.ClipHost.add_CloseRequested({ $Ui.AppContext.ExitThread() })
}

#endregion

#region Main

$null = ConvertFrom-HotkeyText $Hotkey   # fail early on an invalid hotkey

# One instance per user session
$mutex = [System.Threading.Mutex]::new($false, 'Local\PsClipboardManager')
try {
    $ownsMutex = $mutex.WaitOne(0)
}
catch [System.Threading.AbandonedMutexException] {
    $ownsMutex = $true   # the previous instance was killed
}
if (-not $ownsMutex) {
    Write-Warning 'The clipboard manager is already running.'
    $mutex.Dispose()
    return
}

$State = @{
    History             = [List[string]]::new()   # unpinned entries, newest first
    Pinned              = [List[string]]::new()   # pinned entries, in pin order
    Filtered            = [List[string]]::new()   # entries currently shown in the popup
    FilteredPinnedCount = 0
    PasteTarget         = [IntPtr]::Zero          # window to paste into; zero = copy only
    HotkeyText          = Format-HotkeyText $Hotkey   # as shown to the user
    HotkeyActive        = $false
    ThemeSetting        = $Theme                  # Dark, Light or Auto; the tray menu switches it
    PopupSize           = $Size                   # S, M or L; the tray menu changes it
    IsDark              = $null
    Colors              = $null
    Gdi                 = @{}                     # brushes and pens of the current theme
}
$Ui = @{
    AppContext = [ApplicationContext]::new()
}

try {
    Initialize-Ui
    New-PopupWindow
    New-TrayIcon
    Set-Theme (Test-DarkTheme)
    Start-ClipboardListener

    $hotkeyOk = Register-Hotkey $Hotkey
    try {
        $initial = Read-ClipboardText
        if ($null -ne $initial) { Add-ClipboardEntry $initial }
    }
    catch {
        Write-Verbose "Could not read the initial clipboard content: $($_.Exception.Message)"
    }
    Update-TrayText
    $Ui.Tray.Visible = $true

    if (-not $hotkeyOk) {
        $Ui.Tray.ShowBalloonTip(8000, 'Clipboard history',
            "The hotkey $($State.HotkeyText) is already used by another program. Right-click the tray icon and choose 'Change hotkey'.",
            'Warning')
    }

    Write-Verbose "Running (PID $PID). Exit via the tray icon menu."
    [Application]::Run($Ui.AppContext)
}
finally {
    if ($Ui.Tray) {
        $Ui.Tray.Visible = $false
        $Ui.Tray.Dispose()
    }
    if ($Ui.ClipHost) { $Ui.ClipHost.Dispose() }
    if ($Ui.Form) { $Ui.Form.Dispose() }
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    Write-Verbose 'Stopped.'
}

#endregion
