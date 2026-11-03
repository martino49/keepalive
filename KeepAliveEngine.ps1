# KeepAliveEngine.ps1 - shared engine for the KeepAlive tool.
# Dot-source this from KeepAlive.ps1 (CLI) and KeepAliveUI.ps1 (GUI).
# ASCII only: PowerShell 5.1 reads .ps1 as ANSI, so non-ASCII mojibakes.
#
# Provides:
#   * ACTIVE/REST cycle state machine
#   * Keep-awake via Windows power requests (SetThreadExecutionState)
#   * Optional input taps (key or mouse) that respect real user activity
#     (GetLastInputInfo), fullscreen apps and a process blacklist
#   * Dry-run mode: logs intended actions with zero system effect
#   * Single-instance guard (named mutex)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern bool GetSystemPowerStatus(ref SYSTEM_POWER_STATUS lpSystemPowerStatus);

[StructLayout(LayoutKind.Sequential)]
public struct SYSTEM_POWER_STATUS {
    public byte ACLineStatus; public byte BatteryFlag; public byte BatteryLifePercent;
    public byte SystemStatusFlag; public uint BatteryLifeTime; public uint BatteryFullLifeTime;
}
'@ -Name "KAp" -Namespace "Win32" -ErrorAction SilentlyContinue

Add-Type -MemberDefinition @'
[DllImport("user32.dll")]
public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, int dwExtraInfo);

[DllImport("kernel32.dll")]
public static extern uint SetThreadExecutionState(uint esFlags);

[DllImport("user32.dll")]
public static extern uint GetLastInputInfo(ref LASTINPUTINFO plii);

[StructLayout(LayoutKind.Sequential)]
public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

[DllImport("user32.dll")]
public static extern IntPtr GetForegroundWindow();

[DllImport("user32.dll")]
public static extern int GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int count);

[DllImport("user32.dll")]
public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
'@ -Name "KA" -Namespace "Win32"

# ---------------- constants ----------------
$script:KA_VK = @{ Shift = 0x10; Ctrl = 0x11; Alt = 0x12; ScrollLock = 0x91 }
$script:KA_ES_CONTINUOUS      = [uint32]2147483648   # 0x80000000 (hex literal overflows Int32)
$script:KA_ES_SYSTEM_REQUIRED = [uint32]0x00000001
$script:KA_ES_DISPLAY_REQUIRED= [uint32]0x00000002
$script:KA_ES_AWAYMODE_REQUIRED = [uint32]0x00000004

# ---------------- helpers ----------------
function Get-KAKeyCode([string]$name) {
    if ($name -and $script:KA_VK.ContainsKey($name)) { return $script:KA_VK[$name] }
    return 0x10
}

function Format-KASpan([double]$Seconds) {
    if ($Seconds -lt 0) { $Seconds = 0 }
    $ts = [TimeSpan]::FromSeconds($Seconds)
    if ($ts.TotalHours -ge 1) { return '{0:hh\:mm\:ss}' -f $ts }
    return '{0:mm\:ss}' -f $ts
}

# Seconds since the last real keyboard/mouse input anywhere in the session.
function Get-KAIdleSeconds {
    try {
        $lii = New-Object Win32.KA+LASTINPUTINFO
        $lii.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($lii)
        if ([Win32.KA]::GetLastInputInfo([ref]$lii) -eq 0) { return 0 }
        $idle = [Environment]::TickCount - $lii.dwTime
        if ($idle -lt 0) { $idle = 0 }
        return [double]($idle / 1000)
    } catch {
        return 0 # never block ticking because detection failed
    }
}

# Process name of the foreground window ('' when unknown).
function Get-KAForegroundProcess {
    try {
        $h = [Win32.KA]::GetForegroundWindow()
        if ($h -eq [IntPtr]::Zero) { return '' }
        $pid = 0
        [void][Win32.KA]::GetWindowThreadProcessId($h, [ref]$pid)
        if ($pid -le 0) { return '' }
        $p = Get-Process -Id $pid -ErrorAction SilentlyContinue
        if ($p) { return $p.ProcessName }
        return ''
    } catch {
        return ''
    }
}

