// ============================================================================
//  tb_tape.v -- the .TAP player's pulse train
//
//  Feeds it a two-block TAP (a header block carrying 0xA5 0x5A, then an empty
//  block that ends the file) and prints every EAR half-period in 3.5 MHz
//  T-states.  The pilot count is shortened (8063 would be 5 s of simulation);
//  the *lengths* are the real ones and are what the ROM's loader times:
//
//      pilot 2168, sync 667 then 735, bit 1 = 1710, bit 0 = 855, two per bit
//
//  The expected sequence for 0xA5 (1 0 1 0 0 1 0 1) is checked at the end.
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_tape;
    reg clk = 1'b0;
    always #18.518 clk = ~clk;

    // 3.5 MHz T-state tick, the same 7/54 accumulator the FPGA uses
    reg [5:0] acc = 6'd0;
    reg       ce  = 1'b0;
    always @(posedge clk) begin
        if (acc + 6'd7 >= 6'd54) begin acc <= acc + 6'd7 - 6'd54; ce <= 1'b1; end
        else begin acc <= acc + 6'd7; ce <= 1'b0; end
    end

    reg start = 1'b0;
    reg rst = 1'b1;
    wire playing, ear, done, sector_done, rd_req;
    wire [9:0] idx;
    wire [7:0] rd_data;

    // the TAP file: len=4 header block (flag 0x00, A5, 5A, crc), then len=0
    reg [7:0] tap [0:15];
    initial begin
        tap[0] = 8'h04; tap[1] = 8'h00;      // block length = 4
        tap[2] = 8'h00;                      // flag: header (short pilot)
        tap[3] = 8'hA5; tap[4] = 8'h5A;      // data
        tap[5] = 8'h00;                      // checksum (the player skips it)
        tap[6] = 8'h00; tap[7] = 8'h00;      // next block: length 0 -> end
    end

    // byte source: the player's idx picks the byte, one clock later
    reg [7:0] rd_q = 8'h00;
    always @(posedge clk) if (rd_req) rd_q <= tap[idx[3:0]];
    assign rd_data = rd_q;

    tap_player #(
        .PILOT_HDR(14'd8),
        .PILOT_DAT(14'd8),
        .PAUSE_T(22'd2000)
    ) u_player (
        .clk(clk), .reset(rst), .ce_t(ce),
        .start(start), .playing(playing),
        .idx(idx), .rd_req(rd_req), .rd_data(rd_data),
        .buf_ready(1'b1), .sector_done(sector_done),
        .ear(ear), .done(done)
    );


    // +probe: dump the sequencer's first steps (development aid)
    integer pc = 0;
    always @(posedge clk) begin
        if ($test$plusargs("probe") && pc < 60) begin
            pc <= pc + 1;
            $display("t=%0t st=%0d idx=%0d fw=%b hb=%b fst=%0d pbusy=%b ear=%b",
                     $time, u_player.st, idx, u_player.fetch_want,
                     u_player.have_byte, u_player.fstate, u_player.pbusy, ear);
        end
    end

    // ---- measure the half periods -------------------------------------
    integer tcount = 0;
    integer npulse = 0;
    reg     ear_q = 1'b1;
    integer got [0:63];

    always @(posedge clk) begin
        if (ce) begin
            tcount <= tcount + 1;
            if (ear !== ear_q) begin
                ear_q <= ear;
                got[npulse] <= tcount;
                npulse <= npulse + 1;
                tcount <= 0;
            end
        end
    end

    integer i, errors = 0;
    integer exp [0:41];
    initial begin
        // PILOT_HDR counts *half periods*: 8 of 2168, then sync, then the
        // data byte's 16 halves (2 per bit, MSB first)
        for (i = 0; i < 8; i = i + 1) exp[i] = 2168;
        exp[8] = 667;
        exp[9] = 735;
        // the flag (0x00) is the first byte LD-BYTES reads, then 0xA5
        for (i = 0; i < 16; i = i + 1) begin
            exp[10 + i*2]     = (16'h00A5 >> (15 - i)) & 1 ? 1710 : 855;
            exp[10 + i*2 + 1] = exp[10 + i*2];
        end

        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (10) @(posedge clk);
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;

        wait (npulse >= 42);
        repeat (50) @(posedge clk);

        // The pulse generator quantises to T-states, so allow a tick either
        // way -- a real cassette is percents out, not 0.1%.
        for (i = 0; i < 42; i = i + 1) begin
            if (got[i] > exp[i] + 4 || got[i] < exp[i] - 4) begin
                $display("FAIL: half %0d = %0d T, expected %0d", i, got[i], exp[i]);
                errors = errors + 1;
            end
        end
        if (errors == 0)
            $display("PASS: tape pulse train and byte order (pilot 2168, sync 667/735, bits 855/1710, MSB first)");
        else
            $display("FAIL: %0d of 42 half-periods wrong", errors);
        $finish;
    end

    initial begin
        #50ms;
        $display("FAIL: watchdog (npulse=%0d)", npulse);
        $finish;
    end

endmodule

`default_nettype wire
