<#
.SYNOPSIS
  On-screen captions and spoken narration for the demo recorder.

  Captions render in a borderless, top-most, click-through window that never
  steals focus from the demo app (WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW |
  WS_EX_TRANSPARENT), so SendKeys keeps flowing to the real target while text
  is on screen. Each caption runs in its own STA runspace with a self-closing
  timer, so the main engine thread is never blocked.

  Narration uses the built-in System.Speech (SAPI5) synthesizer. NOTE: spoken
  audio is heard live but is only captured in the video if you also record an
  audio loopback device (see README). On-screen captions are always captured.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Speech

# WinRT speech reaches OneCore + installed "Natural" neural voices, which the
# legacy System.Speech (SAPI5) API cannot see. Optional: if the WinRT projection
# is unavailable, the engine transparently falls back to SAPI.
$script:WinRTAvailable = $false
$script:AsTaskOp = $null
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [void][Windows.Media.SpeechSynthesis.SpeechSynthesizer, Windows.Media, ContentType = WindowsRuntime]
    $script:AsTaskOp = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    $script:WinRTAvailable = $true
} catch { $script:WinRTAvailable = $false }

# A Form that shows without activating and lets clicks pass through.
if (-not ([System.Management.Automation.PSTypeName]'DemoNoActivateForm').Type) {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
    using System;
    using System.Windows.Forms;
    public class DemoNoActivateForm : Form {
        public bool IsDemoOverlay { get { return true; } }   // a public member to quiet Add-Type's "no public members" warning
        protected override bool ShowWithoutActivation { get { return true; } }
        const int WS_EX_NOACTIVATE = 0x08000000;
        const int WS_EX_TOOLWINDOW = 0x00000080;
        const int WS_EX_TOPMOST    = 0x00000008;
        const int WS_EX_TRANSPARENT= 0x00000020;
        protected override CreateParams CreateParams {
            get {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_TRANSPARENT;
                return cp;
            }
        }
    }
'@
}

$script:CaptionJobs = New-Object System.Collections.ArrayList   # @{ ps; handle }
$script:Synths      = New-Object System.Collections.ArrayList
$script:Players     = New-Object System.Collections.ArrayList   # async SoundPlayers kept alive
$script:TempWavs    = New-Object System.Collections.ArrayList   # live-only WinRT WAVs to clean up
$script:NarrationCapture = $null   # when set, narration is rendered to WAV + timestamped for muxing
$script:NarrationEngine  = 'sapi'  # 'sapi' | 'winrt'; set via Set-NarrationEngine

# The work each caption runspace performs. Kept as a scriptblock so it can be
# pushed into an STA runspace.
$script:CaptionWorker = {
    param($Text, $DurationMs, $Position, $FontSize, $BgOpacity)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = New-Object DemoNoActivateForm
    $form.FormBorderStyle = 'None'
    $form.StartPosition   = 'Manual'
    $form.ShowInTaskbar   = $false
    $form.TopMost         = $true
    $form.BackColor       = [System.Drawing.Color]::FromArgb(18, 18, 18)
    $form.Opacity         = $BgOpacity

    $label = New-Object System.Windows.Forms.Label
    $label.Text      = $Text
    $label.ForeColor = [System.Drawing.Color]::White
    $label.Dock      = 'Fill'
    $label.TextAlign = 'MiddleCenter'
    $label.Font      = New-Object System.Drawing.Font('Segoe UI', [single]$FontSize, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($label)

    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $w = [int]($area.Width * 0.82)
    $h = [int]($FontSize * 2.6) + 24
    $x = $area.X + [int](($area.Width - $w) / 2)
    switch ($Position) {
        'top'    { $y = $area.Y + 48 }
        'center' { $y = $area.Y + [int](($area.Height - $h) / 2) }
        default  { $y = $area.Y + $area.Height - $h - 72 }
    }
    $form.Bounds = New-Object System.Drawing.Rectangle($x, $y, $w, $h)

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [int]$DurationMs
    $timer.Add_Tick({ $timer.Stop(); $form.Close() })
    $timer.Start()

    [System.Windows.Forms.Application]::Run($form)
    $form.Dispose()
}

function Show-DemoCaption {
    param(
        [string]$Text,
        [int]$DurationMs = 3500,
        [ValidateSet('top','center','bottom')] [string]$Position = 'bottom',
        [int]$FontSize = 28,
        [double]$BgOpacity = 0.85,
        [switch]$Wait
    )
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:CaptionWorker).AddArgument($Text).AddArgument($DurationMs).AddArgument($Position).AddArgument($FontSize).AddArgument($BgOpacity)
    $handle = $ps.BeginInvoke()
    if ($Wait) {
        $ps.EndInvoke($handle)
        $ps.Dispose(); $rs.Dispose()
    } else {
        [void]$script:CaptionJobs.Add(@{ ps = $ps; rs = $rs; handle = $handle })
    }
}

