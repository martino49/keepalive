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
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

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
  -Help                  This text

Exit codes: 0 clean stop, 2 already running, 1 error.
'@
    exit 0
}

. (Join-Path $PSScriptRoot 'KeepAliveEngine.ps1')

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

# ---- build the engine ----
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
    -DryRun:$DryRun

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
if ($DryRun) { Write-Host 'KeepAlive: DRY RUN - nothing will be pressed or claimed' }
Write-Host 'KeepAlive: Ctrl+C to stop.'

# ---- hold the mutex for our lifetime (not in dry-run) ----
if (-not $DryRun) { $null = New-KAMutex }

try {
    Start-KACycle $state
    $taps = 0
    while ($state.Phase -ne 'STOPPED') {
        Start-Sleep -Milliseconds 900
        $out = Invoke-KATick $state
        foreach ($ev in $out.Events) {
            $color = 'Gray'
            if ($ev -like 'ACTIVE*') { $color = 'Green' }
            if ($ev -like 'REST*') { $color = 'DarkGray' }
            if ($ev -like '*error*') { $color = 'Red' }
            Write-Host "[$(Get-Date -Format HH:mm:ss)] $ev" -ForegroundColor $color
        }
        if ($state.PressCount -ne $taps) { $taps = $state.PressCount }
    }
} finally {
    Stop-KACycle $state
    if ($script:KAMutex) { $script:KAMutex.Dispose(); $script:KAMutex = $null }
    Write-Host "KeepAlive: stopped - $($state.PressCount) input actions total."
}
