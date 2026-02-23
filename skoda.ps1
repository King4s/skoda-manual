#Requires -Version 5.1
<#
.SYNOPSIS
    Download a SKODA digital owner's manual to local HTML (and optionally standalone).
.DESCRIPTION
    Authenticates via the Skoda entrypoint API using your car's VIN or part number.
    No browser, no cookies, no login required.
.PARAMETER Identifier
    VIN (17 chars, e.g. TMBZZZ3FZN1234567) or part number (e.g. 657012738AR).
.PARAMETER Language
    Language code, e.g. da_DK, en_GB, de_DE. Default: da_DK.
.PARAMETER Html
    Generate HTML output (default if no format flag is given).
.PARAMETER Standalone
    Embed all images and CSS into a single self-contained HTML file.
.PARAMETER ClearCache
    Delete .\cache\ and .\images\ and exit.
.PARAMETER Help
    Show this help text.
.EXAMPLE
    .\skoda.ps1
.EXAMPLE
    .\skoda.ps1 657012738AR da_DK -Html
.EXAMPLE
    .\skoda.ps1 TMBZZZ3FZN1234567 en_GB -Standalone
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string]$Identifier = "",
    [Parameter(Position = 1)] [string]$Language   = "da_DK",
    [switch]$Html,
    [switch]$Standalone,
    [switch]$ClearCache,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# ── Script-level state ────────────────────────────────────────────────────────
$script:Session        = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$script:Language       = $Language
$script:Identifier     = $Identifier
$script:Manual         = ""
$script:Referer        = "https://digital-manual.skoda-auto.com/"
$script:DoHtml         = $Html.IsPresent
$script:DoStandalone   = $Standalone.IsPresent
$script:MaxSect        = 100
$script:CurrentSection = 0
$script:TotalSections  = 0
$script:ActivateDelay  = $false
$script:TocContent     = $null

$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36'

# ── Helpers ───────────────────────────────────────────────────────────────────

function Write-Status {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Host $Message -ForegroundColor $Color
}

function Get-SectionId {
    param([string]$Link, [string]$Label)
    if ($Link -and $Link -ne 'null') { return $Link }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Label)
    return [Convert]::ToBase64String($bytes) -replace '\+', '-' -replace '/', '_' -replace '=', '~'
}

function Get-SafeFilename {
    param([string]$Raw)
    $s = $Raw -replace '[\/\\:*?"<>|()]', '_' -replace '\s+', '_' -replace '_+', '_'
    $s = $s.Trim('_')
    if (-not $s) { $s = 'manual' }
    return $s
}

function Count-Sections {
    param($Node)
    $count = 0
    if ($Node.linkTarget -and $Node.linkTarget -ne 'null') { $count++ }
    if ($Node.children) {
        foreach ($child in $Node.children) { $count += Count-Sections $child }
    }
    return $count
}

# ── Session ───────────────────────────────────────────────────────────────────

