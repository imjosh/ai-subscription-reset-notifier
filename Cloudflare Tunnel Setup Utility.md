# Cloudflare Tunnel Setup Utility

`Setup-CloudflareTunnel.ps1` configures a locally managed Cloudflare Tunnel on Windows. The origin is `http://127.0.0.1:<port>`; the notifier defaults to port 8787. Start the notifier as described in [README](README.md).

## Requirements and quick start

Use PowerShell 5.1 or later, `cloudflared`, a Cloudflare account, and a domain using Cloudflare DNS. The script looks for `cloudflared.exe` on `PATH`, beside the script, or in the Cloudflare directories under Program Files.

```powershell
winget install --id Cloudflare.cloudflared

# Foreground connector; Ctrl+C stops it.
.\Setup-CloudflareTunnel.ps1 -tunnelName MyTunnel -myDomain example.com -hostname tunnelName.example.com

# Configure only; print the command for a later start.
.\Setup-CloudflareTunnel.ps1 -tunnelName MyTunnel -myDomain example.com -hostname tunnelName.example.com -noRun

# Windows service; run PowerShell as administrator.
.\Setup-CloudflareTunnel.ps1 -mode Production -tunnelName MyTunnel -myDomain example.com -hostname tunnelName.example.com
```

The script authenticates if `cert.pem` is missing, finds or creates the named tunnel, verifies its credentials, routes DNS, writes YAML, validates ingress, and runs the connector (unless `-noRun` is set.) Existing tunnels are selected by exact name; duplicate names or missing tunnel credentials cause setup to stop.

The origin may already be listening. `cloudflared` connects to the application and does not bind its port. Setup can also complete before the application starts; forwarded requests need the application running to succeed.

## Parameters

| Parameter | Default | Behavior |
| --- | --- | --- |
| `-mode` | `Development` | `Development` runs in the foreground; `Production` installs/configures a Windows service and requires elevation. |
| `-tunnelName` | Required; no default | Exact tunnel name to reuse or create. |
| `-myDomain` | Required; no default | Domain used to generate the default hostname. |
| `-hostname` | Lowercase `<tunnelName>.<myDomain>` | Complete DNS hostname override. |
| `-port` | `8787` | Local HTTP origin port, from 1 through 65535; match the server's listening port. |
| `-skipLogin` | Off | Require an existing user `cert.pem`. |
| `-skipCreate` | Off | Require an existing tunnel with the requested name. |
| `-skipDnsRoute` | Off | Leave DNS unchanged. |
| `-overwriteDns` | Off | Allow replacement of an existing hostname's DNS record. |
| `-checkDns` | Off | Retry public hostname resolution for roughly two minutes. |
| `-noRun` | Off | Configure without starting; production leaves the service stopped. |

Supply both `-tunnelName` and `-myDomain`, even when overriding `-hostname`. `-overwriteDns` should only be used when assigning an existing hostname to this tunnel. DNS resolution alone does not verify that the origin or tunnel is healthy.

## Development files

Files stay in `%USERPROFILE%\.cloudflared`:

```text
cert.pem
<tunnel-id>.json
config-<tunnel-id>.yml
```

Each tunnel has its own credentials and config; the account certificate is shared. Multiple foreground connectors can coexist. A generated config resembles:

```yaml
tunnel: <tunnel-id>
credentials-file: 'C:\Users\User\.cloudflared\<tunnel-id>.json'
ingress:
  - hostname: 'tunnelName.example.com'
    service: 'http://127.0.0.1:8787'
  - service: http_status:404
```

Start or validate a configured tunnel manually, substituting its UUID:

```powershell
cloudflared tunnel --config "$env:USERPROFILE\.cloudflared\config-<tunnel-id>.yml" ingress validate
cloudflared tunnel --config "$env:USERPROFILE\.cloudflared\config-<tunnel-id>.yml" run <tunnel-id>
```

## Production files and service

Production uses these paths (on the system drive and Windows directory):

```text
C:\Cloudflared\bin\cloudflared.exe
C:\Cloudflared\cloudflared.log
C:\Windows\System32\config\systemprofile\.cloudflared\<tunnel-id>.json
C:\Windows\System32\config\systemprofile\.cloudflared\config.yml
```

The config also includes the log path. Only tunnel credentials are copied to the service profile; the user's account certificate stays in their profile. The service command uses the installed executable and explicit config:

```text
"C:\Cloudflared\bin\cloudflared.exe" --config "C:\Windows\System32\config\systemprofile\.cloudflared\config.yml" tunnel run
```

The script manages one `cloudflared` service, with automatic startup. It permits reruns for the same tunnel and refuses an existing service whose expected config is missing, unreadable as a tunnel UUID, or belongs to another tunnel. Rerunning setup rewrites the generated config with one hostname/origin rule; preserve any manually added ingress rules before rerunning.

`-noRun` stops an existing service for this tunnel and leaves it stopped after configuration. This setting still installs and updates the service.

```powershell
Get-Service cloudflared
Start-Service cloudflared
Stop-Service cloudflared
Restart-Service cloudflared
Get-Content C:\Cloudflared\cloudflared.log -Wait
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Cloudflared'
```

The connector service can start before logon, but desktop notifications need the Node task running in the logged-in session.

## Troubleshooting and removal

```powershell
cloudflared tunnel list
cloudflared tunnel info MyTunnel
Resolve-DnsName tunnelName.example.com

# Verify the origin without triggering a popup (expect HTTP 404).
curl.exe --max-time 3 -i 'http://127.0.0.1:8787/'

# Inspect a listener if the Node server cannot start.
Get-NetTCPConnection -LocalPort 8787 -State Listen
```

A missing credentials file must be recovered for the exact tunnel UUID; credentials from another tunnel cannot substitute for it. Do not commit credentials. `.gitignore` excludes a repository-local `.cloudflared/` directory and `cert.pem`; keep UUID JSON credentials in the profile locations above.

To remove the service, use elevated PowerShell:

```powershell
Stop-Service cloudflared
cloudflared service uninstall
```

This leaves the remote tunnel and local runtime files intact. To delete an unused remote tunnel separately:

```powershell
cloudflared tunnel delete MyTunnel
```

## Cloudflare reference

- [Locally managed tunnels](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/)
- [Windows service setup](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/as-a-service/windows/)
- [Configuration files and ingress rules](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/configuration-file/)
