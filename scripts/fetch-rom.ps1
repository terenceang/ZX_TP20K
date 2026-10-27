# ============================================================================
#  scripts/fetch-rom.ps1 -- fetch the ZX Spectrum 48K ROM and make the hex
#
#    scripts\fetch-rom.ps1              download (if needed) + verify + convert
#
#  The ROM is Amstrad's copyright; it is not in this repo (roms/README.md has
#  the permission that lets you fetch it).  The copy is verified against the
#  published SHA-256 before anything is written, so a truncated or wrong
#  mirror cannot pass silently.  Outputs:
#      roms\zx48.rom   the 16K binary
#      roms\zx48.hex   one byte per line, what src/zx_core.v $readmemh's
#
#  Skips the download when roms\zx48.rom is already present and correct.
# ============================================================================
[CmdletBinding()]
param(
    [string]$Url = 'https://raw.githubusercontent.com/rastersoft/fbzx/master/data/spectrum-roms/48.rom'
)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$romPath = Join-Path $root 'roms\zx48.rom'
$hexPath = Join-Path $root 'roms\zx48.hex'

# The canonical 48K ROM: MD5 4c42a2f075212361c3117015b107ff68,
# SHA-1 5ea7c2b824672e914525d1d5c419d71b84a426a2 (sinclair.wiki.zxnet.co.uk).
$expectedSha256 = 'D55DAA439B673B0E3F5897F99AC37ECB45F974D1862B4DADB85DEC34AF99CB42'

function Get-RomSha256([byte[]]$bytes) {
    ([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes) |
        ForEach-Object { $_.ToString('x2') }) -join ''
}

if ((Test-Path $romPath) -and (Get-RomSha256 ([System.IO.File]::ReadAllBytes($romPath))) -eq $expectedSha256.ToLower()) {
    Write-Host "== roms\zx48.rom already present and verified"
} else {
    Write-Host "== fetching the ZX Spectrum 48K ROM"
    Write-Host "   $Url"
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing
    $bytes = $response.Content
    if ($bytes.Length -ne 16384) { throw "expected 16384 bytes, got $($bytes.Length)" }
    $sha = Get-RomSha256 $bytes
    if ($sha -ne $expectedSha256.ToLower()) {
        throw "SHA-256 mismatch: got $sha, expected $expectedSha256`nThe URL may be gone or wrong; see roms\README.md for alternatives."
    }
    [System.IO.File]::WriteAllBytes($romPath, $bytes)
    Write-Host "   verified $sha"
}

# One byte per line, uppercase hex -- the $readmemh file.  The first bytes
# are DI; XOR A; LD DE,$FFFF, a fingerprint worth eyeballing.
$sb = New-Object System.Text.StringBuilder
foreach ($b in ([System.IO.File]::ReadAllBytes($romPath))) {
    [void]$sb.AppendLine($b.ToString('X2'))
}
[System.IO.File]::WriteAllText($hexPath, $sb.ToString())
Write-Host "== wrote roms\zx48.hex (16384 lines)"
