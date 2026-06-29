# Demo Recorder

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
.\Setup-Piper.ps1                 # downloads tools/piper + voices/en_US-lessac-medium
.\Setup-Piper.ps1 -Voice en_US-ryan-medium   # or pick another voice
```

Then set the engine in your scenario:
```json
"narration": { "engine": "piper" }
```
The `piper.exe` and model paths are auto-detected; override with
`"piper": { "model": "voices/en_US-ryan-medium.onnx" }`. Browse voices at
[rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices).

**Engine options** (`narration.engine`):
- **`piper`** — offline neural, best quality, free. Needs `Setup-Piper.ps1`.
- **`winrt`** (default) — built-in Windows OneCore voices (David/Zira/Mark).
- **`sapi`** — legacy SAPI5 voices.

Unavailable engines fall back gracefully (e.g. `piper` → `winrt` if not set up).

> ⚠️ Windows 11 **"Natural" voices added via Narrator** (Aria/Ava/Andrew) are
> packaged as Narrator-only app packages and are **not** exposed to SAPI/WinRT, so
> no third-party app (including this one) can use them. Piper is the free/offline
> way to get neural-quality narration. Cloud voices (OpenAI/Azure/ElevenLabs) are
> on the [roadmap](docs/ROADMAP.md).

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
