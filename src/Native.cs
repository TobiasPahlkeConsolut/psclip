// psclip: Win32 calls: clipboard formats, foreground window, keyboard input, idle time.
// Compiled with the other src\*.cs files at startup (Add-Type) as C# 5 - see AGENTS.md. ASCII only.

using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using System.Windows.Forms;
using ComDataObject = System.Runtime.InteropServices.ComTypes.IDataObject;

namespace PsClip
{
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
        [DllImport("user32.dll")] static extern bool IsClipboardFormatAvailable(uint format);
        [DllImport("user32.dll")] static extern IntPtr GetOpenClipboardWindow();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterClipboardFormat(string name);
        [DllImport("dwmapi.dll")]
        static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
        [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr handle);
        [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr handle);
        [DllImport("kernel32.dll")] static extern UIntPtr GlobalSize(IntPtr handle);
        [DllImport("ole32.dll")] static extern void ReleaseStgMedium(ref STGMEDIUM medium);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern int ToUnicode(uint vk, uint scanCode, byte[] keyState, StringBuilder buffer, int bufferSize,
            uint flags);

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
        static extern uint MsgWaitForMultipleObjects(uint count, IntPtr[] handles, bool waitAll, uint milliseconds,
            uint wakeMask);

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
        // Whether the clipboard holds text or an image that is not marked private - asked without opening the
        // clipboard, so it also works while another program has it open. A read that found nothing although this
        // says there is something was refused by such a program (Teams, remote desktop clients read every change).
        public static bool ClipboardHasTextOrImage()
        {
            foreach (string marker in new string[] { "ExcludeClipboardContentFromMonitorProcessing",
                "Clipboard Viewer Ignore", "CanIncludeInClipboardHistory" })
            {
                if (IsClipboardFormatAvailable(RegisterClipboardFormat(marker))) return false;
            }
            return IsClipboardFormatAvailable(13 /* CF_UNICODETEXT */) || IsClipboardFormatAvailable(8 /* CF_DIB */) ||
                IsClipboardFormatAvailable(2 /* CF_BITMAP */) ||
                IsClipboardFormatAvailable(RegisterClipboardFormat("PNG"));
        }

        [DllImport("ole32.dll")]
        static extern int OleGetClipboard(out ComDataObject data);

        // The clipboard's content as Windows Forms reads it (a DataObject over the OLE clipboard, the same as
        // Clipboard.GetDataObject returns). While another program has the clipboard open, it tries again every 10 ms,
        // for at most timeoutMs: Clipboard.GetDataObject waits 100 ms between its tries, and psclip handles nothing
        // else meanwhile - a next copy can replace this one, which psclip then never sees. waitedMs: the time it took.
        public static System.Windows.Forms.IDataObject GetClipboardData(int timeoutMs, out int waitedMs)
        {
            Application.OleRequired();   // OLE on this thread, as Clipboard.GetDataObject makes sure of
            ComDataObject data = null;
            int result = RetryWhileFailing(delegate { return OleGetClipboard(out data); }, timeoutMs, 10, out waitedMs);
            if (result != 0) Marshal.ThrowExceptionForHR(result);
            return data == null ? null : new DataObject(data);
        }

        // Calls attempt until it returns S_OK (0), waiting stepMs between the tries (answering sent messages, see
        // Wait), at most timeoutMs in all; returns the last result. waitedMs: the time it took.
        public static int RetryWhileFailing(Func<int> attempt, int timeoutMs, int stepMs, out int waitedMs)
        {
            int start = Environment.TickCount;
            while (true)
            {
                int result = attempt();
                waitedMs = Environment.TickCount - start;
                if (result == 0 || waitedMs >= timeoutMs) return result;
                Wait(stepMs);
            }
        }

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
            // Programs that watch the clipboard (Teams, remote desktop clients) open it right after psclip put the
            // entry there; a Ctrl+V meanwhile finds it busy and pastes nothing. So wait until nobody holds it open
            // (at most 0.3 s - pasting then is still better than not pasting).
            for (int i = 0; i < 30 && GetOpenClipboardWindow() != IntPtr.Zero; i++) Wait(10);
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
