# usb_hid_host (vendored)

nand2mario's compact USB HID host, <https://github.com/nand2mario/usb_hid_host>
at 678b0137 (2025-03-22), Apache-2.0 (`LICENSE`).  Low-speed (1.5 Mbps) only,
one device, no hubs: boot keyboards, mice and common gamepads, from a 12 MHz
clock.  Changes are marked `ZX:` -- the D+/D- tristates split into
`_i`/`_o`/`usb_oe` (the USB3317 runs it in 6-pin serial mode, `src/zx_usb.v`)
and the ROM's `$readmemh` path made repo-relative.
