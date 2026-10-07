$ErrorActionPreference = 'Stop'
$logDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

try {
    $node = (Get-Command node.exe -CommandType Application -ErrorAction Stop |
        Select-Object -First 1).Source
    $server = Join-Path $PSScriptRoot 'server.js'
    $process = Start-Process -FilePath $node `
        -ArgumentList "`"$server`"" `
        -WorkingDirectory $PSScriptRoot `
        -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $logDir 'server.stdout.log') `
        -RedirectStandardError (Join-Path $logDir 'server.stderr.log') `
        -PassThru -Wait
    exit $process.ExitCode
} catch {
    "$(Get-Date -Format o) $($_.Exception.Message)" |
        Add-Content -LiteralPath (Join-Path $logDir 'launcher.log')
    exit 1
}
