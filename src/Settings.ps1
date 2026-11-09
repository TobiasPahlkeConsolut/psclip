# psclip: The settings file (settings.ini next to ClipboardManager.ps1): reading, writing, applying changes.
# Dot-sourced by ClipboardManager.ps1: shares its $State, $Ui and settings (see AGENTS.md). Install.ps1 uses it too.

using namespace System.Collections.Generic
using namespace System.Drawing
using namespace System.Windows.Forms


# The file is opt-in: psclip reads it when it exists and then saves the tray menu's changes to it, but only
# Install.ps1 and the tray menu's "Edit settings file..." create it. One setting per line, "Name = value", in the
# order and with the comments of $SettingDefinitions; the tray menu changes only the line of its setting, so the
# user's own comments and order stay. Saving the file in an editor applies the changed settings at once.

function Get-SettingsFilePath {
    # settings.ini next to ClipboardManager.ps1. Another instance (-InstanceName) keeps its own file.
    param([string]$Folder, [string]$Name)

    $file = if ($Name -eq 'PsClipboardManager') { 'settings.ini' } else { "settings-$Name.ini" }
    Join-Path $Folder $file
}

function Get-ParameterSettings {
    # The settings as ClipboardManager.ps1's parameters have them - given, or their defaults. Reads the parameter
    # variables of the script that dot-sourced the part files (also when Install.ps1 dot-sources it in a function).
    @{
        Hotkey           = $Hotkey
        MaxMemory        = $MaxMemory
        MaxEntryLength   = $MaxEntryLength
        Theme            = $Theme
        Size             = $Size
        Font             = $Font
        OpenAt           = $OpenAt
        Preview          = [bool]$Preview
        KeepAwake        = [bool]$KeepAwake
        KeepAwakeSeconds = $KeepAwakeSeconds
        KeepPinned       = [bool]$KeepPinned
    }
}

function Get-StartSettings {
    # The settings psclip starts with: given on the command line, else from the settings file, else the default.
    # All in the file's form (ConvertFrom-SettingText) - so an invalid -Hotkey fails here.
    param([string[]]$Given, $File)   # $File: Read-SettingsFile's result, $null without a file

    $parameters = Get-ParameterSettings
    $settings = @{}
    foreach ($name in $SettingDefinitions.Keys) {
        $settings[$name] = if ($null -ne $File -and $File.Values.ContainsKey($name) -and $Given -notcontains $name) {
            $File.Values[$name]
        }
        else {
            ConvertFrom-SettingText $name (ConvertTo-SettingText $parameters[$name])
        }
    }
    $settings
}

function Get-CurrentSettings {
    # psclip's settings as they are now, in the file's form.
    @{
        Hotkey           = Format-HotkeySetting $State.HotkeySpec
        Theme            = $State.ThemeSetting
        Size             = $State.PopupSize
        Font             = $State.FontName
        OpenAt           = $State.OpenAt
        MaxMemory        = $State.MemoryLimit
        KeepPinned       = [bool]$State.KeepPinned
        Preview          = [bool]$State.PreviewDefault
        KeepAwake        = [bool]$State.KeepAwake
        KeepAwakeSeconds = [int]$State.KeepAwakeSeconds
        MaxEntryLength   = [int]$State.MaxEntryLength
    }
}

function Format-HotkeySetting {
    # A parsed hotkey as the settings file keeps it: key names, not the characters of the current keyboard layout
    # ('Ctrl+Oemtilde', not Ctrl + O-umlaut), so that it means the same key on any layout.
    param($Spec)

    $parts = @()
    foreach ($modifier in 'Ctrl', 'Alt', 'Shift', 'Win') {
        if ($Spec.Modifiers -band $HotkeyModifiers[$modifier]) { $parts += $modifier }
    }
    $key = [string][Keys]$Spec.VirtualKey
    if ($key -match '^D\d$') { $key = $key.Substring(1) }   # Keys.D1 -> '1'
    $parts += $key
    $parts -join '+'
}

