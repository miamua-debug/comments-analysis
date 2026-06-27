# fetch-jd.ps1 - Fetch all reviews for a JD product (SPU-level, all SKUs)
# Usage: powershell -ExecutionPolicy Bypass -File fetch-jd.ps1 -Sku "100191929771"

param([string]$Sku)

# Force UTF-8 output encoding (critical for Chinese characters)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$ErrorActionPreference = "Continue"
$headers = @{"User-Agent"="Mozilla/5.0"; "Referer"="https://item.jd.com/$Sku.html"}
$allComments = @()
$validSkus = @()
$productName = ""

# STATUS helper - flush immediately for SSE streaming
function Write-Status($json) {
    $line = "STATUS:$json"
    [Console]::WriteLine($line)
    [Console]::Out.Flush()
}

Write-Status '{"phase":"discover","message":"Discovering SKUs under same SPU..."}'

# ===== Step 1: Discover all SKUs via mobile page =====
try {
    $m = Invoke-WebRequest -Uri "https://item.m.jd.com/product/$Sku.html" `
        -Headers @{"User-Agent"="Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15"} `
        -TimeoutSec 15 -UseBasicParsing
    $mContent = $m.Content

    $allSkuIds = @{}
    $skuListIds = @()
    if ($mContent -match '"skuList"\s*:\s*(\[[^\]]+\])') {
        $skuListJson = $Matches[1] | ConvertFrom-Json
        foreach ($s in $skuListJson) {
            $allSkuIds[$s.skuId] = $true
            $skuListIds += $s.skuId
        }
    }
    # Fallback: if no skuList, find all SKU-like IDs from the page
    if ($skuListIds.Count -eq 0) {
        $skuMatches = [regex]::Matches($mContent, '"sku\w*"\s*:\s*"?(\d{10,})"?')
        foreach ($sm in $skuMatches) {
            $sid = $sm.Groups[1].Value
            if (-not $allSkuIds.ContainsKey($sid)) { $allSkuIds[$sid] = $true }
        }
    }

    $allSkuIds[$Sku] = $true
    Write-Status "{`"phase`":`"discover`",`"message`":`"Found $($allSkuIds.Count) candidate SKUs`"}"
} catch {
    Write-Status "{`"phase`":`"discover`",`"message`":`"Mobile page failed, using single SKU`"}"
    $allSkuIds = @{ $Sku = $true }
}

# ===== Step 2: Validate SKUs and get metadata =====
# If skuList was found, use only those (authoritative); otherwise use all discovered IDs
if ($skuListIds.Count -gt 0) {
    $allSkuIds = @{}
    foreach ($sid in $skuListIds) { $allSkuIds[$sid] = $true }
    $allSkuIds[$Sku] = $true
}
Write-Status '{"phase":"validate","message":"Validating SKUs and getting metadata..."}'

foreach ($sid in $allSkuIds.Keys) {
    try {
        $url = "https://club.jd.com/comment/skuProductPageComments.action?productId=$sid&score=0&sortType=5&page=1&pageSize=1"
        $r = Invoke-WebRequest -Uri $url -Headers $headers -TimeoutSec 10 -UseBasicParsing
        $data = $r.Content | ConvertFrom-Json

        if ($data.comments -and $data.comments.Count -gt 0) {
            $refName = $data.comments[0].referenceName
            $color = $data.comments[0].productColor
            $maxPage = if ($data.maxPage -gt 0) { $data.maxPage } else { 1 }
            $summary = $data.productCommentSummary

            if (-not $productName) { $productName = $refName }

            $vsku = [PSCustomObject]@{
                SKU = $sid; Name = $refName; Color = $color
                MaxPage = $maxPage; Total = $summary.commentCountStr
                AvgScore = $summary.averageScore; GoodRate = $summary.goodRateShow
                Score5 = $summary.score5Count; Score4 = $summary.score4Count
                Score3 = $summary.score3Count; Score2 = $summary.score2Count; Score1 = $summary.score1Count
            }
            $validSkus += $vsku
            Write-Status "{`"phase`":`"validate`",`"message`":`"SKU $sid ($color) - $($summary.commentCountStr) reviews, $maxPage pages`"}"
        }
    } catch {
        Write-Status "{`"phase`":`"validate`",`"message`":`"SKU $sid request failed, skipping`"}"
    }
    Start-Sleep -Milliseconds 300
}

