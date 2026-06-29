# Roadmap

Status of planned work. Done items are listed for context; the rest are ordered
roughly by priority.

## Done
- [x] ffmpeg automated recording (start → graceful stop → playable MP4)
- [x] Manual (Clipchamp) and `none` recording modes
- [x] Scenario format + JSON Schema + Claude generation prompt + validator
- [x] On-screen captions (click-through, non-focus-stealing) and screenshots
- [x] Narration baked into the video (render → timestamp → ffmpeg mux; no Stereo Mix)
- [x] **`winrt` narration engine** — OneCore + installed **Natural** neural voices

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

### Piper (free, local, offline neural) — planned
Good neural quality with no key and no cloud, runs fully offline.
- **Needs:** the `piper` binary + a voice model (`.onnx` + `.json`), run via a
  **uv**-managed environment (no system Python — see project convention).
- **Design sketch:** `narration.engine: "piper"`, `narration.model` path; a small
  setup script downloads a chosen voice (e.g. `en_US-ryan-high`) into the repo.
  `Render-NarrationWavPiper` shells out to `uv run piper ... -f out.wav`.

## Recording
- [ ] **`obs` mode** — OBS WebSocket (obsws): scenes, webcam overlay, picture-in-
      picture, higher-quality capture. (`obs` currently throws on purpose.)
- [ ] Per-window / region capture helpers and a small picker UI.
- [ ] Optional hardware-encoder presets (NVENC/QSV) for lighter CPU use.

## Engine / authoring
- [ ] Coordinate-free UI targeting (UI Automation) to reduce reliance on `click`.
- [ ] `cmd` / WSL / Windows Terminal presets for `run`.
- [ ] A `verify`-style assertion step (wait for a window/text to appear).
- [ ] Per-step ret/timeout and an on-error policy (continue vs. abort).
