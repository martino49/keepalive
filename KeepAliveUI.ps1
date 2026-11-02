# KeepAliveUI.ps1 - GUI for the keep-awake tool. Engine lives in
# KeepAliveEngine.ps1 (shared with the CLI).
#
#   ACTIVE  : key taps / mouse nudges / a Windows power request, guided by
#             real-idle detection, an app no-tap list and fullscreen awareness
#   REST    : zero input (no keyboard, no mouse, nothing)
#
# Settings persist to KeepAlive.settings.json next to this script.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

. (Join-Path $PSScriptRoot 'KeepAliveEngine.ps1')

# ---------------- palette ----------------
$C_BG      = [System.Drawing.Color]::FromArgb(24, 24, 27)
$C_FIELD   = [System.Drawing.Color]::FromArgb(39, 39, 42)
$C_TEXT    = [System.Drawing.Color]::FromArgb(250, 250, 250)
$C_MUTED   = [System.Drawing.Color]::FromArgb(161, 161, 170)
$C_FAINT   = [System.Drawing.Color]::FromArgb(113, 113, 122)
$C_ACCENT  = [System.Drawing.Color]::FromArgb(255, 0, 110)
$C_GREEN   = [System.Drawing.Color]::FromArgb(34, 197, 94)
$C_AMBER   = [System.Drawing.Color]::FromArgb(251, 191, 36)
$C_STOPPED = [System.Drawing.Color]::FromArgb(113, 113, 122)

# ---------------- single instance ----------------
if (Test-KAAlreadyRunning) {
    $focused = Show-KAExistingWindow 'KeepAlive'
    if ($focused) {
        [System.Windows.Forms.MessageBox]::Show('KeepAlive is already running - the existing window was focused.', 'KeepAlive') | Out-Null
    } else {
        [System.Windows.Forms.MessageBox]::Show('KeepAlive is already running (in the tray). Stop it first.', 'KeepAlive') | Out-Null
    }
    exit
}

# ---------------- settings persistence ----------------
$script:SettingsFile = Join-Path $PSScriptRoot 'KeepAlive.settings.json'

function Load-Settings {
    try {
        if (Test-Path $script:SettingsFile) {
            $j = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json
            return @{
                Key = "$($j.Key)"
                InputMode = "$($j.InputMode)"
                Interval = [double]$j.Interval
                Active = [double]$j.Active
                Rest = [double]$j.Rest
                IdleThreshold = [double]$j.IdleThreshold
                Blacklist = @($j.Blacklist)
                PowerRequest = [bool]$j.PowerRequest
                RespectFullscreen = [bool]$j.RespectFullscreen
                From = "$($j.From)"
                Until = "$($j.Until)"
                Days = @($j.Days)
                RunFor = "$($j.RunFor)"
                RunUntil = "$($j.RunUntil)"
                BatteryMode = "$($j.BatteryMode)"
            }
        }
    } catch {
        # corrupt or unreadable settings should never block startup
    }
    return @{
        Key = 'Shift'
        InputMode = 'key'
        Interval = 60
        Active = 60
        Rest = 2
        IdleThreshold = 0
        Blacklist = @()
        PowerRequest = $false
        RespectFullscreen = $false
        From = ''
        Until = ''
        Days = @()
        RunFor = ''
        RunUntil = ''
        BatteryMode = 'ignore'
    }
}

