# test-engine.ps1 - dry-run harness for KeepAliveEngine.ps1 (no side effects).
$ErrorActionPreference = 'Stop'
. 'C:\Users\senior\Desktop\KeepAlive\KeepAliveEngine.ps1'

$pass = 0; $fail = 0
function Check($name, $cond) {
    if ($cond) { Write-Host "  ok - $name"; $script:pass++ }
    else { Write-Host "  FAIL - $name"; $script:fail++ }
}

Write-Host '== engine primitives =='
$idle = Get-KAIdleSeconds
Check 'Get-KAIdleSeconds returns a number' ($idle -is [double] -and $idle -ge 0)
$fg = Get-KAForegroundProcess
Check "Get-KAForegroundProcess returns string (got '$fg')" ($fg -is [string])
Check 'Test-KAFullscreen returns bool' ((Test-KAFullscreen) -is [bool])

Write-Host '== suppression rules =='
$cfgIdle = @{ IdleThreshold = 99999; Blacklist = @(); RespectFullscreen = $false }
$r1 = Get-KASuppressionReason $cfgIdle
Check 'idle threshold suppresses' ($r1 -like 'user active*')

if ($fg) {
    $cfgBlack = @{ IdleThreshold = 0; Blacklist = @("*$fg*", 'NOSUCHPROC'); RespectFullscreen = $false }
    $r2 = Get-KASuppressionReason $cfgBlack
    Check "blacklist suppresses foreground app ($fg)" ($r2 -like "*no-tap list*")
} else {
    Write-Host "  skip - blacklist check (no foreground process in this session)"
}

$cfgFree = @{ IdleThreshold = 0; Blacklist = @(); RespectFullscreen = $false }
Check 'no rules = no suppression' ((Get-KASuppressionReason $cfgFree) -eq '')

Write-Host '== cycle + dry-run =='
$st = Initialize-KAEngine -Key 'Shift' -Interval 1 -ActiveMinutes 0.016 -RestMinutes 0.05 -InputMode 'key' -PowerRequest -DryRun
Start-KACycle $st
Check 'starts in ACTIVE' ($st.Phase -eq 'ACTIVE')

$sawPress = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 300
    $out = Invoke-KATick $st
    if ($out.Events -match 'dry-run: would press Shift') { $sawPress = $true }
    if ($st.Phase -eq 'REST') { break }
}
Check 'dry-run presses log without executing' $sawPress
Check 'cycle enters REST' ($st.Phase -eq 'REST')

$pressesInRest = $st.PressCount
Start-Sleep -Milliseconds 500
[void](Invoke-KATick $st)
Check 'REST performs no input' ($st.PressCount -eq $pressesInRest)

$sawActive = $false
for ($i = 0; $i -lt 40 -and $st.Phase -eq 'REST'; $i++) {
    Start-Sleep -Milliseconds 300
    $out = Invoke-KATick $st
    if ($out.Events -match 'ACTIVE started') { $sawActive = $true }
}
Check 'cycle returns to ACTIVE' ($sawActive -or $st.Phase -eq 'ACTIVE')

Write-Host '== never-rest mode =='
$st2 = Initialize-KAEngine -Interval 1 -ActiveMinutes 0 -RestMinutes 2 -InputMode 'none' -PowerRequest -DryRun
Check 'never rest recognized' $st2.NeverRest
Start-KACycle $st2
$st2.PhaseEnd = (Get-Date).AddSeconds(-1)
[void](Invoke-KATick $st2)
Check 'never-rest stays ACTIVE after window' ($st2.Phase -eq 'ACTIVE')

Write-Host '== mouse mode =='
$st3 = Initialize-KAEngine -Interval 1 -ActiveMinutes 0.5 -InputMode 'mouse' -PowerRequest -DryRun
Start-KACycle $st3
$out3 = Invoke-KATick $st3
Check 'mouse dry-run logged' ($out3.Events -match 'dry-run: would nudge mouse')

Write-Host '== single instance =='
Check 'not already running at start' ((Test-KAAlreadyRunning) -eq $false)
$m = New-KAMutex
Check 'mutex detects the running instance' ((Test-KAAlreadyRunning) -eq $true)
$m.Dispose()

