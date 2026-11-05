# psclip: Building the popup window, the menus and the tray icon.
# Dot-sourced by ClipboardManager.ps1: shares its $State, $Ui and settings (see AGENTS.md).

using namespace System.Collections.Generic
using namespace System.Drawing
using namespace System.Windows.Forms


function Initialize-Ui {
    [void][PsClip.Native]::SetProcessDPIAware()
    [Application]::EnableVisualStyles()
    try {
        [Application]::SetCompatibleTextRenderingDefault($false)
    }
    catch {
        # Only possible before the first window of the process; harmless when it fails.
    }
    [Application]::add_ThreadException({
        param($source, $e)
        Write-Warning "Error in event handler: $($e.Exception.Message)"
    })

    $graphics = [Graphics]::FromHwnd([IntPtr]::Zero)
    $Ui.Scale = $graphics.DpiX / 96.0
    $graphics.Dispose()

    $Ui.Font = [Font]::new('Segoe UI', 10)
    $Ui.SmallFont = [Font]::new('Segoe UI', 8.5)
    $Ui.PinFont = [Font]::new('Segoe MDL2 Assets', 9)
    $Ui.PinGlyph = [string][char]0xE718
    if ($Ui.PinFont.Name -ne 'Segoe MDL2 Assets') {
        # Icon font not installed: fall back to a plain asterisk.
        $Ui.PinFont = $Ui.Font
        $Ui.PinGlyph = '*'
    }
    $Ui.PinColumn = [int](26 * $Ui.Scale)
    $Ui.Padding = [int](8 * $Ui.Scale)
}

function Initialize-ControlHandles {
    # Creates the windows of all child controls, in the order of their Controls collections.
    # WinForms creates the window of a hidden control only when it is first shown, and then moves
    # the control in its parent's collection to match the window order - which is also the docking
    # order. The preview (hidden at first) would end up above its drag bar.
    param([Control]$Parent)

    foreach ($child in @($Parent.Controls)) {
        [void]$child.Handle
        Initialize-ControlHandles $child
    }
}