# True when the foreground window fills its monitor (fullscreen apps).
function Test-KAFullscreen {
    try {
        $h = [Win32.KA]::GetForegroundWindow()
        if ($h -eq [IntPtr]::Zero) { return $false }
        $r = New-Object Win32.KA+RECT
        if (-not [Win32.KA]::GetWindowRect($h, [ref]$r)) { return $false }
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        if ($screen.Width -le 0 -or $screen.Height -le 0) { return $false }
        $w = $r.Right - $r.Left
        $hh = $r.Bottom - $r.Top
        return ($w -ge ($screen.Width - 2) -and $hh -ge ($screen.Height - 2))
    } catch {
        return $false
    }
}

# ---------------- power / battery ----------------
# Returns: 'ac', 'battery' or 'unknown' (255 = no battery info, i.e. desktop).
function Get-KAPowerSource {
    try {
        $s = New-Object Win32.KAp+SYSTEM_POWER_STATUS
        if ([Win32.KAp]::GetSystemPowerStatus([ref]$s)) {
            switch ($s.ACLineStatus) {
                1 { return 'ac' }
                0 { return 'battery' }
                default { return 'unknown' }
            }
        }
    } catch { }
    return 'unknown'
}

# Pure decision so it can be tested without touching hardware.
function Test-KABatteryAllows {
    param($BatteryMode, $PowerSource)
    if (-not $BatteryMode -or $BatteryMode -eq 'ignore') { return $true }
    if ($PowerSource -eq 'battery') { return $false }
    return $true
}

# ---------------- schedule window ----------------
# $From / $Until are 'HH:mm' strings ('' = no window); $Days is an array of
# day names ('' = every day). Returns @{ InWindow = bool; NextStart = DateTime }.
function Test-KAInSchedule {
    param($From, $Until, $Days, $Now = (Get-Date))
    if (-not $From -or -not $Until) { return @{ InWindow = $true; NextStart = $null } }

    if ($Days -and @($Days).Count -gt 0) {
        $dayOk = $false
        foreach ($d in @($Days)) {
            if ($d.Trim() -and $Now.DayOfWeek.ToString().ToLower().StartsWith($d.Trim().Substring(0, 3).ToLower())) { $dayOk = $true }
        }
        if (-not $dayOk) {
            # find the next scheduled day at $From
            $next = $Now.Date.AddDays(1)
            for ($i = 0; $i -lt 8; $i++) {
                $cand = $Now.Date.AddDays($i)
                $match = $false
                foreach ($d in @($Days)) {
                    if ($d.Trim() -and $cand.DayOfWeek.ToString().ToLower().StartsWith($d.Trim().Substring(0, 3).ToLower())) { $match = $true }
                }
                if ($match) { $next = $cand; break }
            }
            $fh = 0; $fm = 0
            if ($From -match '^(\d{1,2}):(\d{2})$') { $fh = [int]$Matches[1]; $fm = [int]$Matches[2] }
            return @{ InWindow = $false; NextStart = $next.AddHours($fh).AddMinutes($fm) }
        }
    }

    $fh = 0; $fm = 0; $uh = 23; $um = 59
    if ($From -match '^(\d{1,2}):(\d{2})$') { $fh = [int]$Matches[1]; $fm = [int]$Matches[2] }
    if ($Until -match '^(\d{1,2}):(\d{2})$') { $uh = [int]$Matches[1]; $um = [int]$Matches[2] }
    $minutesNow = $Now.Hour * 60 + $Now.Minute
    $start = $fh * 60 + $fm
    $end = $uh * 60 + $um
    $inWindow = if ($start -le $end) { ($minutesNow -ge $start -and $minutesNow -lt $end) } else { ($minutesNow -ge $start -or $minutesNow -lt $end) }
    if ($inWindow) { return @{ InWindow = $true; NextStart = $null } }

    # next start today or tomorrow
    $candidate = $Now.Date.AddHours($fh).AddMinutes($fm)
    if ($candidate -le $Now) { $candidate = $candidate.AddDays(1) }
    return @{ InWindow = $false; NextStart = $candidate }
}