# Block on a WinRT IAsyncOperation<T> and return its result (PowerShell can't await).
function Await {
    param($Operation, [type]$ResultType)
    $task = $script:AsTaskOp.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    [void]$task.Wait(-1)
    return $task.Result
}

function Set-NarrationEngine {
    param([ValidateSet('sapi','winrt')] [string]$Engine)
    if ($Engine -eq 'winrt' -and -not $script:WinRTAvailable) {
        Write-Warning "WinRT speech unavailable on this system; using SAPI voices."
        $script:NarrationEngine = 'sapi'
    } else {
        $script:NarrationEngine = $Engine
    }
    return $script:NarrationEngine
}

function Get-WinRTVoices {
    if (-not $script:WinRTAvailable) { return @() }
    return ([Windows.Media.SpeechSynthesis.SpeechSynthesizer]::AllVoices | ForEach-Object { $_.DisplayName })
}

# Render narration to a PCM WAV using the WinRT synth (OneCore / Natural voices).
# Voice matching is tolerant: exact DisplayName, else a fuzzy match that also
# accepts legacy "... Desktop" names (so existing scenarios keep working).
function Render-NarrationWavWinRT {
    param([string]$Text, [string]$Path, [string]$Voice, [int]$Rate = 0, [int]$Volume = 100)
    if (-not $script:WinRTAvailable) { throw "WinRT speech is not available on this system." }
    $synth = New-Object Windows.Media.SpeechSynthesis.SpeechSynthesizer
    try {
        if ($Voice) {
            $req = $Voice.Trim()
            $all = [Windows.Media.SpeechSynthesis.SpeechSynthesizer]::AllVoices
            $v = $all | Where-Object { $_.DisplayName -eq $req } | Select-Object -First 1
            if (-not $v) {
                $reqN = ($req -replace '\s*Desktop$', '')
                $v = $all | Where-Object { $_.DisplayName -eq $reqN -or $_.DisplayName -like "*$reqN*" -or $reqN -like "*$($_.DisplayName)*" } | Select-Object -First 1
            }
            if ($v) { $synth.Voice = $v } else { Write-Warning "WinRT voice '$Voice' not found; using default ($($synth.Voice.DisplayName))." }
        }
        try {
            $synth.Options.SpeakingRate = [Math]::Max(0.5, [Math]::Min(2.0, 1.0 + ($Rate / 10.0) * 0.5))
            $synth.Options.AudioVolume  = [Math]::Max(0.0, [Math]::Min(1.0, $Volume / 100.0))
        } catch {}
        $op = $synth.SynthesizeTextToStreamAsync($Text)
        $stream = Await $op ([Windows.Media.SpeechSynthesis.SpeechSynthesisStream])
        $net = [System.IO.WindowsRuntimeStreamExtensions]::AsStream($stream)
        $fs = [System.IO.File]::Create($Path)
        try { $net.CopyTo($fs) } finally { $fs.Dispose(); $net.Dispose(); $stream.Dispose() }
    } finally {
        $synth.Dispose()
    }
}

# Render narration to a PCM WAV file. SAPI locks the file until output is reset,
# so we reset to null and dispose before returning (per System.Speech guidance).
function Render-NarrationWav {
    param([string]$Text, [string]$Path, [string]$Voice, [int]$Rate = 0, [int]$Volume = 100)
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    try {
        if ($Voice) { try { $synth.SelectVoice($Voice) } catch { Write-Warning "Voice '$Voice' not found; using default." } }
        $synth.Rate   = [Math]::Max(-10, [Math]::Min(10, $Rate))
        $synth.Volume = [Math]::Max(0, [Math]::Min(100, $Volume))
        $synth.SetOutputToWaveFile($Path)
        $synth.Speak($Text)
    } finally {
        try { $synth.SetOutputToNull() } catch {}
        $synth.Dispose()
    }
}

# Begin capturing narration to timestamped WAV clips (for later muxing into the
# video). $Stopwatch must be started at recording-start so offsets line up.
function Initialize-NarrationCapture {
    param([string]$Dir, [System.Diagnostics.Stopwatch]$Stopwatch)
    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $script:NarrationCapture = @{ dir = $Dir; sw = $Stopwatch; clips = (New-Object System.Collections.ArrayList); index = 0 }
}
function Get-NarrationClips {
    if ($script:NarrationCapture) { return @($script:NarrationCapture.clips) }
    return @()
}
function Clear-NarrationCapture { $script:NarrationCapture = $null }

