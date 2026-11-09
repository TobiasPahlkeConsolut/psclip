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

        // A virus scanner, backup program or editor may hold the file for a moment - typically right after it was
        // written, so the next write fails now and then. That is tried again a few times (at most about 0.4 s) before
        // it counts; any other error counts at once. Each attempt writes the temporary file anew, so it also recovers
        // from a File.Replace that got halfway (the old file then no longer exists, and the new one is moved).
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
                    if (!IsInUse(e) || attempt >= InUseAttempts) throw;
                }
                System.Threading.Thread.Sleep(40 * attempt);
            }
        }

        // Errors that mean "another program has the file open right now".
        public static bool IsInUse(IOException e)
        {
            switch (e.HResult & 0xFFFF)
            {
                case 32:     // ERROR_SHARING_VIOLATION
                case 33:     // ERROR_LOCK_VIOLATION
                case 1175:   // ERROR_UNABLE_TO_REMOVE_REPLACED - File.Replace: someone opened the old file meanwhile
                case 1176:   // ERROR_UNABLE_TO_MOVE_REPLACEMENT
                case 1177:   // ERROR_UNABLE_TO_MOVE_REPLACEMENT_2
                    return true;
                default:
                    return false;
            }
        }

        const int InUseAttempts = 5;
    }
}
