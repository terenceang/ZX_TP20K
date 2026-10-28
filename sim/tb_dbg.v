// ============================================================================
//  tb_dbg.v -- development probe for zx_core (not part of the pass/fail suite)
//
//  Runs a short stretch of machine time and prints where the CPU is, what it
//  fetches and whether writes land, so a dead boot can be told apart from a
//  slow one.  Sampled every microsecond; plusarg +us=<n> sets the run length.
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_dbg;
    reg clk = 1'b0;
    always #18.519 clk = ~clk;

    reg [5:0] acc_cpu = 6'd0;
    reg       ce_cpu  = 1'b0;
    integer   fast = 0;
    initial if (!$value$plusargs("fast=%d", fast)) fast = 0;
    always @(posedge clk) begin
        if (fast) begin
            ce_cpu  <= (acc_cpu[0] == 1'b0);
            acc_cpu <= acc_cpu + 6'd1;
        end else if (acc_cpu + 6'd7 >= 6'd54) begin
            acc_cpu <= acc_cpu + 6'd7 - 6'd54; ce_cpu <= 1'b1;
        end else begin
            acc_cpu <= acc_cpu + 6'd7; ce_cpu <= 1'b0;
        end
    end

    reg [9:0] hcnt = 10'd0, vcnt = 10'd0;
    always @(posedge clk) begin
        if (hcnt == 857) begin hcnt <= 0; vcnt <= (vcnt == 524) ? 0 : vcnt + 1; end
        else hcnt <= hcnt + 1;
    end
    wire [9:0] px = hcnt - 10'd2;

    reg rst = 1'b1;
    reg uart_rx = 1'b1;
    wire [23:0] rgb;
    wire halt_n, flash, key_hit, frame_tick, audio_valid;
    wire [15:0] audio_l, audio_r;

    zx_core u_core (
        .clk(clk), .reset(rst), .ce_cpu(ce_cpu), .ce_48k(1'b0),
        .uart_rx(uart_rx), .key_hit(key_hit), .usb_keys(40'd0), .kempston(5'd0),
        .vid_x(px), .vid_y(vcnt), .vid_rgb(rgb), .flash(flash),
        .audio_valid(audio_valid), .audio_l(audio_l), .audio_r(audio_r),
        .halt_n(halt_n), .frame_tick(frame_tick)
    );

    integer us = 60;
    initial if (!$value$plusargs("us=%d", us)) us = 60;

    integer writes = 0;
    integer cen_seen = 0;
    always @(posedge clk) begin
        if (u_core.wr_pulse && !u_core.is_rom) begin
            writes = writes + 1;
            if (writes <= 3)
                $display("[%0t] wr#%0d a=%04x data=%02x idx=%04x pc=%04x",
                         $time, writes, u_core.a, u_core.cpu_dout, u_core.cpu_ram_a, u_core.u_cpu.PC);
        end
        if (u_core.ce) cen_seen = cen_seen + 1;
    end

    // the first opcode fetches, byte by byte
    reg [15:0] last_pc = 16'hFFFF;
    integer trace = 0;
    initial if (!$value$plusargs("trace=%d", trace)) trace = 0;
    always @(posedge clk) begin
        if (trace && u_core.ce && u_core.mc[0] && u_core.ts[2] && !rst && $time > 7400) begin
            $display("[%0t ns] fetch PC=%04x op=%02x A=%04x sp=%04x acc=%02x",
                     $time, u_core.a, u_core.mem_dout, u_core.a,
                     u_core.u_cpu.SP, u_core.u_cpu.ACC);
        end
    end

    integer i;
    initial begin
        rst = 1'b1;
        repeat (200) @(posedge clk);
        rst = 1'b0;
        $display("rom[0]=%02x rom[1]=%02x rom[5]=%02x (want F3 AF C3)",
                 u_core.rom[0], u_core.rom[1], u_core.rom[5]);

        // sample finely enough to watch the boot phase by phase
        for (i = 1; i <= 60; i = i + 1) begin
            #(us * 1ms / 60);
            $display("[%0t] PC=%04x A=%04x halt=%b writes=%0d int_n=%b border=%0d ram0000=%02x ram1800=%02x sp=%04x",
                     $time, u_core.u_cpu.PC, u_core.a, halt_n, writes,
                     u_core.int_n, u_core.border, u_core.ram[0], u_core.ram[16'h1800], u_core.u_cpu.SP);
        end
        $finish;
    end

    // X forensics: the first RAM read/write and anything undefined
    reg seen_rd = 0, seen_wr = 0, complained = 0;
    always @(posedge clk) begin
        if (u_core.ce && u_core.ts[2] && !u_core.iorq && !u_core.write && !u_core.no_read && !u_core.is_rom && !seen_rd) begin
            seen_rd = 1;
            $display("[%0t ns] first RAM read: a=%04x ram_q=%02x mux=%02x window=%b",
                     $time, u_core.a, u_core.ram_q, u_core.mem_dout, u_core.vid_window);
        end
        if (u_core.wr_pulse && !seen_wr) begin
            seen_wr = 1;
            $display("[%0t ns] first RAM write: a=%04x data=%02x -> idx=%04x",
                     $time, u_core.a, u_core.cpu_dout, u_core.cpu_ram_a);
        end
        if (!complained && (u_core.a === 16'hxxxx || u_core.di_bus === 8'hxx)) begin
            complained = 1;
            $display("[%0t ns] X! a=%04x pc=%04x di=%b wr_pulse=%b ts=%b mc=%b",
                     $time, u_core.a, u_core.u_cpu.PC, u_core.di_bus,
                     u_core.wr_pulse, u_core.ts, u_core.mc);
        end
    end

    initial begin
        #((us + 50) * 1ms);
        $display("watchdog");
        $finish;
    end
endmodule

`default_nettype wire
