# KeepAlive.ps1 - CLI keep-awake tool with ACTIVE/REST cycles.
# Engine lives in KeepAliveEngine.ps1 (shared with the GUI).
#
#   ACTIVE  : presses a key / nudges the mouse / holds a Windows power request
#   REST    : zero input (no keyboard, no mouse, nothing)
#
# Usage: KeepAlive.bat -Interval 30 -Key Ctrl -ActiveMinutes 45 -RestMinutes 2
#        KeepAlive.bat -InputMode mouse -PowerRequest
#        KeepAlive.bat -IdleThreshold 120 -BlackList zoom,teams
#        KeepAlive.bat -DryRun        # plan only, press nothing

param(
    [double]$Interval = 60,
    [string]$Key = 'Shift',
    [double]$ActiveMinutes = 60,
    [double]$RestMinutes = 2,
    [ValidateSet('key', 'mouse', 'power', 'none')]
    [string]$InputMode = 'key',
    [switch]$PowerRequest,
    [double]$IdleThreshold = 0,
    [string[]]$BlackList = @(),
    [switch]$RespectFullscreen,
    [switch]$DryRun,
    [string]$From = '',
    [string]$Until = '',
    [string[]]$Days = @(),
    [string]$RunFor = '',
    [string]$RunUntil = '',
    [ValidateSet('ignore', 'require-ac', 'pause-on-battery')]
    [string]$BatteryMode = 'ignore',
    [switch]$AutoStart,
    [switch]$NoAutoStart,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# ---- engine must load before any helper below is called ----
. (Join-Path $PSScriptRoot 'KeepAliveEngine.ps1')

# ---- settings file defaults (explicit flags always win) ----
$file = Read-KASettingsFile
if ($file) {
    if (-not $PSBoundParameters.ContainsKey('Key'))          { $Key = "$($file.Key)" }
    if (-not $PSBoundParameters.ContainsKey('InputMode'))    { $InputMode = "$($file.InputMode)" }
    if (-not $PSBoundParameters.ContainsKey('Interval'))     { $Interval = [double]$file.Interval }
    if (-not $PSBoundParameters.ContainsKey('ActiveMinutes')){ $ActiveMinutes = [double]$file.Active }
    if (-not $PSBoundParameters.ContainsKey('RestMinutes'))  { $RestMinutes = [double]$file.Rest }
    if (-not $PSBoundParameters.ContainsKey('IdleThreshold')){ $IdleThreshold = [double]$file.IdleThreshold }
    if (-not $PSBoundParameters.ContainsKey('BlackList'))    { $BlackList = @($file.Blacklist) }
    if (-not $PSBoundParameters.ContainsKey('From'))         { $From = "$($file.From)" }
    if (-not $PSBoundParameters.ContainsKey('Until'))        { $Until = "$($file.Until)" }
    if (-not $PSBoundParameters.ContainsKey('Days'))         { $Days = @($file.Days) }
    if (-not $PSBoundParameters.ContainsKey('RunFor'))       { $RunFor = "$($file.RunFor)" }
    if (-not $PSBoundParameters.ContainsKey('RunUntil'))     { $RunUntil = "$($file.RunUntil)" }
    if (-not $PSBoundParameters.ContainsKey('BatteryMode'))  { $BatteryMode = "$($file.BatteryMode)" }
    if (-not $PSBoundParameters.ContainsKey('PowerRequest')) { if ($file.PowerRequest) { $PowerRequest = $true } }
    if (-not $PSBoundParameters.ContainsKey('RespectFullscreen')) { if ($file.RespectFullscreen) { $RespectFullscreen = $true } }
    if (-not $DryRun) { if ($file.DryRun) { $DryRun = $true } }
}

if ($Help) {
    Write-Host @'
KeepAlive - keep your PC awake without babysitting it.

  -Interval <sec>        Seconds between input actions (default 60)
  -Key <key>             Shift | Ctrl | Alt | ScrollLock (default Shift)
  -ActiveMinutes <min>   ACTIVE phase length; 0 = never rest (default 60)
  -RestMinutes <min>     REST phase length, no input at all (default 2)
  -InputMode <mode>      key | mouse | power | none (default key)
  -PowerRequest          Hold a Windows power request while active
  -IdleThreshold <sec>   Only act after this much real idle (0 = off)
  -BlackList <names>     Processes that pause input: -BlackList zoom,teams
  -RespectFullscreen      Pause input while a fullscreen app has focus
  -DryRun                Log intended actions, touch nothing

  -From HH:mm            Schedule window start (empty = all day)
  -Until HH:mm           Schedule window end (supports overnight: 22:00-06:00)
  -Days <names>          Weekday filter: -Days mon,tue,wed
  -RunFor <dur>          Stop after this long: 1h30m, 90m
  -RunUntil HH:mm        Stop at this clock time
  -BatteryMode <mode>    ignore | require-ac | pause-on-battery
                         (input pauses/ stops on battery; laptop friendly)
  -AutoStart             Add KeepAlive to Windows startup (runs at logon)
  -NoAutoStart           Remove it from Windows startup
  -Help                  This text

Anything not given on the command line comes from KeepAlive.settings.json
(the file the GUI writes), so a schedule set in the GUI applies here too.
Session activity is appended to KeepAlive.log.

The session lock pauses everything automatically while your screen is locked.

Exit codes: 0 clean stop, 2 already running, 1 error.
'@
    exit 0
}


# ---- validate ----
function Fail([string]$Message) {
    [Console]::Error.WriteLine("KeepAlive: $Message")
    exit 1
}
if ($Interval -lt 1) { Fail '-Interval must be 1 or more.' }
if ($ActiveMinutes -lt 0) { Fail '-ActiveMinutes must be 0 or positive.' }
if ($RestMinutes -lt 0) { Fail '-RestMinutes must be 0 or positive.' }
if ($ActiveMinutes -gt 0 -and $RestMinutes -le 0) {
    Fail 'With a positive active window, -RestMinutes must be at least 0.5 (use -ActiveMinutes 0 for never-rest).'
}
if ($InputMode -eq 'none' -and -not $PowerRequest) {
    Fail 'InputMode none without -PowerRequest would do nothing.'
}
if (-not $DryRun -and (Test-KAAlreadyRunning)) {
    $blocked = Show-KAExistingWindow
    if ($blocked) {
        Write-Host 'KeepAlive: already running - focused the existing window.'
    } else {
        Write-Host 'KeepAlive: already running (no window found). Stop it first or use the tray icon.'
    }
    exit 2
}

# ---- auto-start toggle ----
if ($NoAutoStart) {
    if (Disable-KAAutoStart) { Write-Host 'KeepAlive: removed from Windows startup.' } else { Write-Host 'KeepAlive: nothing to remove.' }
    exit 0
}
if ($AutoStart) {
    if (Enable-KAAutoStart) { Write-Host "KeepAlive: added to Windows startup - runs at logon: $(Get-KAStartupShortcutPath)" }
    else { Fail 'Could not create the startup shortcut.' }
    exit 0
}

# ---- build the engine ----
if ($From -or $Until) {
    if (-not $From) { Fail 'With -Until set, -From is required too.' }
    if (-not $Until) { Fail 'With -From set, -Until is required too.' }
}
if ($From -and $From -notmatch '^\d{1,2}:\d{2}$') { Fail '-From must be HH:mm.' }
if ($Until -and $Until -notmatch '^\d{1,2}:\d{2}$') { Fail '-Until must be HH:mm.' }
$dayNames = Split-KADayList $Days
foreach ($d in $dayNames) {
    if ($d.Substring(0, [Math]::Min(3, $d.Length)).ToLower() -notin @('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun')) {
        Fail "-Days value '$d' is not a weekday (mon..sun)."
    }
}

$state = Initialize-KAEngine `
    -Key $Key `
    -Interval $Interval `
    -ActiveMinutes $ActiveMinutes `
    -RestMinutes $RestMinutes `
    -InputMode $InputMode `
    -PowerRequest:$PowerRequest `
    -IdleThreshold $IdleThreshold `
    -BlackList $BlackList `
    -RespectFullscreen:$RespectFullscreen `
    -DryRun:$DryRun `
    -From $From `
    -Until $Until `
    -Days $dayNames `
    -RunFor $RunFor `
    -RunUntil $RunUntil `
    -BatteryMode $BatteryMode

# ---- report the plan ----
$plan = "ACTIVE $ActiveMinutes min -> REST $RestMinutes min"
if ($ActiveMinutes -le 0) { $plan = 'ACTIVE forever (never rest) -> no REST' }
$mechanism = switch ($InputMode) {
    'key'   { "press $Key every ${Interval}s" }
    'mouse' { "nudge mouse every ${Interval}s" }
    'power' { 'power request only (no input)' }
    'none'  { 'nothing' }
}
Write-Host "KeepAlive: $plan | $mechanism"
if ($PowerRequest) { Write-Host 'KeepAlive: Windows power request held while ACTIVE' }
if ($IdleThreshold -gt 0) { Write-Host "KeepAlive: only acts after ${IdleThreshold}s of real idle" }
if ($BlackList.Count) { Write-Host "KeepAlive: no-tap list = $($BlackList -join ', ')" }
if ($RespectFullscreen) { Write-Host 'KeepAlive: fullscreen apps pause input' }
if ($From -and $Until) {
    $daysText = if ($dayNames.Count) { " on $($dayNames -join ', ')" } else { '' }
    Write-Host "KeepAlive: schedule window $From-$Until$daysText (outside it: no input, no power request)"
}
if ($state.StopAt) { Write-Host "KeepAlive: run window ends at $($state.StopAt.ToString('HH:mm:ss'))" }
if ($BatteryMode -ne 'ignore') { Write-Host "KeepAlive: battery mode '$BatteryMode' (power source: $(Get-KAPowerSource))" }
if ($DryRun) { Write-Host 'KeepAlive: DRY RUN - nothing will be pressed or claimed' }
Write-Host 'KeepAlive: Ctrl+C to stop.'

# ---- session lock pauses everything ----
if (-not $DryRun) { $null = Register-KASessionEvents }

# ---- hold the mutex for our lifetime (not in dry-run) ----
if (-not $DryRun) { $null = New-KAMutex }

if (-not $DryRun) {
    Write-KASessionLog "start (pid $PID): $mechanism, $plan$(if ($From -and $Until) { ", window $From-$Until$daysText" })$(if ($state.StopAt) { ", ends $($state.StopAt.ToString('HH:mm'))" })"
}

try {
    Start-KACycle $state
    Write-KASessionLog 'ACTIVE started'
    while ($state.Phase -ne 'STOPPED') {
        Start-Sleep -Milliseconds 900
        $out = Invoke-KATick $state
        foreach ($ev in $out.Events) {
            $color = 'Gray'
            if ($ev -like 'ACTIVE*') { $color = 'Green' }
            if ($ev -like 'REST*') { $color = 'DarkGray' }
            if ($ev -like '*paused*' -or $ev -like '*battery*') { $color = 'DarkYellow' }
            if ($ev -like '*error*') { $color = 'Red' }
            Write-Host "[$(Get-Date -Format HH:mm:ss)] $ev" -ForegroundColor $color
            if (-not $DryRun) {
                if ($ev -like 'ACTIVE*' -or $ev -like 'REST*' -or $ev -like 'Run window*' -or $ev -like 'input paused*') {
                    Write-KASessionLog $ev
                }
            }
        }
        if ($out.Ended) { break }
    }
} finally {
    Stop-KACycle $state
    if ($script:KAMutex) { $script:KAMutex.Dispose(); $script:KAMutex = $null }
    if (-not $DryRun) { Write-KASessionLog "stopped - $($state.PressCount) actions total" }
    Write-Host "KeepAlive: stopped - $($state.PressCount) input actions total."
}
