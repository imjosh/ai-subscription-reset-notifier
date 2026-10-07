# AI subscription reset notifier

A Windows desktop notifier triggered by HTTP requests for Claude and ChatGPT subscription resets. Node listens on `127.0.0.1:8787` and launches a PowerShell popup. An optional Cloudflare Tunnel forwards a public hostname to that local server.

## Requirements

- Windows with Windows PowerShell 5.1 and Windows Script Host.
- Node.js on `PATH`. The server uses built-in modules; no npm dependencies are required.
- A logged-in desktop session for the popup.
- For sound: the external `Automate-Windows-Audio.ps1` helper, currently loaded from `C:\Users\Josh\Documents\GitHub\personal\automate-windows-audio\Automate-Windows-Audio.ps1`. Update that path in `Reset-Notify.ps1` for another machine. The helper must expose `AutoAudio.SetVolume` and `AutoAudio.PlaySoundFile`.
- For a public endpoint: `cloudflared` and a domain using Cloudflare DNS.

Audio plays between 09:00 and 22:00 local time and sets system volume to 50%. The popup remains until dismissed. This repository does not schedule subscription resets itself; a caller must request `/notify` at the appropriate time.

## Run and verify locally

From the project directory:

```powershell
npm start
# Optional custom port (use the same port when configuring the tunnel):
node .\server.js --port 8788
```

The server also accepts a positional port or `PORT` environment variable, in that order after `--port`; the default is 8787.

In another PowerShell window:

```powershell
# Expected: HTTP 404, confirming the listener without a popup.
curl.exe --max-time 3 -i 'http://127.0.0.1:8787/'

# Expected: HTTP 200 and a desktop popup.
curl.exe 'http://127.0.0.1:8787/notify?claude=true&chatgpt=true'
```

`GET /notify` accepts `claude=true`, `chatgpt=true`, or both. Keys and values are case-insensitive. Missing, duplicate, unknown, or non-true parameters return 400; other methods on `/notify` return 405; other paths return 404. A 200 means the notification was dispatched, not that the popup or audio completed successfully.

## Start automatically at logon

Use Task Scheduler so the notifier runs in your desktop session. The Cloudflare connector can run as a Windows service; the notification server needs an interactive logon.

Open PowerShell **as administrator using your own Windows account**, change to this project directory, and run:

```powershell
node.exe --version
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-ServerTask.ps1
```

The installer creates or replaces `SubscriptionResetNotifier`, stops Node processes running this project's absolute `server.js` path, and starts the task immediately. Pass `-TaskName 'MyResetNotifier'` to choose another name. The task runs as the installing user without elevation and starts again at logon.

If an earlier installation used another task name, disable or remove that task before installing with the new default, or pass its existing name with `-TaskName` to update it.

The launcher chain is intentional:

```text
Task Scheduler -> Run-ServerHidden.vbs -> Start-Server.ps1 -> server.js -> Reset-Notify.ps1
```

The VBS wrapper hides PowerShell and waits for it; PowerShell waits for Node and returns its exit code. This allows Task Scheduler to supervise and restart a failed server. Output goes to `logs/server.stdout.log` and `logs/server.stderr.log`; launcher errors go to `logs/launcher.log`. Each launch replaces the Node output logs.

Verify:

```powershell
Get-ScheduledTask -TaskName 'SubscriptionResetNotifier' | Select-Object TaskName, State
Get-ScheduledTaskInfo -TaskName 'SubscriptionResetNotifier'
curl.exe --max-time 3 -i 'http://127.0.0.1:8787/'
Get-Content .\logs\server.stdout.log
Get-Content .\logs\server.stderr.log
```

Expect task state `Running` and HTTP 404. `LastTaskResult` of `267009` (`0x41301`) means the task is currently running. If installation reports access denied, use administrator PowerShell. The launcher requires `node.exe` on the task user's `PATH`.

Manage the task:

```powershell
Start-ScheduledTask -TaskName 'SubscriptionResetNotifier'
Stop-ScheduledTask -TaskName 'SubscriptionResetNotifier'
Disable-ScheduledTask -TaskName 'SubscriptionResetNotifier' # Prevent future logon launches.

# Remove it:
Stop-ScheduledTask -TaskName 'SubscriptionResetNotifier'
Unregister-ScheduledTask -TaskName 'SubscriptionResetNotifier' -Confirm:$false
```

To stop a remaining server or a manual hidden launch, first stop its scheduled task to prevent restart, then target this project's Node process:

```powershell
$serverPath = (Resolve-Path .\server.js).Path
$serverArgument = '(?:^|\s)"?' + [regex]::Escape($serverPath) + '"?(?:\s|$)'
Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" |
    Where-Object { $_.CommandLine -match $serverArgument } |
    ForEach-Object { Stop-Process -Id $_.ProcessId }
```

The waiting wrappers exit when Node stops. A subsequent `curl.exe --max-time 3 -i 'http://127.0.0.1:8787/'` should fail to connect.

As an alternative, disable or remove the task and put a shortcut to `Run-ServerHidden.vbs` in `shell:startup`. Keep the launcher files together. Use only one logon launcher to avoid competing servers; the Startup-folder option has no automatic restart handling.

## Configure Cloudflare Tunnel

Install the connector if needed, then run development setup:

```powershell
winget install --id Cloudflare.cloudflared
.\Setup-CloudflareTunnel.ps1 -tunnelName MyTunnel -myDomain example.com -hostname reset.example.com
```

Supply both `-tunnelName` and `-myDomain`; neither has a default. Use a domain in your Cloudflare account. The origin port defaults to 8787. Development runs the connector in the foreground. For a service, use elevated PowerShell and `-mode Production`. The local server may already be running during either setup.

See [Cloudflare Tunnel Setup Utility](Cloudflare%20Tunnel%20Setup%20Utility.md) for parameters, credentials, service paths, and troubleshooting. The HTTP endpoint has no built-in authentication; callers able to reach the published hostname can trigger popups.

## Repository files

| File | Purpose |
| --- | --- |
| `server.js` | Local HTTP request validation and notification dispatch. |
| `Reset-Notify.ps1` | Audio and desktop popup. |
| `Install-ServerTask.ps1` | Installs the interactive logon task. |
| `Run-ServerHidden.vbs` | Hidden launcher used by the task or Startup folder. |
| `Start-Server.ps1` | Starts Node, captures logs, and propagates its exit code. |
| `Setup-CloudflareTunnel.ps1` | Development and production tunnel setup. |
| `universfield-cash-register-open-ding-559401.mp3` | Notification sound. |

The Git branch is `master`. Generated logs, local tunnel files, and downloaded connector binaries are ignored. Keep tunnel credentials outside the repository. Production service installation and desktop audio require manual verification on the target machine.
