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
# Cap at 30 pages max — target store products appear early in relevance-sorted results
$low = 1; $high = 100; $lastPage = 1; $MAX_PAGES = 50
while ($low -lt $high) {
    $mid = [Math]::Floor(($low + $high) / 2)
    $url = "https://so.m.jd.com/ware/search.action?keyword=$encoded&shopId=$ShopId&page=$mid"
    try {
        $r = Invoke-WebRequest -Uri $url -Headers $headers -TimeoutSec 15 -UseBasicParsing
        $skuCount = ([regex]::Matches($r.Content, '<div class="search_prolist_item"\s+skuid="(\d+)"')).Count
        if ($skuCount -gt 0) { $lastPage = $mid; $low = $mid + 1 } else { $high = $mid }
    } catch { $high = $mid }
}
$lastPage = [Math]::Min($lastPage, $MAX_PAGES)
Write-Status "{`"phase`":`"search`",`"message`":`"Found $lastPage pages (capped at $MAX_PAGES)`"}"

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
    Start-Sleep -Milliseconds 100
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

# ===== Phase 3.5: Early filter by shop (before expensive review fetching) =====
if (-not $TargetShop) {
    $shopCounts = @{}
    foreach ($sid in $allSkus.Keys) { $s = $allSkus[$sid].Shop; if (-not $s) { $s = '(none)' }; $shopCounts[$s]++ }
    $TargetShop = ($shopCounts.Keys | Sort-Object { $shopCounts[$_] } -Descending | Select-Object -First 1)
}
Write-Status "{`"phase`":`"filter`",`"message`":`"Filtering by shop: $TargetShop (pre-filter: $($allSkus.Count) SKUs)`"}"

$preFiltered = @{}
foreach ($sid in $allSkus.Keys) {
    if ($allSkus[$sid].Shop -eq $TargetShop) { $preFiltered[$sid] = $allSkus[$sid] }
}
$allSkus = $preFiltered
Write-Status "{`"phase`":`"filter`",`"message`":`"After shop filter: $($allSkus.Count) SKUs from $TargetShop`"}"

# ===== Phase 3.6: Fetch mobile page for variant specs (one request per product group) =====
Write-Status '{"phase":"specs","message":"Fetching variant specs from mobile pages..."}'
# Use the first few SKUs to get mobile page data — covers all variants in same SPU
$mobileChecked = @{}  # Track which mobile pages we've checked
$specsFetched = 0
foreach ($sid in $allSkus.Keys) {
    # Only check first 5 SKUs — one mobile page covers all variants in the same product
    if ($specsFetched -ge 5) { break }
    try {
        $murl = "https://item.m.jd.com/product/$sid.html"
        $mr = Invoke-WebRequest -Uri $murl -Headers $headers -TimeoutSec 10 -UseBasicParsing
        # Extract all color variant strings from the page
        $colorPatterns = [regex]::Matches($mr.Content, '"color"\s*:\s*"([^"]+)"')
        $found = 0
        foreach ($cm in $colorPatterns) {
            $cv = $cm.Groups[1].Value
            if ($cv -and $cv.Length -gt 2) {
                # Store as supplementary color data (don't overwrite existing Color from comment API)
                if (-not $mobileChecked.ContainsKey($cv)) {
                    $mobileChecked[$cv] = $true
                    $found++
                }
            }
        }
        if ($found -gt 0) {
            $specsFetched++
            Write-Status "{`"phase`":`"specs`",`"message`":`"Found $found variant specs from SKU $sid`",`"current`":$specsFetched,`"total`":5}"
        }
    } catch { }
    Start-Sleep -Milliseconds 200
}
# Now match mobile page color data to SKUs: if an SKU has no Color yet, try to match by keyword
if ($mobileChecked.Count -gt 0) {
    Write-Status "{`"phase`":`"specs`",`"message`":`"Matching $($mobileChecked.Count) variant specs to SKUs...`"}"
    foreach ($sid in $allSkus.Keys) {
        $s = $allSkus[$sid]
        if ($s.Color) { continue }  # Already has Color from comment API or HTML
        # Match mobile color to SKU by model prefix (e.g. "G2" in both)
        if ($cv -match '([A-Z]\d+)') {
            $cvModel = $Matches[1]
            if ($s.Name.Contains($cvModel)) { $s.Color = $cv; break }
        }
    }
}

