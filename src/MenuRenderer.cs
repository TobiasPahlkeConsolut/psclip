// psclip: Colors and renderer for the context menus in dark and light mode.
// Compiled with the other src\*.cs files at startup (Add-Type) as C# 5 - see AGENTS.md. ASCII only.

using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace PsClip
{
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
}
