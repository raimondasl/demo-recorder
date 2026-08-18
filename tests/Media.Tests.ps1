<#
  Media tests that exercise the real ffmpeg paths without needing a screen:
  test clips are generated with ffmpeg's lavfi source, then trimmed and muxed.
  Requires ffmpeg + ffprobe (installed by CI; auto-located locally). Skipped if absent.
#>

function Find-Tool {
    param([string]$Name)
    $c = Get-Command $Name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $g = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Filter "$Name.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($g) { return $g.FullName }
    return $null
}
$HasFfmpeg = [bool](Find-Tool 'ffmpeg')

Describe 'Media (ffmpeg)' -Skip:(-not $HasFfmpeg) {
    BeforeAll {
        # Re-defined here because discovery-phase functions aren't visible in the run phase.
        function Find-Tool {
            param([string]$Name)
            $c = Get-Command $Name -ErrorAction SilentlyContinue
            if ($c) { return $c.Source }
            $g = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Filter "$Name.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($g) { return $g.FullName }
            return $null
        }
        Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\Recorder.psm1') -Force -DisableNameChecking
        $script:ffmpeg  = Find-Tool 'ffmpeg'
        $script:ffprobe = Find-Tool 'ffprobe'
        $script:work = Join-Path $env:TEMP ("demorec-tests-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:work -Force | Out-Null

        # -hide_banner -loglevel error => no stderr on success, so ffmpeg's banner
        # can't be wrapped into a terminating NativeCommandError under ErrorAction=Stop.
        function script:New-TestVideo { param($Path, $Dur)
            & $script:ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc=duration=${Dur}:size=320x240:rate=15" -pix_fmt yuv420p $Path | Out-Null
        }
        function script:New-TestWav { param($Path, $Dur)
            & $script:ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=440:duration=${Dur}" -ar 24000 -ac 1 $Path | Out-Null
        }
        function script:New-TestAV { param($Path, $Dur)   # video + audio
            & $script:ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc=duration=${Dur}:size=320x240:rate=15" -f lavfi -i "sine=frequency=440:duration=${Dur}" -pix_fmt yuv420p -c:a aac -shortest $Path | Out-Null
        }
        function script:Get-StreamTypes { param($Path)
            (& $script:ffprobe -hide_banner -v error -show_entries stream=codec_type -of default=noprint_wrappers=1:nokey=1 $Path) -join ','
        }
        function script:Get-Dur { param($Path)
            [double](& $script:ffprobe -hide_banner -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $Path)
        }
    }
    AfterAll {
        if ($script:work -and (Test-Path $script:work)) { Remove-Item $script:work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'ffmpeg + ffprobe are available' {
        $script:ffmpeg  | Should -Not -BeNullOrEmpty
        $script:ffprobe | Should -Not -BeNullOrEmpty
    }

    Context 'Trim-Recording.ps1' {
        It 'removes the requested seconds from the start' {
            $src = Join-Path $script:work 'src.mp4'
            New-TestVideo $src 5
            (Get-Dur $src) | Should -BeGreaterThan 4.5
            & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path (Split-Path $PSScriptRoot -Parent) 'Trim-Recording.ps1') $src -StartSec 2 | Out-Null
            $out = Join-Path $script:work 'src-trim.mp4'
            Test-Path $out | Should -BeTrue
            (Get-Dur $out) | Should -BeGreaterThan 2.5
            (Get-Dur $out) | Should -BeLessThan 3.6
        }
    }

    Context 'Add-NarrationToVideo mux' {
        It 'produces a file with both a video and an audio stream' {
            $vid = Join-Path $script:work 'v.mp4'; New-TestVideo $vid 6
            $w1 = Join-Path $script:work 'n1.wav'; New-TestWav $w1 1
            $w2 = Join-Path $script:work 'n2.wav'; New-TestWav $w2 1
            $final = Add-NarrationToVideo -VideoFile $vid -Clips @(
                @{ file = $w1; offsetMs = 500 }, @{ file = $w2; offsetMs = 3000 }
            ) -FfmpegPath $script:ffmpeg
            $types = (& $script:ffprobe -v error -show_entries stream=codec_type -of default=noprint_wrappers=1:nokey=1 $final) -join ','
            $types | Should -Match 'video'
            $types | Should -Match 'audio'
        }

        It 'returns the original file unchanged when there are no clips' {
            $vid = Join-Path $script:work 'v2.mp4'; New-TestVideo $vid 2
            $before = (Get-Item $vid).Length
            $out = Add-NarrationToVideo -VideoFile $vid -Clips @() -FfmpegPath $script:ffmpeg
            $out | Should -Be $vid
            (Get-Item $vid).Length | Should -Be $before
        }
    }

    Context 'Cut-Recording.ps1' {
        BeforeAll { $script:cut = Join-Path (Split-Path $PSScriptRoot -Parent) 'Cut-Recording.ps1' }

        It 'removes a middle interval and rejoins (audio kept)' {
            $src = Join-Path $script:work 'cav.mp4'; New-TestAV $src 8
            & powershell -NoProfile -ExecutionPolicy Bypass -File $script:cut $src -From 3 -To 5 | Out-Null
            $out = Join-Path $script:work 'cav-cut.mp4'
            Test-Path $out | Should -BeTrue
            (Get-Dur $out) | Should -BeGreaterThan 5.5   # 8 - 2
            (Get-Dur $out) | Should -BeLessThan 6.5
            Get-StreamTypes $out | Should -Match 'video'
            Get-StreamTypes $out | Should -Match 'audio'
        }

        It 'extracts only the interval with -Keep' {
            $src = Join-Path $script:work 'kav.mp4'; New-TestAV $src 8
            $out = Join-Path $script:work 'kav-keep.mp4'
            & powershell -NoProfile -ExecutionPolicy Bypass -File $script:cut $src -From 2 -To 5 -Keep -OutPath $out | Out-Null
            (Get-Dur $out) | Should -BeGreaterThan 2.5
            (Get-Dur $out) | Should -BeLessThan 3.5
        }

        It 'works on a video-only recording (no-audio branch)' {
            $src = Join-Path $script:work 'vonly.mp4'; New-TestVideo $src 8
            & powershell -NoProfile -ExecutionPolicy Bypass -File $script:cut $src -From 3 -To 5 | Out-Null
            $out = Join-Path $script:work 'vonly-cut.mp4'
            (Get-Dur $out) | Should -BeGreaterThan 5.5
            (Get-Dur $out) | Should -BeLessThan 6.5
            Get-StreamTypes $out | Should -Not -Match 'audio'
        }
    }

    Context 'Crash-safe container survives a hard kill' {
        It 'leaves a playable file when ffmpeg is killed outright' {
            # Regression test for PR #6: a non-crash-safe capture killed mid-flight
            # leaves an unreadable stub ("moov atom not found"). Uses lavfi (no screen).
            $out = Join-Path $script:work 'killed.mp4'
            $ffArgs = @('-hide_banner','-loglevel','error','-y','-f','lavfi','-i','testsrc=size=320x240:rate=15',
                      '-c:v','libx264','-preset','ultrafast','-crf','32','-pix_fmt','yuv420p',
                      '-movflags','+frag_keyframe+empty_moov+default_base_moof',
                      '-frag_duration','1000000','-flush_packets','1', $out)
            $p = Start-Process -FilePath $script:ffmpeg -ArgumentList $ffArgs -PassThru -WindowStyle Hidden
            Start-Sleep -Seconds 5
            $p.Kill(); $p.WaitForExit(5000) | Out-Null
            Start-Sleep -Milliseconds 500
            (Get-Dur $out) | Should -BeGreaterThan 1     # readable, i.e. moov/fragments on disk
        }
    }

    Context 'Convert-ToFaststart' {
        It 'remuxes a fragmented capture to a normal faststart mp4, preserving duration' {
            $frag = Join-Path $script:work 'frag.mp4'
            & $script:ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc=duration=4:size=320x240:rate=15" `
                -c:v libx264 -preset ultrafast -crf 32 -pix_fmt yuv420p `
                -movflags '+frag_keyframe+empty_moov+default_base_moof' -frag_duration 1000000 -flush_packets 1 $frag | Out-Null
            $before = Get-Dur $frag
            [void](Convert-ToFaststart -Path $frag -FfmpegPath $script:ffmpeg)
            (Get-Dur $frag) | Should -BeGreaterThan ($before - 0.5)
            # A fragmented capture also carries moov at the front (empty_moov), so a
            # moov check proves nothing. Only a real remux removes the moof fragment boxes.
            $all = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($frag))
            $all | Should -Not -Match 'moof'
        }
        It 'still remuxes when the output directory name contains brackets' {
            # Regression: Test-Path -Path treats [final] as a character class, so the
            # remux was silently skipped for perfectly legal Windows paths.
            $dir = Join-Path $script:work 'Q3 [final]'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $frag = Join-Path $dir 'brk.mp4'
            & $script:ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc=duration=3:size=320x240:rate=15" `
                -c:v libx264 -preset ultrafast -crf 32 -pix_fmt yuv420p `
                -movflags '+frag_keyframe+empty_moov+default_base_moof' -frag_duration 1000000 -flush_packets 1 $frag | Out-Null
            [void](Convert-ToFaststart -Path $frag -FfmpegPath $script:ffmpeg)
            $all = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($frag))
            $all | Should -Not -Match 'moof'
        }
        It 'keeps the original take when the remux fails' {
            # The take must never be deleted before a working replacement is in place.
            $frag = Join-Path $script:work 'keepme.mp4'
            & $script:ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc=duration=3:size=320x240:rate=15" `
                -c:v libx264 -preset ultrafast -crf 32 -pix_fmt yuv420p $frag | Out-Null
            $before = (Get-Item -LiteralPath $frag).Length
            # Point at a bogus ffmpeg so the remux cannot succeed.
            [void](Convert-ToFaststart -Path $frag -FfmpegPath (Join-Path $script:work 'no-such-ffmpeg.exe') -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
            Test-Path -LiteralPath $frag | Should -BeTrue
            (Get-Item -LiteralPath $frag).Length | Should -Be $before
            (Get-Dur $frag) | Should -BeGreaterThan 2      # still playable
        }
        It 'returns the path unchanged when the file does not exist' {
            Convert-ToFaststart -Path (Join-Path $script:work 'nope.mp4') -FfmpegPath $script:ffmpeg |
                Should -Be (Join-Path $script:work 'nope.mp4')
        }
    }
}
