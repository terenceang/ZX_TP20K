// ============================================================================
//  tb_zx.v -- the acceptance test: does the 48K ROM reach the BASIC prompt?
//
//  Runs the real zx_core (tv80 + 16K ROM + 48K RAM + ULA) against the real
//  720x480p line/frame counters, then checks the authentic 48K power-on
//  screen: the ROM's start-up prints "© 1982 Sinclair Research Ltd" in the
//  BOTTOM character row of an otherwise white display and then waits for a
//  key in the editor.  So the test proves, in one run:
//
//    * every glyph of the copyright line is the ROM font's own byte pattern,
//      in the bottom row (0x50E0 + line*0x100 + column)
//    * nothing else in the 6144-byte display file is inked
//    * all 768 attribute cells are CLS's paper-7 / ink-0 (0x38)
//    * the system variables hold what the ROM's own code computes: RAMTOP
//      0xFF57, DF_CC 0x4000, S_POSN 33/24, DF_CCL 0x50FC, S_POSNL 5/23,
//      VARS/PROG 0x5CCB, E_LINE 0x5CCC, STKBOT 0x5CCE, CHARS 0x3C00
//    * the captured HDMI frame carries that ink in the bottom row only, over
//      the plain white the ROM's white border (OUT 0xFE,7) and paper give
//
//  The whole 48K is dumped to build/ram.hex and one frame to build/frame.rgb
//  for inspection.  The HDMI serializers and the DDR3 are not instantiated
//  here: the video path under test ends at vid_rgb, and zx_ddr has its own
//  testbench.
//
//  plusargs:
//    +ms=<n>     milliseconds of machine time to run (default 400)
//    +fast=<n>   0: 3.5 MHz, 1: 13.5 MHz, 2: 27 MHz (minimum margin)
//    +noint=1    hold /INT idle (to tell interrupt-path faults apart)
//    +trace=1    print every system-variable write with the PC that made it
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_zx;
    localparam H_TOTAL = 858, V_TOTAL = 525;

    reg clk = 1'b0;
    always #18.519 clk = ~clk;      // 27 MHz

    // the CPU enable.  fast=1 -> every 2 clocks (13.5 MHz), fast=2 -> every
    // clock (27 MHz: T1->T3 is then exactly the two clocks a registered
    // BSRAM read needs, so the memory path is stressed at its minimum
    // margin).  The ROM boots at any speed: the ULA interrupt is a fixed
    // clock count and nothing at boot counts CPU cycles.
    integer fast = 0;
    initial if (!$value$plusargs("fast=%d", fast)) fast = 0;
    reg [5:0] acc_cpu = 6'd0;
    reg       ce_cpu  = 1'b0;
    always @(posedge clk) begin
        if (fast == 2) begin
            ce_cpu <= 1'b1;
        end else if (fast == 1) begin
            ce_cpu  <= (acc_cpu[0] == 1'b0);
            acc_cpu <= acc_cpu + 6'd1;
        end else if (acc_cpu + 6'd7 >= 6'd54) begin
            acc_cpu <= acc_cpu + 6'd7 - 6'd54;
            ce_cpu  <= 1'b1;
        end else begin
            acc_cpu <= acc_cpu + 6'd7;
            ce_cpu  <= 1'b0;
        end
    end

    // the 720x480p raster, as hdmi_tx's scheduler counts it (hcount 0..857,
    // pixel_x = hcount - 2 so the first two clocks wrap high)
    reg [9:0] hcnt = 10'd0, vcnt = 10'd0;
    always @(posedge clk) begin
        if (hcnt == H_TOTAL - 1) begin
            hcnt <= 10'd0;
            vcnt <= (vcnt == V_TOTAL - 1) ? 10'd0 : vcnt + 10'd1;
        end else hcnt <= hcnt + 10'd1;
    end
    wire [9:0] px = hcnt - 10'd2;
    wire [9:0] py = vcnt;

    reg rst = 1'b1;
    reg uart_rx = 1'b1;             // idle; no keys during the boot

    wire [23:0] rgb;
    wire        halt_n, flash, key_hit, frame_tick, audio_valid;
    wire [15:0] audio_l, audio_r;

    zx_core u_core (
        .clk(clk), .reset(rst), .ce_cpu(ce_cpu), .ce_48k(1'b0),
        .uart_rx(uart_rx), .key_hit(key_hit), .ear(1'b1),
        .vid_x(px), .vid_y(py), .vid_rgb(rgb), .flash(flash),
        .audio_valid(audio_valid), .audio_l(audio_l), .audio_r(audio_r),
        .halt_n(halt_n), .frame_tick(frame_tick)
    );

    integer ms = 400;
    initial begin
        if (!$value$plusargs("ms=%d", ms)) ms = 400;
        if (ms < 50) ms = 50;
    end

    // +noint=1 forces the ULA's interrupt line idle, to tell a boot problem
    // in the interrupt path from one in the CPU/memory path.
    integer noint = 0;
    initial begin
        if (!$value$plusargs("noint=%d", noint)) noint = 0;
        if (noint) force u_core.int_n = 1'b1;
    end

    // progress: how much of the screen file has ink, every 100 ms, and dump
    // the screen each time so a half-booted state can be rendered too
    integer nz_bitmap, nz_attr, i, t_ms, fd;
    integer fill_attrs, cls_attrs;
    task count_screen;
        begin
            nz_bitmap = 0; nz_attr = 0; fill_attrs = 0; cls_attrs = 0;
            for (i = 0; i < 6144; i = i + 1) if (u_core.ram[i]      != 8'd0) nz_bitmap = nz_bitmap + 1;
            for (i = 6144; i < 6912; i = i + 1) begin
                if (u_core.ram[i] != 8'd0) nz_attr = nz_attr + 1;
                if (u_core.ram[i] == 8'h02) fill_attrs = fill_attrs + 1;
                if (u_core.ram[i] == 8'h38) cls_attrs = cls_attrs + 1;
            end
        end
    endtask

    task dump_screen;
        begin
            // the whole 48K, not just the screen file: the system variables and
            // the stack say what the ROM thinks is going on
            fd = $fopen("build/ram.hex", "w");
            if (fd != 0) begin
                for (i = 0; i < 49152; i = i + 1) $fwrite(fd, "%02x\n", u_core.ram[i]);
                $fclose(fd);
            end
        end
    endtask

    // +trace=1 prints every system-variable write (0x5C00-0x5CFF) and every
    // write of the copyright glyph (0x7F) into the screen file, with the PC
    // that made it, so the ROM's print routing can be followed.
    integer trace_on = 0;
    initial if (!$value$plusargs("trace=%d", trace_on)) trace_on = 0;
    always @(posedge clk) begin
        if (trace_on && u_core.wr_pulse) begin
            if (u_core.a >= 16'h5C00 && u_core.a <= 16'h5CFF)
                $display("%0d us  WR %04x = %02x  pc=%04x", $time/1000,
                         u_core.a, u_core.cpu_dout, u_core.u_cpu.PC);
            else if (u_core.a >= 16'h4000 && u_core.a <= 16'h5AFF && u_core.cpu_dout == 8'h7F)
                $display("%0d us  WR SCREEN %04x = 7F  pc=%04x", $time/1000,
                         u_core.a, u_core.u_cpu.PC);
        end
    end

    // the ROM's own start-up message, as PO_MSG prints it (0x1539)
    reg [7:0] msg [0:27];
    initial begin
        msg[0]  = 8'h7F;                       // the Spectrum's '©'
        msg[1]  = " ";                         // 1982
        msg[2]  = "1"; msg[3] = "9"; msg[4] = "8"; msg[5] = "2";
        msg[6]  = " ";                         // Sinclair
        msg[7]  = "S"; msg[8] = "i"; msg[9] = "n"; msg[10] = "c";
        msg[11] = "l"; msg[12] = "a"; msg[13] = "i"; msg[14] = "r";
        msg[15] = " ";                         // Research
        msg[16] = "R"; msg[17] = "e"; msg[18] = "s"; msg[19] = "e";
        msg[20] = "a"; msg[21] = "r"; msg[22] = "c"; msg[23] = "h";
        msg[24] = " ";                         // Ltd
        msg[25] = "L"; msg[26] = "t"; msg[27] = "d";
    end

    integer c, l, font_i, copy_bad, stray, attr_bad, sv_bad, frame_bad;




    integer fr_fd;
    reg cap_req = 1'b0;
    reg cap = 1'b0;
    reg [1:0] cap_state = 2'd0;

    // one complete frame of the real video output, R,G,B per pixel, plus a
    // per-character-row count of black pixels and a count of pixels that are
    // neither that black nor the boot screen's plain white.  At power-up the
    // border is white (OUT 0xFE,7) and the whole display is paper 7 / ink 0,
    // so every pixel of the frame must be 0xC0C0C0 except the © line's ink.
    integer frame_ink [0:23];
    integer border_bad = 0;
    integer paper_bad  = 0;
    integer zi;
    initial for (zi = 0; zi < 24; zi = zi + 1) frame_ink[zi] = 0;

    always @(posedge clk) begin
        if (cap_req && cap_state == 2'd0 && px == 10'd0 && py == 10'd0) begin
            fr_fd = $fopen("build/frame.rgb", "wb");
            cap = 1'b1;
            cap_state = 2'd1;
        end
        if (cap && px < 10'd720 && py < 10'd480) begin
            $fwrite(fr_fd, "%c%c%c", rgb[23:16], rgb[15:8], rgb[7:0]);
            if (py >= 10'd48 && py < 10'd432 && px >= 10'd104 && px < 10'd616) begin
                if (rgb == 24'h000000)
                    frame_ink[(py - 10'd48) / 16] = frame_ink[(py - 10'd48) / 16] + 1;
                else if (rgb !== 24'hC0C0C0)
                    paper_bad = paper_bad + 1;
            end else if (rgb !== 24'hC0C0C0)
                border_bad = border_bad + 1;
        end
        if (cap && px == 10'd719 && py == 10'd479) begin
            cap = 1'b0;
            $fclose(fr_fd);
            cap_state = 2'd2;
        end
    end

    initial begin
        rst = 1'b1;
        repeat (200) @(posedge clk);
        rst = 1'b0;

        t_ms = 0;
        while (t_ms < ms) begin
            #100ms;
            t_ms = t_ms + 100;
            count_screen;
            dump_screen;
            $display("[%0d ms] bitmap %0d, attrs %0d (fill 0x02: %0d, cls 0x38: %0d), halt=%b",
                     t_ms, nz_bitmap, nz_attr, fill_attrs, cls_attrs, halt_n);
        end

        count_screen;
        // ------------------------------------------------------------------
        // The authentic 48K power-on screen
        //
        // NEW (0x11B7) clears the display and then, at 0x1295, prints the
        // message at 0x1539 -- "© 1982 Sinclair Research Ltd" -- through
        // PO_MSG.  CLS has left the lower print line at line 23, column 33
        // (0x0DAA: LD BC,$1721), so the message lands in the last character
        // row and the print position ends one cell past its last glyph.  The
        // ROM then opens channel K and waits for a key (WAIT_KEY at 0x15D4),
        // so the rest of the display stays white paper with black ink.
        //
        // That state is checked four ways: the glyphs are the ROM's own font
        // bytes, nothing else in the display file is inked, every attribute
        // cell is CLS's 0x38, and the system variables hold the values the
        // ROM's own instructions compute.  The captured HDMI frame must then
        // carry that ink in the bottom row only, over an all-white field.
        // ------------------------------------------------------------------

        // 1. the copyright line, glyph by glyph, from the ROM's font table
        copy_bad = 0;
        for (c = 0; c < 28; c = c + 1)
            for (l = 0; l < 8; l = l + 1) begin
                font_i = (msg[c] - 8'h20) * 8 + l;
                if (u_core.ram[16'h10E0 + l * 16'h0100 + c] !==
                    u_core.rom[16'h3D00 + font_i])
                    copy_bad = copy_bad + 1;
            end

        // 2. no other ink anywhere in the 6144-byte display file
        stray = 0;
        for (i = 0; i < 6144; i = i + 1)
            if (u_core.ram[i] !== 8'h00 &&
                !(i >= 16'h10E0 && i <= 16'h17FF && i[7:5] == 3'b111))
                stray = stray + 1;

        // 3. CLS painted every cell paper 7 / ink 0 (0x38)
        attr_bad = 0;
        for (i = 6144; i < 6912; i = i + 1)
            if (u_core.ram[i] !== 8'h38) attr_bad = attr_bad + 1;

        // 4. the system variables the start-up code sets.  Each of these is
        //    the result of ROM instructions alone, so a mismatch is a real
        //    divergence, not a modelling choice:
        //      RAMTOP  = the top of the 48K test that passed (0x11EF-0x1219)
        //      ERR_NR  = 0x00: the RAM test leaves RAM zeroed and the start-up
        //                never writes it; LINE_SCAN (0x1B1E) is the first
        //                code to set 0xFF ("no error"), i.e. after the first
        //                line is scanned, not at the prompt
        //      ERR_SP  = SP after EDITOR's two pushes below MAIN_2's CALL
        //                return address (0x0F2C-0x0F34)
        //      DF_SZ   = 2 (0x0D90)
        //      VARS/PROG/E_LINE/STKBOT/CHARS = the boot's areas (0x1235-0x1265)
        //      DF_CC   = 0x4000, S_POSN = 33/24 (CL_ALL's CL_SET, the top row)
        //      DF_CCL  = 0x50FC, S_POSNL = 5/23 (just past the 28 glyphs)
        //      TV_FLAG = 0x21 (lower part in use, "clear it after a key")
        sv_bad = 0;
        if ({u_core.ram[16'h1CB3], u_core.ram[16'h1CB2]} !== 16'hFF57) sv_bad = sv_bad + 1;
        if (u_core.ram[16'h1C3A] !== 8'h00) sv_bad = sv_bad + 1;
        if ({u_core.ram[16'h1C3E], u_core.ram[16'h1C3D]} !== 16'hFF50) sv_bad = sv_bad + 1;
        if (u_core.ram[16'h1C6B] !== 8'h02) sv_bad = sv_bad + 1;
        if ({u_core.ram[16'h1C85], u_core.ram[16'h1C84]} !== 16'h4000) sv_bad = sv_bad + 1;
        if ({u_core.ram[16'h1C89], u_core.ram[16'h1C88]} !== 16'h1821) sv_bad = sv_bad + 1;
        if ({u_core.ram[16'h1C87], u_core.ram[16'h1C86]} !== 16'h50FC) sv_bad = sv_bad + 1;
        if ({u_core.ram[16'h1C8B], u_core.ram[16'h1C8A]} !== 16'h1705) sv_bad = sv_bad + 1;
        if ({u_core.ram[16'h1C4C], u_core.ram[16'h1C4B]} !== 16'h5CCB) sv_bad = sv_bad + 1;
        if ({u_core.ram[16'h1C54], u_core.ram[16'h1C53]} !== 16'h5CCB) sv_bad = sv_bad + 1;
        if ({u_core.ram[16'h1C5A], u_core.ram[16'h1C59]} !== 16'h5CCC) sv_bad = sv_bad + 1;
        if ({u_core.ram[16'h1C64], u_core.ram[16'h1C63]} !== 16'h5CCE) sv_bad = sv_bad + 1;
        if ({u_core.ram[16'h1C37], u_core.ram[16'h1C36]} !== 16'h3C00) sv_bad = sv_bad + 1;
        if (u_core.ram[16'h1C3C] !== 8'h21) sv_bad = sv_bad + 1;

        $display("system vars: RAMTOP=%04x ERR_NR=%02x ERR_SP=%04x DF_SZ=%02x TV_FLAG=%02x pc=%04x sp=%04x",
                 {u_core.ram[16'h1CB3], u_core.ram[16'h1CB2]},
                 u_core.ram[16'h1C3A],
                 {u_core.ram[16'h1C3E], u_core.ram[16'h1C3D]},
                 u_core.ram[16'h1C6B], u_core.ram[16'h1C3C],
                 u_core.u_cpu.PC, u_core.u_cpu.SP);
        $display("print position: DF_CC=%04x S_POSN=%02x%02x  DF_CCL=%04x S_POSNL=%02x%02x",
                 {u_core.ram[16'h1C85], u_core.ram[16'h1C84]},
                 u_core.ram[16'h1C89], u_core.ram[16'h1C88],
                 {u_core.ram[16'h1C87], u_core.ram[16'h1C86]},
                 u_core.ram[16'h1C8B], u_core.ram[16'h1C8A]);
        $display("areas: VARS=%04x PROG=%04x E_LINE=%04x STKBOT=%04x CHARS=%04x",
                 {u_core.ram[16'h1C4C], u_core.ram[16'h1C4B]},
                 {u_core.ram[16'h1C54], u_core.ram[16'h1C53]},
                 {u_core.ram[16'h1C5A], u_core.ram[16'h1C59]},
                 {u_core.ram[16'h1C64], u_core.ram[16'h1C63]},
                 {u_core.ram[16'h1C37], u_core.ram[16'h1C36]});

        dump_screen;

        // grab a frame of the actual video output for the same inspection
        cap_req = 1'b1;
        while (cap_state != 2'd2) @(posedge clk);
        $display("captured build/frame.rgb (720x480 RGB)");

        // 5. the picture: ink in the last character row only, and the rest of
        //    the frame the plain white the ROM's border and paper produce
        frame_bad = 0;
        for (i = 0; i < 23; i = i + 1) if (frame_ink[i] != 0) frame_bad = frame_bad + 1;
        if (frame_ink[23] < 500) frame_bad = frame_bad + 1;

        if (copy_bad != 0)
            $display("FAIL: the copyright line is not the ROM's own glyphs (%0d bytes differ)", copy_bad);
        else if (stray != 0)
            $display("FAIL: %0d inked bytes outside the bottom line", stray);
        else if (attr_bad != 0)
            $display("FAIL: %0d attribute cells are not CLS's 0x38", attr_bad);
        else if (sv_bad != 0)
            $display("FAIL: %0d system variables differ from the ROM's start-up values", sv_bad);
        else if (frame_bad != 0 || border_bad != 0 || paper_bad != 0)
            $display("FAIL: video frame wrong (inked rows outside the bottom line: %0d, black pixels in the bottom line: %0d, border anomalies: %0d, paper anomalies: %0d)",
                     frame_bad, frame_ink[23], border_bad, paper_bad);
        else begin
            $display("PASS: authentic power-on screen -- '© 1982 Sinclair Research Ltd' in the bottom line");
            $display("      %0d inked bytes in the display file, %0d black pixels in the video frame",
                     nz_bitmap, frame_ink[23]);
            $display("      see build/ram.hex and build/frame.rgb for the picture");
        end

        $finish;
    end

    // watchdog
    initial begin
        #((ms + 300) * 1ms);
        $display("FAIL: watchdog expired");
        count_screen;
        dump_screen;
        $finish;
    end

endmodule

`default_nettype wire
