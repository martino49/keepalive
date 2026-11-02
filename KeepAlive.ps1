# KeepAlive.ps1 - Keeps the PC awake in human-like cycles:
#   ACTIVE for $ActiveMinutes  -> presses Shift every $Interval sec
#   REST   for $RestMinutes    -> zero input (no keyboard, no mouse, nothing)
# then repeats until you stop it (Ctrl+C).
#
# Usage:
#   KeepAlive.bat                                  # defaults: 60s taps, 60min active / 2min rest
#   KeepAlive.bat -ActiveMinutes 30 -RestMinutes 5 # custom schedule
#   KeepAlive.bat -Key Ctrl -Interval 30           # different key / faster taps
#   KeepAlive.bat -ActiveMinutes 0                 # old behaviour: never rest

param(
    [double]$Interval = 60,
    [string]$Key = "Shift",
    [double]$ActiveMinutes = 60,
    [double]$RestMinutes = 2
)

Add-Type -MemberDefinition @'
[DllImport("user32.dll")]
public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, int dwExtraInfo);
'@ -Name "K" -Namespace "Win32"

$vk = switch ($Key) {
    "Shift"  { 0x10 }
    "Ctrl"   { 0x11 }
    "Alt"    { 0x12 }
    "Scroll" { 0x91 }
    default  { 0x10 }
}

function Format-Span([double]$Seconds) {
    if ($Seconds -lt 0) { $Seconds = 0 }
    $ts = [TimeSpan]::FromSeconds($Seconds)
    if ($ts.TotalHours -ge 1) { return "{0:hh\:mm\:ss}" -f $ts }
    return "{0:mm\:ss}" -f $ts
}

$schedule = "ACTIVE ${ActiveMinutes}min (${Key} every ${Interval}s) -> REST ${RestMinutes}min"
Write-Host "KeepAlive: $schedule. Ctrl+C to stop." -ForegroundColor Cyan

# ActiveMinutes <= 0 means "never rest" (the old behaviour). It must still
# sleep between presses or it degenerates into a hot spin.
if ($ActiveMinutes -le 0) {
    while ($true) {
        [Win32.K]::keybd_event($vk, 0, 0, 0)
        [Win32.K]::keybd_event($vk, 0, 2, 0)
        Write-Host "[$(Get-Date -Format HH:mm:ss)] ACTIVE $Key (no rest scheduled) - Ctrl+C to stop" -ForegroundColor Green
        Start-Sleep -Seconds ([Math]::Max(1, [Math]::Min($Interval, 86400)))
    }
}

while ($true) {

    # ---------- ACTIVE phase: keep the machine awake ----------
    $activeUntil = (Get-Date).AddMinutes($ActiveMinutes)
    while ($true) {
        # One full tap: press (flags 0) then release (flags 2 = KEYEVENTF_KEYUP).
        [Win32.K]::keybd_event($vk, 0, 0, 0)
        [Win32.K]::keybd_event($vk, 0, 2, 0)

        $remaining = ($activeUntil - (Get-Date)).TotalSeconds
        if ($remaining -le 0) {
            Write-Host "[$(Get-Date -Format HH:mm:ss)] ACTIVE done -> REST $(Format-Span $($RestMinutes * 60))" -ForegroundColor Cyan
            break
        }
        Write-Host "[$(Get-Date -Format HH:mm:ss)] ACTIVE $Key - rest in $(Format-Span $remaining)" -ForegroundColor Green
        Start-Sleep -Seconds ([Math]::Min($Interval, $remaining))
    }

    # ---------- REST phase: absolutely no input ----------
    if ($RestMinutes -le 0) { continue }
    $restUntil = (Get-Date).AddMinutes($RestMinutes)
    while ($true) {
        $remaining = ($restUntil - (Get-Date)).TotalSeconds
        if ($remaining -le 0) {
            Write-Host "[$(Get-Date -Format HH:mm:ss)] REST done -> ACTIVE ${ActiveMinutes}min" -ForegroundColor Cyan
            break
        }
        Write-Host "[$(Get-Date -Format HH:mm:ss)] REST (no input) - active in $(Format-Span $remaining)" -ForegroundColor DarkGray
        Start-Sleep -Seconds ([Math]::Min($Interval, $remaining))
    }
}
