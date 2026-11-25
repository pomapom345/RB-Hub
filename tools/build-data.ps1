# build-data.ps1
# Builds the central RB Hub dataset from the extracted PDF inventory plus the
# hand-curated metadata files.
#
#   data/inventory.raw.txt   <- produced by tools/extract-inventory.ps1
#   data/curated/*.json      <- curated facts (title, year, developer, genre...)
#   data/platforms.json      <- platform reference data
#
# Outputs
#   assets/js/rb-data.js     <- window.RB_DATA = { meta, platforms, genres, games }
#   data/games.json          <- the same dataset as plain JSON (reference copy)
#
# Rules
#  * Never invent a fact. Missing values stay null and are rendered as
#    "Not available" by the site.
#  * Non-game files (music, emulator binaries, save states, config files) are
#    excluded and reported.
#  * Variants of the same game are grouped, but every original filename is kept.

[CmdletBinding()]
param(
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $Root = Split-Path -Parent $scriptDir
}
$Root = (Resolve-Path $Root).Path

$inventoryPath = Join-Path $Root 'data/inventory.raw.txt'
$curatedDir    = Join-Path $Root 'data/curated'
$platformsPath = Join-Path $Root 'data/platforms.json'
$outJs         = Join-Path $Root 'assets/js/rb-data.js'
$outJson       = Join-Path $Root 'data/games.json'

function Write-Step($msg) { Write-Host "  $msg" }

# ---------------------------------------------------------------- helpers ----

$accentMap = @{
    [char]0x00E0='a'; [char]0x00E1='a'; [char]0x00E2='a'; [char]0x00E3='a'; [char]0x00E4='a'; [char]0x00E5='a'; [char]0x0101='a'
    [char]0x00E8='e'; [char]0x00E9='e'; [char]0x00EA='e'; [char]0x00EB='e'; [char]0x0113='e'
    [char]0x00EC='i'; [char]0x00ED='i'; [char]0x00EE='i'; [char]0x00EF='i'; [char]0x012B='i'
    [char]0x00F2='o'; [char]0x00F3='o'; [char]0x00F4='o'; [char]0x00F5='o'; [char]0x00F6='o'; [char]0x014D='o'
    [char]0x00F9='u'; [char]0x00FA='u'; [char]0x00FB='u'; [char]0x00FC='u'; [char]0x016B='u'
    [char]0x00F1='n'; [char]0x00E7='c'; [char]0x00DF='ss'; [char]0x00F8='o'; [char]0x00E6='ae'; [char]0x0153='oe'
    [char]0x2019="'"; [char]0x2018="'"; [char]0x201C='"'; [char]0x201D='"'
}

function ConvertTo-Ascii([string]$text) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $text.ToCharArray()) {
        if ($accentMap.ContainsKey($ch)) { [void]$sb.Append($accentMap[$ch]) }
        else { [void]$sb.Append($ch) }
    }
    $sb.ToString()
}

function Get-Slug([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return 'item' }
    $s = ConvertTo-Ascii $text
    $s = $s.ToLowerInvariant()
    $s = $s -replace '[^a-z0-9]+', '-'
    $s = $s.Trim('-')
    if ($s -eq '') { $s = 'item' }
    return $s
}

function Get-GroupKey([string]$text) {
    $s = ConvertTo-Ascii $text
    $s = $s.ToLowerInvariant()
    $s = $s -replace '^the\s+', ''
    $s = $s -replace '[^a-z0-9]+', ''
    return $s
}

