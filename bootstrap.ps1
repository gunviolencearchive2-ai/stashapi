param()
$ErrorActionPreference = 'Continue'
$dir = $PSScriptRoot
$portFile = Join-Path $dir '.server_port'

function Find-Python {
    foreach ($c in @('python','py')) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

$pyExe = Find-Python
if (-not $pyExe) {
    $pyVer = '3.11.9'
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { 'win32' }
    $zipName = "python-$pyVer-embed-$arch.zip"
    $url = "https://www.python.org/ftp/python/$pyVer/$zipName"
    $pyDir = Join-Path $dir 'py'
    $zipPath = Join-Path $env:TEMP $zipName

    if (-not (Test-Path $pyDir)) {
        New-Item -ItemType Directory -Path $pyDir | Out-Null
    }
    if (-not (Test-Path (Join-Path $pyDir 'python.exe'))) {
        Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
        Expand-Archive -Path $zipPath -DestinationPath $pyDir -Force
        Remove-Item $zipPath -ErrorAction SilentlyContinue
    }
    $pyExe = Join-Path $pyDir 'python.exe'
}

# Ensure server.py is running
$port = $null
if (Test-Path $portFile) {
    $port = Get-Content $portFile -ErrorAction SilentlyContinue
}
$serverUp = $false
if ($port) {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/hello" -UseBasicParsing -TimeoutSec 2 -ErrorAction SilentlyContinue
        if ($r.StatusCode -eq 200) { $serverUp = $true }
    } catch { }
}
if (-not $serverUp) {
    Start-Process $pyExe -ArgumentList "$dir\server.py" -WindowStyle Hidden | Out-Null
    # Wait for server to come up
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 200
        if (Test-Path $portFile) {
            $p2 = Get-Content $portFile -ErrorAction SilentlyContinue
            try {
                $r = Invoke-WebRequest -Uri "http://127.0.0.1:$p2/hello" -UseBasicParsing -TimeoutSec 2 -ErrorAction SilentlyContinue
                if ($r.StatusCode -eq 200) { $serverUp = $true; $port = $p2; break }
            } catch { }
        }
    }
}

# Read JSON input from stdin (from Stash)
$input = $null
try {
    $input = [console]::In.ReadToEnd()
} catch { }

# Forward to server.py /execute and return response to stdout
if ($port -and $serverUp) {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/execute" -Method Post -ContentType "application/json" -Body $input -UseBasicParsing -TimeoutSec 600 -ErrorAction SilentlyContinue
        if ($r) {
            $content = $r.Content
            if ($content) { Write-Output $content }
        } else {
            Write-Output '{"output":{},"error":"no response from server"}'
        }
    } catch {
        Write-Output ('{"output":{},"error":"' + $_.Exception.Message + '"}')
    }
} else {
    Write-Output '{"output":{},"error":"terminal server not available"}'
}
exit 0
