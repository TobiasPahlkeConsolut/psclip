// psclip: Where the text cursor (caret) of another program is - to open the popup there.
// Compiled with the other src\*.cs files at startup (Add-Type) as C# 5 - see AGENTS.md. ASCII only.

using System;
using System.Drawing;
using System.Runtime.InteropServices;
using Accessibility;

namespace PsClip
{
    // Asks the program in front for its text cursor: first as the system caret (classic text boxes,
    // rich edit, Office), then as the accessible caret object that browsers and Electron apps offer
    // for screen magnifiers. Programs that report neither (e.g. terminals) give Rectangle.Empty.
    public static class Caret
    {
        [StructLayout(LayoutKind.Sequential)]
        struct NativeRect
        {
            public int Left, Top, Right, Bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct NativePoint
        {
            public int X, Y;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct GuiThreadInfo
        {
            public int Size;
            public uint Flags;
            public IntPtr Active, Focus, Capture, MenuOwner, MoveSize, CaretWindow;
            public NativeRect CaretRect;
        }

        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
        [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint threadId, ref GuiThreadInfo info);
        [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr hwnd, ref NativePoint point);
        [DllImport("user32.dll")] static extern bool IsHungAppWindow(IntPtr hwnd);

        [DllImport("oleacc.dll")]
        static extern int AccessibleObjectFromWindow(IntPtr hwnd, uint objectId, ref Guid iid,
            [MarshalAs(UnmanagedType.Interface)] out object accessible);

        const uint ObjectIdCaret = 0xFFFFFFF8;   // OBJID_CARET
        static readonly Guid AccessibleId = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");   // IAccessible

        // Screen rectangle of the text cursor in the thread of the window, or Rectangle.Empty.
        public static Rectangle Find(IntPtr window)
        {
            uint processId;
            uint thread = GetWindowThreadProcessId(window, out processId);
            if (thread == 0) return Rectangle.Empty;
            GuiThreadInfo info = new GuiThreadInfo();
            info.Size = Marshal.SizeOf(typeof(GuiThreadInfo));
            if (!GetGUIThreadInfo(thread, ref info)) return Rectangle.Empty;

            NativeRect rect = info.CaretRect;
            if (info.CaretWindow != IntPtr.Zero && rect.Bottom > rect.Top)
            {
                NativePoint topLeft = new NativePoint();
                topLeft.X = rect.Left;
                topLeft.Y = rect.Top;
                if (ClientToScreen(info.CaretWindow, ref topLeft))
                {
                    int width = Math.Max(1, rect.Right - rect.Left);
                    return new Rectangle(topLeft.X, topLeft.Y, width, rect.Bottom - rect.Top);
                }
            }
            return FromAccessible(info.Focus != IntPtr.Zero ? info.Focus : window);
        }

        // The window's accessible caret object (OBJID_CARET). Not for a hung window: asking it would
        // wait for it.
        public static Rectangle FromAccessible(IntPtr window)
        {
            if (window == IntPtr.Zero || IsHungAppWindow(window)) return Rectangle.Empty;
            object found = null;
            try
            {
                Guid id = AccessibleId;
                if (AccessibleObjectFromWindow(window, ObjectIdCaret, ref id, out found) != 0) return Rectangle.Empty;
                IAccessible caret = found as IAccessible;
                if (caret == null) return Rectangle.Empty;
                int left, top, width, height;
                caret.accLocation(out left, out top, out width, out height, 0);   // 0 = the object itself
                if (height <= 0) return Rectangle.Empty;   // no text cursor right now
                return new Rectangle(left, top, Math.Max(1, width), height);
            }
            catch (Exception)
            {
                return Rectangle.Empty;   // the program does not offer it
            }
            finally
            {
                if (found != null && Marshal.IsComObject(found)) Marshal.ReleaseComObject(found);
            }
        }
    }
}