# Title-case a filename-derived title, keeping words that already carry
# intentional capitals (e.g. "RBI Baseball", "McDonald's").
function Get-DisplayTitle([string]$raw) {
    $t = $raw -replace '_', ' '
    $t = $t -replace '\s+', ' '
    $t = $t.Trim()
    if ($t -cnotmatch '[a-z]') {
        $t = (Get-Culture).TextInfo.ToTitleCase($t.ToLowerInvariant())
    }
    elseif ($t -cmatch '^[a-z]') {
        $words = $t -split ' '
        for ($i = 0; $i -lt $words.Count; $i++) {
            if ($words[$i].Length -gt 1) {
                $words[$i] = $words[$i].Substring(0,1).ToUpperInvariant() + $words[$i].Substring(1)
            }
        }
        $t = $words -join ' '
    }
    return $t
}

# --- filename / tag parsing -------------------------------------------------

$regionTokens = @{
    'USA'='USA'; 'US'='USA'; 'U'='USA'; 'Europe'='Europe'; 'E'='Europe';
    'Japan'='Japan'; 'J'='Japan'; 'World'='World'; 'W'='World';
    'Germany'='Germany'; 'France'='France'; 'Spain'='Spain'; 'Italy'='Italy';
    'Australia'='Australia'; 'Korea'='Korea'; 'China'='China'; 'Brazil'='Brazil';
    'Taiwan'='Taiwan'; 'Canada'='Canada'; 'Netherlands'='Netherlands';
    'Sweden'='Sweden'; 'Denmark'='Denmark'; 'Finland'='Finland';
    'Norway'='Norway'; 'Russia'='Russia'; 'Asia'='Asia'; 'K'='Korea';
    'S'='Spain'; 'C'='China'; 'Ch'='China'; 'UK'='United Kingdom';
    'United Kingdom'='United Kingdom'; 'Hong Kong'='Hong Kong'; 'NL'='Netherlands'
}

function Parse-RomName([string]$fileName) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    $tags = New-Object System.Collections.Generic.List[string]

    foreach ($m in [regex]::Matches($name, '\(([^()]*)\)')) { $tags.Add($m.Groups[1].Value.Trim()) }
    foreach ($m in [regex]::Matches($name, '\[([^\[\]]*)\]')) { $tags.Add($m.Groups[1].Value.Trim()) }

    $base = [regex]::Replace($name, '\([^()]*\)', ' ')
    $base = [regex]::Replace($base, '\[[^\[\]]*\]', ' ')
    $base = $base -replace '\s+', ' '
    $base = $base.Trim(' ', '-', '_')

    # Drop a leading catalogue number such as "0201 - "
    $base = $base -replace '^\d{3,4}\s*-\s*', ''

    $region = $null; $rev = $null; $status = $null; $langs = $null
    $other = New-Object System.Collections.Generic.List[string]

    foreach ($tag in $tags) {
        if ($regionTokens.ContainsKey($tag) -and $region -eq $null) { $region = $regionTokens[$tag]; continue }
        if ($tag -match '^(Rev|Revision)\s*(.+)$') { $rev = 'Rev ' + $matches[2]; continue }
        if ($tag -match '^(Proto|Prototype|Beta|Sample|Demo|Unl|Pirate|NP|Hack)$') { $status = $tag; continue }
        if ($tag -match '^([A-Z][a-z])(,[A-Z][a-z])+$') { $langs = $tag; continue }
        if ($tag -match '^[A-Z][a-z]$') { $langs = $tag; continue }
        if ($tag -match '^\d-\d$') { $status = 'Hack tag [' + $tag + ']'; continue }
        if ($tag -eq '!') { continue }
        if ($tag -match '^[a-z]$') { $status = 'Bad dump tag [' + $tag + ']'; continue }
        $other.Add($tag)
    }

    return [pscustomobject]@{
        RawName   = $name
        Title     = Get-DisplayTitle $base
        Region    = $region
        Revision  = $rev
        Status    = $status
        Languages = $langs
        Tags      = $other.ToArray()
        AllTags   = $tags.ToArray()
    }
}

# --- genre inference (conservative, title-keyword based) --------------------

