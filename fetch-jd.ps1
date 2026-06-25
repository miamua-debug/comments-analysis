# fetch-jd.ps1 — Fetch all reviews for a JD product (SPU-level, all SKUs)
# Usage: powershell -ExecutionPolicy Bypass -File fetch-jd.ps1 -Sku "100191929771"
# Output: JSON array of all reviews to stdout, one line per status update (prefixed with STATUS:)

param([string]$Sku)

$ErrorActionPreference = "Continue"
$headers = @{"User-Agent"="Mozilla/5.0"; "Referer"="https://item.jd.com/$Sku.html"}
$allComments = @()
$validSkus = @()
$productName = ""

Write-Output "STATUS:{\"phase\":\"discover\",\"message\":\"Discovering SKUs under same SPU...\"}"

# ===== Step 1: Discover all SKUs via mobile page =====
try {
    $m = Invoke-WebRequest -Uri "https://item.m.jd.com/product/$Sku.html" `
        -Headers @{"User-Agent"="Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15"} `
        -TimeoutSec 15 -UseBasicParsing
    $mContent = $m.Content

    $allSkuIds = @{}
    if ($mContent -match '"skuList"\s*:\s*(\[[^\]]+\])') {
        $skuListJson = $Matches[1] | ConvertFrom-Json
        foreach ($s in $skuListJson) { $allSkuIds[$s.skuId] = $true }
    }
    # Also find all SKU-like IDs
    $skuMatches = [regex]::Matches($mContent, '"sku\w*"\s*:\s*"?(\d{10,})"?')
    foreach ($sm in $skuMatches) {
        $sid = $sm.Groups[1].Value
        if (-not $allSkuIds.ContainsKey($sid)) { $allSkuIds[$sid] = $true }
    }

    $allSkuIds[$Sku] = $true
    Write-Output "STATUS:{\"phase\":\"discover\",\"message\":\"Found $($allSkuIds.Count) candidate SKUs\"}"
} catch {
    Write-Output "STATUS:{\"phase\":\"discover\",\"message\":\"Mobile page failed, using single SKU: $_\"}"
    $allSkuIds = @{ $Sku = $true }
}

# ===== Step 2: Validate SKUs and get metadata =====
Write-Output "STATUS:{\"phase\":\"validate\",\"message\":\"Validating SKUs...\"}"

foreach ($sid in $allSkuIds.Keys) {
    try {
        $url = "https://club.jd.com/comment/skuProductPageComments.action?productId=$sid&score=0&sortType=5&page=1&pageSize=1"
        $r = Invoke-WebRequest -Uri $url -Headers $headers -TimeoutSec 10 -UseBasicParsing
        $data = $r.Content | ConvertFrom-Json

        if ($data.comments -and $data.comments.Count -gt 0) {
            $refName = $data.comments[0].referenceName
            $color = $data.comments[0].productColor
            $maxPage = $data.maxPage
            $summary = $data.productCommentSummary

            if (-not $productName) { $productName = $refName }

            # Only exclude obviously mismatched SKUs
            $namePrefix = $productName.Substring(0, [Math]::Min(4, $productName.Length))
            if ($refName.StartsWith($namePrefix) -or $sid -eq $Sku) {
                $validSkus += [PSCustomObject]@{
                    SKU = $sid
                    Name = $refName
                    Color = $color
                    MaxPage = $maxPage
                    Total = $summary.commentCountStr
                    AvgScore = $summary.averageScore
                    GoodRate = $summary.goodRateShow
                    Score5 = $summary.score5Count
                    Score4 = $summary.score4Count
                    Score3 = $summary.score3Count
                    Score2 = $summary.score2Count
                    Score1 = $summary.score1Count
                }
                Write-Output "STATUS:{\"phase\":\"validate\",\"message\":\"Validated SKU $sid` ($color) — $($summary.commentCountStr) reviews\"}"
            }
        }
    } catch {
        Write-Output "STATUS:{\"phase\":\"validate\",\"message\":\"SKU $sid failed: $_\"}"
    }
    Start-Sleep -Milliseconds 300
}

Write-Output "STATUS:{\"phase\":\"validate\",\"message\":\"Valid SKUs: $($validSkus.Count)\"}"

# ===== Step 3: Fetch all reviews =====
$totalFetched = 0
foreach ($vsku in $validSkus) {
    $sid = $vsku.SKU
    Write-Output "STATUS:{\"phase\":\"fetch\",\"sku\":\"$sid\",\"color\":\"$($vsku.Color)\",\"maxPage\":$($vsku.MaxPage),\"currentPage\":0}"

    for ($page = 1; $page -le $vsku.MaxPage; $page++) {
        try {
            $url = "https://club.jd.com/comment/skuProductPageComments.action?productId=$sid&score=0&sortType=5&page=$page&pageSize=10"
            $r = Invoke-WebRequest -Uri $url -Headers $headers -TimeoutSec 15 -UseBasicParsing
            $data = $r.Content | ConvertFrom-Json

            foreach ($c in $data.comments) {
                $allComments += [PSCustomObject]@{
                    SKU = $sid
                    页码 = $page
                    评价ID = $c.id
                    昵称 = $c.nickname
                    评分 = $c.score
                    评价内容 = ($c.content -replace "[\r\n]+", " ").Trim()
                    购买规格 = $c.productColor
                    地区 = $c.location
                    评价时间 = $c.creationTime
                    购买时间 = $c.referenceTime
                    图片数 = $c.imageCount
                    有用数 = $c.usefulVoteCount
                    回复数 = $c.replyCount
                    购买后天数 = $c.days
                    追评后天数 = $c.afterDays
                    匿名 = $c.anonymousFlag
                    客户端 = $c.userClient
                    Plus = $c.plusAvailable
                }
            }
            $totalFetched += $data.comments.Count
            Write-Output "STATUS:{\"phase\":\"fetch\",\"sku\":\"$sid\",\"currentPage\":$page,\"maxPage\":$($vsku.MaxPage),\"totalFetched\":$totalFetched}"
        } catch {
            Write-Output "STATUS:{\"phase\":\"fetch\",\"sku\":\"$sid\",\"currentPage\":$page,\"error\":\"$_\"}"
        }
        if ($page -lt $vsku.MaxPage) { Start-Sleep -Milliseconds 500 }
    }
}

# ===== Step 4: Output final JSON =====
Write-Output "STATUS:{\"phase\":\"complete\",\"productName\":\"$productName\",\"skuCount\":$($validSkus.Count),\"totalReviews\":$($allComments.Count)}"

# Output the full data as the final line
$result = @{
    productName = $productName
    skuCount = $validSkus.Count
    totalReviews = $allComments.Count
    skus = @($validSkus | ForEach-Object {
        @{
            sku = $_.SKU
            name = $_.Name
            color = $_.Color
            total = $_.Total
            avgScore = $_.AvgScore
            goodRate = $_.GoodRate
        }
    })
    reviews = @($allComments | ForEach-Object {
        @{
            SKU = $_.SKU
            page = $_.页码
            id = $_.评价ID
            nickname = $_.昵称
            score = $_.评分
            content = $_.评价内容
            color = $_.购买规格
            location = $_.地区
            creationTime = $_.评价时间
            referenceTime = $_.购买时间
            imageCount = $_.图片数
            usefulVoteCount = $_.有用数
            replyCount = $_.回复数
            days = $_.购买后天数
            afterDays = $_.追评后天数
            anonymous = $_.匿名
            userClient = $_.客户端
            plus = $_.Plus
        }
    })
}

Write-Output "DATA:$($result | ConvertTo-Json -Depth 4 -Compress)"
