# psclip: Hotkeys: parsing and checking key combinations, registering them, the "Change hotkey" dialog.
# Dot-sourced by ClipboardManager.ps1: shares its $State, $Ui and settings (see AGENTS.md).

using namespace System.Collections.Generic
using namespace System.Drawing
using namespace System.Windows.Forms


function ConvertFrom-HotkeyText {
    # 'Ctrl+Shift+V' -> modifier flags and virtual key code for RegisterHotKey
    param([string]$Text)

    $modifiers = 0
    $key = $null
    foreach ($part in (($Text -split '\+').Trim() | Where-Object { $_ })) {
        if ($HotkeyModifiers.ContainsKey($part)) {
            $modifiers = $modifiers -bor $HotkeyModifiers[$part]
            continue
        }
        if ($null -ne $key) { throw "Hotkey '$Text' contains more than one key." }
        $key = ConvertTo-Key $part
    }
    if ($null -eq $key) { throw "Hotkey '$Text' has no key, only modifiers." }

    $problem = Get-HotkeyProblem -Modifiers $modifiers -Key $key
    if ($problem) { throw "Hotkey '$Text': $problem" }

    [pscustomobject]@{ Modifiers = [uint32]$modifiers; VirtualKey = [uint32]$key }
}

function ConvertTo-Key {
    # 'V', 'F12', 'Oemtilde', '1' or the character printed on a key (e.g. an umlaut) -> [Keys]
    param([string]$Name)

    $keyName = if ($Name -match '^\d$') { "D$Name" } else { $Name }   # '1' -> Keys.D1
    # Enum.Parse would also accept numbers ('65') and lists ('Shift, V'): only plain names here.
    if ($keyName -match '^[A-Za-z][A-Za-z0-9]*$') {
        try {
            $key = [Keys][Enum]::Parse([Keys], $keyName, $true)   # ignore case: 'f12' = 'F12'
            if (Test-KeyUsable $key) { return $key }
        }
        catch {
            # Not a [Keys] name - maybe a character.
        }
    }
    if ($Name.Length -eq 1) {
        $virtualKey = [PsClip.Native]::VirtualKeyOf($Name[0])
        if ($virtualKey -ge 0) { return [Keys]$virtualKey }
    }
    throw ("Unknown key '$Name'. Use a System.Windows.Forms.Keys name such as V, F12 or Space, " +
        'or the character on the key.')
}

function Test-KeyUsable {
    # A single real key: no mouse button, no modifier key on its own, no modifier flags (> 0xFF).
    param([Keys]$Key)

    $modifierKeys = [Keys]::ShiftKey, [Keys]::ControlKey, [Keys]::Menu, [Keys]::LWin, [Keys]::RWin,
        [Keys]::LShiftKey, [Keys]::RShiftKey, [Keys]::LControlKey, [Keys]::RControlKey, [Keys]::LMenu, [Keys]::RMenu
    [int]$Key -ge 8 -and [int]$Key -le 0xFF -and $Key -notin $modifierKeys
}

function Get-HotkeyProblem {
    # Why a combination would get in the way of normal typing, or $null if it is fine.
    param([uint32]$Modifiers, [Keys]$Key)

    if ($Modifiers -eq 0) {
        if ($Key -eq [Keys]::F12) { return 'F12 alone is reserved by Windows for debuggers.' }
        if ($Key -lt [Keys]::F1 -or $Key -gt [Keys]::F24) {
            return 'add Ctrl, Alt, Shift or Win - a plain key would block typing.'
        }
        return $null
    }

    $typesCharacter = $Key -eq [Keys]::Space -or [PsClip.Native]::CharacterOf([int]$Key) -ne [char]0
    if ($Modifiers -eq $HotkeyModifiers.Shift -and $typesCharacter) {
        return 'Shift plus this key types a character - the hotkey would block it.'
    }
    $ctrlAlt = $HotkeyModifiers.Ctrl -bor $HotkeyModifiers.Alt
    if ($Modifiers -eq $ctrlAlt -and [PsClip.Native]::TypesCharacterWithAltGr([int]$Key)) {
        return 'Ctrl+Alt is AltGr, which types a character with this key - the hotkey would block it.'
    }
    return $null
}

