# Review Insight - Local HTTP Server with API Proxy
# Usage: powershell -ExecutionPolicy Bypass -File serve.ps1

$port = 8765
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Review Insight - Local Server" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  URL: http://localhost:$port" -ForegroundColor Green
Write-Host "  API Proxy: /api/proxy -> api.anthropic.com" -ForegroundColor Gray
Write-Host "  Press Ctrl+C to stop" -ForegroundColor Yellow
Write-Host ""

# Start browser
Start-Process "http://localhost:$port"

# Create HTTP listener
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")

$mimeTypes = @{
    ".html" = "text/html; charset=utf-8"
    ".css"  = "text/css; charset=utf-8"
    ".js"   = "application/javascript; charset=utf-8"
    ".json" = "application/json; charset=utf-8"
    ".txt"  = "text/plain; charset=utf-8"
    ".png"  = "image/png"
    ".jpg"  = "image/jpeg"
    ".svg"  = "image/svg+xml"
    ".ico"  = "image/x-icon"
}

try {
    $listener.Start()
    Write-Host "  Server started, waiting for requests..." -ForegroundColor Gray

    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        $requestPath = $request.Url.AbsolutePath

        # ===== API Proxy: forward to DeepSeek / Anthropic =====
        if ($requestPath -eq "/api/proxy" -and $request.HttpMethod -eq "POST") {
            try {
                # Read the incoming request body (force UTF-8 to avoid encoding corruption)
                $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
                $requestBody = $reader.ReadToEnd()
                $reader.Close()

                # Get API key from custom header
                $apiKey = $request.Headers["x-local-api-key"]
                # Which API provider to use
                $provider = $request.Headers["x-api-provider"]
                if (-not $provider) { $provider = "deepseek" }

                if (-not $apiKey) {
                    $response.StatusCode = 400
                    $msg = [System.Text.Encoding]::UTF8.GetBytes('{"error":{"message":"Missing x-local-api-key header"}}')
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $msg.Length
                    $response.OutputStream.Write($msg, 0, $msg.Length)
                    $response.Close()
                    continue
                }

                # Determine target URL and auth header based on provider
                if ($provider -eq "anthropic") {
                    $apiUrl = "https://api.anthropic.com/v1/messages"
                    $authHeaderName = "x-api-key"
                    $authHeaderValue = $apiKey
                } else {
                    # DeepSeek (OpenAI-compatible)
                    $apiUrl = "https://api.deepseek.com/v1/chat/completions"
                    $authHeaderName = "Authorization"
                    $authHeaderValue = "Bearer $apiKey"
                }

                Write-Host "  [API] -> $provider (body=$($requestBody.Length) chars)" -ForegroundColor Gray

                # Create outgoing request
                $httpReq = [System.Net.HttpWebRequest]::Create($apiUrl)
                $httpReq.Method = "POST"
                $httpReq.ContentType = "application/json"
                $httpReq.Headers[$authHeaderName] = $authHeaderValue
                if ($provider -eq "anthropic") {
                    $httpReq.Headers["anthropic-version"] = "2023-06-01"
                }
                $httpReq.AllowReadStreamBuffering = $false
                $httpReq.AllowWriteStreamBuffering = $false
                $httpReq.Timeout = 300000  # 5 min
                $httpReq.ReadWriteTimeout = 300000

                # Write request body
                $reqBytes = [System.Text.Encoding]::UTF8.GetBytes($requestBody)
                $httpReq.ContentLength = $reqBytes.Length
                $reqStream = $httpReq.GetRequestStream()
                $reqStream.Write($reqBytes, 0, $reqBytes.Length)
                $reqStream.Close()

                # Get response
                $httpResp = $httpReq.GetResponse()
                $respStream = $httpResp.GetResponseStream()

                # Copy response headers
                $response.StatusCode = [int]$httpResp.StatusCode
                $response.ContentType = $httpResp.ContentType
                foreach ($key in $httpResp.Headers.AllKeys) {
                    if ($key -ne "Transfer-Encoding" -and $key -ne "Content-Length") {
                        $response.Headers[$key] = $httpResp.Headers[$key]
                    }
                }

                # Stream response back to browser (supports SSE streaming)
                $buffer = New-Object byte[] 8192
                while (($read = $respStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $response.OutputStream.Write($buffer, 0, $read)
                    $response.OutputStream.Flush()
                }

                $respStream.Close()
                $httpResp.Close()
                $response.Close()

                Write-Host "  [API] OK" -ForegroundColor Green
            } catch [System.Net.WebException] {
                # Handle API errors
                $errResp = $_.Exception.Response
                if ($errResp) {
                    $response.StatusCode = [int]$errResp.StatusCode
                    $errStream = $errResp.GetResponseStream()
                    $errReader = New-Object System.IO.StreamReader($errStream)
                    $errBody = $errReader.ReadToEnd()
                    $errReader.Close()
                    $errStream.Close()
                    $errResp.Close()

                    $response.ContentType = "application/json; charset=utf-8"
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes($errBody)
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                    $response.Close()

                    Write-Host "  [API] Error: $($errResp.StatusCode) - $errBody" -ForegroundColor Yellow
                } else {
                    $response.StatusCode = 502
                    $errMsg = $_.Exception.Message -replace '"', '""'
                    $errJson = '{"error":{"message":"Failed to reach API: ' + $errMsg + '"}}'
                    $errBytes = [System.Text.Encoding]::UTF8.GetBytes($errJson)
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $errBytes.Length
                    $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                    $response.Close()

                    Write-Host "  [API] Network error: $($_.Exception.Message)" -ForegroundColor Red
                }
            } catch {
                $response.StatusCode = 502
                $errMsg = $_.Exception.Message -replace '"', '""'
                $errJson = '{"error":{"message":"Proxy error: ' + $errMsg + '"}}'
                $errBytes = [System.Text.Encoding]::UTF8.GetBytes($errJson)
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $errBytes.Length
                $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
                $response.Close()

                Write-Host "  [API] Error: $($_.Exception.Message)" -ForegroundColor Red
            }

            continue
        }

        # ===== Static File Serving =====
        if ($requestPath -eq "/") { $requestPath = "/index.html" }

        $filePath = Join-Path $scriptRoot $requestPath.TrimStart("/")

        if (Test-Path $filePath -PathType Leaf) {
            $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
            $mime = $mimeTypes[$ext]
            if (-not $mime) { $mime = "application/octet-stream" }

            $response.ContentType = $mime
            $response.StatusCode = 200

            $bytes = [System.IO.File]::ReadAllBytes($filePath)
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
        } else {
            $response.StatusCode = 404
            $msg = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found: $requestPath")
            $response.ContentLength64 = $msg.Length
            $response.OutputStream.Write($msg, 0, $msg.Length)
        }

        $response.Close()
    }
} catch [System.OperationCanceledException] {
    Write-Host ""
    Write-Host "  Server stopped by user" -ForegroundColor Yellow
} catch [System.Net.HttpListenerException] {
    Write-Host ""
    Write-Host "  ERROR: Cannot start HTTP listener on port $port" -ForegroundColor Red
    Write-Host "  Try running as Administrator, or register the URL:" -ForegroundColor Yellow
    Write-Host "  netsh http add urlacl url=http://localhost:$port/ user=Everyone" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Or use Python instead:" -ForegroundColor Yellow
    Write-Host "  python -m http.server $port" -ForegroundColor Gray
} catch {
    Write-Host ""
    Write-Host "  Server error: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    if ($listener.IsListening) {
        $listener.Stop()
    }
    $listener.Close()
    Write-Host "  Server closed" -ForegroundColor Gray
}
