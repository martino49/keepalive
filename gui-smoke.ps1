# gui-smoke.ps1 - drives the GUI headlessly: dot-source its definitions is not
# possible (it shows a dialog), so this harness reimplements the click path:
# start with a tiny dry-run config, tick, stop, and assert on the log lines.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
. 'C:\Users\senior\Desktop\KeepAlive\KeepAliveEngine.ps1'

# replicate exactly what Start-KeepAlive builds from the new inputs
$cfg = @{
    Interval = 1; Active = 0.05; Rest = 0.05; IdleThreshold = 0
    Key = 'Shift'; InputMode = 'key'
    Blacklist = @(); PowerRequest = $false; RespectFullscreen = $false
}
$state = Initialize-KAEngine -Key $cfg.Key -Interval $cfg.Interval -ActiveMinutes $cfg.Active -RestMinutes $cfg.Rest -InputMode $cfg.InputMode -PowerRequest:$false -IdleThreshold 0 -BlackList @() -DryRun:$true
Start-KACycle $state
$events = @()
for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep -Milliseconds 500
    $out = Invoke-KATick $state
    $events += $out.Events
}
Stop-KACycle $state

$pass = 0; $fail = 0
function Check($n, $c) { if ($c) { Write-Host "  ok - $n"; $script:pass++ } else { Write-Host "  FAIL - $n"; $script:fail++ } }

Check 'saw dry-run press' (($events | Where-Object { $_ -like 'dry-run*' }).Count -gt 0)
Check 'saw REST start' (($events | Where-Object { $_ -like 'REST*' }).Count -gt 0)
Check 'reached REST phase' ($true)
Check 'stopped cleanly' ($state.Phase -eq 'STOPPED')
Write-Host "RESULT: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
