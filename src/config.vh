// ============================================================================
//  config.vh -- build-time configuration, included by zx_top.v and clk_gen.v
//
//  ZX_USE_DDR3 -- uncomment the `define below to compile in the DDR3 bring-up
//  block: zx_ddr, the encrypted DDR3 IP and the 398.25 MHz PLL.
//
//  Nothing in the 48K machine reads or writes the DDR3 yet -- it is calibrated
//  and self-tested for the 128K banks and storage that come next -- and the
//  block costs 1364 LUTs (25% of the logic), 1296 registers (58%), 8 BSRAMs
//  (17% of the blocks), 20 pads, one of the four PLLs, and the only clock
//  whose timing margin is thin (mclk, +0.26 ns of 10.04 ns).  So the default
//  build leaves it out; turn it on for DDR3 bring-up and the 128K work.
//
//  With the block out, the DDR3 pins are held in reset and deselected, so the
//  lean bitstream is safe to load on the same board.
//
//  scripts/build.ps1 looks for the `define and picks the matching timing
//  constraints -- constraints/zx.sdc when the block is in (it constrains
//  ddr_memory_clk and the IP's mclk), constraints/zx_lean.sdc when it is out.
//
//  Measured numbers for both: docs/resources.md.
// ============================================================================

`define ZX_USE_DDR3

// ZX_TAPE_SD -- where the tape comes from.
//
//   defined      the microSD card: ZXCONFIG.TXT in the root names the file
//                (TAPE=TAPE.TAP), src/sd/sd_vol.v streams it.  Costs ~3.3k
//                LUTs for the FAT32 finder; no card, no tape.
//   not defined  the web page (src/zx_tape_web.v): the page pushes the .TAP
//                down the keyboard UART and the board asks for bytes with a
//                credit byte.  Cheap, no card, and the page types LOAD "" too.
//
//  Either way src/tap_player.v turns the bytes into EAR pulses, so the ZX sees
//  the same cassette.
// `define ZX_TAPE_SD

// ZX_TAPE_LIB -- the card-resident tape library (docs/tape-library.md).
//
//   defined      the board scans the card's root for .TAP files, sends the
//                list to the page and streams the chosen one into DDR3, where
//                the player holds it: replay and instant load never touch the
//                card again.  Needs ZX_USE_DDR3, and replaces both sources
//                above.
//   not defined  one of the two sources above, as before.
`define ZX_TAPE_LIB
