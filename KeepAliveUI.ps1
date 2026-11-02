# KeepAliveUI.ps1 - GUI for the keep-awake tool.
# One command (KeepAlive.bat) opens this window; everything else (key choice,
# timing, the ACTIVE/REST cycle, tray, settings memory) is driven from the UI.
#
#   ACTIVE  : presses the chosen key every N seconds
#   REST    : zero input (no keyboard, no mouse, nothing)
#   cycles  : ACTIVE -> REST -> ACTIVE ... until you stop it (or exit)
#
# Settings persist to KeepAlive.settings.json next to this script.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -MemberDefinition @'
[DllImport("user32.dll")]
public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, int dwExtraInfo);
'@ -Name "K" -Namespace "Win32"

# ---------------- palette ----------------
$C_BG      = [System.Drawing.Color]::FromArgb(24, 24, 27)
$C_PANEL   = [System.Drawing.Color]::FromArgb(32, 32, 36)
$C_FIELD   = [System.Drawing.Color]::FromArgb(39, 39, 42)
$C_TEXT    = [System.Drawing.Color]::FromArgb(250, 250, 250)
$C_MUTED   = [System.Drawing.Color]::FromArgb(161, 161, 170)
$C_FAINT   = [System.Drawing.Color]::FromArgb(113, 113, 122)
$C_ACCENT  = [System.Drawing.Color]::FromArgb(255, 0, 110)
$C_GREEN   = [System.Drawing.Color]::FromArgb(34, 197, 94)
$C_AMBER   = [System.Drawing.Color]::FromArgb(251, 191, 36)
$C_STOPPED = [System.Drawing.Color]::FromArgb(113, 113, 122)

# ---------------- state ----------------
$script:Running = $false
$script:Phase = 'STOPPED'
$script:PhaseEnd = (Get-Date)
$script:LastPress = $null
$script:PressCount = 0
$script:NeverRest = $false
$script:StartedAt = $null
$script:Cfg = $null

$VK = @{ Shift = 0x10; Ctrl = 0x11; Alt = 0x12; ScrollLock = 0x91 }

function Get-KeyCode([string]$name) {
    if ($VK.ContainsKey($name)) { return $VK[$name] }
    return 0x10
}

function Format-Span([double]$Seconds) {
    if ($Seconds -lt 0) { $Seconds = 0 }
    $ts = [TimeSpan]::FromSeconds($Seconds)
    if ($ts.TotalHours -ge 1) { return '{0:hh\:mm\:ss}' -f $ts }
    return '{0:mm\:ss}' -f $ts
}

function Write-Log([string]$Line) {
    $stamp = Get-Date -Format 'HH:mm:ss'
    $script:lstLog.Items.Insert(0, "$stamp  $Line")
    while ($script:lstLog.Items.Count -gt 6) { $script:lstLog.Items.RemoveAt(5) }
}

# ---------------- settings persistence ----------------
$script:SettingsFile = Join-Path $PSScriptRoot 'KeepAlive.settings.json'

function Load-Settings {
    try {
        if (Test-Path $script:SettingsFile) {
            $j = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json
            return @{
                Key = "$($j.Key)"
                Interval = [double]$j.Interval
                Active = [double]$j.Active
                Rest = [double]$j.Rest
            }
        }
    } catch {
        # corrupt or unreadable settings should never block startup
    }
    return @{ Key = 'Shift'; Interval = 60; Active = 60; Rest = 2 }
}

function Save-Settings {
    param($Key, $Interval, $Active, $Rest)
    try {
        @{ Key = $Key; Interval = $Interval; Active = $Active; Rest = $Rest } |
            ConvertTo-Json |
            Set-Content -Path $script:SettingsFile -Encoding ASCII
    } catch {
        # persistence is a convenience, never a failure
    }
}

# ---------------- window ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'KeepAlive'
$form.Size = New-Object System.Drawing.Size(470, 520)
$form.MinimumSize = New-Object System.Drawing.Size(470, 520)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.AutoScaleMode = 'Dpi'
$form.BackColor = $C_BG
$form.ForeColor = $C_TEXT
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.Icon = [System.Drawing.SystemIcons]::Shield

$saved = Load-Settings

# --- header ---
$hdr = New-Object System.Windows.Forms.Label
$hdr.Text = 'KeepAlive'
$hdr.Left = 22; $hdr.Top = 14; $hdr.Width = 200; $hdr.Height = 26
$hdr.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 13)
$hdr.ForeColor = $C_ACCENT
$hdr.Parent = $form