function Save-Settings {
    try {
        @{
            Key               = $cmbKey.SelectedItem.ToString()
            InputMode         = $cmbMode.SelectedItem.ToString()
            Interval          = $txtInterval.Text.Trim()
            Active            = $txtActive.Text.Trim()
            Rest              = $txtRest.Text.Trim()
            IdleThreshold     = $txtIdle.Text.Trim()
            Blacklist         = @($txtBlacklist.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            PowerRequest      = $chkPower.Checked
            RespectFullscreen = $chkFullscreen.Checked
            AutoStart         = $chkAutoStart.Checked
            From              = $txtFrom.Text.Trim()
            Until             = $txtUntil.Text.Trim()
            Days              = @($txtDays.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            RunFor            = $txtRunFor.Text.Trim()
            RunUntil          = $txtRunUntil.Text.Trim()
            BatteryMode       = $cmbBattery.SelectedItem.ToString()
        } | ConvertTo-Json | Set-Content -Path $script:SettingsFile -Encoding ASCII
    } catch {
        # persistence is a convenience, never a failure
    }
}

$saved = Load-Settings

function Write-Log([string]$Line) {
    $stamp = Get-Date -Format 'HH:mm:ss'
    $script:lstLog.Items.Insert(0, "$stamp  $Line")
    while ($script:lstLog.Items.Count -gt 6) { $script:lstLog.Items.RemoveAt(5) }
}

# ---------------- window ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'KeepAlive'
$form.Size = New-Object System.Drawing.Size(470, 800)
$form.MinimumSize = New-Object System.Drawing.Size(470, 800)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.AutoScaleMode = 'Dpi'
$form.BackColor = $C_BG
$form.ForeColor = $C_TEXT
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.Icon = [System.Drawing.SystemIcons]::Shield

# --- header ---
$hdr = New-Object System.Windows.Forms.Label
$hdr.Text = 'KeepAlive'
$hdr.Left = 22; $hdr.Top = 14; $hdr.Width = 200; $hdr.Height = 26
$hdr.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 13)
$hdr.ForeColor = $C_ACCENT
$hdr.Parent = $form

$hdrSub = New-Object System.Windows.Forms.Label
$hdrSub.Text = 'ACTIVE acts - REST does nothing. Set it once, walk away.'
$hdrSub.Left = 22; $hdrSub.Top = 40; $hdrSub.Width = 420; $hdrSub.Height = 18
$hdrSub.ForeColor = $C_MUTED
$hdrSub.Parent = $form

# --- settings group ---
$grpSettings = New-Object System.Windows.Forms.GroupBox
$grpSettings.Text = 'Settings'
$grpSettings.Left = 22; $grpSettings.Top = 68; $grpSettings.Width = 410; $grpSettings.Height = 352
$grpSettings.ForeColor = $C_MUTED
$grpSettings.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$grpSettings.Parent = $form

function Add-RowLabel {
    param($Parent, $Text, $Y, $X = 18, $Width = 120)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Left = $X; $l.Top = $Y; $l.Width = $Width; $l.Height = 18
    $l.ForeColor = $C_MUTED
    $l.Parent = $Parent
    return $l
}

function New-KATextBox {
    param($Parent, $X, $Y, $W = 120, $Value = '')
    $t = New-Object System.Windows.Forms.TextBox
    $t.Left = $X; $t.Top = $Y; $t.Width = $W; $t.Text = $Value
    $t.BackColor = $C_FIELD; $t.ForeColor = $C_TEXT; $t.BorderStyle = 'FixedSingle'
    $t.Parent = $Parent
    return $t
}

# row 1: key + mode
$cmbKey = New-Object System.Windows.Forms.ComboBox
$cmbKey.Left = 118; $cmbKey.Top = 24; $cmbKey.Width = 110
$cmbKey.DropDownStyle = 'DropDownList'
$cmbKey.Items.AddRange(@('Shift', 'Ctrl', 'Alt', 'ScrollLock'))
if ($script:KA_VK -and $script:KA_VK.ContainsKey($saved.Key)) { $cmbKey.SelectedItem = $saved.Key } else { $cmbKey.SelectedItem = 'Shift' }
$cmbKey.BackColor = $C_FIELD; $cmbKey.ForeColor = $C_TEXT; $cmbKey.FlatStyle = 'Flat'
$cmbKey.Parent = $grpSettings
Add-RowLabel $grpSettings 'Key' 27 18 60 | Out-Null

$cmbMode = New-Object System.Windows.Forms.ComboBox
$cmbMode.Left = 278; $cmbMode.Top = 24; $cmbMode.Width = 110
$cmbMode.DropDownStyle = 'DropDownList'
$cmbMode.Items.AddRange(@('key', 'mouse', 'power', 'none'))
$modeIndex = @('key', 'mouse', 'power', 'none').IndexOf($saved.InputMode)
$cmbMode.SelectedIndex = if ($modeIndex -ge 0) { $modeIndex } else { 0 }
$cmbMode.BackColor = $C_FIELD; $cmbMode.ForeColor = $C_TEXT; $cmbMode.FlatStyle = 'Flat'
$cmbMode.Parent = $grpSettings
Add-RowLabel $grpSettings 'Action' 27 250 26 | Out-Null

# row 2: interval + active
$txtInterval = New-KATextBox $grpSettings 118 58 110 ([int]$saved.Interval)
Add-RowLabel $grpSettings 'Seconds' 61 18 60 | Out-Null
$txtActive = New-KATextBox $grpSettings 278 58 110 $saved.Active
Add-RowLabel $grpSettings 'Active min (0 = no rest)' 61 232 46 | Out-Null

# row 3: rest + idle
$txtRest = New-KATextBox $grpSettings 118 92 110 $saved.Rest
Add-RowLabel $grpSettings 'Rest min' 95 18 60 | Out-Null
$txtIdle = New-KATextBox $grpSettings 278 92 110 ([int]$saved.IdleThreshold)
Add-RowLabel $grpSettings 'Idle sec (0 = off)' 95 232 46 | Out-Null

# row 4: blacklist + test
$txtBlacklist = New-KATextBox $grpSettings 118 126 270 ($saved.Blacklist -join ', ')
Add-RowLabel $grpSettings 'No-tap list' 129 18 60 | Out-Null

# row 5: schedule window (from / run-for)
$txtFrom = New-KATextBox $grpSettings 118 158 110 $saved.From
Add-RowLabel $grpSettings 'Sched from' 161 18 60 | Out-Null
$txtRunFor = New-KATextBox $grpSettings 278 158 110 $saved.RunFor
Add-RowLabel $grpSettings 'Run for' 161 232 46 | Out-Null

# row 6: schedule until / run until
$txtUntil = New-KATextBox $grpSettings 118 184 110 $saved.Until
Add-RowLabel $grpSettings 'Sched to' 187 18 60 | Out-Null
$txtRunUntil = New-KATextBox $grpSettings 278 184 110 $saved.RunUntil
Add-RowLabel $grpSettings 'Run until' 187 232 46 | Out-Null

# row 7: days / battery mode
$txtDays = New-KATextBox $grpSettings 118 210 110 ($saved.Days -join ', ')
Add-RowLabel $grpSettings 'Days' 213 18 60 | Out-Null
$cmbBattery = New-Object System.Windows.Forms.ComboBox
$cmbBattery.Left = 278; $cmbBattery.Top = 209; $cmbBattery.Width = 110
$cmbBattery.DropDownStyle = 'DropDownList'
$cmbBattery.Items.AddRange(@('ignore', 'require-ac', 'pause-on-battery'))
$battIndex = @('ignore', 'require-ac', 'pause-on-battery').IndexOf($saved.BatteryMode)
$cmbBattery.SelectedIndex = if ($battIndex -ge 0) { $battIndex } else { 0 }
$cmbBattery.BackColor = $C_FIELD; $cmbBattery.ForeColor = $C_TEXT; $cmbBattery.FlatStyle = 'Flat'
$cmbBattery.Parent = $grpSettings
Add-RowLabel $grpSettings 'Battery' 213 232 46 | Out-Null

$btnTest = New-Object System.Windows.Forms.Button
$btnTest.Left = 118; $btnTest.Top = 238; $btnTest.Width = 110; $btnTest.Height = 24
$btnTest.Text = 'Test key / mouse'
$btnTest.FlatStyle = 'Flat'; $btnTest.FlatAppearance.BorderSize = 0
$btnTest.BackColor = $C_FIELD; $btnTest.ForeColor = $C_MUTED
$btnTest.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$btnTest.Parent = $grpSettings

# row 5: checkboxes
$chkPower = New-Object System.Windows.Forms.CheckBox
$chkPower.Left = 118; $chkPower.Top = 262; $chkPower.Width = 150
$chkPower.Text = 'Windows power request'
$chkPower.ForeColor = $C_MUTED
$chkPower.Checked = [bool]$saved.PowerRequest
$chkPower.Parent = $grpSettings

$chkFullscreen = New-Object System.Windows.Forms.CheckBox
$chkFullscreen.Left = 278; $chkFullscreen.Top = 262; $chkFullscreen.Width = 130
$chkFullscreen.Text = 'Pause in fullscreen'
$chkFullscreen.ForeColor = $C_MUTED
$chkFullscreen.Checked = [bool]$saved.RespectFullscreen
$chkFullscreen.Parent = $grpSettings

$chkDryRun = New-Object System.Windows.Forms.CheckBox
$chkDryRun.Left = 118; $chkDryRun.Top = 284; $chkDryRun.Width = 150

$chkAutoStart = New-Object System.Windows.Forms.CheckBox
$chkAutoStart.Left = 278; $chkAutoStart.Top = 284; $chkAutoStart.Width = 130
$chkAutoStart.Text = 'Start with Windows'
$chkAutoStart.ForeColor = $C_MUTED
$chkAutoStart.Checked = (Test-KAAutoStartEnabled)
$chkAutoStart.Parent = $grpSettings
$chkDryRun.Text = 'Dry run (log only)'
$chkDryRun.ForeColor = $C_AMBER
$chkDryRun.Parent = $grpSettings

$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'Only acts after real idle; pauses for listed apps and fullscreen windows.' + [Environment]::NewLine + 'Dry run plans the schedule without touching anything.'
$hint.Left = 118; $hint.Top = 308; $hint.Width = 280; $hint.Height = 32
$hint.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$hint.ForeColor = $C_FAINT
$hint.Parent = $grpSettings

# --- status group ---
$grpStatus = New-Object System.Windows.Forms.GroupBox
$grpStatus.Text = 'Status'
$grpStatus.Left = 22; $grpStatus.Top = 436; $grpStatus.Width = 410; $grpStatus.Height = 212
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
$lblCdHint = New-Object System.Windows.Forms.Label
$lblCdHint.Left = 150; $lblCdHint.Top = 54; $lblCdHint.Width = 160
$lblCdHint.Text = 'left in phase'
$lblCdHint.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$lblCdHint.ForeColor = $C_FAINT
$lblCdHint.TextAlign = 'TopRight'
$lblCdHint.Parent = $grpStatus

$script:lblTaps = New-Object System.Windows.Forms.Label
$script:lblTaps.Left = 318; $script:lblTaps.Top = 26; $script:lblTaps.Width = 74; $script:lblTaps.Height = 30
$script:lblTaps.Text = '0'
$script:lblTaps.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 15)
$script:lblTaps.ForeColor = $C_TEXT
$script:lblTaps.TextAlign = 'MiddleRight'
$script:lblTaps.Parent = $grpStatus
$lblTapsHint = New-Object System.Windows.Forms.Label
$lblTapsHint.Left = 318; $lblTapsHint.Top = 54; $lblTapsHint.Width = 74
$lblTapsHint.Text = 'actions'
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

