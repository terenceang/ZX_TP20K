// ============================================================================
//  tb_ddr.v -- the DDR3 wrapper against the behavioural IP model
//
//  Waits for zx_ddr's self-test to pass (ready), then drives the client
//  port: a write, a read back, a masked write, a read back.  The model
//  (sim/models/ddr3_model.v) flags protocol crimes on its own; this
//  testbench checks the data.
//
//  The model substitutes for the encrypted IP; `ready` here means the
//  wrapper logic works, not that the board's DDR3 calibrates -- that is a
//  hardware bring-up question (docs/bring-up.md).
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_ddr;
    // the two clocks zx_ddr expects: 27 MHz clients, the IP's memory clock
    reg clk = 1'b0;
    always #18.519 clk = ~clk;

    reg ddr_memory_clk = 1'b0;
    always #1.2557 ddr_memory_clk = ~ddr_memory_clk;   // ~398.25 MHz

    reg pll_lock = 1'b0;

    wire        ready, idle, ack;
    wire [15:0] rdata;

    reg        go = 1'b0;
    reg [25:0] addr = 26'd0;
    reg        we = 1'b0;
    reg [1:0]  be = 2'b11;
    reg [15:0] wdata = 16'd0;

    wire [15:0] DDR3_DQ;
    wire [1:0]  DDR3_DQS, DDR3_DQS_n;
    wire [13:0] DDR3_A;
    wire [2:0]  DDR3_BA;
    wire DDR3_nCS, DDR3_nRAS, DDR3_nCAS, DDR3_nWE, DDR3_CK, DDR3_CK_n,
         DDR3_CKE, DDR3_nRESET, DDR3_ODT;
    wire [1:0] DDR3_DM;

    zx_ddr u_dut (
        .clk(clk), .reset(1'b0),
        .ddr_ref_clk(clk),
        .go(go), .addr(addr), .we(we), .be(be), .wdata(wdata),
        .rdata(rdata), .ack(ack), .idle(idle),
        .ready(ready),
        .ddr_memory_clk(ddr_memory_clk), .ddr_lock(pll_lock),
        .DDR3_DQ(DDR3_DQ), .DDR3_DQS(DDR3_DQS), .DDR3_DQS_n(DDR3_DQS_n),
        .DDR3_A(DDR3_A), .DDR3_BA(DDR3_BA), .DDR3_nCS(DDR3_nCS),
        .DDR3_nRAS(DDR3_nRAS), .DDR3_nCAS(DDR3_nCAS), .DDR3_nWE(DDR3_nWE),
        .DDR3_CK(DDR3_CK), .DDR3_CK_n(DDR3_CK_n), .DDR3_CKE(DDR3_CKE),
        .DDR3_nRESET(DDR3_nRESET), .DDR3_ODT(DDR3_ODT), .DDR3_DM(DDR3_DM)
    );

    integer errors = 0;

    // one client operation, then wait for the ack
    task op(input wr, input [25:0] a, input [1:0] be_, input [15:0] d);
        begin
            @(posedge clk);
            go <= 1'b1; we <= wr; addr <= a; be <= be_; wdata <= d;
            @(posedge clk);
            go <= 1'b0;
            while (!ack) @(posedge clk);
        end
    endtask

    task expect_data(input [15:0] got, input [15:0] want, input [127:0] what);
        if (got !== want) begin
            $display("FAIL: %0s: read %04x, expected %04x", what, got, want);
            errors = errors + 1;
        end else
            $display("ok: %0s (%04x)", what, got);
    endtask

    initial begin
        repeat (20) @(posedge clk);
        pll_lock = 1'b1;

        // the self-test runs after the model's calibration; ready means it passed
        wait (ready === 1'b1);
        $display("ok: self-test passed, DDR3 ready");

        // word address 0x1000: inside the model's region 0
        op(1'b1, 26'h1000, 2'b11, 16'hBEEF);
        op(1'b0, 26'h1000, 2'b11, 16'h0000);
        expect_data(rdata, 16'hBEEF, "write then read back");

        op(1'b1, 26'h1000, 2'b01, 16'h1234);   // the low byte only (bit0 = low)
        op(1'b0, 26'h1000, 2'b11, 16'h0000);
        expect_data(rdata, 16'hBE34, "masked write keeps the high byte");

        op(1'b0, 26'h2000, 2'b11, 16'h0000);
        expect_data(rdata, 16'h0000, "a fresh word reads zero");

        if (errors == 0) $display("PASS: zx_ddr");
        $finish;
    end

    // watchdog
    initial begin
        #2ms;
        $display("FAIL: watchdog expired (self-test step %0d, bad %b)", u_dut.tst, u_dut.tbad);
        $finish;
    end

endmodule

`default_nettype wire
