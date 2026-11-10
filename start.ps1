
$ErrorActionPreference = "Stop"

$root = "C:\KyoshinServer"
$repo = "bosai0701/eq-rts"
$branch = "main"

$serverPath = Join-Path $root "server.js"
$tunnelPath = Join-Path $root "cloudflared.exe"

$nodeLog = Join-Path $root "node.log"
$nodeError = Join-Path $root "node-error.log"
$tunnelLog = Join-Path $root "tunnel.log"
$tunnelError = Join-Path $root "tunnel-error.log"

Write-Host "Starting server..."

$node = (Get-Command node.exe -ErrorAction Stop).Source

if (!(Test-Path $serverPath)) { throw "server.js not found" }
if (!(Test-Path $tunnelPath)) { throw "cloudflared.exe not found" }

$serverReady = $false

try {
    Invoke-RestMethod "http://127.0.0.1:8787/status" -TimeoutSec 2 | Out-Null
    $serverReady = $true
} catch {}

if (!$serverReady) {
    $serverProcess = Start-Process `
        -FilePath $node `
        -ArgumentList "server.js" `
        -WorkingDirectory $root `
        -PassThru `
        -WindowStyle Hidden `
        -RedirectStandardOutput $nodeLog `
        -RedirectStandardError $nodeError

    Set-Content (Join-Path $root "node.pid") $serverProcess.Id

    $ready = $false

    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        try {
            Invoke-RestMethod "http://127.0.0.1:8787/status" -TimeoutSec 2 | Out-Null
            $ready = $true
            break
        } catch {}
    }

    if (!$ready) {
        throw "Node server failed. Check node-error.log"
    }
}

Write-Host "Node server OK"

$oldPidFile = Join-Path $root "cloudflared.pid"

if (Test-Path $oldPidFile) {
    $oldPid = Get-Content $oldPidFile -ErrorAction SilentlyContinue

    if ($oldPid -match '^\d+$') {
        $oldProcess = Get-Process -Id ([int]$oldPid) -ErrorAction SilentlyContinue
        if ($oldProcess -and $oldProcess.ProcessName -eq "cloudflared") {
            Stop-Process -Id ([int]$oldPid) -Force
        }
    }
}

Remove-Item $tunnelLog, $tunnelError -Force -ErrorAction SilentlyContinue

Write-Host "Starting Cloudflare Tunnel..."

$tunnelProcess = Start-Process `
    -FilePath $tunnelPath `
    -ArgumentList @("tunnel", "--url", "http://127.0.0.1:8787", "--no-autoupdate") `
    -WorkingDirectory $root `
    -PassThru `
    -WindowStyle Hidden `
    -RedirectStandardOutput $tunnelLog `
    -RedirectStandardError $tunnelError

Set-Content $oldPidFile $tunnelProcess.Id

$httpsUrl = $null

for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 1

    $logs = ""

    foreach ($file in @($tunnelLog, $tunnelError)) {
        if (Test-Path $file) {
            $logs += Get-Content $file -Raw -ErrorAction SilentlyContinue
        }
    }

    $match = [regex]::Match(
        $logs,
        'https://[a-z0-9-]+\.trycloudflare\.com',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if ($match.Success) {
        $httpsUrl = $match.Value
        break
    }

    if ($tunnelProcess.HasExited) {
        throw "Cloudflare Tunnel stopped. Check tunnel-error.log"
    }
}

if (!$httpsUrl) {
    throw "Could not get Cloudflare URL"
}

$wsUrl = ($httpsUrl -replace '^https://', 'wss://') + "/"

Write-Host "New WSS URL: $wsUrl"

Write-Host "Fetching GitHub file..."

$file = (& gh api "repos/$repo/contents/index.html?ref=$branch" | ConvertFrom-Json)

if ($LASTEXITCODE -ne 0) {
    throw "Could not fetch GitHub file"
}

$bytes = [Convert]::FromBase64String(($file.content -replace '\s', ''))
$html = [System.Text.Encoding]::UTF8.GetString($bytes)

$pattern = "(?m)(const WS_URL\s*=\s*\r?\n\s*)'wss://[^']+';"
$regex = [regex]::new($pattern)

if ($regex.Matches($html).Count -ne 1) {
    throw "WS_URL was not found exactly once. GitHub was not changed."
}

$html = $regex.Replace(
    $html,
    [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        return $m.Groups[1].Value + "'" + $wsUrl + "';"
    },
    1
)

Write-Host "Updating GitHub..."

$newBytes = [System.Text.Encoding]::UTF8.GetBytes($html)
$encoded = [Convert]::ToBase64String($newBytes)

$payload = @{
    message = "Update WebSocket endpoint"
    content = $encoded
    sha = $file.sha
    branch = $branch
} | ConvertTo-Json -Compress

$tempJson = Join-Path $root "github-update.json"

[System.IO.File]::WriteAllText(
    $tempJson,
    $payload,
    [System.Text.UTF8Encoding]::new($false)
)

try {
    & gh api --method PUT "repos/$repo/contents/index.html" --input $tempJson

    if ($LASTEXITCODE -ne 0) {
        throw "GitHub update failed"
    }
}
finally {
    Remove-Item $tempJson -Force -ErrorAction SilentlyContinue
}

Write-Host "GitHub update completed."
Write-Host "WSS URL: $wsUrl"
Write-Host "All tasks completed."