$hdrSub = New-Object System.Windows.Forms.Label
$hdrSub.Text = 'ACTIVE presses a key - REST does nothing. Set it once, walk away.'
$hdrSub.Left = 22; $hdrSub.Top = 40; $hdrSub.Width = 410; $hdrSub.Height = 18
$hdrSub.ForeColor = $C_MUTED
$hdrSub.Parent = $form

# --- settings group ---
$grpSettings = New-Object System.Windows.Forms.GroupBox
$grpSettings.Text = 'Settings'
$grpSettings.Left = 22; $grpSettings.Top = 68; $grpSettings.Width = 410; $grpSettings.Height = 172
$grpSettings.ForeColor = $C_MUTED
$grpSettings.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$grpSettings.Parent = $form

function Add-RowLabel {
    param($Parent, $Text, $Y, $X = 18, $Width = 150)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Left = $X; $l.Top = $Y; $l.Width = $Width; $l.Height = 18
    $l.ForeColor = $C_MUTED
    $l.Parent = $Parent
    return $l
}

$cmbKey = New-Object System.Windows.Forms.ComboBox
$cmbKey.Left = 250; $cmbKey.Top = 24; $cmbKey.Width = 130
$cmbKey.DropDownStyle = 'DropDownList'
$cmbKey.Items.AddRange(@('Shift', 'Ctrl', 'Alt', 'ScrollLock'))
if ($VK.ContainsKey($saved.Key)) { $cmbKey.SelectedItem = $saved.Key } else { $cmbKey.SelectedItem = 'Shift' }
$cmbKey.BackColor = $C_FIELD; $cmbKey.ForeColor = $C_TEXT
$cmbKey.FlatStyle = 'Flat'
$cmbKey.Parent = $grpSettings
Add-RowLabel $grpSettings 'Key to press' 27 | Out-Null

$txtInterval = New-Object System.Windows.Forms.TextBox
$txtInterval.Left = 250; $txtInterval.Top = 58; $txtInterval.Width = 130
$txtInterval.Text = [int]$saved.Interval
$txtInterval.BackColor = $C_FIELD; $txtInterval.ForeColor = $C_TEXT; $txtInterval.BorderStyle = 'FixedSingle'
$txtInterval.Parent = $grpSettings
Add-RowLabel $grpSettings 'Seconds between presses' 61 | Out-Null

$txtActive = New-Object System.Windows.Forms.TextBox
$txtActive.Left = 250; $txtActive.Top = 92; $txtActive.Width = 130
$txtActive.Text = $saved.Active
$txtActive.BackColor = $C_FIELD; $txtActive.ForeColor = $C_TEXT; $txtActive.BorderStyle = 'FixedSingle'
$txtActive.Parent = $grpSettings
Add-RowLabel $grpSettings 'Active minutes  (0 = never rest)' 95 | Out-Null

$txtRest = New-Object System.Windows.Forms.TextBox
$txtRest.Left = 250; $txtRest.Top = 126; $txtRest.Width = 130
$txtRest.Text = $saved.Rest
$txtRest.BackColor = $C_FIELD; $txtRest.ForeColor = $C_TEXT; $txtRest.BorderStyle = 'FixedSingle'
$txtRest.Parent = $grpSettings
Add-RowLabel $grpSettings 'Rest minutes  (0 = skip rest)' 129 | Out-Null

$btnTest = New-Object System.Windows.Forms.Button
$btnTest.Left = 18; $btnTest.Top = 126; $btnTest.Width = 110; $btnTest.Height = 26
$btnTest.Text = 'Test key'
$btnTest.FlatStyle = 'Flat'
$btnTest.BackColor = $C_FIELD
$btnTest.ForeColor = $C_MUTED
$btnTest.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$btnTest.Parent = $grpSettings
$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'presses it once so you can see it is safe to use'
$hint.Left = 134; $hint.Top = 130; $hint.Width = 220; $hint.Height = 18
$hint.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$hint.ForeColor = $C_FAINT
$hint.Parent = $grpSettings

# --- status group ---
$grpStatus = New-Object System.Windows.Forms.GroupBox
$grpStatus.Text = 'Status'
$grpStatus.Left = 22; $grpStatus.Top = 250; $grpStatus.Width = 410; $grpStatus.Height = 212
$grpStatus.ForeColor = $C_MUTED
$grpStatus.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$grpStatus.Parent = $form

