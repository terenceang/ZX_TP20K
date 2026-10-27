# Tang Primer 20K Dock — FPGA Pinout (for this project)

FPGA: Gowin **GW2A-LV18PG256C8/I7** on the SOM (rev 3961), Dock (rev 3713).
The authoritative, fully cross-referenced copy of this table is
`Documents/pinout.md` (same board; sourced from the sibling apple2e project).
Below is what this project uses.

**Required build options** (scripts/build.ps1 sets them):

```tcl
set_option -use_sspi_as_gpio 1    ;# T10 (reset), M8 (SD MISO), P9
set_option -use_ready_as_gpio 1   ;# A13 (LED1)
set_option -use_done_as_gpio 1    ;# C13 (LED0)
```

## This project's pins

| Signal | Ball | Bank / type | Notes |
|---|---|---|---|
| 27 MHz oscillator | **H11** | 0, LVCMOS33 | everything derives from it |
| Reset (S0 / FPGA_RST) | **T10** | 3, LVCMOS33 PU | low at power-up = POR; S0 = Spectrum reset |
| UART RX (← PC) | **T13** | 2, LVCMOS33 PU | 1 Mbps 8N1, web keyboard |
| UART TX (→ PC) | **M11** | 2, LVCMOS33 | boot banner |
| LED0-5 | **C13 A13 N16 N14 L14 L16** | 3/1, LVCMOS33 | active low |
| S1 / S2 (test pattern) | **T3 / T2** | 1.5 V bank, LVCMOS15 PU | held = colour bars + 1 kHz tone |
| microSD (SPI) | **CLK N10, MOSI R14, MISO M8, /CS N11** | LVCMOS33 | the tape library's card |
| HDMI TMDS clk | **G16 / H15** | 0, LVDS25, DRIVE=3.5, PULL=NONE | TLVDS_OBUF pair |
| HDMI TMDS d0 | **H14 / H16** | 0 | |
| HDMI TMDS d1 | **J15 / K16** | 0 | |
| HDMI TMDS d2 | **K14 / K15** | 1 | |
| DDR3 | banks 4-6 | SSTL15, BANK_VCCIO=1.5 | full list in `constraints/zx.cst`, balls per Sipeed's DDR3 example |

Banks 0,1,2,3,7 are 3.3 V; banks 4,5,6 are 1.5 V (DDR3, the S1-S3 buttons
and the DIP switches; S1/S2 are the test pattern, S3 and the DIPs are free).

## Deliberately unused

- PMODs J5/J6 (RGB LCD), J12 (camera), J14 (mic/WS2812) — free for a physical
  8x5 keyboard matrix later; `zx_input`'s OR-input makes it a drop-in.
- PT8211 audio out (N15/P16/P15/R16) — the beeper goes over HDMI.
- USB PHY, Ethernet, camera, RGB LCD; the DIP switches and S3.
