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
$script:NarrationEngine  = 'sapi'  # 'sapi' | 'winrt' | 'piper' | 'azure' | 'openai'
$script:PiperExe   = $null
$script:PiperModel = $null
$script:CloudCfg   = @{ engine = $null; key = $null; region = $null; model = $null; cacheDir = $null }  # cloud TTS config; set via Set-CloudTtsConfig

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

function Set-PiperConfig {
    param([string]$Exe, [string]$Model)
    $script:PiperExe   = $Exe
    $script:PiperModel = $Model
    return (($Exe -and (Test-Path $Exe)) -and ($Model -and (Test-Path $Model)))
}

function Test-PiperReady {
    return ($script:PiperExe -and (Test-Path $script:PiperExe) -and $script:PiperModel -and (Test-Path $script:PiperModel))
}

function Set-CloudTtsConfig {
    param([string]$Engine, [string]$ApiKey, [string]$Region, [string]$Model, [string]$CacheDir)
    $script:CloudCfg = @{ engine = $Engine; key = $ApiKey; region = $Region; model = $Model; cacheDir = $CacheDir }
    if ($CacheDir -and -not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
    return [bool]$ApiKey
}

function Set-NarrationEngine {
    param([ValidateSet('sapi','winrt','piper','azure','openai')] [string]$Engine)
    # Pick the best available fallback if the requested engine can't run.
    $fallback = if ($script:WinRTAvailable) { 'winrt' } else { 'sapi' }
    if (Test-PiperReady) { $fallback = 'piper' }

    if ($Engine -eq 'winrt' -and -not $script:WinRTAvailable) {
        Write-Warning "WinRT speech unavailable on this system; using SAPI voices."
        $script:NarrationEngine = 'sapi'
    } elseif ($Engine -eq 'piper' -and -not (Test-PiperReady)) {
        $fb = if ($script:WinRTAvailable) { 'winrt' } else { 'sapi' }
        Write-Warning "Piper not set up (run Setup-Piper.ps1); falling back to '$fb' voices."
        $script:NarrationEngine = $fb
    } elseif (($Engine -eq 'azure' -or $Engine -eq 'openai') -and -not $script:CloudCfg.key) {
        Write-Warning "No API key for '$Engine' (set the env var; see README); falling back to '$fallback'."
        $script:NarrationEngine = $fallback
    } else {
        $script:NarrationEngine = $Engine
    }
    return $script:NarrationEngine
}

# Render narration to a WAV with the Piper neural binary (offline, free). Text is
# piped on stdin; output goes to -f. length_scale maps our rate (higher=faster).
function Render-NarrationWavPiper {
    param([string]$Text, [string]$Path, [int]$Rate = 0)
    if (-not (Test-PiperReady)) { throw "Piper is not set up. Run Setup-Piper.ps1." }
    $lengthScale = [Math]::Max(0.5, [Math]::Min(2.0, 1.0 - ($Rate / 10.0) * 0.3))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = $script:PiperExe
    $psi.Arguments = '-m "{0}" -f "{1}" --length_scale {2}' -f $script:PiperModel, $Path, $lengthScale.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $psi.WorkingDirectory       = [System.IO.Path]::GetDirectoryName($script:PiperExe)  # so piper finds espeak-ng-data
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardOutput = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.WriteLine($Text)
    $p.StandardInput.Close()
    [void]$p.StandardOutput.ReadToEnd()
    [void]$p.StandardError.ReadToEnd()
    $p.WaitForExit()
    if (-not (Test-Path $Path) -or (Get-Item $Path).Length -eq 0) { throw "Piper failed to render audio (exit $($p.ExitCode))." }
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

# --- Cloud neural TTS (Azure / OpenAI) --------------------------------------
# Both render a WAV over HTTPS. Keys come from the caller (read from an env var
# in Invoke-Demo) and are never stored in scenarios. Results are cached by a hash
# of the request so re-running a demo doesn't re-call (or re-bill) the API.

function Render-NarrationWavAzure {
    param([string]$Text, [string]$Path, [string]$Voice, [int]$Rate = 0)
    $cfg = $script:CloudCfg
    if (-not $cfg.key)    { throw "Azure Speech key not set." }
    if (-not $cfg.region) { throw "Azure region not set (narration.region)." }
    $v = if ($Voice) { $Voice } else { 'en-US-AvaMultilingualNeural' }
    $pct = [int]([Math]::Max(-50, [Math]::Min(50, $Rate * 5)))          # -10..10 -> -50%..+50% (Azure allows 0.5x-2x)
    $rateAttr = if ($pct -ge 0) { "+$pct%" } else { "$pct%" }
    $esc = [System.Security.SecurityElement]::Escape($Text)
    $ssml = "<speak version='1.0' xml:lang='en-US'><voice name='$v'><prosody rate='$rateAttr'>$esc</prosody></voice></speak>"
    $uri = "https://$($cfg.region).tts.speech.microsoft.com/cognitiveservices/v1"
    $headers = @{ 'Ocp-Apim-Subscription-Key' = $cfg.key; 'X-Microsoft-OutputFormat' = 'riff-24khz-16bit-mono-pcm'; 'User-Agent' = 'demo-recorder' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -ContentType 'application/ssml+xml' `
            -Body ([Text.Encoding]::UTF8.GetBytes($ssml)) -OutFile $Path -UseBasicParsing -ErrorAction Stop | Out-Null
    } catch {
        if (Test-Path $Path) { Remove-Item $Path -Force -ErrorAction SilentlyContinue }
        throw "Azure TTS request failed (voice '$v', region '$($cfg.region)'): $($_.Exception.Message)"
    }
}

function Render-NarrationWavOpenAI {
    param([string]$Text, [string]$Path, [string]$Voice, [int]$Rate = 0)
    $cfg = $script:CloudCfg
    if (-not $cfg.key) { throw "OpenAI API key not set." }
    $model = if ($cfg.model) { $cfg.model } else { 'tts-1-hd' }
    $v = if ($Voice) { $Voice } else { 'coral' }
    $bodyObj = [ordered]@{ model = $model; voice = $v; input = $Text; response_format = 'wav' }
    if ($model -like 'tts-1*') {                                        # 'speed' is only honored by tts-1 / tts-1-hd
        $bodyObj.speed = [Math]::Round([Math]::Max(0.5, [Math]::Min(2.0, 1.0 + ($Rate / 10.0) * 0.4)), 2)
    }
    $body = $bodyObj | ConvertTo-Json -Compress
    $headers = @{ Authorization = "Bearer $($cfg.key)" }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        Invoke-WebRequest -Uri 'https://api.openai.com/v1/audio/speech' -Method Post -Headers $headers -ContentType 'application/json' `
            -Body ([Text.Encoding]::UTF8.GetBytes($body)) -OutFile $Path -UseBasicParsing -ErrorAction Stop | Out-Null
    } catch {
        if (Test-Path $Path) { Remove-Item $Path -Force -ErrorAction SilentlyContinue }
        throw "OpenAI TTS request failed (model '$model', voice '$v'): $($_.Exception.Message)"
    }
}

# Render via a cloud engine, using a local WAV cache keyed by the request content.
function Invoke-CloudRender {
    param([string]$Engine, [string]$Text, [string]$Path, [string]$Voice, [int]$Rate = 0)
    $cfg = $script:CloudCfg
    $cacheFile = $null
    if ($cfg.cacheDir) {
        $material = "$Engine|$Voice|$($cfg.model)|$Rate|$Text"
        $md5 = [System.Security.Cryptography.MD5]::Create()
        $hash = ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($material))) -replace '-', '').ToLowerInvariant()
        $md5.Dispose()
        $cacheFile = Join-Path $cfg.cacheDir ("$hash.wav")
        if (Test-Path $cacheFile) { Copy-Item $cacheFile $Path -Force; return }
    }
    switch ($Engine) {
        'azure'  { Render-NarrationWavAzure  -Text $Text -Path $Path -Voice $Voice -Rate $Rate }
        'openai' { Render-NarrationWavOpenAI -Text $Text -Path $Path -Voice $Voice -Rate $Rate }
    }
    if ($cacheFile -and (Test-Path $Path)) { Copy-Item $Path $cacheFile -Force }
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
    if ($engine -eq 'piper' -and -not (Test-PiperReady))      { $engine = if ($script:WinRTAvailable) { 'winrt' } else { 'sapi' } }
    $capturing = [bool]$script:NarrationCapture

    # winrt/piper always render to a WAV (no direct device output); SAPI renders to
    # WAV only when capturing (so it can be muxed), otherwise it speaks directly.
    $renderToWav = ($engine -in @('winrt','piper','azure','openai')) -or $capturing
    if ($renderToWav) {
        if ($capturing) {
            $cap = $script:NarrationCapture; $cap.index++
            $wav = Join-Path $cap.dir ("narr-{0:D3}.wav" -f $cap.index)
        } else {
            $wav = Join-Path ([System.IO.Path]::GetTempPath()) ("demo-narr-" + [guid]::NewGuid().ToString('N') + ".wav")
            [void]$script:TempWavs.Add($wav)
        }
        switch ($engine) {
            'piper'  { Render-NarrationWavPiper -Text $Text -Path $wav -Rate $Rate }
            'winrt'  { Render-NarrationWavWinRT  -Text $Text -Path $wav -Voice $Voice -Rate $Rate -Volume $Volume }
            'azure'  { Invoke-CloudRender -Engine 'azure'  -Text $Text -Path $wav -Voice $Voice -Rate $Rate }
            'openai' { Invoke-CloudRender -Engine 'openai' -Text $Text -Path $wav -Voice $Voice -Rate $Rate }
            default  { Render-NarrationWav        -Text $Text -Path $wav -Voice $Voice -Rate $Rate -Volume $Volume }
        }
        if ($capturing) { [void]$cap.clips.Add(@{ file = $wav; offsetMs = [int]$cap.sw.Elapsed.TotalMilliseconds }) }
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
    Render-NarrationWav, Render-NarrationWavWinRT, Render-NarrationWavPiper, Render-NarrationWavAzure, Render-NarrationWavOpenAI, `
    Initialize-NarrationCapture, Get-NarrationClips, Clear-NarrationCapture, `
    Set-NarrationEngine, Set-PiperConfig, Test-PiperReady, Set-CloudTtsConfig, Get-WinRTVoices
