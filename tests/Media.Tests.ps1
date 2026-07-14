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
}
