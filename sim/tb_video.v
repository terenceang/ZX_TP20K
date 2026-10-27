// ============================================================================
//  tb_video.v -- does zx_video put a known screen-file byte on the right pixel?
//
//  The screen file is interleaved, and the comment in zx_video spells the
//  mapping out:
//
//      pixel    0x4000 | y[7:6]<<11 | y[2:0]<<8 | y[5:3]<<5 | x[7:3]
//      attr     0x5800 | y[7:3]<<5 | x[7:3]
//
//  This testbench fills a 48K RAM with white paper / black ink attributes and
//  a handful of single pixel bytes at known (character row, line, column)
//  positions, runs two 720x480 fields through zx_video, and reports which
//  character cells those bytes actually came out in.
//
//  A vertical offset, a doubled line or a byte landing in the wrong character
//  row all show up as a cell that is not the one the byte was put in.
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_video;
    localparam H_TOTAL = 858, V_TOTAL = 525;
    localparam integer X0 = 104, Y0 = 48;

    reg clk = 1'b0;
    always #18.519 clk = ~clk;

    reg [9:0] hcnt = 10'd0, vcnt = 10'd0;
    always @(posedge clk) begin
        if (hcnt == H_TOTAL - 1) begin
            hcnt <= 10'd0;
            vcnt <= (vcnt == V_TOTAL - 1) ? 10'd0 : vcnt + 10'd1;
        end else hcnt <= hcnt + 10'd1;
    end
    wire [9:0] px = hcnt - 10'd2;
    wire [9:0] py = vcnt;

    reg  [7:0] ram [0:49151];
    reg  [7:0] ram_q = 8'h00;

    wire [15:0] vram_addr;
    wire [15:0] vid_a = vram_addr - 16'h4000;
    always @(posedge clk) ram_q <= ram[vid_a];

    wire [23:0] rgb;
    zx_video u_video (
        .clk(clk), .x(px), .y(py),
        .border(3'd7), .flash(1'b0),
        .vram_addr(vram_addr), .vram_data(ram_q),
        .rgb(rgb)
    );

    integer i, r, c;
    integer black [0:24*32-1];       // black samples per character cell
    integer put_row [0:15], put_line [0:15], put_col [0:15];
    integer put_byte [0:15];
    integer nput = 0;

    task put_pixel;
        input integer row;           // character row 0..23
        input integer line;          // pixel line within the row 0..7
        input integer col;           // character column 0..31
        input [7:0]   value;
        integer y, a;
        begin
            y = row * 8 + line;
            a = ((y & 16'h00C0) << 5) | ((y & 16'h0007) << 8) |
                ((y & 16'h0038) << 2) | col;
            ram[a] = value;
            put_row[nput] = row; put_line[nput] = line;
            put_col[nput] = col; put_byte[nput] = value;
            nput = nput + 1;
        end
    endtask

    // score every active pixel into its character cell
    always @(posedge clk) begin
        if (px >= X0 && px < X0 + 512 && py >= Y0 && py < Y0 + 384 &&
            rgb == 24'h000000) begin
            r = (py - Y0) / 16;
            c = (px - X0) / 16;
            if (r < 24 && c < 32) black[r*32 + c] = black[r*32 + c] + 1;
        end
    end

    integer errors = 0;
    initial begin
        for (i = 0; i < 49152; i = i + 1) ram[i] = 8'h00;
        for (i = 0; i < 768; i = i + 1) ram[6144 + i] = 8'h38;   // paper 7, ink 0

        // four markers, each easy to tell apart from the others
        put_pixel(0,  0,  0,  8'hFF);   // top-left
        put_pixel(0,  4,  9,  8'h3C);   // top row, middle line
        put_pixel(23, 0,  0,  8'hFF);   // bottom-left, first line
        put_pixel(23, 7,  9,  8'h81);   // bottom row, last line

        for (i = 0; i < 24*32; i = i + 1) black[i] = 0;

        repeat (2 * H_TOTAL * V_TOTAL) @(posedge clk);

        for (i = 0; i < nput; i = i + 1)
            $display("put %02x at row %0d line %0d col %0d",
                     put_byte[i], put_row[i], put_line[i], put_col[i]);

        for (r = 0; r < 24; r = r + 1)
            for (c = 0; c < 32; c = c + 1)
                if (black[r*32 + c] != 0)
                    $display("inked cell row %0d col %0d: %0d samples",
                             r, c, black[r*32 + c]);

        // every marker must have landed in its own cell, and nowhere else
        for (i = 0; i < nput; i = i + 1) begin
            if (black[put_row[i]*32 + put_col[i]] == 0) begin
                $display("FAIL: %02x put at row %0d col %0d never appeared there",
                         put_byte[i], put_row[i], put_col[i]);
                errors = errors + 1;
            end
        end
        if (errors == 0) $display("PASS: every pixel byte rendered in its own cell");
        else             $display("FAIL: %0d markers missing", errors);
        $finish;
    end

endmodule

`default_nettype wire
