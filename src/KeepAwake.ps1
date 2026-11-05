# psclip: Keep awake (unrelated to the clipboard): presses F15 after some idle time.
# Dot-sourced by ClipboardManager.ps1: shares its $State, $Ui and settings (see AGENTS.md).

using namespace System.Collections.Generic
using namespace System.Drawing
using namespace System.Windows.Forms


function Initialize-KeepAwake {
    $timer = [System.Windows.Forms.Timer]::new()
    $timer.Interval = 1000
    $timer.add_Tick({ Invoke-KeepAwakeCheck })
    $Ui.KeepAwakeTimer = $timer
    Set-KeepAwake $KeepAwake.IsPresent
}

function Set-KeepAwake {
    param([bool]$Enabled)

    $State.KeepAwake = $Enabled
    $Ui.KeepAwakeTimer.Enabled = $Enabled
    Write-Verbose "Keep awake $(if ($Enabled) { 'on' } else { 'off' })."
}

function Invoke-KeepAwakeCheck {
    # Every second: after KeepAwakeSeconds without mouse or keyboard input, press F15 - a key no
    # keyboard has and no program uses (Pause would freeze the output of console windows) - so
    # that Windows does not consider the session idle.
    if (-not (Test-KeepAwakeDue ([PsClip.Native]::GetIdleMilliseconds()))) { return }

    [PsClip.Native]::PressKey(0x7E)   # VK_F15
    Write-Verbose 'Keep awake: pressed F15.'
}

function Test-KeepAwakeDue {
    param([int]$IdleMilliseconds)
    $IdleMilliseconds -ge $KeepAwakeSeconds * 1000
}
