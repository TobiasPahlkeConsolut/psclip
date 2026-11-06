// psclip: One history entry: a text with its formatting, or an image.
// Compiled with the other src\*.cs files at startup (Add-Type) as C# 5 - see AGENTS.md. ASCII only.

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace PsClip
{
    // One history entry: a text with the formatting it was copied with - or an image.
    // The per-entry work of the list (filter, list line, size) is done here, not in PowerShell: the
    // history is limited by memory, not by count, and may hold many thousands of entries.
    public sealed class ClipEntry
    {
        public string Html;          // "HTML Format" (CF_HTML), or null
        public string Rtf;           // Rich Text Format, or null
        public byte[] Png;           // images: the image, PNG-compressed (in memory only)
        public int Width, Height;    // images: size in pixels
        public Bitmap Thumbnail;     // images: small version for the list
        public DateTime Copied;
        string text;
        string ocrText;
        string listText;             // cached line for the list
        string imageHash;
        long thumbnailBytes;

        static readonly Regex LineBreaks = new Regex("\r\n?|\n");
        static readonly Regex Blanks = new Regex("[ \t]+");

        public ClipEntry(string text)
        {
            this.text = text;
            Copied = DateTime.Now;
        }

        // null for images
        public string Text
        {
            get { return text; }
            set { text = value; listText = null; }
        }

        // Images: the recognized text; null = not (yet) recognized, "" = none found
        public string OcrText
        {
            get { return ocrText; }
            set { ocrText = value; listText = null; }
        }

        public static ClipEntry FromImage(Image image, int thumbnailHeight)
        {
            byte[] png;
            using (MemoryStream stream = new MemoryStream())
            {
                image.Save(stream, ImageFormat.Png);
                png = stream.ToArray();
            }
            return NewImageEntry(png, image, thumbnailHeight);
        }

        // An image entry from saved PNG bytes (PinnedStore). The bytes are kept as they are, so the
        // entry is the same image (SameContent) as the one that was saved.
        public static ClipEntry FromPng(byte[] png, int thumbnailHeight)
        {
            using (MemoryStream stream = new MemoryStream(png))
            using (Image image = Image.FromStream(stream))
            {
                return NewImageEntry(png, image, thumbnailHeight);
            }
        }

        static ClipEntry NewImageEntry(byte[] png, Image image, int thumbnailHeight)
        {
            ClipEntry entry = new ClipEntry(null);
            entry.Png = png;
            entry.Width = image.Width;
            entry.Height = image.Height;
            using (System.Security.Cryptography.SHA256 sha = System.Security.Cryptography.SHA256.Create())
            {
                entry.imageHash = Convert.ToBase64String(sha.ComputeHash(png));
            }
            entry.Thumbnail = CreateThumbnail(image, thumbnailHeight);
            entry.thumbnailBytes = 4L * entry.Thumbnail.Width * entry.Thumbnail.Height;   // 32 bits per pixel
            return entry;
        }

        // Approximate memory use in bytes: strings are UTF-16, plus the PNG and the thumbnail.
        public long Size
        {
            get
            {
                long chars = LengthOf(text) + LengthOf(Html) + LengthOf(Rtf) + LengthOf(ocrText);
                return 100 + 2 * chars + (Png == null ? 0 : Png.Length) + thumbnailBytes;
            }
        }

        public static long TotalSize(IEnumerable<ClipEntry> entries)
        {
            long total = 0;
            foreach (ClipEntry entry in entries) total += entry.Size;
            return total;
        }

        static long LengthOf(string value)
        {
            return value == null ? 0 : value.Length;
        }

        // What the filter searches: the text, or for an image the word "image" and the text recognized in it.
        public string SearchText
        {
            get { return IsImage ? "image " + ocrText : text; }
        }

        // True if the search text contains every term (case-insensitive).
        public bool Matches(string[] terms)
        {
            string searchText = SearchText ?? string.Empty;
            foreach (string term in terms)
            {
                if (searchText.IndexOf(term, StringComparison.OrdinalIgnoreCase) < 0) return false;
            }
            return true;
        }

        // The entries that contain every term, in their order.
        public static List<ClipEntry> Filter(IEnumerable<ClipEntry> entries, string[] terms)
        {
            List<ClipEntry> found = new List<ClipEntry>();
            foreach (ClipEntry entry in entries)
            {
                if (entry.Matches(terms)) found.Add(entry);
            }
            return found;
        }

        // The line shown in the list: the start of the text, or for an image its size and the start of
        // the recognized text. Cached; changing Text or OcrText renews it.
        public string ListText
        {
            get
            {
                if (listText == null)
                {
                    if (!IsImage)
                    {
                        listText = FormatListText(text, "\n");
                    }
                    else
                    {
                        listText = "Image " + Width + " \u00D7 " + Height;
                        // The recognized text on the second line
                        if (!string.IsNullOrEmpty(ocrText)) listText += "\n" + FormatListText(ocrText, " ");
                    }
                }
                return listText;
            }
        }

        // The list lines of the entries, for ListBox.Items.AddRange.
        public static object[] ListTexts(IList<ClipEntry> entries)
        {
            object[] texts = new object[entries.Count];
            for (int i = 0; i < texts.Length; i++) texts[i] = entries[i].ListText;
            return texts;
        }

        // One line for the list: line breaks shown as a mark, runs of blanks as one. Looks only at the
        // start of the text - entries can be megabytes long.
        // The start of a text for the list, which shows two lines of each entry (ListPainter): its lines without
        // indentation, empty lines and runs of blanks, joined with lineSeparator ("\n": a line of its own).
        public static string FormatListText(string value, string lineSeparator)
        {
            if (value == null) return string.Empty;
            int first = 0;
            while (first < value.Length && char.IsWhiteSpace(value[first])) first++;
            // Only the start shows: two lines
            string start = value.Substring(first, Math.Min(2000, value.Length - first));
            StringBuilder result = new StringBuilder();
            foreach (string line in LineBreaks.Split(start))
            {
                string trimmed = Blanks.Replace(line, " ").Trim();
                if (trimmed.Length == 0) continue;
                if (result.Length > 0) result.Append(lineSeparator);
                result.Append(trimmed);
                if (result.Length >= MaxListTextLength) break;
            }
            return result.Length > MaxListTextLength ? result.ToString(0, MaxListTextLength) : result.ToString();
        }

        const int MaxListTextLength = 300;   // more than two lines of the widest popup hold

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
            return IsImage ? "Image " + Width + " x " + Height : text;
        }
    }
}
