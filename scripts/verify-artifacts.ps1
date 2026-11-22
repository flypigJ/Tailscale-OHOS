param(
  [ValidateSet('default', 'release')]
  [string]$Product = 'default'
)

$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$installedDevEcoHomes = Get-ChildItem -Path (Join-Path $env:ProgramFiles 'Huawei') `
  -Directory -Filter 'DevEco Studio*' -ErrorAction SilentlyContinue | ForEach-Object {
    $_.FullName
    Join-Path $_.FullName 'DevEco Studio'
  }
$devecoCandidates = @(
  $env:DEVECO_STUDIO_HOME,
  $env:DEVECO_HOME,
  'C:\Program Files\Huawei\DevEco Studio'
) + @($installedDevEcoHomes)
$devecoHome = $devecoCandidates |
  Where-Object { $_ -and (Test-Path (Join-Path $_ 'product-info.json')) } | Select-Object -First 1
if (-not $devecoHome) {
  throw 'DevEco Studio was not found.'
}

$sdkCandidates = @(
  $env:DEVECO_SDK_HOME,
  (Join-Path $projectRoot '.tools\harmony-sdk-26-release'),
  (Join-Path $env:LOCALAPPDATA 'OpenHarmony\Sdk\26.0.0-release'),
  (Join-Path $env:LOCALAPPDATA 'OpenHarmony\Sdk\26.0.0'),
  (Join-Path $devecoHome 'sdk')
) | Where-Object { $_ -and (Test-Path $_) }
$sdkHome = $sdkCandidates | Select-Object -First 1
$targetApiLevel = $env:TAILSCALE_OHOS_TARGET_API_LEVEL
$readelfCandidates = @(
  $(if ($targetApiLevel) { Join-Path $sdkHome "$targetApiLevel\native\llvm\bin\llvm-readelf.exe" }),
  (Join-Path $sdkHome 'default\openharmony\native\llvm\bin\llvm-readelf.exe')
) | Where-Object { $_ }
$readelf = $readelfCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $readelf) {
  throw "llvm-readelf was not found under $sdkHome"
}
$goLibrary = Join-Path $projectRoot 'native\go_bridge\dist\arm64-v8a\libtailscale_go.so'
$hapOutputDirectory = Join-Path $projectRoot "entry\build\$Product\outputs\default"
$hapPath = @('entry-default-signed.hap', 'entry-default-unsigned.hap') | ForEach-Object {
  Join-Path $hapOutputDirectory $_
} | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$hap = if ($hapPath) { Get-Item -LiteralPath $hapPath } else { $null }

if (-not (Test-Path $goLibrary)) {
  throw 'The Go shared library is missing.'
}
if (-not $hap) {
  throw 'The HAP artifact is missing.'
}

function Assert-HardenedArm64SharedObject {
  param(
    [Parameter(Mandatory = $true)]
    [string]$BinaryPath,
    [Parameter(Mandatory = $true)]
    [string]$Label
  )
  $header = (& $readelf -h $BinaryPath) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $header -notmatch 'Machine:\s+AArch64' -or $header -notmatch 'Type:\s+DYN') {
    throw "$Label is not an AArch64 ELF shared object."
  }

  $programHeaders = (& $readelf -l -W $BinaryPath) -join "`n"
  if ($LASTEXITCODE -ne 0) {
    throw "Could not read ELF program headers for $Label."
  }
  if ($programHeaders -notmatch '\bGNU_RELRO\b') {
    throw "$Label is missing the GNU_RELRO segment."
  }
  $gnuStackLines = @($programHeaders -split "\r?\n" | Where-Object { $_ -match '^\s*GNU_STACK\b' })
  if ($gnuStackLines.Count -eq 0) {
    throw "$Label is missing the GNU_STACK segment."
  }
  foreach ($stackLine in $gnuStackLines) {
    if ($stackLine -match 'GNU_STACK.*RWE' -or $stackLine -match '\s+[RW]*E\s+0x[0-9a-fA-F]+\s*$') {
      throw "$Label has an executable stack: $stackLine"
    }
  }

  $dynamicSection = (& $readelf -d -W $BinaryPath) -join "`n"
  if ($LASTEXITCODE -ne 0) {
    throw "Could not read ELF dynamic section for $Label."
  }
  if ($dynamicSection -notmatch '\(BIND_NOW\)' -and
    $dynamicSection -notmatch '\(FLAGS\).*\bBIND_NOW\b' -and
    $dynamicSection -notmatch '\(FLAGS_1\).*\bNOW\b') {
    throw "$Label is missing full RELRO eager binding (BIND_NOW)."
  }
}

