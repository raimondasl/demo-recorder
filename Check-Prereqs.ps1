<#
.SYNOPSIS
  Verify the environment can run the demo recorder, and report what is optional.

  Nothing here is required for the MVP except Windows PowerShell 5.1+ (built in).
  ffmpeg is the only thing needed for fully-automated recording.
#>
[CmdletBinding()] param([switch]$InstallFfmpeg)

$ok   = @()
$warn = @()

function Add-OK   { param($m) $script:ok   += $m; Write-Host "  [ OK ] $m" -ForegroundColor Green }
function Add-Warn { param($m) $script:warn += $m; Write-Host "  [WARN] $m" -ForegroundColor Yellow }

Write-Host "Demo Recorder - environment check" -ForegroundColor Cyan
Write-Host ("-" * 50)

# PowerShell
if ($PSVersionTable.PSVersion.Major -ge 5) { Add-OK "PowerShell $($PSVersionTable.PSVersion) (required)" }
else { Add-Warn "PowerShell $($PSVersionTable.PSVersion) is older than 5.1 - upgrade recommended." }

# Built-in .NET facilities
foreach ($asm in 'System.Windows.Forms','System.Drawing','System.Speech') {
    try { Add-Type -AssemblyName $asm -ErrorAction Stop; Add-OK "$asm available (built in)" }
    catch { Add-Warn "$asm failed to load: $($_.Exception.Message)" }
}
try { $null = New-Object -ComObject WScript.Shell; Add-OK "WScript.Shell (SendKeys/AppActivate) available" }
catch { Add-Warn "WScript.Shell unavailable: $($_.Exception.Message)" }

# TTS voices
try {
    Add-Type -AssemblyName System.Speech
    $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $voices = ($s.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo.Name }) -join ', '
    $s.Dispose()
    Add-OK "Narration voices: $voices"
} catch { Add-Warn "No TTS voices detected." }

# ffmpeg (optional - for automated recording)
$ff = Get-Command ffmpeg -ErrorAction SilentlyContinue
# Normalize to a path string: Get-Command yields a CommandInfo (.Source), the
# winget-path probe yields a FileInfo (.FullName). Mixing them broke `& $ff.Source`.
$onPath = [bool]$ff
$ffPath = if ($ff) { $ff.Source } else { $null }
if (-not $ffPath) {
    $guess = Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Filter ffmpeg.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($guess) { $ffPath = $guess.FullName }
}
if ($ffPath) {
    $ver = (& $ffPath -version 2>$null | Select-Object -First 1)
    Add-OK "ffmpeg found: $ffPath"
    if ($ver) { Write-Host "         $ver" -ForegroundColor DarkGray }
    if (-not $onPath) {
        Add-Warn "ffmpeg is installed but not on PATH for this session. Open a new terminal, or the engine will auto-locate it."
    }
} else {
    Add-Warn "ffmpeg NOT found (needed only for recording.mode = ffmpeg)."
    if ($InstallFfmpeg) {
        Write-Host "  Installing ffmpeg via winget..." -ForegroundColor Cyan
        winget install --id Gyan.FFmpeg -e --accept-package-agreements --accept-source-agreements
    } else {
        Write-Host "         Install with: winget install Gyan.FFmpeg" -ForegroundColor DarkGray
        Write-Host "         (or re-run: .\Check-Prereqs.ps1 -InstallFfmpeg)" -ForegroundColor DarkGray
    }
}

# Clipchamp (for manual mode)
$clip = Get-AppxPackage -Name "*Clipchamp*" -ErrorAction SilentlyContinue
if ($clip) { Add-OK "Clipchamp present (for recording.mode = manual)" }
else { Add-Warn "Clipchamp not found - any screen recorder works in manual mode." }

Write-Host ("-" * 50)
Write-Host "Ready to record automatically: " -NoNewline
if ($ffPath) { Write-Host "YES (ffmpeg mode)" -ForegroundColor Green }
else     { Write-Host "Manual mode only (install ffmpeg for hands-off recording)" -ForegroundColor Yellow }
