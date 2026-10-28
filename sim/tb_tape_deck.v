// ============================================================================
//  tb_tape_deck.v -- the library deck's path, card byte to EAR pulse
//
//  zx_tape_lib's glue, reproduced around the real store and player: the card
//  side offers bytes the way sd_vol does (f_up_go held until f_up_done, then
//  dropped the clock after), img_len arrives first (lib_found), the store
//  fills, and tap_player plays it through rd_hold/rd_pop.  EAR is decoded
//  back into bytes from its half periods and compared with the .TAP's blocks,
//  then the tape is played again the way the deck replays it after its end:
//  a rewind and a start one clock later, before the store has refilled.
//  ce_t ticks every clock and the pilots are short, so it runs in seconds.
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_tape_deck;
    reg clk = 1'b0;
    always #18.519 clk = ~clk;                 // 27 MHz

    reg ddr_memory_clk = 1'b0;
    always #1.2557 ddr_memory_clk = ~ddr_memory_clk;
    reg ddr_lock = 1'b0;

    wire        ready, idle, ack;
    wire [15:0] rdata;
    wire [15:0] DDR3_DQ;
    wire [1:0]  DDR3_DQS, DDR3_DQS_n;
    wire [13:0] DDR3_A;
    wire [2:0]  DDR3_BA;
    wire DDR3_nCS, DDR3_nRAS, DDR3_nCAS, DDR3_nWE, DDR3_CK, DDR3_CK_n,
         DDR3_CKE, DDR3_nRESET, DDR3_ODT;
    wire [1:0] DDR3_DM;

    wire        tm_go, tm_we;
    wire [25:0] tm_addr;
    wire [1:0]  tm_be;
    wire [15:0] tm_wdata;

    zx_ddr u_ddr (
        .clk(clk), .reset(1'b0), .ddr_ref_clk(clk),
        .go(ready ? tm_go : 1'b0), .addr(ready ? tm_addr : 26'd0),
        .we(ready ? tm_we : 1'b0), .be(ready ? tm_be : 2'b11),
        .wdata(ready ? tm_wdata : 16'd0),
        .rdata(rdata), .ack(ack), .idle(idle), .ready(ready),
        .ddr_memory_clk(ddr_memory_clk), .ddr_lock(ddr_lock),
        .DDR3_DQ(DDR3_DQ), .DDR3_DQS(DDR3_DQS), .DDR3_DQS_n(DDR3_DQS_n),
        .DDR3_A(DDR3_A), .DDR3_BA(DDR3_BA), .DDR3_nCS(DDR3_nCS),
        .DDR3_nRAS(DDR3_nRAS), .DDR3_nCAS(DDR3_nCAS), .DDR3_nWE(DDR3_nWE),
        .DDR3_CK(DDR3_CK), .DDR3_CK_n(DDR3_CK_n), .DDR3_CKE(DDR3_CKE),
        .DDR3_nRESET(DDR3_nRESET), .DDR3_ODT(DDR3_ODT), .DDR3_DM(DDR3_DM)
    );

    // ---- the store ---------------------------------------------------------
    reg         reset_tm = 1'b1;
    reg         rewind = 1'b0;
    reg  [23:0] img_len = 24'd0;
    wire        wr_ready, img_ready, rd_empty;
    wire [23:0] wr_count, rd_count;
    wire [7:0]  rd_byte;
    wire        rd_pop;
    reg         wr_take = 1'b0;
    reg  [7:0]  f_up_data = 8'h00;

    zx_tape_mem u_mem (
        .clk(clk), .reset(reset_tm),
        .ddr_go(tm_go), .ddr_addr(tm_addr), .ddr_we(tm_we), .ddr_be(tm_be),
        .ddr_wdata(tm_wdata), .ddr_rdata(rdata), .ddr_ack(ack), .ddr_idle(idle),
        .wr_valid(wr_take), .wr_byte(f_up_data), .wr_ready(wr_ready),
        .wr_count(wr_count), .img_len(img_len), .rewind(rewind),
        .rd_count(rd_count), .img_ready(img_ready), .rd_empty(rd_empty),
        .rd_pop(rd_pop), .rd_byte(rd_byte), .clear(1'b0)
    );

    // ---- zx_tape_lib's write glue, against an sd_vol-shaped offer ----------
    reg f_up_go = 1'b0, f_up_done = 1'b0;
    always @(posedge clk) begin
        wr_take   <= 1'b0;
        f_up_done <= 1'b0;
        if (f_up_go && wr_ready && !f_up_done) begin
            wr_take   <= 1'b1;
            f_up_done <= 1'b1;
        end
    end

    // ---- zx_tape_lib's read glue and the player ----------------------------
    reg        tap_start = 1'b0;
    wire       tap_rd_req, playing, ear, tap_done;
    reg  [7:0] rd_hold = 8'h00;
    assign rd_pop = tap_rd_req && !rd_empty;
    wire tap_eof = (img_len != 24'd0) && (rd_count >= img_len);
    always @(posedge clk) begin
        if (tap_rd_req && tap_eof)        rd_hold <= 8'h00;
        else if (tap_rd_req && !rd_empty) rd_hold <= rd_byte;
    end
    reg ended = 1'b0;
    always @(posedge clk) if (tap_done) ended <= 1'b1;

    tap_player #(.PILOT_HDR(14'd40), .PILOT_DAT(14'd30), .PAUSE_T(22'd2000)) u_player (
        .clk(clk), .reset(reset_tm | rewind), .ce_t(1'b1),
        .start(tap_start), .playing(playing),
        .rd_req(tap_rd_req), .rd_data(rd_hold), .rd_ready(!rd_empty || tap_eof),
        .ear(ear), .done(tap_done)
    );

    // ---- the tape: web/.. HELLO.TAP, a header and a 26-byte program ---------
    localparam integer N = 66;
    reg [7:0] tap [0:N-1];
    initial $readmemh("sim/data/hello_tap.hex", tap);

    // ---- EAR decoder: half periods -> bytes, per block ---------------------
    integer last_edge = 0, now = 0, half = 0;
    reg     have_half = 1'b0;
    integer half1 = 0;
    reg     in_data = 1'b0;
    reg [7:0] sh = 8'h00;
    integer nbits = 0, got_n = 0;
    reg [7:0] got [0:N-1];
    reg ear_q = 1'b1;
    always @(posedge clk) begin
        now = now + 1;
        ear_q <= ear;
        if (ear !== ear_q) begin
            half = now - last_edge;
            last_edge = now;
            if (half > 600 && half < 700) begin        // first sync pulse
                in_data = 1'b0;
            end else if (half > 700 && half < 800) begin   // second sync: data follows
                in_data = 1'b1; have_half = 1'b0; nbits = 0;
            end else if (half > 2000) begin            // pilot
                in_data = 1'b0;
            end else if (in_data) begin
                if (!have_half) begin half1 = half; have_half = 1'b1; end
                else begin
                    have_half = 1'b0;
                    sh = {sh[6:0], (half1 + half) > 2565};   // 2x855 vs 2x1710
                    nbits = nbits + 1;
                    if (nbits == 8) begin
                        if (got_n < N) got[got_n] = sh;
                        got_n = got_n + 1;
                        nbits = 0;
                    end
                end
            end
        end
    end

    integer i, errors = 0, k, pass;

    // the two blocks' payloads (flag..checksum), without the length words
    task check_ear;
        begin
            wait (got_n >= N - 4);
            repeat (5000) @(posedge clk);
            k = 0;
            for (i = 0; i < N; i = i + 1) begin
                if (i == 0 || i == 1 || i == 2 + tap[0] || i == 3 + tap[0]) ; // length words
                else begin
                    if (got[k] !== tap[i]) begin
                        if (errors < 8) $display("FAIL: pass %0d EAR byte %0d = %02x, file byte %0d = %02x", pass, k, got[k], i, tap[i]);
                        errors = errors + 1;
                    end
                    k = k + 1;
                end
            end
            wait (ended || !playing);
            if (!ended) begin $display("FAIL: pass %0d never reached the end of the tape", pass); errors = errors + 1; end
        end
    endtask

    initial begin
        repeat (20) @(posedge clk);
        @(negedge clk); ddr_lock <= 1'b1;
        wait (ready);
        repeat (20) @(posedge clk);
        @(negedge clk); reset_tm <= 1'b0;
        repeat (10) @(posedge clk);

        // lib_found: the length is known before the first byte
        @(negedge clk); img_len <= N;
        for (i = 0; i < N; i = i + 1) begin
            @(negedge clk);
            f_up_go <= 1'b1; f_up_data <= tap[i];
            @(posedge clk); while (!f_up_done) @(posedge clk);
            @(negedge clk); f_up_go <= 1'b0;            // sd_vol drops it the clock after
            repeat (3) @(negedge clk);
        end
        wait (img_ready);
        $display("image in: wr_count=%0d", wr_count);
        if (wr_count != N) begin $display("FAIL: wrote %0d bytes, expected %0d", wr_count, N); $finish; end

        repeat (50) @(posedge clk);
        pass = 1;
        @(negedge clk); tap_start <= 1'b1; @(negedge clk); tap_start <= 1'b0;
        check_ear;

        // play after the end: zx_tape_lib's S_END + play
        pass = 2;
        repeat (100) @(posedge clk);
        @(negedge clk); got_n = 0; ended <= 1'b0; rewind <= 1'b1;
        @(negedge clk); rewind <= 1'b0; tap_start <= 1'b1;
        @(negedge clk); tap_start <= 1'b0;
        check_ear;
        if (errors == 0) $display("PASS: library deck path (66-byte .TAP, card -> DDR3 -> player -> EAR, decoded intact, end of tape, replayed)");
        else             $display("FAIL: %0d bad bytes on EAR", errors);
        $finish;
    end

    initial begin
        #160ms;
        $display("FAIL: watchdog (wr_count=%0d img_ready=%b rd_count=%0d got=%0d w_avail=%b w_half=%b busy=%b idle=%b f_up_go=%b wr_ready=%b i=%0d)",
                 wr_count, img_ready, rd_count, got_n, u_mem.w_avail, u_mem.w_half, u_mem.busy, idle, f_up_go, wr_ready, i);
        $finish;
    end
endmodule

`default_nettype wire
