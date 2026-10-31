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
        Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
        Expand-Archive -Path $zipPath -DestinationPath $pyDir -Force
        Remove-Item $zipPath -ErrorAction SilentlyContinue
    }
    $pyExe = Join-Path $pyDir 'python.exe'
}

# Read JSON input from stdin as raw bytes (UTF-8).
$payloadStr = $null
try {
    $ms = New-Object System.IO.MemoryStream
    [Console]::OpenStandardInput().CopyTo($ms)
    $payloadStr = [Text.Encoding]::UTF8.GetString($ms.ToArray())
} catch { }

# Hand the payload to app.py via an env var: environment values are UTF-16
# internally, so Cyrillic paths survive; piping strings through PowerShell
# would re-encode them into the OEM codepage and corrupt JSON.
$env:STASH_INPUT = $payloadStr
$env:PYTHONIOENCODING = 'utf-8'
& $pyExe (Join-Path $dir 'app.py')
exit $LASTEXITCODE
