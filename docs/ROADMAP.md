# Roadmap

Status of planned work. Done items are listed for context; the rest are ordered
roughly by priority.

## Done
- [x] ffmpeg automated recording (start → graceful stop → playable MP4)
- [x] Manual (Clipchamp) and `none` recording modes
- [x] Scenario format + JSON Schema + Claude generation prompt + validator
- [x] On-screen captions (click-through, non-focus-stealing) and screenshots
- [x] Narration baked into the video (render → timestamp → ffmpeg mux; no Stereo Mix)
- [x] **`winrt` / `sapi` narration engines** — built-in Windows OneCore / legacy voices
- [x] **`piper` narration engine** — offline neural voices (free, natural; `Setup-Piper.ps1`)
- [x] **Larger terminal font** for demos (`settings.terminal.*`; classic `conhost` + `HKCU\Console`, restored after)
- [x] **`Trim-Recording.ps1`** — cut the start/end off a recording (re-encode or fast copy)

> Note: Windows 11 "Natural" voices added via Narrator (Aria/Ava/Andrew) are
> packaged as Narrator-only app packages and are NOT exposed to the SAPI/WinRT
> speech APIs, so no third-party app can synthesize with them. Piper fills that
> gap for free/offline neural narration.

## Narration voices — additional engines

The narration engine is pluggable: each provider just needs to turn text into a
WAV, which the existing timestamp+mux pipeline then bakes into the video. Adding
a provider means a new `Render-NarrationWav*` function in `modules/Overlay.psm1`
and a new `narration.engine` value.

### Cloud neural TTS (highest quality) — planned
Best naturalness/expressiveness. Pre-render each line to WAV at run time.
- **Candidates:** Azure AI Speech (neural, generous free tier), OpenAI TTS
  (`gpt-4o-mini-tts` — cheap, simple), ElevenLabs (most expressive, pricier).
- **Needs:** an API key (read from an env var, never committed), internet, and a
  small per-character cost.
- **Design sketch:** `narration.engine: "azure" | "openai" | "elevenlabs"`, with
  `narration.apiKeyEnv`, `narration.model`, `narration.voice`. Cache WAVs by a
  hash of (text+voice+engine) so re-runs don't re-bill. Fail closed to `winrt`
  with a clear warning if the key is missing or the call fails.

### Piper (free, local, offline neural) — DONE
Implemented via the self-contained Piper Windows binary (no Python at all).
`Setup-Piper.ps1` downloads `tools/piper/piper.exe` + a voice model into `voices/`;
`narration.engine: "piper"` renders each line with `Render-NarrationWavPiper`
(text on stdin → WAV), which feeds the existing mux pipeline. Pick voices with
`Setup-Piper.ps1 -Voice <name>`. Possible follow-ups: bundle more default voices,
optional GPU (onnxruntime) build.

## Recording
- [ ] **`obs` mode** — OBS WebSocket (obsws): scenes, webcam overlay, picture-in-
      picture, higher-quality capture. (`obs` currently throws on purpose.)
- [ ] Per-window / region capture helpers and a small picker UI.
- [ ] Optional hardware-encoder presets (NVENC/QSV) for lighter CPU use.

## Engine / authoring
- [ ] Coordinate-free UI targeting (UI Automation) to reduce reliance on `click`.
- [ ] `cmd` / WSL / Windows Terminal presets for `run`.
- [ ] A `verify`-style assertion step (wait for a window/text to appear).
- [ ] Per-step retry/timeout and an on-error policy (continue vs. abort).

## Post-processing & polish
- [ ] **Built-in auto-trim** — `recording.trimStartSec` (and `trimEndSec`) so a demo
      trims its own startup dead time after recording stops, reusing the
      `Trim-Recording.ps1` logic. (The countdown already runs before recording,
      so the first ~3s is mostly the controller minimizing + first caption/terminal.)
- [ ] **Batch trim** — a flag/mode to trim every clip in `recordings/` in one pass.
- [ ] **Polished example defaults** — ship the bundled example scenarios with a
      chosen Piper voice + terminal font size so a fresh clone looks good out of the box.
