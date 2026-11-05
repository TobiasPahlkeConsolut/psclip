<#
.SYNOPSIS
    Shared setup of the unit tests (*.Tests.ps1): loads the app's functions and builds test state.

.DESCRIPTION
    Dot-sourced at the start of every test file. Controls are created but never shown; clipboard data is
    built in memory with [DataObject].
#>

# Load the functions without starting the app (see the guard at the start of "#region Main").
. (Join-Path $PSScriptRoot '..\ClipboardManager.ps1')

# Some tests depend on the keyboard layout: the o-umlaut is on the Oemtilde key on German layouts.
$germanLayout = [PsClip.Native]::VirtualKeyOf([char]0xF6) -eq 0xC0
$upperUmlaut = [string][char]0xD6

function Reset-TestState {
    # Minimal $State / $Ui as built by the Main region, with stand-ins for the tray controls.
    $script:State = @{
        History              = [System.Collections.Generic.List[PsClip.ClipEntry]]::new()
        Pinned               = [System.Collections.Generic.List[PsClip.ClipEntry]]::new()
        Filtered             = [System.Collections.Generic.List[PsClip.ClipEntry]]::new()
        FilteredPinnedCount  = 0
        OwnClipboardSequence = 0
        PasteTarget         = [IntPtr]::Zero
        HotkeySpec          = [pscustomobject]@{ Modifiers = 6; VirtualKey = 0x56 }
        HotkeyText          = 'Ctrl+Shift+V'
        HotkeyActive        = $true
        ThemeSetting        = 'Dark'
        PopupSize           = 'M'
        PreviewVisible      = $false
        PreviewTextShare    = 0.3
        KeepAwake           = $false
        OcrQueue            = [System.Collections.Generic.Queue[PsClip.ClipEntry]]::new()
        OcrJob              = $null
        IsDark              = $null
        Colors              = $null
        Gdi                 = @{}
    }
    $script:Ui = @{
        Form            = [pscustomobject]@{ Visible = $false }
        HotkeyMenuItem  = [pscustomobject]@{ Text = '' }
        Tray            = [pscustomobject]@{ Text = '' }
        KeepAwakeTimer  = [pscustomobject]@{ Enabled = $false }
        ThumbnailHeight = 22
    }
    $script:MaxItems = 200
    $script:MaxImages = 20
    $script:MaxEntryLength = 1000000
    $script:KeepAwakeSeconds = 30
}

function Add-Entries {
    param([string[]]$Texts)
    foreach ($text in $Texts) { Add-ClipboardEntry ([PsClip.ClipEntry]::new($text)) }
}

function Get-Entry {
    # The entry with this text from the pinned entries or the history.
    param([string]$Text)
    foreach ($entry in @($State.Pinned) + @($State.History)) {
        if ($entry.Text -ceq $Text) { return $entry }
    }
    throw "No entry '$Text'"
}

function New-FormattedEntry {
    param([string]$Text, [string]$Rtf = $null, [string]$Html = $null)
    $entry = [PsClip.ClipEntry]::new($Text)
    $entry.Rtf = $Rtf
    $entry.Html = $Html
    $entry
}

function New-TestImage {
    # A plain-colored bitmap; different colors give different images.
    param([int]$Width = 40, [int]$Height = 20, [string]$Color = 'SteelBlue')
    $bitmap = [System.Drawing.Bitmap]::new($Width, $Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([System.Drawing.Color]::FromName($Color))
    $graphics.Dispose()
    $bitmap
}

function New-ImageEntry {
    param([string]$Color = 'SteelBlue', [int]$Width = 40, [int]$Height = 20)
    [PsClip.ClipEntry]::FromImage((New-TestImage $Width $Height $Color), 22)
}

function New-KeyEvent {
    param([System.Windows.Forms.Keys]$KeyData)
    [System.Windows.Forms.KeyEventArgs]::new($KeyData)
}

function New-ClipHostStub {
    # Records the calls instead of registering hotkeys with Windows.
    $stub = [pscustomobject]@{ Calls = [System.Collections.Generic.List[string]]::new() }
    $stub | Add-Member -MemberType ScriptMethod -Name ClearHotkey -Value { $this.Calls.Add('clear') }
    $stub | Add-Member -MemberType ScriptMethod -Name SetHotkey -Value {
        param($modifiers, $key)
        $this.Calls.Add("set $modifiers $key")
        $true
    }
    $stub
}