$script:lblPhase = New-Object System.Windows.Forms.Label
$script:lblPhase.Left = 18; $script:lblPhase.Top = 24; $script:lblPhase.Width = 130; $script:lblPhase.Height = 34
$script:lblPhase.Text = 'STOPPED'
$script:lblPhase.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
$script:lblPhase.ForeColor = $C_STOPPED
$script:lblPhase.Parent = $grpStatus

$script:lblCountdown = New-Object System.Windows.Forms.Label
$script:lblCountdown.Left = 150; $script:lblCountdown.Top = 26; $script:lblCountdown.Width = 160; $script:lblCountdown.Height = 30
$script:lblCountdown.Text = '--:--'
$script:lblCountdown.Font = New-Object System.Drawing.Font('Consolas', 15)
$script:lblCountdown.ForeColor = $C_TEXT
$script:lblCountdown.TextAlign = 'MiddleRight'
$script:lblCountdown.Parent = $grpStatus
$lblCountdownHint = New-Object System.Windows.Forms.Label
$lblCountdownHint.Left = 150; $lblCountdownHint.Top = 54; $lblCountdownHint.Width = 160
$lblCountdownHint.Text = 'left in phase'
$lblCountdownHint.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$lblCountdownHint.ForeColor = $C_FAINT
$lblCountdownHint.TextAlign = 'TopRight'
$lblCountdownHint.Parent = $grpStatus

$script:lblTaps = New-Object System.Windows.Forms.Label
$script:lblTaps.Left = 318; $script:lblTaps.Top = 26; $script:lblTaps.Width = 72; $script:lblTaps.Height = 30
$script:lblTaps.Text = '0'
$script:lblTaps.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 15)
$script:lblTaps.ForeColor = $C_TEXT
$script:lblTaps.TextAlign = 'MiddleRight'
$script:lblTaps.Parent = $grpStatus
$lblTapsHint = New-Object System.Windows.Forms.Label
$lblTapsHint.Left = 318; $lblTapsHint.Top = 54; $lblTapsHint.Width = 72
$lblTapsHint.Text = 'key taps'
$lblTapsHint.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$lblTapsHint.ForeColor = $C_FAINT
$lblTapsHint.TextAlign = 'TopRight'
$lblTapsHint.Parent = $grpStatus

$script:progress = New-Object System.Windows.Forms.ProgressBar
$script:progress.Left = 18; $script:progress.Top = 92; $script:progress.Width = 374; $script:progress.Height = 5
$script:progress.Style = 'Continuous'
$script:progress.Parent = $grpStatus

$script:lblSchedule = New-Object System.Windows.Forms.Label
$script:lblSchedule.Left = 18; $script:lblSchedule.Top = 104; $script:lblSchedule.Width = 374; $script:lblSchedule.Height = 18
$script:lblSchedule.Text = 'Configure above, then press Start.'
$script:lblSchedule.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$script:lblSchedule.ForeColor = $C_FAINT
$script:lblSchedule.Parent = $grpStatus

$script:lstLog = New-Object System.Windows.Forms.ListBox
$script:lstLog.Left = 18; $script:lstLog.Top = 128; $script:lstLog.Width = 374; $script:lstLog.Height = 66
$script:lstLog.BorderStyle = 'None'
$script:lstLog.BackColor = $C_FIELD
$script:lstLog.ForeColor = $C_MUTED
$script:lstLog.Font = New-Object System.Drawing.Font('Consolas', 8)
$script:lstLog.ItemHeight = 11
$script:lstLog.Parent = $grpStatus
Write-Log 'Idle - not started.'

# --- buttons ---
$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Left = 22; $btnStart.Top = 474; $btnStart.Width = 120; $btnStart.Height = 40
$btnStart.Text = 'Start'
$btnStart.FlatStyle = 'Flat'; $btnStart.FlatAppearance.BorderSize = 0
$btnStart.BackColor = $C_ACCENT; $btnStart.ForeColor = [System.Drawing.Color]::White
$btnStart.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$btnStart.Parent = $form

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Left = 152; $btnStop.Top = 474; $btnStop.Width = 120; $btnStop.Height = 40
$btnStop.Text = 'Stop'
$btnStop.Enabled = $false
$btnStop.FlatStyle = 'Flat'; $btnStop.FlatAppearance.BorderSize = 0
$btnStop.BackColor = $C_FIELD; $btnStop.ForeColor = $C_TEXT
$btnStop.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$btnStop.Parent = $form

