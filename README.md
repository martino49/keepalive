# KeepAlive

Windows keep-awake tool. Keeps your PC awake in human-like cycles and gets out of the way - no console flags to remember, no window babysitting.

**One command:** double-click `KeepAlive.bat`.

---

## How it works

The tool runs in repeating two-phase cycles:

| Phase | What happens |
|---|---|
| **ACTIVE** (default 60 min) | Presses the chosen key once every N seconds. A lone Shift tap doesn't register as input in any app, so the machine stays awake without typing anything or triggering shortcuts. |
| **REST** (default 2 min) | Zero input - no keyboard, no mouse, nothing. A genuine idle window. |

Then it repeats: ACTIVE -> REST -> ACTIVE ... until you stop it.

## Two ways to run it

### GUI (recommended)

`KeepAlive.bat` with **no arguments** opens the window:

- **Settings** - key (Shift / Ctrl / Alt / ScrollLock), seconds between presses, active minutes, rest minutes
- **Test key** - presses your chosen key once so you can confirm it's safe first
- **Status** - live phase readout, phase countdown, tap counter, phase progress bar, session uptime, and a rolling activity log
- **Start / Stop / Hide to tray** - closing the window keeps it running in the tray; right-click the tray icon to exit
- Settings are remembered between runs

### Command line

`KeepAlive.bat <any arguments>` routes to the text version. Defaults are 60s taps, 60 min ACTIVE / 2 min REST.

| Parameter | Default | Meaning |
|---|---|---|
| `-Interval <sec>` | `60` | Seconds between input actions |
| `-Key <key>` | `Shift` | `Shift`, `Ctrl`, `Alt`, `ScrollLock` (unknown values fall back to Shift) |
| `-ActiveMinutes <min>` | `60` | ACTIVE phase length. `0` = never rest |
| `-RestMinutes <min>` | `2` | REST phase length (no input) |
| `-InputMode <mode>` | `key` | `key` / `mouse` / `power` / `none` |
| `-PowerRequest` | off | Hold a Windows power request while ACTIVE (survives where synthetic keys are ignored) |
| `-IdleThreshold <sec>` | `0` | Only act after this much real idle (uses `GetLastInputInfo`) |
| `-BlackList <names>` | none | Processes that pause input: `-BlackList zoom,teams` |
| `-RespectFullscreen` | off | Pause input while a fullscreen app has focus |
| `-DryRun` | off | Log the plan, touch nothing |
| `-From HH:mm` | all day | Schedule window start (overnight windows like `22:00-06:00` work) |
| `-Until HH:mm` | all day | Schedule window end |
| `-Days <names>` | every day | Weekday filter: `-Days mon,tue,wed` |
| `-RunFor <dur>` | none | Stop after: `1h30m`, `90m`, `45s` |
| `-RunUntil HH:mm` | none | Stop at this clock time |
| `-BatteryMode <mode>` | `ignore` | `ignore` / `require-ac` / `pause-on-battery` |

```bat
KeepAlive.bat                                            # GUI
KeepAlive.bat -ActiveMinutes 30 -RestMinutes 5           # 30 min on, 5 min idle, repeat
KeepAlive.bat -Key Ctrl -Interval 30                     # faster Ctrl taps
KeepAlive.bat -ActiveMinutes 0                           # never rest
KeepAlive.bat -DryRun                                    # plan only, press nothing
KeepAlive.bat -From 08:00 -Until 18:00 -Days mon,tue,wed,thu,fri   # work hours only
KeepAlive.bat -From 22:00 -Until 06:00 -BatteryMode pause-on-battery  # overnight, battery friendly
KeepAlive.bat -RunFor 2h                                 # stop after two hours
KeepAlive.bat -RunUntil 17:00                            # stop at 17:00
```

The CLI prints each phase transition with a live countdown. Stop it with **Ctrl+C**.

## Files

| File | Purpose |
|---|---|
| `KeepAlive.bat` | Launcher. No arguments -> GUI; any argument -> CLI |
| `KeepAliveUI.ps1` | WinForms GUI (settings, live status, tray, diagnostics, persistence) |
| `KeepAlive.ps1` | CLI with `--help`, validation, exit codes |
| `KeepAliveEngine.ps1` | Shared engine: cycle state machine, power requests, idle detection, app awareness, single-instance, dry-run |
| `test-engine.ps1` | Dry-run test harness for the engine (no side effects) |
| `gui-smoke.ps1` | Smoke test driving the GUI flow's engine path |

Settings from the GUI are saved to `KeepAlive.settings.json` next to the script (gitignored - your machine, your schedule).

## Requirements

- Windows with PowerShell 5.1+ (built in)
- No installs, no modules, no admin rights

## Notes

- **It knows when to stay out of the way.** With an idle threshold set, it only taps after you have actually been idle; the no-tap list and fullscreen detection pause input for chosen apps (presentations, meetings). `-DryRun` prints the intended schedule without touching anything.
- **Only one instance runs** (named mutex). A second launch focuses the existing window or reports exit code 2.
- **It runs on your schedule.** Time-of-day windows (with overnight support and weekday filters), a run-for duration, or a run-until clock time end the session on their own. Outside the window it waits with no input and no power claim.
- **Laptop friendly.** The battery modes pause input (or refuse to claim a power request) when unplugged, and locking the session pauses everything until you unlock.
- **Shift is the safe default.** A lone Shift tap is ignored by every app. Ctrl is mostly safe too; Alt can focus a menu bar, and ScrollLock visibly toggles its keyboard light.
- **It does not bypass policy.** Group policy or a corporate idle policy can still lock the session regardless of activity.
- Kill it cleanly: Stop button / Ctrl+C in the CLI, or Exit from the tray icon. The key is always released immediately after each press, so killing it mid-cycle never leaves a stuck modifier key.