$genreRules = @(
    @{ rx = '(?i)\b(kart|racing|race|grand prix|f-?zero|nascar|rally|speedway|drift|super sprint|pole position|micro machines)\b'; g = 'Racing' },
    @{ rx = '(?i)\b(golf|tennis|baseball|soccer|football|hockey|basketball|bowling|volleyball|boxing|wrestling|billiards|darts|skate|ski|slalom|surf|fishing|olympic|sports|stadium|league|superbowl|pro am)\b'; g = 'Sports' },
    @{ rx = '(?i)\b(tetris|puzzle|columns|klax|hatris|puyo|boulder dash|solomon|loopz|pipe dream|mendel|bust-a-move|arkanoid|q\*bert|q bert)\b'; g = 'Puzzle' },
    @{ rx = '(?i)\b(street fighter|mortal kombat|killer instinct|fatal fury|samurai shodown|fighting|fighter|karate|kung fu|art of fighting|clay fighter|brawl)\b'; g = 'Fighting' },
    @{ rx = '(?i)\b(final fantasy|dragon warrior|dragon quest|earthbound|mother 3|the legend of zelda|breath of fire|chrono|secret of mana|ultima|wizardry|rpg|lufia|phantasy star|fire emblem)\b'; g = 'RPG' },
    @{ rx = '(?i)\b(gradius|xeviou?|r-?type|salamander|1942|1943|zaxxon|galaga|galaxian|space invaders|contra|shooter|thunder|raiden|darius|soldier|heli|jet|aircraft)\b'; g = 'Shooter' },
    @{ rx = '(?i)\b(maniac mansion|shadowgate|deja vu|adventure|mystery|quest for|uninvited|startropics)\b'; g = 'Adventure' },
    @{ rx = '(?i)\b(mario|sonic|kirby|platform|boy and his blob|lolo|bomberman|wario|yoshi)\b'; g = 'Platformer' }
)

function Get-InferredGenre([string]$title) {
    foreach ($rule in $genreRules) {
        if ($title -match $rule.rx) { return $rule.g }
    }
    return $null
}

# --------------------------------------------------------------- load data ---

Write-Host 'RB Hub dataset build'
Write-Step "inventory: $inventoryPath"
Write-Step "curated:   $curatedDir"

if (-not (Test-Path $inventoryPath)) { throw "Missing $inventoryPath - run tools/extract-inventory.ps1 first." }

$curated = @{}
foreach ($file in Get-ChildItem $curatedDir -Filter '*.json') {
    $json = Get-Content -Raw -Encoding UTF8 -Path $file.FullName | ConvertFrom-Json
    foreach ($prop in $json.PSObject.Properties) {
        if ($prop.Name.StartsWith('_')) { continue }
        $curated[$prop.Name] = $prop.Value
    }
}
Write-Step "curated records: $($curated.Count)"

$platformsJson = Get-Content -Raw -Encoding UTF8 -Path $platformsPath | ConvertFrom-Json
$platformOrder = @('arcade','nes','snes','atari2600','gba','nds','n64','homebrew')

# Inventory folder name -> platform id. The LÖVE homebrew package lives in a
# folder called "love" but belongs to the "homebrew" platform.
$folderToPlatform = @{ 'love' = 'homebrew' }

# Files that are not games. Extensions are rejected outright; specific paths
# are excluded because they are emulator binaries or metadata inside a folder.
$junkExtensions = @('.mp3','.txt','.ini','.dll','.exe','.state','.srm','.eep','.mpk','.dsv','.pal','.diz','.sav','.cfg')
$excludedPaths  = @{
    'arcade/EPROM' = 'Folder of raw EPROM dump files, not a playable ROM set'
}

# ------------------------------------------------------------ read inventory -

$entries = New-Object System.Collections.Generic.List[object]
$excluded = New-Object System.Collections.Generic.List[object]
$unknownPlatforms = @{}

