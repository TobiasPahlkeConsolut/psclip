# psclip: Dark and light mode of the popup and the menus.
# Dot-sourced by ClipboardManager.ps1: shares its $State, $Ui and settings (see AGENTS.md).

using namespace System.Collections.Generic
using namespace System.Drawing
using namespace System.Windows.Forms


function Test-DarkTheme {
    if ($State.ThemeSetting -eq 'Dark') { return $true }
    if ($State.ThemeSetting -eq 'Light') { return $false }

    try {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        return (Get-ItemPropertyValue $key -Name AppsUseLightTheme) -eq 0
    }
    catch {
        return $false
    }
}

function Set-Theme {
    param([bool]$Dark)

    if ($State.IsDark -eq $Dark) { return }
    $State.IsDark = $Dark
    $colors = if ($Dark) { $Palettes.Dark } else { $Palettes.Light }
    $State.Colors = $colors

    foreach ($gdiObject in $State.Gdi.Values) { $gdiObject.Dispose() }
    $State.Gdi = @{
        Back      = [SolidBrush]::new($colors.Back)
        SelBack   = [SolidBrush]::new($colors.SelBack)
        Separator = [Pen]::new($colors.Border)
    }

    $Ui.Form.BackColor = $colors.Back
    $Ui.SearchPanel.BackColor = $colors.Input
    $Ui.Search.BackColor = $colors.Input
    $Ui.Search.ForeColor = $colors.Text
    $Ui.List.BackColor = $colors.Back
    $Ui.List.ForeColor = $colors.Text
    $Ui.Status.BackColor = $colors.Back
    $Ui.Status.ForeColor = $colors.Muted
    $Ui.Preview.BackColor = $colors.Input
    $Ui.PreviewInfo.ForeColor = $colors.Muted
    $Ui.PreviewText.BackColor = $colors.Input
    $Ui.PreviewText.ForeColor = $colors.Text
    $Ui.PreviewImage.BackColor = $colors.Input
    $Ui.PreviewSplitter.BackColor = $colors.Border
    $Ui.PreviewTextSplitter.BackColor = $colors.Border
    [PsClip.Native]::SetDarkTitleBar($Ui.Form.Handle, $Dark)
    [PsClip.Native]::SetDarkControlTheme($Ui.List.Handle, $Dark)
    [PsClip.Native]::SetDarkControlTheme($Ui.PreviewText.Handle, $Dark)

    # Submenus are separate drop-downs and need their own renderer.
    foreach ($menu in $Ui.TrayMenu, $Ui.SizeMenuItem.DropDown, $Ui.ListMenu, $Ui.PreviewMenu) {
        $menu.Renderer = [PsClip.MenuRenderer]::new($colors.Back, $colors.Hover, $colors.Border, $colors.Text)
        $menu.BackColor = $colors.Back
        $menu.ForeColor = $colors.Text
    }
    $Ui.List.Invalidate()
}

function Switch-DarkMode {
    $State.ThemeSetting = if ($State.IsDark) { 'Light' } else { 'Dark' }
    Set-Theme (Test-DarkTheme)
}
