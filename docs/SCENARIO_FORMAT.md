# Scenario File Format

A **scenario** is a JSON file that drives an automated demo. The engine reads it
top-to-bottom and performs each step while recording the screen.

- Machine-readable schema: [`scenario.schema.json`](scenario.schema.json)
- Validate any file with: `./Invoke-Demo.ps1 my.json -Validate`
- Preview without running: `./Invoke-Demo.ps1 my.json -DryRun`

---

## 1. Top-level shape

```json
{
  "schemaVersion": "1.0",
  "name": "My Product CLI Demo",
  "description": "Shows installing the tool and running its first command.",
  "settings": { ... },
  "steps": [ ... ]
}
```

Only `name` and `steps` are required. `settings` is optional; every field has a
sensible default.

### `settings`

| Group | Field | Default | Meaning |
|------|-------|---------|---------|
| `recording` | `mode` | `ffmpeg` | `ffmpeg` (automated), `manual` (you drive Clipchamp), `none`, `obs` (later). |
| | `auto` | `true` | Record the whole scenario automatically. Set `false` to control via `record` steps. |
| | `outputDir` | `recordings` | Where the `.mp4` and screenshots go. |
| | `fileName` | `demo` | Base name; timestamp + `.mp4` appended. |
| | `framerate` | `30` | Capture FPS. |
| | `crf` | `23` | Quality (lower = sharper/bigger). |
| | `preset` | `veryfast` | x264 speed/efficiency. |
| | `captureCursor` | `true` | Show the mouse cursor in the video. |
| | `region` | _full screen_ | `{x,y,width,height}` rectangle, or `{ "window": "Exact Title" }`. |
| | `audioDevice` | _none_ | dshow device to record audio (see "Narration in the video" below). |
| `defaults` | `typeStyle` | `human` | `human` types char-by-char; `instant` is paste-speed. |
| | `typeDelayMs` | `30` | Per-character delay when `human`. |
| | `stepPauseMs` | `800` | Pause after each step. |
| | `shell` | `powershell` | Default shell for `run`. |
| `narration` | `enabled` | `true` | Spoken narration on/off. |
| | `captureToVideo` | `true` | With ffmpeg recording, bake narration into the MP4 (rendered to WAV + muxed at the right time; no Stereo Mix needed). |
| | `voice` | _default_ | e.g. `Microsoft Zira Desktop`, `Microsoft David Desktop`. |
| | `rate` / `volume` | `0` / `100` | Speech rate (-10..10), volume (0..100). |
| `captions` | `enabled` | `true` | On-screen captions on/off. |
| | `position` | `bottom` | `top` / `center` / `bottom`. |
| | `fontSize` | `28` | Caption font size. |
| | `defaultDurationMs` | `3500` | How long captions show. |
| `startup` | `countdownSec` | `3` | Countdown before the demo starts. |
| (top) | `minimizeControllerWindow` | `true` | Hide the script's own console during capture. |

---

## 2. Steps

Every step is an object with an `action`. Two optional shorthands work on **any**
step and fire alongside it:

- `"caption": "text"` — show an on-screen caption (non-blocking).
- `"say": "text"` — speak a line of narration (non-blocking).
- `"pauseAfterMs": 1500` — override the pause after this step.
- `"id"` / `"comment"` — ignored at runtime; for your own readability.

### Action catalog

| `action` | Required | Key options | What it does |
|----------|----------|-------------|--------------|
| `run` | `command` | `shell`, `newWindow`, `as`, `typeStyle`, `submit`, `waitMs` | **The headline action.** Opens (or reuses) a visible terminal, types the command character-by-character, presses Enter. |
| `launch` | `app` | `args`, `as`, `windowState` | Starts an application/window (`notepad`, `explorer`, a full `.exe` path...). |
| `type` | `text` | `typeStyle`, `submit` | Types text into the currently focused window. |
| `keys` | `keys` | `count`, `intervalMs` | Sends key chords (see vocabulary below). |
| `focus` | one of `as`/`title`/`titleContains`/`processName` | | Brings a window to the foreground. |
| `window` | a target | `state`, `x`,`y`,`width`,`height` | Moves / resizes / maximizes / minimizes a window. |
| `click` | `x`, `y` | `button` | Clicks at absolute screen coordinates. **Fragile** — prefer keyboard. |
| `caption` | `text` | `durationMs`, `position`, `fontSize`, `wait` | Explicit on-screen caption. |
| `narrate` | `text` | `voice`, `rate`, `volume`, `wait` | Explicit spoken narration (`wait` defaults true). |
| `wait` | `seconds` or `ms` | | Pause. |
| `screenshot` | — | `path`, `region` | Saves a PNG. |
| `marker` | `label` | | Prints a structural label to the console log (no screen effect). |
| `prompt` | `message` | | Pauses and waits for the operator to press Enter (restores the console first). |
| `record` | `op` | `start`/`stop` | Manual recording control; only when `settings.recording.auto=false`. |

