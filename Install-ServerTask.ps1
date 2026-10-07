param([string]$TaskName = 'SubscriptionResetNotifier')

$ErrorActionPreference = 'Stop'
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$launcher = Join-Path $PSScriptRoot 'Run-ServerHidden.vbs'
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'

$action = New-ScheduledTaskAction -Execute $wscript `
    -Argument "//B //Nologo `"$launcher`"" -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

# Stop the previous task before replacing its action.
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
}
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description 'AI subscription reset server, hidden in the logged-in desktop session' `
    -Force -ErrorAction Stop | Out-Null

# Take over from a manual launch of this exact server, without touching other Node apps.
$serverPath = Join-Path $PSScriptRoot 'server.js'
$serverArgument = '(?:^|\s)"?' + [regex]::Escape($serverPath) + '"?(?:\s|$)'
Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction Stop |
    Where-Object { $_.CommandLine -match $serverArgument } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction Stop }

Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
Get-ScheduledTask -TaskName $TaskName