function ConvertFrom-SettingText {
    # The value of a setting as written in the file -> psclip's form ('dark' -> 'Dark', 'yes' -> $true, ...).
    # Throws a short message for the user when it is not valid.
    param([string]$Name, [string]$Text)

    $definition = $SettingDefinitions[$Name]
    $type = $definition.Type
    if ($type -eq 'Hotkey') {
        return Format-HotkeySetting (ConvertFrom-HotkeyText $Text)   # with the reason when it is not valid
    }
    if ($type -eq 'Font') {
        $installed = Get-InstalledFontName $Text
        if ($installed) { return $installed }
        throw "Font '$Text' is not installed."
    }
    if ($type -eq 'Choice') {
        $choice = @($definition.Choices) -eq $Text.Trim()   # -eq ignores case
        if ($choice.Count -gt 0) { return [string]$choice[0] }
        $choices = @($definition.Choices)
        $allowed = ($choices[0..($choices.Count - 2)] -join ', ') + ' or ' + $choices[-1]
        throw "$Name '$Text' is not valid - use $allowed."
    }
    if ($type -eq 'Switch') {
        if (@('true', 'yes', 'on', '1') -contains $Text.Trim()) { return $true }
        if (@('false', 'no', 'off', '0') -contains $Text.Trim()) { return $false }
        throw "$Name '$Text' is not valid - use true or false."
    }
    $number = 0
    $parsed = [int]::TryParse($Text.Trim(), [Globalization.NumberStyles]::Integer,
        [Globalization.CultureInfo]::InvariantCulture, [ref]$number)
    if ($parsed -and $number -ge $definition.Minimum -and $number -le $definition.Maximum) { return $number }
    throw "$Name '$Text' is not valid - use a whole number from $($definition.Minimum) to $($definition.Maximum)."
}

function Get-InstalledFontName {
    # The name of an installed font family as Windows writes it ('consolas' -> 'Consolas'), or $null. Fonts installed
    # for the user only count too.
    param([string]$Name)

    $fonts = [System.Drawing.Text.InstalledFontCollection]::new()
    try {
        foreach ($family in $fonts.Families) {
            if ($family.Name -eq $Name.Trim()) { return $family.Name }
        }
    }
    finally {
        $fonts.Dispose()
    }
    $null
}

function ConvertTo-SettingText {
    # A setting's value as the file shows it: true / false, numbers and texts as they are.
    param($Value)

    if ($Value -is [bool] -or $Value -is [switch]) {
        if ($Value) { return 'true' }
        return 'false'
    }
    [string]$Value
}

function ConvertFrom-SettingsText {
    # The lines of a settings file -> Values (valid settings only, the last line of a setting wins) and Problems
    # (one message per line that was ignored). Empty lines and comments (#, ;) are skipped, quotes around a value
    # removed.
    param([string[]]$Lines)

    $values = @{}
    $problems = [List[string]]::new()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i].Trim()
        if ($line -eq '' -or $line[0] -in '#', ';', '[') { continue }
        $at = $line.IndexOf('=')
        if ($at -lt 1) {
            $problems.Add("line $($i + 1): '$line' is not 'Name = value'.")
            continue
        }
        $key = $line.Substring(0, $at).Trim()
        $text = $line.Substring($at + 1).Trim()
        if ($text.Length -ge 2 -and $text[0] -eq '"' -and $text[-1] -eq '"') {
            $text = $text.Substring(1, $text.Length - 2)
        }
        $name = @($SettingDefinitions.Keys) -eq $key   # -eq ignores case
        if ($name.Count -eq 0) {
            $problems.Add("line $($i + 1): there is no setting '$key'.")
            continue
        }
        try {
            $values[$name[0]] = ConvertFrom-SettingText $name[0] $text
        }
        catch {
            $problems.Add("line $($i + 1): $($_.Exception.Message)")
        }
    }
    [pscustomobject]@{ Values = $values; Problems = $problems.ToArray() }
}

function Read-SettingsLines {
    # The lines of the file - UTF-8, or what its byte order mark says (an editor may have saved it so).
    param([string]$Path)

    $bytes = [PsClip.SafeFile]::Read($Path)   # retried while a virus scanner holds it
    $reader = [IO.StreamReader]::new([IO.MemoryStream]::new($bytes), [Text.UTF8Encoding]::new($false), $true)
    try {
        $text = $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }
    if ($text -eq '') { return }
    $lines = $text -split '\r?\n'
    if ($lines[-1] -eq '') { $lines = $lines[0..($lines.Count - 2)] }   # the line break at the end
    $lines
}

function Write-SettingsLines {
    # UTF-8 without byte order mark, Windows line breaks; never half a file (SafeFile).
    param([string]$Path, [string[]]$Lines)

    $text = (@($Lines) -join "`r`n") + "`r`n"
    [PsClip.SafeFile]::Write($Path, [Text.UTF8Encoding]::new($false).GetBytes($text))
}

function Read-SettingsFile {
    # The settings in the file (ConvertFrom-SettingsText), or $null when there is none. Throws when it cannot be
    # read (in use, no access).
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    ConvertFrom-SettingsText @(Read-SettingsLines $Path)
}