### Key vocabulary (for `keys`)

Modifiers: `Ctrl`, `Shift`, `Alt`. Combine with `+`, e.g. `"Ctrl+Shift+Esc"`, `"Alt+F4"`.

Named keys: `Enter`, `Tab`, `Esc`, `Backspace`, `Delete`, `Up`, `Down`, `Left`,
`Right`, `Home`, `End`, `PageUp`, `PageDown`, `Space`, `Insert`, `F1`–`F12`,
`PrintScreen`, `CapsLock`, `NumLock`. Single characters (`"a"`, `"7"`) are also valid.

> Anything not in this list is rejected by the validator — this is intentional,
> so a typo like `"Ctrl+Entr"` fails fast instead of misfiring on camera.

> ⚠️ The Windows logo key (`Win`) cannot be sent via this mechanism. Use the
> Start menu by other means, or `launch` apps directly.

---

## 3. A small complete example

```json
{
  "name": "Hello CLI Demo",
  "description": "Opens PowerShell and shows two commands.",
  "settings": {
    "recording": { "mode": "ffmpeg", "outputDir": "recordings", "fileName": "hello" },
    "defaults": { "typeStyle": "human", "stepPauseMs": 900 },
    "narration": { "voice": "Microsoft Zira Desktop" }
  },
  "steps": [
    { "action": "caption", "text": "Welcome to the demo", "durationMs": 2500, "wait": true },
    { "action": "narrate", "text": "Let's open PowerShell and check the system." },
    { "action": "run", "command": "Get-Date", "caption": "What time is it?" },
    { "action": "run", "command": "Get-Process | Sort-Object CPU -Descending | Select-Object -First 5 Name, CPU",
      "say": "Here are the top five processes by CPU.", "waitMs": 1500 },
    { "action": "caption", "text": "Thanks for watching!", "durationMs": 3000, "wait": true }
  ]
}
```

---

## 4. Authoring tips (and how the engine behaves)

- **`run` reuses one terminal** across steps unless you pass `newWindow: true` or
  a different `as`. So a sequence of `run` steps reads like a real session.
- **Captions and narration are both in the video.** Captions are recorded as
  pixels; narration is rendered to WAV during the run and muxed into the MP4
  afterward (default `narration.captureToVideo: true`, ffmpeg mode). No Stereo
  Mix or loopback device is needed. Set `captureToVideo: false` to only hear it
  live (e.g. manual recording).
- **Prefer `keys`/`run`/`type` over `click`.** Coordinates break across screen
  resolutions; keyboard-driven steps are portable.
- **Give windows an `as` name** when you will `focus`/`window` them later.
- **Timing:** the global `stepPauseMs` plus per-step `waitMs`/`pauseAfterMs` set
  the rhythm. Slow demos read better than fast ones.

### Narration in the video

By default (ffmpeg mode), narration **is** in the MP4. Each `narrate`/`say` line
is rendered to a WAV with the chosen voice, timestamped relative to recording
start, and muxed onto the video afterward (`adelay` + `amix`, video stream copied
— fast and lossless). No Stereo Mix, loopback, or virtual cable is required. The
engine cleans up the temporary WAVs automatically.