function Initialize-Session {
    $id = $script:Identifier
    if ($id -match '^[A-HJ-NPR-Z0-9]{17}$') {
        $body = "vin=$id&uiLanguage=$($script:Language)&importerId=004"
        Write-Status "Initialising session with VIN..."
    } else {
        $body = "partNumber=$id&uiLanguage=$($script:Language)&importerId=004"
        Write-Status "Initialising session with part number..."
    }

    $headers = @{
        'Content-Type'   = 'application/x-www-form-urlencoded'
        'Origin'         = 'https://www.skoda.dk'
        'Referer'        = 'https://www.skoda.dk/apps/manuals/Models'
        'User-Agent'     = $UA
        'Sec-Fetch-Site' = 'cross-site'
        'Sec-Fetch-Mode' = 'navigate'
        'Sec-Fetch-Dest' = 'document'
    }

    $script:Session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

    try {
        Invoke-WebRequest -Uri 'https://digital-manual.skoda-auto.com/api/entrypoint/V1/direct/' `
            -Method POST -Body $body -Headers $headers `
            -WebSession $script:Session -UseBasicParsing `
            -MaximumRedirection 5 | Out-Null
    } catch {
        # A 303 redirect may throw in some PS versions — that is expected
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -and $code -notin @(301, 302, 303, 307, 308)) {
            Write-Error "Session creation failed: $_"
            exit 1
        }
    }

    # Verify the session created a valid Direct_PN user
    try {
        $check = Invoke-RestMethod `
            -Uri 'https://digital-manual.skoda-auto.com/api/users/V1/getuser' `
            -WebSession $script:Session `
            -Headers @{ Accept = 'application/json'; 'User-Agent' = $UA } `
            -UseBasicParsing
        if ($check.username -ne 'Direct_PN') {
            Write-Error "Session invalid. Check that the VIN or part number is correct and belongs to a Skoda."
            exit 1
        }
    } catch {
        Write-Error "Session invalid: $_"
        exit 1
    }

    Write-Status "Session ready." "Green"
}

function Resolve-ManualId {
    $searchFile = ".\cache\manual_list_$($script:Language).json"
    if (Test-Path $searchFile) { Remove-Item $searchFile }

    Invoke-FetchFile ("https://digital-manual.skoda-auto.com/api/web/V6/search" +
        "?query=&facetfilters=topic-type_%7C_welcome&lang=$($script:Language)&page=0&pageSize=200") $searchFile

    $data = Get-Content $searchFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $data.results -or $data.results.Count -eq 0) {
        Write-Error "No manual found for this VIN/part number in language $($script:Language). Try en_GB."
        exit 1
    }
    $script:Manual = $data.results[0].topicId
    Write-Status "Manual resolved: $($script:Manual)"
}

# ── HTTP helpers ──────────────────────────────────────────────────────────────

function Invoke-FetchFile {
    param([string]$Url, [string]$Destination, [int]$Retry = 0)

    if ($Retry -ge 5) {
        Write-Error "Failed to fetch $Destination after 5 retries."
        exit 1
    }

    if ((Test-Path $Destination) -and (Get-Item $Destination).Length -gt 0) {
        Write-Host "  [cache] $Destination" -ForegroundColor DarkGray
        return
    }

    Write-Host "Fetching $Destination" -ForegroundColor Gray
    $dir = Split-Path $Destination -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    try {
        Invoke-WebRequest -Uri $Url -WebSession $script:Session -UseBasicParsing `
            -Headers @{
                Accept           = 'application/json, text/plain, */*'
                'Accept-Language'= 'en-GB,en;q=0.9'
                Referer          = $script:Referer
                'User-Agent'     = $UA
            } -OutFile $Destination
    } catch {
        Write-Warning "Fetch error for ${Url}: $_"
        return
    }

    $script:ActivateDelay = $true

    $content = Get-Content $Destination -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($content -match 'An Authentication object was not found in the SecurityContext') {
        Remove-Item $Destination
        Write-Status "Session expired — reinitialising..." "Yellow"
        Initialize-Session
        Invoke-FetchFile $Url $Destination ($Retry + 1)
    }
}

