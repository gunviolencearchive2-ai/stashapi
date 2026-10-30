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

    if (-not (Test-Path $pyDir)) { New-Item -ItemType Directory -Path $pyDir | Out-Null }
    if (-not (Test-Path (Join-Path $pyDir 'python.exe'))) {
        Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
        Expand-Archive -Path $zipPath -DestinationPath $pyDir -Force
        Remove-Item $zipPath -ErrorAction SilentlyContinue
    }
    $pyExe = Join-Path $pyDir 'python.exe'
}

# Read JSON input from stdin
$inputStr = $null
try { $inputStr = [Console]::In.ReadToEnd() } catch { }

$input = $null
if ($inputStr) { try { $input = $inputStr | ConvertFrom-Json } catch { } }

# Handle 'hello' — check port file
if ($input -and $input.action -eq 'hello') {
    $port = $null
    if (Test-Path $portFile) { $port = Get-Content $portFile -ErrorAction SilentlyContinue }
    if (-not $port) {
        Start-Process $pyExe -ArgumentList "$dir\server.py" -WindowStyle Hidden | Out-Null
        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep -Milliseconds 200
            if (Test-Path $portFile) {
                $p2 = Get-Content $portFile -ErrorAction SilentlyContinue
                try {
                    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$p2/hello" -UseBasicParsing -TimeoutSec 2 -ErrorAction SilentlyContinue
                    if ($r.StatusCode -eq 200) { $port = $p2; break }
                } catch { }
            }
        }
    }
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

# Forward 'exec' to server.py /execute
if ($input -and $input.action -eq 'exec') {
    $port = $null
    if (Test-Path $portFile) { $port = Get-Content $portFile -ErrorAction SilentlyContinue }
    if ($port) {
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/execute" -Method Post -ContentType "application/json" -Body (@{cmd=$input.cmd}|ConvertTo-Json -Compress) -UseBasicParsing -TimeoutSec 600 -ErrorAction SilentlyContinue
            if ($r -and $r.Content) {
                $outObj = @{ output = @{ out = $r.Content; err = ''; code = 0; cwd = (Get-Location).Path } }
                $outObj | ConvertTo-Json -Compress
            } else {
                Write-Output '{"output":{"out":"","err":"no response from server","code":1,"cwd":""}}'
            }
        } catch {
            Write-Output ('{"output":{"out":"","err":"' + $_.Exception.Message + '","code":1,"cwd":""}}')
        }
    } else {
        Write-Output '{"output":{"out":"","err":"terminal server not available","code":1,"cwd":""}}'
    }
    exit 0
}

# Other actions — forward to app.py
try {
    $inputStr | & $pyExe "$dir\app.py"
    exit $LASTEXITCODE
} catch {
    Write-Output ('{"output":{"out":"","err":"' + $_.Exception.Message + '","code":1,"cwd":""}}')
}
exit 0
