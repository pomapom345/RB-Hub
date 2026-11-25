# extract-inventory.ps1
# Reads the source inventory PDF (List.pdf) and extracts every hyperlinked
# repository path it contains. The PDF is a print of a GitHub directory
# listing, so each row carries a link of the form
#   https://github.com/<user>/<repo>/(tree|blob)/master/<path>
# Those links are the most reliable machine-readable form of the inventory.
#
# Output: data/inventory.raw.txt    (lines: "<tree|blob>\t<path>", deduplicated)

param(
    [string]$PdfPath = "C:\Users\Admin\Downloads\List.pdf",
    [string]$OutPath = (Join-Path $PSScriptRoot "..\data\inventory.raw.txt")
)

$bytes = [System.IO.File]::ReadAllBytes($PdfPath)
# Latin-1 maps every byte to one char, so binary-safe regex scanning works.
$text = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)

# PDF literal strings escape ( ) \ -- allow escaped chars inside.
$uriRx = [regex]'/URI \((?:[^()\\]|\\.)*\)'
$linkRx = [regex]'^https://github\.com/[^/]+/[^/]+/(tree|blob)/master/(.*)$'

$rows = New-Object System.Collections.Generic.HashSet[string]

foreach ($match in $uriRx.Matches($text)) {
    $uri = $match.Value.Substring(6, $match.Value.Length - 7)
    $uri = $uri -replace '\\(.)', '$1'          # unescape \( \) \\
    $link = $linkRx.Match($uri)
    if (-not $link.Success) { continue }
    $kind = $link.Groups[1].Value
    $path = [System.Uri]::UnescapeDataString($link.Groups[2].Value) -replace '\\', '/'
    [void]$rows.Add("$kind`t$path")
}

$sorted = $rows | Sort-Object { ($_ -split "`t")[1] }

$dir = Split-Path -Parent $OutPath
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
$sorted | Set-Content -Path $OutPath -Encoding utf8

Write-Host ("Extracted {0} unique linked entries from {1}" -f $rows.Count, $PdfPath)