# dynamic tray icons, drawn at runtime (green ACTIVE / grey REST / red stopped)
function New-KADotIcon {
    param($Color)
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush($Color)
    $g.FillEllipse($brush, 1, 1, 14, 14)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(24, 24, 27))
    $g.DrawEllipse($pen, 1, 1, 14, 14)
    $g.Dispose()
    $handle = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($handle)
    $bmp.Dispose()
    return $icon
}
$script:IconActive = New-KADotIcon $C_GREEN
$script:IconRest = New-KADotIcon $C_FAINT
$script:IconStopped = New-KADotIcon $C_ACCENT
# tray icon is applied once the NotifyIcon exists (phase handlers below)

$script:lblSuppress = New-Object System.Windows.Forms.Label
$script:lblSuppress.Left = 18; $script:lblSuppress.Top = 120; $script:lblSuppress.Width = 374; $script:lblSuppress.Height = 18
$script:lblSuppress.Text = ''
$script:lblSuppress.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$script:lblSuppress.ForeColor = $C_AMBER
$script:lblSuppress.Parent = $grpStatus

$script:lstLog = New-Object System.Windows.Forms.ListBox
$script:lstLog.Left = 18; $script:lstLog.Top = 144; $script:lstLog.Width = 374; $script:lstLog.Height = 56
$script:lstLog.BorderStyle = 'None'
$script:lstLog.BackColor = $C_FIELD
$script:lstLog.ForeColor = $C_MUTED
$script:lstLog.Font = New-Object System.Drawing.Font('Consolas', 8)
$script:lstLog.ItemHeight = 11
$script:lstLog.Parent = $grpStatus
Write-Log 'Idle - not started.'

