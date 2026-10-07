Option Explicit

Dim shell, files, scriptDir, launcher, command, result
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
scriptDir = files.GetParentFolderName(WScript.ScriptFullName)
launcher = files.BuildPath(scriptDir, "Start-Server.ps1")
shell.CurrentDirectory = scriptDir

command = """" & shell.ExpandEnvironmentStrings("%SystemRoot%") & _
    "\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & launcher & """"

' Hide the console and wait so Task Scheduler can supervise the server.
result = shell.Run(command, 0, True)
WScript.Quit result
