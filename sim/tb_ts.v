// ============================================================================
//  tb_ts.v -- T-state trace of zx_core (development probe)
//
//  Prints every enabled T-state in a time window: the CPU's bus, the ULA's
//  view of it, and the CPU's accumulator.  For finding where an instruction
//  stream derails.
//
//    +t0=<us> +t1=<us>   window, default 15..45
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_ts;
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
    wire [23:0] rgb;
    wire halt_n, flash, key_hit, frame_tick, audio_valid;
    wire [15:0] audio_l, audio_r;

    zx_core u_core (
        .clk(clk), .reset(rst), .ce_cpu(ce_cpu), .ce_48k(1'b0),
        .uart_rx(1'b1), .key_hit(key_hit),
        .vid_x(px), .vid_y(vcnt), .vid_rgb(rgb), .flash(flash),
        .audio_valid(audio_valid), .audio_l(audio_l), .audio_r(audio_r),
        .halt_n(halt_n), .frame_tick(frame_tick)
    );

    integer t0 = 15, t1 = 45;
    realtime tns;
    integer n = 0;

    initial begin
        if (!$value$plusargs("t0=%d", t0)) t0 = 15;
        if (!$value$plusargs("t1=%d", t1)) t1 = 45;
    end

    always @(posedge clk) begin
        tns = $realtime;   // ns
        if (tns >= t0*1000 && tns <= t1*1000) begin
            // sysvars the boot's CLS and print-position logic touch, plus the
            // code around the boot's CLS/©-print calls
            if (u_core.wr_pulse && u_core.a >= 16'h5C00 && u_core.a <= 16'h5CFF)
                $display("%0t WR  a=%04x d=%02x", $time, u_core.a, u_core.cpu_dout);
            if (u_core.rd_strobe && u_core.ts[2] && u_core.mc[0] &&
                ((u_core.a >= 16'h09E0 && u_core.a <= 16'h0A60) ||
                 (u_core.a >= 16'h0D40 && u_core.a <= 16'h0DB0) ||
                 (u_core.a >= 16'h0E20 && u_core.a <= 16'h0E80) ||
                 (u_core.a >= 16'h1290 && u_core.a <= 16'h12A0) ||
                 (u_core.a >= 16'h15C0 && u_core.a <= 16'h1640)))
                $display("%0t RD  pc=%04x op=%02x", $time, u_core.a, u_core.bus_now);
            n = n + 1;
            if (n > 4000) $finish;
        end
    end

    initial begin
        repeat (200) @(posedge clk);
        rst = 1'b0;
        #((t1 + 5) * 1000);
        $display("done, %0d T-states", n);
        $finish;
    end
endmodule

`default_nettype wire
