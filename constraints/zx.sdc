// Timing constraints for the ZX Spectrum on Tang Primer 20K (Gowin EDA).
//
// Clock trees off the 27 MHz oscillator:
//   clk: 27 MHz crystal input (asynchronous to the internal PLL clocks)
//   u_clk_gen/pll_tmds -> clk_tmds 135 MHz -> CLKDIV /5 -> clk_pixel 27 MHz
//                        (everything ZX, and the HDMI pixel clock)
//   u_clk_gen/pll_ddr  -> ddr_memory_clk 398.25 MHz -> DDR3 IP -> its
//                        clk_out mclk (~99.56 MHz, u_ddr/mclk)
// zx_ddr crosses between clk_pixel and mclk with toggle handshakes whose
// data is held steady for two receiving clocks, so the groups are
// asynchronous.
create_clock -name clk -period 37.037 [get_ports {clk}]
create_generated_clock -name clk_tmds  -source [get_ports {clk}] -multiply_by 5 [get_pins {u_clk_gen/pll_tmds/CLKOUT}]
create_generated_clock -name clk_pixel -source [get_pins {u_clk_gen/pll_tmds/CLKOUT}] -master_clock clk_tmds -divide_by 5 [get_pins {u_clk_gen/clkdiv_pixel/CLKOUT}]
create_clock -name ddr_memory_clk -period 2.511 [get_nets {ddr_memory_clk}]
create_clock -name mclk -period 10.042 [get_nets {u_ddr/mclk}]
// USB: the host's 12 MHz (third rPLL) and the USB3317's 60 MHz CLKOUT,
// which only runs the PHY's register writes (src/zx_usb.v)
create_generated_clock -name clk_usb -source [get_ports {clk}] -multiply_by 4 -divide_by 9 [get_pins {u_clk_gen/pll_usb/CLKOUT}]
create_clock -name usb_clk60 -period 16.667 [get_ports {usb_clkout}]

set_clock_groups -asynchronous -group [get_clocks {clk}] -group [get_clocks {clk_tmds clk_pixel}] -group [get_clocks {ddr_memory_clk}] -group [get_clocks {mclk}] -group [get_clocks {clk_usb}] -group [get_clocks {usb_clk60}]

// OSER10 serializers: RESET is an asynchronous initialization signal released
// 128 pixel clocks after PLL lock, well before video active data begins.
set_false_path -to [get_pins {g_tmds_lane[0].u_ser/RESET g_tmds_lane[1].u_ser/RESET g_tmds_lane[2].u_ser/RESET g_tmds_lane[3].u_ser/RESET}]

// Asynchronous input ports
set_false_path -from [get_ports {rst_n uart_rx}]
