#requires -Version 7.0
param([Parameter(Mandatory)][string]$ToolchainRoot,
  [string]$VendorRepository='https://github.com/tailscale/tailscale.git',
  [string]$VendorDestination='')
$ErrorActionPreference='Stop'
$project=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$toolchain=(Resolve-Path -LiteralPath $ToolchainRoot).Path
$lock=Get-Content -Raw (Join-Path $project 'native/engine-lock.json')|ConvertFrom-Json
if(-not $VendorDestination){$VendorDestination=$lock.vendorRoot}
$destination=[IO.Path]::GetFullPath((Join-Path $project $VendorDestination))
if(-not $destination.StartsWith($project+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Engine destination must remain in this workspace'}
foreach($file in $lock.inputs){if((Get-FileHash -LiteralPath (Join-Path $project $file.path)).Hash -cne $file.sha256){throw 'Locked input changed'}}
$k2=Get-Content -Raw (Join-Path $project 'patches/experimental/k2-engine-manifest.json')|ConvertFrom-Json
$k4=Get-Content -Raw (Join-Path $project 'patches/experimental/k4-cold-peer-manifest.json')|ConvertFrom-Json
if(-not(Test-Path -LiteralPath $destination)){
  & git clone --quiet --no-hardlinks --no-checkout $VendorRepository $destination
  if($LASTEXITCODE -ne 0){throw 'Cannot clone vendor source'}
  & git -C $destination config core.autocrlf false
  & git -C $destination config core.longpaths true
  & git -C $destination checkout --quiet --detach $k2.upstreamCommit
  if($LASTEXITCODE -ne 0){throw 'Pinned upstream commit missing'}
  & git -C $destination apply --index (Join-Path $project 'patches/experimental/tailscale-v1.104.5-ohos.patch')
  if($LASTEXITCODE -ne 0){throw 'Reviewed platform patch did not apply'}
  $tree=(& git -C $destination write-tree).Trim()
  if($LASTEXITCODE -ne 0 -or $tree -cne $lock.vendorBaselineTree){throw 'Replayed platform source tree differs'}
  & git -C $destination -c user.name='MeshArc source replay' -c user.email='replay@localhost' -c commit.gpgsign=false commit -q -m 'Reviewed Tailscale 1.104.5 platform baseline'
  if($LASTEXITCODE -ne 0){throw 'Cannot freeze dependency baseline'}
  & git -C $destination apply --index (Join-Path $project $k4.patch.path)
  if($LASTEXITCODE -ne 0){throw 'Reviewed cold-peer fix did not apply'}
  foreach($extraPatch in $lock.additionalVendorPatches){
    & git -C $destination apply --index (Join-Path $project $extraPatch)
    if($LASTEXITCODE -ne 0){throw 'Reviewed incremental engine patch did not apply'}
  }
}
$result=((& node (Join-Path $PSScriptRoot 'verify-engine-inputs.cjs') --go-root $toolchain --vendor-root $destination)-join "`n")
if($LASTEXITCODE -ne 0){throw 'Prepared inputs did not pass the normal build gate'}
$link=Join-Path $project $lock.toolchainRoot
if(-not(Test-Path -LiteralPath $link)){New-Item -ItemType Junction -Path $link -Target $toolchain|Out-Null}
else{
  $existing=(Get-Item -LiteralPath $link).Target
  if($existing -and [IO.Path]::GetFullPath([string]$existing) -cne $toolchain -and [IO.Path]::GetFullPath($link) -cne $toolchain){throw 'Existing toolchain link differs; refusing replacement'}
}
Write-Output $result
