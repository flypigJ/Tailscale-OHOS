$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$devecoHome = @(
  $env:DEVECO_STUDIO_HOME,
  $env:DEVECO_HOME,
  'C:\Program Files\Huawei\DevEco Studio'
) | Where-Object { $_ -and (Test-Path (Join-Path $_ 'product-info.json')) } | Select-Object -First 1
if (-not $devecoHome) {
  throw 'DevEco Studio was not found.'
}

$readelf = Join-Path $devecoHome 'sdk\default\openharmony\native\llvm\bin\llvm-readelf.exe'
$goLibrary = Join-Path $projectRoot 'native\go_bridge\dist\arm64-v8a\libtailscale_go.so'
$hap = Get-ChildItem -Path (Join-Path $projectRoot 'entry\build') -Recurse -Filter '*.hap' |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1

if (-not (Test-Path $goLibrary)) {
  throw 'The Go shared library is missing.'
}
if (-not $hap) {
  throw 'The HAP artifact is missing.'
}

$header = (& $readelf -h $goLibrary) -join "`n"
if ($header -notmatch 'Machine:\s+AArch64' -or $header -notmatch 'Type:\s+DYN') {
  throw 'The Go library is not an AArch64 ELF shared object.'
}

$dynamic = (& $readelf -d $goLibrary) -join "`n"
if ($dynamic -notmatch 'SONAME.*libtailscale_go\.so') {
  throw 'The Go library does not expose the expected SONAME.'
}

$hapEntries = tar -tf $hap.FullName
$requiredEntries = @(
  'libs/arm64-v8a/libtailscale_go.so',
  'libs/arm64-v8a/libtailscale_ohos.so',
  'ets/modules.abc',
  'module.json'
)
foreach ($entry in $requiredEntries) {
  if ($hapEntries -notcontains $entry) {
    throw "HAP is missing required entry: $entry"
  }
}

Write-Host "Verified AArch64 Go/N-API HAP: $($hap.FullName)"
