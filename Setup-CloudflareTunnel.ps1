#Requires -Version 5.1

[CmdletBinding()]
param(
  [ValidateSet("Development", "Production")]
  [string]$mode = "Development",

  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$tunnelName,

  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$myDomain,

  # If omitted, defaults to <tunnelName>.<myDomain>
  [string]$hostname = "",

  [ValidateRange(1, 65535)]
  [int]$port = 8787,

  [switch]$skipLogin,
  [switch]$skipCreate,
  [switch]$skipDnsRoute,

  # Allows cloudflared to replace an existing DNS record.
  [switch]$overwriteDns,

  [switch]$checkDns,

  # Development:
  #   Configure everything but do not run cloudflared.
  #
  # Production:
  #   Install/configure the service but leave it stopped.
  [switch]$noRun
)

$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)

  return $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
  )
}

function Get-CloudflaredExe {
  $command = Get-Command cloudflared -ErrorAction SilentlyContinue

  if ($command -and $command.Source) {
    return $command.Source
  }

  $candidates = @(
    (Join-Path $PSScriptRoot "cloudflared.exe"),
    (Join-Path $env:ProgramFiles "Cloudflare\cloudflared\cloudflared.exe"),
    (Join-Path $env:ProgramFiles "Cloudflare\Cloudflared\cloudflared.exe")
  )

  if (${env:ProgramFiles(x86)}) {
    $candidates += @(
      (Join-Path ${env:ProgramFiles(x86)} "cloudflared\cloudflared.exe"),
      (Join-Path ${env:ProgramFiles(x86)} "Cloudflare\cloudflared\cloudflared.exe"),
      (Join-Path ${env:ProgramFiles(x86)} "Cloudflare\Cloudflared\cloudflared.exe")
    )
  }

  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) {
      return $candidate
    }
  }

  throw "cloudflared.exe was not found."
}

function Invoke-Cloudflared {
  param(
    [Parameter(Mandatory = $true)]
    [string]$exe,

    [Parameter(Mandatory = $true)]
    [string[]]$arguments
  )

  & $exe @arguments

  if ($LASTEXITCODE -ne 0) {
    throw @"
cloudflared exited with code $LASTEXITCODE.

Command:
cloudflared $($arguments -join ' ')
"@
  }
}

function Get-CloudflaredOutput {
  param(
    [Parameter(Mandatory = $true)]
    [string]$exe,

    [Parameter(Mandatory = $true)]
    [string[]]$arguments
  )

  $output = & $exe @arguments

  if ($LASTEXITCODE -ne 0) {
    throw @"
cloudflared exited with code $LASTEXITCODE.

Command:
cloudflared $($arguments -join ' ')
"@
  }

  return ($output -join [Environment]::NewLine)
}

function Get-Tunnel {
  param(
    [Parameter(Mandatory = $true)]
    [string]$name,

    [Parameter(Mandatory = $true)]
    [string]$exe
  )

  $json = Get-CloudflaredOutput `
    -exe $exe `
    -arguments @(
      "tunnel",
      "list",
      "--name",
      $name,
      "--output",
      "json"
    )

  if ([string]::IsNullOrWhiteSpace($json)) {
    return $null
  }

  try {
    $parsed = $json | ConvertFrom-Json
  }
  catch {
    throw @"
Could not parse JSON returned by:

cloudflared tunnel list --name "$name" --output json

$($_.Exception.Message)
"@
  }

  # Windows PowerShell 5.1 can preserve the JSON array differently
  # depending on the pipeline context. Explicitly flatten the parsed
  # result so a JSON array can never be returned as one nested object.
  $tunnels = @()

  if ($null -eq $parsed) {
    return $null
  }

  if ($parsed -is [System.Array]) {
    foreach ($item in $parsed) {
      if ($null -ne $item) {
        $tunnels += $item
      }
    }
  }
  else {
    $tunnels += $parsed
  }

  $matchingTunnels = @(
    $tunnels |
      Where-Object {
        $_.name -eq $name
      }
  )

  if ($matchingTunnels.Count -eq 0) {
    return $null
  }

  if ($matchingTunnels.Count -gt 1) {
    $ids = (
      $matchingTunnels |
        ForEach-Object {
          "  $($_.id)"
        }
    ) -join [Environment]::NewLine

    throw @"
Multiple active Cloudflare tunnels named '$name' were found.

Tunnel IDs:
$ids

This utility requires tunnel names to be unique.

Delete or rename the duplicate tunnel before continuing.
"@
  }

  # The leading comma prevents PowerShell from enumerating the returned
  # object if cloudflared ever supplies an array-like object here.
  return ,$matchingTunnels[0]
}

