param()
$ErrorActionPreference = 'Continue'
$dir = $PSScriptRoot

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

# Start server.py in background (detached), then exit so Stash considers the plugin loaded
Start-Process $pyExe -ArgumentList "$dir\server.py" -WindowStyle Hidden | Out-Null
exit 0