$btnHide = New-Object System.Windows.Forms.Button
$btnHide.Left = 282; $btnHide.Top = 474; $btnHide.Width = 150; $btnHide.Height = 40
$btnHide.Text = 'Hide to tray'
$btnHide.FlatStyle = 'Flat'; $btnHide.FlatAppearance.BorderSize = 0
$btnHide.BackColor = $C_FIELD; $btnHide.ForeColor = $C_TEXT
$btnHide.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$btnHide.Parent = $form

$lblFooter = New-Object System.Windows.Forms.Label
$lblFooter.Left = 22; $lblFooter.Top = 522; $lblFooter.Width = 410; $lblFooter.Height = 30
$lblFooter.Text = 'Closing the window keeps running in the tray.' + [Environment]::NewLine + 'Exit from the tray icon or press Stop.'
$lblFooter.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$lblFooter.ForeColor = $C_FAINT
$lblFooter.Parent = $form

# ---------------- tray ----------------
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.SystemIcons]::Shield
$tray.Visible = $false
$tray.Text = 'KeepAlive - stopped'

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$trayShow = $trayMenu.Items.Add('Show window')
$trayToggle = $trayMenu.Items.Add('Start / Stop')
$trayMenu.Items.Add('-') | Out-Null
$trayExit = $trayMenu.Items.Add('Exit')
$tray.ContextMenuStrip = $trayMenu

# ---------------- engine ----------------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000

$timer.Add_Tick({
    if (-not $script:Running) { return }

    $now = Get-Date
    $remaining = ($script:PhaseEnd - $now).TotalSeconds

    if ($script:Phase -eq 'ACTIVE') {
        $interval = [double]$script:Cfg.Interval
        if ($interval -lt 1) { $interval = 1 }
        if (-not $script:LastPress -or ($now - $script:LastPress).TotalSeconds -ge $interval) {
            $vk = Get-KeyCode $script:Cfg.Key
            [Win32.K]::keybd_event($vk, 0, 0, 0)
            [Win32.K]::keybd_event($vk, 0, 2, 0)
            $script:LastPress = $now
            $script:PressCount++
            $tray.Text = "KeepAlive - ACTIVE ($($script:PressCount) taps)"
        }
        if ($remaining -le 0) {
            if ($script:NeverRest) {
                $script:PhaseEnd = $now.AddMinutes([double]::Max(1, [double]$script:Cfg.Active))
            } else {
                $script:Phase = 'REST'
                $script:PhaseEnd = $now.AddMinutes([double]$script:Cfg.Rest)
                $script:LastPress = $null
                $script:lblPhase.Text = 'REST'
                $script:lblPhase.ForeColor = $C_FAINT
                Write-Log "REST started ($($script:Cfg.Rest) min - no input)"
            }
        }
    }
    elseif ($script:Phase -eq 'REST') {
        if ($remaining -le 0) {
            $script:Phase = 'ACTIVE'
            $script:PhaseEnd = $now.AddMinutes([double]$script:Cfg.Active)
            $script:lblPhase.Text = 'ACTIVE'
            $script:lblPhase.ForeColor = $C_GREEN
            Write-Log "ACTIVE started ($($script:Cfg.Active) min)"
        }
    }

    if ($script:Running) {
        $script:lblCountdown.Text = (Format-Span $remaining)
        $script:lblTaps.Text = "$($script:PressCount)"
        $total = ($script:PhaseEnd - $script:CfgPhaseStart).TotalSeconds
        $pct = 0
        if ($total -gt 0) { $pct = [int]((1 - ($remaining / $total)) * 100) }
        if ($pct -lt 0) { $pct = 0 }; if ($pct -gt 100) { $pct = 100 }
        try { $script:progress.Value = $pct } catch { }
        $uptime = if ($script:StartedAt) { Format-Span ((Get-Date) - $script:StartedAt).TotalSeconds } else { '00:00' }
        $script:lblSchedule.Text = "Key $($script:Cfg.Key) every $($script:Cfg.Interval)s  |  running $uptime"
    }
})

