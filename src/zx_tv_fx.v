// ============================================================================
//  zx_tv_fx.v -- the "television" in front of the ULA's RGB
//
//  Two things a Spectrum on a TV does that crisp RGB does not, selected by the
//  Dock's DIP switches (Documents/pinout.md):
//
//    DIP1 (C7)  colour TV    composite keeps luma but only ~1.3 MHz of chroma,
//                            so colours bleed sideways.  Luma on the DSP
//                            multipliers (Y = 77R + 150G + 29B), chroma as
//                            B-Y / R-Y, a 2-tap chroma filter across output
//                            pixels (half a ZX pixel at the 2x upscale), then
//                            back to RGB with shift-add reconstruction.
//    DIP2 (E9)  scanlines    25% darker on alternate raster lines, like a CRT's
//                            line structure.
//
//  There are no monochrome modes: a Spectrum was sold with a colour TV or a
//  colour monitor, never with a green/amber terminal.
//
//  Everything is pipelined in three stages so the multiplier chain fits the
//  27 MHz pixel clock, and zx_video's X0 is moved back by the same three clocks
//  (see zx_core's VID_X0) so the picture does not move.
// ============================================================================
`default_nettype none

module zx_tv_fx #(
    parameter integer LATENCY = 3
) (
    input  wire        clk,
    input  wire [9:0]  y,           // raster line, for the scanline phase
    input  wire        color_tv,    // DIP1
    input  wire        scanline,    // DIP2
    input  wire [23:0] rgb_in,
    output reg  [23:0] rgb_out
);
    // ------------------------------------------------------------------
    // Stage 1: luma and chroma differences
    // ------------------------------------------------------------------
    wire [7:0] r_in = rgb_in[23:16];
    wire [7:0] g_in = rgb_in[15:8];
    wire [7:0] b_in = rgb_in[7:0];

    wire [17:0] ysum = 18'd77 * r_in + 18'd150 * g_in + 18'd29 * b_in;
    wire [7:0]  yv   = ysum[15:8];
    wire signed [8:0] cr = $signed({1'b0, r_in}) - $signed({1'b0, yv});   // R-Y
    wire signed [8:0] cb = $signed({1'b0, b_in}) - $signed({1'b0, yv});   // B-Y

    reg [7:0]        yv_1   = 8'd0;
    reg signed [8:0] cr_1   = 9'sd0, cb_1 = 9'sd0;
    reg [23:0]       raw_1  = 24'd0;
    reg              tv_1   = 1'b0;
    reg              odd_1  = 1'b0;
    reg              scan_1 = 1'b0;

    // ------------------------------------------------------------------
    // Stage 2: chroma band-limiting (3/4 now + 1/4 previous)
    // ------------------------------------------------------------------
    reg signed [8:0] cr_1q = 9'sd0, cb_1q = 9'sd0;
    wire signed [9:0] cr_blend = cr_1 - (cr_1 >>> 2) + (cr_1q >>> 2);
    wire signed [9:0] cb_blend = cb_1 - (cb_1 >>> 2) + (cb_1q >>> 2);

    reg [7:0]        yv_2   = 8'd0;
    reg signed [9:0] cr_2   = 10'sd0, cb_2 = 10'sd0;
    reg [23:0]       raw_2  = 24'd0;
    reg              tv_2   = 1'b0;
    reg              odd_2  = 1'b0;
    reg              scan_2 = 1'b0;

    always @(posedge clk) begin
        yv_1   <= yv;
        cr_1   <= cr;
        cb_1   <= cb;
        raw_1  <= rgb_in;
        tv_1   <= color_tv;
        odd_1  <= y[0];
        scan_1 <= scanline;

        cr_1q  <= cr_1;
        cb_1q  <= cb_1;
        yv_2   <= yv_1;
        cr_2   <= cr_blend;
        cb_2   <= cb_blend;
        raw_2  <= raw_1;
        tv_2   <= tv_1;
        odd_2  <= odd_1;
        scan_2 <= scan_1;
    end

    // ------------------------------------------------------------------
    // Stage 3: rebuild, then the scanline attenuation
    //   R = Y + Cr,  B = Y + Cb,  G = Y - 0.509Cr - 0.186Cb
    //   0.509 ~ 1/2 + 1/128, 0.186 ~ 1/8 + 1/16 (a TV does not need better)
    // ------------------------------------------------------------------
    wire signed [10:0] r_sum = $signed({2'b00, yv_2}) + cr_2;
    wire signed [10:0] b_sum = $signed({2'b00, yv_2}) + cb_2;

    wire signed [10:0] cr_half = cr_2 >>> 1;
    wire signed [10:0] cr_sml  = cr_2 >>> 7;
    wire signed [10:0] cb_med  = cb_2 >>> 3;
    wire signed [10:0] cb_sml  = cb_2 >>> 4;
    wire signed [10:0] g_res   = $signed({2'b00, yv_2}) - cr_half - cr_sml - cb_med - cb_sml;

    function [7:0] sat8(input signed [10:0] x);
        begin
            if (x < 0)             sat8 = 8'd0;
            else if (x > 11'sd255) sat8 = 8'd255;
            else                   sat8 = x[7:0];
        end
    endfunction

    wire [23:0] rgb_colour = tv_2 ? {sat8(r_sum), sat8(g_res), sat8(b_sum)} : raw_2;

    // 25% darker: keep 3/4 of each channel
    function [7:0] atten(input [7:0] c);
        begin
            atten = c - (c >> 2);
        end
    endfunction

    always @(posedge clk) begin
        if (odd_2 && scan_2)
            rgb_out <= {atten(rgb_colour[23:16]),
                        atten(rgb_colour[15:8]),
                        atten(rgb_colour[7:0])};
        else
            rgb_out <= rgb_colour;
    end

endmodule

`default_nettype wire
