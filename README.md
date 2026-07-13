# Demo Recorder

[![CI](https://github.com/raimondasl/demo-recorder/actions/workflows/ci.yml/badge.svg)](https://github.com/raimondasl/demo-recorder/actions/workflows/ci.yml)

Record a video demo of any Windows app or CLI workflow — **fully automated**.
You write (or have Claude generate) a JSON **scenario**; the engine opens windows,
types commands into a real terminal, narrates, shows captions, and captures the
screen to an MP4.

- **No commercial software required.** The engine is pure PowerShell + built-in
  .NET. The only optional dependency is **ffmpeg** (free, open source) for
  hands-off recording. Manual mode uses **Clipchamp** (free, ships with Windows 11).
- **Claude-friendly.** A documented scenario format + a ready-made prompt let
  Claude turn a plain-English brief into a runnable demo.

```powershell
.\Check-Prereqs.ps1                                   # verify the environment
.\Invoke-Demo.ps1 .\scenarios\example-powershell-demo.json -DryRun   # preview
.\Invoke-Demo.ps1 .\scenarios\example-powershell-demo.json           # record!
```

---

## What it can do

| Capability | How |
|---|---|
| Run CLI commands **visibly** | `run` opens a real PowerShell/cmd window and types the command char-by-char, then Enter |
| Open apps & windows | `launch` (`notepad`, `explorer`, any `.exe`) |
| Type text / send hotkeys | `type`, `keys` (`Ctrl+Shift+Esc`, `Alt+F4`, `F5`, ...) |
| Focus / move / resize windows | `focus`, `window` |
| Mouse clicks | `click` (discouraged — prefer keyboard) |
| On-screen captions | `caption` — top-most, click-through, never steals focus; **always in the video** |
| Spoken narration | `narrate` / `say` — built-in Windows TTS |
| Screenshots | `screenshot` |
| **Video capture** | `ffmpeg` (automated) · `manual` (Clipchamp) · `none` |

See **[docs/SCENARIO_FORMAT.md](docs/SCENARIO_FORMAT.md)** for the full action
catalog and the **prompt for Claude**.

---

## Requirements

| | Needed? | Notes |
|---|---|---|
| Windows 10/11 + PowerShell 5.1 | **Required** | Built in. Everything else is .NET that ships with Windows. |
| **ffmpeg** | Optional | Only for `recording.mode = ffmpeg` (automated capture). `winget install Gyan.FFmpeg` |
| **Clipchamp** | Optional | Only for `recording.mode = manual`. Ships with Windows 11. |
| OBS Studio | Not yet | `obs` mode is reserved for a later phase. |

> **No commercial programs are required.** ffmpeg, OBS, and Clipchamp are all free.

Run `.\Check-Prereqs.ps1` to see exactly what's present, or
`.\Check-Prereqs.ps1 -InstallFfmpeg` to install ffmpeg.

If your PowerShell blocks scripts, allow them for your user:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

---

## Quick start

1. **Check the environment**
   ```powershell
   .\Check-Prereqs.ps1
   ```
2. **Preview a scenario** (no recording, no actions — just prints the plan)
   ```powershell
   .\Invoke-Demo.ps1 .\scenarios\minimal.json -DryRun
   ```
3. **Record it**
   ```powershell
   .\Invoke-Demo.ps1 .\scenarios\minimal.json
   ```
   A 3-second countdown starts, the controller window minimizes, the demo runs,
   and the MP4 lands in `recordings\`.

> ⚠️ While a demo runs it **takes over your mouse and keyboard** (it sends real
> keystrokes to whatever window is focused). Don't type or click until it's done.
> Slam the mouse into a corner or `Alt+Tab` only if you must abort — closing the
> controller window stops the run and finalizes the video.

---

## Generating a demo with Claude

The whole point: describe a demo in words, let Claude produce the scenario.

1. Open **[prompts/generate-scenario.md](prompts/generate-scenario.md)**.
2. Fill in the **DEMO REQUIREMENTS** block (what to show, environment, tone...).
3. Paste it into Claude; save the returned JSON to `scenarios\my-demo.json`.
4. Validate, preview, record:
   ```powershell
   .\Invoke-Demo.ps1 .\scenarios\my-demo.json -Validate
   .\Invoke-Demo.ps1 .\scenarios\my-demo.json -DryRun
   .\Invoke-Demo.ps1 .\scenarios\my-demo.json
   ```

The validator rejects unknown actions, missing fields, and invented key names, so
a malformed generation fails fast instead of misfiring on camera.

---

## Recording modes (phased)

| Mode | Status | What happens |
|---|---|---|
| `ffmpeg` | ✅ Phase 1 | Engine starts/stops ffmpeg (gdigrab) itself. Fully hands-off. **Default.** |
| `manual` | ✅ Phase 1 | Engine prompts you to start Clipchamp (or any recorder), runs the demo, prompts you to stop. The original MVP. |
| `none` | ✅ Phase 1 | Run the actions with no capture (rehearsal). |
| `obs` | 🔜 Later | OBS WebSocket control (scenes, webcam, overlays). |

Override at the command line without editing the scenario:

```powershell
.\Invoke-Demo.ps1 .\scenarios\my-demo.json -RecordMode manual
.\Invoke-Demo.ps1 .\scenarios\my-demo.json -NoRecord
```

### Narration is baked into the video

Spoken narration is included in the MP4 automatically (ffmpeg mode): each line is
rendered to a WAV, timestamped against recording start, and muxed onto the video
afterward — **no Stereo Mix or loopback device needed**. Disable with
`narration.captureToVideo: false`. To also capture other app/system audio, set
`recording.audioDevice` (see [docs/SCENARIO_FORMAT.md](docs/SCENARIO_FORMAT.md)).

### Better-sounding voices — Piper (free, offline neural)

The built-in Windows voices are robotic. For natural, non-robotic narration —
free, offline, no API key — use the **`piper`** engine. One-time setup downloads a
small self-contained binary (no Python) and a voice model:

```powershell
.\Setup-Piper.ps1                            # default: en_US-lessac-medium (lighter/faster)
.\Setup-Piper.ps1 -Voice en_US-ryan-high     # best-quality male
.\Setup-Piper.ps1 -Voice en_US-lessac-high   # best-quality neutral
```

Then set the engine in your scenario:
```json
"narration": { "engine": "piper" }
```
The `piper.exe` and model paths are auto-detected (they default to the
`en_US-lessac-medium` you installed first); to use a different voice, point at it:
```json
"narration": { "engine": "piper", "piper": { "model": "voices/en_US-ryan-high.onnx" } }
```
**Quality tiers:** `high` > `medium` > `low`. `high` models (~110 MB) sound best
but render a bit slower; `medium` (~60 MB) is a good balance. Listen to every
voice at the official [samples page](https://rhasspy.github.io/piper-samples/),
then browse files at [rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices).

**Engine options** (`narration.engine`):
- **`piper`** — offline neural, free. Needs `Setup-Piper.ps1`.
- **`azure`** — Azure AI Speech neural (Aria/Andrew/Ava…). **Free tier available.** Needs a key.
- **`openai`** — OpenAI TTS. Paid. Needs a key + billing.
- **`winrt`** (default) — built-in Windows OneCore voices (David/Zira/Mark).
- **`sapi`** — legacy SAPI5 voices.

Unavailable engines fall back gracefully (e.g. `piper` → `winrt` if not set up;
`azure`/`openai` → a local voice if the key env var isn't set).

> ⚠️ Windows 11 **"Natural" voices added via Narrator** (Aria/Ava/Andrew) are
> packaged as Narrator-only app packages and are **not** exposed to SAPI/WinRT, so
> no third-party app can use them — but the *same* voices are available through the
> **`azure`** engine below.

### Cloud voices — Azure & OpenAI (highest quality)

Both engines read the **API key from an environment variable** (never the scenario
file), render each line to WAV over HTTPS, and cache results in `.tts-cache/` so
re-running a demo doesn't re-call (or re-bill) the API.

Pick one:

| | Cost | Voices | Best for |
|---|---|---|---|
| **Azure** | **Free tier**: 500K chars/month, then ~$15 / 1M | Aria, Andrew, Ava, Jenny, Guy… (the Windows "Natural" voices) | Free, high-quality neural |
| **OpenAI** | Paid, ~$15–30 / 1M chars (no real free tier) | alloy, nova, coral, onyx, shimmer, echo… | Simplest API if you already have OpenAI billing |

#### Azure AI Speech — get a key (free)

1. Sign in to the [Azure portal](https://portal.azure.com) (create a free account if needed).
2. **Create a resource → search "Speech" → Create.**
3. Set Subscription, Resource group, a **Region** (e.g. *East US* — remember it), a Name, and **Pricing tier = Free F0**.
4. **Review + create → Create → Go to resource.**
5. Left menu → **Resource Management → Keys and Endpoint.** Copy **KEY 1** and note the **Location/Region** (e.g. `eastus`).
6. Set the key as an env var and use it:
   ```powershell
   setx AZURE_SPEECH_KEY "<your-key>"     # persists; reopen the terminal after
   ```
   ```json
   "narration": { "engine": "azure", "region": "eastus", "voice": "en-US-AvaMultilingualNeural" }
   ```
   Voices: `en-US-AvaMultilingualNeural`, `en-US-AndrewMultilingualNeural`,
   `en-US-EmmaMultilingualNeural`, `en-US-AriaNeural`, `en-US-JennyNeural`, …

#### OpenAI — get a key (paid)

1. Sign in to the [OpenAI platform](https://platform.openai.com); verify email + phone.
2. **Settings → Billing → Add payment method** (TTS fails without billing; optionally set a usage limit).
3. **[API keys](https://platform.openai.com/api-keys) → Create new secret key**, copy it (shown once, starts with `sk-`).
4. Set it and use it:
   ```powershell
   setx OPENAI_API_KEY "sk-..."           # persists; reopen the terminal after
   ```
   ```json
   "narration": { "engine": "openai", "model": "tts-1-hd", "voice": "coral" }
   ```
   Models: `tts-1-hd` (default, predictable pacing), `tts-1` (cheaper, free-tier
   at 3 req/min), `gpt-4o-mini-tts` (most expressive, but ignores `rate` and can
   add trailing silence). Voices: `coral`, `nova`, `onyx`, `shimmer`, `alloy`, …

> The API key lives only in the env var and is never written to a scenario or the
> repo. If a key leaks, rotate it in the provider's dashboard.

### Bigger terminal font (readability)

The tiny default console font is hard to read on video. Add a `terminal` block —
no manual setup needed:

```json
"settings": { "terminal": { "fontSize": 26, "fontFace": "Consolas" } }
```

The engine temporarily sets the `HKCU\Console` font and launches `run` terminals
through the classic console host (`conhost`), which honors it (Windows Terminal
ignores console fonts). The original font is **restored automatically** when the
demo ends. This also makes typing/focus more reliable when Windows Terminal is
your default. Try ~24–32 px.

### Trimming a recording

To cut the startup dead time (or the end) off a finished recording:

```powershell
.\Trim-Recording.ps1 .\recordings\demo.mp4               # drop the first 3s
.\Trim-Recording.ps1 .\recordings\demo.mp4 -StartSec 5 -EndTrimSec 2
.\Trim-Recording.ps1 .\recordings\demo.mp4 -InPlace      # overwrite the original
```

Re-encodes for a frame-accurate cut by default; add `-Fast` for an instant,
lossless stream copy (snaps to the nearest keyframe).

---

## How it works

```
Invoke-Demo.ps1            entry point: load → validate → record → run steps → finalize
modules/
  Scenario.psm1            parse + strict-validate + dry-run plan
  Engine.psm1              SendKeys typing, key chords, window mgmt, clicks, screenshots
  Overlay.psm1             click-through caption window (STA runspace) + System.Speech TTS
  Recorder.psm1            ffmpeg / manual / none backends
docs/
  SCENARIO_FORMAT.md       schema reference + the Claude prompt
  scenario.schema.json     JSON Schema (editor validation)
prompts/generate-scenario.md   standalone Claude prompt
scenarios/                 example scenarios
```

Design notes:
- **Visible CLI**: `run` launches a real terminal and uses `WScript.Shell` SendKeys
  so the typing is on screen. Consecutive `run` steps reuse one terminal session.
- **Captions don't steal focus**: the caption window is `WS_EX_NOACTIVATE |
  WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT`, shown from its own STA runspace, so
  keystrokes keep flowing to the demo app while text is on screen.
- **Clean MP4**: ffmpeg is stopped by sending `q` to stdin (a hard kill would leave
  an unplayable file); `+faststart` is applied for smooth playback.

---

## Troubleshooting

- **"ffmpeg not found"** — install it (`winget install Gyan.FFmpeg`) or use
  `-RecordMode manual`. After installing, open a **new** terminal so PATH updates
  (the engine also auto-locates a winget-installed ffmpeg).
- **Keystrokes go to the wrong window** — something stole focus. Add a `focus`
  step before typing, give windows an `as` name, and don't touch input during a run.
- **A caption lingers** — captions auto-dismiss after `durationMs`; the engine also
  clears overlays on exit.
- **Script won't run** — `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.
- **`run` command has quotes/braces** — that's fine; the engine escapes SendKeys
  special characters automatically.

---

## Tests

Pester tests run in CI on `windows-latest` (and locally):

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Force -SkipPublisherCheck -Scope CurrentUser
Invoke-Pester -Path .\tests -Output Detailed
```

They cover the logic (validation, SendKeys encoding, settings, ffmpeg arg building)
and the real ffmpeg trim/mux paths (using generated test clips — no screen needed).
GUI automation, audio playback, and live cloud TTS can't run headlessly — see
[tests/README.md](tests/README.md) for the full coverage breakdown.

## Roadmap

Full list in **[docs/ROADMAP.md](docs/ROADMAP.md)**. Highlights:

- [x] Narration baked into the video (no Stereo Mix needed)
- [x] `piper` offline neural narration engine (free, natural voices)
- [x] `winrt`/`sapi` engines (built-in Windows voices)
- [ ] Cloud neural TTS (OpenAI/Azure/ElevenLabs)
- [ ] `obs` recording mode (OBS WebSocket: scenes, webcam, overlays)
- [ ] Coordinate-free UI targeting; `cmd`/WSL terminal presets

## License

MIT — see [LICENSE](LICENSE).
