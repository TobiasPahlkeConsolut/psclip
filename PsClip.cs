// Native helpers for ClipboardManager.ps1, compiled at startup with Add-Type.
// Windows PowerShell 5.1 compiles this as C# 5 - see AGENTS.md. Keep the file ASCII-only.

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

        [StructLayout(LayoutKind.Sequential)]
        struct LastInputInfo
        {
            public uint Size;
            public uint Time;
        }

        [DllImport("user32.dll")]
        static extern bool GetLastInputInfo(ref LastInputInfo info);

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

        public static void PressKey(byte vk)
        {
            SendKey(vk, false);
            SendKey(vk, true);
        }

        // Milliseconds since the last mouse or keyboard input in this session (synthetic input counts too).
        public static int GetIdleMilliseconds()
        {
            LastInputInfo info = new LastInputInfo();
            info.Size = (uint)Marshal.SizeOf(info);
            if (!GetLastInputInfo(ref info)) return 0;
            return (int)unchecked((uint)Environment.TickCount - info.Time);
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
