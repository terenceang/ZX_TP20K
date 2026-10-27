// ============================================================================
//  clk_gen.v -- ZX Spectrum on Tang Primer 20K, clock generation
//
//  Three things off the 27 MHz SOM oscillator:
//    * clk_tmds  135.0 MHz   rPLL x5, the TMDS serial clock (5 bits/pixel)
//    * clk_pixel  27.0 MHz   CLKDIV /5 off clk_tmds, everything ZX runs here
//    * ddr_memory_clk 398.25 MHz   second rPLL, the DDR3 IP's memory clock
//
//  clk_pixel MUST be derived from clk_tmds via CLKDIV (divide-by-5), not
//  tapped directly off the crystal: OSER10 requires a fixed, drift-free phase
//  relationship between PCLK (clk_pixel) and FCLK (clk_tmds), which only a
//  shared hardware divider off the same PLL output guarantees.  Feeding it
//  the raw crystal instead causes the HDMI serializers to intermittently lose
//  PCLK/FCLK alignment -- observed on hardware as the display dropping in and
//  out of sync.  Same rPLL+CLKDIV pattern as the sibling apple2e project and
//  Gowin's own DVI TX reference.
//
//  Clock enables, in the clk_pixel domain:
//    * ce_cpu  3.5 MHz -- the 48K Spectrum's CPU rate, exactly 7/54 of
//      27 MHz, one pulse every 7 or 8 clocks (fractional accumulator)
//    * ce_48k 48 kHz -- the beeper's HDMI audio sample rate, exactly 16/9000
// ============================================================================
`default_nettype none

module clk_gen (
    input  wire       clk_in,       // 27.0 MHz onboard oscillator (H11)
    input  wire       rst_in,       // active-high, asynchronous
    output wire       clk_tmds,     // 135.0 MHz TMDS bit clock
    output wire       clk_pixel,    // 27.0 MHz pixel clock
    output wire       pll_locked,
    output wire       ddr_memory_clk, // 398.25 MHz (DDR3 IP ref/PLL clock)
    output wire       ddr_lock,
    output reg        ce_cpu,
    output reg        ce_48k
);

    // ------------------------------------------------------------------
    // TMDS PLL: 27 -> 135 MHz (VCO 540 MHz)
    // ------------------------------------------------------------------
    rPLL #(
        .FCLKIN("27.0"),
        .IDIV_SEL(0),   // PFD = 27.0 MHz
        .FBDIV_SEL(4),  // CLKOUT = 135.0 MHz
        .ODIV_SEL(4)    // VCO = 540.0 MHz
    ) pll_tmds (
        .CLKIN(clk_in),
        .CLKOUT(clk_tmds),
        .LOCK(pll_locked),
        .CLKOUTP(),
        .CLKOUTD(),
        .CLKOUTD3(),
        .RESET(rst_in),
        .RESET_P(1'b0),
        .CLKFB(1'b0),
        .FBDSEL(6'b0),
        .IDSEL(6'b0),
        .ODSEL(6'b0),
        .PSDA(4'b0),
        .DUTYDA(4'b0),
        .FDLY(4'b0)
    );

    // clk_pixel = clk_tmds / 5.  See the header: this must be a hardware
    // divider off the PLL output, never the raw crystal.
    CLKDIV #(
        .DIV_MODE("5"),
        .GSREN("false")
    ) clkdiv_pixel (
        .CLKOUT(clk_pixel),
        .HCLKIN(clk_tmds),
        .RESETN(~rst_in & pll_locked),
        .CALIB(1'b0)
    );

    // ------------------------------------------------------------------
    // DDR3 PLL: 27 -> 398.25 MHz (VCO 796.5 MHz), the same parameters the
    // sibling project and Sipeed's DDR3 example use for this board's IP.
    // ------------------------------------------------------------------
    rPLL #(
        .FCLKIN("27"), .DEVICE("GW2A-18C"),
        .IDIV_SEL(3), .FBDIV_SEL(58), .ODIV_SEL(2),
        .CLKFB_SEL("internal"),
        .DYN_IDIV_SEL("false"), .DYN_FBDIV_SEL("false"), .DYN_ODIV_SEL("false")
    ) pll_ddr (
        .CLKIN(clk_in),
        .CLKOUT(ddr_memory_clk),
        .LOCK(ddr_lock),
        .CLKOUTP(),
        .CLKOUTD(),
        .CLKOUTD3(),
        .RESET(rst_in),
        .RESET_P(1'b0),
        .CLKFB(1'b0),
        .FBDSEL(6'b0),
        .IDSEL(6'b0),
        .ODSEL(6'b0),
        .PSDA(4'b0),
        .DUTYDA(4'b0),
        .FDLY(4'b0)
    );

    // ------------------------------------------------------------------
    // 3.5 MHz CPU enable: 27 MHz * 7/54, exact.  Pulse when the accumulator
    // wraps past 54 (the fractional-N form: 7/54 of the clocks).
    // ------------------------------------------------------------------
    localparam [5:0] CE_NUM = 6'd7, CE_DEN = 6'd54;
    reg [5:0] acc_cpu = 6'd0;
    always @(posedge clk_pixel or posedge rst_in) begin
        if (rst_in) begin
            acc_cpu <= 6'd0;
            ce_cpu  <= 1'b0;
        end else if (acc_cpu + CE_NUM >= CE_DEN) begin
            acc_cpu <= acc_cpu + CE_NUM - CE_DEN;
            ce_cpu  <= 1'b1;
        end else begin
            acc_cpu <= acc_cpu + CE_NUM;
            ce_cpu  <= 1'b0;
        end
    end

    // 48 kHz audio enable: 27 MHz * 16/9000, exact.
    localparam [13:0] AK_NUM = 14'd16, AK_DEN = 14'd9000;
    reg [13:0] acc_48k = 14'd0;
    always @(posedge clk_pixel or posedge rst_in) begin
        if (rst_in) begin
            acc_48k <= 14'd0;
            ce_48k  <= 1'b0;
        end else if (acc_48k + AK_NUM >= AK_DEN) begin
            acc_48k <= acc_48k + AK_NUM - AK_DEN;
            ce_48k  <= 1'b1;
        end else begin
            acc_48k <= acc_48k + AK_NUM;
            ce_48k  <= 1'b0;
        end
    end

endmodule

`default_nettype wire
