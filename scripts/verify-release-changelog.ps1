$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$changelogPath = Join-Path $projectRoot 'entry\src\main\ets\services\ReleaseChangelog.ets'
$appJsonPath = Join-Path $projectRoot 'AppScope\app.json5'

if (-not (Test-Path $changelogPath)) {
  throw "Release changelog entry is missing: $changelogPath"
}
if (-not (Test-Path $appJsonPath)) {
  throw "App metadata is missing: $appJsonPath"
}

$changelog = Get-Content -Raw -Encoding UTF8 $changelogPath
$appJson = Get-Content -Raw -Encoding UTF8 $appJsonPath
$appVersionMatch = [regex]::Match($appJson, '"versionName"\s*:\s*"([^"]+)"')
$appCodeMatch = [regex]::Match($appJson, '"versionCode"\s*:\s*(\d+)')
if (-not $appVersionMatch.Success -or -not $appCodeMatch.Success) {
  throw 'AppScope/app.json5 must define versionName and versionCode.'
}

$entryListMarker = 'export const RELEASE_CHANGELOG_ENTRIES'
$entryListStart = $changelog.IndexOf($entryListMarker, [StringComparison]::Ordinal)
if ($entryListStart -lt 0) {
  throw "Release changelog entry list is missing: $entryListMarker"
}
$firstObjectStart = $changelog.IndexOf('{', $entryListStart)
$firstObjectEnd = $changelog.IndexOf('},', $firstObjectStart)
if ($firstObjectStart -lt 0 -or $firstObjectEnd -lt 0) {
  throw 'Release changelog must contain a first entry.'
}
$firstEntry = $changelog.Substring($firstObjectStart, $firstObjectEnd - $firstObjectStart)

$sourceVersionMatch = [regex]::Match($firstEntry, "versionName\s*:\s*'([^']+)'")
$sourceCodeMatch = [regex]::Match($firstEntry, 'versionCode\s*:\s*(\d+)')
if (-not $sourceVersionMatch.Success -or -not $sourceCodeMatch.Success) {
  throw 'The first release changelog entry must define versionName and versionCode.'
}

$appVersion = $appVersionMatch.Groups[1].Value
$appCode = [int64]$appCodeMatch.Groups[1].Value
$sourceVersion = $sourceVersionMatch.Groups[1].Value
$sourceCode = [int64]$sourceCodeMatch.Groups[1].Value
if ($appVersion -notmatch '^\d+\.\d+\.\d+$') {
  throw "App versionName must use X.Y.Z form, got '$appVersion'."
}
if ($appVersion -ne $sourceVersion -or $appCode -ne $sourceCode) {
  throw "Release changelog does not match AppScope/app.json5. App=$appVersion/$appCode, changelog=$sourceVersion/$sourceCode."
}

function Assert-NonEmptyStringField {
  param([string]$Entry, [string]$FieldName)

  $match = [regex]::Match($Entry, "(?s)$FieldName\s*:\s*'([^']*)'")
  if (-not $match.Success -or [string]::IsNullOrWhiteSpace($match.Groups[1].Value)) {
    throw "The first release changelog entry must fill $FieldName."
  }
}

function Assert-NonEmptyStringArrayField {
  param([string]$Entry, [string]$FieldName)

  $arrayMatch = [regex]::Match($Entry, "(?s)$FieldName\s*:\s*\[(.*?)\]")
  if (-not $arrayMatch.Success) {
    throw "The first release changelog entry must define $FieldName."
  }
  $items = [regex]::Matches($arrayMatch.Groups[1].Value, "'([^']*)'")
  if ($items.Count -eq 0) {
    throw "The first release changelog entry must contain at least one item in $FieldName."
  }
  foreach ($item in $items) {
    $value = $item.Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($value) -or $value -match '(?i)TODO|TBD') {
      throw "The first release changelog entry contains an empty placeholder in $FieldName."
    }
  }
}

Assert-NonEmptyStringField -Entry $firstEntry -FieldName 'releaseDateZh'
Assert-NonEmptyStringField -Entry $firstEntry -FieldName 'releaseDateEn'
Assert-NonEmptyStringArrayField -Entry $firstEntry -FieldName 'changesZh'
Assert-NonEmptyStringArrayField -Entry $firstEntry -FieldName 'changesEn'

Write-Host "Release changelog verified: v$sourceVersion (versionCode $sourceCode)"
