// ============================================================================
//  tb_tv_fx.v -- the TV effect stage: colour TV and 25% scanlines
//
//  Checks the numbers, not just "it changed":
//
//    * both DIPs off -> the ULA's RGB comes out untouched
//    * DIP2 on       -> odd raster lines keep 3/4 of each channel, even lines
//                       untouched
//    * DIP1 on       -> a red pixel on a white field loses saturation, and the
//                       pixel after it picks up a red tint (the chroma smear),
//                       while the field stays white
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_tv_fx;
    reg clk = 1'b0;
    always #18.518 clk = ~clk;

    reg  [9:0]  y = 10'd100;
    reg         color_tv = 1'b0;
    reg         scanline = 1'b0;
    reg  [23:0] rgb_in = 24'h000000;
    wire [23:0] rgb_out;

    zx_tv_fx u_dut (
        .clk(clk), .y(y),
        .color_tv(color_tv), .scanline(scanline),
        .rgb_in(rgb_in), .rgb_out(rgb_out)
    );

    integer errors = 0;
    reg [7:0] r, g, b;
    localparam integer LAT = 3;      // pipeline depth

    task samp;
        begin
            #1;
            r = rgb_out[23:16]; g = rgb_out[15:8]; b = rgb_out[7:0];
        end
    endtask

    task px;
        input [23:0] v;
        begin
            rgb_in = v;
            repeat (LAT + 1) @(posedge clk);
            samp;
        end
    endtask

    task expect_rgb;
        input [7:0] er, eg, eb;
        input [255:0] what;
        begin
            if (r !== er || g !== eg || b !== eb) begin
                $display("FAIL: %0s: got %02x %02x %02x, expected %02x %02x %02x",
                         what, r, g, b, er, eg, eb);
                errors = errors + 1;
            end else
                $display("ok: %0s -> %02x %02x %02x", what, r, g, b);
        end
    endtask

    initial begin
        // ---------------- both off: passthrough ----------------
        y = 10'd100; color_tv = 0; scanline = 0;
        px(24'hFF0000); expect_rgb(8'hFF, 8'h00, 8'h00, "off: red");
        px(24'h00C0C0); expect_rgb(8'h00, 8'hC0, 8'hC0, "off: cyan");
        px(24'hC0C0C0); expect_rgb(8'hC0, 8'hC0, 8'hC0, "off: white");

        // ---------------- DIP2: 25% scanlines ----------------
        y = 10'd101;                       // odd raster line
        scanline = 1;
        px(24'hFFFFFF); expect_rgb(8'd192, 8'd192, 8'd192, "scan odd line white");
        px(24'hFF0000); expect_rgb(8'd192, 8'd0,   8'd0,   "scan odd line red");
        y = 10'd100;                       // even line is untouched
        px(24'hFFFFFF); expect_rgb(8'hFF, 8'hFF, 8'hFF, "scan even line white");
        scanline = 0;

        // ---------------- DIP1: colour TV / chroma smear ----------------
        // white, white, red, white, white -- one pixel per clock -- read three
        // clocks behind: the isolated red loses saturation, the white after it
        // is tinted, the next white is clean.
        color_tv = 1;
        rgb_in = 24'hFFFFFF; @(posedge clk);
        rgb_in = 24'hFFFFFF; @(posedge clk);
        rgb_in = 24'hFF0000; @(posedge clk);
        rgb_in = 24'hFFFFFF; @(posedge clk);
        rgb_in = 24'hFFFFFF; @(posedge clk);

        samp;                                       // the red pixel
        if (r < 8'd190 || g > 8'd40) begin
            $display("FAIL: tv: red pixel not red-ish after chroma filter: %02x %02x %02x", r, g, b);
            errors = errors + 1;
        end else
            $display("ok: tv: isolated red pixel -> %02x %02x %02x (chroma diluted)", r, g, b);

        @(posedge clk); samp;                       // white after red
        if (r < 8'd250 || g < 8'd200 || g > 8'd252 || b < 8'd200 || b > 8'd252) begin
            $display("FAIL: tv: no chroma bleed after red: got %02x %02x %02x", r, g, b);
            errors = errors + 1;
        end else
            $display("ok: tv: white after red is tinted -> %02x %02x %02x", r, g, b);

        @(posedge clk); samp;                       // the next white
        expect_rgb(8'hFF, 8'hFF, 8'hFF, "tv: smear clears on the next white");

        if (errors == 0) $display("PASS: tv effects (colour TV + 25%% scanlines)");
        else             $display("FAIL: %0d tv effect checks", errors);
        $finish;
    end

endmodule

`default_nettype wire
