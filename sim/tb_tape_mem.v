// ============================================================================
//  tb_tape_mem.v -- the DDR3 tape store
//
//  Brings zx_ddr up against the behavioural IP model, writes a 301-byte image
//  (odd length, so the half-word tail is exercised) through the byte port the
//  card would use, waits for img_ready, then reads it back the way the player
//  does -- one rd_req at a time -- and compares.  Then rewinds and reads it
//  again, which is what replaying a tape without the card does.
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_tape_mem;
    reg clk = 1'b0;
    always #18.519 clk = ~clk;                 // 27 MHz

    reg ddr_memory_clk = 1'b0;
    always #1.2557 ddr_memory_clk = ~ddr_memory_clk;

    reg ddr_lock = 1'b0;

    wire        ready, idle, ack;
    wire [15:0] rdata;
    wire [31:0] diag;

    wire [15:0] DDR3_DQ;
    wire [1:0]  DDR3_DQS, DDR3_DQS_n;
    wire [13:0] DDR3_A;
    wire [2:0]  DDR3_BA;
    wire DDR3_nCS, DDR3_nRAS, DDR3_nCAS, DDR3_nWE, DDR3_CK, DDR3_CK_n,
         DDR3_CKE, DDR3_nRESET, DDR3_ODT;
    wire [1:0] DDR3_DM;

    // the store's client port, muxed away until the DDR3 is ready
    wire        tm_go;
    wire [25:0] tm_addr;
    wire        tm_we;
    wire [1:0]  tm_be;
    wire [15:0] tm_wdata;

    wire go    = ready ? tm_go    : 1'b0;
    wire [25:0] addr  = ready ? tm_addr  : 26'd0;
    wire we    = ready ? tm_we    : 1'b0;
    wire [1:0]  be    = ready ? tm_be    : 2'b11;
    wire [15:0] wdata = ready ? tm_wdata : 16'd0;

    zx_ddr u_ddr (
        .clk(clk), .reset(1'b0), .ddr_ref_clk(clk),
        .go(go), .addr(addr), .we(we), .be(be), .wdata(wdata),
        .rdata(rdata), .ack(ack), .idle(idle), .ready(ready), .diag(diag),
        .ddr_memory_clk(ddr_memory_clk), .ddr_lock(ddr_lock),
        .DDR3_DQ(DDR3_DQ), .DDR3_DQS(DDR3_DQS), .DDR3_DQS_n(DDR3_DQS_n),
        .DDR3_A(DDR3_A), .DDR3_BA(DDR3_BA), .DDR3_nCS(DDR3_nCS),
        .DDR3_nRAS(DDR3_nRAS), .DDR3_nCAS(DDR3_nCAS), .DDR3_nWE(DDR3_nWE),
        .DDR3_CK(DDR3_CK), .DDR3_CK_n(DDR3_CK_n), .DDR3_CKE(DDR3_CKE),
        .DDR3_nRESET(DDR3_nRESET), .DDR3_ODT(DDR3_ODT), .DDR3_DM(DDR3_DM)
    );

    // ---- the store under test -------------------------------------------
    reg         reset_tm = 1'b1;
    reg         wr_valid = 1'b0;
    reg  [7:0]  wr_byte = 8'h00;
    wire        wr_ready;
    wire [23:0] wr_count;
    reg  [23:0] img_len = 24'd0;
    reg         rewind = 1'b0;
    wire [23:0] rd_count;
    wire        img_ready, rd_empty;
    reg         rd_pop = 1'b0;
    wire [7:0]  rd_byte;

    zx_tape_mem u_mem (
        .clk(clk), .reset(reset_tm),
        .ddr_go(tm_go), .ddr_addr(tm_addr), .ddr_we(tm_we), .ddr_be(tm_be),
        .ddr_wdata(tm_wdata), .ddr_rdata(rdata), .ddr_ack(ack), .ddr_idle(idle),
        .wr_valid(wr_valid), .wr_byte(wr_byte), .wr_ready(wr_ready),
        .wr_count(wr_count), .img_len(img_len), .rewind(rewind),
        .rd_count(rd_count), .img_ready(img_ready), .rd_empty(rd_empty),
        .rd_pop(rd_pop), .rd_byte(rd_byte), .clear(1'b0)
    );

    // ---- the image: 301 bytes, a pattern that catches byte swaps ---------
    localparam integer N = 301;
    reg [7:0] img [0:N-1];
    integer i, errors = 0, pass;
    reg [7:0] got;

    // Driven from the falling edge, so every pulse is stable across the
    // rising edge the store works on -- no races in the testbench.
    task send_byte;
        input [7:0] b;
        begin
            @(negedge clk);
            while (!wr_ready) @(negedge clk);
            wr_valid <= 1'b1; wr_byte <= b;
            @(negedge clk);
            wr_valid <= 1'b0;
        end
    endtask

    task get_byte;
        output [7:0] b;
        begin
            @(negedge clk);
            while (rd_empty) @(negedge clk);
            b = rd_byte;
            rd_pop <= 1'b1;
            @(negedge clk);
            rd_pop <= 1'b0;
        end
    endtask



    initial begin
        for (i = 0; i < N; i = i + 1) img[i] = i[7:0] ^ 8'h5A;

        repeat (20) @(posedge clk);
        @(negedge clk); ddr_lock <= 1'b1;
        wait (ready);
        $display("ddr ready");
        repeat (20) @(posedge clk);
        @(negedge clk); reset_tm <= 1'b0;
        repeat (10) @(posedge clk);

        // ---- write the image ------------------------------------------
        for (i = 0; i < N; i = i + 1) send_byte(img[i]);
        img_len <= N;
        wait (img_ready);
        $display("image in: wr_count=%0d", wr_count);
        repeat (10) @(posedge clk);

        // ---- read it back, twice --------------------------------------
        for (pass = 0; pass < 2; pass = pass + 1) begin
            if (pass == 1) begin
                @(negedge clk); rewind <= 1'b1; @(negedge clk); rewind <= 1'b0;
                repeat (10) @(posedge clk);
            end
            for (i = 0; i < N; i = i + 1) begin
                get_byte(got);
                if (got !== img[i]) begin
                    if (errors < 6)
                        $display("FAIL: %s byte %0d = %02x, expected %02x",
                                 pass ? "replay" : "first", i, got, img[i]);
                    errors = errors + 1;
                end
            end
            $display("%s: %0d bytes read", pass ? "replay" : "first", rd_count);
        end

        if (errors == 0)
            $display("PASS: DDR3 tape store (301 bytes written, read back, rewound, read again)");
        else
            $display("FAIL: %0d bad bytes", errors);
        $finish;
    end

    initial begin
        #40ms;
        $display("FAIL: watchdog (wr_count=%0d ready=%b rd_count=%0d)",
                 wr_count, img_ready, rd_count);
        $finish;
    end

endmodule

`default_nettype wire
