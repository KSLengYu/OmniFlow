$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$WinDir = Join-Path $Root "win"
$WorkDir = Join-Path $Root "installer\build\win"
$OutDir = Join-Path $Root "dist"
$Staging = Join-Path $WorkDir "payload"

if (Test-Path $WorkDir) { Remove-Item -Recurse -Force $WorkDir }
New-Item -ItemType Directory -Force -Path $Staging, $OutDir | Out-Null

Write-Host "==> Building OmniFlow Release x64..."
Push-Location $WinDir
try {
    dotnet build "OmniFlow.csproj" -c Release -o $Staging --nologo
    if ($LASTEXITCODE -ne 0) { throw "dotnet build failed" }
} finally {
    Pop-Location
}

# Remove PDB debug symbols from installer payload to keep setup tiny
Get-ChildItem $Staging -Filter "*.pdb" | Remove-Item -Force -ErrorAction SilentlyContinue

# Include WinUSB/Wintun runtime helpers if available adjacent in C:\OmniFlow or win\
foreach ($extra in @("omniflow-usb.exe", "omniflow-restore.exe", "wintun.dll")) {
    $cand1 = Join-Path $WinDir $extra
    $cand2 = Join-Path "C:\OmniFlow" $extra
    if (Test-Path $cand1) { Copy-Item $cand1 $Staging -Force }
    elseif (Test-Path $cand2) { Copy-Item $cand2 $Staging -Force }
}

Write-Host "==> Compressing payload via LZX CAB..."
$DdfPath = Join-Path $WorkDir "payload.ddf"
$CabName = "omniflow_payload.cab"
$lines = @(
    ".OPTION EXPLICIT",
    ".Set CabinetNameTemplate=$CabName",
    ".Set DiskDirectoryTemplate=$WorkDir",
    ".Set CompressionType=LZX",
    ".Set CompressionMemory=21",
    ".Set Cabinet=ON",
    ".Set Compress=ON",
    ".Set UniqueFiles=OFF"
)
Get-ChildItem $Staging -File | ForEach-Object {
    $lines += "`"$($_.FullName)`""
}
Set-Content -Path $DdfPath -Value $lines -Encoding ASCII
Push-Location $WorkDir
try {
    & makecab.exe /V0 /F $DdfPath | Out-Null
} finally {
    Pop-Location
}

Copy-Item (Join-Path $PSScriptRoot "omniflow_setup.cpp") $WorkDir -Force
Copy-Item (Join-Path $PSScriptRoot "setup.rc") $WorkDir -Force
Copy-Item (Join-Path $PSScriptRoot "setup.manifest") $WorkDir -Force
Copy-Item (Join-Path $WinDir "app.ico") $WorkDir -Force
Copy-Item (Join-Path $Root "assets\github_avatar.jpg") (Join-Path $WorkDir "github_avatar.jpg") -Force

$MingwBin = $env:MINGW_BIN
if ([string]::IsNullOrWhiteSpace($MingwBin)) {
    $gxxCmd = Get-Command g++.exe -ErrorAction SilentlyContinue
    if ($gxxCmd) {
        $MingwBin = Split-Path -Parent $gxxCmd.Source
    } else {
        foreach ($cand in @("C:\msys64\mingw64\bin", "C:\mingw64\bin", (Join-Path $env:USERPROFILE "Desktop\mingw64\bin"))) {
            if (Test-Path (Join-Path $cand "g++.exe")) { $MingwBin = $cand; break }
        }
    }
}
if ([string]::IsNullOrWhiteSpace($MingwBin) -or !(Test-Path (Join-Path $MingwBin "g++.exe"))) {
    throw "MinGW-w64 (g++.exe / windres.exe) not found. Add it to PATH or set MINGW_BIN."
}
$Windres = Join-Path $MingwBin "windres.exe"
$Gxx = Join-Path $MingwBin "g++.exe"
$OutExe = Join-Path $OutDir "OmniFlow-Windows-Setup.exe"

Write-Host "==> Compiling native tiny Win32 GUI setup..."
Push-Location $WorkDir
try {
    & $Windres "setup.rc" -O coff -o "setup_res.o"
    if ($LASTEXITCODE -ne 0) { throw "windres failed" }
    & $Gxx -std=c++17 -O2 -Os -s -DUNICODE -D_UNICODE -municode -mwindows `
        "omniflow_setup.cpp" "setup_res.o" -o $OutExe `
        -static-libgcc -static-libstdc++ `
        -lgdiplus -lsetupapi -lwinhttp -lcomctl32 -lshell32 -lshlwapi -lole32 -luuid
    if ($LASTEXITCODE -ne 0) { throw "g++ link failed" }
} finally {
    Pop-Location
}

Get-Item $OutExe | Select-Object FullName, Length
