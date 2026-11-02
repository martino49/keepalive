# KeepAliveUI.ps1 - GUI for the keep-awake tool.
# One command (KeepAlive.bat) opens this window; everything else (key choice,
# timing, the ACTIVE/REST cycle, tray minimising) is driven from the UI.
#
#   ACTIVE  : presses the chosen key every N seconds
#   REST    : zero input (no keyboard, no mouse, nothing)
#   cycles  : ACTIVE -> REST -> ACTIVE ... until you stop it (or exit)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -MemberDefinition @'
[DllImport("user32.dll")]
public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, int dwExtraInfo);
'@ -Name "K" -Namespace "Win32"
# ---------------- state ----------------
$script:Running = $false
$script:Phase = 'STOPPED'
$script:PhaseEnd = (Get-Date)
$script:LastPress = $null
$script:PressCount = 0
$script:NeverRest = $false
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
function Set-Status {
    param($Text, $Color = 'Gray')
    $script:lblStatus.Text = $Text
    $script:lblStatus.ForeColor = $Color
}
# ---------------- window ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'KeepAlive'
$form.Size = New-Object System.Drawing.Size(430, 470)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 27)
$form.ForeColor = [System.Drawing.Color]::White
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
function Add-Label {
    param($Parent, $Text, $X, $Y, $Width = 120)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Left = $X; $l.Top = $Y; $l.Width = $Width; $l.Height = 18
    $l.ForeColor = [System.Drawing.Color]::FromArgb(212, 212, 216)
    $l.Parent = $Parent
    return $l
}
function Add-Input {
    param($Parent, $X, $Y, $Width = 140, $Default)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Left = $X; $t.Top = $Y; $t.Width = $Width; $t.Text = $Default
    $t.BackColor = [System.Drawing.Color]::FromArgb(39, 39, 42)
    $t.ForeColor = [System.Drawing.Color]::White
    $t.BorderStyle = 'FixedSingle'
    $t.Parent = $Parent
    return $t
}
$hdr = New-Object System.Windows.Forms.Label
$hdr.Text = 'Keep your PC awake - set it once, walk away.'
$hdr.Left = 20; $hdr.Top = 12; $hdr.Width = 380; $hdr.Height = 20
$hdr.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$hdr.ForeColor = [System.Drawing.Color]::FromArgb(255, 0, 110)
$hdr.Parent = $form
Add-Label $form 'Key to press' 20 50 | Out-Null
$cmbKey = New-Object System.Windows.Forms.ComboBox
$cmbKey.Left = 145; $cmbKey.Top = 46; $cmbKey.Width = 140
$cmbKey.DropDownStyle = 'DropDownList'
$cmbKey.Items.AddRange(@('Shift', 'Ctrl', 'Alt', 'ScrollLock'))
$cmbKey.SelectedItem = 'Shift'
$cmbKey.BackColor = [System.Drawing.Color]::FromArgb(39, 39, 42)
$cmbKey.ForeColor = [System.Drawing.Color]::White
$cmbKey.Parent = $form
Add-Label $form 'Seconds between presses' 20 82 | Out-Null
$txtInterval = Add-Input $form 145 78 140 60
Add-Label $form 'Active minutes (0 = never rest)' 20 114 | Out-Null
$txtActive = Add-Input $form 145 110 140 60
Add-Label $form 'Rest minutes (0 = skip rest)' 20 146 | Out-Null
$txtRest = Add-Input $form 145 142 140 2
Add-Label $form 'During REST there is no keyboard, mouse or anything.' 20 176 300 | Out-Null
# ---- live status ----
$script:lblStatus = New-Object System.Windows.Forms.Label
$script:lblStatus.Left = 20; $script:lblStatus.Top = 210; $script:lblStatus.Width = 380; $script:lblStatus.Height = 26
$script:lblStatus.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$script:lblStatus.Text = 'STOPPED'
$script:lblStatus.ForeColor = [System.Drawing.Color]::Gray
$script:lblStatus.Parent = $form
$script:lblDetail = New-Object System.Windows.Forms.Label
$script:lblDetail.Left = 20; $script:lblDetail.Top = 240; $script:lblDetail.Width = 380; $script:lblDetail.Height = 44
$script:lblDetail.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$script:lblDetail.ForeColor = [System.Drawing.Color]::FromArgb(161, 161, 170)
$script:lblDetail.Text = 'Configure above, then press Start.'
$script:lblDetail.Parent = $form
$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Left = 20; $progress.Top = 292; $progress.Width = 380; $progress.Height = 6
$progress.Style = 'Continuous'
$progress.Parent = $form
# ---- buttons ----
$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Left = 20; $btnStart.Top = 316; $btnStart.Width = 120; $btnStart.Height = 40
$btnStart.Text = 'Start'
$btnStart.FlatStyle = 'Flat'
$btnStart.BackColor = [System.Drawing.Color]::FromArgb(255, 0, 110)
$btnStart.ForeColor = [System.Drawing.Color]::White
$btnStart.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$btnStart.Parent = $form
$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Left = 150; $btnStop.Top = 316; $btnStop.Width = 120; $btnStop.Height = 40
$btnStop.Text = 'Stop'
$btnStop.Enabled = $false
$btnStop.FlatStyle = 'Flat'
$btnStop.BackColor = [System.Drawing.Color]::FromArgb(39, 39, 42)
$btnStop.ForeColor = [System.Drawing.Color]::White
$btnStop.Parent = $form
$btnHide = New-Object System.Windows.Forms.Button
$btnHide.Left = 280; $btnHide.Top = 316; $btnHide.Width = 120; $btnHide.Height = 40
$btnHide.Text = 'Hide to tray'
$btnHide.FlatStyle = 'Flat'
$btnHide.BackColor = [System.Drawing.Color]::FromArgb(39, 39, 42)
$btnHide.ForeColor = [System.Drawing.Color]::White
$btnHide.Parent = $form
$lblFooter = New-Object System.Windows.Forms.Label
$lblFooter.Left = 20; $lblFooter.Top = 372; $lblFooter.Width = 380; $lblFooter.Height = 48
$lblFooter.ForeColor = [System.Drawing.Color]::FromArgb(113, 113, 122)
$lblFooter.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$lblFooter.Text = 'Closing the window keeps running in the tray. Exit from the tray icon or press Stop.'
$lblFooter.Parent = $form
# ---------------- tray ----------------
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.SystemIcons]::Application
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
        # Press when the interval elapses (and always on phase entry).
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
                # 'never rest' cycles in place: refresh the phase window only.
                $script:PhaseEnd = $now.AddMinutes([double]::Max(1, [double]$script:Cfg.Active))
            } else {
                $script:Phase = 'REST'
                $script:PhaseEnd = $now.AddMinutes([double]$script:Cfg.Rest)
                $script:LastPress = $null
                Set-Status 'REST' ([System.Drawing.Color]::FromArgb(113, 113, 122))
            }
        }
    }
    elseif ($script:Phase -eq 'REST') {
        if ($remaining -le 0) {
            $script:Phase = 'ACTIVE'
            $script:PhaseEnd = $now.AddMinutes([double]$script:Cfg.Active)
            Set-Status 'ACTIVE' ([System.Drawing.Color]::FromArgb(34, 197, 94))
        }
    }
    # ---- status line + progress ----
    if ($script:Running) {
        $total = ($script:PhaseEnd - $script:CfgStarted).TotalSeconds
        $pct = 0
        if ($total -gt 0) { $pct = [int]((1 - ($remaining / $total)) * 100) }
        if ($pct -lt 0) { $pct = 0 }; if ($pct -gt 100) { $pct = 100 }
        $progress.Value = $pct
        $script:lblDetail.Text = "Phase time left: $(Format-Span $remaining)`nKey: $($script:Cfg.Key) every $($script:Cfg.Interval)s - taps so far: $($script:PressCount)"
    }
    if (-not $script:Running) {
        $progress.Value = 0
        Set-Status 'STOPPED' ([System.Drawing.Color]::FromArgb(113, 113, 122))
        $script:lblDetail.Text = 'Configure above, then press Start.'
    }
})
# ---------------- actions ----------------
function Start-KeepAlive {
    $interval = 0; $active = 0; $rest = 0
    if (-not [double]::TryParse($txtInterval.Text, [ref]$interval) -or $interval -lt 1) {
        [System.Windows.Forms.MessageBox]::Show('Seconds between presses must be a number of 1 or more.', 'KeepAlive') | Out-Null
        return
    }
    if (-not [double]::TryParse($txtActive.Text, [ref]$active) -or $active -lt 0) {
        [System.Windows.Forms.MessageBox]::Show('Active minutes must be 0 (never rest) or a positive number.', 'KeepAlive') | Out-Null
        return
    }
    if (-not [double]::TryParse($txtRest.Text, [ref]$rest) -or $rest -lt 0) {
        [System.Windows.Forms.MessageBox]::Show('Rest minutes must be 0 or a positive number.', 'KeepAlive') | Out-Null
        return
    }
    if ($active -gt 0 -and $rest -le 0) {
        [System.Windows.Forms.MessageBox]::Show('With an active timer set, rest minutes must be at least 0.5 (use 0 active minutes for the never-rest mode).', 'KeepAlive') | Out-Null
        return
    }
    $script:Cfg = @{ Interval = $interval; Active = $active; Rest = $rest; Key = $cmbKey.SelectedItem.ToString() }
    $script:NeverRest = ($active -le 0)
    $script:Running = $true
    $script:Phase = 'ACTIVE'
    $script:CfgStarted = Get-Date
    $script:PhaseEnd = (Get-Date).AddMinutes([double]::Max(0.016, $active))
    $script:LastPress = $null
    $script:PressCount = 0
    Set-Status 'ACTIVE' ([System.Drawing.Color]::FromArgb(34, 197, 94))
    $btnStart.Enabled = $false
    $btnStop.Enabled = $true
    foreach ($c in @($cmbKey, $txtInterval, $txtActive, $txtRest)) { $c.Enabled = $false }
    $tray.Text = 'KeepAlive - ACTIVE'
    $timer.Start()
}
function Stop-KeepAlive {
    $script:Running = $false
    $script:Phase = 'STOPPED'
    $timer.Stop()
    Set-Status 'STOPPED' ([System.Drawing.Color]::FromArgb(113, 113, 122))
    $progress.Value = 0
    $btnStart.Enabled = $true
    $btnStop.Enabled = $false
    foreach ($c in @($cmbKey, $txtInterval, $txtActive, $txtRest)) { $c.Enabled = $true }
    $tray.Text = 'KeepAlive - stopped'
}
$btnStart.Add_Click({ Start-KeepAlive })
$btnStop.Add_Click({ Stop-KeepAlive })
$trayToggle.Add_Click({ if ($script:Running) { Stop-KeepAlive } else { Start-KeepAlive } })
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
# Closing the window keeps the tool running in the tray (it survives until
# you exit from the tray icon); a stopped tool closes normally.
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