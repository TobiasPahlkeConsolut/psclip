// Native helpers for ClipboardManager.ps1, compiled at startup with Add-Type.
// Windows PowerShell 5.1 compiles this as C# 5 - see AGENTS.md. Keep the file ASCII-only.

using System;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using ComDataObject = System.Runtime.InteropServices.ComTypes.IDataObject;

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

    // One history entry: a text with the formatting it was copied with - or an image.
    public sealed class ClipEntry
    {
        public string Text;          // null for images
        public string Html;          // "HTML Format" (CF_HTML), or null
        public string Rtf;           // Rich Text Format, or null
        public byte[] Png;           // images: the image, PNG-compressed (in memory only)
        public int Width, Height;    // images: size in pixels
        public Bitmap Thumbnail;     // images: small version for the list
        public string OcrText;       // images: recognized text; null = not (yet) recognized, "" = none found
        public DateTime Copied;
        string imageHash;

        public ClipEntry(string text)
        {
            Text = text;
            Copied = DateTime.Now;
        }

        public static ClipEntry FromImage(Image image, int thumbnailHeight)
        {
            ClipEntry entry = new ClipEntry(null);
            using (MemoryStream stream = new MemoryStream())
            {
                image.Save(stream, ImageFormat.Png);
                entry.Png = stream.ToArray();
            }
            entry.Width = image.Width;
            entry.Height = image.Height;
            using (System.Security.Cryptography.SHA256 sha = System.Security.Cryptography.SHA256.Create())
            {
                entry.imageHash = Convert.ToBase64String(sha.ComputeHash(entry.Png));
            }
            entry.Thumbnail = CreateThumbnail(image, thumbnailHeight);
            return entry;
        }

        public bool IsImage
        {
            get { return Png != null; }
        }

        public bool HasFormatting
        {
            get { return Html != null || Rtf != null; }
        }

        // The same entry for the history: equal text (the formatting may differ - the newer copy
        // wins), or the same image.
        public bool SameContent(ClipEntry other)
        {
            if (other == null) return false;
            if (IsImage || other.IsImage) return IsImage && other.IsImage && imageHash == other.imageHash;
            return string.Equals(Text, other.Text, StringComparison.Ordinal);
        }

        // A new bitmap of the image (the caller owns it).
        public Bitmap ToBitmap()
        {
            using (MemoryStream stream = new MemoryStream(Png))
            using (Image image = Image.FromStream(stream))
            {
                return new Bitmap(image);   // a copy: FromStream needs its stream as long as the image lives
            }
        }

        static Bitmap CreateThumbnail(Image image, int height)
        {
            double scale = Math.Min(1.0, Math.Min((double)height / image.Height, 3.0 * height / image.Width));
            int width = Math.Max(1, (int)Math.Round(image.Width * scale));
            int thumbnailHeight = Math.Max(1, (int)Math.Round(image.Height * scale));
            Bitmap thumbnail = new Bitmap(width, thumbnailHeight);
            using (Graphics graphics = Graphics.FromImage(thumbnail))
            {
                graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                graphics.DrawImage(image, 0, 0, width, thumbnailHeight);
            }
            return thumbnail;
        }

        public override string ToString()
        {
            return IsImage ? "Image " + Width + " x " + Height : Text;
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
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint MapVirtualKey(uint code, uint mapType);
        [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extraInfo);
        [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr handle);
        [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
        [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr handle);
        [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr handle);
        [DllImport("kernel32.dll")] static extern UIntPtr GlobalSize(IntPtr handle);
        [DllImport("ole32.dll")] static extern void ReleaseStgMedium(ref STGMEDIUM medium);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern int ToUnicode(uint vk, uint scanCode, byte[] keyState, StringBuilder buffer, int bufferSize, uint flags);

        [StructLayout(LayoutKind.Sequential)]
        struct Input
        {
            public uint Type;
            public InputUnion Data;
        }

        // MouseInput is the largest member and gives the union its size; it is never sent.
        [StructLayout(LayoutKind.Explicit)]
        struct InputUnion
        {
            [FieldOffset(0)] public MouseInput Mouse;
            [FieldOffset(0)] public KeyboardInput Keyboard;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct MouseInput
        {
            public int X, Y;
            public uint MouseData, Flags, Time;
            public IntPtr ExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct KeyboardInput
        {
            public ushort VirtualKey, ScanCode;
            public uint Flags, Time;
            public IntPtr ExtraInfo;
        }

        [DllImport("user32.dll", SetLastError = true)]
        static extern uint SendInput(uint count, Input[] inputs, int size);

        [StructLayout(LayoutKind.Sequential)]
        struct Msg
        {
            public IntPtr Hwnd;
            public uint Message;
            public IntPtr WParam, LParam;
            public uint Time;
            public int X, Y;
        }

        [DllImport("user32.dll")]
        static extern bool PeekMessage(out Msg msg, IntPtr hwnd, uint filterMin, uint filterMax, uint remove);

        [DllImport("user32.dll")]
        static extern uint MsgWaitForMultipleObjects(uint count, IntPtr[] handles, bool waitAll, uint milliseconds, uint wakeMask);

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

        // True if Ctrl+Alt plus this key types a character on the current layout. Windows treats
        // Ctrl+Alt as AltGr, so e.g. Ctrl+Alt+Q types @ on a German keyboard.
        public static bool TypesCharacterWithAltGr(int vk)
        {
            byte[] keyState = new byte[256];
            keyState[0x11] = 0x80;   // Ctrl
            keyState[0x12] = 0x80;   // Alt
            StringBuilder buffer = new StringBuilder(8);
            // Flag 4: do not change the keyboard state (pending dead keys) of this thread.
            int result = ToUnicode((uint)vk, MapVirtualKey((uint)vk, 0), keyState, buffer, buffer.Capacity, 4);
            return result != 0;   // > 0: characters, -1: dead key
        }

        // Raw bytes of a clipboard format, read directly from its HGLOBAL; null if the format is
        // missing or larger than maxBytes. WinForms' DataObject.GetData deserializes custom formats
        // with BinaryFormatter - which runs code chosen by whoever put the data on the clipboard -
        // so custom formats must only be read with this method.
        public static byte[] ReadFormatBytes(object dataObject, string formatName, int maxBytes)
        {
            ComDataObject data = dataObject as ComDataObject;
            if (data == null) return null;

            FORMATETC format = new FORMATETC();
            format.cfFormat = unchecked((short)DataFormats.GetFormat(formatName).Id);
            format.dwAspect = DVASPECT.DVASPECT_CONTENT;
            format.lindex = -1;
            format.tymed = TYMED.TYMED_HGLOBAL;
            if (data.QueryGetData(ref format) != 0) return null;

            STGMEDIUM medium;
            try
            {
                data.GetData(ref format, out medium);
            }
            catch (COMException)
            {
                return null;
            }

            try
            {
                if (medium.tymed != TYMED.TYMED_HGLOBAL || medium.unionmember == IntPtr.Zero) return null;
                ulong size = GlobalSize(medium.unionmember).ToUInt64();
                if (size > (ulong)maxBytes) return null;

                IntPtr pointer = GlobalLock(medium.unionmember);
                if (pointer == IntPtr.Zero) return null;
                try
                {
                    byte[] bytes = new byte[size];
                    Marshal.Copy(pointer, bytes, 0, bytes.Length);
                    return bytes;
                }
                finally
                {
                    GlobalUnlock(medium.unionmember);
                }
            }
            finally
            {
                ReleaseStgMedium(ref medium);
            }
        }

        // Brings a window to the foreground. Tries the plain way first, which works whenever this
        // process may set the foreground window: it is in front, or it just received the hotkey or
        // a tray icon click. Only if that is refused, it attaches to the input queue of the
        // foreground thread - a fallback, because attaching can confuse that thread's keyboard
        // focus (seen with rich text boxes): the window then refuses to be activated again later.
        public static string LastActivation;   // "already", "plain", "attached" or "failed" - for the log

        public static bool ForceForeground(IntPtr hwnd)
        {
            LastActivation = "failed";
            for (int attempt = 0; attempt < 3; attempt++)
            {
                if (GetForegroundWindow() == hwnd)
                {
                    LastActivation = attempt == 0 ? "already" : "attached";
                    return true;
                }

                BringWindowToTop(hwnd);
                if (SetForegroundWindow(hwnd) && WaitForForeground(hwnd, 100))
                {
                    LastActivation = "plain";
                    return true;
                }

                // Attach to the foreground thread - or, if Windows has no foreground window at the
                // moment (an activation got stuck), to the target window's thread.
                IntPtr current = GetForegroundWindow();
                uint unused;
                uint otherThread = GetWindowThreadProcessId(current != IntPtr.Zero ? current : hwnd, out unused);
                uint thisThread = GetCurrentThreadId();
                bool attached = otherThread != 0 && otherThread != thisThread
                                && AttachThreadInput(thisThread, otherThread, true);
                try
                {
                    BringWindowToTop(hwnd);
                    SetForegroundWindow(hwnd);
                }
                finally
                {
                    if (attached) AttachThreadInput(thisThread, otherThread, false);
                }
                if (WaitForForeground(hwnd, 100))
                {
                    LastActivation = "attached";
                    return true;
                }
            }
            return false;
        }

        // Activation can complete a moment later (GetForegroundWindow returns null meanwhile).
        static bool WaitForForeground(IntPtr hwnd, int milliseconds)
        {
            int end = Environment.TickCount + milliseconds;
            while (GetForegroundWindow() != hwnd)
            {
                if (Environment.TickCount - end >= 0) return false;
                Wait(10);
            }
            return true;
        }

        // Waits, but keeps answering messages that other threads send to this one. Activating a
        // window of another program can depend on that: a rich text box there (Outlook, Word, ...)
        // coordinates its keyboard focus with the thread that had it before - this one. Posted
        // messages (input, timers, hotkeys) are not processed, so nothing in the app runs meanwhile.
        public static void Wait(int milliseconds)
        {
            const uint QS_SENDMESSAGE = 0x0040;
            const uint PM_NOREMOVE_QS_SENDMESSAGE = 0x00400000;
            int end = Environment.TickCount + milliseconds;
            int left = milliseconds;
            while (left > 0)
            {
                MsgWaitForMultipleObjects(0, null, false, (uint)left, QS_SENDMESSAGE);
                Msg msg;
                PeekMessage(out msg, IntPtr.Zero, 0, 0, PM_NOREMOVE_QS_SENDMESSAGE);   // handles sent messages
                left = end - Environment.TickCount;
            }
        }

        // Sends Ctrl+V to the target window. Waits (max. 1 s) until the user has released Shift,
        // Ctrl, Alt, Win and Enter - otherwise it would become e.g. Ctrl+Shift+V, or a held Enter
        // would repeat into the target - then checks again that the target is in the foreground and
        // sends the four key events as one sequence that user input cannot interleave.
        // Returns false if nothing was sent.
        public static bool PasteInto(IntPtr target)
        {
            int[] keys = { 0x10, 0x11, 0x12, 0x5B, 0x5C, 0x0D };   // Shift, Ctrl, Alt, LWin, RWin, Enter
            for (int i = 0; i < 100 && AnyKeyDown(keys); i++) Wait(10);
            if (AnyKeyDown(keys) || GetForegroundWindow() != target) return false;

            Input[] inputs =
            {
                KeyInput(0x11, false), KeyInput(0x56, false), KeyInput(0x56, true), KeyInput(0x11, true)
            };
            return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(Input))) == inputs.Length;
        }

        static Input KeyInput(ushort vk, bool up)
        {
            Input input = new Input();
            input.Type = 1;   // INPUT_KEYBOARD
            input.Data.Keyboard.VirtualKey = vk;
            input.Data.Keyboard.ScanCode = (ushort)MapVirtualKey(vk, 0);
            input.Data.Keyboard.Flags = up ? 0x0002u : 0u;   // KEYEVENTF_KEYUP
            return input;
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