# ===== Phase 4: Fetch review data (only for target store SKUs) =====
Write-Status "{`"phase`":`"reviews`",`"message`":`"Fetching review data for $($allSkus.Count) SKUs...`",`"total`":$($allSkus.Count)}"
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

        # Capture variant specs from comment API (richest data source)
        if ($data.comments -and $data.comments.Count -gt 0) {
            $c = $data.comments[0]
            # productColor has variant specs like "G2青春版 双屏 8G+256G【酷睿i5】"
            if ($c.productColor -and -not $allSkus[$sid].Color) {
                $allSkus[$sid].Color = $c.productColor
            }
            # referenceName is often the full product name with all specs
            if ($c.referenceName -and $c.referenceName.Length -gt $allSkus[$sid].Name.Length) {
                $allSkus[$sid].FullName = $c.referenceName
            }
        }
    } catch { }
    $processed++
    if ($processed % 30 -eq 0 -or $processed -eq $allSkus.Count) {
        Write-Status "{`"phase`":`"reviews`",`"message`":`"Fetched reviews: $processed / $($allSkus.Count)`",`"current`":$processed,`"total`":$($allSkus.Count)}"
    }
    Start-Sleep -Milliseconds 80
}

# ===== Phase 5: Parse specs from product names =====
Write-Status '{"phase":"parse","message":"Parsing product specs from names..."}'