# --- buttons ---
$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Left = 22; $btnStart.Top = 660; $btnStart.Width = 120; $btnStart.Height = 40
$btnStart.Text = 'Start'
$btnStart.FlatStyle = 'Flat'; $btnStart.FlatAppearance.BorderSize = 0
$btnStart.BackColor = $C_ACCENT; $btnStart.ForeColor = [System.Drawing.Color]::White
$btnStart.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$btnStart.Parent = $form

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Left = 152; $btnStop.Top = 660; $btnStop.Width = 120; $btnStop.Height = 40
$btnStop.Text = 'Stop'
$btnStop.Enabled = $false
$btnStop.FlatStyle = 'Flat'; $btnStop.FlatAppearance.BorderSize = 0
$btnStop.BackColor = $C_FIELD; $btnStop.ForeColor = $C_TEXT
$btnStop.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$btnStop.Parent = $form

$btnHide = New-Object System.Windows.Forms.Button
$btnHide.Left = 282; $btnHide.Top = 660; $btnHide.Width = 150; $btnHide.Height = 40
$btnHide.Text = 'Hide to tray'
$btnHide.FlatStyle = 'Flat'; $btnHide.FlatAppearance.BorderSize = 0
$btnHide.BackColor = $C_FIELD; $btnHide.ForeColor = $C_TEXT
$btnHide.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$btnHide.Parent = $form