function Invoke-GrabImage {
    param([string]$Img, [string]$DestPath, [int]$Retry = 0)

    if (-not $Img -or $Img -eq 'null') { return }
    if ($Retry -ge 5) { Write-Warning "Failed to fetch image $Img after 5 retries. Skipping."; return }

    $destination = Join-Path $DestPath $Img

    if ((Test-Path $destination) -and (Get-Item $destination).Length -gt 0) {
        $content = Get-Content $destination -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($content -notmatch 'An Authentication object') {
            Write-Host "  [cache] image: $Img" -ForegroundColor DarkGray
            return
        }
        Remove-Item $destination
    }

    Write-Host "  Fetching image: $Img" -ForegroundColor Gray

    try {
        Invoke-WebRequest `
            -Uri "https://digital-manual.skoda-auto.com/public/media?lang=$($script:Language)&key=$Img" `
            -WebSession $script:Session -UseBasicParsing `
            -Headers @{
                Accept           = 'image/avif,image/webp,*/*'
                'Accept-Language'= 'en-GB,en;q=0.9'
                Referer          = $script:Referer
                'User-Agent'     = $UA
            } -OutFile $destination
    } catch {
        Write-Warning "Image fetch error ${Img}: $_"
        return
    }

    $script:ActivateDelay = $true

    $content = Get-Content $destination -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($content -match 'An Authentication object was not found in the SecurityContext') {
        Remove-Item $destination
        Write-Status "Session expired (image) — reinitialising..." "Yellow"
        Initialize-Session
        Invoke-GrabImage $Img $DestPath ($Retry + 1)
    }
}

# ── HTML generation ───────────────────────────────────────────────────────────

function Convert-SectionContentToHtml {
    param([string]$JsonPath)

    $data     = Get-Content $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $bodyHtml = [string]$data.bodyHtml

    # Process link states
    if ($data.linkState) {
        foreach ($entry in $data.linkState) {
            $key      = [regex]::Escape([string]$entry.id)
            $linkType = [string]$entry.linkType

            if ($linkType -eq 'dynamic') {
                $target = [string]$entry.target
                # Replace href="#" → href="#target" in the anchor that has id="key"
                # Pattern handles both attribute orderings
                $bodyHtml = $bodyHtml -replace "(<a(?:\s[^>]*)?\sid=""$key""[^>]*\shref="")#("")", "`${1}#$target`${2}"
                $bodyHtml = $bodyHtml -replace "(<a[^>]*\shref="")#(""[^>]*\sid=""$key"")", "`${1}#$target`${2}"
            } else {
                $bodyHtml = $bodyHtml -replace 'href="([^.]*)\.html#([^"]*)"', 'href="#$1"'
            }
        }
    }

    # Replace image data-src URLs with local paths
    $imgPattern = 'data-src="https://digital-manual\.skoda-auto\.com/default/public/media\?lang=' `
                  + [regex]::Escape($script:Language) + '&amp;key='
    $bodyHtml = $bodyHtml -replace $imgPattern, 'src="images/'

    return $bodyHtml
}

function Invoke-HandleSection {
    param($Node, [string]$CurrentPath)

    $sb    = New-Object System.Text.StringBuilder
    $label = ($Node.label -replace '<[^>]*>', '') -replace '/', ', '
    $link  = if ($Node.PSObject.Properties['linkTarget']) { [string]$Node.linkTarget } else { '' }
    $id    = Get-SectionId $link $label

    if ($id -and $id -ne 'null') {
        [void]$sb.Append("<div class='section' id='$id'>")
    } else {
        [void]$sb.Append("<div class='section'>")
    }
    [void]$sb.Append("<div class='section-label'>$label</div>")

    $workingPath = Join-Path $CurrentPath $label
    New-Item -ItemType Directory -Force -Path $workingPath | Out-Null

    if ($link -and $link -ne 'null') {
        $script:CurrentSection++
        Write-Host "[$($script:CurrentSection)/$($script:TotalSections)] $label" -ForegroundColor White

        $jsonPath = Join-Path $workingPath "$label.json"
        Invoke-FetchFile ("https://digital-manual.skoda-auto.com/api/vw-topic/V1/topic" +
            "?key=$link&displaytype=desktop&language=$($script:Language)") $jsonPath

        if ((Test-Path $jsonPath) -and (Get-Item $jsonPath).Length -gt 0) {
            $sectionHtml = Convert-SectionContentToHtml $jsonPath
            [void]$sb.Append($sectionHtml)

            # Download images referenced in this section
            $imgMatches = [regex]::Matches($sectionHtml, 'src="images/([^"]+)"')
            foreach ($m in $imgMatches) {
                $imgKey = $m.Groups[1].Value -replace '&amp;', '&'
                Invoke-GrabImage $imgKey '.\images'
            }
        }

        if ($script:ActivateDelay) {
            $delay = Get-Random -Minimum 5 -Maximum 15
            Write-Host "  Pausing $delay seconds..." -ForegroundColor DarkGray
            Start-Sleep -Seconds $delay
            $script:ActivateDelay = $false
        }
    }

    $childCount = if ($Node.children) { $Node.children.Count } else { 0 }
    $top        = [Math]::Min($childCount, $script:MaxSect)
    for ($i = 0; $i -lt $top; $i++) {
        [void]$sb.Append((Invoke-HandleSection $Node.children[$i] $workingPath))
    }

    [void]$sb.Append("</div>")
    return $sb.ToString()
}

function Invoke-HandleTocItem {
    param($Node)

    $sb    = New-Object System.Text.StringBuilder
    $label = ($Node.label -replace '<[^>]*>', '') -replace '/', ', '
    $link  = if ($Node.PSObject.Properties['linkTarget']) { [string]$Node.linkTarget } else { '' }
    $id    = Get-SectionId $link $label

    [void]$sb.Append("<li><a href='#$id'>$label</a><ol>")

    $childCount = if ($Node.children) { $Node.children.Count } else { 0 }
    $top        = [Math]::Min($childCount, $script:MaxSect)
    for ($i = 0; $i -lt $top; $i++) {
        [void]$sb.Append((Invoke-HandleTocItem $Node.children[$i]))
    }

    [void]$sb.Append("</ol></li>")
    return $sb.ToString()
}

function Invoke-HandleCover {
    param([string]$ManualListPath)

    $data   = Get-Content $ManualListPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $result = $data.results | Where-Object { $_.topicId -eq $script:Manual } | Select-Object -First 1
    if (-not $result) { return "" }

    $coverImage    = $result.previewImage
    $coverAbstract = $result.abstractText
    $coverPart     = if ($result.facets -and $result.facets.Count -gt 0 -and $result.facets[0].'1') {
                         $result.facets[0].'1'[0]
                     } else { "" }

    return @"
<div class="panel panel-default">
  <div class="panel-heading">
    <img class="content blockimage" src="./images/$coverImage" alt="Cover">
  </div>
  <div class="panel-body">
    <h1 class="card-title">$coverAbstract</h1>
    $coverPart
  </div>
</div>
"@
}

function New-ManualHtml {
    param([string]$ManualListPath, [string]$Title)

    $sb  = New-Object System.Text.StringBuilder
    $toc = $script:TocContent

    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine("<html lang=""$($script:Language)"">")
    [void]$sb.AppendLine('<head>')
    [void]$sb.AppendLine("<title>$Title</title>")
    [void]$sb.AppendLine('<meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="description" content="SKODA digital manual">')
    [void]$sb.AppendLine('<link href="bootstrap.css" rel="stylesheet" type="text/css"/>')
    [void]$sb.AppendLine('<link href="extra.css" rel="stylesheet" type="text/css"/>')
    [void]$sb.AppendLine('<style>')
    [void]$sb.AppendLine('@media print {')
    [void]$sb.AppendLine('  nav#toc { page-break-after: always; }')
    [void]$sb.AppendLine('  .section > .section-label { page-break-before: always; }')
    [void]$sb.AppendLine('  .section .section > .section-label { page-break-before: auto; }')
    [void]$sb.AppendLine('  img { max-width: 100% !important; page-break-inside: avoid; }')
    [void]$sb.AppendLine('  table { page-break-inside: avoid; }')
    [void]$sb.AppendLine('}')
    [void]$sb.AppendLine('</style>')
    [void]$sb.AppendLine('</head>')
    [void]$sb.AppendLine('<body>')

    # Cover
    Write-Status "Generating cover..."
    [void]$sb.AppendLine((Invoke-HandleCover $ManualListPath))

    # Table of contents
    Write-Status "Generating table of contents..."
    $tocLabel   = $toc[0].label
    $childCount = if ($toc[0].children) { $toc[0].children.Count } else { 0 }
    $top        = [Math]::Min($childCount, $script:MaxSect)

    [void]$sb.AppendLine('<nav id="toc" aria-labelledby="toc-label">')
    [void]$sb.AppendLine("<h2 id=""toc-label"">$tocLabel</h2>")
    [void]$sb.AppendLine('<ol>')
    for ($i = 0; $i -lt $top; $i++) {
        [void]$sb.AppendLine((Invoke-HandleTocItem $toc[0].children[$i]))
    }
    [void]$sb.AppendLine('</ol>')
    [void]$sb.AppendLine('</nav>')

    # Content
    [void]$sb.AppendLine((Invoke-HandleSection $toc[0] '.\cache'))

    [void]$sb.AppendLine('</body>')
    [void]$sb.AppendLine('</html>')

    return $sb.ToString()
}

function New-StandaloneHtml {
    param([string]$HtmlIn, [string]$HtmlOut)

    Write-Status "Embedding assets into standalone HTML..."
    $content = [System.IO.File]::ReadAllText($HtmlIn, [System.Text.Encoding]::UTF8)

    # Inline CSS files
    $content = [regex]::Replace($content,
        '<link[^>]+href="([^"]+\.css)"[^>]*/>', {
        param($m)
        $cssPath = $m.Groups[1].Value
        if (Test-Path $cssPath) {
            $css = [System.IO.File]::ReadAllText($cssPath, [System.Text.Encoding]::UTF8)
            return "<style>`n$css`n</style>"
        }
        return $m.Value
    })

    # Inline images
    $content = [regex]::Replace($content, 'src="(images/[^"]+)"', {
        param($m)
        $imgPath = $m.Groups[1].Value
        if (Test-Path $imgPath) {
            try {
                $bytes = [System.IO.File]::ReadAllBytes($imgPath)
                $b64   = [Convert]::ToBase64String($bytes)
                $ext   = [System.IO.Path]::GetExtension($imgPath).ToLower().TrimStart('.')
                $mime  = switch ($ext) {
                    'png'  { 'image/png' }
                    'jpg'  { 'image/jpeg' }
                    'jpeg' { 'image/jpeg' }
                    'gif'  { 'image/gif' }
                    'webp' { 'image/webp' }
                    'avif' { 'image/avif' }
                    'svg'  { 'image/svg+xml' }
                    default { 'application/octet-stream' }
                }
                return "src=""data:$mime;base64,$b64"""
            } catch {
                Write-Warning "Could not embed image $imgPath : $_"
            }
        }
        return $m.Value
    })

    [System.IO.File]::WriteAllText($HtmlOut, $content, [System.Text.Encoding]::UTF8)
    $sizeMb = [math]::Round((Get-Item $HtmlOut).Length / 1MB, 1)
    Write-Status "Standalone HTML written ($sizeMb MB)" "Green"
}

# ── Interactive menu ──────────────────────────────────────────────────────────

function Show-InteractiveMenu {
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        Write-Error "Interactive mode requires a terminal. Run with arguments instead (use -Help for usage)."
        exit 1
    }

    Write-Host ""
    Write-Host "=====================================================" -ForegroundColor Cyan
    Write-Host "       SKODA Manual Downloader" -ForegroundColor Cyan
    Write-Host "=====================================================" -ForegroundColor Cyan

    # Step 1: Language
    Write-Host ""
    Write-Host "Step 1/3 - Language" -ForegroundColor White
    Write-Host ""

    $langCodes = @("da_DK","en_GB","de_DE","cs_CZ","sk_SK","fr_FR","nl_NL","pl_PL","es_ES","it_IT")
    $langNames = @("Danish","English (UK)","German","Czech","Slovak","French","Dutch","Polish","Spanish","Italian")

    for ($i = 0; $i -lt $langCodes.Count; $i++) {
        Write-Host ("  {0,2})  {1,-12}  {2}" -f ($i + 1), $langCodes[$i], $langNames[$i])
    }
    Write-Host ("  {0,2})  Other" -f ($langCodes.Count + 1))
    Write-Host ""

    $langChoice = Read-Host "  Choose [1]"
    if (-not $langChoice) { $langChoice = "1" }
    $langIdx = [int]$langChoice - 1

    if ($langIdx -eq $langCodes.Count) {
        $script:Language = Read-Host "  Enter language code (e.g. sv_SE)"
    } elseif ($langIdx -ge 0 -and $langIdx -lt $langCodes.Count) {
        $script:Language = $langCodes[$langIdx]
    }
    Write-Host "  -> $($script:Language)" -ForegroundColor Green

    # Step 2: VIN or part number
    Write-Host ""
    Write-Host "Step 2/3 - VIN or part number" -ForegroundColor White
    Write-Host ""
    Write-Host "  Enter your car's VIN (17 chars, e.g. TMBZZZ3FZN1234567)"
    Write-Host "  or part number (e.g. 657012738AR)."
    Write-Host "  The VIN is on your registration documents or dashboard."
    Write-Host ""

    $idInput = Read-Host "  VIN or part number"
    if (-not $idInput) {
        Write-Error "No VIN or part number provided."
        exit 1
    }
    $script:Identifier = $idInput
    Write-Host "  -> $idInput" -ForegroundColor Green

    # Authenticate and resolve manual
    $script:Referer = "https://digital-manual.skoda-auto.com/w/$($script:Language)/"
    Initialize-Session
    Resolve-ManualId

    $listData   = Get-Content ".\cache\manual_list_$($script:Language).json" -Raw | ConvertFrom-Json
    $foundTitle = if ($listData.results[0].abstractText) { $listData.results[0].abstractText } else { "Unknown" }
    Write-Host "  -> Found: $foundTitle" -ForegroundColor Green

    # Step 3: Output format
    Write-Host ""
    Write-Host "Step 3/3 - Output format" -ForegroundColor White
    Write-Host ""
    Write-Host "  1)  HTML                 (folder with images/)"
    Write-Host "  2)  Standalone HTML      (single file, images embedded)"
    Write-Host "  3)  HTML + Standalone"
    Write-Host ""

    $fmtChoice = Read-Host "  Choose [1]"
    if (-not $fmtChoice) { $fmtChoice = "1" }

    switch ($fmtChoice) {
        "2" { $script:DoStandalone = $true }
        "3" { $script:DoHtml = $true; $script:DoStandalone = $true }
        default { $script:DoHtml = $true }
    }

    # Confirm
    Write-Host ""
    Write-Host "-----------------------------------------------------"
    Write-Host "  Manual:   $foundTitle"
    Write-Host "  Language: $($script:Language)"
    Write-Host -NoNewline "  Output:   "
    if ($script:DoHtml)       { Write-Host -NoNewline "HTML " }
    if ($script:DoStandalone) { Write-Host -NoNewline "Standalone" }
    Write-Host ""
    Write-Host "-----------------------------------------------------"
    Write-Host ""

    $confirm = Read-Host "  Start download? [Y/n]"
    if ($confirm -and $confirm -notmatch '^[Yy]') {
        Write-Host "  Aborted."
        exit 0
    }
    Write-Host ""
}

# ── Entry point ───────────────────────────────────────────────────────────────

if ($Help) {
    Write-Host @"

Usage: .\skoda.ps1 [OPTIONS] [VIN_OR_PARTNUMBER] [LANGUAGE]

  Run without arguments for interactive mode.

  VIN_OR_PARTNUMBER:
    VIN (17 chars)              e.g. TMBZZZ3FZN1234567
    Part number (VW/Skoda)      e.g. 657012738AR

Options:
  -Html          Generate HTML output (default)
  -Standalone    Embed all assets into a single HTML file
  -ClearCache    Delete .\cache\ and .\images\
  -Help          Show this help

Examples:
  .\skoda.ps1
  .\skoda.ps1 657012738AR da_DK -Html
  .\skoda.ps1 TMBZZZ3FZN1234567 en_GB -Html
  .\skoda.ps1 657012738AR da_DK -Standalone
  .\skoda.ps1 -ClearCache
"@
    exit 0
}

if ($ClearCache) {
    Write-Status "Clearing cache..."
    if (Test-Path '.\cache')  { Remove-Item '.\cache'  -Recurse -Force }
    if (Test-Path '.\images') { Remove-Item '.\images' -Recurse -Force }
    Write-Status "Done." "Green"
    exit 0
}

New-Item -ItemType Directory -Force -Path '.\cache'  | Out-Null
New-Item -ItemType Directory -Force -Path '.\images' | Out-Null

if (-not $script:Identifier) {
    Show-InteractiveMenu
} else {
    $script:Referer = "https://digital-manual.skoda-auto.com/w/$($script:Language)/"
    Initialize-Session
    Resolve-ManualId
    $script:Referer = "https://digital-manual.skoda-auto.com/w/$($script:Language)/show/$($script:Manual)?ct=$($script:Manual)"
}

if (-not $script:DoHtml -and -not $script:DoStandalone) {
    $script:DoHtml = $true
}

# Bootstrap CSS
if (-not (Test-Path '.\bootstrap.css')) {
    Write-Status "Downloading Bootstrap CSS..."
    Invoke-WebRequest -Uri 'https://maxcdn.bootstrapcdn.com/bootstrap/3.4.1/css/bootstrap.min.css' `
        -OutFile '.\bootstrap.css' -UseBasicParsing
}

