# ============================================================================
#  sim/render-screen.ps1 -- turn the RAM dump (or a raw RGB frame) into a PNG
#
#    sim\render-screen.ps1                 build\ram.hex -> build\screen.png
#    sim\render-screen.ps1 -Hex x.hex -Out x.png -Border 0
#
#  Reads the 16K dump tb_zx writes (6144 bitmap bytes, 768 attributes, the
#  rest unused) and draws the 48K's picture the way zx_video does: 256x192
#  doubled to 512x384 at (104, 48) in a 720x480 border, ULA palette, BRIGHT,
#  FLASH ignored (a still frame).
# ============================================================================
[CmdletBinding()]
param(
    [string]$Hex = 'build/ram.hex',
    [string]$Out = 'build/screen.png',
    [int]$Border = 0,           # 0-7, the border colour
    [string]$Rgb = ''           # raw 720x480 RGB frame from tb_zx instead
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot   # sim\ -> repo root
Set-Location $root

Add-Type -AssemblyName System.Drawing

$W = 720; $H = 480; $X0 = 104; $Y0 = 48

function Save-Bgra([byte[]]$px, [string]$path) {
    $bmp = New-Object System.Drawing.Bitmap($W, $H)
    $rect = New-Object System.Drawing.Rectangle(0, 0, $W, $H)
    $fmt = [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, $fmt)
    [System.Runtime.InteropServices.Marshal]::Copy($px, 0, $data.Scan0, $px.Count)
    $bmp.UnlockBits($data)
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "== $path ($W x $H)"
}

# --- mode 1: the real video path's frame (R,G,B bytes straight from vid_rgb)
if ($Rgb) {
    $raw = [System.IO.File]::ReadAllBytes($Rgb)
    if ($raw.Length -ne $W * $H * 3) { throw "$Rgb is $($raw.Length) bytes, expected $($W*$H*3)" }
    $px = New-Object byte[] ($W * $H * 4)
    for ($i = 0; $i -lt $W * $H; $i++) {
        $px[$i * 4]     = $raw[$i * 3 + 2]
        $px[$i * 4 + 1] = $raw[$i * 3 + 1]
        $px[$i * 4 + 2] = $raw[$i * 3]
        $px[$i * 4 + 3] = 255
    }
    Save-Bgra $px $Out
    return
}

# --- mode 2: the screen file from the RAM dump
# 'xx' (an X byte in simulation) and blank lines are read as 0, so a dump
# taken while the CPU still has undefined state can still be rendered.
$bytes = Get-Content $Hex | ForEach-Object {
    $t = $_.Trim()
    if ($t -match '^[0-9a-fA-F]{2}$') { [Convert]::ToByte($t, 16) } else { [byte]0 }
}
if ($bytes.Count -lt 6912) { throw "$Hex has only $($bytes.Count) bytes; need 6912" }

# ULA palette: bit0 blue, bit1 red, bit2 green; BRIGHT lifts 0xC0 -> 0xFF
function Pal([int]$c) {
    $lvl = if ($c -band 8) { 255 } else { 192 }
    $r = if ($c -band 2) { $lvl } else { 0 }
    $g = if ($c -band 4) { $lvl } else { 0 }
    $b = if ($c -band 1) { $lvl } else { 0 }
    ,@([byte]$b, [byte]$g, [byte]$r)   # BGR
}
$palette = @{}
for ($i = 0; $i -lt 16; $i++) { $palette[$i] = Pal $i }
$bR, $bG, $bB = $palette[$Border]

$bmp = New-Object System.Drawing.Bitmap($W, $H)
$rect = New-Object System.Drawing.Rectangle(0, 0, $W, $H)
$fmt = [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
$px = New-Object byte[] ($W * $H * 4)

# fill the border first
for ($y = 0; $y -lt $H; $y++) {
    $row = $y * $W * 4
    for ($x = 0; $x -lt $W; $x++) {
        $o = $row + $x * 4
        $px[$o] = $bB; $px[$o + 1] = $bG; $px[$o + 2] = $bR; $px[$o + 3] = 255
    }
}

# the picture
for ($ly = 0; $ly -lt 192; $ly++) {
    # ZX screen-file interleave: third (y>>6) at bit 11, the scanline within
    # the character row (y&7) at bits 10:8, the character row (y>>3)&7 at
    # bits 7:5 -- the scanline is the *high* of the two, 0x100 apart.
    $lineBase = (($ly -band 0xC0) -shl 5) -bor (($ly -band 7) -shl 8) -bor
                (((($ly -band 0x38) -shr 3)) -shl 5)
    $attrBase = 6144 + (($ly -shr 3) -shl 5)
    for ($cx = 0; $cx -lt 32; $cx++) {
        $bmpByte = $bytes[$lineBase + $cx]
        $at = $bytes[$attrBase + $cx]
        $ink = $at -band 7; $paper = ($at -shr 3) -band 7
        if ($at -band 0x40) { $ink += 8; $paper += 8 }
        for ($b = 0; $b -lt 8; $b++) {
            $c = if (($bmpByte -shr (7 - $b)) -band 1) { $ink } else { $paper }
            $p = $palette[$c]
            for ($sy = 0; $sy -lt 2; $sy++) {
                $py = $Y0 + $ly * 2 + $sy
                $row = $py * $W * 4
                for ($sx = 0; $sx -lt 2; $sx++) {
                    $o = $row + ($X0 + $cx * 8 + $b) * 2 * 4 + $sx * 4
                    $px[$o] = $p[0]; $px[$o + 1] = $p[1]; $px[$o + 2] = $p[2]; $px[$o + 3] = 255
                }
            }
        }
    }
}

Save-Bgra $px $Out
