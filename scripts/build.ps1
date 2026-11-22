param(
  [ValidateSet('default', 'release')]
  [string]$Product = 'default'
)

$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$targetApiLevel = '26'

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
  throw 'DevEco Studio was not found. Set DEVECO_STUDIO_HOME to its installation directory.'
}
$hvigorHome = Join-Path $devecoHome 'tools\hvigor\hvigor'
$hvigor = Join-Path $hvigorHome 'bin\hvigor.js'
$hvigorWrapper = Join-Path $devecoHome 'tools\hvigor\bin\hvigorw.js'
$javaHome = Join-Path $devecoHome 'jbr'
$sdkCandidates = @(
  $env:DEVECO_SDK_HOME,
  # Prefer the complete vendor distribution over locally assembled SDK copies.
  (Join-Path $devecoHome 'sdk'),
  (Join-Path $projectRoot '.tools\harmony-sdk-26-release'),
  (Join-Path $env:LOCALAPPDATA 'OpenHarmony\Sdk\26.0.0-release'),
  (Join-Path $env:LOCALAPPDATA 'OpenHarmony\Sdk\26.0.0'),
  (Join-Path $env:LOCALAPPDATA 'OpenHarmony\Sdk\26.0.0-release2')
) | Where-Object { $_ -and (Test-Path $_) }
$requiredSdkComponents = @('ets', 'js', 'native', 'previewer', 'toolchains')
$requiredHmsSdkComponents = @('ets', 'js', 'native', 'previewer', 'toolchains')
$sdkHome = $null
$sdkComponentMetadata = @{}
foreach ($candidate in $sdkCandidates | Select-Object -Unique) {
  $candidateMetadata = @{}
  $candidateIsValid = $true
  foreach ($component in $requiredSdkComponents) {
    $metadataCandidates = @(
      (Join-Path $candidate "$targetApiLevel\$component\oh-uni-package.json"),
      (Join-Path $candidate "$component\oh-uni-package.json"),
      (Join-Path $candidate "default\openharmony\$component\oh-uni-package.json")
    )
    $metadataPath = $metadataCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $metadataPath) {
      $candidateIsValid = $false
      break
    }
    $metadata = Get-Content -Raw $metadataPath | ConvertFrom-Json
    if ([int]$metadata.apiVersion -ne [int]$targetApiLevel -or
      $metadata.releaseType -ne 'Release') {
      $candidateIsValid = $false
      break
    }
    $candidateMetadata[$component] = $metadata
  }
  if ($candidateIsValid) {
    foreach ($component in $requiredHmsSdkComponents) {
      # Vendor HMS distributions use uni-package.json. Older assembled SDKs
      # may use the OpenHarmony metadata filename instead.
      $hmsMetadataCandidates = @(
        (Join-Path $candidate "default\hms\$component\uni-package.json"),
        (Join-Path $candidate "default\hms\$component\oh-uni-package.json")
      )
      $hmsMetadataPath = $hmsMetadataCandidates |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
      if (-not $hmsMetadataPath) {
        $candidateIsValid = $false
        break
      }
      $hmsMetadata = Get-Content -Raw $hmsMetadataPath | ConvertFrom-Json
      if ([int]$hmsMetadata.apiVersion -ne [int]$targetApiLevel -or
        $hmsMetadata.releaseType -ne 'Release') {
        $candidateIsValid = $false
        break
      }
      $candidateMetadata["hms-$component"] = $hmsMetadata
    }
  }
  if ($candidateIsValid) {
    $sdkHome = $candidate
    $sdkComponentMetadata = $candidateMetadata
    break
  }
}
if (-not $sdkHome) {
  throw "A complete HarmonyOS API $targetApiLevel $Product SDK with ETS/JS/Native/Previewer/Toolchains components was not found."
}
Write-Host "Using HarmonyOS SDK: $sdkHome"
$requiredSdkComponents | ForEach-Object {
  $metadata = $sdkComponentMetadata[$_]
  Write-Host "  $($_): $($metadata.version) $($metadata.releaseType)"
}
$requiredHmsSdkComponents | ForEach-Object {
  $metadata = $sdkComponentMetadata["hms-$_"]
  Write-Host "  hms-$($_): $($metadata.version) $($metadata.releaseType)"
}

if (-not (Test-Path $hvigor) -and -not (Test-Path $hvigorWrapper)) {
  throw "DevEco Hvigor was not found under $devecoHome"
}

if ($Product -eq 'release') {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $PSScriptRoot 'verify-release-changelog.ps1')
  if ($LASTEXITCODE -ne 0) {
    throw "Release changelog verification failed with exit code $LASTEXITCODE"
  }
}

