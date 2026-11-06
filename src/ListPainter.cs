// psclip: Draws the text of a list row - two lines at most, with the filter's words highlighted.
// Compiled with the other src\*.cs files at startup (Add-Type) as C# 5 - see AGENTS.md. ASCII only.

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Text;

namespace PsClip
{
    public static class ListPainter
    {
        // GDI+ measures where the words are (MeasureCharacterRanges) - so it also draws the text, with the same
        // layout: word wrap, only whole lines that fit (two in a row), "..." where the text is cut off.
        public static void DrawText(Graphics graphics, string text, Font font, Rectangle bounds, Color textColor,
            Color highlight, string[] terms)
        {
            if (string.IsNullOrEmpty(text)) return;
            using (StringFormat format = new StringFormat(StringFormatFlags.LineLimit))
            {
                format.Trimming = StringTrimming.EllipsisCharacter;
                format.LineAlignment = StringAlignment.Center;
                format.HotkeyPrefix = System.Drawing.Text.HotkeyPrefix.None;

                List<CharacterRange> matches = FindMatches(text, terms, MaxHighlights);
                if (matches.Count > 0)
                {
                    format.SetMeasurableCharacterRanges(matches.ToArray());
                    Region[] regions = graphics.MeasureCharacterRanges(text, font, bounds, format);
                    using (SolidBrush brush = new SolidBrush(highlight))
                    {
                        foreach (Region region in regions)
                        {
                            graphics.FillRegion(brush, region);
                            region.Dispose();
                        }
                    }
                }

                graphics.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;   // the row background is opaque
                using (SolidBrush brush = new SolidBrush(textColor))
                {
                    graphics.DrawString(text, font, brush, bounds, format);
                }
            }
        }

        // MeasureCharacterRanges takes at most 32 ranges
        const int MaxHighlights = 32;

        // Where the terms occur in the text - case-insensitive like the filter (ClipEntry.Matches) - as sorted,
        // non-overlapping ranges, at most max of them.
        public static List<CharacterRange> FindMatches(string text, string[] terms, int max)
        {
            List<int[]> spans = new List<int[]>();
            if (terms != null)
            {
                foreach (string term in terms)
                {
                    if (string.IsNullOrEmpty(term)) continue;
                    int index = text.IndexOf(term, StringComparison.OrdinalIgnoreCase);
                    while (index >= 0)
                    {
                        spans.Add(new int[] { index, index + term.Length });
                        index = text.IndexOf(term, index + term.Length, StringComparison.OrdinalIgnoreCase);
                    }
                }
            }
            spans.Sort(delegate (int[] a, int[] b) { return a[0].CompareTo(b[0]); });

            List<CharacterRange> ranges = new List<CharacterRange>();
            int start = -1, end = -1;
            foreach (int[] span in spans)
            {
                if (span[0] <= end)
                {
                    end = Math.Max(end, span[1]);   // overlapping or touching: one range
                    continue;
                }
                if (start >= 0) ranges.Add(new CharacterRange(start, end - start));
                start = span[0];
                end = span[1];
            }
            if (start >= 0) ranges.Add(new CharacterRange(start, end - start));
            if (ranges.Count > max) ranges.RemoveRange(max, ranges.Count - max);
            return ranges;
        }
    }
}