# Helper: extract specs from name+color+attrs (cash register / scale focused)
# Priority: Attrs (structured) > Color (variant spec) > Name (product title)
function Parse-Specs($name, $color, $attrs) {
    $specs = @{
        RAM=''; Disk=''; CPU=''; CPUModel=''; Model=''
        ScreenCount=''; ScreenType=''; System=''; SystemDetail=''
        AccessoryType=''; ProductType=''; AI=''
    }

    # ===== A) Parse structured Attrs first (CustomAttrListNew format: key:value^key:value) =====
    if ($attrs) {
        $attrParts = $attrs -split '\^'
        foreach ($part in $attrParts) {
            if ($part -match '^系统[:：](.+)') {
                $sys = $Matches[1].Trim()
                if ($sys -match 'Windows\s*(\d+)?') {
                    $specs.System = 'Windows'
                    if ($Matches[1]) { $specs.SystemDetail = "Windows $($Matches[1])" }
                } elseif ($sys -match 'Android|安卓') { $specs.System = 'Android' }
            }
            elseif ($part -match '屏幕数量[:：](.+)') {
                $sc = $Matches[1].Trim()
                if ($sc -match '双屏|单屏|无屏') { $specs.ScreenCount = $sc }
            }
            elseif ($part -match '屏幕类型[:：](.+)') {
                $st = $Matches[1].Trim()
                if ($st -match '电容|液晶|触摸|触控|高清|LED|LCD|IPS') { $specs.ScreenType = $st }
            }
        }
    }

    # ===== B) Parse Color field (variant spec string like "C7经济版双屏 8G+256G【酷睿i5】") =====
    if ($color) {
        # Model from Color
        if (-not $specs.Model -and $color -match '([A-Z]\d+)') { $specs.Model = $Matches[1] }
        # RAM+Disk from Color: "8G+256G", "4G+64G", "8+128G", "4+64G"
        if (-not $specs.RAM -and $color -match '(\d+)G?\s*\+\s*(\d+)G') {
            $specs.RAM = "$($Matches[1])G"; $specs.Disk = "$($Matches[2])G"
        }
        # Screen from Color
        if (-not $specs.ScreenCount -and $color -match '双屏|单屏|无屏') { $specs.ScreenCount = $Matches[0] }
        # CPU from Color
        if (-not $specs.CPUModel -and $color -match '酷睿\s*(i\d)') { $specs.CPU = 'Intel'; $specs.CPUModel = "酷睿$($Matches[1])" }
        if (-not $specs.System -and $color -match 'Windows') { $specs.System = 'Windows' }
        if (-not $specs.AI -and $color -match 'AI识别|Ai识别|智能识物|商品识别|自动识物') { $specs.AI = '是' }
    }

    # ===== C) Parse Name (product title — fallback for anything not found above) =====
    # --- RAM + Disk from name ---
    if (-not $specs.RAM) {
        # "8G+256G", "8G+512G", "8+256G", "4+64G", "4G+64G"
        if ($name -match '(\d+)G?\s*\+\s*(\d+)G') { $specs.RAM = "$($Matches[1])G"; $specs.Disk = "$($Matches[2])G" }
        # Standalone: "8G内存", "4G运存"
        elseif ($name -match '(\d+)G\s*(?:内存|运存|RAM)') { $specs.RAM = "$($Matches[1])G" }
        # Implicit: product name mentions "8G" or "4G" near RAM context
        elseif ($name -match '\b(\d+)G\b' -and $name -match '内存|运存') { $specs.RAM = "$($Matches[1])G" }
    }
    if (-not $specs.Disk) {
        if ($name -match '(\d+)G\s*(?:硬盘|存储|固态|SSD|闪存|大存储|大容量|大内存存储)') { $specs.Disk = "$($Matches[1])G" }
        elseif ($name -match '(\d+)G\s*(?:大|超大)\w{0,2}(?:存储|容量)') { $specs.Disk = "$($Matches[1])G" }
        # Fallback: "256G" in name (standalone storage mention)
        elseif (-not $specs.Disk -and $name -match '\b(\d+)G\b' -and $name -match '存储|硬盘|SSD|固态|闪存') { $specs.Disk = "$($Matches[1])G" }
    }

    # --- CPU from name ---
    if (-not $specs.CPU) {
        if ($name -match '酷睿\s*(i\d)') { $specs.CPU = 'Intel'; $specs.CPUModel = "酷睿$($Matches[1])" }
        elseif ($name -match 'Intel') { $specs.CPU = 'Intel' }
        elseif ($name -match '四核') { $specs.CPU = '四核' }
        elseif ($name -match '八核') { $specs.CPU = '八核' }
        elseif ($name -match '疾速') { $specs.CPU = '疾速处理器' }
    }

    # --- Model from name ---
    if (-not $specs.Model -and $name -match '([A-Z]\d+)') {
        $specs.Model = $Matches[1]
    }

    # --- Screen Count from name ---
    if (-not $specs.ScreenCount) {
        if ($name -match '双屏') { $specs.ScreenCount = '双屏' }
        elseif ($name -match '单屏') { $specs.ScreenCount = '单屏' }
        elseif ($name -match '无屏') { $specs.ScreenCount = '无屏' }
    }

    # --- Screen Type from name ---
    if (-not $specs.ScreenType -and $name -match '电容屏|液晶|触摸屏|触屏|触控屏|高清屏|LED|LCD') {
        $specs.ScreenType = $Matches[0]
    }

    # --- OS from name ---
    if (-not $specs.System) {
        if ($name -match 'Windows\s*(\d+)?') { $specs.System = 'Windows'; if ($Matches[1]) { $specs.SystemDetail = "Windows $($Matches[1])" } }
        elseif ($name -match 'Android|安卓') { $specs.System = 'Android' }
    }

    # --- AI from name ---
    if (-not $specs.AI -and $name -match 'AI识别|Ai识别|AI识物|智能识物|Ai商品识别|商品识别|自动识物|自动识别商品') { $specs.AI = '是' }

    # --- Accessory Type from name ---
    if ($name -match '打印纸|标签纸|小票纸|收银纸|热敏纸|价签纸|碳带|色带|墨水') { $specs.AccessoryType = '耗材' }
    elseif ($name -match '扫码枪|扫码平台|扫描枪|条码枪|扫描平台') { $specs.AccessoryType = '扫码设备' }
    elseif ($name -match '标签机|打印机|小票机|票据打印机|热敏打印机|标签打印机|厨房打印机') { $specs.AccessoryType = '打印设备' }
    elseif ($name -match '钱箱|收银箱|现金箱') { $specs.AccessoryType = '钱箱' }
    elseif ($name -match '监控|摄像头|录像|夜视') { $specs.AccessoryType = '监控设备' }
    elseif ($name -match '支架|壁挂|挂架|底座|立柱') { $specs.AccessoryType = '安装配件' }
    elseif ($name -match '会员卡|定制卡|IC卡|磁卡') { $specs.AccessoryType = '会员卡' }
    elseif ($name -match '存储卡|内存卡|TF卡|SD卡') { $specs.AccessoryType = '存储卡' }
    elseif ($name -match '\b(?:电子秤|收银秤|称重|台秤|条码秤|标签秤)\b') { $specs.AccessoryType = '' }  # main product, not accessory

    # --- Product Type from name ---
    if ($name -match '收银秤|称重收银|称重一体|收银称|电子称|条码秤|标签秤|智能称|称重秤') { $specs.ProductType = '收银秤' }
    elseif ($name -match '收银机|收银系统|收款机|POS机|收银终端|收银一体|一体收银|收银设备|零售收银') { $specs.ProductType = '收银机' }
    if ($specs.AccessoryType) { $specs.ProductType = '配件/' + $specs.AccessoryType }

    return $specs
}

