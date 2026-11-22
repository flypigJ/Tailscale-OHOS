function Assert-HdcCommandSucceeded {
  param(
    [int]$ExitCode,
    [AllowEmptyString()][string]$Output,
    [string]$Operation = 'command'
  )
  # HDC transport failures can be printed while its process still exits zero.
  $protocolFailure = $Output -match '(?m)^\s*(?:\[Fail\]|\[F\])'
  if ($ExitCode -eq 0 -and -not $protocolFailure) { return }
  $reason = if ($Output -match 'E001005|(?m)^\s*\[Fail\]Target device .+ not available') {
    'device unavailable'
  } else {
    "command failed (exit $ExitCode)"
  }
  throw "HDC $Operation failed: $reason."
}
