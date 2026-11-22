function Get-EngineCDeclarations {
  param([Parameter(Mandatory)][string]$Header)
  $declarations = @($Header -split '\r?\n' | Where-Object { $_ -match '^extern .*\bTS\w+\(' } |
    ForEach-Object { $_.Trim().Replace('(void)', '()') } | Sort-Object)
  $names = @($declarations | ForEach-Object { [regex]::Match($_, '\b(TS\w+)\(').Groups[1].Value })
  if ($names.Count -eq 0 -or @($names | Sort-Object -Unique).Count -ne $names.Count) {
    throw 'Missing or duplicate engine C declarations'
  }
  return $declarations
}

function Get-EngineSourceHeader {
  param([Parameter(Mandatory)][string]$BridgeRoot)
  # Read source, not a possibly stale generated header. Fail closed when a new
  # export uses a C type this small contract reader does not yet understand.
  $declarations = @()
  foreach ($file in (Get-ChildItem -LiteralPath $BridgeRoot -File -Filter '*.go' | Sort-Object Name)) {
    if ($file.Name -like '*_test.go') { continue }
    $source = [IO.File]::ReadAllText($file.FullName)
    $exports = [regex]::Matches($source, '(?m)^//export (TS\w+)\r?$')
    foreach ($export in $exports) {
      $name = $export.Groups[1].Value
      $signature = [regex]::Match($source.Substring($export.Index + $export.Length),
        '^\s*func ' + [regex]::Escape($name) + '\(([^)]*)\)\s*([^\{]*)\{')
      if (-not $signature.Success) { throw "Cannot read Go export: $name" }
      $parameters = @()
      foreach ($parameter in ($signature.Groups[1].Value -split ',')) {
        if (-not $parameter.Trim()) { continue }
        $match = [regex]::Match($parameter.Trim(), '^(\w+)\s+(\*C\.char|C\.int)$')
        if (-not $match.Success) { throw "Unsupported Go export parameter: $name" }
        $type = if ($match.Groups[2].Value -ceq '*C.char') { 'char*' } else { 'int' }
        $parameters += "$type $($match.Groups[1].Value)"
      }
      $result = $signature.Groups[2].Value.Trim()
      if (-not $result) { $returnType = 'void' }
      elseif ($result -ceq '*C.char' -or $result -match '^\(\w+\s+\*C\.char\)$') { $returnType = 'char*' }
      else { throw "Unsupported Go export return type: $name" }
      $declarations += "extern $returnType $name($($parameters -join ', '));"
    }
  }
  return (Get-EngineCDeclarations -Header ($declarations -join "`n")) -join "`n"
}

function Assert-EngineCAbi {
  param([Parameter(Mandatory)][string]$ExpectedHeader, [Parameter(Mandatory)][string]$ActualHeader)
  $expected = @(Get-EngineCDeclarations -Header $ExpectedHeader)
  $actual = @(Get-EngineCDeclarations -Header $ActualHeader)
  if ($expected.Count -eq 0 -or ($expected -join "`n") -cne ($actual -join "`n")) {
    throw 'The generated C ABI differs from the existing application contract'
  }
  return $actual.Count
}