Write-Host '== tier 2: schedule window =='
$sched = Test-KAInSchedule -From '00:00' -Until '23:59' -Days @() -Now (Get-Date)
Check 'all-day window always in' ($sched.InWindow)
$sched2 = Test-KAInSchedule -From '00:00' -Until '00:01' -Days @() -Now (Get-Date)
if ($sched2.InWindow) {
    Write-Host '  skip - currently inside the 00:00-00:01 window'
} else {
    Check 'narrow window excludes now' (-not $sched2.InWindow)
    Check 'next start computed' ($sched2.NextStart -is [DateTime])
}
# overnight window (22:00-06:00) must be handled both halves
$midnight = [DateTime]::new(2026, 11, 2, 23, 30, 0)
$sched3 = Test-KAInSchedule -From '22:00' -Until '06:00' -Days @() -Now $midnight
Check 'overnight window in (23:30)' $sched3.InWindow
$morning = [DateTime]::new(2026, 11, 2, 3, 0, 0)
$sched4 = Test-KAInSchedule -From '22:00' -Until '06:00' -Days @() -Now $morning
Check 'overnight window in (03:00)' $sched4.InWindow
$noon = [DateTime]::new(2026, 11, 3, 12, 0, 0)
$sched5 = Test-KAInSchedule -From '22:00' -Until '06:00' -Days @() -Now $noon
Check 'overnight window out (12:00)' (-not $sched5.InWindow)
# day filter
$sched6 = Test-KAInSchedule -From '00:00' -Until '23:59' -Days @('Sunday') -Now $noon
if ($noon.DayOfWeek -eq 'Sunday') {
    Check 'day filter includes Sunday' $sched6.InWindow
} else {
    Check 'day filter excludes other days' (-not $sched6.InWindow)
}

Write-Host '== tier 2: run until / run for =='
$st4 = Initialize-KAEngine -Interval 1 -ActiveMinutes 1 -RestMinutes 1 -InputMode 'power' -PowerRequest -RunFor '30m'
Check 'run-for parsed to a stop time' ($st4.StopAt -is [DateTime])
$st5 = Initialize-KAEngine -Interval 1 -ActiveMinutes 1 -RestMinutes 1 -InputMode 'power' -PowerRequest -RunUntil '23:59'
Check 'run-until parsed to a stop time' ($st5.StopAt -is [DateTime])
$st6 = Initialize-KAEngine -InputMode 'power' -PowerRequest -RunFor '1h30m'
$mins = ($st6.StopAt - (Get-Date)).TotalMinutes
Check '1h30m parsed to 90 minutes' ($mins -gt 89 -and $mins -lt 91)
$st7 = Initialize-KAEngine -InputMode 'power' -PowerRequest -RunFor 'bogus'
Check 'unparsable duration = no stop time' ($null -eq $st7.StopAt)
# stop-at fires inside the tick
$st8 = Initialize-KAEngine -Interval 1 -ActiveMinutes 1 -RestMinutes 1 -InputMode 'none' -PowerRequest -RunFor '0m'
if (-not $st8.StopAt) { $st8.StopAt = (Get-Date).AddSeconds(-1) }
Start-KACycle $st8
$out8 = Invoke-KATick $st8
Check 'expired run window stops the engine' ($st8.Phase -eq 'STOPPED' -and $out8.Events -match 'Run window ended')

Write-Host '== tier 2: battery =='
Check 'ignore mode always allows' (Test-KABatteryAllows 'ignore' 'battery')
Check 'require-ac blocks battery' (-not (Test-KABatteryAllows 'require-ac' 'battery'))
Check 'require-ac allows ac' (Test-KABatteryAllows 'require-ac' 'ac')
Check 'unknown power source allows' (Test-KABatteryAllows 'require-ac' 'unknown')
$src = Get-KAPowerSource
Check "power source query works (got '$src')" (@('ac', 'battery', 'unknown').Contains($src))
$st9 = Initialize-KAEngine -Interval 1 -ActiveMinutes 1 -RestMinutes 1 -InputMode 'key' -BatteryMode 'require-ac'
if ($src -eq 'battery') {
    Check 'battery suppression reason present' ((Get-KASuppressionReason $st9.Cfg) -like 'on battery*')
} else {
    Check 'ac = no suppression' ((Get-KASuppressionReason $st9.Cfg) -eq '')
}

Write-Host '== tier 2: day list + duration parsing =='
Check 'day list splits' ((Split-KADayList @('mon, tue', 'wed')).Count -eq 3)
Check 'days trimmed' ((Split-KADayList @(' mon ') | ForEach-Object { $_ }) -eq 'mon')
Check 'duration split' ((Split-KADayList @()).Count -eq 0)

Write-Host "RESULT: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
exit 0
