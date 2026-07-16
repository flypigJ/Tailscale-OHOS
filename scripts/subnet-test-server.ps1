param(
  [int]$Port = 38443,
  [string]$CountFile = ''
)

$ErrorActionPreference = 'Stop'
$requestCount = 0
if ($CountFile) {
  [System.IO.File]::WriteAllText($CountFile, '0')
}
$listener = [System.Net.Sockets.TcpListener]::new(
  [System.Net.IPAddress]::Any, $Port)
$listener.Start()

try {
  while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
      $client.ReceiveTimeout = 3000
      $stream = $client.GetStream()
      $buffer = New-Object byte[] 4096
      try {
        [void]$stream.Read($buffer, 0, $buffer.Length)
      } catch {
        # A complete request body is not required for this fixed response.
      }
      $body = "TailscaleOHOS subnet route probe OK`n"
      $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
      $headers = "HTTP/1.1 200 OK`r`nContent-Type: text/plain; charset=utf-8`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`nCache-Control: no-store`r`n`r`n"
      $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headers)
      $stream.Write($headerBytes, 0, $headerBytes.Length)
      $stream.Write($bodyBytes, 0, $bodyBytes.Length)
      $stream.Flush()
      $requestCount++
      if ($CountFile) {
        [System.IO.File]::WriteAllText($CountFile, [string]$requestCount)
      }
    } finally {
      $client.Close()
    }
  }
} finally {
  $listener.Stop()
}
