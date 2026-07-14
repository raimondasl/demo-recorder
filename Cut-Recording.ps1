<#
.SYNOPSIS
  Remove an interval from inside a recording (keep the parts before and after and
  rejoin them), or extract just that interval with -Keep.

.DESCRIPTION
  Frame-accurate: the kept segments are re-encoded and concatenated with ffmpeg's
  trim/concat filters. Works whether or not the recording has an audio track
  (e.g. narrated demos have AAC audio; silent captures don't).

.PARAMETER Path
  The .mp4 to edit.

.PARAMETER From
  Start of the interval. Seconds (e.g. 12.5) or a timestamp (mm:ss / hh:mm:ss).

.PARAMETER To
  End of the interval. Same formats as -From.

.PARAMETER Keep
  Keep ONLY the [From, To] interval (extract a clip) instead of removing it.

.PARAMETER OutPath
  Output file. Default: "<name>-cut.mp4" next to the input.

.PARAMETER InPlace
  Overwrite the original file.

.EXAMPLE
  # Remove the segment from 00:12 to 00:18 and rejoin the rest:
  .\Cut-Recording.ps1 .\recordings\demo.mp4 -From 12 -To 18
.EXAMPLE
  # Keep only 00:30 to 00:45:
  .\Cut-Recording.ps1 .\recordings\demo.mp4 -From 0:30 -To 0:45 -Keep
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)] [string]$Path,
    [Parameter(Mandatory = $true)] [string]$From,
    [Parameter(Mandatory = $true)] [string]$To,
    [switch]$Keep,
    [string]$OutPath,
    [switch]$InPlace
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

if (-not (Test-Path $Path)) { throw "File not found: $Path" }
$Path = (Resolve-Path $Path).Path

function ConvertTo-Seconds([string]$t) {
    if ($t -match '^\d+(\.\d+)?$') { return [double]::Parse($t, $inv) }
    $s = 0.0
    foreach ($p in ($t -split ':')) { $s = $s * 60 + [double]::Parse($p, $inv) }
    return $s
}

function Find-Tool([string]$name) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $g = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Filter "$name.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($g) { return $g.FullName }
    return $null
}
$ffmpeg  = Find-Tool 'ffmpeg'
$ffprobe = Find-Tool 'ffprobe'
if (-not $ffmpeg)  { throw "ffmpeg not found. Install it: winget install Gyan.FFmpeg" }
if (-not $ffprobe) { throw "ffprobe not found (comes with ffmpeg)." }

$fromS = ConvertTo-Seconds $From
$toS   = ConvertTo-Seconds $To
$dur   = [double]::Parse((& $ffprobe -hide_banner -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $Path | Select-Object -First 1), $inv)
if ($fromS -lt 0 -or $toS -gt $dur + 0.05 -or $fromS -ge $toS) {
    throw ("Invalid interval: from=$fromS to=$toS (video is $([Math]::Round($dur,2))s). Need 0 <= from < to <= duration.")
}

# Determine which time ranges to KEEP.
if ($Keep) {
    $segs = @(@{ s = $fromS; e = $toS })
} else {
    $segs = @()
    if ($fromS -gt 0.001)      { $segs += @{ s = 0.0;   e = $fromS } }
    if ($toS   -lt $dur - 0.001) { $segs += @{ s = $toS; e = $dur } }
    if ($segs.Count -eq 0) { throw "Removing [$fromS,$toS] would leave nothing." }
}

# Does the file have an audio stream?
$hasAudio = [bool]((& $ffprobe -hide_banner -v error -select_streams a -show_entries stream=index -of csv=p=0 $Path) | Select-Object -First 1)

# Build the trim/concat filter graph over the kept segments.
$defs = @(); $concatIn = ''
for ($i = 0; $i -lt $segs.Count; $i++) {
    $s = ([double]$segs[$i].s).ToString($inv); $e = ([double]$segs[$i].e).ToString($inv)
    $defs += "[0:v]trim=start=${s}:end=${e},setpts=PTS-STARTPTS[v$i]"
    $concatIn += "[v$i]"
    if ($hasAudio) { $defs += "[0:a]atrim=start=${s}:end=${e},asetpts=PTS-STARTPTS[a$i]"; $concatIn += "[a$i]" }
}
$aFlag  = if ($hasAudio) { 1 } else { 0 }
$filter = ($defs -join ';') + ";${concatIn}concat=n=$($segs.Count):v=1:a=$aFlag[v]" + $(if ($hasAudio) { '[a]' } else { '' })

# Output path
if ($InPlace)     { $out = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($Path), [System.IO.Path]::GetFileNameWithoutExtension($Path) + '.cut.tmp.mp4') }
elseif ($OutPath) { $out = $OutPath }
else              { $out = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($Path), [System.IO.Path]::GetFileNameWithoutExtension($Path) + '-cut.mp4') }

$ffArgs = @('-hide_banner', '-loglevel', 'error', '-y', '-i', $Path, '-filter_complex', $filter, '-map', '[v]')
if ($hasAudio) { $ffArgs += @('-map', '[a]', '-c:a', 'aac') }
$ffArgs += @('-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20', '-movflags', '+faststart', $out)

$verb = if ($Keep) { "Extracting" } else { "Cutting out" }
Write-Host "$verb [$From, $To] in $([System.IO.Path]::GetFileName($Path))..." -ForegroundColor Cyan

# Run ffmpeg via ProcessStartInfo so stderr is captured (no PS 5.1 NativeCommandError wrapping).
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