function Get-KeyDisplayName {
    # The character printed on OEM keys (an umlaut instead of 'Oemtilde' on a German keyboard),
    # digits without the 'D', otherwise the [Keys] name.
    param([Keys]$Key)

    $name = [string]$Key
    if ($name -match '^D\d$') { return $name.Substring(1) }
    if ($name -like 'Oem*') {
        $character = ([string][PsClip.Native]::CharacterOf([int]$Key)).ToUpper()
        # Only if it maps back to the same key; '+' would clash with the separator.
        if ($character.Length -eq 1 -and $character -ne "`0" -and $character -ne '+' -and
            [PsClip.Native]::VirtualKeyOf($character[0]) -eq [int]$Key) {
            return $character
        }
    }
    return $name
}

function Format-HotkeySpec {
    # Display text of a parsed hotkey, e.g. 'Ctrl+Shift+V', or 'Ctrl+' + umlaut for Ctrl+Oemtilde
    # on a German keyboard.
    param($Spec)

    $parts = @()
    foreach ($modifier in 'Ctrl', 'Alt', 'Shift', 'Win') {
        if ($Spec.Modifiers -band $HotkeyModifiers[$modifier]) { $parts += $modifier }
    }
    $parts += Get-KeyDisplayName ([Keys]$Spec.VirtualKey)
    $parts -join '+'
}

function Format-HotkeyText {
    # Normalized display text, e.g. 'ctrl+shift+v' -> 'Ctrl+Shift+V'
    param([string]$Text)
    Format-HotkeySpec (ConvertFrom-HotkeyText $Text)
}

function ConvertTo-HotkeyText {
    # Builds 'Ctrl+Shift+V' from a KeyDown event; returns $null while only modifiers are pressed.
    param([KeyEventArgs]$KeyEvent)

    $modifierKeys = [Keys]::ShiftKey, [Keys]::ControlKey, [Keys]::Menu, [Keys]::LWin, [Keys]::RWin
    if ($KeyEvent.KeyCode -in $modifierKeys) { return $null }

    $parts = @()
    if ($KeyEvent.Control) { $parts += 'Ctrl' }
    if ($KeyEvent.Alt) { $parts += 'Alt' }
    if ($KeyEvent.Shift) { $parts += 'Shift' }
    if ([PsClip.Native]::IsKeyDown(0x5B) -or [PsClip.Native]::IsKeyDown(0x5C)) { $parts += 'Win' }
    $parts += Get-KeyDisplayName $KeyEvent.KeyCode
    $parts -join '+'
}

function Register-Hotkey {
    # Takes a parsed hotkey (ConvertFrom-HotkeyText). Returns $false if the combination is
    # already used by another program.
    param($Spec)

    if (-not $Ui.ClipHost.SetHotkey($Spec.Modifiers, $Spec.VirtualKey)) { return $false }

    # Keep the key code, not the text: the text depends on the current keyboard layout.
    $State.HotkeySpec = $Spec
    $State.HotkeyText = Format-HotkeySpec $Spec
    $State.HotkeyActive = $true
    Write-Verbose "Hotkey $($State.HotkeyText) registered."
    return $true
}

function Edit-Hotkey {
    Set-Theme (Test-DarkTheme)
    $wasActive = $State.HotkeyActive
    $Ui.ClipHost.ClearHotkey()   # so that the current combination can be pressed in the dialog
    $State.HotkeyActive = $false

    try {
        if (-not (Show-HotkeyDialog) -and $wasActive) {
            [void](Register-Hotkey $State.HotkeySpec)   # cancelled: restore the previous hotkey
        }
    }
    finally {
        Update-TrayText
    }
}