function New-PopupWindow {
    $scale = $Ui.Scale

    $form = [Form]::new()
    $form.Text = 'Clipboard history'
    $form.FormBorderStyle = 'SizableToolWindow'
    $form.StartPosition = 'Manual'
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.KeyPreview = $true
    $form.AutoScaleMode = 'None'
    $form.Font = $Ui.Font
    $form.MinimumSize = [Size]::new([int](300 * $scale), [int](200 * $scale))

    $search = [TextBox]::new()
    $search.Dock = 'Top'
    $search.BorderStyle = 'None'

    $searchPanel = [Panel]::new()
    $searchPanel.Dock = 'Top'
    $searchPanel.Padding = [Padding]::new($Ui.PinColumn, $Ui.Padding, $Ui.Padding, $Ui.Padding)
    $searchPanel.Height = $search.PreferredHeight + 2 * $Ui.Padding
    $searchPanel.Controls.Add($search)

    $list = [ListBox]::new()
    $list.Dock = 'Fill'
    $list.IntegralHeight = $false
    $list.BorderStyle = 'None'
    $list.DrawMode = 'OwnerDrawFixed'
    $list.ItemHeight = $Ui.Font.Height + [int](10 * $scale)
    $Ui.ThumbnailHeight = $list.ItemHeight - [int](6 * $scale)
    $list.ContextMenuStrip = New-ListMenu

    $status = [Label]::new()
    $status.Dock = 'Bottom'
    $status.AutoSize = $false
    $status.Font = $Ui.SmallFont
    $status.Height = [int]($Ui.SmallFont.Height * 1.8)
    $status.TextAlign = 'MiddleLeft'
    $status.Padding = [Padding]::new([int](4 * $scale), 0, 0, 0)

    # Preview (F3) between list and status line: an info line, then the text or the image
    $preview = [Panel]::new()
    $preview.Dock = 'Bottom'
    $preview.Height = [int]($PreviewHeight * $scale)
    $preview.Padding = [Padding]::new($Ui.PinColumn, [int]($Ui.Padding / 2), $Ui.Padding, $Ui.Padding)
    $preview.Visible = $State.PreviewVisible

    $previewInfo = [Label]::new()
    $previewInfo.Dock = 'Top'
    $previewInfo.AutoSize = $false
    $previewInfo.Font = $Ui.SmallFont
    $previewInfo.Height = [int]($Ui.SmallFont.Height * 1.7)
    $previewInfo.TextAlign = 'MiddleLeft'

    # Text can be selected and copied (Ctrl+C, context menu), e.g. a part of the text recognized in an image.
    $previewText = [TextBox]::new()
    $previewText.Dock = 'Fill'
    $previewText.Multiline = $true
    $previewText.ReadOnly = $true
    $previewText.WordWrap = $true
    $previewText.ScrollBars = 'Vertical'
    $previewText.BorderStyle = 'None'
    $previewText.TabStop = $false
    $previewText.HideSelection = $false
    $previewText.ContextMenuStrip = New-PreviewMenu

    $previewImage = [PictureBox]::new()
    $previewImage.Dock = 'Fill'
    $previewImage.SizeMode = 'Zoom'
    $previewImage.Visible = $false

    # Drag bars: one at the top edge of the preview resizes the whole preview, one between an image
    # and its recognized text divides the preview between them (both until the popup closes). A
    # splitter resizes the control on its far side (for Dock Bottom: the one directly below it).
    # Their window texts let tests and accessibility tools find them.
    $previewTextSplitter = [Splitter]::new()
    $previewTextSplitter.Dock = 'Bottom'
    $previewTextSplitter.Height = [int](5 * $scale)
    $previewTextSplitter.MinSize = [int](20 * $scale)     # smallest text
    $previewTextSplitter.MinExtra = [int](30 * $scale)    # smallest image
    $previewTextSplitter.Text = 'Preview text size'
    $previewTextSplitter.Visible = $false

    $previewSplitter = [Splitter]::new()
    $previewSplitter.Dock = 'Bottom'
    $previewSplitter.Height = [int](5 * $scale)
    $previewSplitter.MinSize = [int](60 * $scale)         # smallest preview
    $previewSplitter.MinExtra = $list.ItemHeight * 2      # the list keeps at least two rows
    $previewSplitter.Text = 'Preview size'
    $previewSplitter.Visible = $State.PreviewVisible

    # Docking runs in reverse order of adding: info at the top, then the text (Fill for text
    # entries, Bottom below an image), the bar above it, and the image fills the rest.
    $preview.Controls.Add($previewImage)
    $preview.Controls.Add($previewTextSplitter)
    $preview.Controls.Add($previewText)
    $preview.Controls.Add($previewInfo)

    # Same here: status line at the bottom, the preview above it, its bar above the preview, the
    # search box at the top; the list (Fill, added first) takes the rest.
    $form.Controls.Add($list)
    $form.Controls.Add($searchPanel)
    $form.Controls.Add($previewSplitter)
    $form.Controls.Add($preview)
    $form.Controls.Add($status)

    $Ui.Form = $form
    $Ui.Search = $search
    $Ui.SearchPanel = $searchPanel
    $Ui.List = $list
    $Ui.Status = $status
    $Ui.Preview = $preview
    $Ui.PreviewInfo = $previewInfo
    $Ui.PreviewText = $previewText
    $Ui.PreviewImage = $previewImage
    $Ui.PreviewSplitter = $previewSplitter
    $Ui.PreviewTextSplitter = $previewTextSplitter
    Reset-PopupSize

    [void]$form.Handle   # create the window now so that BeginInvoke works before the first Show
    Initialize-ControlHandles $form
    [PsClip.Native]::SetCueBanner($search.Handle, 'Type to filter...')

    # Event handlers run after this function has returned: use $Ui / $State, not local variables.
    $search.add_TextChanged({ if ($Ui.Form.Visible) { Update-PopupList } })   # Hide-Popup empties it
    $list.add_SelectedIndexChanged({ Update-Preview })
    $form.add_Resize({ if ($Ui.Form.Visible) { Update-StatusText } })
    $preview.add_Resize({ Update-PreviewTextHeight })
    # The splitter sets the preview's bounds while the form is laying out; the preview's own
    # content (text, image) is only arranged again when asked explicitly.
    $previewSplitter.add_SplitterMoved({
        Update-PreviewTextHeight
        $Ui.Preview.PerformLayout()
    })
    $previewTextSplitter.add_SplitterMoved({ Save-PreviewTextShare })
    $previewText.add_KeyDown({
        param($source, $e)
        # Ctrl+A selects all (multi-line text boxes do not do that by themselves); Ctrl+C copies natively.
        if ($e.Control -and $e.KeyCode -eq [Keys]::A) {
            $Ui.PreviewText.SelectAll()
            $e.SuppressKeyPress = $true
        }
    })
    $previewText.add_KeyPress({
        param($source, $e)
        # Typing a character continues in the filter box.
        if (-not [char]::IsControl($e.KeyChar)) {
            [void]$Ui.Search.Focus()
            $Ui.Search.AppendText([string]$e.KeyChar)
            $e.Handled = $true
        }
    })
    $list.add_DrawItem({
        param($source, $e)
        Write-ListItem $e
    })
    $list.add_MouseDoubleClick({
        param($source, $e)
        if ($Ui.List.IndexFromPoint($e.Location) -ge 0) { Invoke-SelectedEntry }
    })
    $list.add_MouseDown({
        param($source, $e)
        if ($e.Button -eq 'Right') {
            # Select the entry under the mouse before the context menu opens.
            $index = $Ui.List.IndexFromPoint($e.Location)
            if ($index -ge 0) { $Ui.List.SelectedIndex = $index }
        }
    })
    $list.add_MouseUp({
        param($source, $e)
        if ($e.Button -eq 'Left') { [void]$Ui.Search.Focus() }   # keep typing going to the filter box
    })
    $form.add_KeyDown({
        param($source, $e)
        Invoke-PopupKey $e
    })
    $form.add_Deactivate({ Hide-Popup })
    $form.add_FormClosing({
        param($source, $e)
        if ($e.CloseReason -eq 'UserClosing') {
            $e.Cancel = $true   # the close button only hides the popup
            Hide-Popup
        }
    })
}