Set `narration.captureToVideo: false` to disable muxing and only hear narration
live (useful for `manual` recording, where you don't own the video file).

**Capturing other system audio (optional).** If you also want app sounds or other
audio in the recording, set `recording.audioDevice` to a dshow device:

1. Enable *Stereo Mix* (Sound settings → Recording → show disabled devices), or
   install a virtual audio cable.
2. List device names: `ffmpeg -list_devices true -f dshow -i dummy`
3. Set e.g. `"audioDevice": "Stereo Mix (Realtek(R) Audio)"`.

---

## 5. Prompt for Claude — generate a scenario

Paste the following into Claude, fill in the **DEMO REQUIREMENTS**, and it will
return a ready-to-run scenario. (A standalone copy lives in
[`../prompts/generate-scenario.md`](../prompts/generate-scenario.md).)

> You are generating a **scenario file** for a Windows "demo recorder". The output
> must be a single JSON object — no prose, no markdown fences — that conforms to the
> schema below. The engine runs each step in order on Windows while recording the
> screen.
>
> **Hard rules**
> 1. Output **only** valid JSON. Top-level keys: `name`, optional `description`,
>    optional `settings`, and `steps` (a non-empty array).
> 2. Use only these `action` values: `run`, `launch`, `type`, `keys`, `focus`,
>    `window`, `click`, `caption`, `narrate`, `wait`, `screenshot`, `marker`,
>    `prompt`.
> 3. For CLI work use `run` (it types the command into a visible terminal). Put the
>    exact command in `command`. Default shell is PowerShell; set `"shell":"cmd"`
>    if needed.
> 4. For `keys`, only use: modifiers `Ctrl`/`Shift`/`Alt`; named keys `Enter`,
>    `Tab`, `Esc`, `Backspace`, `Delete`, `Up`, `Down`, `Left`, `Right`, `Home`,
>    `End`, `PageUp`, `PageDown`, `Space`, `Insert`, `F1`–`F12`; or a single
>    character. Never invent key names. Do not use the Windows key.
> 5. **Avoid `click`** unless absolutely necessary — coordinates are unreliable.
>    Prefer `run`, `keys`, `type`, `focus`.
> 6. Make it watchable: open with a title `caption`, add a short `caption` (and/or
>    `say`) before each meaningful step explaining what is about to happen, and end
>    with a closing `caption`. Keep captions under ~8 words.
> 7. Use realistic pacing: rely on default pauses; add `waitMs` to `run` steps
>    whose output takes time to appear; use `wait` steps sparingly.
> 8. Only reference apps/commands that exist on a standard Windows 11 machine, or
>    that the requirements say are installed. Never run destructive commands
>    (no deleting user data, no `Format`, no irreversible changes) unless explicitly
>    requested and clearly scoped to a temp folder.
> 9. Prefer a temp working area (e.g. `$env:TEMP\demo`) for files the demo creates,
>    and clean up at the end if you created anything.
>
> **Settings guidance**
> - Default `recording.mode` to `ffmpeg`. If the requirements say recording is
>   manual, use `manual`.
> - Pick a `narration.voice` of `Microsoft Zira Desktop` or `Microsoft David
>   Desktop` if narration is wanted.
> - Set `recording.fileName` to a short slug of the demo name.
>
> **Schema (abridged — full version in scenario.schema.json):**
> ```
> step.action: run|launch|type|keys|focus|window|click|caption|narrate|wait|screenshot|marker|prompt
> run:    { command, shell?, newWindow?, as?, submit?, waitMs?, typeStyle? }
> launch: { app, args?, as?, windowState? }
> type:   { text, submit?, typeStyle? }
> keys:   { keys: string|string[], count?, intervalMs? }
> focus:  { as? | title? | titleContains? | processName? }
> window: { (target), state?, x?, y?, width?, height? }
> caption:{ text, durationMs?, position?, wait? }
> narrate:{ text, voice?, rate?, volume?, wait? }
> wait:   { seconds? | ms? }
> screenshot: { path?, region? }
> any step may also carry: caption (string), say (string), pauseAfterMs (int)
> ```
>
> **DEMO REQUIREMENTS** (fill this in):
> - Product/system being demoed:
> - Audience and goal of the demo:
> - Environment / what's already installed:
> - The exact flow to show (ordered):
> - Any specific commands or apps to use:
> - Tone & length (e.g. "2 minutes, friendly"):
> - Recording: automated (ffmpeg) or manual (Clipchamp)?
>
> Now output the scenario JSON.
