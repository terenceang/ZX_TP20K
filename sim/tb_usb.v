// ============================================================================
//  tb_usb.v -- the USB keyboard / gamepad path (src/zx_usb.v)
//
//  1. A USB3317 stand-in on the ULPI pins: DIR high through its start-up,
//     NXT for each TXCMD and data byte, and one RX CMD (DIR) dropped into the
//     middle of the first write.  The link must write exactly
//     04<=46, 0A<=06, 07<=01, each ended by one STP over 00, then let go of
//     data[7:3] and drive only the serial pins (tx_enable idle low).
//  2. zx_usb_map on its own: HID reports in, membrane contacts and the
//     Kempston byte out.
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_usb;
    reg clk = 1'b0;   always #18.519 clk = ~clk;     // 27 MHz
    reg c12 = 1'b0;   always #41.667 c12 = ~c12;     // 12 MHz
    reg c60 = 1'b0;   always #8.333  c60 = ~c60;     // PHY CLKOUT

    wire       rst_n, stp;
    reg        dir = 1'b1, nxt = 1'b0;
    reg  [7:0] phy_o = 8'h00;
    wire [7:0] data;
    assign data = dir ? phy_o : 8'hzz;
    pulldown pd[7:0] (data);       // weak: shows an undriven bit as 0 below

    wire [39:0] keys;
    wire [4:0]  kemp;
    wire        hit;

    zx_usb u_dut (
        .clk(clk), .clk_usb(c12),
        .usb_clk60(c60), .usb_reset_n(rst_n),
        .usb_dir(dir), .usb_nxt(nxt), .usb_stp(stp), .usb_data(data),
        .usb_keys(keys), .kempston(kemp), .usb_hit(hit)
    );

    integer fails = 0;
    task check(input cond, input [8*64-1:0] what);
        if (!cond) begin $display("FAIL: %0s", what); fails = fails + 1; end
    endtask

    // ---- the PHY: register writes as the ULPI spec draws them ----------
    reg [7:0] got_a [0:7];
    reg [7:0] got_d [0:7];
    integer   n_wr = 0, n_rxcmd = 0;
    reg [7:0] cur_a;
    reg [1:0] ph = 2'd0;           // 0 idle, 1 cmd accepted, 2 data on the bus, 3 STP
    always @(posedge c60) begin
        nxt <= 1'b0;
        if (!dir) case (ph)
            2'd0: if (data[7:6] == 2'b10) begin
                      // one RX CMD across the first write's TXCMD
                      if (n_wr == 0 && n_rxcmd == 0) begin
                          n_rxcmd <= 1; dir <= 1'b1; phy_o <= 8'h01;
                      end else begin cur_a <= data; nxt <= 1'b1; ph <= 2'd1; end
                  end
            2'd1: begin nxt <= 1'b1; ph <= 2'd2; end                    // NXT through the data cycle
            2'd2: begin got_a[n_wr] <= cur_a & 8'h3F; got_d[n_wr] <= data; ph <= 2'd3; end
            2'd3: begin
                      check(stp === 1'b1 && data === 8'h00, "STP over 00 after the data byte");
                      n_wr <= n_wr + 1; ph <= 2'd0;
                  end
        endcase
        else if (n_rxcmd == 1 && rst_n) begin dir <= 1'b0; n_rxcmd <= 2; end   // RX CMD done
    end

    // ---- zx_usb_map on its own -------------------------------------------
    reg  [1:0] typ = 2'd0;
    reg  [7:0] kmod = 8'h00, k1 = 8'h00, k2 = 8'h00, k3 = 8'h00, k4 = 8'h00;
    reg  [4:0] pad = 5'd0;
    reg        psel = 1'b0, psta = 1'b0;
    wire [39:0] mk;
    wire [4:0]  mkemp;
    zx_usb_map u_map (.typ(typ), .kmod(kmod), .k1(k1), .k2(k2), .k3(k3), .k4(k4),
                      .pad(pad), .pad_sel(psel), .pad_sta(psta), .keys(mk), .kemp(mkemp));

    function [39:0] at;            // bits set at the given positions (63 = none)
        input [5:0] a, b, c;
        begin
            at = 40'd0;
            if (a != 63) at[a] = 1'b1;
            if (b != 63) at[b] = 1'b1;
            if (c != 63) at[c] = 1'b1;
        end
    endfunction

    task kb(input [7:0] m, input [7:0] a, input [7:0] b, input [39:0] want, input [8*48-1:0] what);
        begin
            typ = 2'd1; kmod = m; k1 = a; k2 = b; #1;
            if (mk !== want) begin
                $display("FAIL: %0s: keys %h, want %h", what, mk, want); fails = fails + 1;
            end
        end
    endtask

    initial begin
        // ---- map ----
        kb(8'h00, 8'h04, 8'h00, at(5, 63, 63),   "a");
        kb(8'h02, 8'h04, 8'h00, at(0, 5, 63),    "LShift+a = CAPS+A");
        kb(8'h00, 8'h27, 8'h00, at(20, 63, 63),  "0");
        kb(8'h02, 8'h1E, 8'h00, at(36, 15, 63),  "LShift+1 = ! (SYM+1, no CAPS)");
        kb(8'h02, 8'h34, 8'h00, at(36, 25, 63),  "LShift+' = \" (SYM+P)");
        kb(8'h00, 8'h37, 8'h00, at(36, 37, 63),  ". = SYM+M");
        kb(8'h00, 8'h2A, 8'h00, at(0, 20, 63),   "Backspace = DELETE");
        kb(8'h00, 8'h52, 8'h00, at(0, 23, 63),   "Up = CAPS+7");
        kb(8'h00, 8'h29, 8'h00, at(0, 35, 63),   "Esc = BREAK");
        kb(8'h20, 8'h13, 8'h00, at(36, 25, 63),  "RShift+p = SYM+P");
        kb(8'h22, 8'h00, 8'h00, at(0, 36, 63),   "both shifts = extended mode");
        kb(8'h00, 8'h28, 8'h2C, at(30, 35, 63),  "Enter + Space together");
        kb(8'h00, 8'h31, 8'h00, 40'd0,           "unmapped (\\) is nothing");
        typ = 2'd3; pad = 5'b10101; psta = 1'b1; #1;
        check(mkemp === 5'b10101, "gamepad -> Kempston bits");
        check(mk === at(30, 63, 63), "START = ENTER");
        typ = 2'd1; #1;
        check(mkemp === 5'd0, "a keyboard is not a joystick");

        // ---- ULPI set-up ----
        wait (rst_n === 1'b1);
        repeat (200) @(posedge c60);
        dir <= 1'b0;                              // PHY start-up done
        repeat (2000) @(posedge c60);
        check(n_rxcmd == 2, "the RX CMD happened");
        check(n_wr == 3, "three register writes");
        check(got_a[0] == 8'h04 && got_d[0] == 8'h46, "Function Control <= 46 (LS host)");
        check(got_a[1] == 8'h0A && got_d[1] == 8'h06, "OTG Control <= 06 (pull-downs)");
        check(got_a[2] == 8'h07 && got_d[2] == 8'h01, "Interface Control <= 01 (6-pin serial)");
        check(u_dut.serial === 1'b1, "serial mode");
        dir = 1'b1; phy_o = 8'hzz;                // serial: PHY drives rx_dp/rx_dm only
        #200;
        check(data[7:3] === 5'b00000 && data[0] === 1'b0, "link drives only tx_* (enable low)");
        check(stp === 1'b0, "STP low (high would leave serial mode)");

        if (fails == 0) $display("PASS");
        $finish;
    end
endmodule

`default_nettype wire
