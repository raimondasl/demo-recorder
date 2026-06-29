<#
.SYNOPSIS
  Video-capture backends for the demo recorder.

  Modes:
    ffmpeg  - fully automated screen capture via ffmpeg + gdigrab (Phase 1 default).
              Stopped GRACEFULLY by writing 'q' to ffmpeg's stdin so the MP4 is
              finalized (a hard kill would leave an unplayable file).
    manual  - the operator starts/stops their own recorder (e.g. Clipchamp). The
              engine just prompts and waits. This is the original MVP path.
    none    - run the scenario with no recording (useful for rehearsing).
    obs     - reserved for a later phase (OBS WebSocket); throws a clear message.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-FfmpegAvailable {
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # winget installs may not be on PATH yet in this session; probe common locations.
    $guess = Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Filter ffmpeg.exe -Recurse -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if ($guess) { return $guess.FullName }
    return $null
}

function New-FfmpegArgs {
    param([hashtable]$R, [string]$OutFile)
    $fps     = if ($R.ContainsKey('framerate')) { [int]$R.framerate } else { 30 }
    $crf     = if ($R.ContainsKey('crf'))       { [int]$R.crf }       else { 23 }
    $preset  = if ($R.ContainsKey('preset'))    { [string]$R.preset } else { 'veryfast' }
    $cursor  = if ($R.ContainsKey('captureCursor')) { [bool]$R.captureCursor } else { $true }

    $a = New-Object System.Collections.ArrayList
    [void]$a.AddRange(@('-y', '-f', 'gdigrab', '-framerate', "$fps", '-draw_mouse', $(if ($cursor) {'1'} else {'0'})))

    $region = $null
    if ($R.ContainsKey('region')) { $region = $R.region }
    if ($region -and $region.PSObject.Properties.Name -contains 'window' -and $region.window) {
        [void]$a.AddRange(@('-i', "title=$($region.window)"))
    } elseif ($region -and $region.PSObject.Properties.Name -contains 'width') {
        [void]$a.AddRange(@('-offset_x', "$($region.x)", '-offset_y', "$($region.y)", '-video_size', "$($region.width)x$($region.height)", '-i', 'desktop'))
    } else {
        [void]$a.AddRange(@('-i', 'desktop'))
    }

    # Optional audio loopback (e.g. "Stereo Mix (Realtek(R) Audio)") to capture narration/system sound.
    $haveAudio = $false
    if ($R.ContainsKey('audioDevice') -and $R.audioDevice) {
        [void]$a.AddRange(@('-f', 'dshow', '-rtbufsize', '256M', '-i', "audio=$($R.audioDevice)"))
        $haveAudio = $true
    }

    [void]$a.AddRange(@('-c:v', 'libx264', '-preset', $preset, '-crf', "$crf", '-pix_fmt', 'yuv420p'))
    # Force even dimensions (libx264 + yuv420p requirement) when capturing odd regions.
    [void]$a.AddRange(@('-vf', 'crop=trunc(iw/2)*2:trunc(ih/2)*2'))
    if ($haveAudio) { [void]$a.AddRange(@('-c:a', 'aac', '-b:a', '160k')) }
    [void]$a.AddRange(@('-movflags', '+faststart'))
    [void]$a.Add($OutFile)
    return ($a.ToArray())
}

function Start-DemoRecording {
    param([hashtable]$Recording, [string]$OutputDir, [string]$BaseName, [string]$TimeStamp)

    $mode = if ($Recording.ContainsKey('mode')) { [string]$Recording.mode } else { 'ffmpeg' }

    switch ($mode) {
        'none' {
            return @{ mode = 'none' }
        }
        'manual' {
            Write-Host ''
            Write-Host '  >>> MANUAL RECORDING <<<' -ForegroundColor Yellow
            Write-Host '  Start your screen recorder now (e.g. Clipchamp: New video > Record > Screen).' -ForegroundColor Yellow
            Write-Host '  Press ENTER here once it is recording to begin the demo...' -ForegroundColor Yellow
            [void](Read-Host)
            return @{ mode = 'manual' }
        }
        'obs' {
            throw "Recording mode 'obs' is reserved for a later phase. Use 'ffmpeg' (automated) or 'manual' for now."
        }
        'ffmpeg' {
            $ff = Test-FfmpegAvailable
            if (-not $ff) {
                throw "ffmpeg not found. Install it (``winget install Gyan.FFmpeg``) or set recording.mode to 'manual'."
            }
            if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
            $outFile = Join-Path $OutputDir ("{0}-{1}.mp4" -f $BaseName, $TimeStamp)
            $logFile = Join-Path $OutputDir ("{0}-{1}.ffmpeg.log" -f $BaseName, $TimeStamp)
            $ffArgs  = New-FfmpegArgs -R $Recording -OutFile $outFile

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName               = $ff
            $psi.Arguments              = ($ffArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
            $psi.UseShellExecute        = $false
            $psi.CreateNoWindow         = $true
            $psi.RedirectStandardInput  = $true
            $psi.RedirectStandardError  = $true
            $psi.RedirectStandardOutput = $false

            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $psi

            # Drain stderr asynchronously into a log file so the pipe never blocks ffmpeg.
            $writer = New-Object System.IO.StreamWriter($logFile, $false)
            $writer.AutoFlush = $true
            $errEvent = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -MessageData $writer -Action {
                if ($EventArgs.Data) { try { $Event.MessageData.WriteLine($EventArgs.Data) } catch {} }
            }
            [void]$proc.Start()
            $proc.BeginErrorReadLine()
            Start-Sleep -Milliseconds 700   # let capture spin up before the demo starts

            if ($proc.HasExited) {
                $writer.Close()
                throw "ffmpeg exited immediately (code $($proc.ExitCode)). See log: $logFile"
            }
            Write-Host "  Recording (ffmpeg) -> $outFile" -ForegroundColor Green
            return @{
                mode = 'ffmpeg'; process = $proc; writer = $writer; event = $errEvent;
                outputFile = $outFile; logFile = $logFile
            }
        }
        default { throw "Unknown recording mode '$mode'. Use ffmpeg | manual | none." }
    }
}

function Stop-DemoRecording {
    param([hashtable]$Handle)
    if (-not $Handle) { return $null }
    switch ($Handle.mode) {
        'none'   { return $null }
        'manual' {
            Write-Host ''
            Write-Host '  >>> Demo complete. STOP and SAVE your recording now (Clipchamp: Finish/Stop). <<<' -ForegroundColor Yellow
            return $null
        }
        'ffmpeg' {
            $proc = $Handle.process
            try {
                if (-not $proc.HasExited) {
                    $proc.StandardInput.Write('q')      # graceful stop -> finalizes the MP4
                    $proc.StandardInput.Flush()
                    $proc.StandardInput.Close()
                    if (-not $proc.WaitForExit(12000)) {
                        Write-Warning 'ffmpeg did not stop gracefully in time; terminating (file may be slightly truncated).'
                        $proc.Kill(); $proc.WaitForExit(3000) | Out-Null
                    }
                }
            } catch {
                Write-Warning "Error stopping ffmpeg: $($_.Exception.Message)"
                try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
            } finally {
                try { Unregister-Event -SourceIdentifier $Handle.event.Name -ErrorAction SilentlyContinue } catch {}
                try { $Handle.writer.Close() } catch {}
            }
            return $Handle.outputFile
        }
    }
}

Export-ModuleMember -Function Test-FfmpegAvailable, Start-DemoRecording, Stop-DemoRecording
