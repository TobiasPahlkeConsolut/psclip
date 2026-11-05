// psclip: Hidden window that receives clipboard-change notifications and the global hotkey.
// Compiled with the other src\*.cs files at startup (Add-Type) as C# 5 - see AGENTS.md. ASCII only.

using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
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
}