function New-SettingsLines {
    # A whole settings file with these values: every setting with its comment, in the order of $SettingDefinitions.
    param([System.Collections.IDictionary]$Values)

    $lines = [List[string]]::new()
    $lines.AddRange([string[]]$SettingsFileHeader)
    foreach ($name in $SettingDefinitions.Keys) {
        $definition = $SettingDefinitions[$name]
        if ($definition.ContainsKey('Comment')) {   # not $definition.Comment: StrictMode throws for a missing key
            $lines.Add('')
            foreach ($commentLine in $definition.Comment) { $lines.Add("# $commentLine") }
        }
        $lines.Add("$name = $(ConvertTo-SettingText $Values[$name])")
    }
    $lines.ToArray()
}

function Set-SettingLine {
    # The file's lines with the setting's line(s) set to the new value; added at the end if it has none. All other
    # lines - comments, other settings, empty lines - stay as they are.
    param([string[]]$Lines, [string]$Name, [string]$Text)

    $result = [List[string]]::new()
    $found = $false
    foreach ($line in $Lines) {
        $trimmed = $line.Trim()
        $at = $trimmed.IndexOf('=')
        $isSetting = $at -gt 0 -and $trimmed[0] -notin '#', ';' -and $trimmed.Substring(0, $at).Trim() -eq $Name
        if ($isSetting) {
            $result.Add("$Name = $Text")
            $found = $true
        }
        else {
            $result.Add($line)
        }
    }
    if (-not $found) { $result.Add("$Name = $Text") }
    $result.ToArray()
}

function Save-Setting {
    # A setting changed in the tray menu: written to the settings file - only if there is one (it is opt-in, see
    # above). Only that setting's line changes.
    param([string]$Name)

    $path = $State.SettingsFile
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $value = (Get-CurrentSettings)[$Name]
    $text = ConvertTo-SettingText $value
    try {
        $lines = Set-SettingLine -Lines @(Read-SettingsLines $path) -Name $Name -Text $text
        Write-SettingsLines $path $lines
    }
    catch {
        $message = $_.Exception.GetBaseException().Message.Trim()
        Write-Verbose "Could not save $Name to ${path}: $message"
        Show-TrayWarning "Could not save the setting to $(Split-Path -Leaf $path): $message"
        return
    }
    $State.SettingsInFile[$Name] = $value   # so that the file's change event finds nothing new
    Write-Verbose "Saved $Name = $text to $path."
    Show-GivenSettingHint $Name
}

function Show-GivenSettingHint {
    # Once per run: a setting also given on the command line - e.g. by a shortcut of an older Install.ps1 - gets
    # the command line's value again at the next start, whatever the file says.
    param([string]$Name)

    if ($State.SettingsGiven -notcontains $Name -or $State.SettingsHintShown) { return }
    $State.SettingsHintShown = $true
    $fileName = Split-Path -Leaf $State.SettingsFile
    Show-TrayWarning ("$Name is also set on psclip's command line, which wins over $fileName at the next start. " +
        'Run Install.ps1 again to start psclip without it.')
}

function Set-Setting {
    # Applies one setting from the settings file, the way the tray menu would.
    param([string]$Name, $Value)

    if ((Get-CurrentSettings)[$Name] -eq $Value) { return }
    Write-Verbose "Settings file: $Name = $(ConvertTo-SettingText $Value)."
    switch ($Name) {
        'Hotkey' {
            $spec = ConvertFrom-HotkeyText $Value
            $previous = $State.HotkeySpec
            $wasActive = $State.HotkeyActive
            if (-not (Register-Hotkey $spec)) {
                $State.HotkeyActive = $wasActive -and (Register-Hotkey $previous)   # SetHotkey released it
                $fileName = Split-Path -Leaf $State.SettingsFile
                Show-TrayWarning "The hotkey $(Format-HotkeySpec $spec) from $fileName is used by another program."
            }
            Update-TrayText
        }
        'Theme' {
            $State.ThemeSetting = $Value
            Set-Theme (Test-DarkTheme)
        }
        'Size' { $State.PopupSize = $Value }   # the popup opens at this size next time
        'Font' { Set-PopupFont $Value }
        'OpenAt' { $State.OpenAt = $Value }
        'MaxMemory' { Set-MemoryLimit $Value }
        'KeepPinned' { Set-KeepPinned $Value }
        'Preview' { $State.PreviewDefault = $Value }
        'KeepAwake' { Set-KeepAwake $Value }
        'KeepAwakeSeconds' { $State.KeepAwakeSeconds = $Value }
        'MaxEntryLength' { $State.MaxEntryLength = $Value }
    }
}

