$ErrorActionPreference = 'Stop'

$devecoHome = @(
  $env:DEVECO_STUDIO_HOME,
  $env:DEVECO_HOME,
  'C:\Program Files\Huawei\DevEco Studio'
) | Where-Object { $_ -and (Test-Path (Join-Path $_ 'product-info.json')) } | Select-Object -First 1
if (-not $devecoHome) {
  throw 'DevEco Studio was not found. Set DEVECO_STUDIO_HOME to its installation directory.'
}
$hvigorHome = Join-Path $devecoHome 'tools\hvigor\hvigor'
$hvigor = Join-Path $hvigorHome 'bin\hvigor.js'
$javaHome = Join-Path $devecoHome 'jbr'
$sdkHome = if ($env:DEVECO_SDK_HOME -and (Test-Path $env:DEVECO_SDK_HOME)) {
  $env:DEVECO_SDK_HOME
} else {
  Join-Path $devecoHome 'sdk'
}

if (-not (Test-Path $hvigor)) {
  throw "DevEco Hvigor was not found at $hvigor"
}

$toolingScope = Join-Path $PSScriptRoot '..\.tooling\node_modules\@ohos'
New-Item -ItemType Directory -Force -Path $toolingScope | Out-Null
$localHvigor = Join-Path $toolingScope 'hvigor'
$localOhosPlugin = Join-Path $toolingScope 'hvigor-ohos-plugin'
if (-not (Test-Path $localHvigor)) {
  New-Item -ItemType Junction -Path $localHvigor -Target $hvigorHome | Out-Null
}
if (-not (Test-Path $localOhosPlugin)) {
  New-Item -ItemType Junction -Path $localOhosPlugin `
    -Target (Join-Path $devecoHome 'tools\hvigor\hvigor-ohos-plugin') | Out-Null
}

$env:JAVA_HOME = $javaHome
$env:Path = (Join-Path $javaHome 'bin') + ';' + $env:Path
$env:DEVECO_SDK_HOME = $sdkHome
$env:OHOS_SDK_HOME = $sdkHome
$env:HVIGOR_USER_HOME = Join-Path $PSScriptRoot '..\.hvigor-user'
$env:NODE_PATH = @(
  (Join-Path $PSScriptRoot '..\.tooling\node_modules'),
  (Join-Path $hvigorHome 'node_modules'),
  (Join-Path $devecoHome 'tools\hvigor\hvigor-ohos-plugin\node_modules')
) -join ';'

& powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File (Join-Path $PSScriptRoot 'build-go.ps1')
if ($LASTEXITCODE -ne 0) {
  throw "OpenHarmony Go build failed with exit code $LASTEXITCODE"
}

& node $hvigor --mode module -p module=entry@default -p product=default assembleHap --no-daemon
if ($LASTEXITCODE -ne 0) {
  throw "Hvigor build failed with exit code $LASTEXITCODE"
}

$haps = Get-ChildItem -Path (Join-Path $PSScriptRoot '..\entry\build') -Recurse -Filter '*.hap'
if (-not $haps) {
  throw 'Build completed but no HAP artifact was found.'
}

$haps | ForEach-Object { Write-Host "Built: $($_.FullName)" }

& powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File (Join-Path $PSScriptRoot 'verify-artifacts.ps1')
if ($LASTEXITCODE -ne 0) {
  throw "Artifact verification failed with exit code $LASTEXITCODE"
}
