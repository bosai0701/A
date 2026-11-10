@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
"$root='C:\KyoshinServer'; ^
foreach($name in @('cloudflared','node')) { ^
$p=Join-Path $root ($name+'.pid'); ^
if(Test-Path $p) { ^
$id=Get-Content $p; ^
if($id -match '^\d+$') { Stop-Process -Id ([int]$id) -Force -ErrorAction SilentlyContinue }; ^
Remove-Item $p -Force -ErrorAction SilentlyContinue ^
} ^
}; ^
Write-Host 'Server and Tunnel stopped.'"
pause