$buildMode = if ($Product -eq 'release') { 'release' } else { 'debug' }
$debuggable = if ($Product -eq 'release') { 'false' } else { 'true' }

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
$env:DEVECO_STUDIO_HOME = $devecoHome
$env:DEVECO_SDK_HOME = $sdkHome
$env:OHOS_SDK_HOME = $sdkHome
$env:TAILSCALE_OHOS_TARGET_API_LEVEL = $targetApiLevel
$env:npm_config_registry = 'https://registry.npmjs.org/'
[Environment]::SetEnvironmentVariable(
  'npm_config_@ohos:registry',
  'https://repo.harmonyos.com/npm/',
  [EnvironmentVariableTarget]::Process
)
$env:HVIGOR_USER_HOME = Join-Path $PSScriptRoot '..\.hvigor-user'
$env:NODE_PATH = @(
  (Join-Path $PSScriptRoot '..\.tooling\node_modules'),
  (Join-Path $hvigorHome 'node_modules'),
  (Join-Path $devecoHome 'tools\hvigor\hvigor-ohos-plugin\node_modules')
) -join ';'

& node (Join-Path $PSScriptRoot 'update-runtime-fingerprint.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Diagnostic fingerprint generation failed' }

& node (Join-Path $PSScriptRoot 'verify-sdk-baseline.cjs') `
  (Join-Path $projectRoot 'build-profile.json5')
if ($LASTEXITCODE -ne 0) {
  throw 'API 26 SDK baseline verification failed.'
}

$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
$nativePowerShell = if ($pwshCmd) { $pwshCmd.Source } else { (Get-Command powershell.exe -ErrorAction Stop).Source }
& $nativePowerShell -NoProfile -ExecutionPolicy Bypass `
  -File (Join-Path $PSScriptRoot 'build-go.ps1')
if ($LASTEXITCODE -ne 0) {
  throw "OpenHarmony Go build failed with exit code $LASTEXITCODE"
}

$hvigorEntry = if (Test-Path $hvigorWrapper) { $hvigorWrapper } else { $hvigor }
if ($hvigorEntry -eq $hvigorWrapper) {
  # The wrapper loads the project's matching Hvigor/plugin dependency pair.
  # Injecting the IDE's engine through NODE_PATH can create a second singleton
  # and fail before PreBuild with "The root node is not yet available".
  Remove-Item Env:NODE_PATH -ErrorAction SilentlyContinue
}
& node $hvigorEntry --mode module -p module=entry@default -p product=$Product `
  -p buildMode=$buildMode -p debuggable=$debuggable assembleHap --no-daemon
if ($LASTEXITCODE -ne 0) {
  throw "Hvigor build failed with exit code $LASTEXITCODE"
}

if ($Product -eq 'release') {
  & node $hvigorEntry --mode project -p product=$Product `
    -p buildMode=$buildMode -p debuggable=$debuggable assembleApp --no-daemon
  if ($LASTEXITCODE -ne 0) {
    throw "Hvigor release assembleApp failed with exit code $LASTEXITCODE"
  }
}

$hapOutputDirectory = Join-Path $projectRoot "entry\build\$Product\outputs\default"
$haps = @('entry-default-signed.hap', 'entry-default-unsigned.hap') | ForEach-Object {
  $artifactPath = Join-Path $hapOutputDirectory $_
  if (Test-Path -LiteralPath $artifactPath) {
    Get-Item -LiteralPath $artifactPath
  }
}
if (-not $haps) {
  throw 'Build completed but no HAP artifact was found.'
}

$haps | ForEach-Object { Write-Host "Built: $($_.FullName)" }

if ($Product -eq 'release') {
  $appOutputDirectory = Join-Path $projectRoot "build\outputs\$Product"
  $signedApps = @(Get-ChildItem -LiteralPath $appOutputDirectory -Filter '*-signed.app' -File -ErrorAction SilentlyContinue)
  if ($signedApps.Count -eq 0) {
    throw "Release build completed but no signed .app artifact was found under $appOutputDirectory"
  }
  $signedApps | ForEach-Object { Write-Host "Built APP: $($_.FullName)" }
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File (Join-Path $PSScriptRoot 'verify-artifacts.ps1') -Product $Product
if ($LASTEXITCODE -ne 0) {
  throw "Artifact verification failed with exit code $LASTEXITCODE"
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File (Join-Path $PSScriptRoot 'export-apms-symbols.ps1') -Product $Product `
  -ReadElf (Join-Path $sdkHome 'default\openharmony\native\llvm\bin\llvm-readelf.exe')
if ($LASTEXITCODE -ne 0) {
  throw "APMS symbol archive failed with exit code $LASTEXITCODE"
}
