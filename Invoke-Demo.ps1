<#
.SYNOPSIS
  Run an automated software demo described by a JSON scenario, while capturing
  the screen to video. Pure PowerShell + built-in .NET; ffmpeg is the only
  optional dependency (for hands-off recording).

.DESCRIPTION
  The engine opens apps, types CLI commands into a visible terminal, sends key
  chords, shows on-screen captions, narrates, takes screenshots, and records the
  whole thing. See docs/SCENARIO_FORMAT.md for the scenario schema and the prompt
  that makes Claude generate one.

.PARAMETER Scenario
  Path to the scenario .json file.

.PARAMETER DryRun
  Validate and print the planned steps without executing or recording anything.

.PARAMETER Validate
  Validate only (exit non-zero on errors). Implies no execution.

.PARAMETER NoRecord
  Run the demo actions but do not record (overrides the scenario's recording mode).

.PARAMETER RecordMode
  Override the recording mode (ffmpeg | manual | none).

.PARAMETER KeepController
  Do not minimize this controller window during the demo.

.EXAMPLE
  .\Invoke-Demo.ps1 .\scenarios\example-powershell-demo.json
.EXAMPLE
  .\Invoke-Demo.ps1 .\scenarios\example-powershell-demo.json -DryRun
.EXAMPLE
  .\Invoke-Demo.ps1 .\scenarios\example-powershell-demo.json -RecordMode manual
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string]$Scenario,
    [switch]$DryRun,
    [switch]$Validate,
    [switch]$NoRecord,
    [ValidateSet('ffmpeg','manual','none')] [string]$RecordMode,
    [switch]$KeepController,
    [switch]$ListVoices
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modules = Join-Path $PSScriptRoot 'modules'
Import-Module (Join-Path $modules 'Engine.psm1')   -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Overlay.psm1')  -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Recorder.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modules 'Scenario.psm1') -Force -DisableNameChecking

# --- List voices and exit (helper for choosing narration.voice) -------------
if ($ListVoices) {
    Write-Host "WinRT voices (engine 'winrt'; built-in Windows OneCore voices):" -ForegroundColor Cyan
    $wv = Get-WinRTVoices
    if ($wv) { $wv | ForEach-Object { Write-Host "  $_" } } else { Write-Host "  (WinRT speech unavailable on this system)" -ForegroundColor Yellow }
    Write-Host "SAPI voices (legacy):" -ForegroundColor Cyan
    Get-DemoVoices | ForEach-Object { Write-Host "  $_" }
    Write-Host "Piper voices (engine 'piper'; offline neural, from voices/):" -ForegroundColor Cyan
    $voicesDir = Join-Path $PSScriptRoot 'voices'
    $models = if (Test-Path $voicesDir) { Get-ChildItem $voicesDir -Filter *.onnx -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName } }
    if ($models) { $models | ForEach-Object { Write-Host "  $_" } } else { Write-Host "  (none - run .\Setup-Piper.ps1)" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "Note: Windows 'Natural' voices added via Narrator are locked to Narrator and NOT usable here." -ForegroundColor DarkGray
    Write-Host "For natural narration, use engine 'piper' (.\Setup-Piper.ps1) - free & offline." -ForegroundColor DarkGray
    Write-Host "Cloud engines 'azure' / 'openai' have their own voices - see README > Cloud voices." -ForegroundColor DarkGray
    exit 0
}
if (-not $Scenario) { Write-Host "Specify a scenario file (or use -ListVoices)." -ForegroundColor Red; exit 1 }

# --- Load + validate --------------------------------------------------------
$scn = Read-DemoScenario -Path $Scenario
$result = Test-DemoScenario -Scenario $scn