Write-Status "{`"phase`":`"validate`",`"message`":`"Done. Valid SKUs: $($validSkus.Count)`"}"

# ===== Step 3: Fetch all reviews for all valid SKUs =====
$totalFetched = 0

foreach ($vsku in $validSkus) {
    $sid = $vsku.SKU
    for ($page = 1; $page -le $vsku.MaxPage; $page++) {
        try {
            $url = "https://club.jd.com/comment/skuProductPageComments.action?productId=$sid&score=0&sortType=5&page=$page&pageSize=10"
            $r = Invoke-WebRequest -Uri $url -Headers $headers -TimeoutSec 15 -UseBasicParsing
            $data = $r.Content | ConvertFrom-Json

            foreach ($c in $data.comments) {
                $comment = [PSCustomObject]@{
                    SKU = $sid; Page = $page; Id = $c.id; Nickname = $c.nickname
                    Score = $c.score; Content = ($c.content -replace "[\r\n]+", " ").Trim()
                    Color = $c.productColor; Location = $c.location
                    CreationTime = $c.creationTime; ReferenceTime = $c.referenceTime
                    ImageCount = $c.imageCount; UsefulVoteCount = $c.usefulVoteCount
                    ReplyCount = $c.replyCount; Days = $c.days; AfterDays = $c.afterDays
                    Anonymous = $c.anonymousFlag; UserClient = $c.userClient; Plus = $c.plusAvailable
                }
                $allComments += $comment
            }
            $totalFetched += $data.comments.Count
        } catch {
            # Silent skip for individual page errors
        }
        if ($page -lt $vsku.MaxPage) {
            # Progress update every page
            Write-Status "{`"phase`":`"fetch`",`"sku`":`"$sid`",`"color`":`"$($vsku.Color)`",`"currentPage`":$page,`"maxPage`":$($vsku.MaxPage),`"totalFetched`":$totalFetched}"
            Start-Sleep -Milliseconds 500
        }
    }
    Write-Status "{`"phase`":`"fetch`",`"sku`":`"$sid`",`"color`":`"$($vsku.Color)`",`"currentPage`":$($vsku.MaxPage),`"maxPage`":$($vsku.MaxPage),`"totalFetched`":$totalFetched}"
}

# ===== Step 4: Output final JSON =====
$summary = [PSCustomObject]@{
    productName = $productName
    skuCount = $validSkus.Count
    totalReviews = $allComments.Count
}

# Build reviews array (use indexed property access to avoid unicode issues)
$reviewsArr = @()
foreach ($c in $allComments) {
    $reviewsArr += [PSCustomObject]@{
        SKU = $c.SKU; page = $c.Page; id = $c.Id; nickname = $c.Nickname
        score = $c.Score; content = $c.Content; color = $c.Color
        location = $c.Location; creationTime = $c.CreationTime; referenceTime = $c.ReferenceTime
        imageCount = $c.ImageCount; usefulVoteCount = $c.UsefulVoteCount
        replyCount = $c.ReplyCount; days = $c.Days; afterDays = $c.AfterDays
        anonymous = $c.Anonymous; userClient = $c.UserClient; plus = $c.Plus
    }
}

# Build SKU summaries
$skuArr = @()
foreach ($vs in $validSkus) {
    $skuArr += [PSCustomObject]@{
        sku = $vs.SKU; name = $vs.Name; color = $vs.Color
        total = $vs.Total; avgScore = $vs.AvgScore; goodRate = $vs.GoodRate
    }
}

$result = [PSCustomObject]@{
    productName = $productName
    skuCount = $validSkus.Count
    totalReviews = $allComments.Count
    skus = $skuArr
    reviews = $reviewsArr
}

$resultJson = $result | ConvertTo-Json -Depth 4 -Compress
Write-Status "{`"phase`":`"complete`",`"productName`":`"$($productName -replace '"','\"')`",`"skuCount`":$($validSkus.Count),`"totalReviews`":$($allComments.Count)}"
[Console]::WriteLine("DATA:$resultJson")
[Console]::Out.Flush()