foreach ($line in Get-Content -Encoding UTF8 -Path $inventoryPath) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $parts = $line -split "`t", 2
    if ($parts.Count -lt 2) { continue }
    $kind = $parts[0].Trim()
    $path = $parts[1].Trim()
    $folder = ($path -split '/')[0]
    $platformId = if ($folderToPlatform.ContainsKey($folder)) { $folderToPlatform[$folder] } else { $folder }
    $fileName = Split-Path $path -Leaf
    $ext = [System.IO.Path]::GetExtension($fileName).ToLowerInvariant()

    if ($excludedPaths.ContainsKey($path)) {
        $excluded.Add([pscustomobject]@{ path = $path; reason = $excludedPaths[$path] })
        continue
    }
    if ($junkExtensions -contains $ext) {
        $reason = switch ($ext) {
            '.mp3'   { 'Music file' }
            '.txt'   { 'Text document' }
            '.ini'   { 'Emulator configuration file' }
            '.dll'   { 'Emulator library' }
            '.exe'   { 'Emulator executable' }
            '.state' { 'Emulator save state' }
            '.srm'   { 'Battery save file' }
            '.eep'   { 'EEPROM save file' }
            '.mpk'   { 'Controller Pak save file' }
            '.dsv'   { 'DeSmuME save file' }
            '.pal'   { 'Emulator palette file' }
            '.diz'   { 'Release metadata file' }
            '.sav'   { 'Save file' }
            '.cfg'   { 'Configuration file' }
            default  { 'Non-game file' }
        }
        $excluded.Add([pscustomobject]@{ path = $path; reason = $reason })
        continue
    }
    if ($folder -eq 'music') {
        $excluded.Add([pscustomobject]@{ path = $path; reason = 'Music file' })
        continue
    }
    if (-not $platformOrder.Contains($platformId)) {
        if (-not $unknownPlatforms.ContainsKey($folder)) { $unknownPlatforms[$folder] = 0 }
        $unknownPlatforms[$folder]++
        $excluded.Add([pscustomobject]@{ path = $path; reason = "Folder '$folder' is not a recognised platform" })
        continue
    }

    $isDir = ($kind -eq 'tree')
    $parsed = Parse-RomName $fileName
    $c = $null
    if ($curated.ContainsKey($path)) { $c = $curated[$path] }

    $title = if ($c -and $c.title) { $c.title } else { $parsed.Title }
    if ($folder -eq 'arcade' -and -not $c) { $title = $fileName }

    $groupText = if ($c -and $c.group) { $c.group } elseif ($c -and $c.title) { $c.title } else { $parsed.Title }
    $groupKey = Get-GroupKey $(if ($c -and $c.group) { $c.group } else { $groupText })
    if ([string]::IsNullOrWhiteSpace($groupKey)) { $groupKey = Get-Slug $fileName }

    $genre = if ($c -and $c.genre) { $c.genre } else { Get-InferredGenre $title }
    $genreSource = if ($c -and $c.genre) { 'curated' } elseif ($genre) { 'title-inferred' } else { 'unknown' }

    $entries.Add([pscustomobject]@{
        path        = $path
        kind        = $kind
        fileName    = $fileName
        extension   = $ext
        isDir       = $isDir
        platform    = $platformId
        title       = $title
        groupKey    = $groupKey
        region      = if ($c -and $c.region) { $c.region } else { $parsed.Region }
        revision    = $parsed.Revision
        status      = $parsed.Status
        languages   = $parsed.Languages
        tags        = $parsed.Tags
        genre       = $genre
        genreSource = $genreSource
        curated     = $c
        parsed      = $parsed
    })
}

# A curated key that never matched the inventory is a bug or a typo.
$inventoryPaths = @{}
foreach ($e in $entries) { $inventoryPaths[$e.path] = $true }
$orphanCurated = @($curated.Keys | Where-Object { -not $inventoryPaths.ContainsKey($_) })

# ------------------------------------------------------------- group games ---

