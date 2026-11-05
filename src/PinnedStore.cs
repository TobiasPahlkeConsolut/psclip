// psclip: The pinned entries in a file (-KeepPinned), encrypted for the Windows user.
// Compiled with the other src\*.cs files at startup (Add-Type) as C# 5 - see AGENTS.md. ASCII only.

using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace PsClip
{
    // A small binary format of its own - texts with their formatting, images as PNG with their
    // recognized text - encrypted with DPAPI for the current Windows user: the key comes from the user's
    // Windows account, so only that account can read the file (not other users, not a copy of the file
    // on another PC). Programs running as the same user could decrypt it, like they could read
    // psclip's memory. No general-purpose deserializer (BinaryFormatter, CliXml) reads the file, so
    // even a manipulated one only ever yields strings and PNG bytes.
    public static class PinnedStore
    {
        const string Header = "psclip pinned entries";
        const int FormatVersion = 1;

        // Mixed into the encryption: data that another program encrypted for the same user with DPAPI
        // cannot be passed off as this file, nor the other way round.
        static readonly byte[] Entropy = Encoding.ASCII.GetBytes("psclip.pinned.v1");

        // Writes the entries, or deletes the file when there are none.
        public static void Save(string path, IList<ClipEntry> entries)
        {
            if (entries.Count == 0)
            {
                File.Delete(path);   // no error when there is no file
                return;
            }
            byte[] data = ProtectedData.Protect(Serialize(entries), Entropy, DataProtectionScope.CurrentUser);
            // Written next to the file first, then swapped in: a crash or power cut while writing leaves the
            // previous version, never half a file. Flushed to the disk before the swap - otherwise the swap
            // could be on the disk after a power cut while the new content is not.
            string temp = path + ".tmp";
            using (FileStream stream = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None, 4096,
                FileOptions.WriteThrough))
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
        }

        // The saved entries, or none when there is no file. Throws
        // - an IOException or UnauthorizedAccessException when the file cannot be opened - maybe only for the
        //   moment, e.g. while a backup program or virus scanner reads it;
        // - an InvalidDataException (with a short message for the user) when it can be opened but not read:
        //   another Windows account's or computer's file (the key does not fit), a password reset by an
        //   administrator, damage, a newer format.
        public static List<ClipEntry> Load(string path, int thumbnailHeight)
        {
            if (!File.Exists(path)) return new List<ClipEntry>();
            byte[] data = File.ReadAllBytes(path);
            byte[] plain;
            try
            {
                plain = ProtectedData.Unprotect(data, Entropy, DataProtectionScope.CurrentUser);
            }
            catch (CryptographicException e)
            {
                throw new InvalidDataException("It belongs to another Windows account or computer, or is damaged.", e);
            }
            try
            {
                return Deserialize(plain, thumbnailHeight);
            }
            catch (InvalidDataException)
            {
                throw;
            }
            catch (Exception e)
            {
                // E.g. an EndOfStreamException - an IOException, but nothing that goes away by itself.
                throw new InvalidDataException("The file is damaged.", e);
            }
        }

        public static byte[] Serialize(IList<ClipEntry> entries)
        {
            using (MemoryStream stream = new MemoryStream())
            using (BinaryWriter writer = new BinaryWriter(stream, Encoding.UTF8))
            {
                writer.Write(Header);
                writer.Write(FormatVersion);
                writer.Write(entries.Count);
                foreach (ClipEntry entry in entries)
                {
                    writer.Write(entry.Copied.ToBinary());
                    writer.Write(entry.IsImage);
                    if (entry.IsImage)
                    {
                        writer.Write(entry.Png.Length);
                        writer.Write(entry.Png);
                        WriteText(writer, entry.OcrText);   // null = not recognized yet: done again after loading
                    }
                    else
                    {
                        WriteText(writer, entry.Text);
                        WriteText(writer, entry.Html);
                        WriteText(writer, entry.Rtf);
                    }
                }
                writer.Flush();
                return stream.ToArray();
            }
        }

        public static List<ClipEntry> Deserialize(byte[] data, int thumbnailHeight)
        {
            using (MemoryStream stream = new MemoryStream(data))
            using (BinaryReader reader = new BinaryReader(stream, Encoding.UTF8))
            {
                if (reader.ReadString() != Header)
                {
                    throw new InvalidDataException("This is not a file of pinned entries.");
                }
                int version = reader.ReadInt32();
                if (version != FormatVersion)
                {
                    throw new InvalidDataException("The file was saved by another version of psclip (format " +
                        version + ").");
                }
                int count = reader.ReadInt32();
                List<ClipEntry> entries = new List<ClipEntry>();
                for (int i = 0; i < count; i++)
                {
                    DateTime copied = DateTime.FromBinary(reader.ReadInt64());
                    ClipEntry entry;
                    if (reader.ReadBoolean())
                    {
                        entry = ClipEntry.FromPng(ReadBytes(reader, reader.ReadInt32()), thumbnailHeight);
                        entry.OcrText = ReadText(reader);
                    }
                    else
                    {
                        string text = ReadText(reader);
                        if (text == null) throw new InvalidDataException("The file contains an entry without text.");
                        entry = new ClipEntry(text);
                        entry.Html = ReadText(reader);
                        entry.Rtf = ReadText(reader);
                    }
                    entry.Copied = copied;
                    entries.Add(entry);
                }
                return entries;
            }
        }

        // Strings as raw UTF-16: unlike an encoding, this gives back every string exactly, also one with
        // a lone surrogate (which can be copied) - the entry must stay the same text (SameContent).
        static void WriteText(BinaryWriter writer, string value)
        {
            if (value == null)
            {
                writer.Write(-1);
                return;
            }
            byte[] bytes = new byte[value.Length * 2];
            Buffer.BlockCopy(value.ToCharArray(), 0, bytes, 0, bytes.Length);
            writer.Write(value.Length);
            writer.Write(bytes);
        }

        static string ReadText(BinaryReader reader)
        {
            int length = reader.ReadInt32();
            if (length < 0) return null;
            byte[] bytes = ReadBytes(reader, 2L * length);
            char[] chars = new char[length];
            Buffer.BlockCopy(bytes, 0, chars, 0, bytes.Length);
            return new string(chars);
        }

        // Checks the length against the data left first: a damaged length must not allocate gigabytes.
        static byte[] ReadBytes(BinaryReader reader, long count)
        {
            Stream stream = reader.BaseStream;
            if (count < 0 || count > stream.Length - stream.Position)
            {
                throw new InvalidDataException("The file is incomplete or damaged.");
            }
            return reader.ReadBytes((int)count);
        }
    }
}
