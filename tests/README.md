# Tests

Pester tests, run in GitHub Actions on `windows-latest` (Windows PowerShell 5.1)
and locally.

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Force -SkipPublisherCheck -Scope CurrentUser
Import-Module Pester -MinimumVersion 5.0 -Force
Invoke-Pester -Path .\tests -Output Detailed
```

## What's covered

**`Unit.Tests.ps1`** — pure logic, no display/audio/network:
- Module load + key exports.
- SendKeys encoding (`ConvertTo-SendKeysLiteral`, `ConvertTo-SendKeysChord`), including rejection of invalid keys/modifiers.
- Settings resolution (`Get-Prop`) — explicit `false`/`0` respected, defaults, null objects.
- Scenario validation — bundled examples pass; malformed scenarios produce the expected errors.
- ffmpeg argument building (`New-FfmpegArgs`) — desktop / window-title / audio variants.

**`Media.Tests.ps1`** — real ffmpeg paths, using generated test clips (ffmpeg
`lavfi`), so **no screen is needed**:
- `Trim-Recording.ps1` cuts the requested seconds off the start (verified with `ffprobe`).
- `Cut-Recording.ps1` removes an interval from the middle, extracts one (`-Keep`), and handles the video-only (no-audio) path.
- `Add-NarrationToVideo` muxes WAV clips into a silent video (asserts video+audio streams).

Requires `ffmpeg`/`ffprobe` (installed by CI; auto-located locally). These tests
skip if ffmpeg is absent.

## What is intentionally *not* covered (can't run headlessly)

- **GUI automation** — SendKeys into live windows, window focus/move, mouse clicks.
  Needs an interactive desktop session; CI runners are non-interactive.
- **On-screen captions** — top-most WinForms overlay (needs a display).
- **Audio playback** — `SoundPlayer` narration playback (needs an audio device).
- **Screen capture via gdigrab** — the live `Start/Stop-DemoRecording` path needs a
  real desktop; the mux/trim tests exercise ffmpeg instead.
- **Live cloud TTS** (`azure`/`openai`) — would need real API keys/secrets and would
  bill; only the request-shape was verified manually (dummy key → HTTP 401).
- **Piper / WinRT / SAPI rendering** — voice models / OS voices vary by machine.

These are validated manually on a real Windows desktop.
