# KeepAlive - Roadmap

README documents what the tool does today. This file documents everything that is planned, why it is worth building, and in what order.

## Shipped (v1 feature complete)

| Area | What |
|---|---|
| Engine | ACTIVE/REST cycle state machine, never-rest mode, per-phase transitions |
| Keep-awake | Key taps (Shift/Ctrl/Alt/ScrollLock), Windows power requests, mouse nudge |
| Intelligence | Idle detection (GetLastInputInfo), process no-tap list, fullscreen pause |
| Scheduling | Time-of-day windows with overnight support, weekday filter, run-for duration, run-until clock time |
| Power | Battery modes (ignore / require-ac / pause-on-battery), session-lock pause |
| Trust | Dry-run, single instance, session log, first-run onboarding, exit codes |
| Frontends | WinForms GUI (settings, live status, diagnostics line, tray, dynamic icon), CLI with full help |
| Ops | Auto-start shortcut, shared settings file, test harnesses (36 + 4 checks) |

## Planned backlog

### A. New reasons to keep awake

| # | Feature | Why it matters | Batch |
|---|---|---|---|
| A1 | **Process-triggered runs** - `-WhileProcess node,chrome` / `-UntilProcessGone excel` | "Keep awake while my build runs" / "stop when Excel closes" - the long-task babysitting case | 1 |
| A2 | **Activity-triggered runs** - CPU above X%, or network traffic flowing | Keeps renders/downloads/ML jobs awake, stops when the machine goes quiet | 2 |
| A3 | **System awake, display may sleep** - drop ES_DISPLAY_REQUIRED from the claim | Screen sleeps (real power saving) while the session stays alive | 2 |
| A4 | **Status-apps mode** - short-interval taps, no power request | Key taps reset the Windows idle timer, so Teams/Slack/Outlook stay green instead of Away. Make the accidental behavior intentional | 2 |
| A5 | **Wake/resume handling** - re-claim on resume, log the event | Policy or lid-close can still sleep the machine; the tool must recover on its own | 1 |
| A6 | **Weekly recurring schedule** - saved Mon-Fri presets | A schedule you retype every morning is a schedule you stop using | 4 |

### B. Trust and self-service

| # | Feature | Why it matters | Batch |
|---|---|---|---|
| B1 | **`-Diagnose` mode** - sleep timeouts + `powercfg /requests` dump | Answers "why did my PC sleep anyway?" without a web search | 1 |
| B2 | **Deadline warning + completion toast** | T-5min warning before a run window ends, then "3h 12m awake, 180 taps, 4 rests" | 1 |
| B3 | **Insights panel** - sessions/day, awake time, taps, rest compliance from the log | Users trust tools that show their own data | 3 |
| B4 | **Last-session recap on startup** | One line: "Yesterday: 8h 12m, 480 taps, 4 rests" | 3 |

### C. Workflow

| # | Feature | Why it matters | Batch |
|---|---|---|---|
| C1 | **Profiles** - Work / Gaming / Presentation / Status-apps, one click | The settings panel answers everything; profiles answer *quickly* | 3 |
| C2 | **Global hotkeys** - toggle + panic stop | Control without hunting the window | 3 |
| C3 | **Compact always-on-top widget** | A phase pill you can park instead of the full window | 3 |
| C4 | **Config import/export** | Move a schedule between machines | 4 |
| C5 | **Jittered intervals** - randomized cadence | A machine-perfect 60.000s cadence looks mechanical | 4 |

### D. Platform touches

| # | Feature | Why it matters | Batch |
|---|---|---|---|
| D1 | **Machine-type defaults** - laptop starts at pause-on-battery | Sensible first run without reading docs | 2 |
| D2 | **Tray balloons on phase change** (opt-in, quiet default) | Awareness without the window open | 4 |
| D3 | **Per-tap CSV export** | Auditing and proof-of-attendance debates | 4 |

## Build batches

1. **A1, A5, B1, B2** - process triggers, resume recovery, diagnose, deadline toasts. Covers "long tasks" and "why did it sleep".
2. **A2, A3, A4, D1** - activity triggers, display-sleep control, status-apps preset, machine-type defaults.
3. **C1, C2, C3, B3, B4** - profiles, hotkeys, widget, insights, recap.
4. **A6, C4, C5, D2, D3** - weekly schedules, config exchange, jitter, balloons, CSV.

## Considered and rejected

| Idea | Why not |
|---|---|
| Block Windows lock / bypass session policy | Explicitly out of scope: it cannot work against Group Policy, and the tool must stay policy-honest |
| Elevated powercfg profile switching | Breaks the no-admin-rights principle; power requests already cover the use case |
| Browser-based remote control | Attack surface for no real gain |
| Keyboard/macro sending to apps (typing text, clicks) | The whole selling point is that the input is inert; writing text would break that |
| Machine-learning idle prediction | The idle threshold already solves the real problem with one number |
| Running as a Windows service or scheduled task | Per-user startup shortcut is the right altitude for this tool |

## Contributing notes

- PowerShell 5.1 compatible; ASCII-only sources (5.1 reads .ps1 as ANSI, so non-ASCII mojibakes).
- Shared engine first: every behavior lands in `KeepAliveEngine.ps1`, then both frontends inherit it.
- Every feature ships with a harness check in `test-engine.ps1` and/or `gui-smoke.ps1`.
