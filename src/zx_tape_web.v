// ============================================================================
//  zx_tape_web.v -- a virtual cassette deck fed from the web page
//
//  The page reads a .TAP file the user picks and pushes it down the same
//  1 Mbps UART the keyboard uses, two bytes at a time:
//
//      host -> FPGA   0xFD <byte>        one tape byte
//      FPGA -> host   0x06               "credit": send me another
//
//  Credits are demand-driven: the board asks only while `level + pending` is
//  below IN_FLIGHT, where `pending` counts credits it has sent and not yet been
//  answered.  Without that count it would ask at UART speed and the page would
//  overrun the FIFO.
//
//  The tape player sets the pace (one byte per ~855 T-states), so a whole .TAP
//  trickles in at cassette speed with nothing buffered in bulk.  The file's
//  first byte starts the tape, which is the cassette's PLAY: then type
//  LOAD "" inside the leader tone (the page does it for you).
//
//  0xFD collides with nothing in the keyboard protocol (0xFE key, 0xFF all-up,
//  anything else a printable ASCII keystroke) and 0x06 is not a banner byte.
// ============================================================================
`default_nettype none

module zx_tape_web (
    input  wire        clk,           // 27 MHz (clk_pixel)
    input  wire        reset,
    input  wire        ce_cpu,        // 3.5 MHz T-state tick
    input  wire        tape_load,     // pulse: the ROM entered LD-BYTES
    input  wire        auto_play,     // DIP5: roll without waiting

    input  wire        tape_valid,    // from zx_input: one byte of the .TAP
    input  wire [7:0]  tape_byte,

    output wire        tx_req,        // to the UART transmitter: credit byte
    output wire [7:0]  tx_data,
    input  wire        tx_busy,

    output wire        ear,           // into the ULA's port 0xFE bit 6
    output wire        playing,
    output wire        loaded         // a tape byte has arrived
);
    localparam [7:0] IN_FLIGHT = 8'd16;   // bytes allowed on the wire at once

    // ---- the FIFO -----------------------------------------------------
    reg [7:0]  fifo [0:127];
    reg [6:0]  f_rd = 7'd0, f_wr = 7'd0;
    reg [7:0]  level = 8'd0;
    reg [7:0]  pending = 8'd0;        // credits out, answers not in yet
    wire       empty = (level == 8'd0);
    wire       full  = (level == 8'd128);

    // the deck is on hold until LOAD "" runs (or DIP5 says roll now)
    reg load_seen = 1'b0;
    always @(posedge clk) begin
        if (reset)          load_seen <= 1'b0;
        else if (tape_load) load_seen <= 1'b1;
    end
    wire start_ok = auto_play | load_seen;

    wire       credit = start_ok && !tx_busy && ((level + pending) < IN_FLIGHT);
    assign tx_req  = credit;
    assign tx_data = 8'h06;

    // ---- the player ---------------------------------------------------
    reg  [7:0] rd_hold = 8'h00;
    reg        start_pulse = 1'b0;
    reg        been_loaded = 1'b0;
    wire       rd_req;
    wire [9:0] idx;
    wire       sector_done;

    always @(posedge clk) begin
        start_pulse <= 1'b0;
        if (reset) begin
            f_rd <= 7'd0;
            f_wr <= 7'd0;
            level <= 8'd0;
            pending <= 8'd0;
            been_loaded <= 1'b0;
        end else begin
            // host -> FIFO.  One byte per credit, so a drop should never
            // happen; the guard is only there to keep the FIFO consistent.
            if (tape_valid && !full) begin
                fifo[f_wr] <= tape_byte;
                f_wr  <= f_wr + 7'd1;
                level <= level + 8'd1;
            end

            // player takes a byte
            if (rd_req && !empty) begin
                rd_hold <= fifo[f_rd];
                f_rd    <= f_rd + 7'd1;
                level   <= level - 8'd1;
            end

            // the credits outstanding: +1 sent, -1 answered (net 0 if both)
            if (credit && !tape_valid)
                pending <= pending + 8'd1;
            else if (!credit && tape_valid && pending != 8'd0)
                pending <= pending - 8'd1;

            // cassette PLAY: the first byte of a file starts the tape
            if (tape_valid && !been_loaded) begin
                been_loaded <= 1'b1;
                start_pulse <= 1'b1;
            end else if (tape_valid && !playing && level == 8'd0) begin
                start_pulse <= 1'b1;              // a second file: play it too
            end
        end
    end

    tap_player u_player (
        .clk(clk), .reset(reset), .ce_t(ce_cpu),
        .start(start_pulse), .playing(playing),
        .idx(idx), .rd_req(rd_req), .rd_data(rd_hold),
        .buf_ready(!empty), .sector_done(sector_done),
        .ear(ear), .done()
    );

    assign loaded = been_loaded;

endmodule

`default_nettype wire
