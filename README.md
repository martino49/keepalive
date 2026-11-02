# KeepAlive

Windows keep-awake tool. Keeps your PC awake in human-like cycles, knows when to stay out of your way, and runs unattended when you want it to.

No installs, no modules, no admin rights.

---

## Quick start

| I want to... | Do this |
|---|---|
| Just keep my PC awake | Double-click `KeepAlive.bat` -> press **Start** |
| Run it every time I log on | `KeepAlive.bat -AutoStart` (or tick **Start with Windows** in the GUI) |
| Only during work hours | `KeepAlive.bat -From 08:00 -Until 18:00 -Days mon,tue,wed,thu,fri` |
| Keep awake for 3 hours then stop | `KeepAlive.bat -RunFor 3h` |
| See the plan without doing it | `KeepAlive.bat -DryRun` |
| Never touch the keyboard | `KeepAlive.bat -InputMode mouse` or `-InputMode power` |
| Stop | GUI **Stop** button, CLI **Ctrl+C**, or **Exit** from the tray icon |

---

## How it works

KeepAlive runs in repeating two-phase cycles:

| Phase | What happens |
|---|---|
| **ACTIVE** (default 60 min) | Keeps the machine awake: presses the chosen key (or nudges the mouse, or holds a Windows power request) every N seconds |
| **REST** (default 2 min) | Zero input - no keyboard, no mouse, nothing. A genuine idle window |

Then it repeats: ACTIVE -> REST -> ACTIVE ... until you stop it (or a run window ends it).

It keeps your PC awake in three independent ways, used together or alone:

1. **Input taps** - a full key press+release every N seconds. A lone Shift tap is ignored by every application, so nothing you are working on is disturbed.
2. **Windows power request** - `SetThreadExecutionState` claims "system + display required" while ACTIVE and releases it during REST. This is the API Windows itself honors, and it works even where synthetic keys are ignored (fullscreen apps, elevated windows).
3. **Mouse nudge** - moves the cursor 1px and back. For setups that only respond to mouse activity.

By default it uses key taps only. Everything is configurable.

---

## Using the GUI

Double-click `KeepAlive.bat` with **no arguments**.

### Settings panel

| Field | What to enter |
|---|---|
| **Key** | Which key to tap: Shift (safe default), Ctrl, Alt, ScrollLock |
| **Action** | `key` (tap the key), `mouse` (nudge the cursor), `power` (power request only, no input), `none` (do nothing - use with power request) |
| **Seconds** | Seconds between input actions (default 60) |
| **Active min (0 = no rest)** | Length of the ACTIVE phase. `0` means never rest - the original behavior |
| **Rest min** | Length of the REST phase (no input at all) |
| **Idle sec (0 = off)** | Only act after this much *real* idle. `120` means: if you used the keyboard or mouse in the last 2 minutes, it stays quiet. `0` disables the check |
| **No-tap list** | Process names that pause input while foreground - e.g. `zoom, POWERPNT, teams` (comma-separated; names match process names like `zoom`, `POWERPNT`) |
| **Sched from / Sched to** | Time window, e.g. `08:00` / `18:00`. Overnight windows work (`22:00` to `06:00`). Both empty = all day. Outside the window the status shows **WAITING** and nothing is pressed or claimed |
| **Days** | Weekday filter: `mon,tue,wed`. Empty = every day |
| **Run for** | Stop after a duration: `1h30m`, `90m`, `45s`. Empty = run indefinitely |
| **Run until** | Stop at a clock time: `17:00`. Empty = no clock limit |
| **Battery** | `ignore` (default), `require-ac` (do nothing while on battery), `pause-on-battery` (keep running but pause input while on battery) |
| **Windows power request** | Also hold a power request while ACTIVE |
| **Pause in fullscreen** | Pause input while a fullscreen app has focus (games, videos) |
| **Dry run (log only)** | Log the intended actions and press nothing - for testing a configuration |
| **Start with Windows** | Add/remove the startup shortcut immediately |