# ---------------- actions ----------------
function Start-KeepAlive {
    $interval = 0; $active = 0; $rest = 0
    if (-not [double]::TryParse($txtInterval.Text, [ref]$interval) -or $interval -lt 1) {
        [System.Windows.Forms.MessageBox]::Show('Seconds between presses must be 1 or more.', 'KeepAlive', 'OK', 'Warning') | Out-Null
        return
    }
    if (-not [double]::TryParse($txtActive.Text, [ref]$active) -or $active -lt 0) {
        [System.Windows.Forms.MessageBox]::Show('Active minutes must be 0 (never rest) or a positive number.', 'KeepAlive', 'OK', 'Warning') | Out-Null
        return
    }
    if (-not [double]::TryParse($txtRest.Text, [ref]$rest) -or $rest -lt 0) {
        [System.Windows.Forms.MessageBox]::Show('Rest minutes must be 0 or a positive number.', 'KeepAlive', 'OK', 'Warning') | Out-Null
        return
    }
    if ($active -gt 0 -and $rest -le 0) {
        [System.Windows.Forms.MessageBox]::Show('With an active timer set, rest minutes must be at least 0.5.' + [Environment]::NewLine + 'Use 0 active minutes for the never-rest mode.', 'KeepAlive', 'OK', 'Warning') | Out-Null
        return
    }

    $script:Cfg = @{ Interval = $interval; Active = $active; Rest = $rest; Key = $cmbKey.SelectedItem.ToString() }
    $script:NeverRest = ($active -le 0)
    $script:Running = $true
    $script:Phase = 'ACTIVE'
    $script:CfgPhaseStart = Get-Date
    $script:PhaseEnd = (Get-Date).AddMinutes([double]::Max(0.016, $active))
    $script:LastPress = $null
    $script:PressCount = 0
    $script:StartedAt = Get-Date

    $script:lblPhase.Text = 'ACTIVE'
    $script:lblPhase.ForeColor = $C_GREEN
    $btnStart.Enabled = $false
    $btnStop.Enabled = $true
    foreach ($c in @($cmbKey, $txtInterval, $txtActive, $txtRest)) { $c.Enabled = $false }
    $tray.Text = 'KeepAlive - ACTIVE'
    Save-Settings -Key $script:Cfg.Key -Interval $interval -Active $active -Rest $rest
    Write-Log "ACTIVE started - $($script:Cfg.Key) every $($interval)s, active $active min$(if ($script:NeverRest) { ' (never rest)' } else { ", rest $rest min" })"
    $timer.Start()
}

function Stop-KeepAlive {
    $script:Running = $false
    $script:Phase = 'STOPPED'
    $timer.Stop()
    $script:lblPhase.Text = 'STOPPED'
    $script:lblPhase.ForeColor = $C_STOPPED
    $script:lblCountdown.Text = '--:--'
    $script:progress.Value = 0
    $script:lblSchedule.Text = 'Configure above, then press Start.'
    $btnStart.Enabled = $true
    $btnStop.Enabled = $false
    foreach ($c in @($cmbKey, $txtInterval, $txtActive, $txtRest)) { $c.Enabled = $true }
    $tray.Text = 'KeepAlive - stopped'
    Write-Log "Stopped - $($script:PressCount) taps total."
}

$btnStart.Add_Click({ Start-KeepAlive })
$btnStop.Add_Click({ Stop-KeepAlive })
$trayToggle.Add_Click({ if ($script:Running) { Stop-KeepAlive } else { Start-KeepAlive } })

$btnTest.Add_Click({
    $vk = Get-KeyCode $cmbKey.SelectedItem.ToString()
    [Win32.K]::keybd_event($vk, 0, 0, 0)
    [Win32.K]::keybd_event($vk, 0, 2, 0)
    Write-Log "Test press: $($cmbKey.SelectedItem)"
})

$btnHide.Add_Click({
    $form.WindowState = 'Minimized'
    $form.ShowInTaskbar = $false
    $tray.Visible = $true
})

$trayShow.Add_Click({
    $form.ShowInTaskbar = $true
    $form.WindowState = 'Normal'
    $tray.Visible = $false
})
$tray.Add_MouseDoubleClick({ $trayShow.PerformClick() })

$trayExit.Add_Click({
    Stop-KeepAlive
    $tray.Visible = $false
    $form.Close()
})

$form.Add_FormClosing({
    param($sender, $e)
    if ($script:Running) {
        $e.Cancel = $true
        $form.WindowState = 'Minimized'
        $form.ShowInTaskbar = $false
        $tray.Visible = $true
        $tray.ShowBalloonTip(3000, 'KeepAlive', 'Still running in the tray. Right-click the icon to exit.', 'Info')
    } else {
        $tray.Visible = $false
    }
})

[void]$form.ShowDialog()
$timer.Stop()
