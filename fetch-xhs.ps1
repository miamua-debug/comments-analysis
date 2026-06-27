# fetch-xhs.ps1 - Extract Xiaohongshu notes via opencli
# Usage: powershell -ExecutionPolicy Bypass -File fetch-xhs.ps1 -Keyword "收银机" -Limit 20 -Profile "hkzg2bpx"

param([string]$Keyword, [int]$Limit = 20, [string]$Profile = "hkzg2bpx")

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"

function Write-Status($json) {
    $line = "STATUS:$json"
    [Console]::WriteLine($line)
    [Console]::Out.Flush()
}

Write-Status '{"phase":"search","message":"Searching XHS notes..."}'

$tempDir = [System.IO.Path]::GetTempPath() + "xhs_notes\"
if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }

$searchFile = "$tempDir`search.json"

# ===== Step 1: Search =====
$searchCmd = "opencli --profile $Profile xiaohongshu search `"$Keyword`" --limit $Limit -f json"
try {
    $searchOutput = cmd /c $searchCmd 2`>`&1
    # Extract everything from first '[' to last ']' as JSON
    $rawStr = $searchOutput -join "`n"
    $jsonStart = $rawStr.IndexOf('[')
    $jsonEnd = $rawStr.LastIndexOf(']')
    if ($jsonStart -ge 0 -and $jsonEnd -gt $jsonStart) {
        $jsonStr = $rawStr.Substring($jsonStart, $jsonEnd - $jsonStart + 1)
    } else {
        $jsonStr = $rawStr.Trim()
    }
    if (-not $jsonStr.Trim() -or $jsonStr -eq '[]') { throw "No results from search" }
    [System.IO.File]::WriteAllText($searchFile, $jsonStr, [System.Text.Encoding]::UTF8)

    $searchData = $jsonStr | ConvertFrom-Json
    $total = if ($searchData -is [Array]) { $searchData.Count } else { 1 }
    Write-Status "{`"phase`":`"search`",`"message`":`"Found $total notes`",`"total`":$total}"
} catch {
    Write-Status "{`"phase`":`"search`",`"message`":`"Search failed: $_`"}"
    $total = 0
}

if ($total -eq 0) {
    [Console]::WriteLine('DATA:{"totalNotes":0,"notes":[]}')
    [Console]::Out.Flush()
    exit 0
}

# ===== Step 2: Get detail for each note =====
Write-Status "{`"phase`":`"detail`",`"message`":`"Fetching details for $total notes...`",`"total`":$total}"
$notes = @()
$idx = 0

foreach ($item in $searchData) {
    $idx++
    $url = $item.url
    $noteId = ''
    if ($url -match 'search_result/([a-f0-9]+)') { $noteId = $Matches[1] }

    $content = ''; $collects = '0'; $comments = '0'; $tags = ''

    if ($url) {
        try {
            $noteCmd = "opencli --profile $Profile xiaohongshu note `"$url`" -f json"
            $noteOutput = cmd /c $noteCmd 2`>`&1
            $rawNote = $noteOutput -join "`n"
            $ns = $rawNote.IndexOf('['); $ne = $rawNote.LastIndexOf(']')
            $noteJsonStr = if ($ns -ge 0 -and $ne -gt $ns) { $rawNote.Substring($ns, $ne - $ns + 1) } else { $rawNote.Trim() }
            if ($noteJsonStr.Trim() -and $noteJsonStr -ne '[]') {
                $detail = $noteJsonStr | ConvertFrom-Json
                foreach ($d in $detail) {
                    $fld = $d.field; $val = $d.value
                    if ($fld -eq 'content') { $content = $val }
                    elseif ($fld -eq 'collects') { $collects = $val }
                    elseif ($fld -eq 'comments') { $comments = $val }
                    elseif ($fld -eq 'tags') { $tags = $val }
                }
            }
        } catch { }
    }

    $notes += [PSCustomObject]@{
        index = $idx; noteId = $noteId; url = $url; title = $item.title
        content = ($content -replace "[\r\n]+", " ").Trim()
        likes = [string]$item.likes; comments = $comments; collects = $collects
        publishedAt = $item.published_at; author = $item.author; authorUrl = $item.author_url
        tags = $tags
    }

    if ($idx % 5 -eq 0 -or $idx -eq $total) {
        Write-Status "{`"phase`":`"detail`",`"message`":`"Fetched $idx / $total notes`",`"current`":$idx,`"total`":$total}"
    }
}

# ===== Step 3: Output =====
Write-Status "{`"phase`":`"complete`",`"totalNotes`":$($notes.Count)}"

$result = [PSCustomObject]@{
    keyword = $Keyword; totalNotes = $notes.Count
    notes = @($notes | ForEach-Object {
        [PSCustomObject]@{
            index = $_.index; noteId = $_.noteId; url = $_.url; title = $_.title
            content = $_.content; likes = $_.likes; comments = $_.comments
            collects = $_.collects; publishedAt = $_.publishedAt
            author = $_.author; authorUrl = $_.authorUrl; tags = $_.tags
        }
    })
}

$resultJson = $result | ConvertTo-Json -Depth 4 -Compress
[Console]::WriteLine("DATA:$resultJson")
[Console]::Out.Flush()
