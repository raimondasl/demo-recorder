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
    # crashSafe writes a fragmented MP4, which stays playable even if this process is
    # killed outright (closing the controller window, Ctrl+C, a crash) - without it the
    # moov atom is never written and the take is unreadable. Stop-DemoRecording remuxes
    # back to a normal +faststart file on the graceful path, so nothing is lost.
    $crashSafe = if ($R.ContainsKey('crashSafe')) { [bool]$R.crashSafe } else { $true }
    # Hard duration cap: if the controller dies, ffmpeg is orphaned and would otherwise
    # record until the disk fills. Generous by default; far beyond any demo.
    $maxSec  = if ($R.ContainsKey('maxSeconds')) { [int]$R.maxSeconds } else { 7200 }

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
    if ($maxSec -gt 0) { [void]$a.AddRange(@('-t', "$maxSec")) }
    if ($crashSafe) {
        # Fragmented MP4, a new fragment every second, flushed to disk immediately.
        # Verified empirically: with the movflags alone a kill -9 leaves a 28-byte
        # unreadable stub (output still buffered, keyframes too far apart); adding
        # -frag_duration + -flush_packets keeps the on-disk file playable at all
        # times, losing at most the final fragment.
        [void]$a.AddRange(@('-movflags', '+frag_keyframe+empty_moov+default_base_moof',
                            '-frag_duration', '1000000', '-flush_packets', '1'))
    } else {
        [void]$a.AddRange(@('-movflags', '+faststart'))
    }
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
                outputFile = $outFile; logFile = $logFile; ffmpeg = $ff
                crashSafe = $(if ($Recording.ContainsKey('crashSafe')) { [bool]$Recording.crashSafe } else { $true })
            }
        }
        default { throw "Unknown recording mode '$mode'. Use ffmpeg | manual | none." }
    }
}

# A crash-safe (fragmented) capture is playable as-is, but a normal +faststart MP4
# seeks better and is friendlier to editors. On the graceful stop path, remux with
# -c copy (lossless, ~instant). If anything goes wrong we keep the fragmented file,
# which is still perfectly playable - never trade a working take for a tidy one.
function Convert-ToFaststart {
    param([string]$Path, [string]$FfmpegPath)
    # -LiteralPath everywhere: an outputDir like "Q3 [final]" is a legal Windows path,
    # but Test-Path -Path would read [final] as a character class, silently decide the
    # file does not exist and skip the remux without a word.
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    $ff = if ($FfmpegPath) { $FfmpegPath } else { Test-FfmpegAvailable }
    if (-not $ff) { return $Path }
    $tmp = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($Path),
           [System.IO.Path]::GetFileNameWithoutExtension($Path) + '.faststart.tmp.mp4')
    $bak = $Path + '.bak'
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName  = $ff
        $psi.Arguments = ('-hide_banner -loglevel error -y -i "{0}" -c copy -movflags +faststart "{1}"' -f $Path, $tmp)
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        if ($p.ExitCode -eq 0 -and (Test-Path -LiteralPath $tmp) -and (Get-Item -LiteralPath $tmp).Length -gt 0) {
            # Atomic swap: the finished take keeps its name until the replacement is
            # actually in place. Never delete-then-rename - a failure there would
            # destroy the recording we just captured.
            [System.IO.File]::Replace($tmp, $Path, $bak)
            Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue
        } else {
            Write-Warning "Could not remux to faststart (keeping the crash-safe file, which is playable). ffmpeg: $err"
        }
    } catch {
        Write-Warning "Could not remux to faststart: $($_.Exception.Message)"
    } finally {
        foreach ($leftover in @($tmp, $bak)) {
            if (Test-Path -LiteralPath $leftover) { Remove-Item -LiteralPath $leftover -Force -ErrorAction SilentlyContinue }
        }
    }
    return $Path
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
            if ($Handle.ContainsKey('crashSafe') -and $Handle.crashSafe) {
                $ffPath = if ($Handle.ContainsKey('ffmpeg')) { $Handle.ffmpeg } else { $null }
                [void](Convert-ToFaststart -Path $Handle.outputFile -FfmpegPath $ffPath)
            }
            return $Handle.outputFile
        }
    }
}

# Overlay timestamped narration WAV clips onto a (silent) captured video.
# Each clip is delayed to its offset and all clips are mixed into one audio
# track; the video stream is copied (no re-encode), so this is fast and lossless.
# On success the original file is replaced in place; on failure the silent video
# is kept and a warning is emitted.
function Add-NarrationToVideo {
    param([string]$VideoFile, [object[]]$Clips, [string]$FfmpegPath)
    if (-not $Clips -or $Clips.Count -eq 0) { return $VideoFile }
    if (-not (Test-Path $VideoFile)) { Write-Warning "Video not found for narration mux: $VideoFile"; return $VideoFile }
    $ff = if ($FfmpegPath) { $FfmpegPath } else { Test-FfmpegAvailable }
    if (-not $ff) { Write-Warning "ffmpeg not found; leaving the video without narration."; return $VideoFile }

    $dir  = [System.IO.Path]::GetDirectoryName($VideoFile)
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($VideoFile)
    $tmp  = Join-Path $dir ($stem + '.narrated.mp4')
    $log  = Join-Path $dir ($stem + '.mux.log')

    # Build: -i video -i clip1 -i clip2 ... -filter_complex "<delays>;<mix>" ...
    $ffArgs = New-Object System.Collections.ArrayList
    [void]$ffArgs.AddRange(@('-y', '-i', $VideoFile))
    foreach ($c in $Clips) { [void]$ffArgs.AddRange(@('-i', $c.file)) }

    $chains = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Clips.Count; $i++) {
        $off = [int]$Clips[$i].offsetMs
        [void]$chains.Add(("[{0}:a]adelay=delays={1}:all=1[a{0}]" -f ($i + 1), $off))
    }
    $mixIn  = ((1..$Clips.Count) | ForEach-Object { "[a$_]" }) -join ''
    $filter = ($chains -join ';') + ';' + $mixIn + ("amix=inputs={0}:normalize=0[aout]" -f $Clips.Count)

    [void]$ffArgs.AddRange(@(
        '-filter_complex', $filter,
        '-map', '0:v', '-map', '[aout]',
        '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k',
        '-movflags', '+faststart', $tmp
    ))

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = $ff
    # Only spaces require quoting for CommandLineToArgvW; the filter graph has none.
    $psi.Arguments = ($ffArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardError  = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $err  = $proc.StandardError.ReadToEnd()   # drain fully (blocks until exit) - no deadlock
    $proc.WaitForExit()
    Set-Content -Path $log -Value $err -Encoding UTF8

    if ($proc.ExitCode -ne 0 -or -not (Test-Path $tmp)) {
        Write-Warning "Narration mux failed (ffmpeg exit $($proc.ExitCode)); keeping silent video. See $log"
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        return $VideoFile
    }
    Remove-Item $VideoFile -Force
    Rename-Item -Path $tmp -NewName ([System.IO.Path]::GetFileName($VideoFile))
    Remove-Item $log -Force -ErrorAction SilentlyContinue
    return $VideoFile
}

Export-ModuleMember -Function Test-FfmpegAvailable, Start-DemoRecording, Stop-DemoRecording, Add-NarrationToVideo, Convert-ToFaststart
