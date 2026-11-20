<#
.SYNOPSIS
  Build the NSOnline Windows installer without make (PowerShell 5.1+ / 7).

.DESCRIPTION
  1. go generate ./backend/internal/secrets   (embeds .env, obfuscated)
  2. go build nsonline.exe with the version from app/pubspec.yaml
  3. flutter build windows --release
  4. copy the backend as nsonline-core.exe next to nsonline.exe
  5. iscc -> dist\NSOnline-<ver>-windows-x64-setup.exe

  Prerequisites: Go 1.22+, Flutter 3.x, Visual Studio 2022 ("Desktop development
  with C++"), Inno Setup 6.3+ (iscc.exe on PATH or in its default location).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File packaging\windows\build.ps1
  powershell -File packaging\windows\build.ps1 -SkipSecrets
#>
[CmdletBinding()]
param(
  [switch]$SkipSecrets,
  [switch]$SkipFlutter,
  [string]$Iscc = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$AppDir = Join-Path $Root "app"
$Dist = Join-Path $Root "dist"
$Release = Join-Path $AppDir "build\windows\x64\runner\Release"

function Invoke-Checked([string]$What, [scriptblock]$Block) {
  Write-Host "==> $What"
  & $Block
  if ($LASTEXITCODE -ne 0) { throw "$What failed (exit $LASTEXITCODE)" }
}

# Version: pubspec.yaml "version: 0.1.0+2" -> 0.1.0
$line = Select-String -Path (Join-Path $AppDir "pubspec.yaml") -Pattern '^version:\s*([^+\s]+)' | Select-Object -First 1
if (-not $line) { throw "could not read the version from app/pubspec.yaml" }
$Version = $line.Matches[0].Groups[1].Value
Write-Host "NSOnline $Version"

if (-not $SkipSecrets) {
  $envFile = if ($env:NSONLINE_ENV_FILE) { $env:NSONLINE_ENV_FILE } else { Join-Path $Root ".env" }
  if (-not (Test-Path $envFile)) {
    throw "$envFile not found. Run: Copy-Item .env.example .env  and fill in your own values (see CONTRIBUTING.md)."
  }
  Push-Location $Root
  try { Invoke-Checked "go generate (secrets)" { go generate ./backend/internal/secrets } } finally { Pop-Location }
}

$BackendOut = Join-Path $Root "build\backend\windows-amd64\nsonline.exe"
New-Item -ItemType Directory -Force -Path (Split-Path $BackendOut) | Out-Null
Push-Location $Root
try {
  $env:GOOS = "windows"; $env:GOARCH = "amd64"
  Invoke-Checked "go build nsonline.exe" {
    go build -trimpath -ldflags "-s -w -X nsonline/internal/version.Version=$Version" -o $BackendOut ./backend/cmd/nsonline
  }
} finally {
  Remove-Item Env:GOOS, Env:GOARCH -ErrorAction SilentlyContinue
  Pop-Location
}

if (-not $SkipFlutter) {
  Push-Location $AppDir
  try { Invoke-Checked "flutter build windows" { flutter build windows --release } } finally { Pop-Location }
}
if (-not (Test-Path (Join-Path $Release "nsonline.exe"))) { throw "nsonline.exe not found in $Release" }
Copy-Item -Force $BackendOut (Join-Path $Release "nsonline-core.exe")

if (-not $Iscc) {
  $cmd = Get-Command iscc.exe -ErrorAction SilentlyContinue
  if ($cmd) { $Iscc = $cmd.Source }
  else {
    foreach ($p in @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe")) {
      if (Test-Path $p) { $Iscc = $p; break }
    }
  }
}
if (-not $Iscc) { throw "ISCC.exe (Inno Setup 6) not found; pass -Iscc <path>" }

New-Item -ItemType Directory -Force -Path $Dist | Out-Null
Invoke-Checked "iscc" {
  & $Iscc "/DAppVersion=$Version" "/DBuildDir=$Release" "/O$Dist" (Join-Path $PSScriptRoot "nsonline.iss")
}

$Setup = Join-Path $Dist "NSOnline-$Version-windows-x64-setup.exe"
$hash = (Get-FileHash -Algorithm SHA256 $Setup).Hash.ToLower()
Write-Host "built $Setup"
Write-Host "$hash  $(Split-Path -Leaf $Setup)"