# Parses 'HH:mm' -> today at that time; past times become tomorrow for
# -RunUntil (a stop time that already passed means "stop immediately").
function Convert-KATimeOfDay {
    param([string]$Value, [switch]$PastMeansTomorrow)
    if ($Value -notmatch '^(\d{1,2}):(\d{2})$') { return $null }
    $h = [int]$Matches[1]; $m = [int]$Matches[2]
    if ($h -gt 23 -or $m -gt 59) { return $null }
    $t = (Get-Date).Date.AddHours($h).AddMinutes($m)
    if ($t -le (Get-Date)) { $t = $t.AddDays(1) }
    return $t
}

# Parses '1h30m', '90m', '45s' -> total minutes (0 when unparsable).
function Convert-KADuration {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 0 }
    $total = 0
    foreach ($m in [regex]::Matches($Value, '(\d+)\s*h')) { $total += [int]$m.Groups[1].Value * 60 }
    foreach ($m in [regex]::Matches($Value, '(\d+)\s*m')) { $total += [int]$m.Groups[1].Value }
    foreach ($m in [regex]::Matches($Value, '(\d+)\s*s')) { $total += ([int]$m.Groups[1].Value / 60.0) }
    return $total
}

function Split-KADayList {
    param([string[]]$Names)
    $out = @()
    foreach ($n in @($Names)) {
        foreach ($piece in ($n -split ',')) {
            $p = $piece.Trim()
            if ($p) { $out += $p }
        }
    }
    return $out
}

# ---------------- power request ----------------
function Set-KAPowerAwake {
    param([switch]$DisplayOnly, [switch]$AwayMode, [switch]$Suppress)
    if ($Suppress) { return }
    $flags = $script:KA_ES_CONTINUOUS
    if ($DisplayOnly) {
        $flags = $flags -bor $script:KA_ES_DISPLAY_REQUIRED
    } else {
        $flags = $flags -bor $script:KA_ES_SYSTEM_REQUIRED -bor $script:KA_ES_DISPLAY_REQUIRED
    }
    if ($AwayMode) { $flags = $flags -bor $script:KA_ES_AWAYMODE_REQUIRED }
    [void][Win32.KA]::SetThreadExecutionState($flags)
}

function Clear-KAPowerAwake {
    param([switch]$Suppress)
    if ($Suppress) { return }
    # ES_CONTINUOUS alone releases the request.
    [void][Win32.KA]::SetThreadExecutionState($script:KA_ES_CONTINUOUS)
}

# ---------------- input actions ----------------
function Invoke-KAKeyTap {
    param([string]$Key, [switch]$Suppress)
    if ($Suppress) { return }
    $vk = Get-KAKeyCode $Key
    [Win32.KA]::keybd_event($vk, 0, 0, 0)
    [Win32.KA]::keybd_event($vk, 0, 2, 0)
}

function Invoke-KAMouseNudge {
    param([switch]$Suppress)
    if ($Suppress) { return }
    # Move 1px right-down then straight back: invisible, counts as activity.
    $pos = [System.Windows.Forms.Cursor]::Position
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(($pos.X + 1), ($pos.Y + 1))
    Start-Sleep -Milliseconds 50
    [System.Windows.Forms.Cursor]::Position = $pos
}

# ---------------- suppression rules ----------------
# Returns a reason string when input must NOT be injected right now, else ''.
function Get-KASuppressionReason {
    param($Cfg)
    if (-not $Cfg) { return '' }

    if (Test-KASessionSuspended) { return 'session locked' }

    $idle = Get-KAIdleSeconds
    if ($Cfg.IdleThreshold -gt 0 -and $idle -lt [double]$Cfg.IdleThreshold) {
        return "user active (idle $([int]$idle)s < $($Cfg.IdleThreshold)s)"
    }

    $fg = Get-KAForegroundProcess
    if ($fg) {
        if ($Cfg.Blacklist | Where-Object { $_ -and $fg -like $_ }) {
            return "app '$fg' is on the no-tap list"
        }
        if ($Cfg.RespectFullscreen -and (Test-KAFullscreen)) {
            return "fullscreen app '$fg'"
        }
    }

    # battery rules: pure decision, hardware queried once per call
    if ($Cfg.BatteryMode -and $Cfg.BatteryMode -ne 'ignore') {
        $source = Get-KAPowerSource
        if (-not (Test-KABatteryAllows -BatteryMode $Cfg.BatteryMode -PowerSource $source)) {
            if ($source -eq 'battery') { return 'on battery' }
        }
    }
    return ''
}