function New-ListMenu {
    $menu = [ContextMenuStrip]::new()

    $Ui.ListMenuUse = $menu.Items.Add('Paste')
    $Ui.ListMenuUse.ShortcutKeyDisplayString = 'Enter'
    $Ui.ListMenuUse.add_Click({ Invoke-SelectedEntry })

    $Ui.ListMenuPlain = $menu.Items.Add('Paste as plain text')
    $Ui.ListMenuPlain.ShortcutKeyDisplayString = 'Shift+Enter'
    $Ui.ListMenuPlain.add_Click({ Invoke-SelectedEntry -PlainText })

    $Ui.ListMenuPin = $menu.Items.Add('Pin to top')
    $Ui.ListMenuPin.ShortcutKeyDisplayString = 'Ctrl+P'
    $Ui.ListMenuPin.add_Click({
        Switch-SelectedPin
        [void]$Ui.Search.Focus()
    })

    $remove = $menu.Items.Add('Remove')
    $remove.ShortcutKeyDisplayString = 'Shift+Del'
    $remove.add_Click({
        Remove-SelectedEntry
        [void]$Ui.Search.Focus()
    })

    [void]$menu.Items.Add([ToolStripSeparator]::new())
    $Ui.ListMenuPreview = $menu.Items.Add('Preview')
    $Ui.ListMenuPreview.ShortcutKeyDisplayString = 'F3'
    $Ui.ListMenuPreview.add_Click({
        Switch-Preview
        [void]$Ui.Search.Focus()
    })

    $menu.add_Opening({
        param($source, $e)
        $entry = Get-SelectedEntry
        if ($null -eq $entry) {
            $e.Cancel = $true
            return
        }
        $verb = if ($State.PasteTarget -ne [IntPtr]::Zero) { 'Paste' } else { 'Copy' }
        $Ui.ListMenuUse.Text = $verb
        $Ui.ListMenuPlain.Text = "$verb as plain text"
        $Ui.ListMenuPlain.Visible = $entry.HasFormatting   # same as the normal paste otherwise
        $Ui.ListMenuPin.Text = if ($State.Pinned.Contains($entry)) { 'Unpin' } else { 'Pin to top' }
        $Ui.ListMenuPreview.Checked = $State.PreviewVisible
    })

    $Ui.ListMenu = $menu
    return $menu
}

