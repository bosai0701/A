
$ErrorActionPreference = "Stop"

$root = "C:\KyoshinServer"
$repo = "bosai0701/eq-rts"
$branch = "main"

$serverPath = Join-Path $root "server.js"
$tunnelPath = Join-Path $root "cloudflared.exe"

$node = "C:\Program Files\nodejs\node.exe"

$nodeLog = Join-Path $root "node.log"
$nodeError = Join-Path $root "node-error.log"
$tunnelLog = Join-Path $root "tunnel.log"
$tunnelError = Join-Path $root "tunnel-error.log"

Write-Host "Starting server..."

# Check required files
if (!(Test-Path $serverPath)) {
    throw "server.js not found"
}

if (!(Test-Path $tunnelPath)) {
    throw "cloudflared.exe not found"
}

if (!(Test-Path $node)) {
    throw "Node.js not found: $node"
}

# Check Node.js version
$nodeVersion = & $node -v
Write-Host "Node.js version: $nodeVersion"

# Check existing server
$serverReady = $false

try {
    Invoke-RestMethod "http://127.0.0.1:8787/status" -TimeoutSec 2 | Out-Null
    $serverReady = $true
} catch {}

# Start Node.js if needed
if (!$serverReady) {

    Write-Host "Starting Node.js collector..."

    $serverProcess = Start-Process `
        -FilePath $node `
        -ArgumentList @("--experimental-fetch", "server.js") `
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

# Stop previous tunnel started by this script
$oldPidFile = Join-Path $root "cloudflared.pid"

if (Test-Path $oldPidFile) {

    $oldPid = Get-Content $oldPidFile -ErrorAction SilentlyContinue

    if ($oldPid -match '^\d+$') {

        $oldProcess = Get-Process -Id ([int]$oldPid) -ErrorAction SilentlyContinue

        if ($oldProcess -and $oldProcess.ProcessName -eq "cloudflared") {
            Stop-Process -Id ([int]$oldPid) -Force
            Start-Sleep -Seconds 2
        }
    }
}

Remove-Item $tunnelLog, $tunnelError -Force -ErrorAction SilentlyContinue

Write-Host "Starting Cloudflare Tunnel..."

$tunnelProcess = Start-Process `
    -FilePath $tunnelPath `
    -ArgumentList @(
        "tunnel",
        "--url",
        "http://127.0.0.1:8787",
        "--no-autoupdate"
    ) `
    -WorkingDirectory $root `
    -PassThru `
    -WindowStyle Hidden `
    -RedirectStandardOutput $tunnelLog `
    -RedirectStandardError $tunnelError

Set-Content $oldPidFile $tunnelProcess.Id

# Wait for Quick Tunnel URL
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

# Check GitHub CLI
$ghCommand = Get-Command gh.exe -ErrorAction Stop
$gh = $ghCommand.Definition

if ([string]::IsNullOrEmpty($gh)) {
    throw "GitHub CLI not found"
}

if (!(Test-Path $gh)) {
    throw "GitHub CLI executable not found"
}

# Check GitHub login
Write-Host "Checking GitHub login..."

& $gh auth status

if ($LASTEXITCODE -ne 0) {
    throw "GitHub login required. Run gh auth login first."
}

# Fetch GitHub file
Write-Host "Fetching GitHub file..."

$fileJson = & $gh api "repos/$repo/contents/index.html?ref=$branch"

if ($LASTEXITCODE -ne 0) {
    throw "Could not fetch GitHub file"
}

$file = $fileJson | ConvertFrom-Json

if (!$file.content -or !$file.sha) {
    throw "GitHub file content or SHA is missing"
}

$bytes = [Convert]::FromBase64String(
    ($file.content -replace '\s', '')
)

$html = [System.Text.Encoding]::UTF8.GetString($bytes)

# Replace exactly one WS_URL
$pattern = "(?m)(const WS_URL\s*=\s*\r?\n\s*)'wss://[^']+';"

$matches = [regex]::Matches($html, $pattern)

if ($matches.Count -ne 1) {
    throw "WS_URL was not found exactly once. GitHub was not changed."
}

$evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
    param($m)

    return $m.Groups[1].Value + "'" + $wsUrl + "';"
}

$html = [regex]::Replace(
    $html,
    $pattern,
    $evaluator,
    1
)

Write-Host "Preparing GitHub update..."

$newBytes = [System.Text.Encoding]::UTF8.GetBytes($html)
$encoded = [Convert]::ToBase64String($newBytes)

$payload = @{
    message = "Update WebSocket endpoint"
    content = $encoded
    sha = $file.sha
    branch = $branch
} | ConvertTo-Json -Compress

$tempJson = Join-Path $root "github-update.json"

$utf8 = New-Object System.Text.UTF8Encoding($false)

[System.IO.File]::WriteAllText(
    $tempJson,
    $payload,
    $utf8
)

try {

    Write-Host "Updating GitHub..."

    & $gh api `
        --method PUT `
        "repos/$repo/contents/index.html" `
        --input $tempJson

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
