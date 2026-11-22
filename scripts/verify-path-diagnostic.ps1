param([Parameter(Mandatory=$true)][string]$Hap,
  [Parameter(Mandatory=$true)][string]$Manifest,
  [Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sdk = 'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony'
$java = 'C:\Program Files\Huawei\DevEco Studio\jbr\bin\java.exe'
$signTool = Join-Path $sdk 'toolchains\lib\hap-sign-tool.jar'
$readelf = Join-Path $sdk 'native\llvm\bin\llvm-readelf.exe'
$source = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$temporary = Join-Path $temporaryRoot ('mesharc-pathdiag-verify-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary | Out-Null
try {
  $chain = Join-Path $temporary 'chain.cer'; $profileFile = Join-Path $temporary 'profile.p7b'
  $signatureLog = (& $java -jar $signTool verify-app -inFile $Hap -outCertChain $chain -outProfile $profileFile 2>&1) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $signatureLog -notmatch 'verify.*success|verification.*success') {
    throw "Package signature verification did not confirm success: $signatureLog"
  }
  $profileResult = Join-Path $temporary 'profile-result.json'
  & $java -jar $signTool verify-profile -inFile $profileFile -outFile $profileResult | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Embedded profile verification failed.' }
  $verified = Get-Content -LiteralPath $profileResult -Raw | ConvertFrom-Json
  if (-not $verified.verifiedPassed) { throw 'Embedded profile verifier rejected profile.' }
  $profile = $verified.content
  if ($profile.type -ne 'release' -or $profile.'app-distribution-type' -ne 'app_gallery' -or
    $profile.'bundle-info'.'bundle-name' -ne 'io.github.tailscaleohos') { throw 'Unexpected distribution profile.' }
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  if ($now -lt $profile.validity.'not-before' -or $now -gt $profile.validity.'not-after') { throw 'Profile is outside its validity period.' }
  $expectedLeafPath = Join-Path $root 'certs\release\Tailscale OHOS Release.cer'
  $expectedLeaf = [Security.Cryptography.X509Certificates.X509Certificate2]::new($expectedLeafPath)
  $embeddedLeaf = [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($profile.'bundle-info'.'distribution-certificate')
  if ($expectedLeaf.Thumbprint -ne $embeddedLeaf.Thumbprint) { throw 'Profile does not match the approved Release certificate.' }
  $zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Hap).Path)
  try {
    $reader = [IO.StreamReader]::new($zip.GetEntry('module.json').Open())
    try { $module = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    if ($module.app.versionName -ne $source.versionName -or $module.app.versionCode -ne $source.versionCode -or
      $module.app.bundleName -ne 'io.github.tailscaleohos' -or $module.app.debug -ne $false -or
      $module.app.minAPIVersion -ne 260000026 -or $module.app.targetAPIVersion -ne 260000026) { throw 'HAP version/debug/API metadata mismatch.' }
    $hashes = @{}
    foreach ($name in @('libtailscale_go.so','libtailscale_ohos.so')) {
      $entry = $zip.GetEntry("libs/arm64-v8a/$name")
      if ($null -eq $entry) { throw "Missing $name" }
      $library = Join-Path $temporary $name
      $inputStream = $entry.Open(); $outputStream = [IO.File]::Create($library)
      try { $inputStream.CopyTo($outputStream) } finally { $inputStream.Dispose(); $outputStream.Dispose() }
      $header = (& $readelf -h $library) -join "`n"
      if ($LASTEXITCODE -ne 0 -or $header -notmatch 'Machine:\s+AArch64') { throw "Invalid ABI for $name" }
      $hashes[$name] = (Get-FileHash -LiteralPath $library -Algorithm SHA256).Hash.ToLowerInvariant()
      # Hvigor's Release DoNativeStrip uses --strip-all. Verify the exact
      # derivation from final unstripped Go/CMake output, not a raw-hash equality.
      $reference = if ($name -eq 'libtailscale_go.so') {
        Join-Path $root 'native\go_bridge\dist\arm64-v8a\libtailscale_go.so'
      } else {
        Join-Path $root 'entry\build\release\intermediates\cmake\default\obj\arm64-v8a\libtailscale_ohos.so'
      }
      $strippedReference = Join-Path $temporary ('expected-' + $name)
      & (Join-Path $sdk 'native\llvm\bin\llvm-strip.exe') --strip-all $reference -o $strippedReference
      if ($LASTEXITCODE -ne 0) { throw "Could not reproduce Release stripping for $name" }
      $referenceHash = (Get-FileHash -LiteralPath $strippedReference -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($hashes[$name] -ne $referenceHash) { throw "Packaged $name differs from stripped final build output." }
      if ($name -eq 'libtailscale_go.so') {
        $symbols = (& $readelf --dyn-syms -W $library) -join "`n"
        if ($symbols -notmatch '\bTSBackendPathDiagnostic\b') { throw 'Missing path diagnostic C ABI.' }
        & node -e 'const fs=require("node:fs");if(!fs.readFileSync(process.argv[1]).includes(Buffer.from(process.argv[2])))process.exit(1)' $library $source.sourceID
        if ($LASTEXITCODE -ne 0) { throw 'Source manifest stamp not present in packaged Go library.' }
      } else {
        & node -e 'const fs=require("node:fs");if(!fs.readFileSync(process.argv[1]).includes(Buffer.from("backendPathDiagnosticAsync")))process.exit(1)' $library
        if ($LASTEXITCODE -ne 0) { throw 'Missing diagnostic N-API binding.' }
      }
    }
  } finally { $zip.Dispose() }
  $result = [ordered]@{ schema=1; versionName=$module.app.versionName; versionCode=$module.app.versionCode;
    debug=$module.app.debug; bundle=$module.app.bundleName; minAPI=$module.app.minAPIVersion; targetAPI=$module.app.targetAPIVersion;
    abi='arm64-v8a'; profileType=$profile.type; distribution=$profile.'app-distribution-type';
    profileValidFrom=[DateTimeOffset]::FromUnixTimeSeconds($profile.validity.'not-before').ToString('u');
    profileValidUntil=[DateTimeOffset]::FromUnixTimeSeconds($profile.validity.'not-after').ToString('u');
    releaseCertificateMatches=$true; packageSignatureVerified=$true; embeddedProfileVerified=$true;
    packagedNativeMatchesStrippedBuildOutput=$true; stripping='llvm-strip --strip-all'; sourceID=$source.sourceID; nativeLibraries=$hashes;
    hapSHA256=(Get-FileHash -LiteralPath $Hap -Algorithm SHA256).Hash.ToLowerInvariant();
    bytes=(Get-Item -LiteralPath $Hap).Length; deviceTested=$false; directInstallGuaranteed=$false }
  [IO.File]::WriteAllText([IO.Path]::GetFullPath($Output), ($result | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
  Write-Output "Verified diagnostic Release HAP: $($result.hapSHA256)"
} finally {
  $resolved = [IO.Path]::GetFullPath($temporary)
  if ($resolved.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -and
    [IO.Path]::GetFileName($resolved).StartsWith('mesharc-pathdiag-verify-')) {
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
  }
}
