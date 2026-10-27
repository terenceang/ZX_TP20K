// Timing constraints for the ZX Spectrum on Tang Primer 20K (Gowin EDA).
//
// LEAN BUILD: src/config.vh has ZX_USE_DDR3 = 0, so there is no DDR3 block and
// no DDR3 clocks.  What is left is one clock tree off the 27 MHz oscillator:
//
//   clk: 27 MHz crystal input (asynchronous to the internal PLL clocks)
//   u_clk_gen/pll_tmds -> clk_tmds 135 MHz -> CLKDIV /5 -> clk_pixel 27 MHz
//                        (everything ZX, and the HDMI pixel clock)
//
// constraints/zx.sdc is the full set, with ddr_memory_clk and the DDR3 IP's
// mclk; scripts/build.ps1 picks the file that matches src/config.vh.

create_clock -name clk -period 37.037 [get_ports {clk}]
create_generated_clock -name clk_tmds  -source [get_ports {clk}] -multiply_by 5 [get_pins {u_clk_gen/pll_tmds/CLKOUT}]
create_generated_clock -name clk_pixel -source [get_pins {u_clk_gen/pll_tmds/CLKOUT}] -master_clock clk_tmds -divide_by 5 [get_pins {u_clk_gen/clkdiv_pixel/CLKOUT}]

set_clock_groups -asynchronous -group [get_clocks {clk}] -group [get_clocks {clk_tmds clk_pixel}]

// OSER10 serializers: RESET is an asynchronous initialization signal released
// 128 pixel clocks after PLL lock, well before video active data begins.
set_false_path -to [get_pins {g_tmds_lane[0].u_ser/RESET g_tmds_lane[1].u_ser/RESET g_tmds_lane[2].u_ser/RESET g_tmds_lane[3].u_ser/RESET}]

// Asynchronous input ports
set_false_path -from [get_ports {rst_n uart_rx}]