function Invoke-DemoNarration {
    param(
        [string]$Text,
        [string]$Voice,
        [int]$Rate = 0,        # -10 .. 10
        [int]$Volume = 100,    # 0 .. 100
        [switch]$Wait
    )
    $engine = $script:NarrationEngine
    if ($engine -eq 'winrt' -and -not $script:WinRTAvailable) { $engine = 'sapi' }
    $capturing = [bool]$script:NarrationCapture

    # WinRT engine: it renders to a stream (no direct device output), so we always
    # render a WAV and play it. Captured clips are kept for muxing; live ones are
    # temp files cleaned up at the end.
    if ($engine -eq 'winrt') {
        if ($capturing) {
            $cap = $script:NarrationCapture; $cap.index++
            $wav = Join-Path $cap.dir ("narr-{0:D3}.wav" -f $cap.index)
        } else {
            $wav = Join-Path ([System.IO.Path]::GetTempPath()) ("demo-narr-" + [guid]::NewGuid().ToString('N') + ".wav")
            [void]$script:TempWavs.Add($wav)
        }
        Render-NarrationWavWinRT -Text $Text -Path $wav -Voice $Voice -Rate $Rate -Volume $Volume
        if ($capturing) { [void]$cap.clips.Add(@{ file = $wav; offsetMs = [int]$cap.sw.Elapsed.TotalMilliseconds }) }
        $player = New-Object System.Media.SoundPlayer($wav)
        if ($Wait) { $player.PlaySync(); $player.Dispose() }
        else { [void]$script:Players.Add($player); $player.Play() }
        return
    }

    # SAPI engine, capture mode: render to WAV, timestamp it, play it.
    if ($capturing) {
        $cap = $script:NarrationCapture; $cap.index++
        $wav = Join-Path $cap.dir ("narr-{0:D3}.wav" -f $cap.index)
        Render-NarrationWav -Text $Text -Path $wav -Voice $Voice -Rate $Rate -Volume $Volume
        [void]$cap.clips.Add(@{ file = $wav; offsetMs = [int]$cap.sw.Elapsed.TotalMilliseconds })
        $player = New-Object System.Media.SoundPlayer($wav)
        if ($Wait) { $player.PlaySync(); $player.Dispose() }
        else { [void]$script:Players.Add($player); $player.Play() }
        return
    }

    # SAPI engine, live-only mode (manual/none recording): speak to the device.
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    if ($Voice) { try { $synth.SelectVoice($Voice) } catch { Write-Warning "Voice '$Voice' not found; using default." } }
    $synth.Rate   = [Math]::Max(-10, [Math]::Min(10, $Rate))
    $synth.Volume = [Math]::Max(0, [Math]::Min(100, $Volume))
    if ($Wait) {
        try { $synth.Speak($Text) } finally { $synth.Dispose() }
    } else {
        [void]$script:Synths.Add($synth)
        [void]$synth.SpeakAsync($Text)
    }
}

function Get-DemoVoices {
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    try { return ($synth.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo.Name }) }
    finally { $synth.Dispose() }
}

# Tear down any lingering captions / async narration at end of run.
function Stop-DemoOverlays {
    foreach ($job in $script:CaptionJobs) {
        try { if (-not $job.handle.IsCompleted) { $job.ps.Stop() } } catch {}
        try { $job.ps.Dispose() } catch {}
        try { $job.rs.Dispose() } catch {}
    }
    $script:CaptionJobs.Clear()
    foreach ($s in $script:Synths) {
        try { $s.SpeakAsyncCancelAll() } catch {}
        try { $s.Dispose() } catch {}
    }
    $script:Synths.Clear()
    foreach ($p in $script:Players) {
        try { $p.Stop() } catch {}
        try { $p.Dispose() } catch {}
    }
    $script:Players.Clear()
    foreach ($w in $script:TempWavs) { try { Remove-Item $w -Force -ErrorAction SilentlyContinue } catch {} }
    $script:TempWavs.Clear()
}

Export-ModuleMember -Function Show-DemoCaption, Invoke-DemoNarration, Get-DemoVoices, Stop-DemoOverlays, `
    Render-NarrationWav, Render-NarrationWavWinRT, Initialize-NarrationCapture, Get-NarrationClips, Clear-NarrationCapture, `
    Set-NarrationEngine, Get-WinRTVoices
