Set shell = CreateObject("WScript.Shell")
psPath = Replace(WScript.ScriptFullName, WScript.ScriptName, "KeepAliveUI.ps1")
shell.Run "powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & psPath & """", 0, False
