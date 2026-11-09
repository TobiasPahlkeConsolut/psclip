// psclip: Writing psclip's own files (pinned entries, settings) so that an interruption never leaves half a file.
// Compiled with the other src\*.cs files at startup (Add-Type) as C# 5 - see AGENTS.md. ASCII only.

using System;
using System.IO;

namespace PsClip
{
    public static class SafeFile
    {
        // Written next to the file first, then swapped in: a crash or power cut while writing leaves the previous
        // version, never half a file. Flushed to the disk before the swap - otherwise the swap could be on the disk
        // after a power cut while the new content is not.
        public static void Write(string path, byte[] data)
        {
            string temp = path + ".tmp";
            RetryWhileInUse(delegate
            {
                using (FileStream stream = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None,
                    4096, FileOptions.WriteThrough))
                {
                    stream.Write(data, 0, data.Length);
                    stream.Flush(true);
                }
                if (File.Exists(path))
                {
                    File.Replace(temp, path, null);
                }
                else
                {
                    File.Move(temp, path);
                }
            });
        }

        public static byte[] Read(string path)
        {
            byte[] data = null;
            RetryWhileInUse(delegate { data = File.ReadAllBytes(path); });
            return data;
        }

        public static void Delete(string path)
        {
            RetryWhileInUse(delegate { File.Delete(path); });   // no error when there is no file
        }

        public static void Move(string path, string newPath)
        {
            RetryWhileInUse(delegate { File.Move(path, newPath); });
        }

        // A virus scanner or backup program may hold the file for a moment - typically right after it was written,
        // so the next write fails now and then. Such a sharing violation is tried again a few times (at most about
        // 0.4 s) before it counts; any other error counts at once.
        static void RetryWhileInUse(Action action)
        {
            for (int attempt = 1; ; attempt++)
            {
                try
                {
                    action();
                    return;
                }
                catch (IOException e)
                {
                    int code = e.HResult & 0xFFFF;
                    bool inUse = code == 32 || code == 33;   // ERROR_SHARING_VIOLATION, ERROR_LOCK_VIOLATION
                    if (!inUse || attempt >= InUseAttempts) throw;
                }
                System.Threading.Thread.Sleep(40 * attempt);
            }
        }

        const int InUseAttempts = 5;
    }
}
