#requires -Version 5.1
$ErrorActionPreference='Stop'
$projectRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'engine-abi-checks.ps1')
$verifiedText=(& node (Join-Path $PSScriptRoot 'verify-engine-inputs.cjs')) -join "`n"
if($LASTEXITCODE -ne 0){throw 'Pinned engine inputs failed verification'}
$inputs=$verifiedText|ConvertFrom-Json
$goRoot=$inputs.goRoot;$go=Join-Path $goRoot 'bin/go.exe'
$devecoHome=@($env:DEVECO_STUDIO_HOME,$env:DEVECO_HOME,'C:/Program Files/Huawei/DevEco Studio')|
  Where-Object {$_ -and (Test-Path (Join-Path $_ 'product-info.json'))}|Select-Object -First 1
if(-not $devecoHome){throw 'Set DEVECO_STUDIO_HOME to DevEco Studio'}
$sdkHomes=@($env:DEVECO_SDK_HOME,(Join-Path $devecoHome 'sdk'))|Where-Object {$_ -and (Test-Path $_)}
$nativeSdk=@(foreach($sdkHome in $sdkHomes){(Join-Path $sdkHome 'default/openharmony/native');(Join-Path $sdkHome '26/native')})|Where-Object {Test-Path $_}|Select-Object -First 1
if(-not $nativeSdk){throw 'HarmonyOS native SDK missing'}
$sdkInfo=Get-Content -Raw (Join-Path $nativeSdk 'oh-uni-package.json')|ConvertFrom-Json
if($sdkInfo.apiVersion -ne 26 -or $sdkInfo.releaseType -cne 'Release' -or
  ($env:TAILSCALE_OHOS_TARGET_API_LEVEL -and $env:TAILSCALE_OHOS_TARGET_API_LEVEL -cne '26')){throw 'API 26 Release SDK required'}
$sdkLink=Join-Path $projectRoot '.tools/ohos-native'
if(Test-Path -LiteralPath $sdkLink){
  if([IO.Path]::GetFullPath([string](@((Get-Item -LiteralPath $sdkLink).Target)[0])) -cne [IO.Path]::GetFullPath($nativeSdk)){throw 'Existing native SDK link differs; refusing replacement'}
}else{New-Item -ItemType Junction -Path $sdkLink -Target $nativeSdk|Out-Null}
$bridge=Join-Path $projectRoot 'native/go_bridge'
$output=Join-Path $bridge 'dist/arm64-v8a';$hapLib=Join-Path $projectRoot 'entry/libs/arm64-v8a'
New-Item -ItemType Directory -Force -Path $output,$hapLib|Out-Null
$sources=@(Get-ChildItem -LiteralPath $bridge -File -Filter '*.go')+@(Get-ChildItem -LiteralPath (Join-Path $bridge 'vpnroute') -File -Filter '*.go')+@(Get-Item (Join-Path $bridge 'go.mod'),(Join-Path $bridge 'go.sum'))
$rootPrefix=[IO.Path]::GetFullPath($projectRoot).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
$sourceFiles=@($sources|ForEach-Object{
  $full=[IO.Path]::GetFullPath($_.FullName)
  $rel=if($full.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)){$full.Substring($rootPrefix.Length)}else{$full}
  @{path=$rel;sha256=(Get-FileHash -LiteralPath $full).Hash}
}|Sort-Object path)
$digestText=($sourceFiles|ForEach-Object{$_.path+':'+$_.sha256}) -join "`n"
$sha256Obj=[Security.Cryptography.SHA256]::Create()
try{$sourceDigest=([BitConverter]::ToString($sha256Obj.ComputeHash([Text.Encoding]::UTF8.GetBytes($digestText)))).Replace('-','')}finally{$sha256Obj.Dispose()}
$diagnosticId=$sourceDigest.ToLowerInvariant()
if($env:MESHARC_DIAGNOSTIC_SOURCE_ID){
  if($env:MESHARC_DIAGNOSTIC_SOURCE_ID -cnotmatch '^[a-f0-9]{64}$'){throw 'Invalid diagnostic source ID'}
  $diagnosticId=$env:MESHARC_DIAGNOSTIC_SOURCE_ID
}
$receipt=[ordered]@{schemaVersion=1;milestone='K7';status='building';inputs=$inputs;sdkVersion=$sdkInfo.version;
  sourceFiles=$sourceFiles;sourceDigest=$sourceDigest;diagnosticSourceId=$diagnosticId;startedAt=Get-Date -Format o;fixtureAbiExports=0}