# ---------------- session lock/resume ----------------
# Registered by the frontends (CLI/GUI). While suspended, the engine still
# ticks but never acts - the session is locked so input is meaningless.
$script:KASessionSuspended = $false
$script:KARoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

function Suspend-KASession {
    $script:KASessionSuspended = $true
}

function Resume-KASession {
    $script:KASessionSuspended = $false
}

function Test-KASessionSuspended { return $script:KASessionSuspended }

function Register-KASessionEvents {
    try {
        $null = [Microsoft.Win32.SystemEvents]::add_SessionSwitch({
            if ($EventArgs.Reason -eq [Microsoft.Win32.SessionSwitchReason]::SessionLock) {
                Suspend-KASession | Out-Null
            } elseif ($EventArgs.Reason -eq [Microsoft.Win32.SessionSwitchReason]::SessionUnlock) {
                Resume-KASession | Out-Null
            }
        })
        return $true
    } catch {
        return $false
    }
}

# Power claim only when the battery mode allows it.
function Test-KAShouldClaimPower {
    param($State)
    $Cfg = $State.Cfg
    if (-not $Cfg.PowerRequest) { return $false }
    $source = Get-KAPowerSource
    return (Test-KABatteryAllows -BatteryMode $Cfg.BatteryMode -PowerSource $source)
}

# ---------------- engine ----------------
function Initialize-KAEngine {
    param(
        [string]$Key = 'Shift',
        [double]$Interval = 60,
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
        [string]$BatteryMode = 'ignore'
    )

    $state = [ordered]@{
        Cfg             = @{
            Key               = $Key
            Interval          = $Interval
            ActiveMinutes     = $ActiveMinutes
            RestMinutes       = $RestMinutes
            InputMode         = $InputMode
            PowerRequest      = [bool]$PowerRequest
            IdleThreshold     = $IdleThreshold
            Blacklist         = @($BlackList)
            RespectFullscreen = [bool]$RespectFullscreen
            DryRun            = [bool]$DryRun
            From              = $From
            Until             = $Until
            Days              = @($Days)
            BatteryMode       = $BatteryMode
        }
        StopAt           = $null
        ScheduleEnded    = $false
        Phase            = 'STOPPED'
        PhaseEnd         = (Get-Date)
        PhaseStart       = (Get-Date)
        LastPress        = $null
        PressCount       = 0
        NeverRest        = ($ActiveMinutes -le 0)
        StartedAt        = $null
        SuppressedSince  = $null
        LastReason       = ''
    }

    # --RunFor <1h30m> -> stop this many minutes after Start.
    if ($RunFor) {
        $mins = Convert-KADuration $RunFor
        if ($mins -gt 0) { $state.StopAt = (Get-Date).AddMinutes($mins) }
    }
    # --RunUntil HH:mm -> stop at that clock time (past times roll to tomorrow).
    if ($RunUntil) {
        $t = Convert-KATimeOfDay $RunUntil
        if ($t) { $state.StopAt = $t }
    }
    return $state
}

function Start-KACycle {
    param($State)
    $now = Get-Date
    $State.Phase = 'ACTIVE'
    $State.PhaseStart = $now
    $State.PhaseEnd = $now.AddMinutes([Math]::Max(0.016, [double]$State.Cfg.ActiveMinutes))
    $State.LastPress = $null
    $State.StartedAt = $now
    $State.PressCount = 0
    if (Test-KAShouldClaimPower $State) { Set-KAPowerAwake -Suppress:$State.Cfg.DryRun }
}

function Stop-KACycle {
    param($State)
    $State.Phase = 'STOPPED'
    if ($State.Cfg.PowerRequest) { Clear-KAPowerAwake -Suppress:$State.Cfg.DryRun }
}

