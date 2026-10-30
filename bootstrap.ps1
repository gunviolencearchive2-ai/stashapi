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
$inputStr = $null
try {
    $inputStr = [console]::In.ReadToEnd()
} catch { }

$input = $null
if ($inputStr) {
    try { $input = $inputStr | ConvertFrom-Json } catch { }
}

# Handle 'hello' directly — return port info
if ($input -and $input.action -eq 'hello') {
    $output = @{
        output = @{
            cwd = (Get-Location).Path
            user = [Environment]::UserName
            host = [Environment]::MachineName
            os = [System.Environment]::OSVersion.VersionString
            platform = 'Windows'
            python = $pyExe
            sep = '\'
            drives = @()
            server_port = [int]$port
        }
    }
    $output | ConvertTo-Json -Compress
    exit 0
}

# Route actions
if ($input -and $input.action -eq 'exec') {
    # Terminal command — forward to server.py
    if ($port -and $serverUp) {
        try {
            $serverBody = @{ cmd = $input.cmd } | ConvertTo-Json -Compress
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/execute" -Method Post -ContentType "application/json" -Body $serverBody -UseBasicParsing -TimeoutSec 600 -ErrorAction SilentlyContinue
            if ($r) {
                $content = $r.Content
                if ($content) {
                    $outObj = @{
                        output = @{
                            out = $content
                            err = ''
                            code = 0
                            cwd = (Get-Location).Path
                        }
                    }
                    $outObj | ConvertTo-Json -Compress
                } else {
                    Write-Output '{"output":{"out":"","err":"","code":0,"cwd":""}}'
                }
            } else {
                Write-Output '{"output":{"out":"","err":"no response from server","code":1,"cwd":""}}'
            }
        } catch {
            Write-Output ('{"output":{"out":"","err":"' + $_.Exception.Message + '","code":1,"cwd":""}}')
        }
    } else {
        Write-Output '{"output":{"out":"","err":"terminal server not available","code":1,"cwd":""}}'
    }
} else {
    # Other actions (list, download, etc.) — forward to app.py
    try {
        $inputStr | & $pyExe "$dir\app.py"
        exit $LASTEXITCODE
    } catch {
        Write-Output ('{"output":{"out":"","err":"' + $_.Exception.Message + '","code":1,"cwd":""}}')
    }
}
exit 0
