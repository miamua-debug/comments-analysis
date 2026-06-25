# fetch-store-skus.ps1 - Extract all SKUs from a JD store
# Usage: powershell -ExecutionPolicy Bypass -File fetch-store-skus.ps1 -ShopId "10320377" -Keyword "芯友"

param([string]$ShopId, [string]$Keyword, [string]$TargetShop)

# Force UTF-8 output
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$ErrorActionPreference = "Continue"
$headers = @{"User-Agent"="Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15"}
$commentHeaders = @{"User-Agent"="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"; "Referer"="https://item.jd.com/"}

function Write-Status($json) {
    $line = "STATUS:$json"
    [Console]::WriteLine($line)
    [Console]::Out.Flush()
}

$encoded = [uri]::EscapeDataString($Keyword)
$tempDir = [System.IO.Path]::GetTempPath() + "jd_sku_$ShopId\"
if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }

# ===== Phase 1: Find last page via binary search =====
Write-Status '{"phase":"search","message":"Finding total pages via binary search..."}'
$low = 1; $high = 100; $lastPage = 1
while ($low -lt $high) {
    $mid = [Math]::Floor(($low + $high) / 2)
    $url = "https://so.m.jd.com/ware/search.action?keyword=$encoded&shopId=$ShopId&page=$mid"
    try {
        $r = Invoke-WebRequest -Uri $url -Headers $headers -TimeoutSec 15 -UseBasicParsing
        $skuCount = ([regex]::Matches($r.Content, '<div class="search_prolist_item"\s+skuid="(\d+)"')).Count
        if ($skuCount -gt 0) { $lastPage = $mid; $low = $mid + 1 } else { $high = $mid }
    } catch { $high = $mid }
}
Write-Status "{`"phase`":`"search`",`"message`":`"Found $lastPage pages`"}"

# ===== Phase 2: Download all pages =====
Write-Status "{`"phase`":`"download`",`"message`":`"Downloading $lastPage pages...`",`"total`":$lastPage}"
for ($page = 1; $page -le $lastPage; $page++) {
    $url = "https://so.m.jd.com/ware/search.action?keyword=$encoded&shopId=$ShopId&page=$page"
    try {
        $r = Invoke-WebRequest -Uri $url -Headers $headers -TimeoutSec 15 -UseBasicParsing
        $r.Content | Out-File "$tempDir`p$page.html" -Encoding UTF8
        if ($page % 5 -eq 0 -or $page -eq $lastPage) {
            Write-Status "{`"phase`":`"download`",`"message`":`"Downloaded $page / $lastPage pages`",`"current`":$page,`"total`":$lastPage}"
        }
    } catch {
        Write-Status "{`"phase`":`"download`",`"message`":`"Page $page failed, skipping`",`"current`":$page,`"total`":$lastPage}"
    }
    Start-Sleep -Milliseconds 200
}

# ===== Phase 3: Extract SKU data =====
Write-Status '{"phase":"extract","message":"Extracting SKU data from HTML..."}'
$allSkus = @{}

