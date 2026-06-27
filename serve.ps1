# Review Insight - Local HTTP Server with API Proxy
# Usage: powershell -ExecutionPolicy Bypass -File serve.ps1

$port = 9877
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

        # ===== JD Review Fetcher (SSE streaming) =====
        if ($requestPath -eq "/api/fetch-reviews" -and $request.HttpMethod -eq "POST") {
            $reader2 = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
            $reqBody2 = $reader2.ReadToEnd()
            $reader2.Close()

            try {
                $reqJson = $reqBody2 | ConvertFrom-Json
                $platform = $reqJson.platform
                $sku = $reqJson.sku

                if ($platform -ne "jd" -or -not $sku) {
                    $response.StatusCode = 400
                    $msg = [System.Text.Encoding]::UTF8.GetBytes('{"error":"Invalid request. Required: {platform:\"jd\", sku:\"123456\"}"}')
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $msg.Length
                    $response.OutputStream.Write($msg, 0, $msg.Length)
                    $response.Close()
                    continue
                }

                Write-Host "  [FETCH] JD reviews for SKU: $sku" -ForegroundColor Cyan

                # Set up SSE response
                $response.ContentType = "text/event-stream; charset=utf-8"
                $response.Headers["Cache-Control"] = "no-cache"
                $response.Headers["Connection"] = "keep-alive"
                $response.Headers["X-Accel-Buffering"] = "no"

                # Spawn fetch-jd.ps1
                $fetchScript = Join-Path $scriptRoot "fetch-jd.ps1"
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = "powershell.exe"
                $psi.Arguments = "-ExecutionPolicy Bypass -File `"$fetchScript`" -Sku `"$sku`""
                $psi.UseShellExecute = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.CreateNoWindow = $true
                $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8

                $proc = [System.Diagnostics.Process]::Start($psi)

                # Read stdout line by line and stream as SSE
                while (-not $proc.StandardOutput.EndOfStream) {
                    $line = $proc.StandardOutput.ReadLine()
                    if ($line.StartsWith("STATUS:")) {
                        $statusJson = $line.Substring(7)
                        # Wrap: add type field so frontend can distinguish progress vs result
                        $wrap = '{"type":"progress",' + $statusJson.Substring(1)
                        $sseData = "data: $wrap`n`n"
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($sseData)
                        $response.OutputStream.Write($bytes, 0, $bytes.Length)
                        $response.OutputStream.Flush()
                        continue
                    }
                    if ($line.StartsWith("DATA:")) {
                        $dataJson = $line.Substring(5)
                        # Wrap: add type field for result
                        $wrap = '{"type":"result",' + $dataJson.Substring(1)
                        $sseData = "data: $wrap`n`n"
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($sseData)
                        $response.OutputStream.Write($bytes, 0, $bytes.Length)
                        $response.OutputStream.Flush()
                        break
                    }
                }

                # Drain remaining stream to avoid orphaned process
                try { while (-not $proc.StandardOutput.EndOfStream) { $null = $proc.StandardOutput.ReadLine() } } catch {}
                if (-not $proc.HasExited) { $proc.WaitForExit(5000) }
                $response.Close()
                Write-Host "  [FETCH] Complete" -ForegroundColor Green
            } catch {
                $errMsg = $_.Exception.Message -replace '"', '""'
                $errJson = "{""error"":""$errMsg""}"
                $errSse = "event: error`ndata: $errJson`n`n"
                $errBytes = [System.Text.Encoding]::UTF8.GetBytes($errSse)
                try { $response.OutputStream.Write($errBytes, 0, $errBytes.Length) } catch {}
                $response.Close()
                Write-Host "  [FETCH] Error: $($_.Exception.Message)" -ForegroundColor Red
            }
            continue
        }

        # ===== Store SKU Fetcher (SSE streaming) =====
        if ($requestPath -eq "/api/fetch-store-skus" -and $request.HttpMethod -eq "POST") {
            $reader3 = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
            $reqBody3 = $reader3.ReadToEnd()
            $reader3.Close()

            try {
                $reqJson = $reqBody3 | ConvertFrom-Json
                $shopId = $reqJson.shopId
                $keyword = $reqJson.keyword
                $targetShop = $reqJson.targetShop

                if (-not $shopId -or -not $keyword) {
                    $response.StatusCode = 400
                    $msg = [System.Text.Encoding]::UTF8.GetBytes('{"error":"Required: shopId and keyword"}')
                    $response.ContentType = "application/json; charset=utf-8"
                    $response.ContentLength64 = $msg.Length
                    $response.OutputStream.Write($msg, 0, $msg.Length)
                    $response.Close()
                    continue
                }

                Write-Host "  [STORE] SKU fetch: shopId=$shopId keyword=$keyword" -ForegroundColor Cyan

                $response.ContentType = "text/event-stream; charset=utf-8"
                $response.Headers["Cache-Control"] = "no-cache"
                $response.Headers["Connection"] = "keep-alive"
                $response.Headers["X-Accel-Buffering"] = "no"

                $fetchScript = Join-Path $scriptRoot "fetch-store-skus.ps1"
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = "powershell.exe"
                $psi.Arguments = "-ExecutionPolicy Bypass -File `"$fetchScript`" -ShopId `"$shopId`" -Keyword `"$keyword`""
                if ($targetShop) { $psi.Arguments += " -TargetShop `"$targetShop`"" }
                $psi.UseShellExecute = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.CreateNoWindow = $true
                $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8

                $proc = [System.Diagnostics.Process]::Start($psi)

                while (-not $proc.StandardOutput.EndOfStream) {
                    $line = $proc.StandardOutput.ReadLine()
                    if ($line.StartsWith("STATUS:")) {
                        $statusJson = $line.Substring(7)
                        $wrap = '{"type":"progress",' + $statusJson.Substring(1)
                        $sseData = "data: $wrap`n`n"
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($sseData)
                        $response.OutputStream.Write($bytes, 0, $bytes.Length)
                        $response.OutputStream.Flush()
                        continue
                    }
                    if ($line.StartsWith("DATA:")) {
                        $dataJson = $line.Substring(5)
                        $wrap = '{"type":"result",' + $dataJson.Substring(1)
                        $sseData = "data: $wrap`n`n"
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($sseData)
                        $response.OutputStream.Write($bytes, 0, $bytes.Length)
                        $response.OutputStream.Flush()
                        break
                    }
                }

                try { while (-not $proc.StandardOutput.EndOfStream) { $null = $proc.StandardOutput.ReadLine() } } catch {}
                if (-not $proc.HasExited) { $proc.WaitForExit(5000) }
                $response.Close()
                Write-Host "  [STORE] Complete" -ForegroundColor Green
            } catch {
                $errMsg = $_.Exception.Message -replace '"', '""'
                $errJson = "{""error"":""$errMsg""}"
                $errSse = "event: error`ndata: $errJson`n`n"
                $errBytes = [System.Text.Encoding]::UTF8.GetBytes($errSse)
                try { $response.OutputStream.Write($errBytes, 0, $errBytes.Length) } catch {}
                $response.Close()
                Write-Host "  [STORE] Error: $($_.Exception.Message)" -ForegroundColor Red
            }
            continue
        }

        # ===== XHS Note Fetcher (SSE streaming) =====
        if ($requestPath -eq "/api/fetch-xhs-notes" -and $request.HttpMethod -eq "POST") {
            $reader4 = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
            $reqBody4 = $reader4.ReadToEnd()
            $reader4.Close()

            try {
                $reqJson = $reqBody4 | ConvertFrom-Json
                $keyword = $reqJson.keyword; $limit = [int]$reqJson.limit; $profile = $reqJson.profile
                if (-not $keyword) { $response.StatusCode = 400; $msg = [System.Text.Encoding]::UTF8.GetBytes('{"error":"keyword required"}'); $response.OutputStream.Write($msg,0,$msg.Length); $response.Close(); continue }
                if ($limit -le 0) { $limit = 20 }
                if (-not $profile) { $profile = "hkzg2bpx" }

                Write-Host "  [XHS] Fetch: keyword=$keyword limit=$limit profile=$profile" -ForegroundColor Cyan
                $response.ContentType = "text/event-stream; charset=utf-8"
                $response.Headers["Cache-Control"] = "no-cache"
                $response.Headers["Connection"] = "keep-alive"

                $fetchScript = Join-Path $scriptRoot "fetch-xhs.ps1"
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = "powershell.exe"
                $psi.Arguments = "-ExecutionPolicy Bypass -File `"$fetchScript`" -Keyword `"$keyword`" -Limit $limit -Profile `"$profile`""
                $psi.UseShellExecute = $false
                $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
                $psi.CreateNoWindow = $true
                $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8

                $proc = [System.Diagnostics.Process]::Start($psi)
                while (-not $proc.StandardOutput.EndOfStream) {
                    $line = $proc.StandardOutput.ReadLine()
                    if ($line.StartsWith("STATUS:")) {
                        $wrap = '{"type":"progress",' + $line.Substring(7).Substring(1)
                        $sseData = "data: $wrap`n`n"
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($sseData)
                        $response.OutputStream.Write($bytes, 0, $bytes.Length)
                        $response.OutputStream.Flush()
                    } elseif ($line.StartsWith("DATA:")) {
                        $wrap = '{"type":"result",' + $line.Substring(5).Substring(1)
                        $sseData = "data: $wrap`n`n"
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($sseData)
                        $response.OutputStream.Write($bytes, 0, $bytes.Length)
                        $response.OutputStream.Flush()
                        break
                    }
                }
                try { while (-not $proc.StandardOutput.EndOfStream) { $null = $proc.StandardOutput.ReadLine() } } catch {}
                if (-not $proc.HasExited) { $proc.WaitForExit(5000) }
                $response.Close()
                Write-Host "  [XHS] Complete" -ForegroundColor Green
            } catch {
                $errSse = "event: error`ndata: {`"error`":`"$($_.Exception.Message -replace '"','\"')`"}`n`n"
                $errBytes = [System.Text.Encoding]::UTF8.GetBytes($errSse)
                try { $response.OutputStream.Write($errBytes, 0, $errBytes.Length) } catch {}
                $response.Close()
                Write-Host "  [XHS] Error: $($_.Exception.Message)" -ForegroundColor Red
            }
            continue
        }

        # ===== Douyin Store SKU Fetcher (SSE streaming) =====
        if ($requestPath -eq "/api/fetch-douyin-skus" -and $request.HttpMethod -eq "POST") {
            $reader5 = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
            $reqBody5 = $reader5.ReadToEnd(); $reader5.Close()
            try {
                $reqJson = $reqBody5 | ConvertFrom-Json
                $keyword = $reqJson.keyword; $token = $reqJson.apifyToken; $maxPages = [int]$reqJson.maxPages
                if (-not $keyword -or -not $token) { $response.StatusCode = 400; $msg = [System.Text.Encoding]::UTF8.GetBytes('{"error":"keyword and apifyToken required"}'); $response.OutputStream.Write($msg,0,$msg.Length); $response.Close(); continue }
                if ($maxPages -le 0) { $maxPages = 10 }

                Write-Host "  [DOUYIN] Fetch: keyword=$keyword maxPages=$maxPages" -ForegroundColor Cyan
                $response.ContentType = "text/event-stream; charset=utf-8"
                $response.Headers["Cache-Control"] = "no-cache"

                # Write keyword to temp file to avoid encoding issues in command-line args
                $tmpFile = [System.IO.Path]::GetTempFileName() + ".json"
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($tmpFile, ($reqBody5 | ConvertFrom-Json | ConvertTo-Json -Compress), $utf8NoBom)

                $pyScript = Join-Path $scriptRoot "fetch-douyin-skus.py"
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = "python"
                $psi.Arguments = "`"$pyScript`" --file `"$tmpFile`""
                $psi.UseShellExecute = $false
                $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
                $psi.CreateNoWindow = $true
                $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
                $psi.EnvironmentVariables["PYTHONUNBUFFERED"] = "1"
                $psi.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8"
                $psi.EnvironmentVariables["PYTHONUTF8"] = "1"

                $proc = [System.Diagnostics.Process]::Start($psi)
                while (-not $proc.StandardOutput.EndOfStream) {
                    $line = $proc.StandardOutput.ReadLine()
                    if ($line.StartsWith("STATUS:")) {
                        $wrap = '{"type":"progress",' + $line.Substring(7).Substring(1)
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes("data: $wrap`n`n")
                        $response.OutputStream.Write($bytes, 0, $bytes.Length); $response.OutputStream.Flush()
                    } elseif ($line.StartsWith("DATA:")) {
                        $wrap = '{"type":"result",' + $line.Substring(5).Substring(1)
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes("data: $wrap`n`n")
                        $response.OutputStream.Write($bytes, 0, $bytes.Length); $response.OutputStream.Flush()
                        break
                    }
                }
                try { while (-not $proc.StandardOutput.EndOfStream) { $null = $proc.StandardOutput.ReadLine() } } catch {}
                if (-not $proc.HasExited) { $proc.WaitForExit(5000) }
                $response.Close()
                Write-Host "  [DOUYIN] Complete" -ForegroundColor Green
            } catch {
                $errSse = "event: error`ndata: {`"error`":`"$($_.Exception.Message -replace '"','\"')`"}`n`n"
                try { $response.OutputStream.Write([System.Text.Encoding]::UTF8.GetBytes($errSse),0,$errSse.Length) } catch {}
                $response.Close()
                Write-Host "  [DOUYIN] Error: $($_.Exception.Message)" -ForegroundColor Red
            }
            continue
        }

        # ===== Tmall Store SKU Fetcher (SSE streaming) =====
        if ($requestPath -eq "/api/fetch-tmall-skus" -and $request.HttpMethod -eq "POST") {
            $reader6 = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
            $reqBody6 = $reader6.ReadToEnd(); $reader6.Close()
            try {
                $reqJson = $reqBody6 | ConvertFrom-Json
                $keyword = $reqJson.keyword; $token = $reqJson.apifyToken; $maxPages = [int]$reqJson.maxPages
                if (-not $keyword -or -not $token) { $response.StatusCode = 400; $msg = [System.Text.Encoding]::UTF8.GetBytes('{"error":"keyword and apifyToken required"}'); $response.OutputStream.Write($msg,0,$msg.Length); $response.Close(); continue }
                if ($maxPages -le 0) { $maxPages = 3 }

                Write-Host "  [TMALL] Fetch: keyword=$keyword maxPages=$maxPages" -ForegroundColor Cyan
                Write-Host "  [TMALL] Raw body (first 200): $($reqBody6.Substring(0, [Math]::Min(200, $reqBody6.Length)))"
                Write-Host "  [TMALL] Token length: $($token.Length) starts with: $($token.Substring(0, [Math]::Min(8, $token.Length)))"
                $response.ContentType = "text/event-stream; charset=utf-8"
                $response.Headers["Cache-Control"] = "no-cache"

                $tmpFile = [System.IO.Path]::GetTempFileName() + ".json"
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($tmpFile, ($reqBody6 | ConvertFrom-Json | ConvertTo-Json -Compress), $utf8NoBom)

                $pyScript = Join-Path $scriptRoot "fetch-tmall-skus.py"
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = "python"; $psi.Arguments = "`"$pyScript`" --file `"$tmpFile`""
                $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
                $psi.CreateNoWindow = $true; $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
                $psi.EnvironmentVariables["PYTHONUNBUFFERED"] = "1"
                $psi.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8"
                $psi.EnvironmentVariables["PYTHONUTF8"] = "1"

                $proc = [System.Diagnostics.Process]::Start($psi)
                while (-not $proc.StandardOutput.EndOfStream) {
                    $line = $proc.StandardOutput.ReadLine()
                    if ($line.StartsWith("STATUS:")) {
                        $wrap = '{"type":"progress",' + $line.Substring(7).Substring(1)
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes("data: $wrap`n`n")
                        $response.OutputStream.Write($bytes, 0, $bytes.Length); $response.OutputStream.Flush()
                    } elseif ($line.StartsWith("DATA:")) {
                        $wrap = '{"type":"result",' + $line.Substring(5).Substring(1)
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes("data: $wrap`n`n")
                        $response.OutputStream.Write($bytes, 0, $bytes.Length); $response.OutputStream.Flush()
                        break
                    }
                }
                try { while (-not $proc.StandardOutput.EndOfStream) { $null = $proc.StandardOutput.ReadLine() } } catch {}
                if (-not $proc.HasExited) { $proc.WaitForExit(5000) }
                $response.Close()
                Write-Host "  [TMALL] Complete" -ForegroundColor Green
            } catch {
                $errSse = "event: error`ndata: {`"error`":`"$($_.Exception.Message -replace '"','\"')`"}`n`n"
                try { $response.OutputStream.Write([System.Text.Encoding]::UTF8.GetBytes($errSse),0,$errSse.Length) } catch {}
                $response.Close()
                Write-Host "  [TMALL] Error: $($_.Exception.Message)" -ForegroundColor Red
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
            # Disable caching for HTML/CSS/JS
            if ($ext -match '\.(html|css|js)$') {
                $response.Headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
            }

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
