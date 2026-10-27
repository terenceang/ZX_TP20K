// ============================================================================
//  tb_vol.v -- ZXCONFIG.TXT's VOL= line, through sd_vol's config parser
//
//  No card model: each byte is forced straight into the parser's input (the
//  DATA state's T_CFG branch, rxv), one clock at a time, then a newline.
// ============================================================================
`timescale 1ns/1ps
module tb_vol;
    reg clk = 0; always #18.5 clk = ~clk;
    sd_vol u (.clk(clk), .reset(1'b0), .sd_miso(1'b1), .ddr_ready(1'b0), .m_rdata(16'd0), .m_ack(1'b0),
              .f_up_busy(1'b0), .f_up_done(1'b0), .f_dn_data(8'd0), .f_dn_valid(1'b0), .fl_wr(1'b0),
              .fl_wr_drv(1'b0), .fl_wr_blk(11'd0), .bg_hold(1'b1), .wb_go(1'b0), .wb_drv(1'b0), .wb_blk(16'd0),
              .rb_go(1'b0), .mnt_go(1'b0), .mnt_drv(2'd0), .x_go(1'b0), .x_lba(32'd0), .x_zero(1'b0),
              .x_byte(8'd0), .x_valid(1'b0), .r_go(1'b0), .r_lba(32'd0), .r_cnt(16'd0), .r_take(1'b0));
    integer errors = 0, i;
    task feed(input [8*40-1:0] s, input integer n); begin
        u.vs = 0; u.bcnt = 0; u.fsize[4] = 400;
        for (i = n-1; i >= 0; i = i - 1) begin
            @(negedge clk); force u.st = 6; force u.got = 1; force u.tgt = 4; force u.rxv = s[8*i +: 8];
            @(posedge clk); #1 release u.st; release u.got; release u.tgt; release u.rxv;
        end
        @(negedge clk); force u.st = 6; force u.got = 1; force u.tgt = 4; force u.rxv = 8'h0A;
        @(posedge clk); #1 release u.st; release u.got; release u.tgt; release u.rxv;
    end endtask
    task chk(input [6:0] want); begin
        if (u.vol !== want) begin $display("FAIL: vol %0d, want %0d", u.vol, want); errors = errors + 1; end
    end endtask
    initial begin
        #100; chk(5);
        feed("VOL=20", 6);              chk(20);
        feed("  vol = 7 ; low", 15);    chk(7);
        feed("VOL=250", 7);             chk(100);
        feed("VOL=100", 7);             chk(100);
        feed("VOL=0", 5);               chk(0);
        feed("VOL=", 4);                chk(0);   // no digits: unchanged
        feed("VOLUME=9", 8);            chk(0);   // not the key
        feed("TAPE=VOL.TAP", 12);       chk(0);
        feed("VOL=x1", 6);              chk(0);
        feed({"VOL=33", 8'h0D}, 7);   chk(33);
        if (errors == 0) $display("PASS: vol parser");
        $finish;
    end
endmodule
`default_nettype wire