function Get-ValidatedTunnelId {
  param(
    [Parameter(Mandatory = $true)]
    $tunnel
  )

  $rawId = $tunnel.id

  if ($null -eq $rawId) {
    throw "The Cloudflare tunnel object does not contain an ID."
  }

  if ($rawId -is [System.Array]) {
    throw @"
cloudflared returned multiple tunnel IDs where exactly one was expected:

$($rawId -join [Environment]::NewLine)
"@
  }

  $tunnelId = ([string]$rawId).Trim()

  $parsedTunnelId = [Guid]::Empty

  if (-not [Guid]::TryParse($tunnelId, [ref]$parsedTunnelId)) {
    throw "Invalid tunnel ID returned by cloudflared: '$tunnelId'"
  }

  return $parsedTunnelId.ToString()
}

function Get-TunnelIdFromConfig {
  param(
    [Parameter(Mandatory = $true)]
    [string]$configFile
  )

  if (-not (Test-Path -LiteralPath $configFile)) {
    return $null
  }

  $line = Get-Content `
    -LiteralPath $configFile `
    -ErrorAction Stop |
    Where-Object {
      $_ -match '^\s*tunnel\s*:'
    } |
    Select-Object -First 1

  if (-not $line) {
    return $null
  }

  if ($line -match "^\s*tunnel\s*:\s*['`"]?([^'`"\s#]+)") {
    $id = $Matches[1]

    $parsedId = [Guid]::Empty

    if ([Guid]::TryParse($id, [ref]$parsedId)) {
      return $parsedId.ToString()
    }
  }

  return $null
}

function ConvertTo-YamlString {
  param(
    [Parameter(Mandatory = $true)]
    [string]$value
  )

  return "'" + ($value -replace "'", "''") + "'"
}

function Write-Utf8NoBom {
  param(
    [Parameter(Mandatory = $true)]
    [string]$path,

    [Parameter(Mandatory = $true)]
    [string]$content
  )

  $directory = Split-Path -Parent $path

  if ($directory) {
    New-Item `
      -ItemType Directory `
      -Path $directory `
      -Force |
      Out-Null
  }

  $encoding = New-Object System.Text.UTF8Encoding($false)

  [System.IO.File]::WriteAllText(
    $path,
    $content,
    $encoding
  )
}

function New-TunnelConfig {
  param(
    [Parameter(Mandatory = $true)]
    [string]$tunnelId,

    [Parameter(Mandatory = $true)]
    [string]$credentialsFile,

    [Parameter(Mandatory = $true)]
    [string]$hostname,

    [Parameter(Mandatory = $true)]
    [int]$port,

    [string]$logFile = ""
  )

  $lines = @(
    "tunnel: $tunnelId"
    "credentials-file: $(ConvertTo-YamlString $credentialsFile)"
  )

  if ($logFile) {
    $lines += "logfile: $(ConvertTo-YamlString $logFile)"
  }

  $lines += @(
    "ingress:"
    "  - hostname: $(ConvertTo-YamlString $hostname)"
    "    service: $(ConvertTo-YamlString "http://127.0.0.1:$port")"
    "  - service: http_status:404"
  )

  return ($lines -join "`r`n") + "`r`n"
}

function Test-Dns {
  param(
    [Parameter(Mandatory = $true)]
    [string]$hostname
  )

  Write-Host "Waiting for DNS: $hostname"

  for ($i = 1; $i -le 12; $i++) {
    try {
      $result = Resolve-DnsName `
        -Name $hostname `
        -ErrorAction Stop

      Write-Host "DNS is resolving."

      $result |
        Select-Object Name, Type, IPAddress, NameHost |
        Format-Table -AutoSize

      return
    }
    catch {
      if ($i -eq 12) {
        throw "DNS did not resolve after approximately 2 minutes: $hostname"
      }

      Start-Sleep -Seconds 10
    }
  }
}

function Stop-CloudflaredService {
  $service = Get-Service `
    -Name "cloudflared" `
    -ErrorAction SilentlyContinue

  if (-not $service) {
    return
  }

  if ($service.Status -eq "Stopped") {
    return
  }

  Write-Host "Stopping cloudflared service..."

  Stop-Service `
    -Name "cloudflared" `
    -Force `
    -ErrorAction Stop

  $service = Get-Service -Name "cloudflared"

  $service.WaitForStatus(
    [System.ServiceProcess.ServiceControllerStatus]::Stopped,
    [TimeSpan]::FromSeconds(20)
  )
}

# ----------------------------------------------------------------------
# Paths
# ----------------------------------------------------------------------

$userCloudflaredDir = Join-Path `
  $env:USERPROFILE `
  ".cloudflared"

$userCertFile = Join-Path `
  $userCloudflaredDir `
  "cert.pem"

$serviceRoot = Join-Path `
  $env:SystemDrive `
  "Cloudflared"

$serviceBinDir = Join-Path `
  $serviceRoot `
  "bin"

$serviceExe = Join-Path `
  $serviceBinDir `
  "cloudflared.exe"

$serviceLogFile = Join-Path `
  $serviceRoot `
  "cloudflared.log"

$systemProfileCloudflaredDir = Join-Path `
  $env:windir `
  "System32\config\systemprofile\.cloudflared"

$serviceConfigFile = Join-Path `
  $systemProfileCloudflaredDir `
  "config.yml"

# ----------------------------------------------------------------------
# Validate parameters
# ----------------------------------------------------------------------

if (-not $hostname) {
  $hostname = "$(
    $tunnelName.ToLowerInvariant()
  ).$(
    $myDomain.Trim('.').ToLowerInvariant()
  )"
}

if ([Uri]::CheckHostName($hostname) -ne [UriHostNameType]::Dns) {
  throw "Invalid hostname: $hostname"
}

if ($mode -eq "Production" -and -not (Test-IsAdministrator)) {
  throw "Production mode must be run from an elevated PowerShell window."
}

# cloudflared connects to the origin; it does not bind the origin port.
# Allow setup whether the local application is already running or starts later.
# ----------------------------------------------------------------------
# Find cloudflared
# ----------------------------------------------------------------------

$cloudflaredExe = Get-CloudflaredExe

Write-Host ""
Write-Host "Mode:        $mode"
Write-Host "Tunnel:      $tunnelName"
Write-Host "Hostname:    $hostname"
Write-Host "Origin:      http://127.0.0.1:$port"
Write-Host "cloudflared: $cloudflaredExe"
Write-Host ""

New-Item `
  -ItemType Directory `
  -Path $userCloudflaredDir `
  -Force |
  Out-Null

# ----------------------------------------------------------------------
# Authenticate
# ----------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $userCertFile)) {
  if ($skipLogin) {
    throw "Cloudflare login certificate not found: $userCertFile"
  }

  Write-Host "Opening browser for Cloudflare authentication..."

  Invoke-Cloudflared `
    -exe $cloudflaredExe `
    -arguments @(
      "tunnel",
      "login"
    )

  if (-not (Test-Path -LiteralPath $userCertFile)) {
    throw "Login completed but cert.pem was not found at $userCertFile"
  }
}
else {
  Write-Host "Cloudflare authentication already exists."
}

# ----------------------------------------------------------------------
# Find or create tunnel
# ----------------------------------------------------------------------

$tunnel = Get-Tunnel `
  -name $tunnelName `
  -exe $cloudflaredExe

if (-not $tunnel) {
  if ($skipCreate) {
    throw "Tunnel '$tunnelName' does not exist and -skipCreate was specified."
  }

  Write-Host "Creating tunnel: $tunnelName"

  Invoke-Cloudflared `
    -exe $cloudflaredExe `
    -arguments @(
      "tunnel",
      "create",
      $tunnelName
    )

  # Query Cloudflare again rather than parsing human-readable output
  # from the create command.
  $tunnel = Get-Tunnel `
    -name $tunnelName `
    -exe $cloudflaredExe

  if (-not $tunnel) {
    throw "Tunnel was created but could not be found afterward."
  }
}
else {
  Write-Host "Tunnel already exists."
}

# ----------------------------------------------------------------------
# Validate tunnel ID
# ----------------------------------------------------------------------

$tunnelId = Get-ValidatedTunnelId -tunnel $tunnel

Write-Host "Tunnel ID: $tunnelId"

$userCredentialsFile = Join-Path `
  $userCloudflaredDir `
  "$tunnelId.json"

$developmentConfigFile = Join-Path `
  $userCloudflaredDir `
  "config-$tunnelId.yml"

$serviceCredentialsFile = Join-Path `
  $systemProfileCloudflaredDir `
  "$tunnelId.json"

# ----------------------------------------------------------------------
# Verify credentials
# ----------------------------------------------------------------------

if ($mode -eq "Development") {
  if (-not (Test-Path -LiteralPath $userCredentialsFile)) {
    throw @"
Tunnel '$tunnelName' exists, but its local credentials file is missing:

$userCredentialsFile

A locally managed tunnel cannot be run without its tunnel credentials.
"@
  }
}
else {
  if (
    -not (Test-Path -LiteralPath $userCredentialsFile) -and
    -not (Test-Path -LiteralPath $serviceCredentialsFile)
  ) {
    throw @"
Tunnel '$tunnelName' exists, but no credentials file was found at either:

$userCredentialsFile

or:

$serviceCredentialsFile
"@
  }
}

# ----------------------------------------------------------------------
# Protect an existing production service
# ----------------------------------------------------------------------

if ($mode -eq "Production") {
  $existingService = Get-Service `
    -Name "cloudflared" `
    -ErrorAction SilentlyContinue

  if ($existingService) {
    if (-not (Test-Path -LiteralPath $serviceConfigFile)) {
      throw @"
A cloudflared Windows service is already installed, but its expected
configuration file could not be found:

$serviceConfigFile

The existing service will not be overwritten automatically.
"@
    }

    $existingTunnelId = Get-TunnelIdFromConfig `
      -configFile $serviceConfigFile

    if (-not $existingTunnelId) {
      throw @"
A cloudflared Windows service is already installed, but the tunnel ID
could not be determined from:

$serviceConfigFile

The existing service will not be overwritten automatically.
"@
    }

    if ($existingTunnelId -ne $tunnelId) {
      throw @"
A different production Cloudflare Tunnel is already installed as the
cloudflared Windows service.

Existing tunnel ID:  $existingTunnelId
Requested tunnel ID: $tunnelId

Only one service-run cloudflared instance should be installed on this
machine.

The existing service will not be overwritten.
"@
    }

    Write-Host "Existing production service belongs to this tunnel."
  }
}