# Fetch table of contents
Write-Status "Fetching table of contents: $($script:Manual) ($($script:Language))..."
$topicPath = '.\cache\topic.json'
Invoke-FetchFile ("https://digital-manual.skoda-auto.com/api/web/V6/topic" +
    "?key=$($script:Manual)&displaytype=topic&language=$($script:Language)&query=undefined") $topicPath

$manualListPath = ".\cache\manual_list_$($script:Language).json"
if (-not (Test-Path $manualListPath) -or (Get-Item $manualListPath).Length -eq 0) {
    Invoke-FetchFile ("https://digital-manual.skoda-auto.com/api/web/V6/search" +
        "?query=&facetfilters=topic-type_%7C_welcome&lang=$($script:Language)&page=0&pageSize=200") $manualListPath
}

# Cover image
$manualListData = Get-Content $manualListPath -Raw | ConvertFrom-Json
$coverImg = ($manualListData.results | Where-Object { $_.topicId -eq $script:Manual } |
    Select-Object -First 1).previewImage
if ($coverImg) { Invoke-GrabImage $coverImg '.\images' }

# Parse TOC
$topicData         = Get-Content $topicPath -Raw | ConvertFrom-Json
$script:TocContent = $topicData.trees
$title             = [string]$script:TocContent[0].label

