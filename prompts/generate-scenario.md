# Prompt: generate a demo scenario with Claude

Copy everything in the block below into Claude (or `claude -p`), fill in the
**DEMO REQUIREMENTS** at the bottom, and save the JSON it returns as
`scenarios/<your-demo>.json`. Then run:

```powershell
.\Invoke-Demo.ps1 .\scenarios\<your-demo>.json -DryRun   # preview
.\Invoke-Demo.ps1 .\scenarios\<your-demo>.json           # record
```

---

You are generating a **scenario file** for a Windows "demo recorder". The output
must be a single JSON object — no prose, no markdown fences — that conforms to the
schema below. The engine runs each step in order on Windows while recording the
screen.

**Hard rules**
1. Output **only** valid JSON. Top-level keys: `name`, optional `description`,
   optional `settings`, and `steps` (a non-empty array).
2. Use only these `action` values: `run`, `launch`, `type`, `keys`, `focus`,
   `window`, `click`, `caption`, `narrate`, `wait`, `screenshot`, `marker`,
   `prompt`.
3. For CLI work use `run` (it types the command into a visible terminal). Put the
   exact command in `command`. Default shell is PowerShell; set `"shell":"cmd"`
   if needed.
4. For `keys`, only use: modifiers `Ctrl`/`Shift`/`Alt`; named keys `Enter`,
   `Tab`, `Esc`, `Backspace`, `Delete`, `Up`, `Down`, `Left`, `Right`, `Home`,
   `End`, `PageUp`, `PageDown`, `Space`, `Insert`, `F1`–`F12`; or a single
   character. Never invent key names. Do not use the Windows key.
5. **Avoid `click`** unless absolutely necessary — coordinates are unreliable.
   Prefer `run`, `keys`, `type`, `focus`.
6. Make it watchable: open with a title `caption`, add a short `caption` (and/or
   `say`) before each meaningful step explaining what is about to happen, and end
   with a closing `caption`. Keep captions under ~8 words.
7. Use realistic pacing: rely on default pauses; add `waitMs` to `run` steps whose
   output takes time to appear; use `wait` steps sparingly.
8. Only reference apps/commands that exist on a standard Windows 11 machine, or
   that the requirements say are installed. Never run destructive commands
   (no deleting user data, no `Format`, no irreversible changes) unless explicitly
   requested and clearly scoped to a temp folder.
9. Prefer a temp working area (e.g. `$env:TEMP\demo`) for files the demo creates,
   and clean up at the end if you created anything.

**Settings guidance**
- Default `recording.mode` to `ffmpeg`. If the requirements say recording is
  manual, use `manual`.
- Pick a `narration.voice` of `Microsoft Zira Desktop` or `Microsoft David
  Desktop` if narration is wanted.
- Set `recording.fileName` to a short slug of the demo name.

**Schema (abridged — full version in docs/scenario.schema.json):**
```
step.action: run|launch|type|keys|focus|window|click|caption|narrate|wait|screenshot|marker|prompt
run:    { command, shell?, newWindow?, as?, submit?, waitMs?, typeStyle? }
launch: { app, args?, as?, windowState? }
type:   { text, submit?, typeStyle? }
keys:   { keys: string|string[], count?, intervalMs? }
focus:  { as? | title? | titleContains? | processName? }
window: { (target), state?, x?, y?, width?, height? }
caption:{ text, durationMs?, position?, wait? }
narrate:{ text, voice?, rate?, volume?, wait? }
wait:   { seconds? | ms? }
screenshot: { path?, region? }
any step may also carry: caption (string), say (string), pauseAfterMs (int)
```

**DEMO REQUIREMENTS** (fill this in):
- Product/system being demoed:
- Audience and goal of the demo:
- Environment / what's already installed:
- The exact flow to show (ordered):
- Any specific commands or apps to use:
- Tone & length (e.g. "2 minutes, friendly"):
- Recording: automated (ffmpeg) or manual (Clipchamp)?

Now output the scenario JSON.