if ($result.Warnings.Count -gt 0) {
    Write-Host "Warnings:" -ForegroundColor Yellow
    $result.Warnings | ForEach-Object { Write-Host "  ! $_" -ForegroundColor Yellow }
}
if ($result.Errors.Count -gt 0) {
    Write-Host "Validation failed:" -ForegroundColor Red
    $result.Errors | ForEach-Object { Write-Host "  x $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Scenario is valid." -ForegroundColor Green

if ($Validate) { exit 0 }
if ($DryRun)   { Write-DemoScenarioPlan -Scenario $scn; exit 0 }

# --- Resolve settings (scenario over built-in defaults) ---------------------
$settings = Get-Prop $scn 'settings'
$rec      = Get-Prop $settings 'recording'
$def      = Get-Prop $settings 'defaults'
$narr     = Get-Prop $settings 'narration'
$caps     = Get-Prop $settings 'captions'
$startup  = Get-Prop $settings 'startup'

$term     = Get-Prop $settings 'terminal'

$mode = Get-Prop $rec 'mode' 'ffmpeg'
if ($RecordMode) { $mode = $RecordMode }
if ($NoRecord)   { $mode = 'none' }

$recCfg = @{
    mode          = $mode
    framerate     = Get-Prop $rec 'framerate' 30
    crf           = Get-Prop $rec 'crf' 23
    preset        = Get-Prop $rec 'preset' 'veryfast'
    captureCursor = [bool](Get-Prop $rec 'captureCursor' $true)
}
if (Get-Prop $rec 'region')      { $recCfg.region = (Get-Prop $rec 'region') }
if (Get-Prop $rec 'audioDevice') { $recCfg.audioDevice = (Get-Prop $rec 'audioDevice') }

$outputDir = Get-Prop $rec 'outputDir' (Join-Path $PSScriptRoot 'recordings')
if (-not [System.IO.Path]::IsPathRooted($outputDir)) { $outputDir = Join-Path $PSScriptRoot $outputDir }
$baseName  = Get-Prop $rec 'fileName' 'demo'
$autoRec   = [bool](Get-Prop $rec 'auto' $true)
$timeStamp = (Get-Date).ToString('yyyyMMdd-HHmmss')

$cfg = @{
    outputDir        = $outputDir
    typeStyle        = Get-Prop $def 'typeStyle' 'human'
    typeDelay        = [int](Get-Prop $def 'typeDelayMs' 30)
    shell            = Get-Prop $def 'shell' 'powershell'
    stepPause        = [int](Get-Prop $def 'stepPauseMs' 800)
    captionsEnabled  = [bool](Get-Prop $caps 'enabled' $true)
    captionDuration  = [int](Get-Prop $caps 'defaultDurationMs' 3500)
    captionPos       = Get-Prop $caps 'position' 'bottom'
    captionFont      = [int](Get-Prop $caps 'fontSize' 28)
    narrationEnabled = [bool](Get-Prop $narr 'enabled' $true)
    voice            = Get-Prop $narr 'voice' ''
    rate             = [int](Get-Prop $narr 'rate' 0)
    volume           = [int](Get-Prop $narr 'volume' 100)
}
$minimize = (-not $KeepController) -and [bool](Get-Prop $settings 'minimizeControllerWindow' $true)
$countdown = [int](Get-Prop $startup 'countdownSec' 3)

# Narration engine: 'piper' (offline neural), 'winrt' (OneCore voices), or 'sapi'.
$piperCfg   = Get-Prop $narr 'piper'
$piperExe   = Get-Prop $piperCfg 'exe'   (Join-Path $PSScriptRoot 'tools\piper\piper.exe')
$piperModel = Get-Prop $piperCfg 'model' (Join-Path $PSScriptRoot 'voices\en_US-lessac-medium.onnx')
if (-not [System.IO.Path]::IsPathRooted($piperExe))   { $piperExe   = Join-Path $PSScriptRoot $piperExe }
if (-not [System.IO.Path]::IsPathRooted($piperModel)) { $piperModel = Join-Path $PSScriptRoot $piperModel }
[void](Set-PiperConfig -Exe $piperExe -Model $piperModel)

# Cloud engines (azure/openai): read the API key from an env var (never the scenario).
$engineName = Get-Prop $narr 'engine' 'winrt'
if ($engineName -eq 'azure' -or $engineName -eq 'openai') {
    if ($engineName -eq 'azure') { $defEnv = 'AZURE_SPEECH_KEY'; $defModel = '' }
    else                         { $defEnv = 'OPENAI_API_KEY';   $defModel = 'tts-1-hd' }
    $apiKeyEnv = Get-Prop $narr 'apiKeyEnv' $defEnv
    $apiKey    = [Environment]::GetEnvironmentVariable($apiKeyEnv)
    $region    = Get-Prop $narr 'region' 'eastus'
    $model     = Get-Prop $narr 'model' $defModel
    [void](Set-CloudTtsConfig -Engine $engineName -ApiKey $apiKey -Region $region -Model $model -CacheDir (Join-Path $PSScriptRoot '.tts-cache'))
    if (-not $apiKey) { Write-Host "  Note: env var '$apiKeyEnv' is not set - '$engineName' will fall back to a local voice. See README > Cloud voices." -ForegroundColor Yellow }
}
$narrEngine = Set-NarrationEngine -Engine $engineName

# Narration is baked into the video (post-mux) only when we own a recorded file.
$narrationToVideo = ($mode -eq 'ffmpeg') -and $autoRec -and $cfg.narrationEnabled -and [bool](Get-Prop $narr 'captureToVideo' $true)
$narrDir = $null

# Terminal appearance (opt-in): larger console font + classic conhost for readability.
$termFont  = [int](Get-Prop $term 'fontSize' 0)
$termFace  = Get-Prop $term 'fontFace' 'Consolas'
$termForce = [bool](Get-Prop $term 'forceConhost' ($termFont -gt 0))

$script:RecHandle = $null
$script:ShotIndex = 0

# --- Step dispatcher --------------------------------------------------------
function Invoke-DemoStep {
    param($Step, $Cfg)
    $action = $Step.action

    # Inline shorthands: a caption and/or narration that accompany this step.
    $inlineCap = Get-Prop $Step 'caption'
    if ($inlineCap -and $Cfg.captionsEnabled) {
        Show-DemoCaption -Text $inlineCap -DurationMs (Get-Prop $Step 'captionDurationMs' $Cfg.captionDuration) -Position $Cfg.captionPos -FontSize $Cfg.captionFont
    }
    $inlineSay = Get-Prop $Step 'say'
    if ($inlineSay -and $Cfg.narrationEnabled) {
        Invoke-DemoNarration -Text $inlineSay -Voice $Cfg.voice -Rate $Cfg.rate -Volume $Cfg.volume
    }

    switch ($action) {
        'wait' {
            $s = Get-Prop $Step 'seconds'; $m = Get-Prop $Step 'ms'
            if ($s) { Start-Sleep -Seconds ([double]$s) } else { Start-Sleep -Milliseconds ([int]$m) }
        }
        'caption' {
            if ($Cfg.captionsEnabled) {
                Show-DemoCaption -Text $Step.text `
                    -DurationMs (Get-Prop $Step 'durationMs' $Cfg.captionDuration) `
                    -Position   (Get-Prop $Step 'position' $Cfg.captionPos) `
                    -FontSize   (Get-Prop $Step 'fontSize' $Cfg.captionFont) `
                    -Wait:([bool](Get-Prop $Step 'wait' $false))
            }
        }
        'narrate' {
            if ($Cfg.narrationEnabled) {
                Invoke-DemoNarration -Text $Step.text -Voice (Get-Prop $Step 'voice' $Cfg.voice) `
                    -Rate (Get-Prop $Step 'rate' $Cfg.rate) -Volume (Get-Prop $Step 'volume' $Cfg.volume) `
                    -Wait:([bool](Get-Prop $Step 'wait' $true))
            }
        }
        'launch' {
            $a = Get-Prop $Step 'args'
            if ($a -and $a -isnot [System.Array]) { $a = @($a) }
            $p = Start-DemoApp -App $Step.app -Arguments $a -As (Get-Prop $Step 'as')
            $ws = Get-Prop $Step 'windowState'
            if ($ws) { Set-DemoWindowState -Process $p -State $ws }
        }
        'run' {
            [void](Invoke-DemoRun -Command $Step.command `
                -Shell    (Get-Prop $Step 'shell' $Cfg.shell) `
                -NewWindow ([bool](Get-Prop $Step 'newWindow' $false)) `
                -As       (Get-Prop $Step 'as') `
                -Style    (Get-Prop $Step 'typeStyle' $Cfg.typeStyle) `
                -DelayMs  (Get-Prop $Step 'typeDelayMs' $Cfg.typeDelay) `
                -Submit   ([bool](Get-Prop $Step 'submit' $true)) `
                -WaitMs   ([int](Get-Prop $Step 'waitMs' 800)))
        }
        'type' {
            Send-DemoText -Text $Step.text -Style (Get-Prop $Step 'typeStyle' $Cfg.typeStyle) `
                -DelayMs (Get-Prop $Step 'typeDelayMs' $Cfg.typeDelay) -Submit:([bool](Get-Prop $Step 'submit' $false))
        }
        'keys' {
            $keys = $Step.keys; if ($keys -isnot [System.Array]) { $keys = @($keys) }
            Send-DemoKeys -Keys $keys -Count ([int](Get-Prop $Step 'count' 1)) -IntervalMs ([int](Get-Prop $Step 'intervalMs' 60))
        }
        'focus' {
            [void](Focus-DemoWindow -As (Get-Prop $Step 'as') -Title (Get-Prop $Step 'title') `
                -TitleContains (Get-Prop $Step 'titleContains') -ProcessName (Get-Prop $Step 'processName'))
        }
        'window' {
            $p = Get-DemoWindowProcess -As (Get-Prop $Step 'as') -Title (Get-Prop $Step 'title') `
                -TitleContains (Get-Prop $Step 'titleContains') -ProcessName (Get-Prop $Step 'processName')
            Set-DemoWindowState -Process $p -State (Get-Prop $Step 'state' 'normal') `
                -X (Get-Prop $Step 'x') -Y (Get-Prop $Step 'y') -Width (Get-Prop $Step 'width') -Height (Get-Prop $Step 'height')
        }
        'click' {
            Invoke-DemoClick -X ([int]$Step.x) -Y ([int]$Step.y) -Button (Get-Prop $Step 'button' 'left')
        }
        'screenshot' {
            $script:ShotIndex++
            $path = Get-Prop $Step 'path'
            if (-not $path) { $path = Join-Path $Cfg.outputDir ("$baseName-$timeStamp-shot{0:D2}.png" -f $script:ShotIndex) }
            elseif (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path $Cfg.outputDir $path }
            $region = Get-Prop $Step 'region'
            $rh = $null
            if ($region) { $rh = @{ x = [int]$region.x; y = [int]$region.y; width = [int]$region.width; height = [int]$region.height } }
            $saved = Save-DemoScreenshot -Path $path -Region $rh
            Write-Host "    screenshot -> $saved" -ForegroundColor DarkGray
        }
        'record' {
            $op = Get-Prop $Step 'op'
            if ($autoRec) { Write-Warning "record:$op ignored because settings.recording.auto is true (the whole scenario is auto-recorded)."; return }
            if ($op -eq 'start' -and -not $script:RecHandle) {
                $script:RecHandle = Start-DemoRecording -Recording $recCfg -OutputDir $cfg.outputDir -BaseName $baseName -TimeStamp $timeStamp
            } elseif ($op -eq 'stop' -and $script:RecHandle) {
                $f = Stop-DemoRecording -Handle $script:RecHandle; $script:RecHandle = $null
                if ($f) { Write-Host "    saved -> $f" -ForegroundColor Green }
            }
        }
        'marker' { Write-Host "  --- $(Get-Prop $Step 'label') ---" -ForegroundColor Magenta }
        'prompt' {
            Set-ControllerWindowState -State normal
            [void](Read-Host ("  " + (Get-Prop $Step 'message')))
            if ($minimize) { Set-ControllerWindowState -State minimized }
        }
    }
}

# --- Run --------------------------------------------------------------------
$steps = Get-Prop $scn 'steps'
if ($steps -isnot [System.Array]) { $steps = @($steps) }

Write-Host ''
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host " DEMO: $(Get-Prop $scn 'name' 'untitled')" -ForegroundColor Cyan
Write-Host " $($steps.Count) steps | recording mode: $mode" -ForegroundColor Cyan
Write-Host " Do NOT use the mouse or keyboard while the demo runs." -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

for ($c = $countdown; $c -gt 0; $c--) { Write-Host "  starting in $c..." -ForegroundColor DarkCyan; Start-Sleep -Seconds 1 }

if ($termForce -or $termFont -gt 0) { Set-DemoTerminalStyle -FontSize $termFont -FontFace $termFace -ForceConhost $termForce }

if ($autoRec -and $mode -ne 'none') {
    $script:RecHandle = Start-DemoRecording -Recording $recCfg -OutputDir $cfg.outputDir -BaseName $baseName -TimeStamp $timeStamp
}
if ($narrationToVideo -and $script:RecHandle) {
    $narrSw  = [System.Diagnostics.Stopwatch]::StartNew()   # t=0 at recording start, for clip offsets
    $narrDir = Join-Path $cfg.outputDir (".narration-$timeStamp")
    Initialize-NarrationCapture -Dir $narrDir -Stopwatch $narrSw
}
if ($minimize) { Set-ControllerWindowState -State minimized }

$failed = $null
try {
    $n = 0
    foreach ($step in $steps) {
        $n++
        Invoke-DemoStep -Step $step -Cfg $cfg
        if ($step.action -notin @('wait','narrate')) {
            $pause = Get-Prop $step 'pauseAfterMs' $cfg.stepPause
            Start-Sleep -Milliseconds ([int]$pause)
        }
    }
} catch {
    $failed = $_
} finally {
    Set-ControllerWindowState -State normal
    Restore-DemoTerminalStyle   # put HKCU\Console font back
    if ($script:RecHandle) {
        $outFile = Stop-DemoRecording -Handle $script:RecHandle
        $script:RecHandle = $null
    }
    # Bake the timestamped narration clips into the finalized video.
    if ($narrationToVideo -and $outFile) {
        $clips = Get-NarrationClips
        if ($clips.Count -gt 0) {
            Write-Host "  Muxing $($clips.Count) narration clip(s) into the video..." -ForegroundColor Cyan
            $outFile = Add-NarrationToVideo -VideoFile $outFile -Clips $clips
        }
    }
    Stop-DemoOverlays        # releases SoundPlayer file handles before cleanup
    Clear-NarrationCapture
    if ($narrDir -and (Test-Path $narrDir)) { Remove-Item $narrDir -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($failed) {
    Write-Host "Demo stopped on an error:" -ForegroundColor Red
    Write-Host "  $($failed.Exception.Message)" -ForegroundColor Red
}
Write-Host "Done." -ForegroundColor Green
if ($outFile) { Write-Host "Video: $outFile" -ForegroundColor Green }
elseif ($mode -eq 'manual') { Write-Host "Video: saved by your recorder (Clipchamp)." -ForegroundColor Green }
if ($failed) { exit 1 }