**Test key / mouse** presses your chosen input once so you can confirm it is safe before committing to a cycle.

### Status panel

| Readout | Meaning |
|---|---|
| **ACTIVE / REST / WAITING / STOPPED** | Current phase (color-coded; tray icon matches) |
| **left in phase** | Countdown to the next phase transition |
| **actions** | How many input actions this session has performed |
| **progress bar** | Progress through the current phase |
| **diagnostics line** | Live: idle seconds, foreground app, power source (ac/battery/unknown), phase-end clock time |
| **amber line** | Why input is paused right now (user active / no-tap app / fullscreen / on battery / session locked) - straight from the engine's rules |
| **activity log** | Rolling log of what happened and when |

### Buttons

- **Start** - begins the cycle; settings lock while running (stop to change them)
- **Stop** - ends the cycle
- **Hide to tray** - minimizes to the tray; closing the window also keeps running in the tray. Right-click the tray icon for **Show window / Start / Stop / Exit**
- Settings are remembered between runs in `KeepAlive.settings.json`
- Closing the window while running keeps it in the tray. To fully quit: **Exit** from the tray icon or press **Stop** first

---

## Using the CLI

`KeepAlive.bat <any arguments>` opens the text version. It prints the full plan first, then each phase transition, and stops with **Ctrl+C**.

Full parameter reference:

| Parameter | Default | Meaning |
|---|---|---|
| `-Interval <sec>` | `60` | Seconds between input actions |
| `-Key <key>` | `Shift` | `Shift`, `Ctrl`, `Alt`, `ScrollLock` (unknown values fall back to Shift) |
| `-ActiveMinutes <min>` | `60` | ACTIVE phase length. `0` = never rest |
| `-RestMinutes <min>` | `2` | REST phase length (no input) |
| `-InputMode <mode>` | `key` | `key` / `mouse` / `power` / `none` |
| `-PowerRequest` | off | Hold a Windows power request while ACTIVE |
| `-IdleThreshold <sec>` | `0` | Only act after this much real idle |
| `-BlackList <names>` | none | Processes that pause input: `-BlackList zoom,teams` |
| `-RespectFullscreen` | off | Pause input while a fullscreen app has focus |
| `-DryRun` | off | Log the plan, touch nothing |
| `-From HH:mm` | all day | Schedule window start (overnight works) |
| `-Until HH:mm` | all day | Schedule window end |
| `-Days <names>` | every day | Weekday filter: `-Days mon,tue,wed` |
| `-RunFor <dur>` | none | Stop after: `1h30m`, `90m`, `45s` |
| `-RunUntil HH:mm` | none | Stop at this clock time |
| `-BatteryMode <mode>` | `ignore` | `ignore` / `require-ac` / `pause-on-battery` |
| `-AutoStart` | off | Add to Windows startup and exit |
| `-NoAutoStart` | off | Remove from Windows startup and exit |

**Default values come from `KeepAlive.settings.json`** (the file the GUI writes), so anything configured in the GUI applies to the CLI too. Explicit flags always win.

### Recipes

```bat
KeepAlive.bat -Help                          # full usage
KeepAlive.bat                                # GUI

KeepAlive.bat                               # defaults: Shift every 60s, 60/2 cycle
KeepAlive.bat -ActiveMinutes 30 -RestMinutes 5        # 30 min on, 5 min idle, repeat
KeepAlive.bat -Key Ctrl -Interval 30                  # faster Ctrl taps
KeepAlive.bat -ActiveMinutes 0                       # never rest

KeepAlive.bat -InputMode mouse -PowerRequest         # no keyboard at all
KeepAlive.bat -IdleThreshold 120 -BlackList zoom,teams   # wait for idle, mute listed apps
KeepAlive.bat -DryRun                                # plan only, press nothing

KeepAlive.bat -From 08:00 -Until 18:00 -Days mon,tue,wed,thu,fri   # work hours
KeepAlive.bat -From 22:00 -Until 06:00 -BatteryMode pause-on-battery   # overnight, laptop friendly
KeepAlive.bat -RunFor 2h                             # stop after two hours
KeepAlive.bat -RunUntil 17:00                        # stop at 17:00
KeepAlive.bat -AutoStart                             # run at every logon
KeepAlive.bat -NoAutoStart                           # stop running at logon
```

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Clean stop (or a completed run window) |
| `2` | Already running - the existing window was focused |
| `1` | Bad input (validation error, with a message) |

