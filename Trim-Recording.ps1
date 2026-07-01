<#
.SYNOPSIS
  Trim seconds off the start (and/or end) of a demo recording with ffmpeg.

.DESCRIPTION
  Defaults to cutting the first 3 seconds (the startup dead time) and re-encoding
  for a frame-accurate, clean cut. Use -Fast for an instant, lossless cut that
  snaps to the nearest keyframe (may land a bit off the requested time).

.PARAMETER Path
  The .mp4 to trim.

.PARAMETER StartSec
  Seconds to remove from the start (default 3).

.PARAMETER EndTrimSec
  Seconds to remove from the end (default 0).

.PARAMETER OutPath
  Output file. Default: "<name>-trim.mp4" next to the input.

.PARAMETER Fast
  Use stream copy (-c copy): instant and lossless, but cuts at the nearest
  keyframe rather than exactly at StartSec.

.PARAMETER InPlace
  Overwrite the original file.

.EXAMPLE
  .\Trim-Recording.ps1 .\recordings\git-cli-demo-20260630-210032.mp4
.EXAMPLE
  .\Trim-Recording.ps1 .\recordings\demo.mp4 -StartSec 5 -EndTrimSec 2
.EXAMPLE
  .\Trim-Recording.ps1 .\recordings\demo.mp4 -InPlace
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)] [string]$Path,
    [double]$StartSec = 3,
    [double]$EndTrimSec = 0,
    [string]$OutPath,
    [switch]$Fast,
    [switch]$InPlace
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

if (-not (Test-Path $Path)) { throw "File not found: $Path" }
$Path = (Resolve-Path $Path).Path

# Locate ffmpeg / ffprobe (PATH first, then the winget install location).
function Find-Tool($name) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $g = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Filter "$name.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($g) { return $g.FullName }
    return $null
}
$ffmpeg  = Find-Tool 'ffmpeg'
$ffprobe = Find-Tool 'ffprobe'
if (-not $ffmpeg) { throw "ffmpeg not found. Install it: winget install Gyan.FFmpeg" }

# Output path
if ($InPlace) {
    $out = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($Path), [System.IO.Path]::GetFileNameWithoutExtension($Path) + '.trim.tmp.mp4')
} elseif ($OutPath) {
    $out = $OutPath
} else {
    $out = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($Path), [System.IO.Path]::GetFileNameWithoutExtension($Path) + '-trim.mp4')
}

# Build args. -ss before -i seeks fast; combined with re-encode it's frame-accurate.
$ffArgs = @('-hide_banner', '-loglevel', 'error', '-y', '-ss', $StartSec.ToString($inv), '-i', $Path)

if ($EndTrimSec -gt 0) {
    if (-not $ffprobe) { throw "ffprobe not found (needed for -EndTrimSec)." }
    $durRaw = (& $ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $Path) | Select-Object -First 1
    $total  = [double]::Parse($durRaw, $inv)
    $keep   = $total - $StartSec - $EndTrimSec
    if ($keep -le 0) { throw "Nothing left to keep: total=$([Math]::Round($total,2))s, start=$StartSec, endTrim=$EndTrimSec." }
    $ffArgs += @('-t', $keep.ToString($inv))
}

if ($Fast) {
    $ffArgs += @('-c', 'copy')
} else {
    $ffArgs += @('-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20', '-c:a', 'aac')
}
$ffArgs += @('-movflags', '+faststart', $out)

Write-Host "Trimming $([System.IO.Path]::GetFileName($Path)) (start -$StartSec s$(if($EndTrimSec){", end -$EndTrimSec s"}))..." -ForegroundColor Cyan
# Run ffmpeg via ProcessStartInfo so its stderr is captured cleanly (avoids the
# PowerShell 5.1 NativeCommandError wrapping that '2>$null' triggers).
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName  = $ffmpeg
$psi.Arguments = ($ffArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
$psi.UseShellExecute = $false
$psi.CreateNoWindow  = $true
$psi.RedirectStandardError = $true
$proc = [System.Diagnostics.Process]::Start($psi)
$err  = $proc.StandardError.ReadToEnd()
$proc.WaitForExit()
if ($proc.ExitCode -ne 0 -or -not (Test-Path $out)) { throw "ffmpeg failed (exit $($proc.ExitCode)):`n$err" }

if ($InPlace) {
    Remove-Item $Path -Force
    Rename-Item -Path $out -NewName ([System.IO.Path]::GetFileName($Path))
    $final = $Path
} else {
    $final = $out
}
Write-Host "Saved -> $final" -ForegroundColor Green