for ($page = 1; $page -le $lastPage; $page++) {
    $file = "$tempDir`p$page.html"
    if (-not (Test-Path $file)) { continue }
    $content = Get-Content $file -Raw -Encoding UTF8

    $blocks = $content -split '<div class="search_prolist_item"\s+skuid="'
    foreach ($block in $blocks) {
        if ($block -notmatch '^(\d+)"') { continue }
        $sid = $Matches[1]
        if ($allSkus.ContainsKey($sid)) { continue }

        $name = ''; if ($block -match 'class="search_prolist_title"[^>]*>([^<]+)<') { $name = $Matches[1].Trim() }
        $price = 0; if ($block -match 'pri="([^"]+)"') { $price = [double]$Matches[1] }
        $rate = ''; if ($block -match "id=`"rate_${sid}`"[^>]*>(\d+)<") { $rate = $Matches[1] }
        $shop = ''; if ($block -match 'class="shop_name"[^>]*>([^<]+)<') { $shop = $Matches[1].Trim() }

        if ($name) {
            $entry = @{ Name=$name; Price=$price; Rate=$rate; Shop=$shop; Color=''; Attrs=''; ExtName='';
                        CommentCount=''; AvgScore=0; GoodRate=0; RAM=''; Disk=''; CPU=''; Model='';
                        Screen=''; System=''; BaseName='' }
            $allSkus[$sid] = $entry
        }

        # Extract JSON variant data for Attrs + Color
        $jsonMatches = [regex]::Matches($block, '\{[^}]*"warename"[^}]*"CustomAttrListNew":"([^"]*)"[^}]*"extname":"([^"]*)"[^}]*\}')
        foreach ($jm in $jsonMatches) {
            $a = $jm.Groups[1].Value; $e = $jm.Groups[2].Value
            if (-not $allSkus[$sid].Attrs -and $a) { $allSkus[$sid].Attrs = $a }
            if (-not $allSkus[$sid].ExtName -and $e) { $allSkus[$sid].ExtName = $e }
        }
        # Also check color field in JSON
        $colorMatches = [regex]::Matches($block, '\{[^}]*"color":"([^"]+)"[^}]*\}')
        foreach ($cm in $colorMatches) {
            $c = $cm.Groups[1].Value
            if (-not $allSkus[$sid].Color -and $c) { $allSkus[$sid].Color = $c }
        }
    }
}
Write-Status "{`"phase`":`"extract`",`"message`":`"Extracted $($allSkus.Count) candidate SKUs`"}"

# ===== Phase 4: Fetch review data =====
Write-Status "{`"phase`":`"reviews`",`"message`":`"Fetching review data...`",`"total`":$($allSkus.Count)}"
$processed = 0
foreach ($sid in $allSkus.Keys) {
    try {
        $url = "https://club.jd.com/comment/skuProductPageComments.action?productId=$sid&score=0&sortType=5&page=1&pageSize=10"
        $r = Invoke-WebRequest -Uri $url -Headers $commentHeaders -TimeoutSec 8 -UseBasicParsing
        $data = $r.Content | ConvertFrom-Json

        $s = $data.productCommentSummary
        $allSkus[$sid].CommentCount = $s.commentCountStr
        $allSkus[$sid].AvgScore = $s.averageScore
        $allSkus[$sid].GoodRate = $s.goodRateShow

        if ($data.comments -and $data.comments[0].productColor -and -not $allSkus[$sid].Color) {
            $allSkus[$sid].Color = $data.comments[0].productColor
        }
    } catch { }
    $processed++
    if ($processed % 30 -eq 0 -or $processed -eq $allSkus.Count) {
        Write-Status "{`"phase`":`"reviews`",`"message`":`"Fetched reviews: $processed / $($allSkus.Count)`",`"current`":$processed,`"total`":$($allSkus.Count)}"
    }
    Start-Sleep -Milliseconds 300
}

# ===== Phase 5: Filter by shop + Parse specs =====
Write-Status '{"phase":"filter","message":"Filtering by shop and parsing specs..."}'

# Find dominant shop
if (-not $TargetShop) {
    $shopCounts = @{}
    foreach ($sid in $allSkus.Keys) {
        $s = $allSkus[$sid].Shop; if (-not $s) { $s = '(none)' }
        $shopCounts[$s]++
    }
    $TargetShop = ($shopCounts.Keys | Sort-Object { $shopCounts[$_] } -Descending | Select-Object -First 1)
}

# Helper: extract specs from name+color
function Parse-Specs($name, $color, $attrs) {
    $specs = @{ RAM=''; Disk=''; CPU=''; Model=''; Screen=''; System='' }
    $combined = "$name $color $attrs"

    # RAM + Disk: "8G+256G", "8G+512G"
    if ($combined -match '(\d+)G\s*\+\s*(\d+)G') { $specs.RAM="$($Matches[1])G"; $specs.Disk="$($Matches[2])G" }
    elseif ($combined -match '(\d+)\s*\+\s*(\d+)G') { $specs.RAM="$($Matches[1])G"; $specs.Disk="$($Matches[2])G" }
    if (-not $specs.RAM -and $combined -match '(\d+)G\s*(?:内存|运存|RAM)') { $specs.RAM="$($Matches[1])G" }
    if (-not $specs.Disk -and $combined -match '(\d+)G\s*(?:硬盘|存储|固态|SSD|闪存)') { $specs.Disk="$($Matches[1])G" }

    # CPU
    if ($combined -match '酷睿\s*(i\d)') { $specs.CPU="酷睿$($Matches[1])" }
    elseif ($combined -match '\b(?:Intel|intel)\b') { $specs.CPU='Intel' }
    elseif ($combined -match '四核') { $specs.CPU='四核' }
    elseif ($combined -match '八核') { $specs.CPU='八核' }

    # Model
    if ($combined -match '\b([A-Z]\d+)\b') { $specs.Model=$Matches[1] }

    # Screen
    if ($combined -match '双屏|单屏|无屏') { $specs.Screen=$Matches[0] }
    # System
    if ($combined -match 'Windows|安卓|Android') { $specs.System=$Matches[0] }

    return $specs
}

# Filter by shop and parse specs
$filtered = @{}
foreach ($sid in $allSkus.Keys) {
    $s = $allSkus[$sid]
    if ($s.Shop -ne $TargetShop) { continue }
    $sp = Parse-Specs $s.Name $s.Color $s.Attrs
    $s.RAM = $sp.RAM; $s.Disk = $sp.Disk; $s.CPU = $sp.CPU
    $s.Model = $sp.Model; $s.Screen = $sp.Screen; $s.System = $sp.System
    $filtered[$sid] = $s
}
Write-Status "{`"phase`":`"filter`",`"message`":`"Filtered: $($filtered.Count) SKUs from $TargetShop`"}"

# ===== Phase 6: Family grouping + spec propagation =====
Write-Status '{"phase":"family","message":"Grouping product families and propagating specs..."}'

function Get-BaseName($name) {
    $base = $name -replace '\s+', ' '
    $base = $base -replace '\s*(?:官方标配|套餐一|套餐二|套餐三|套餐四|套餐五|套餐六|标准版|标配版|基础版|专业版)\s*$', ''
    $base = $base -replace '\s+[（(][^)）]*[)）]\s*$', ''
    return $base.Trim()
}

# Group by base name
$families = @{}
foreach ($sid in $filtered.Keys) {
    $s = $filtered[$sid]
    $base = Get-BaseName($s.Name)
    $s.BaseName = $base
    if (-not $families.ContainsKey($base)) { $families[$base] = @() }
    $families[$base] += $sid
}

# Propagate specs within families
foreach ($base in $families.Keys) {
    $members = $families[$base]
    # Find best specs
    $best = @{ RAM=''; Disk=''; CPU=''; Model=''; Screen=''; System='' }
    foreach ($sid in $members) {
        $s = $filtered[$sid]
        foreach ($k in @('RAM','Disk','CPU','Model','Screen','System')) {
            if ($s[$k] -and -not $best[$k]) { $best[$k] = $s[$k] }
        }
    }
    # Propagate
    foreach ($sid in $members) {
        $s = $filtered[$sid]
        foreach ($k in @('RAM','Disk','CPU','Model','Screen','System')) {
            if (-not $s[$k]) { $s[$k] = $best[$k] }
        }
    }
}
Write-Status "{`"phase`":`"family`",`"message`":`"Product families: $($families.Count)`"}"