$groups = @{}
foreach ($e in $entries) {
    $key = $e.platform + '::' + $e.groupKey
    if (-not $groups.ContainsKey($key)) { $groups[$key] = New-Object System.Collections.Generic.List[object] }
    $groups[$key].Add($e)
}

function Get-VariantScore($entry) {
    $score = 0
    if ($entry.curated) { $score += 40 }
    if ($entry.region -eq 'USA') { $score += 14 }
    elseif ($entry.region -eq 'World') { $score += 13 }
    elseif ($entry.region -eq 'Europe') { $score += 12 }
    elseif ($entry.region -eq 'Japan') { $score += 4 }
    if ($entry.region) { } else { $score += 12 }
    if (-not $entry.status) { $score += 6 }
    if ($entry.status -match '(?i)beta|proto|sample') { $score -= 4 }
    if ($entry.kind -eq 'blob') { $score += 1 }
    return $score
}

$games = New-Object System.Collections.Generic.List[object]
$usedIds = @{}

foreach ($key in $groups.Keys) {
    $list = $groups[$key]
    $primary = $list | Sort-Object -Property @{ Expression = { Get-VariantScore $_ } } -Descending | Select-Object -First 1
    $c = $primary.curated
    if (-not $c) {
        foreach ($e in $list) { if ($e.curated) { $c = $e.curated; break } }
    }

    $platformId = $primary.platform
    $platform = $platformsJson.$platformId

    $title = if ($c -and $c.title) { $c.title } else { $primary.title }
    $slugBase = if ($c -and $c.slug) { $c.slug } else { Get-Slug $title }
    $id = "$platformId-$slugBase"
    if ($usedIds.ContainsKey($id)) {
        $n = 2
        while ($usedIds.ContainsKey("$id-$n")) { $n++ }
        $id = "$id-$n"
    }
    $usedIds[$id] = $true

    $variants = New-Object System.Collections.Generic.List[object]
    foreach ($e in ($list | Sort-Object -Property @{ Expression = { $_.fileName } })) {
        $variants.Add([pscustomobject]@{
            file      = $e.path
            fileName  = $e.fileName
            kind      = if ($e.isDir) { 'folder' } else { 'file' }
            extension = $e.extension
            region    = $e.region
            revision  = $e.revision
            status    = $e.status
            languages = $e.languages
            tags      = $e.tags
        })
    }

    $verified = $true
    if ($c -and $c.PSObject.Properties.Name -contains 'verified') { $verified = [bool]$c.verified }
    if (-not $c) { $verified = $false }

    $game = [pscustomobject]@{
        id            = $id
        title         = $title
        platform      = $platformId
        platformName  = $platform.name
        genre         = if ($c -and $c.genre) { $c.genre } elseif ($primary.genre) { $primary.genre } else { $null }
        genreSource   = if ($c -and $c.genre) { 'curated' } elseif ($primary.genre) { 'title-inferred' } else { 'unknown' }
        year          = if ($c -and $c.year) { [int]$c.year } else { $null }
        developer     = if ($c -and $c.developer) { $c.developer } else { $null }
        publisher     = if ($c -and $c.publisher) { $c.publisher } else { $null }
        desc          = if ($c -and $c.desc) { $c.desc } else { $null }
        gameplay      = if ($c -and $c.gameplay) { $c.gameplay } else { $null }
        history       = if ($c -and $c.history) { $c.history } else { $null }
        notes         = if ($c -and $c.notes) { $c.notes } else { $null }
        hardware      = if ($c -and $c.hardware) { $c.hardware } else { $null }
        official      = if ($c -and $c.official) { $c.official } else { $null }
        verified      = $verified
        primaryFile   = $primary.path
        emulator      = $platform.emulator
        compatibility = $platform.compatibility
        difficulty    = $platform.difficulty
        variants      = $variants.ToArray()
    }
    $games.Add($game)
}

# ------------------------------------------------------------------ output ---

