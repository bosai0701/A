
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

$nodePidFile = Join-Path $root "node.pid"
$tunnelPidFile = Join-Path $root "cloudflared.pid"

Write-Host "=================================="
Write-Host " Kyoshin Server Startup"
Write-Host "=================================="

if (!(Test-Path $serverPath)) {
    throw "server.js not found: $serverPath"
}

if (!(Test-Path $tunnelPath)) {
    throw "cloudflared.exe not found: $tunnelPath"
}

if (!(Test-Path $node)) {
    throw "Node.js not found: $node"
}

# Node.jsのバージョン確認
$nodeVersion = & $node -v
Write-Host "Node.js: $nodeVersion"

# fetchが有効になるか確認
$fetchCheck = & $node --experimental-fetch -e "console.log(typeof fetch); console.log(typeof AbortSignal.timeout)"

if ($LASTEXITCODE -ne 0) {
    throw "Node.js fetch check failed"
}

if ($fetchCheck[0] -ne "function") {
    throw "fetch is not available"
}

if ($fetchCheck[1] -ne "function") {
    throw "AbortSignal.timeout is not available"
}

Write-Host "Fetch support OK"

# 前回起動したNode.jsを停止
if (Test-Path $nodePidFile) {

    $oldNodePid = Get-Content $nodePidFile -ErrorAction SilentlyContinue

    if ($oldNodePid -match '^\d+$') {

        $oldNodeProcess = Get-Process -Id ([int]$oldNodePid) -ErrorAction SilentlyContinue

        if ($oldNodeProcess -and $oldNodeProcess.ProcessName -eq "node") {
            Write-Host "Stopping previous Node.js process..."
            Stop-Process -Id ([int]$oldNodePid) -Force
            Start-Sleep -Seconds 2
        }
    }
}

# 8787番ポートに既存サーバーが残っていないか確認
try {
    Invoke-RestMethod "http://127.0.0.1:8787/status" -TimeoutSec 2 | Out-Null
    throw "Port 8787 is already occupied. Stop the existing collector first."
} catch {
    if ($_.Exception.Message -like "*already occupied*") {
        throw
    }
}

# ログを初期化
Remove-Item $nodeLog, $nodeError -Force -ErrorAction SilentlyContinue

# Node.js起動
Write-Host "Starting Node.js collector..."

$serverProcess = Start-Process `
    -FilePath $node `
    -ArgumentList @("--experimental-fetch", "server.js") `
    -WorkingDirectory $root `
    -PassThru `
    -WindowStyle Hidden `
    -RedirectStandardOutput $nodeLog `
    -RedirectStandardError $nodeError

Set-Content $nodePidFile $serverProcess.Id

# サーバー起動確認
$ready = $false

for ($i = 0; $i -lt 30; $i++) {

    Start-Sleep -Seconds 1

    if ($serverProcess.HasExited) {
        throw "Node.js stopped. Check node-error.log"
    }

    try {
        $status = Invoke-RestMethod "http://127.0.0.1:8787/status" -TimeoutSec 2
        $ready = $true
        break
    } catch {}
}

if (!$ready) {
    throw "Node.js server failed to start. Check node-error.log"
}

Write-Host "Node.js server OK"

# 前回のCloudflare Tunnelを停止
if (Test-Path $tunnelPidFile) {

    $oldTunnelPid = Get-Content $tunnelPidFile -ErrorAction SilentlyContinue

    if ($oldTunnelPid -match '^\d+$') {

        $oldTunnelProcess = Get-Process -Id ([int]$oldTunnelPid) -ErrorAction SilentlyContinue

        if ($oldTunnelProcess -and $oldTunnelProcess.ProcessName -eq "cloudflared") {
            Write-Host "Stopping previous Cloudflare Tunnel..."
            Stop-Process -Id ([int]$oldTunnelPid) -Force
            Start-Sleep -Seconds 2
        }
    }
}

Remove-Item $tunnelLog, $tunnelError -Force -ErrorAction SilentlyContinue

# Cloudflare Tunnel起動
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

Set-Content $tunnelPidFile $tunnelProcess.Id

# Cloudflare URL取得
$httpsUrl = $null

Write-Host "Waiting for Cloudflare URL..."

for ($i = 0; $i -lt 60; $i++) {

    Start-Sleep -Seconds 1

    if ($tunnelProcess.HasExited) {
        throw "Cloudflare Tunnel stopped. Check tunnel-error.log"
    }

    $logs = ""

    foreach ($logFile in @($tunnelLog, $tunnelError)) {

        if (Test-Path $logFile) {
            $logs += Get-Content $logFile -Raw -ErrorAction SilentlyContinue
        }
    }

    $urlMatch = [regex]::Match(
        $logs,
        'https://[a-z0-9-]+\.trycloudflare\.com',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if ($urlMatch.Success) {
        $httpsUrl = $urlMatch.Value
        break
    }
}

if (!$httpsUrl) {
    throw "Could not get Cloudflare URL. Check tunnel.log"
}

$wsUrl = ($httpsUrl -replace '^https://', 'wss://') + "/"

Write-Host ""
Write-Host "Cloudflare URL: $httpsUrl"
Write-Host "WSS URL: $wsUrl"

# GitHub CLI確認
$ghCommand = Get-Command gh.exe -ErrorAction SilentlyContinue

if (!$ghCommand) {
    throw "GitHub CLI not found. Install GitHub CLI and add it to PATH."
}

$gh = $ghCommand.Definition

Write-Host ""
Write-Host "Checking GitHub login..."

& $gh auth status

if ($LASTEXITCODE -ne 0) {
    throw "GitHub login required. Run gh auth login first."
}

# GitHubからHTML取得
Write-Host "Fetching GitHub index.html..."

$fileJson = & $gh api "repos/$repo/contents/index.html?ref=$branch"

if ($LASTEXITCODE -ne 0) {
    throw "Could not fetch GitHub index.html"
}

$file = $fileJson | ConvertFrom-Json

if (!$file.content -or !$file.sha) {
    throw "GitHub file content or SHA is missing"
}

$bytes = [Convert]::FromBase64String(
    ($file.content -replace '\s', '')
)

$html = [System.Text.Encoding]::UTF8.GetString($bytes)

# WS_URLを1か所だけ変更
$pattern = "(?m)(const WS_URL\s*=\s*\r?\n\s*)'wss://[^']+';"

$regex = New-Object System.Text.RegularExpressions.Regex($pattern)

$urlMatches = $regex.Matches($html)

if ($urlMatches.Count -ne 1) {
    throw "WS_URL was not found exactly once. GitHub was not changed."
}

$evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
    param($m)

    return $m.Groups[1].Value + "'" + $wsUrl + "';"
}

$html = $regex.Replace($html, $evaluator, 1)

# GitHub更新用データ作成
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

Write-Host ""
Write-Host "=================================="
Write-Host " Startup completed"
Write-Host "=================================="
Write-Host "WSS URL: $wsUrl"
Write-Host "GitHub index.html updated."
Write-Host "Node.js and Cloudflare are running."
