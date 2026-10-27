# roms/

The ZX Spectrum 48K ROM is copyright 1982 Amstrad/Sky In-Home Service and is
**not** in this repository.  It is fetched and hash-verified by
`scripts/fetch-rom.ps1` (or `make rom`):

- `zx48.rom` — the 16K binary, SHA-256 verified before it is written
- `zx48.hex` — generated from it, one byte per line, what `src/zx_core.v`
  `$readmemh`s at synthesis/simulation

Both are gitignored.

## The permission

Amstrad's 1999 statement (widely reproduced, e.g. on World of Spectrum)
permits the redistribution of the ROM images including the Sinclair BASIC
editor *for use in emulation* and *provided the copyright notices are
retained*:

> Amstrad have kindly given permission for the redistribution of their
> copyrighted material but retain the copyright on it, and on the ROM
> images including the Sinclair BASIC editor.

This project embeds the image into an FPGA bitstream you build for yourself,
which is the same use.  The copyright remains Amstrad's; do not redistribute
`zx48.rom`, `zx48.hex` or bitstreams built from them.

## If the URL dies

`scripts/fetch-rom.ps1 -Url <alternative>` — any copy of the authentic 48K
ROM will pass, because the script checks SHA-256
`d55daa439b673b0e3f5897f99ac37ecb45f974d1862b4dadb85dec34af99cb42`
(MD5 `4c42a2f075212361c3117015b107ff68`,
SHA-1 `5ea7c2b824672e914525d1d5c419d71b84a426a2`).  A good fingerprint at a
glance: the file starts `F3 AF 11 FF FF C3 CB 11` — `DI; XOR A; LD DE,$FFFF`.