function Show-HotkeyDialog {
    # Modal dialog that captures a key combination and registers it. Returns $true on success.
    $colors = $State.Colors
    $scale = $Ui.Scale
    $pad = [int](12 * $scale)
    $gap = [int](6 * $scale)
    $width = [int](380 * $scale)

    $form = [Form]::new()
    $form.Text = 'Change hotkey'
    $form.FormBorderStyle = 'FixedToolWindow'
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.AutoScaleMode = 'None'
    $form.Font = $Ui.Font
    $form.BackColor = $colors.Back
    $form.ForeColor = $colors.Text

    $prompt = [Label]::new()
    $prompt.Text = 'Press the new key combination:'
    $prompt.AutoSize = $true
    $prompt.Location = [Point]::new($pad, $pad)

    $keyBox = [TextBox]::new()
    $keyBox.ReadOnly = $true
    $keyBox.BorderStyle = 'FixedSingle'
    $keyBox.BackColor = $colors.Input
    $keyBox.ForeColor = $colors.Text
    $keyBox.Text = $State.HotkeyText
    $keyBox.Location = [Point]::new($pad, $pad + $prompt.PreferredHeight + $gap)
    $keyBox.Width = $width - 2 * $pad

    $hint = [Label]::new()
    $hint.AutoSize = $false
    $hint.ForeColor = $colors.Muted
    $hint.Text = 'Ctrl, Alt, Shift or Win plus a key, or an F-key alone.'
    $hint.Location = [Point]::new($pad, $keyBox.Bottom + $gap)
    $hint.Size = [Size]::new($width - 2 * $pad, $Ui.Font.Height * 2)

    $buttonSize = [Size]::new([int](88 * $scale), [int](30 * $scale))
    $buttonTop = $hint.Bottom + $gap
    $cancel = New-FlatButton -Text 'Cancel' -Size $buttonSize `
        -Location ([Point]::new($width - $pad - $buttonSize.Width, $buttonTop))
    $ok = New-FlatButton -Text 'OK' -Size $buttonSize `
        -Location ([Point]::new($cancel.Left - $gap - $buttonSize.Width, $buttonTop))
    $ok.Enabled = $false
    $cancel.DialogResult = 'Cancel'

    $form.CancelButton = $cancel
    $form.ClientSize = [Size]::new($width, $buttonTop + $buttonSize.Height + $pad)
    $form.Controls.AddRange([Control[]]@($prompt, $keyBox, $hint, $ok, $cancel))

    # The handlers run during ShowDialog, while the variables of this function still exist.
    $dialogControls = @{
        Form        = $form
        KeyBox      = $keyBox
        Hint        = $hint
        Ok          = $ok
        Pending     = $null   # parsed hotkey waiting for OK
        PendingText = $null
    }

    $keyBox.add_PreviewKeyDown({
        param($source, $e)
        $e.IsInputKey = $true   # also capture Tab, arrows, ...
    })
    $keyBox.add_KeyDown({
        param($source, $e)
        Update-HotkeyDialog -Dialog $dialogControls -KeyEvent $e
    })
    $ok.add_Click({
        if (Register-Hotkey $dialogControls.Pending) {
            $dialogControls.Form.DialogResult = 'OK'
        }
        else {
            $dialogControls.Hint.Text =
                "$($dialogControls.PendingText) is already used by another program. Try another one."
            $dialogControls.Ok.Enabled = $false
        }
    })
    $form.add_Shown({
        [void][PsClip.Native]::ForceForeground($dialogControls.Form.Handle)
        $dialogControls.Form.Activate()
        [void]$dialogControls.KeyBox.Focus()
    })

    [PsClip.Native]::SetDarkTitleBar($form.Handle, $State.IsDark)
    $result = $form.ShowDialog()
    $form.Dispose()
    return ($result -eq [DialogResult]::OK)
}

function Update-HotkeyDialog {
    # KeyDown in the hotkey dialog: shows the pressed combination, Enter applies, Esc cancels.
    param([hashtable]$Dialog, [KeyEventArgs]$KeyEvent)

    $KeyEvent.Handled = $true
    $KeyEvent.SuppressKeyPress = $true

    $text = ConvertTo-HotkeyText $KeyEvent
    if (-not $text) { return }

    if ($text -eq 'Escape') {
        $Dialog.Form.DialogResult = 'Cancel'
        return
    }
    if ($text -eq 'Return') {
        if ($Dialog.Ok.Enabled) { $Dialog.Ok.PerformClick() }
        return
    }

    # Same rules as for the -Hotkey parameter (ConvertFrom-HotkeyText).
    $Dialog.KeyBox.Text = $text
    try {
        $Dialog.Pending = ConvertFrom-HotkeyText $text
    }
    catch {
        $Dialog.Pending = $null
        $Dialog.Hint.Text = $_.Exception.Message
        $Dialog.Ok.Enabled = $false
        return
    }
    $Dialog.PendingText = $text
    $Dialog.Hint.Text = 'Press Enter or click OK to apply.'
    $Dialog.Ok.Enabled = $true
}

function New-FlatButton {
    param([string]$Text, [Point]$Location, [Size]$Size)

    $button = [Button]::new()
    $button.Text = $Text
    $button.Location = $Location
    $button.Size = $Size
    $button.FlatStyle = 'Flat'
    $button.BackColor = $State.Colors.Input
    $button.ForeColor = $State.Colors.Text
    $button.FlatAppearance.BorderColor = $State.Colors.Border
    $button
}