# ===== Phase 7: Build output =====
Write-Status '{"phase":"output","message":"Building output..."}'

$skuArr = @()
foreach ($sid in $filtered.Keys) {
    $s = $filtered[$sid]
    $skuArr += [PSCustomObject]@{
        skuId = $sid; name = $s.Name; color = $s.Color; price = $s.Price
        commentCount = $s.CommentCount; avgScore = $s.AvgScore; goodRate = $s.GoodRate
        model = $s.Model; cpu = $s.CPU; ram = $s.RAM; disk = $s.Disk
        screen = $s.Screen; system = $s.System; baseName = $s.BaseName
        attrs = $s.Attrs; extName = $s.ExtName
    }
}

$result = [PSCustomObject]@{
    shopName = $TargetShop; shopId = $ShopId; keyword = $Keyword
    totalSkus = $skuArr.Count; familyCount = $families.Count
    skus = $skuArr
}

$resultJson = $result | ConvertTo-Json -Depth 5 -Compress
Write-Status "{`"phase`":`"complete`",`"shopName`":`"$TargetShop`",`"totalSkus`":$($skuArr.Count),`"familyCount`":$($families.Count)}"
[Console]::WriteLine("DATA:$resultJson")
[Console]::Out.Flush()

# Cleanup temp files
try { Remove-Item -Recurse -Force $tempDir } catch { }