function New-PreviewMenu {
    # Context menu of the preview text: copy a part of it, e.g. of the text recognized in an image.
    $menu = [ContextMenuStrip]::new()

    $Ui.PreviewMenuCopy = $menu.Items.Add('Copy')
    $Ui.PreviewMenuCopy.ShortcutKeyDisplayString = 'Ctrl+C'
    $Ui.PreviewMenuCopy.add_Click({ $Ui.PreviewText.Copy() })

    $selectAll = $menu.Items.Add('Select all')
    $selectAll.ShortcutKeyDisplayString = 'Ctrl+A'
    $selectAll.add_Click({ $Ui.PreviewText.SelectAll() })

    $menu.add_Opening({ $Ui.PreviewMenuCopy.Enabled = $Ui.PreviewText.SelectionLength -gt 0 })
    $Ui.PreviewMenu = $menu
    return $menu
}

function New-TrayIcon {
    $menu = [ContextMenuStrip]::new()
    $menu.Items.Add('Show history').add_Click({ Show-PopupLater })
    $menu.Items.Add('Clear history (keeps pinned)').add_Click({ Clear-ClipboardHistory })
    [void]$menu.Items.Add([ToolStripSeparator]::new())

    $Ui.HotkeyMenuItem = $menu.Items.Add('Change hotkey...')
    $Ui.HotkeyMenuItem.add_Click({ [void]$Ui.Form.BeginInvoke([Action] { Edit-Hotkey }) })

    $Ui.DarkModeMenuItem = $menu.Items.Add('Dark mode')
    $Ui.DarkModeMenuItem.add_Click({ Switch-DarkMode })

    $Ui.SizeMenuItem = [ToolStripMenuItem]::new('Window size')
    $sizeOptions = @{ Tag = 'S'; Text = 'Small' }, @{ Tag = 'M'; Text = 'Medium' }, @{ Tag = 'L'; Text = 'Large' }
    foreach ($option in $sizeOptions) {
        $item = $Ui.SizeMenuItem.DropDownItems.Add($option.Text)
        $item.Tag = $option.Tag
        $item.add_Click({
            param($source, $e)
            $State.PopupSize = $source.Tag
        })
    }
    [void]$menu.Items.Add($Ui.SizeMenuItem)

    $Ui.OpenAtMenuItem = [ToolStripMenuItem]::new('Open at')
    $openAtOptions = @{ Tag = 'Mouse'; Text = 'Mouse pointer'; Tip = $null },
        @{ Tag = 'TextCursor'; Text = 'Text cursor'; Tip = 'Below the text cursor, if the program reports it' }
    foreach ($option in $openAtOptions) {
        $item = $Ui.OpenAtMenuItem.DropDownItems.Add($option.Text)
        $item.Tag = $option.Tag
        $item.ToolTipText = $option.Tip
        $item.add_Click({
            param($source, $e)
            $State.OpenAt = $source.Tag
            Write-Verbose "Popup opens at: $($source.Tag)."
        })
    }
    $Ui.OpenAtMenuItem.DropDown.ShowItemToolTips = $true
    [void]$menu.Items.Add($Ui.OpenAtMenuItem)

    $Ui.MemoryMenuItem = [ToolStripMenuItem]::new('Memory limit')
    $Ui.MemoryMenuItem.ToolTipText = 'Memory the history may use; the oldest unpinned entries are dropped'
    foreach ($limit in $MemoryLimits.Keys) {
        $item = $Ui.MemoryMenuItem.DropDownItems.Add((Format-MemorySize $MemoryLimits[$limit]))
        $item.Tag = $limit
        $item.add_Click({
            param($source, $e)
            Set-MemoryLimit $source.Tag
        })
    }
    [void]$menu.Items.Add($Ui.MemoryMenuItem)

    $Ui.KeepPinnedMenuItem = $menu.Items.Add('Keep pinned entries')
    $Ui.KeepPinnedMenuItem.ToolTipText = 'Saves the pinned entries encrypted to pinned.dat; loaded at start with ' +
        '-KeepPinned. Off deletes the file'
    $Ui.KeepPinnedMenuItem.add_Click({ Set-KeepPinned (-not $State.KeepPinned) })
    [void]$menu.Items.Add([ToolStripSeparator]::new())

    $Ui.KeepAwakeMenuItem = $menu.Items.Add('Keep awake')
    $Ui.KeepAwakeMenuItem.ToolTipText = "Presses the F15 key after $KeepAwakeSeconds s without mouse or keyboard input"
    $Ui.KeepAwakeMenuItem.add_Click({ Set-KeepAwake (-not $State.KeepAwake) })
    [void]$menu.Items.Add([ToolStripSeparator]::new())

    $menu.Items.Add('Exit').add_Click({ $Ui.AppContext.ExitThread() })
    $menu.ShowItemToolTips = $true
    $menu.add_Opening({ Update-TrayMenu })
    $Ui.TrayMenu = $menu

    $tray = [NotifyIcon]::new()
    $tray.Icon = New-ClipboardIcon
    $tray.ContextMenuStrip = $menu
    $tray.add_MouseClick({
        param($source, $e)
        if ($e.Button -eq 'Left') { Show-PopupLater }
    })
    $Ui.Tray = $tray
}