Assert-HardenedArm64SharedObject -BinaryPath $goLibrary -Label 'The Go library'

$dynamic = (& $readelf -d -W $goLibrary) -join "`n"
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

$tempExtractDir = Join-Path ([IO.Path]::GetTempPath()) ("tailscaleohos-verify-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempExtractDir | Out-Null
try {
  & tar -xf $hap.FullName -C $tempExtractDir 'libs/arm64-v8a/libtailscale_go.so' 'libs/arm64-v8a/libtailscale_ohos.so'
  if ($LASTEXITCODE -ne 0) {
    throw 'Failed to extract native shared libraries from HAP.'
  }
  foreach ($soEntry in @('libs/arm64-v8a/libtailscale_go.so', 'libs/arm64-v8a/libtailscale_ohos.so')) {
    $extractedSo = Join-Path $tempExtractDir ($soEntry -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $extractedSo)) {
      throw "Extracted HAP entry missing: $soEntry"
    }
    Assert-HardenedArm64SharedObject -BinaryPath $extractedSo -Label "HAP $soEntry"
  }
} finally {
  if ([IO.Directory]::Exists($tempExtractDir)) {
    [IO.Directory]::Delete($tempExtractDir, $true)
  }
}

$moduleJson = (tar -xOf $hap.FullName 'module.json') | ConvertFrom-Json
if ($moduleJson.app.apiReleaseType -ne 'Release') {
  throw "HAP uses a non-Release HarmonyOS API: $($moduleJson.app.apiReleaseType)"
}
if ($moduleJson.app.compileSdkVersion -match 'Beta|Canary') {
  throw "HAP compileSdkVersion is not a Release SDK: $($moduleJson.app.compileSdkVersion)"
}
if ($moduleJson.app.compileSdkVersion -notmatch '^26\.0\.0(?:\.|$)' -or
  [int]$moduleJson.app.minAPIVersion -ne 260000026 -or
  [int]$moduleJson.app.targetAPIVersion -ne 260000026) {
  throw 'HAP must compile, target and require HarmonyOS API 26.0.0.'
}

if ($Product -eq 'release') {
  if ($hap.Name -ne 'entry-default-signed.hap') {
    throw "Release verification requires signed HAP entry-default-signed.hap, got $($hap.Name)"
  }
  if ($moduleJson.app.debug -eq $true) {
    throw 'Release HAP must have app.debug = false.'
  }
  $appJson = Get-Content -Raw (Join-Path $projectRoot 'AppScope\app.json5') | ConvertFrom-Json
  if ([int64]$moduleJson.app.versionCode -ne [int64]$appJson.app.versionCode -or
    $moduleJson.app.versionName -ne $appJson.app.versionName) {
    throw "Release HAP version ($($moduleJson.app.versionName)/$($moduleJson.app.versionCode)) does not match AppScope/app.json5 ($($appJson.app.versionName)/$($appJson.app.versionCode))."
  }
  $appOutputDirectory = Join-Path $projectRoot 'build\outputs\release'
  $signedApp = Get-ChildItem -LiteralPath $appOutputDirectory -Filter '*-signed.app' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
  if (-not $signedApp) {
    throw "Signed release .app package was not found under $appOutputDirectory"
  }
  $appEntries = tar -tf $signedApp.FullName
  if ($appEntries -notcontains 'pack.info') {
    throw "Signed release .app is missing pack.info: $($signedApp.FullName)"
  }
  $packInfo = (tar -xOf $signedApp.FullName 'pack.info') | ConvertFrom-Json
  if ([int64]$packInfo.summary.app.version.code -ne [int64]$appJson.app.versionCode -or
    $packInfo.summary.app.version.name -ne $appJson.app.versionName) {
    throw "Signed release .app pack.info version ($($packInfo.summary.app.version.name)/$($packInfo.summary.app.version.code)) does not match AppScope/app.json5."
  }
  Write-Host "Verified signed release APP ($($packInfo.summary.app.version.name) / $($packInfo.summary.app.version.code)): $($signedApp.FullName)"
}

Write-Host "Verified $Product HAP using Release SDK $($moduleJson.app.compileSdkVersion), API 26-only, hardened AArch64 Go/N-API (RELRO/BIND_NOW/NX): $($hap.FullName)"
