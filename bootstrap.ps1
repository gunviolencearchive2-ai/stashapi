param()
$ErrorActionPreference = 'Continue'
$dir = $PSScriptRoot
$portFile = Join-Path $dir '.server_port'
$debugLog = Join-Path $dir '.server_debug.log'

function Write-Dbg($msg) {
    try { Add-Content -Path $debugLog -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) -Encoding UTF8 } catch { }
}

function Find-Python {
    foreach ($c in @('python','py')) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

function Test-RealPython($exe) {
    # 'python' can be a Microsoft Store app-execution alias stub that
    # exits silently -- verify it actually executes code
    try {
        $null = & $exe -c "print(1)" 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

$pyExe = Find-Python
if ($pyExe -and -not (Test-RealPython $pyExe)) {
    Write-Dbg "python at $pyExe is a stub/broken -- falling back to embedded download"
    $pyExe = $null
}
if (-not $pyExe) {
    $pyVer = '3.11.9'
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { 'win32' }
    $zipName = "python-$pyVer-embed-$arch.zip"
    $url = "https://www.python.org/ftp/python/$pyVer/$zipName"
    $pyDir = Join-Path $dir 'py'
    $zipPath = Join-Path $env:TEMP $zipName

    if (-not (Test-Path $pyDir)) { New-Item -ItemType Directory -Path $pyDir | Out-Null }
    if (-not (Test-Path (Join-Path $pyDir 'python.exe'))) {
        Write-Dbg "downloading embedded python $pyVer"
        Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
        Expand-Archive -Path $zipPath -DestinationPath $pyDir -Force
        Remove-Item $zipPath -ErrorAction SilentlyContinue
    }
    $pyExe = Join-Path $pyDir 'python.exe'
}

# Read JSON input from stdin as raw bytes (UTF-8).
# [Console]::In would decode using the OEM codepage and corrupt UTF-8.
$payloadStr = $null
try {
    $ms = New-Object System.IO.MemoryStream
    [Console]::OpenStandardInput().CopyTo($ms)
    $payloadStr = [Text.Encoding]::UTF8.GetString($ms.ToArray())
} catch { }

$payload = $null
if ($payloadStr) {
    # strip UTF-8 BOM + whitespace (PowerShell piping prepends a BOM)
    $payloadStr = ($payloadStr -replace '^[\uFEFF\s]+', '').Trim()
    try { $payload = $payloadStr | ConvertFrom-Json } catch { }
}

# Stash wraps the operation args: {"server_connection":{...},"args":{...},...}
# Unwrap so $payload.action / $payload.cmd work like a direct call.
if ($payload -and $payload.PSObject.Properties['args'] -and $payload.args) {
    $payload = $payload.args
}

# Handle 'hello' -- return a LIVE server port (start server if needed)
if ($payload -and "$($payload.action)" -eq 'hello') {
    function Test-Port($p) {
        if (-not $p) { return $false }
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$p/hello" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            return ($r.StatusCode -eq 200)
        } catch { return $false }
    }

    $port = $null
    if (Test-Path $portFile) { $port = Get-Content $portFile -ErrorAction SilentlyContinue }
    if (-not (Test-Port $port)) {
        # stale or missing -- remove file and (re)start the server
        Remove-Item $portFile -Force -ErrorAction SilentlyContinue
        $port = $null
        Write-Dbg "starting server: $pyExe server.py"
        # stderr goes to the debug log so remote start failures are visible
        Start-Process $pyExe -ArgumentList "`"$dir\server.py`"" -WorkingDirectory $dir -WindowStyle Hidden | Out-Null
        for ($i = 0; $i -lt 25; $i++) {
            Start-Sleep -Milliseconds 200
            if (Test-Path $portFile) {
                $p2 = Get-Content $portFile -ErrorAction SilentlyContinue
                if (Test-Port $p2) { $port = $p2; break }
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
if ($payload -and $payload.action -eq 'exec') {
    $port = $null
    if (Test-Path $portFile) { $port = Get-Content $portFile -ErrorAction SilentlyContinue }
    if ($port) {
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/execute" -Method Post -ContentType "application/json" -Body (@{cmd=$payload.cmd}|ConvertTo-Json -Compress) -UseBasicParsing -TimeoutSec 600 -ErrorAction SilentlyContinue
            if ($r) {
                # decode manually: PS 5.1 IWR mis-decodes text/plain bodies
                # (cp866 shell output became cp1251 mojibake)
                $text = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
                # empty output is valid: commands like 'start notepad' print nothing
                $outObj = @{ output = @{ out = $text; err = ''; code = 0; cwd = (Get-Location).Path } }
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

# Other actions -- forward to app.py
try {
    $payloadStr | & $pyExe "$dir\app.py"
    exit $LASTEXITCODE
} catch {
    Write-Output ('{"output":{"out":"","err":"' + $_.Exception.Message + '","code":1,"cwd":""}}')
}
exit 0
