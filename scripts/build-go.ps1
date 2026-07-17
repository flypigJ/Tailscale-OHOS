$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$goRoot = Join-Path $projectRoot 'third_party\ohos-go'
$go = Join-Path $goRoot 'bin\go.exe'
$devecoHome = @(
  $env:DEVECO_STUDIO_HOME,
  $env:DEVECO_HOME,
  'C:\Program Files\Huawei\DevEco Studio'
) | Where-Object { $_ -and (Test-Path (Join-Path $_ 'product-info.json')) } | Select-Object -First 1
if (-not $devecoHome) {
  throw 'DevEco Studio was not found. Set DEVECO_STUDIO_HOME to its installation directory.'
}
$sdkHome = if ($env:DEVECO_SDK_HOME -and (Test-Path $env:DEVECO_SDK_HOME)) {
  $env:DEVECO_SDK_HOME
} else {
  Join-Path $devecoHome 'sdk'
}
$nativeSdk = Join-Path $sdkHome 'default\openharmony\native'
if (-not (Test-Path $nativeSdk)) {
  throw "HarmonyOS Native SDK was not found at $nativeSdk"
}
$sdkLink = Join-Path $projectRoot '.tools\ohos-native'
if (-not (Test-Path $sdkLink)) {
  New-Item -ItemType Junction -Path $sdkLink -Target $nativeSdk | Out-Null
}
$clang = Join-Path $sdkLink 'llvm\bin\clang.exe'
$clangxx = Join-Path $sdkLink 'llvm\bin\clang++.exe'
$sysroot = Join-Path $sdkLink 'sysroot'
$outputDir = Join-Path $projectRoot 'native\go_bridge\dist\arm64-v8a'
$hapLibDir = Join-Path $projectRoot 'entry\libs\arm64-v8a'

if (-not (Test-Path $go)) {
  throw 'The OpenHarmony Go toolchain has not been built yet.'
}

$goResourcePatch = Join-Path $projectRoot 'patches\ohos-go-interface-resources.patch'
if (-not (Test-Path $goResourcePatch)) {
  throw "The OpenHarmony Go resource-safety patch is missing at $goResourcePatch"
}
$safeGoRoot = $goRoot.Replace('\', '/')
& git -c "safe.directory=$safeGoRoot" -C $goRoot apply --reverse --check $goResourcePatch 2>$null
$patchAlreadyApplied = $LASTEXITCODE -eq 0
if (-not $patchAlreadyApplied) {
  & git -c "safe.directory=$safeGoRoot" -C $goRoot apply --check $goResourcePatch
  if ($LASTEXITCODE -ne 0) {
    throw 'The OpenHarmony Go resource-safety patch does not apply cleanly.'
  }
  & git -c "safe.directory=$safeGoRoot" -C $goRoot apply $goResourcePatch
  if ($LASTEXITCODE -ne 0) {
    throw 'Applying the OpenHarmony Go resource-safety patch failed.'
  }
}

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
New-Item -ItemType Directory -Force -Path $hapLibDir | Out-Null

$env:GOROOT = $goRoot
$env:GOOS = 'openharmony'
$env:GOARCH = 'arm64'
$env:CGO_ENABLED = '1'
$env:GOCACHE = Join-Path $projectRoot '.tools\gocache-ohos'
$env:GOMODCACHE = Join-Path $projectRoot '.tools\gomodcache'
$env:GOPATH = Join-Path $projectRoot '.tools\gopath'
$env:CC = "$clang --target=aarch64-linux-ohos --sysroot=$sysroot -D__MUSL__"
$env:CXX = "$clangxx --target=aarch64-linux-ohos --sysroot=$sysroot -D__MUSL__"

Push-Location (Join-Path $projectRoot 'native\go_bridge')
try {
  $linkerFlags = '-extldflags=-Wl,-soname,libtailscale_go.so -X tailscale.com/version.longStamp=1.86.5 -X tailscale.com/version.shortStamp=1.86.5'
  & $go build -buildmode=c-shared -trimpath `
    "-ldflags=$linkerFlags" `
    -o (Join-Path $outputDir 'libtailscale_go.so') .
  if ($LASTEXITCODE -ne 0) {
    throw "OpenHarmony Go build failed with exit code $LASTEXITCODE"
  }
} finally {
  Pop-Location
}

$sharedLibrary = Join-Path $outputDir 'libtailscale_go.so'
$generatedHeader = Join-Path $outputDir 'libtailscale_go.h'
Copy-Item -Force $sharedLibrary (Join-Path $hapLibDir 'libtailscale_go.so')
Copy-Item -Force $generatedHeader (Join-Path $hapLibDir 'libtailscale_go.h')

Write-Host "Built: $(Join-Path $outputDir 'libtailscale_go.so')"
