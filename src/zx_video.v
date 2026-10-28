// ============================================================================
//  zx_video.v -- the ULA's picture, on the 720x480p HDMI raster
//
//  The Spectrum display is 256x192 pixels plus border.  Here it is doubled
//  to 512x384 and centred at (X0, Y0) = (104, 48) in the 720x480 frame;
//  everything else on the screen is the border colour, so the picture sits
//  in a border like a real 48K.
//
//  Display memory (the "screen file") is interleaved, not linear:
//
//      pixel byte  0x4000 | {y[7:6], y[2:0], y[5:3], x[7:3]}
//      attribute   0x5800 | {y[7:3], x[7:3]}      ink bits2:0, paper 5:3,
//                                                    bit6 BRIGHT, bit7 FLASH
//
//  Fetch: the left border of each output line (x = 0..63) is dead time on
//  this raster, so all 32 pixel bytes and 32 attribute bytes of the current
//  ZX line are prefetched there into two 32-byte buffers -- 64 reads, one per
//  clock, all done 40 clocks before the first ZX pixel.  zx_core hands the
//  shared RAM's address port to vram_addr during that window and stalls the
//  CPU (its address is stable anyway, so nothing is lost but ~7% of the
//  frame's cycles -- a nod to the real ULA's contention).
//
//  Colours: the ULA palette, bit1=red bit2=green bit0=blue, BRIGHT raising
//  the level from 0xC0 to 0xFF.  Border is always non-bright, as on hardware.
//  FLASH swaps ink and paper at ~1.5 Hz (the `flash` input, from zx_core).
// ============================================================================

`default_nettype none

module zx_video #(
    parameter integer X0 = 104,     // first output pixel of the ZX picture
    parameter integer Y0 = 48       // first output line of the ZX picture
) (
    input  wire        clk,
    input  wire [9:0]  x,           // hdmi_tx active-pixel coordinates
    input  wire [9:0]  y,
    input  wire [2:0]  border,      // OUT (0xFE) bits 2:0
    input  wire        flash,       // ~1.5 Hz flash phase

    // shared RAM read port, owned by this module while x < 64 (zx_core muxes)
    output wire [15:0] vram_addr,
    input  wire [7:0]  vram_data,

    output wire [23:0] rgb
);
    localparam integer ZX_W = 512;  // 256 doubled
    localparam integer ZX_H = 384;  // 192 doubled

    // ------------------------------------------------------------------
    // Which ZX line (0..191) this output line shows
    // ------------------------------------------------------------------
    wire in_lines = (y >= Y0) && (y < (Y0 + ZX_H));
    wire [7:0] zy = in_lines ? ((y - Y0) >> 1) : 8'd0;

    // ------------------------------------------------------------------
    // Prefetch, x = 0..31 pixel bytes, x = 32..63 attributes
    // ------------------------------------------------------------------
    wire [5:0] fx = x[5:0];
    wire [4:0] fxc = fx[4:0];       // byte column of the prefetch

    // Screen-file interleave: scanlines 0x100 apart, character rows 0x20:
    //   addr = 0x4000 | y[7:6]<<11 | (y&7)<<8 | ((y>>3)&7)<<5 | column
    wire [15:0] pix_a = {2'b01, 1'b0, zy[7:6], zy[2:0], zy[5:3], fxc};
    wire [15:0] attr_a = 16'h5800 | {zy[7:3], fxc};
    assign vram_addr = fx[5] ? attr_a : pix_a;

    reg [7:0] pixbuf [0:31];
    reg [7:0] attbuf [0:31];
    reg [5:0] fx_q = 6'd0;
    reg       pf_q = 1'b0;

    // vram_data lags vram_addr by one clock (registered RAM read), so the
    // capture uses fx_q/pf_q -- last clock's column -- not this clock's.
    always @(posedge clk) begin
        if (pf_q) begin
            if (!fx_q[5]) pixbuf[fx_q[4:0]] <= vram_data;
            else          attbuf[fx_q[4:0]] <= vram_data;
        end
        fx_q <= fx;
        pf_q <= (x < 10'd64);
    end

    // ------------------------------------------------------------------
    // Pixel decode
    // ------------------------------------------------------------------
    wire in_pic   = (x >= X0) && (x < (X0 + ZX_W)) && in_lines;
    wire [8:0] sx = (x - X0) >> 1;          // 0..255, only valid in_pic
    wire [7:0] bmp = pixbuf[sx[7:3]];
    wire [7:0] at  = attbuf[sx[7:3]];
    wire       dot = bmp[3'd7 - sx[2:0]];

    wire [3:0] ink   = {at[6], at[2], at[1], at[0]};   // {BRIGHT, G, R, B}
    wire [3:0] paper = {at[6], at[5], at[4], at[3]};
    wire       swap  = at[7] & flash;
    wire [3:0] col   = in_pic ? (swap ? (dot ? paper : ink)
                                      : (dot ? ink   : paper))
                              : {1'b0, border};

    // palette: the lit channels sit at 0xC0, or 0xFF with BRIGHT.
    // col = {BRIGHT, G, R, B} -> RGB byte order R = bit1, G = bit2, B = bit0.
    wire [7:0] lvl = col[3] ? 8'hFF : 8'hC0;
    assign rgb = {col[1] ? lvl : 8'h00,
                  col[2] ? lvl : 8'h00,
                  col[0] ? lvl : 8'h00};

endmodule

`default_nettype wire