$lblFooter = New-Object System.Windows.Forms.Label
$lblFooter.Left = 22; $lblFooter.Top = 708; $lblFooter.Width = 410; $lblFooter.Height = 30
$lblFooter.Text = 'Closing the window keeps running in the tray. Exit from the tray icon or press Stop.'
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

# ---------------- engine + timer ----------------
$script:State = $null
$script:Mutex = $null

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 900

$timer.Add_Tick({
    if (-not $script:State) { return }
    $out = Invoke-KATick $script:State
    foreach ($ev in $out.Events) { Write-Log $ev }

    $remaining = ($script:State.PhaseEnd - (Get-Date)).TotalSeconds
    $script:lblCountdown.Text = (Format-KASpan $remaining)
    $script:lblTaps.Text = "$($script:State.PressCount)"

    $total = ($script:State.PhaseEnd - $script:State.PhaseStart).TotalSeconds
    $pct = 0
    if ($total -gt 0) { $pct = [int]((1 - ($remaining / $total)) * 100) }
    if ($pct -lt 0) { $pct = 0 }; if ($pct -gt 100) { $pct = 100 }
    try { $script:progress.Value = $pct } catch { }

    $uptime = if ($script:State.StartedAt) { Format-KASpan ((Get-Date) - $script:State.StartedAt).TotalSeconds } else { '00:00' }
    $script:lblSchedule.Text = "$($script:State.Cfg.InputMode) every $($script:State.Cfg.Interval)s  |  running $uptime"

    # live "why not acting" line, straight from the suppression rules
    $script:lblSuppress.Text = (Get-KASuppressionReason $script:State.Cfg)

    # diagnostics strip: what the engine is actually seeing
    $src = Get-KAPowerSource
    $idle = [int](Get-KAIdleSeconds)
    $fg = Get-KAForegroundProcess
    $fgText = if ($fg) { $fg } else { 'unknown' }
    $phaseClock = if ($script:State.PhaseEnd -gt (Get-Date)) { $script:State.PhaseEnd.ToString('HH:mm') } else { '--:--' }
    $script:lblSchedule.Text = "$($script:State.Cfg.InputMode) every $($script:State.Cfg.Interval)s  |  idle ${idle}s  |  app $fgText  |  power $src  |  phase ends $phaseClock"

    # tray tooltip mirrors the phase
    if ($script:State.Phase -eq 'ACTIVE') {
        $script:lblPhase.Text = 'ACTIVE'
        $script:lblPhase.ForeColor = $C_GREEN
        $tray.Icon = $script:IconActive
        $tray.Text = "KeepAlive - ACTIVE ($($script:State.PressCount) actions)"
    } elseif ($script:State.Phase -eq 'REST') {
        $script:lblPhase.Text = 'REST'
        $script:lblPhase.ForeColor = $C_FAINT
        $tray.Icon = $script:IconRest
        $tray.Text = 'KeepAlive - REST'
    } elseif ($script:State.Phase -eq 'SCHEDULED') {
        $script:lblPhase.Text = 'WAITING'
        $script:lblPhase.ForeColor = $C_AMBER
        $tray.Icon = $script:IconRest
        $tray.Text = 'KeepAlive - waiting for schedule window'
    }
})

