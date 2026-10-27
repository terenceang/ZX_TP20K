// ============================================================================
//  tb_type.v -- type the LOAD "" macro into the real 48K ROM and read back
//  what lands on the screen.
//
//  The web page's typist (web/src/zxkeys.js typeText) sends FE matrix events
//  at a fixed pace: chord down, 45 ms hold, up, 35 ms gap.  This tb drives
//  the same key sequence into zx_core (tv80 + real ROM) at that pace, then
//  decodes the editor line (character row 23) glyph by glyph through the
//  ROM's own font, and checks that ENTER actually ran LOAD "" by watching
//  tape_load -- zx_core pulses it when the CPU fetches LD-BYTES (0x0556),
//  which is exactly what the tape deck listens for.
//
//  Variants (+variant=N):
//    1  the page today: chord = [sym, main]; press sym, press main, hold,
//       release sym, release main
//    2  release the main key first, then the shift (a typist lifting the
//       letter finger before the shift finger)
//    3  human style: SYMBOL SHIFT held across both quotes, P tapped twice
//
//  plusargs: +variant=1..3  +fast=0|1|2 (CPU speed, default 2)  +quiet=1
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_type;
    localparam H_TOTAL = 858, V_TOTAL = 525;

    reg clk = 1'b0;
    always #18.519 clk = ~clk;      // 27 MHz

    integer fast = 2;
    initial if (!$value$plusargs("fast=%d", fast)) fast = 2;
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
    reg uart_rx = 1'b1;

    wire [23:0] rgb;
    wire halt_n, flash, key_hit, frame_tick, audio_valid, tape_load;
    wire [15:0] audio_l, audio_r;

    zx_core u_core (
        .clk(clk), .reset(rst), .ce_cpu(ce_cpu), .ce_48k(1'b0),
        .uart_rx(uart_rx), .key_hit(key_hit), .ear(1'b1),
        .tape_load(tape_load),
        .vid_x(px), .vid_y(py), .vid_rgb(rgb), .flash(flash),
        .audio_valid(audio_valid), .audio_l(audio_l), .audio_r(audio_r),
        .halt_n(halt_n), .frame_tick(frame_tick)
    );

    reg saw_tape = 1'b0;
    always @(posedge clk) if (tape_load) saw_tape <= 1'b1;

    // ---- instrumentation: virtual-matrix changes + the ROM's keyboard vars
    reg [39:0] vk_prev = 40'd0;
    always @(posedge clk) begin
        if (!rst && u_core.vk_matrix !== vk_prev) begin
            $display("%0t ms  vk_matrix %010x -> %010x",
                     $time / 1000000, vk_prev, u_core.vk_matrix);
            vk_prev <= u_core.vk_matrix;
        end
    end

    // K0/K1 (0x5C08/09: the raw two-key scan result) and LASTK (0x5C41: the
    // decoded key the editor consumes)
    always @(posedge clk) begin
        if (!rst && u_core.wr_pulse) begin
            if (u_core.a == 16'h5C08)
                $display("%0t ms  K0   = %02x", $time / 1000000, u_core.cpu_dout);
            else if (u_core.a == 16'h5C09)
                $display("%0t ms  K1   = %02x", $time / 1000000, u_core.cpu_dout);
            else if (u_core.a == 16'h5C41)
                $display("%0t ms  LASTK= %02x", $time / 1000000, u_core.cpu_dout);
        end
    end

    // every ULA port read in the interesting window (address + byte given
    // to the CPU) -- the smoking gun if KEY-SCAN runs but reads nothing
    reg ula_rd_prev = 1'b0;
    always @(posedge clk) begin
        if (!rst && $time >= 340000000 && $time <= 580000000) begin
            ula_rd_prev <= u_core.io_rd && u_core.ula;
            if (u_core.io_rd && u_core.ula && !ula_rd_prev)
                $display("%0t ms  ULA RD a=%04x -> %02x",
                         $time / 1000000, u_core.a, u_core.io_dout);
        end
    end

    // KEY-SCAN entry (0x02BB): prove the editor is actually polling the
    // keyboard, and when
    reg scan_prev = 1'b0;
    always @(posedge clk) begin
        if (!rst) begin
            scan_prev <= (u_core.u_cpu.PC == 16'h02BB);
            if (u_core.u_cpu.PC == 16'h02BB && !scan_prev)
                $display("%0t ms  KEY-SCAN entered", $time / 1000000);
        end
    end

    integer quiet = 0;
    initial if (!$value$plusargs("quiet=%d", quiet)) quiet = 0;
    integer variant = 1;
    initial if (!$value$plusargs("variant=%d", variant)) variant = 1;
    // shift the typing start (ms): on hardware the phase between keystrokes
    // and the ROM's scan bursts drifts, so a fix must pass at every phase
    integer phase = 0;
    initial if (!$value$plusargs("phase=%d", phase)) phase = 0;

    // the page's pacing (typeText defaults, overridable for the sweep)
    integer HOLD = 45;              // ms the chord is held
    integer GAP  = 35;              // ms before the next chord
    integer RPT  = 35;              // ms after a chord that repeats next
    initial if (!$value$plusargs("hold=%d", HOLD)) HOLD = 45;
    initial if (!$value$plusargs("gap=%d", GAP)) GAP = 35;
    initial if (!$value$plusargs("rpt=%d", RPT)) RPT = 35;

    integer errors = 0;

    // one byte, 8N1, LSB first, 27 clocks per bit
    task send_byte(input [7:0] b);
        integer k;
        begin
            uart_rx = 1'b0;                       // start
            repeat (27) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                uart_rx = b[k];
                repeat (27) @(posedge clk);
            end
            uart_rx = 1'b1;                       // stop
            repeat (27) @(posedge clk);
        end
    endtask

    task key(input [5:0] pos, input down);
        begin
            send_byte(8'hFE);
            send_byte({2'b00, pos});
            send_byte({7'b0, down});
        end
    endtask

    task tap(input [5:0] p);
        begin
            key(p, 1'b1);
            #(HOLD * 1ms);
            key(p, 1'b0);
            #(GAP * 1ms);
        end
    endtask

    // a quote chord followed by the SAME chord: the trailing RPT gap is the
    // all-up window before the repeat.  The ROM's KSTATE keeps a released
    // key latched ~5 interrupts (~100 ms); a re-press inside that window is
    // treated as the same press and dropped, so the repeat must wait it out.
    task chord_repeat(input [5:0] shift, input [5:0] main);
        begin
            key(shift, 1'b1); key(main, 1'b1);
            #(HOLD * 1ms);
            key(shift, 1'b0); key(main, 1'b0);
            #(RPT * 1ms);
        end
    endtask

    // variant 1 -- what typeText does today: release in chord order, i.e.
    // the shift first, then the main key
    task chord_v1(input [5:0] shift, input [5:0] main);
        begin
            key(shift, 1'b1); key(main, 1'b1);
            #(HOLD * 1ms);
            key(shift, 1'b0); key(main, 1'b0);
            #(GAP * 1ms);
        end
    endtask

    // variant 2 -- main key up first, then the shift
    task chord_v2(input [5:0] shift, input [5:0] main);
        begin
            key(shift, 1'b1); key(main, 1'b1);
            #(HOLD * 1ms);
            key(main, 1'b0); key(shift, 1'b0);
            #(GAP * 1ms);
        end
    endtask

    // variant 3 -- the human chord: the shift stays held, the main key is
    // tapped twice, then the shift comes up
    task quotes_v3;
        begin
            key(6'd36, 1'b1);                                      // SYMBOL SHIFT
            key(6'd25, 1'b1); #(HOLD * 1ms); key(6'd25, 1'b0); #(GAP * 1ms);
            key(6'd25, 1'b1); #(HOLD * 1ms); key(6'd25, 1'b0); #(GAP * 1ms);
            key(6'd36, 1'b0); #(GAP * 1ms);
        end
    endtask

    // ------------------------------------------------------------------
    // decode character row 23 (the editor line) through the ROM's own
    // font, exactly as tb_zx checks the copyright line.  Glyph for ch is
    // rom[0x3D00 + (ch-0x20)*8 + l]; row 23's bitmap base is 0x50E0.
    // ------------------------------------------------------------------
    reg [7:0] line_txt [0:31];

    task decode_line;
        integer c, l, ch, ok;
        begin
            for (c = 0; c < 32; c = c + 1) begin
                line_txt[c] = 8'h3F;              // '?' if nothing matches
                for (ch = 8'h20; ch < 8'h80 && line_txt[c] == 8'h3F; ch = ch + 1) begin
                    ok = 1;
                    for (l = 0; l < 8; l = l + 1)
                        if (u_core.ram[16'h10E0 + l * 16'h0100 + c] !==
                            u_core.rom[16'h3D00 + (ch - 8'h20) * 8 + l]) ok = 0;
                    if (ok) line_txt[c] = ch;
                end
            end
            $write("      line 23: \"");
            for (c = 0; c < 32; c = c + 1) $write("%c", line_txt[c]);
            $write("\"\n");
        end
    endtask

    task check_char(input integer col, input [7:0] want, input [127:0] what);
        begin
            if (line_txt[col] !== want) begin
                $display("FAIL: %0s: col %0d is %02x, expected %02x",
                         what, col, line_txt[col], want);
                errors = errors + 1;
            end else if (!quiet)
                $display("ok: %0s (col %0d)", what, col);
        end
    endtask

    integer fd, i;
    initial begin
        rst = 1'b1;
        repeat (200) @(posedge clk);
        rst = 1'b0;

        // boot to the editor prompt (~240 ms machine time at +fast=2), then
        // start typing at +phase into the scan burst cycle
        #((280 + phase) * 1ms);
        $display("-- typing the macro, variant %0d (hold %0d ms, gap %0d ms)",
                 variant, HOLD, GAP);

        tap(6'd33);                                        // J: the LOAD token
        if (variant == 3) begin
            quotes_v3;
        end else if (variant == 2) begin
            chord_repeat(6'd36, 6'd25);     // quote 1: long all-up after it
            chord_v2(6'd36, 6'd25);         // quote 2: different keys next (ENTER)
        end else begin
            chord_repeat(6'd36, 6'd25);     // quote 1: long all-up after it
            chord_v1(6'd36, 6'd25);         // quote 2: next is ENTER, a new key
        end

        decode_line;
        check_char(0, "L", "LOAD token: L");
        check_char(1, "O", "LOAD token: O");
        check_char(2, "A", "LOAD token: A");
        check_char(3, "D", "LOAD token: D");
        check_char(4, " ", "the keyword's trailing space");
        check_char(5, "\"", "first quote");
        check_char(6, "\"", "second quote");

        tap(6'd30);                                        // ENTER
        #200ms;

        if (saw_tape) begin
            if (!quiet) $display("ok: ENTER ran LOAD \"\" (tape_load pulsed, LD-BYTES entered)");
        end else begin
            $display("FAIL: ENTER did not run LOAD \"\" (no tape_load pulse)");
            errors = errors + 1;
        end

        // the whole 48K for manual inspection
        fd = $fopen("build/type_ram.hex", "w");
        if (fd != 0) begin
            for (i = 0; i < 49152; i = i + 1) $fwrite(fd, "%02x\n", u_core.ram[i]);
            $fclose(fd);
        end

        if (errors == 0) $display("PASS: variant %0d types LOAD \"\" and runs it", variant);
        else $display("FAIL: variant %0d: %0d errors", variant, errors);
        $finish;
    end

    // watchdog
    initial begin
        #2s;
        $display("FAIL: watchdog expired");
        $finish;
    end

endmodule

`default_nettype wire