# Parse specs for all target store SKUs
# Use FullName (from comment API) if available — it usually has richer specs than search page name
foreach ($sid in $allSkus.Keys) {
    $s = $allSkus[$sid]
    $parseName = if ($s.FullName) { $s.FullName } else { $s.Name }
    $sp = Parse-Specs $parseName $s.Color $s.Attrs
    $s.RAM = $sp.RAM; $s.Disk = $sp.Disk; $s.CPU = $sp.CPU; $s.CPUModel = $sp.CPUModel
    $s.Model = $sp.Model
    $s.ScreenCount = $sp.ScreenCount; $s.ScreenType = $sp.ScreenType
    $s.System = $sp.System; $s.SystemDetail = $sp.SystemDetail
    $s.AccessoryType = $sp.AccessoryType; $s.ProductType = $sp.ProductType; $s.AI = $sp.AI
}
Write-Status "{`"phase`":`"parse`",`"message`":`"Parsed specs for $($allSkus.Count) SKUs`"}"

# ===== Phase 6: Family grouping + spec propagation =====
Write-Status '{"phase":"family","message":"Grouping product families and propagating specs..."}'

function Get-BaseName($name) {
    $base = $name -replace '\s+', ' '
    $base = $base -replace '\s*\([^)]*\)\s*$', ''
    $base = $base -replace '\s*（[^）]*）\s*$', ''
    $base = $base -replace '\s*\[[^\]]*\]\s*$', ''
    return $base.Trim()
}

# Group by base name
$families = @{}
foreach ($sid in $allSkus.Keys) {
    $s = $allSkus[$sid]
    $base = Get-BaseName($s.Name)
    $s.BaseName = $base
    if (-not $families.ContainsKey($base)) {
        $families[$base] = [System.Collections.ArrayList]::new()
    }
    [void]$families[$base].Add($sid)
}

# Propagate specs within families
$famIdx = 0; $famTotal = $families.Count
$propagateKeys = @('RAM','Disk','CPU','CPUModel','Model','ScreenCount','ScreenType','System','SystemDetail','AI')
foreach ($base in $families.Keys) {
    $famIdx++
    $members = $families[$base]
    # Find best (first non-empty) specs across family
    $best = @{}
    foreach ($k in $propagateKeys) { $best[$k] = '' }
    foreach ($sid in $members) {
        $s = $allSkus[$sid]
        foreach ($k in $propagateKeys) {
            if ($s.$k -and -not $best[$k]) { $best[$k] = $s.$k }
        }
    }
    # Propagate to members
    foreach ($sid in $members) {
        $s = $allSkus[$sid]
        foreach ($k in $propagateKeys) {
            if (-not $s.$k) { $s.$k = $best[$k] }
        }
    }
    if ($famIdx % 5 -eq 0 -or $famIdx -eq $famTotal) {
        Write-Status "{`"phase`":`"family`",`"message`":`"Grouping product families... $famIdx / $famTotal`",`"current`":$famIdx,`"total`":$famTotal}"
    }
}
Write-Status "{`"phase`":`"family`",`"message`":`"Product families: $($families.Count)`"}"

# ===== Phase 7: Build output =====
Write-Status '{"phase":"output","message":"Building output..."}'

$skuArr = @()
foreach ($sid in $allSkus.Keys) {
    $s = $allSkus[$sid]
    $skuArr += [PSCustomObject]@{
        skuId = $sid; name = $s.Name; color = $s.Color; price = $s.Price
        commentCount = $s.CommentCount; avgScore = $s.AvgScore; goodRate = $s.GoodRate
        model = $s.Model; cpu = $s.CPU; cpuModel = $s.CPUModel; ram = $s.RAM; disk = $s.Disk
        screenCount = $s.ScreenCount; screenType = $s.ScreenType
        system = $s.System; systemDetail = $s.SystemDetail
        accessoryType = $s.AccessoryType; productType = $s.ProductType; ai = $s.AI
        baseName = $s.BaseName; attrs = $s.Attrs; extName = $s.ExtName
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