# One engine tick. Returns @{ Events = string[] } describing what happened so
# the CLI/GUI can log. Never throws into the caller.
function Invoke-KATick {
    param($State)

    $events = @()
    try {
        $Cfg = $State.Cfg
        $now = Get-Date
        $remaining = ($State.PhaseEnd - $now).TotalSeconds

        # ---- scheduled end of the whole session ----
        if ($State.StopAt -and $now -ge $State.StopAt -and $State.Phase -ne 'STOPPED') {
            Stop-KACycle $State
            $State.ScheduleEnded = $true
            $events += 'Run window ended - stopped'
            return @{ Events = $events; Ended = $true }
        }

        # ---- schedule window (time of day / days) ----
        $sched = Test-KAInSchedule -From $Cfg.From -Until $Cfg.Until -Days $Cfg.Days -Now $now
        if (-not $sched.InWindow) {
            if ($State.Phase -ne 'SCHEDULED') {
                $State.Phase = 'SCHEDULED'
                if ($Cfg.PowerRequest) { Clear-KAPowerAwake -Suppress:$Cfg.DryRun }
                $nextText = if ($sched.NextStart) { Format-KASpan (($sched.NextStart - $now).TotalSeconds) } else { 'unknown' }
                $events += "Outside schedule - waiting (next window in $nextText)"
            }
            # while outside the window: no power request, no input
            return @{ Events = $events }
        }
        if ($State.Phase -eq 'SCHEDULED') {
            $State.Phase = 'ACTIVE'
            $State.PhaseStart = $now
            $State.PhaseEnd = $now.AddMinutes([Math]::Max(0.016, [double]$Cfg.ActiveMinutes))
            $State.LastPress = $null
            if (Test-KAShouldClaimPower $State) { Set-KAPowerAwake -Suppress:$Cfg.DryRun }
            $events += 'Schedule window started - ACTIVE'
        }

        if ($State.Phase -eq 'ACTIVE') {

            # ---- input action (key or mouse) ----
            if ($Cfg.InputMode -eq 'key' -or $Cfg.InputMode -eq 'mouse') {
                $interval = [double]$Cfg.Interval
                if ($interval -lt 1) { $interval = 1 }
                $due = (-not $State.LastPress) -or (($now - $State.LastPress).TotalSeconds -ge $interval)
                if ($due) {
                    $reason = Get-KASuppressionReason $Cfg
                    if ($reason) {
                        if ($State.LastReason -ne $reason) {
                            $State.LastReason = $reason
                            $events += "input paused - $reason"
                        }
                    } else {
                        if ($State.LastReason) { $events += 'input resumed' }
                        $State.LastReason = ''
                        if ($Cfg.DryRun) {
                            if ($Cfg.InputMode -eq 'key') {
                                $events += "dry-run: would press $($Cfg.Key)"
                            } else {
                                $events += 'dry-run: would nudge mouse'
                            }
                        } else {
                            if ($Cfg.InputMode -eq 'key') {
                                Invoke-KAKeyTap -Key $Cfg.Key
                            } else {
                                Invoke-KAMouseNudge
                            }
                        }
                        $State.LastPress = $now
                        $State.PressCount++
                        if ($State.SuppressedSince) { $State.SuppressedSince = $null }
                    }
                }
            }

            # ---- phase transition ----
            if ($remaining -le 0) {
                if ($State.NeverRest) {
                    $State.PhaseStart = $now
                    $State.PhaseEnd = $now.AddMinutes([Math]::Max(1, [double]$Cfg.ActiveMinutes))
                } else {
                    $State.Phase = 'REST'
                    $State.PhaseStart = $now
                    $State.PhaseEnd = $now.AddMinutes([double]$Cfg.RestMinutes)
                    $State.LastPress = $null
                    $State.LastReason = ''
                    if ($Cfg.PowerRequest) { Clear-KAPowerAwake -Suppress:$Cfg.DryRun }
                    $events += "REST started - $($Cfg.RestMinutes) min of zero input"
                }
            }
        }
        elseif ($State.Phase -eq 'REST') {
            if ($remaining -le 0) {
                $State.Phase = 'ACTIVE'
                $State.PhaseStart = $now
                $State.PhaseEnd = $now.AddMinutes([double]$Cfg.ActiveMinutes)
                $State.LastPress = $null
                if (Test-KAShouldClaimPower $State) { Set-KAPowerAwake -Suppress:$Cfg.DryRun }
                $events += "ACTIVE started - $($Cfg.ActiveMinutes) min"
            }
        }
    } catch {
        $events += "engine error: $($_.Exception.Message)"
    }

    return @{ Events = $events }
}