---

## Unattended operation

- **Auto-start**: `-AutoStart` or the GUI checkbox creates a shortcut in the shell:startup folder. It starts the GUI (which starts with the last-used schedule); set `KEEPALIVE_NO_ONBOARDING=1` in that shortcut's environment, or run once manually, to skip the first-run dialog.
- **Logging**: both frontends append to `KeepAlive.log` next to the scripts - start time, phase transitions, stop time, action counts.
- **Single instance**: a second launch never double-taps. The GUI focuses the running window; the CLI prints "already running" and exits `2`.

---

## Files

| File | Purpose |
|---|---|
| `KeepAlive.bat` | Launcher. No arguments -> GUI; any argument -> CLI |
| `KeepAliveUI.ps1` | WinForms GUI (settings, live status, tray, diagnostics, persistence) |
| `KeepAlive.ps1` | CLI with full help, validation, exit codes |
| `KeepAliveEngine.ps1` | Shared engine: cycle state machine, power requests, idle detection, app awareness, schedule windows, battery rules, single-instance, dry-run |
| `test-engine.ps1` | Engine test harness (36 checks, no side effects - safe to run anytime) |
| `gui-smoke.ps1` | GUI flow smoke test |
| `KeepAlive.log` | Session history (created at runtime; gitignored) |
| `KeepAlive.settings.json` | GUI settings, shared with the CLI (created at runtime; gitignored) |

Run the tests any time:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File test-engine.ps1
```

---

## Requirements

- Windows, PowerShell 5.1+ (built into every supported Windows)
- No installs, no modules, no admin rights
- Portable: copy the folder anywhere and run `KeepAlive.bat`

## Uninstall

1. `KeepAlive.bat -NoAutoStart` (removes the startup shortcut)
2. Delete the folder. Nothing else was installed; no registry keys, no services.

---

## FAQ

**Is a lone Shift press really invisible?**
Yes - an unmodified Shift press+release produces no character, no shortcut, and no scroll. Every app ignores it. Ctrl is nearly as safe; Alt can focus a menu bar in some apps, and ScrollLock visibly toggles its keyboard LED.

**It stopped pressing when I was typing - why?**
That is the idle threshold doing its job (`Idle sec`). It only acts after N seconds of real inactivity. The amber line in the status panel always tells you why it is quiet.

**My presenter app is triggering things - fix it?**
Add the process name to the no-tap list, or tick **Pause in fullscreen**. Both pause input for that app while it has focus.

**My laptop got hot / drained.**
Use `-BatteryMode pause-on-battery` or `require-ac`. Power requests also keep the *display* on - that is the setting's purpose, and exactly what you asked for by running the tool.

**Can it get me in trouble at work?**
It cannot bypass policy: Group Policy, corporate idle policies or a domain lock can still lock your session no matter how much activity looks like. Know your employer's rules about keep-awake tools before using one.

**Nothing happens when I double-click the .bat?**
Right-click -> Run with PowerShell, or from a terminal: `powershell -ExecutionPolicy Bypass -File KeepAliveUI.ps1`. (Windows may block `.bat` downloaded from the internet - right-click -> Properties -> Unblock.)

**It says "already running"?**
That is the single-instance guard. The running copy lives in the tray - right-click its icon, or focus the window a second launch raises.

---

## Project layout

```text
KeepAlive.bat          launcher (GUI vs CLI)
KeepAliveEngine.ps1    shared engine (cycle, power, idle, schedule, battery, mutex)
KeepAliveUI.ps1        GUI front end
KeepAlive.ps1          CLI front end
test-engine.ps1        engine test harness
gui-smoke.ps1          GUI flow smoke test
```
