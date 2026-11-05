// psclip: One history entry: a text with its formatting, or an image.
// Compiled with the other src\*.cs files at startup (Add-Type) as C# 5 - see AGENTS.md. ASCII only.

using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;

namespace PsClip
{
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
}
