<#
.SYNOPSIS
  Download the self-contained Piper neural TTS binary + a voice model so the
  demo recorder can narrate with a natural, offline, free voice.

  No Python is installed or touched: Piper ships as a standalone Windows binary.
  Everything lands under tools/piper and voices/ in this repo (both gitignored).

.PARAMETER Voice
  Piper voice name, formatted <locale>-<name>-<quality> (default en_US-lessac-medium).
  Browse options at https://huggingface.co/rhasspy/piper-voices (e.g.
  en_US-ryan-medium, en_US-amy-medium, en_GB-alba-medium).

.PARAMETER Force
  Re-download even if files already exist.

.EXAMPLE
  .\Setup-Piper.ps1
.EXAMPLE
  .\Setup-Piper.ps1 -Voice en_US-ryan-medium
#>
[CmdletBinding()]
param([string]$Voice = 'en_US-lessac-medium', [switch]$Force)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root      = $PSScriptRoot
$toolsDir  = Join-Path $root 'tools'
$piperDir  = Join-Path $toolsDir 'piper'
$piperExe  = Join-Path $piperDir 'piper.exe'
$voicesDir = Join-Path $root 'voices'
$binUrl    = 'https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_windows_amd64.zip'

foreach ($d in $toolsDir, $voicesDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

# --- 1) Piper binary --------------------------------------------------------
if ((Test-Path $piperExe) -and -not $Force) {
    Write-Host "[ OK ] Piper binary already present: $piperExe" -ForegroundColor Green
} else {
    Write-Host "Downloading Piper binary..." -ForegroundColor Cyan
    $zip = Join-Path $env:TEMP 'piper_windows_amd64.zip'
    Invoke-WebRequest -Uri $binUrl -OutFile $zip -UseBasicParsing
    if (Test-Path $piperDir) { Remove-Item $piperDir -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $toolsDir -Force   # zip contains a top-level 'piper/' folder
    Remove-Item $zip -Force
    if (-not (Test-Path $piperExe)) { throw "Piper binary not found after extraction at $piperExe" }
    Write-Host "[ OK ] Installed Piper -> $piperExe" -ForegroundColor Green
}

# --- 2) Voice model ---------------------------------------------------------
# Voice name <locale>-<name>-<quality>, e.g. en_US-lessac-medium
$parts = $Voice -split '-'
if ($parts.Count -lt 3) { throw "Voice '$Voice' must look like <locale>-<name>-<quality>, e.g. en_US-lessac-medium." }
$locale  = $parts[0]
$name    = $parts[1]
$quality = $parts[2]
$lang    = ($locale -split '_')[0]
$base    = "https://huggingface.co/rhasspy/piper-voices/resolve/main/$lang/$locale/$name/$quality/$Voice"
$onnx     = Join-Path $voicesDir "$Voice.onnx"
$onnxJson = Join-Path $voicesDir "$Voice.onnx.json"

foreach ($item in @(@{ url = "$base.onnx"; path = $onnx }, @{ url = "$base.onnx.json"; path = $onnxJson })) {
    if ((Test-Path $item.path) -and -not $Force) {
        Write-Host "[ OK ] Voice file present: $([System.IO.Path]::GetFileName($item.path))" -ForegroundColor Green
    } else {
        Write-Host "Downloading $([System.IO.Path]::GetFileName($item.path))..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $item.url -OutFile $item.path -UseBasicParsing
    }
}
if ((Get-Item $onnx).Length -lt 1MB) { throw "Voice model looks too small; download may have failed: $onnx" }

# --- 3) Verify by rendering a test clip -------------------------------------
Write-Host "Rendering a test clip..." -ForegroundColor Cyan
$testWav = Join-Path $env:TEMP 'piper-setup-test.wav'
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $piperExe
$psi.Arguments = '-m "{0}" -f "{1}"' -f $onnx, $testWav
$psi.WorkingDirectory = $piperDir            # so piper finds its bundled espeak-ng-data
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardError = $true
$p = [System.Diagnostics.Process]::Start($psi)
$p.StandardInput.WriteLine("Piper neural text to speech is now set up and working.")
$p.StandardInput.Close()
$err = $p.StandardError.ReadToEnd()
$p.WaitForExit()

if ((Test-Path $testWav) -and (Get-Item $testWav).Length -gt 0) {
    Write-Host "[ OK ] Test render succeeded ($([Math]::Round((Get-Item $testWav).Length/1KB,1)) KB)." -ForegroundColor Green
    Remove-Item $testWav -Force
} else {
    Write-Host "[FAIL] Piper did not produce audio. stderr:" -ForegroundColor Red
    Write-Host $err -ForegroundColor DarkGray
    throw "Piper verification failed."
}

Write-Host ""
Write-Host "Done. Use it in a scenario with:" -ForegroundColor Cyan
Write-Host ('  "narration": { "engine": "piper", "piper": { "model": "voices/' + $Voice + '.onnx" } }') -ForegroundColor White
Write-Host '(tools/piper/piper.exe and this model are auto-detected, so just "engine":"piper" usually works.)' -ForegroundColor DarkGray
