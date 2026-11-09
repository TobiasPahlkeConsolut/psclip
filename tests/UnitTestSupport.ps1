<#
.SYNOPSIS
    Shared setup of the unit tests (*.Tests.ps1): loads the app's functions and builds test state.

.DESCRIPTION
    Dot-sourced at the start of every test file. Controls are created but never shown; clipboard data is
    built in memory with [DataObject].
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Used by the test files that dot-source this one')]
param()

# Load the functions without starting the app (see the guard at the start of "#region Main").
. (Join-Path $PSScriptRoot '..\ClipboardManager.ps1')

if (-not ('PsClipTest.ComForwarder' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices.ComTypes;

namespace PsClipTest
{
    // A plain COM IDataObject in front of a DataObject: WinForms then reads it through COM (an
    // OleConverter) like the real clipboard, with that path's conversions and fallbacks.
    public class ComForwarder : IDataObject
    {
        readonly IDataObject inner;
        public ComForwarder(IDataObject inner) { this.inner = inner; }
        public int DAdvise(ref FORMATETC f, ADVF a, IAdviseSink s, out int c)
        {
            return inner.DAdvise(ref f, a, s, out c);
        }
        public void DUnadvise(int c) { inner.DUnadvise(c); }
        public int EnumDAdvise(out IEnumSTATDATA e) { return inner.EnumDAdvise(out e); }
        public IEnumFORMATETC EnumFormatEtc(DATADIR d) { return inner.EnumFormatEtc(d); }
        public int GetCanonicalFormatEtc(ref FORMATETC i, out FORMATETC o)
        {
            return inner.GetCanonicalFormatEtc(ref i, out o);
        }
        public void GetData(ref FORMATETC f, out STGMEDIUM m) { inner.GetData(ref f, out m); }
        public void GetDataHere(ref FORMATETC f, ref STGMEDIUM m) { inner.GetDataHere(ref f, ref m); }
        public int QueryGetData(ref FORMATETC f) { return inner.QueryGetData(ref f); }
        public void SetData(ref FORMATETC f, ref STGMEDIUM m, bool r) { inner.SetData(ref f, ref m, r); }
    }

    // Counts how often BinaryFormatter recreates it - another program's clipboard data must never be deserialized.
    [System.Serializable]
    public class DeserializationCanary : System.Runtime.Serialization.ISerializable
    {
        public static int Deserialized;
        public DeserializationCanary() { }
        protected DeserializationCanary(System.Runtime.Serialization.SerializationInfo info,
            System.Runtime.Serialization.StreamingContext context)
        {
            Deserialized++;
        }
        public void GetObjectData(System.Runtime.Serialization.SerializationInfo info,
            System.Runtime.Serialization.StreamingContext context) { }
    }

    // A DataObject that notes which formats are read from it
    public class RecordingDataObject : System.Windows.Forms.DataObject
    {
        public readonly System.Collections.Generic.List<string> Read = new System.Collections.Generic.List<string>();
        public override object GetData(string format, bool autoConvert)
        {
            Read.Add(format);
            return base.GetData(format, autoConvert);
        }
    }

    public static class FileLock
    {
        // Holds a file open without sharing for a while, released by another thread - like a virus scanner.
        public static void HoldFor(string path, int milliseconds)
        {
            System.IO.FileStream stream = System.IO.File.Open(path, System.IO.FileMode.Open,
                System.IO.FileAccess.Read, System.IO.FileShare.None);
            System.Threading.Thread thread = new System.Threading.Thread(delegate ()
            {
                System.Threading.Thread.Sleep(milliseconds);
                stream.Dispose();
            });
            thread.IsBackground = true;
            thread.Start();
        }
    }
}
'@ -ReferencedAssemblies System.Windows.Forms
}

function New-OleData {
    # Clipboard data as the real clipboard delivers it (through COM), see ComForwarder.
    param([System.Windows.Forms.DataObject]$Inner)
    [System.Windows.Forms.DataObject]::new([PsClipTest.ComForwarder]::new($Inner))
}

# Some tests depend on the keyboard layout: the o-umlaut is on the Oemtilde key on German layouts.
$germanLayout = [PsClip.Native]::VirtualKeyOf([char]0xF6) -eq 0xC0
$upperUmlaut = [string][char]0xD6

function Reset-TestState {
    # Minimal $State / $Ui as built by the Main region, with stand-ins for the tray controls.
    $script:State = @{
        History              = [System.Collections.Generic.List[PsClip.ClipEntry]]::new()
        Pinned               = [System.Collections.Generic.List[PsClip.ClipEntry]]::new()
        KeepPinned           = $false
        PinnedFile           = $null
        PinnedSaveFailed     = $false
        Filtered            = [System.Collections.Generic.List[PsClip.ClipEntry]]::new()
        FilteredPinnedCount  = 0
        FoundCount           = 0
        MemoryLimit          = '100MB'
        OwnClipboardSequence = 0
        ClipboardRetry       = @{ Sequence = 0; Count = 0 }
        PasteTarget         = [IntPtr]::Zero
        HotkeySpec          = [pscustomobject]@{ Modifiers = 6; VirtualKey = 0x56 }
        HotkeyText          = 'Ctrl+Shift+V'
        HotkeyActive        = $true
        ThemeSetting        = 'Dark'
        PopupSize           = 'M'
        OpenAt              = 'Mouse'
        PreviewVisible      = $false
        PreviewDefault      = $false
        PreviewTextShare    = 0.3
        PreviewEntry        = $null
        FilterTerms         = [string[]]@()
        EditEntry           = $null
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
        ClipboardTimer  = [pscustomobject]@{ Enabled = $false }
        ThumbnailHeight = 22
    }
    $script:MemoryLimits = [ordered]@{ '100MB' = 100MB; '500MB' = 500MB; '1GB' = 1GB }
    $script:MaxListItems = 1000
    $script:MaxEntryLength = 1000000
    $script:MaxImageBytes = 50MB
    $script:MaxPreviewLength = 100000
    $script:KeepAwakeSeconds = 30
}

function Set-TestMemoryLimit {
    # A tiny memory limit in bytes: a text entry of n characters needs 100 + 2n bytes (ClipEntry.Size).
    param([long]$Bytes)
    $script:MemoryLimits = [ordered]@{ Test = $Bytes; Large = 1GB }
    $State.MemoryLimit = 'Test'
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
    [PsClip.ClipEntry]::FromImage((New-TestImage -Width $Width -Height $Height -Color $Color), 22)
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
