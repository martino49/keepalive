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
    return ''
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
        [string[]]$Blacklist = @(),
        [switch]$RespectFullscreen,
        [switch]$DryRun
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
            Blacklist         = @($Blacklist)
            RespectFullscreen = [bool]$RespectFullscreen
            DryRun            = [bool]$DryRun
        }
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
    if ($State.Cfg.PowerRequest) { Set-KAPowerAwake -Suppress:$State.Cfg.DryRun }
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
                if ($Cfg.PowerRequest) { Set-KAPowerAwake -Suppress:$Cfg.DryRun }
                $events += "ACTIVE started - $($Cfg.ActiveMinutes) min"
            }
        }
    } catch {
        $events += "engine error: $($_.Exception.Message)"
    }

    return @{ Events = $events }
}

# ---------------- single instance ----------------
function New-KAMutex {
    param([string]$Name = 'Global\KeepAlive.SingleInstance')
    $isNew = $false
    $script:KAMutex = New-Object System.Threading.Mutex($true, $Name, [ref]$isNew)
    return $script:KAMutex
}

function Test-KAAlreadyRunning {
    try {
        $createdNew = $false
        $m = New-Object System.Threading.Mutex($true, 'Global\KeepAlive.SingleInstance', [ref]$createdNew)
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