# ---------------- actions ----------------
function Read-KAInputs {
    $interval = 0.0; $active = 0.0; $rest = 0.0; $idle = 0.0
    if (-not [double]::TryParse($txtInterval.Text, [ref]$interval) -or $interval -lt 1) {
        Warn 'Seconds between actions must be 1 or more.'; return $null
    }
    if (-not [double]::TryParse($txtActive.Text, [ref]$active) -or $active -lt 0) {
        Warn 'Active minutes must be 0 (never rest) or positive.'; return $null
    }
    if (-not [double]::TryParse($txtRest.Text, [ref]$rest) -or $rest -lt 0) {
        Warn 'Rest minutes must be 0 or positive.'; return $null
    }
    if ($active -gt 0 -and $rest -le 0) {
        Warn 'With an active timer, rest minutes must be at least 0.5.' + [Environment]::NewLine + 'Use 0 active minutes for never-rest.'; return $null
    }
    if (-not [double]::TryParse($txtIdle.Text, [ref]$idle) -or $idle -lt 0) {
        Warn 'Idle seconds must be 0 or positive.'; return $null
    }
    $mode = $cmbMode.SelectedItem.ToString()
    if ($mode -eq 'none' -and -not $chkPower.Checked) {
        Warn 'Action "none" without the power request does nothing.'; return $null
    }
    $from = $txtFrom.Text.Trim(); $until = $txtUntil.Text.Trim()
    if ($from -or $until) {
        if (-not $from -or -not $until) {
            Warn 'Schedule needs both a from and a to time.'; return $null
        }
        if ($from -notmatch '^\d{1,2}:\d{2}$' -or $until -notmatch '^\d{1,2}:\d{2}$') {
            Warn 'Schedule times must be HH:mm.'; return $null
        }
    }
    $runFor = $txtRunFor.Text.Trim(); $runUntil = $txtRunUntil.Text.Trim()
    if ($runFor -and (Convert-KADuration $runFor) -le 0) {
        Warn 'Run for must look like 1h30m or 90m.'; return $null
    }
    if ($runUntil -and $runUntil -notmatch '^\d{1,2}:\d{2}$') {
        Warn 'Run until must be HH:mm.'; return $null
    }
    $days = @($txtDays.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($d in $days) {
        if ($d.Substring(0, [Math]::Min(3, $d.Length)).ToLower() -notin @('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun')) {
            Warn "Day '$d' must be mon..sun."; return $null
        }
    }
    return @{
        Interval = $interval; Active = $active; Rest = $rest; IdleThreshold = $idle
        Key = $cmbKey.SelectedItem.ToString()
        InputMode = $mode
        Blacklist = @($txtBlacklist.Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        PowerRequest = $chkPower.Checked
        RespectFullscreen = $chkFullscreen.Checked
        From = $from; Until = $until; Days = $days
        RunFor = $runFor; RunUntil = $runUntil
        BatteryMode = $cmbBattery.SelectedItem.ToString()
    }
}

function Warn([string]$Message) {
    [System.Windows.Forms.MessageBox]::Show($Message, 'KeepAlive', 'OK', 'Warning') | Out-Null
}

function Start-KeepAlive {
    $cfg = Read-KAInputs
    if (-not $cfg) { return }

    $script:State = Initialize-KAEngine `
        -Key $cfg.Key `
        -Interval $cfg.Interval `
        -ActiveMinutes $cfg.Active `
        -RestMinutes $cfg.Rest `
        -InputMode $cfg.InputMode `
        -PowerRequest:$cfg.PowerRequest `
        -IdleThreshold $cfg.IdleThreshold `
        -BlackList $cfg.Blacklist `
        -RespectFullscreen:$cfg.RespectFullscreen `
        -DryRun:$chkDryRun.Checked `
        -From $cfg.From `
        -Until $cfg.Until `
        -Days $cfg.Days `
        -RunFor $cfg.RunFor `
        -RunUntil $cfg.RunUntil `
        -BatteryMode $cfg.BatteryMode

    if (-not $chkDryRun.Checked) {
        $script:Mutex = New-KAMutex
        $null = Register-KASessionEvents
    }

    Start-KACycle $script:State
    Write-Log "ACTIVE started - $($cfg.InputMode) every $($cfg.Interval)s, active $($cfg.Active) min$(if ($cfg.Active -le 0) { ' (never rest)' } else { ', rest ' + $cfg.Rest + ' min' })"
    if ($cfg.PowerRequest) { Write-Log 'Power request claimed' }
    if ($cfg.IdleThreshold -gt 0) { Write-Log "Only acts after $($cfg.IdleThreshold)s idle" }
    if ($cfg.Blacklist.Count) { Write-Log "No-tap list: $($cfg.Blacklist -join ', ')" }
    if ($cfg.From -and $cfg.Until) { Write-Log "Schedule $($cfg.From)-$($cfg.Until)$(if ($cfg.Days.Count) { " on $($cfg.Days -join ', ')" })" }
    if ($script:State.StopAt) { Write-Log "Run window ends $($script:State.StopAt.ToString('HH:mm'))" }
    if ($cfg.BatteryMode -ne 'ignore') { Write-Log "Battery mode $($cfg.BatteryMode)" }
    if ($chkDryRun.Checked) { Write-Log 'DRY RUN - nothing is pressed or claimed' }

    $btnStart.Enabled = $false
    $btnStop.Enabled = $true
    $btnTest.Enabled = $false

    # reflect the auto-start choice immediately (Windows startup shortcut)
    $wantAuto = $chkAutoStart.Checked
    $haveAuto = Test-KAAutoStartEnabled
    if ($wantAuto -and -not $haveAuto) {
        if (Enable-KAAutoStart) { Write-Log 'Added to Windows startup' } else { Warn 'Could not create the startup shortcut.' }
    } elseif (-not $wantAuto -and $haveAuto) {
        if (Disable-KAAutoStart) { Write-Log 'Removed from Windows startup' }
    }
    foreach ($c in @($cmbKey, $cmbMode, $txtInterval, $txtActive, $txtRest, $txtIdle, $txtBlacklist, $txtFrom, $txtUntil, $txtDays, $txtRunFor, $txtRunUntil, $cmbBattery)) { $c.Enabled = $false }
    Save-Settings
    $tray.Text = 'KeepAlive - ACTIVE'
    $timer.Start()
}

function Stop-KeepAlive {
    if ($script:State) { Stop-KACycle $script:State }
    if ($script:Mutex) { $script:Mutex.Dispose(); $script:Mutex = $null }
    $timer.Stop()

    $script:lblPhase.Text = 'STOPPED'
    $script:lblPhase.ForeColor = $C_STOPPED
    $script:lblCountdown.Text = '--:--'
    $script:progress.Value = 0
    $script:lblSuppress.Text = ''
    $script:lblSchedule.Text = 'Configure above, then press Start.'
    if ($script:State) { Write-Log "Stopped - $($script:State.PressCount) actions total." }

    $btnStart.Enabled = $true
    $btnStop.Enabled = $false
    $btnTest.Enabled = $true
    foreach ($c in @($cmbKey, $cmbMode, $txtInterval, $txtActive, $txtRest, $txtIdle, $txtBlacklist, $txtFrom, $txtUntil, $txtDays, $txtRunFor, $txtRunUntil, $cmbBattery)) { $c.Enabled = $true }
    $tray.Text = 'KeepAlive - stopped'
    $tray.Icon = $script:IconStopped
    $script:State = $null
}

# ---- first-run onboarding: shown once, AFTER the main window (a modal box
# here would block ShowDialog and the user would never see the app at all) ----
$script:OnboardMarker = Join-Path $PSScriptRoot '.onboarded'
$form.Add_Shown({
    if (Test-Path $script:OnboardMarker) { return }
    # unattended starts (Windows startup) must never block on a modal
    if ($env:KEEPALIVE_NO_ONBOARDING) { return }
    try {
        $intro = 'ACTIVE presses a key (or nudges the mouse) on a timer so your PC never sleeps. REST is a genuine idle window: no keyboard, no mouse, nothing.' +
            [Environment]::NewLine + [Environment]::NewLine +
            'You choose the key, the cadence and the ACTIVE/REST lengths, or set a schedule window. A lone Shift press does not register as input in any app, so nothing you are working on is disturbed. Closing this window keeps it running in the tray.'
        [void][System.Windows.Forms.MessageBox]::Show($intro, 'Welcome to KeepAlive', 'OK', 'Information')
        Set-Content -Path $script:OnboardMarker -Value 'onboarded' -Encoding ASCII
    } catch {
        # onboarding must never break the window
    }
})

$btnStart.Add_Click({ Start-KeepAlive })
$btnStop.Add_Click({ Stop-KeepAlive })
$trayToggle.Add_Click({ if ($script:State) { Stop-KeepAlive } else { Start-KeepAlive } })

$btnTest.Add_Click({
    if ($cmbMode.SelectedItem.ToString() -eq 'mouse') {
        Invoke-KAMouseNudge
        Write-Log 'Test action: mouse nudge'
    } else {
        Invoke-KAKeyTap -Key $cmbKey.SelectedItem.ToString()
        Write-Log "Test action: pressed $($cmbKey.SelectedItem)"
    }
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
    if ($script:State) {
        $e.Cancel = $true
        $form.WindowState = 'Minimized'
        $form.ShowInTaskbar = $false
        $tray.Visible = $true
        $tray.ShowBalloonTip(3000, 'KeepAlive', 'Still running in the tray. Right-click the icon to exit.', 'Info')
    } else {
        if ($script:Mutex) { $script:Mutex.Dispose(); $script:Mutex = $null }
        $tray.Visible = $false
    }
})

[void]$form.ShowDialog()
if ($script:Mutex) { $script:Mutex.Dispose(); $script:Mutex = $null }
$timer.Stop()
