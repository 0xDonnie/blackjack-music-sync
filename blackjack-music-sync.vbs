' blackjack-music-sync launcher
' Double-click this file to open the music GUI. No console window.
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = scriptDir
sh.Run "pwsh.exe -NoProfile -ExecutionPolicy Bypass -File """ & scriptDir & "\gui_v1.ps1""", 0, False
