// ============================================================================
//  zx_tape_mem.v -- a tape image held in DDR3
//
//  The whole .TAP lives in the board's DRAM, so the card is finished with it
//  in a fraction of a second, the deck can hold, rewind and replay without
//  touching the card again, and instant load has the whole image to read from.
//
//  The DDR3 client port (src/zx_ddr.v) is word addressed -- 16-bit words with
//  byte enables -- and takes a one-clock `go` pulse, answering later with a
//  one-clock `ack`; `ddr_idle` says no operation is pending, and a request may
//  only be presented then.
//
//      write   two bytes buffered into one word write (both enables), the odd
//              last byte of an image written alone with the low enable
//      read    a read-ahead FIFO filled a word at a time, its head presented
//              for the player, which pops one byte per tape byte (~855 T)
//
//  Byte n lives in word n>>1, low byte first.
//
//  Three blocks own three disjoint sets of signals -- the write staging, the
//  byte side, and the bus -- which is what keeps this synthesizable as one
//  driver per net.
// ============================================================================
`default_nettype none

module zx_tape_mem (
    input  wire        clk,
    input  wire        reset,
    input  wire        clear,         // forget the image (a new tape)

    // DDR3 client port (zx_ddr)
    output reg         ddr_go,
    output reg  [25:0] ddr_addr,
    output reg         ddr_we,
    output reg  [1:0]  ddr_be,
    output reg  [15:0] ddr_wdata,
    input  wire [15:0] ddr_rdata,
    input  wire        ddr_ack,
    input  wire        ddr_idle,

    // ---- write side: the card fills the image as fast as it can --------
    input  wire        wr_valid,
    input  wire [7:0]  wr_byte,
    output wire        wr_ready,
    output reg  [23:0] wr_count,      // bytes accepted

    // ---- image control --------------------------------------------------
    input  wire [23:0] img_len,       // size in bytes (0: not known yet)
    input  wire        rewind,        // pulse: play from the first byte again
    output reg  [23:0] rd_count,      // bytes handed to the player
    output wire        img_ready,     // the whole image is in DDR3

    // ---- read side: the player -----------------------------------------
    input  wire        rd_pop,        // take the head byte
    output wire [7:0]  rd_byte,
    output wire        rd_empty
);
    localparam [23:0] LIMIT = 24'h80_0000;      // 8 MB of tape is plenty

    // the bus's own state (declared first: every block below reads some of it)
    reg busy    = 1'b0;
    reg wr_op   = 1'b0;
    reg wr_done = 1'b0;
    reg rd_pend = 1'b0;
    reg rd_done = 1'b0;

    // ==================================================================
    // Write staging: two bytes make a word
    // ==================================================================
    reg        w_half  = 1'b0;
    reg [7:0]  w_lo    = 8'h00;
    reg        w_avail = 1'b0;        // a word is ready to be written
    reg [15:0] w_data  = 16'h0000;
    reg [1:0]  w_be    = 2'b11;
    reg [22:0] w_word  = 23'd0;

    assign wr_ready = !w_avail && (wr_count < LIMIT);

    always @(posedge clk) begin
        if (reset || clear) begin
            w_half  <= 1'b0;
            w_avail <= 1'b0;
            wr_count <= 24'd0;
        end else begin
          // a word's write finishing and the next byte arriving can share a
          // clock: as an else-if chain that byte was dropped (every ~10th on
          // hardware, so the tape lost its framing)
          if (wr_done) w_avail <= 1'b0;
          if (wr_valid && wr_ready) begin
            if (!w_half) begin
                w_lo    <= wr_byte;
                w_half  <= 1'b1;
            end else begin
                w_data  <= {wr_byte, w_lo};
                w_be    <= 2'b11;
                w_word  <= wr_count[23:1];
                w_avail <= 1'b1;
                w_half  <= 1'b0;
            end
            wr_count <= wr_count + 24'd1;
        end else if (w_half && !w_avail && (img_len != 24'd0) &&
                     (wr_count == img_len) && img_len[0]) begin
            // an odd-length image: the last byte goes alone, low half only
            w_data  <= {8'h00, w_lo};
            w_be    <= 2'b01;
            w_word  <= wr_count[23:1];
            w_avail <= 1'b1;
            w_half  <= 1'b0;
          end
        end
    end

    // ==================================================================
    // Read-ahead FIFO and the player's side of it
    // ==================================================================
    reg [7:0]  fifo [0:7];
    reg [2:0]  f_rd = 3'd0, f_wr = 3'd0;
    reg [3:0]  f_lvl = 4'd0;
    wire       f_empty = (f_lvl == 4'd0);
    wire       f_full  = (f_lvl == 4'd8);

    reg [22:0] rp      = 23'd0;       // the word to fetch next
    reg        r_want  = 1'b0;        // the FIFO is low: fetch a word
    reg [15:0] r_hold  = 16'h0000;    // the word just read
    reg [1:0]  r_push  = 2'd0;        // bytes of it still to push
    reg        r_phase = 1'b0;        // 0: low byte next, 1: high byte next
    reg        r_skip  = 1'b0;        // a read went out and was rewound under

    wire [23:0] words_total = {1'b0, ((img_len + 24'd1) >> 1)};

    assign img_ready = (img_len != 24'd0) && (wr_count >= img_len);
    assign rd_empty  = f_empty;
    assign rd_byte   = fifo[f_rd];

    always @(posedge clk) begin
        if (reset || clear) begin
            f_rd    <= 3'd0;
            f_wr    <= 3'd0;
            f_lvl   <= 4'd0;
            rp      <= 23'd0;
            r_want  <= 1'b0;
            r_push  <= 2'd0;
            r_skip  <= 1'b0;
            rd_count <= 24'd0;
        end else if (rewind) begin
            rp      <= 23'd0;
            f_rd    <= 3'd0;
            f_wr    <= 3'd0;
            f_lvl   <= 4'd0;
            r_want  <= 1'b0;
            r_push  <= 2'd0;
            rd_count <= 24'd0;
            r_skip  <= r_want | rd_pend;    // whatever was in flight is stale
        end else begin
            // a completed read hands over its word
            if (rd_done) begin
                if (r_skip) begin
                    r_skip <= 1'b0;         // drop it: the head moved under it
                end else begin
                    r_hold  <= ddr_rdata;
                    r_push  <= ((rp + 23'd1) == words_total[22:0] && img_len[0]) ? 2'd1 : 2'd2;
                    r_phase <= 1'b0;
                    rp      <= rp + 23'd1;
                end
            end

            // the player takes the head byte
            if (rd_pop && !f_empty) begin
                f_rd     <= f_rd + 3'd1;
                f_lvl    <= f_lvl - 4'd1;
                rd_count <= rd_count + 24'd1;
            end

            // push the bytes of a completed read
            if ((r_push != 2'd0) && !f_full && !(rd_pop && !f_empty)) begin
                fifo[f_wr] <= r_phase ? r_hold[15:8] : r_hold[7:0];
                f_wr    <= f_wr + 3'd1;
                f_lvl   <= f_lvl + 4'd1;
                r_push  <= r_push - 2'd1;
                r_phase <= !r_phase;
            end

            // ask for the next word when the FIFO runs low
            if ((r_push == 2'd0) && !r_want && !busy && img_ready &&
                (f_lvl <= 4'd4) && (rp < words_total[22:0]))
                r_want <= 1'b1;
            if (r_want && busy && !wr_op)
                r_want <= 1'b0;
        end
    end

    // ==================================================================
    // The bus: one request at a time, writes first
    // ==================================================================

    always @(posedge clk) begin
        ddr_go  <= 1'b0;
        wr_done <= 1'b0;
        rd_done <= 1'b0;

        if (reset) begin
            busy     <= 1'b0;
            ddr_we   <= 1'b0;
            ddr_be   <= 2'b11;
            ddr_addr <= 26'd0;
            ddr_wdata <= 16'd0;
            rd_pend  <= 1'b0;
        end else if (!busy) begin
            if (w_avail && ddr_idle) begin
                ddr_go    <= 1'b1;
                ddr_we    <= 1'b1;
                ddr_be    <= w_be;
                ddr_addr  <= {3'b000, w_word};
                ddr_wdata <= w_data;
                busy      <= 1'b1;
                wr_op     <= 1'b1;
            end else if (r_want && ddr_idle && (rp < words_total[22:0])) begin
                ddr_go    <= 1'b1;
                ddr_we    <= 1'b0;
                ddr_be    <= 2'b11;
                ddr_addr  <= {3'b000, rp};
                busy      <= 1'b1;
                wr_op     <= 1'b0;
                rd_pend   <= 1'b1;
            end
        end else if (ddr_ack) begin
            busy <= 1'b0;
            if (wr_op) wr_done <= 1'b1;
            else begin
                rd_done <= 1'b1;
                rd_pend <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