# ----------------------------------------------------------------------
# DNS
# ----------------------------------------------------------------------

if (-not $skipDnsRoute) {
  Write-Host "Configuring DNS route: $hostname"

  $dnsArguments = @(
    "tunnel",
    "route",
    "dns"
  )

  if ($overwriteDns) {
    $dnsArguments += "--overwrite-dns"
  }

  $dnsArguments += @(
    $tunnelId,
    $hostname
  )

  try {
    Invoke-Cloudflared `
      -exe $cloudflaredExe `
      -arguments $dnsArguments
  }
  catch {
    if (-not $overwriteDns) {
      throw @"
Failed to configure DNS for $hostname.

If the hostname already has a DNS record and this tunnel should own it,
rerun with:

  -overwriteDns

Original error:
$($_.Exception.Message)
"@
    }

    throw
  }
}

if ($checkDns) {
  Test-Dns -hostname $hostname
}

# ======================================================================
# DEVELOPMENT
# ======================================================================

if ($mode -eq "Development") {
  $config = New-TunnelConfig `
    -tunnelId $tunnelId `
    -credentialsFile $userCredentialsFile `
    -hostname $hostname `
    -port $port

  Write-Utf8NoBom `
    -path $developmentConfigFile `
    -content $config

  Write-Host "Wrote development config:"
  Write-Host "  $developmentConfigFile"

  Write-Host "Validating configuration..."

  Invoke-Cloudflared `
    -exe $cloudflaredExe `
    -arguments @(
      "tunnel",
      "--config",
      $developmentConfigFile,
      "ingress",
      "validate"
    )

  Write-Host ""
  Write-Host "URL: https://$hostname"

  if ($noRun) {
    Write-Host ""
    Write-Host "Development setup complete."
    Write-Host ""
    Write-Host "Start manually with:"
    Write-Host ""
    Write-Host "cloudflared tunnel --config `"$developmentConfigFile`" run $tunnelId"

    return
  }

  Write-Host ""
  Write-Host "Starting development tunnel..."
  Write-Host "Press Ctrl+C to stop."
  Write-Host ""

  Invoke-Cloudflared `
    -exe $cloudflaredExe `
    -arguments @(
      "tunnel",
      "--config",
      $developmentConfigFile,
      "run",
      $tunnelId
    )

  return
}

# ======================================================================
# PRODUCTION
# ======================================================================

Write-Host ""
Write-Host "Configuring production Windows service..."

# Stop an existing instance of this service before replacing its
# executable or configuration.
Stop-CloudflaredService

New-Item `
  -ItemType Directory `
  -Path $serviceBinDir `
  -Force |
  Out-Null

New-Item `
  -ItemType Directory `
  -Path $systemProfileCloudflaredDir `
  -Force |
  Out-Null

# ----------------------------------------------------------------------
# Install/update cloudflared executable
# ----------------------------------------------------------------------

$sourceExePath = [System.IO.Path]::GetFullPath($cloudflaredExe)
$destinationExePath = [System.IO.Path]::GetFullPath($serviceExe)

if (
  -not [string]::Equals(
    $sourceExePath,
    $destinationExePath,
    [StringComparison]::OrdinalIgnoreCase
  )
) {
  Copy-Item `
    -LiteralPath $cloudflaredExe `
    -Destination $serviceExe `
    -Force
}

if (-not (Test-Path -LiteralPath $serviceExe)) {
  throw "Production cloudflared executable was not installed."
}

Write-Host "Production executable:"
Write-Host "  $serviceExe"

# ----------------------------------------------------------------------
# Install tunnel credentials
# ----------------------------------------------------------------------

if (Test-Path -LiteralPath $userCredentialsFile) {
  Copy-Item `
    -LiteralPath $userCredentialsFile `
    -Destination $serviceCredentialsFile `
    -Force
}

if (-not (Test-Path -LiteralPath $serviceCredentialsFile)) {
  throw "Production credentials file was not installed."
}

Write-Host "Production credentials:"
Write-Host "  $serviceCredentialsFile"

# ----------------------------------------------------------------------
# Production config
# ----------------------------------------------------------------------

$config = New-TunnelConfig `
  -tunnelId $tunnelId `
  -credentialsFile $serviceCredentialsFile `
  -hostname $hostname `
  -port $port `
  -logFile $serviceLogFile

Write-Utf8NoBom `
  -path $serviceConfigFile `
  -content $config

Write-Host "Production config:"
Write-Host "  $serviceConfigFile"

Write-Host "Validating production configuration..."

Invoke-Cloudflared `
  -exe $serviceExe `
  -arguments @(
    "tunnel",
    "--config",
    $serviceConfigFile,
    "ingress",
    "validate"
  )

# ----------------------------------------------------------------------
# Install service if necessary
# ----------------------------------------------------------------------

$service = Get-Service `
  -Name "cloudflared" `
  -ErrorAction SilentlyContinue

if (-not $service) {
  Write-Host "Installing cloudflared Windows service..."

  Invoke-Cloudflared `
    -exe $serviceExe `
    -arguments @(
      "service",
      "install"
    )
}

# The installer may start the service immediately.
Stop-CloudflaredService

# ----------------------------------------------------------------------
# Explicitly configure service command
# ----------------------------------------------------------------------

$serviceRegistryPath = `
  "HKLM:\SYSTEM\CurrentControlSet\Services\Cloudflared"

if (-not (Test-Path -LiteralPath $serviceRegistryPath)) {
  throw "cloudflared service registry entry was not created."
}

$imagePath = `
  "`"$serviceExe`" --config `"$serviceConfigFile`" tunnel run"

Set-ItemProperty `
  -Path $serviceRegistryPath `
  -Name "ImagePath" `
  -Value $imagePath

Set-Service `
  -Name "cloudflared" `
  -StartupType Automatic

Write-Host "Service command:"
Write-Host "  $imagePath"

# ----------------------------------------------------------------------
# Start service
# ----------------------------------------------------------------------

if ($noRun) {
  Write-Host ""
  Write-Host "Production setup complete."
  Write-Host "Service installed but left stopped."
  Write-Host ""
  Write-Host "Start it with:"
  Write-Host ""
  Write-Host "Start-Service cloudflared"

  return
}

Write-Host "Starting cloudflared service..."

Start-Service `
  -Name "cloudflared" `
  -ErrorAction Stop

$service = Get-Service -Name "cloudflared"

$service.WaitForStatus(
  [System.ServiceProcess.ServiceControllerStatus]::Running,
  [TimeSpan]::FromSeconds(20)
)

Write-Host ""
Write-Host "Production setup complete."
Write-Host "Service status: $($service.Status)"
Write-Host "URL: https://$hostname"
Write-Host "Log: $serviceLogFile"