$envMap=@{GOROOT=$goRoot;GOOS='openharmony';GOARCH='arm64';CGO_ENABLED='1';GOENV='off';GOTOOLCHAIN='local';GOWORK='off';GOFLAGS='';GOEXPERIMENT='';GOTOOLDIR=$null;
  GOCACHE=(Join-Path $projectRoot '.tools/gocache-go1.27.3');GOMODCACHE=(Join-Path $projectRoot '.tools/gomodcache-go1.27.3');
  CC="$(Join-Path $sdkLink 'llvm/bin/clang.exe') --target=aarch64-linux-ohos --sysroot=$(Join-Path $sdkLink 'sysroot') -D__MUSL__ -fstack-protector-strong";
  CXX="$(Join-Path $sdkLink 'llvm/bin/clang++.exe') --target=aarch64-linux-ohos --sysroot=$(Join-Path $sdkLink 'sysroot') -D__MUSL__ -fstack-protector-strong"}
$previous=@{};foreach($key in $envMap.Keys){$previous[$key]=[Environment]::GetEnvironmentVariable($key,'Process')}
try{
  foreach($key in $envMap.Keys){[Environment]::SetEnvironmentVariable($key,$envMap[$key],'Process')}
  $selected=((& $go -C $bridge list -m -json tailscale.com)-join "`n")|ConvertFrom-Json
  if($LASTEXITCODE -ne 0 -or $selected.Version -cne 'v1.104.5' -or [IO.Path]::GetFullPath($selected.Replace.Dir) -cne [IO.Path]::GetFullPath($inputs.vendorRoot)){throw 'Wrong selected Tailscale source'}
  $library=Join-Path $output 'libtailscale_go.so';$header=Join-Path $output 'libtailscale_go.h'
  $flags="-extldflags=-Wl,-soname,libtailscale_go.so,--build-id=sha1,-z,relro,-z,now,-z,noexecstack -X tailscale.com/version.longStamp=1.104.5 -X tailscale.com/version.shortStamp=1.104.5 -X main.pathDiagnosticBuild=$diagnosticId"
  & $go -C $bridge build -p 2 -mod=readonly -buildmode=c-shared -trimpath -buildvcs=false "-ldflags=$flags" -o $library .
  if($LASTEXITCODE -ne 0){throw 'Native engine compilation failed'}
  $metadata=(& $go version -m $library)-join "`n"
  if($LASTEXITCODE -ne 0 -or $metadata -notmatch ': go1\.27\.3' -or $metadata -notmatch 'tailscale.com\s+v1\.104\.5' -or $metadata -notmatch 'GOOS=openharmony' -or $metadata -notmatch 'GOARCH=arm64'){throw 'Engine metadata mismatch'}
  $receipt.productionAbiExports=Assert-EngineCAbi (Get-EngineSourceHeader $bridge) (Get-Content -Raw $header)
  if($receipt.productionAbiExports -ne 44){throw 'Unexpected production ABI (K0 41 + D1 query + D2 DNS runtime + live peer snapshot)'}
  foreach($file in $sourceFiles){if((Get-FileHash -LiteralPath (Join-Path $projectRoot $file.path)).Hash -cne $file.sha256){throw 'Bridge changed during build'}}
  $after=((& node (Join-Path $PSScriptRoot 'verify-engine-inputs.cjs'))-join "`n")|ConvertFrom-Json
  if($LASTEXITCODE -ne 0 -or $after.lockSha256 -cne $inputs.lockSha256){throw 'Engine inputs changed during build'}
  $receipt.librarySha256=(Get-FileHash $library).Hash;$receipt.headerSha256=(Get-FileHash $header).Hash
  $packed=Join-Path $output 'expected-packaged-engine.so'
  & (Join-Path $sdkLink 'llvm/bin/llvm-strip.exe') --strip-all -o $packed $library
  if($LASTEXITCODE -ne 0){throw 'Packaged engine transform failed'}
  $receipt.packagedLibrarySha256=(Get-FileHash $packed).Hash
  Copy-Item -LiteralPath $library,$header -Destination $hapLib
  $receipt.status='built';$metadata|Set-Content (Join-Path $output 'binary-metadata.log')
}catch{$receipt.status='failed';$receipt.failure=$_.Exception.Message;throw}
finally{
  foreach($key in $previous.Keys){[Environment]::SetEnvironmentVariable($key,$previous[$key],'Process')}
  $receipt.finishedAt=Get-Date -Format o
  $receipt|ConvertTo-Json -Depth 7|Set-Content (Join-Path $output 'engine-build.json') -Encoding utf8
}
Write-Host 'Built verified Tailscale 1.104.5 / Go 1.27.3 production engine (no probe ABI).'