# ---------------- session log ----------------
$script:KALogPath = Join-Path $(if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }) 'KeepAlive.log'

function Write-KASessionLog {
    param([string]$Message)
    try {
        $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
        Add-Content -Path $script:KALogPath -Value $line -Encoding ASCII
    } catch {
        # logging must never break the tool
    }
}

function Get-KASessionLogTail {
    param([int]$Lines = 20)
    try {
        if (Test-Path $script:KALogPath) {
            return (Get-Content $script:KALogPath -Tail $Lines)
        }
    } catch { }
    return @()
}

# ---------------- auto-start with Windows ----------------
function Get-KAStartupShortcutPath {
    return (Join-Path ([Environment]::GetFolderPath('Startup')) 'KeepAlive.lnk')
}

function Test-KAAutoStartEnabled {
    return (Test-Path (Get-KAStartupShortcutPath))
}

function Enable-KAAutoStart {
    param([switch]$Minimized)
    try {
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut((Get-KAStartupShortcutPath))
        $lnk.TargetPath = "$env:WINDIR\System32\cmd.exe"
        # /c start with the empty title keeps a console flashless batch launch
        $lnk.Arguments = '/c ""' + '"' + (Join-Path $script:KARoot 'KeepAlive.bat') + '""'
        $lnk.WorkingDirectory = $script:KARoot
        $lnk.Description = 'KeepAlive - keep this PC awake'
        $lnk.Save()
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        return $true
    } catch {
        return $false
    }
}

function Disable-KAAutoStart {
    try {
        Remove-Item (Get-KAStartupShortcutPath) -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

# ---------------- shared settings ----------------
# CLI and GUI share one config file so a schedule set in the GUI is the
# default for the CLI too (explicit flags always win).
function Read-KASettingsFile {
    param([string]$Path = (Join-Path $(if ($PSScriptRoot) { $PSScriptRoot } else { '.' }) 'KeepAlive.settings.json'))
    try {
        if (Test-Path $Path) {
            return (Get-Content $Path -Raw | ConvertFrom-Json)
        }
    } catch { }
    return $null
}

# ---------------- single instance ----------------
function New-KAMutex {
    param([string]$Name = 'Local\KeepAlive.SingleInstance')
    try {
        $isNew = $false
        $script:KAMutex = New-Object System.Threading.Mutex($true, $Name, [ref]$isNew)
        return $script:KAMutex
    } catch {
        # Session-scoped named objects can still fail (elevated siblings,
        # odd ACL setups). The guard is a nicety - never let it stop the user.
        $script:KAMutex = $null
        return $null
    }
}

function Test-KAAlreadyRunning {
    try {
        $createdNew = $false
        $m = New-Object System.Threading.Mutex($true, 'Local\KeepAlive.SingleInstance', [ref]$createdNew)
        $m.Dispose()
        return (-not $createdNew)
    } catch {
        return $false # if the check itself fails, let the app run
    }
}

# Focus an existing instance window (best effort).
function Show-KAExistingWindow {
    param([string]$Title = 'KeepAlive')
    try {
        Add-Type -MemberDefinition @'
[DllImport("user32.dll")]
public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

[DllImport("user32.dll")]
public static extern bool SetForegroundWindow(IntPtr hWnd);

[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -Name "KAW" -Namespace "Win32" -ErrorAction SilentlyContinue

        $h = [Win32.KAW]::FindWindow($null, $Title)
        if ($h -ne [IntPtr]::Zero) {
            [void][Win32.KAW]::ShowWindow($h, 9) # SW_RESTORE
            [void][Win32.KAW]::SetForegroundWindow($h)
            return $true
        }
    } catch { }
    return $false
}
