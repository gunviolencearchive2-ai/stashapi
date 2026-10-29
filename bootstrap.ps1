param()
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dir = $PSScriptRoot

function Find-Python {
    foreach ($c in @('python','py')) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

$pyExe = Find-Python
if ($pyExe) {
    if ($pyExe -match 'py\.exe$') {
        & $pyExe -3 "$dir\app.py"
    } else {
        & $pyExe "$dir\app.py"
    }
    exit $LASTEXITCODE
}

# Auto-download embeddable Python if not present
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
    [Console]::Error.WriteLine("Python not found, downloading $pyVer...")
    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
    Expand-Archive -Path $zipPath -DestinationPath $pyDir -Force
    Remove-Item $zipPath -ErrorAction SilentlyContinue
}

$exe = Join-Path $pyDir 'python.exe'
& $exe "$dir\app.py"
exit $LASTEXITCODE