function Receive-SettingsFileChange {
    # The settings file was saved - by an editor, Install.ps1 or psclip itself (Request-SettingsRead waited until
    # the writing was done). Applies the settings whose value in the file changed since it was last read or
    # written: psclip's own saves change nothing, and a setting given on the command line keeps its value until
    # the user changes it in the file.
    $Ui.SettingsTimer.Stop()
    try {
        $file = Read-SettingsFile $State.SettingsFile
    }
    catch {
        Write-Verbose "Could not read $($State.SettingsFile): $($_.Exception.GetBaseException().Message)"
        return   # e.g. still being written: its next change event comes
    }
    if ($null -eq $file) {
        $State.SettingsInFile = @{}   # deleted: nothing is saved any more
        return
    }
    $before = $State.SettingsInFile
    $State.SettingsInFile = $file.Values
    foreach ($name in $SettingDefinitions.Keys) {
        if (-not $file.Values.ContainsKey($name)) { continue }   # removed lines keep the current value
        if ($before.ContainsKey($name) -and $before[$name] -eq $file.Values[$name]) { continue }
        Set-Setting $name $file.Values[$name]
        Show-GivenSettingHint $name
    }
    Show-SettingsProblems $file.Problems
}

function Show-SettingsProblems {
    # Lines of the settings file that were ignored - shown when they change, not again at every save.
    param([string[]]$Problems)

    $message = Get-SettingsProblemMessage $Problems
    if ($message -ceq $State.SettingsProblems) { return }
    $State.SettingsProblems = $message
    if ($message) { Show-TrayWarning $message }
}

function Get-SettingsProblemMessage {
    # One message for the tray (the start shows it with the other warnings), or '' when all lines are fine.
    param([string[]]$Problems)

    if (@($Problems).Count -eq 0) { return '' }
    foreach ($problem in $Problems) { Write-Verbose "Settings file, $problem" }
    "Ignored in $(Split-Path -Leaf $State.SettingsFile) - $(@($Problems) -join ' ')"
}

function Request-SettingsRead {
    # A change event of the settings file: editors write in several steps, so it is read once they stop.
    $Ui.SettingsTimer.Stop()
    $Ui.SettingsTimer.Start()
}

function Start-SettingsWatcher {
    # Saving the settings file applies it at once (Receive-SettingsFileChange) - also when it is created later.
    $timer = [System.Windows.Forms.Timer]::new()
    $timer.Interval = 300
    $timer.add_Tick({ Receive-SettingsFileChange })
    $Ui.SettingsTimer = $timer

    $path = $State.SettingsFile
    try {
        $watcher = [IO.FileSystemWatcher]::new((Split-Path -Parent $path), (Split-Path -Leaf $path))
        $watcher.NotifyFilter = [IO.NotifyFilters]'FileName, LastWrite, Size'
        $watcher.SynchronizingObject = $Ui.Form   # its events then run on the UI thread, like all others
        $watcher.add_Changed({ Request-SettingsRead })
        $watcher.add_Created({ Request-SettingsRead })
        $watcher.add_Renamed({ Request-SettingsRead })   # editors that save to a temporary file first
        $watcher.add_Deleted({ Request-SettingsRead })
        $watcher.EnableRaisingEvents = $true
        $Ui.SettingsWatcher = $watcher
    }
    catch {
        Write-Verbose "Changes of $path apply at the next start only: $($_.Exception.GetBaseException().Message)"
    }
}

function Open-SettingsFile {
    # Tray menu "Edit settings file...": opens it in the editor for .ini files (Notepad). Without a file, writes it
    # first, with the current settings - from then on psclip saves its settings.
    $path = $State.SettingsFile
    try {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $values = Get-CurrentSettings
            Write-SettingsLines $path (New-SettingsLines $values)
            $State.SettingsInFile = $values
            Write-Verbose "Created $path."
        }
        Start-SettingsEditor $path
    }
    catch {
        Show-TrayWarning "Could not open $(Split-Path -Leaf $path): $($_.Exception.GetBaseException().Message)"
    }
}

function Start-SettingsEditor {
    # The program Windows opens .ini files with - Notepad, unless the user chose another one.
    param([string]$Path)

    try {
        Start-Process -FilePath $Path
    }
    catch {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\notepad.exe') -ArgumentList "`"$Path`""
    }
}