function Update-TrayMenu {
    # Before the tray menu opens: current theme and check marks.
    Set-Theme (Test-DarkTheme)
    $Ui.DarkModeMenuItem.Checked = $State.IsDark
    foreach ($item in $Ui.SizeMenuItem.DropDownItems) {
        $item.Checked = $item.Tag -eq $State.PopupSize
    }
    foreach ($item in $Ui.OpenAtMenuItem.DropDownItems) {
        $item.Checked = $item.Tag -eq $State.OpenAt
    }
    $Ui.MemoryMenuItem.Text = "Memory limit ($(Format-MemorySize (Get-HistorySize)) used)"
    foreach ($item in $Ui.MemoryMenuItem.DropDownItems) {
        $item.Checked = $item.Tag -eq $State.MemoryLimit
    }
    $Ui.KeepPinnedMenuItem.Checked = $State.KeepPinned
    $Ui.KeepAwakeMenuItem.Checked = $State.KeepAwake
}

function Update-TrayText {
    $hotkeyLabel = if ($State.HotkeyActive) { $State.HotkeyText } else { 'no hotkey' }
    $Ui.HotkeyMenuItem.Text = "Change hotkey ($hotkeyLabel)..."

    $count = $State.Pinned.Count + $State.History.Count
    $entries = if ($count -eq 1) { '1 entry' } else { "$count entries" }
    $text = "Clipboard history: $entries ($hotkeyLabel)"
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }   # NotifyIcon limit
    $Ui.Tray.Text = $text
}

function Show-TrayWarning {
    # A message at the tray icon - psclip has no window of its own to show problems in.
    param([string]$Text)

    # Windows cuts the text after 255 characters - without a sign that something is missing
    if ($Text.Length -gt 255) { $Text = $Text.Substring(0, 254) + [char]0x2026 }
    $Ui.Tray.ShowBalloonTip(8000, 'Clipboard history', $Text, 'Warning')
}

function New-ClipboardIcon {
    # Draws a small clipboard so the tray icon is not confused with other PowerShell windows.
    $iconSize = [SystemInformation]::SmallIconSize.Width
    $u = $iconSize / 16.0

    $bitmap = [Bitmap]::new($iconSize, $iconSize)
    $graphics = [Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = 'AntiAlias'
    $board = [SolidBrush]::new([Color]::FromArgb(43, 108, 176))
    $clip = [SolidBrush]::new([Color]::FromArgb(70, 70, 70))

    $graphics.FillRectangle($board, [float](2 * $u), [float](2 * $u), [float](12 * $u), [float](14 * $u))
    $graphics.FillRectangle([Brushes]::White, [float](4 * $u), [float](5 * $u), [float](8 * $u), [float](9 * $u))
    foreach ($lineY in 7, 9.5, 12) {
        $graphics.FillRectangle($board, [float](5.5 * $u), [float]($lineY * $u), [float](5 * $u), [float]$u)
    }
    $graphics.FillRectangle($clip, [float](5 * $u), [float](0.5 * $u), [float](6 * $u), [float](3.5 * $u))

    $graphics.Dispose()
    $board.Dispose()
    $clip.Dispose()

    # The clone owns its own icon handle, so the temporary one can be released right away.
    $handle = $bitmap.GetHicon()
    $icon = [Icon]([Icon]::FromHandle($handle).Clone())
    [void][PsClip.Native]::DestroyIcon($handle)
    $bitmap.Dispose()
    $icon
}

function Start-ClipboardListener {
    $Ui.ClipHost = [PsClip.ClipboardHost]::new($InstanceName)
    $Ui.ClipHost.add_ClipboardChanged({ Receive-ClipboardChange })
    $Ui.ClipHost.add_HotkeyPressed({ Switch-Popup })
    $Ui.ClipHost.add_CloseRequested({ $Ui.AppContext.ExitThread() })
}