# Count sections
$script:TotalSections = Count-Sections $script:TocContent[0]
Write-Status "Manual: $title — $($script:TotalSections) sections"

# Output filenames
$manualNameRaw = ($manualListData.results | Where-Object { $_.topicId -eq $script:Manual } |
    Select-Object -First 1).abstractText
if (-not $manualNameRaw) { $manualNameRaw = $title }
if (-not $manualNameRaw) { $manualNameRaw = $script:Manual }

$manualName       = Get-SafeFilename $manualNameRaw
$timestamp        = Get-Date -Format 'dd-MM-yyyy_HH-mm-ss'
$outputBase       = "${manualName}_$($script:Language)_${timestamp}"
$outputHtml       = ".\${outputBase}.html"
$outputStandalone = ".\${outputBase}_standalone.html"
Write-Status "Output base: $outputBase"

# Generate HTML
Write-Status "Generating HTML..."
$htmlContent = New-ManualHtml $manualListPath $title
[System.IO.File]::WriteAllText($outputHtml, $htmlContent, [System.Text.Encoding]::UTF8)
$sizeMb = [math]::Round((Get-Item $outputHtml).Length / 1MB, 1)
Write-Status "HTML written ($sizeMb MB)" "Green"

# Standalone
if ($script:DoStandalone) {
    New-StandaloneHtml $outputHtml $outputStandalone
}

# Summary
Write-Host ""
Write-Status "Done." "Green"
if ($script:DoHtml)       { Write-Host "  HTML:       $(Resolve-Path $outputHtml)" }
if ($script:DoStandalone) { Write-Host "  Standalone: $(Resolve-Path $outputStandalone)" }
