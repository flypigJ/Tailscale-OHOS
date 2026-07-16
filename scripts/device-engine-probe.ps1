param(
  [string]$ArtifactDir = '',
  [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$devecoHome = @(
  $env:DEVECO_STUDIO_HOME,
  $env:DEVECO_HOME,
  'C:\Program Files\Huawei\DevEco Studio'
) | Where-Object { $_ -and (Test-Path (Join-Path $_ 'product-info.json')) } |
  Select-Object -First 1
if (-not $devecoHome) {
  throw 'DevEco Studio was not found.'
}

$hdc = Join-Path $devecoHome 'sdk\default\openharmony\toolchains\hdc.exe'
$usbTargets = & $hdc list targets -v |
  Where-Object { $_ -match "`t`tUSB`tConnected`t" }
if (@($usbTargets).Count -ne 1) {
  throw 'Expected exactly one connected USB target.'
}
$target = ($usbTargets -split "`t")[0]

if (-not $ArtifactDir) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $ArtifactDir = Join-Path $projectRoot ".hvigor\outputs\engine-probe-$stamp"
}
New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null

$hap = Join-Path $projectRoot 'entry\build\default\outputs\default\entry-default-signed.hap'
if (-not $SkipInstall) {
  if (-not (Test-Path $hap)) {
    throw 'The signed HAP is missing. Run scripts/build.ps1 first.'
  }
  & $hdc -t $target install -r $hap | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "HAP install failed with exit code $LASTEXITCODE"
  }
}

& $hdc -t $target shell aa start -b io.github.tailscaleohos -a EntryAbility | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Ability start failed with exit code $LASTEXITCODE"
}
Start-Sleep -Seconds 2

function Receive-Layout([string]$Name) {
  $remote = "/data/local/tmp/tailscaleohos-$Name.json"
  $local = Join-Path $ArtifactDir "$Name.json"
  & $hdc -t $target shell uitest dumpLayout -p $remote | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Layout capture failed with exit code $LASTEXITCODE"
  }
  & $hdc -t $target file recv $remote $local | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Layout receive failed with exit code $LASTEXITCODE"
  }
  & $hdc -t $target shell rm -f $remote | Out-Null
  return $local
}

$beforePath = Receive-Layout 'before'
$before = Get-Content -Raw $beforePath
foreach ($marker in @('Go go1.24.5', 'openharmony/arm64', 'engine-probe')) {
  if (-not $before.Contains($marker)) {
    throw "Baseline layout is missing marker: $marker"
  }
}

$bounds = [regex]::Match(
  $before,
  'id":"engine-probe".{0,900}?origBounds":"\[(\d+),(\d+)\]\[(\d+),(\d+)\]"'
)
if (-not $bounds.Success) {
  throw 'Could not resolve the engine probe button bounds.'
}
$x = [int](($bounds.Groups[1].ValueAsInt64 + $bounds.Groups[3].ValueAsInt64) / 2)
$y = [int](($bounds.Groups[2].ValueAsInt64 + $bounds.Groups[4].ValueAsInt64) / 2)
& $hdc -t $target shell uitest uiInput click $x $y | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Engine probe tap failed with exit code $LASTEXITCODE"
}
Start-Sleep -Seconds 1

$appPid = & $hdc -t $target shell pidof io.github.tailscaleohos
if ($appPid -notmatch '\d') {
  throw 'The application process exited during the engine probe.'
}

$afterPath = Receive-Layout 'after'
$after = Get-Content -Raw $afterPath
foreach ($marker in @('Tailscale 1.86.5', 'userspace engine initialized')) {
  if (-not $after.Contains($marker)) {
    throw "Engine probe layout is missing marker: $marker"
  }
}

[PSCustomObject]@{
  Result = 'passed'
  Runtime = 'openharmony/arm64 Go 1.24.5'
  Tailscale = '1.86.5'
  Probe = 'userspace engine initialized'
  ArtifactDir = (Resolve-Path $ArtifactDir).Path
}