$platformsOut = New-Object System.Collections.Generic.List[object]
foreach ($platId in $platformOrder) {
    $p = $platformsJson.$platId
    $count = @($games | Where-Object { $_.platform -eq $platId }).Count
    $entryCount = @($entries | Where-Object { $_.platform -eq $platId }).Count
    $platformsOut.Add([pscustomobject]@{
        id                = $platId
        name              = $p.name
        shortName         = $p.shortName
        tagline           = $p.tagline
        description       = $p.description
        longDescription   = $p.longDescription
        hardware          = $p.hardware
        emulator          = $p.emulator
        compatibility     = $p.compatibility
        compatibilityNote = $p.compatibilityNote
        piModels          = $p.piModels
        controller        = $p.controller
        install           = $p.install
        difficulty        = $p.difficulty
        resources         = @($p.resources)
        gameCount         = $count
        entryCount        = $entryCount
    })
}

$genreCounts = @{}
foreach ($g in $games) {
    $name = if ($g.genre) { $g.genre } else { 'Not verified' }
    if (-not $genreCounts.ContainsKey($name)) { $genreCounts[$name] = 0 }
    $genreCounts[$name]++
}
$genreList = @($genreCounts.Keys | Sort-Object)

$sortedGames = @($games | Sort-Object -Property @{ Expression = { $_.title.ToLowerInvariant() } })

$years = @($games | Where-Object { $_.year } | ForEach-Object { $_.year })
$yearMin = if ($years.Count) { ($years | Measure-Object -Minimum).Minimum } else { $null }
$yearMax = if ($years.Count) { ($years | Measure-Object -Maximum).Maximum } else { $null }

$data = [pscustomobject]@{
    meta = [pscustomobject]@{
        name           = 'RB Hub'
        tagline        = 'Your Gateway to Retro Gaming.'
        source         = 'List.pdf (inventory export of github.com/Shugabuga/RomCollection)'
        generated      = (Get-Date).ToString('yyyy-MM-dd')
        totalGames     = $games.Count
        totalEntries   = $entries.Count
        totalPlatforms = $platformOrder.Count
        excludedCount  = $excluded.Count
        yearMin        = $yearMin
        yearMax        = $yearMax
        curatedCount   = @($games | Where-Object { $_.verified -eq $true -and $_.desc }).Count
        excluded       = @($excluded | Sort-Object path)
        orphanCurated  = @($orphanCurated | Sort-Object { $_ })
    }
    platforms = $platformsOut.ToArray()
    genres    = $genreList
    games     = $sortedGames
}

$json = $data | ConvertTo-Json -Depth 12 -Compress

$dir = Split-Path -Parent $outJs
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

$header = "/* RB Hub collection dataset - generated by tools/build-data.ps1. Do not edit by hand. */`n"
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($outJs, $header + 'window.RB_DATA = ' + $json + ';' + "`n", $utf8)
[System.IO.File]::WriteAllText($outJson, ($data | ConvertTo-Json -Depth 12), $utf8)

Write-Host ''
Write-Host "  games:     $($games.Count)"
Write-Host "  inventory: $($entries.Count)"
Write-Host "  excluded:  $($excluded.Count)"
Write-Host "  curated:   $($data.meta.curatedCount)"
Write-Host "  output:    $outJs"

if ($orphanCurated.Count) {
    Write-Host ''
    Write-Host '  WARNING: curated keys not found in the inventory:' -ForegroundColor Yellow
    foreach ($k in $orphanCurated) { Write-Host "    - $k" -ForegroundColor Yellow }
}
if ($unknownPlatforms.Count) {
    Write-Host ''
    Write-Host '  WARNING: unknown platform folders:' -ForegroundColor Yellow
    foreach ($k in $unknownPlatforms.Keys) { Write-Host "    - $k ($($unknownPlatforms[$k]) entries)" -ForegroundColor Yellow }
}


