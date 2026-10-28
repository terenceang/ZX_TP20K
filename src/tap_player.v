// ============================================================================
//  tap_player.v -- a .TAP file played into the ULA's EAR bit
//
//  The 48K ROM's LOAD/VERIFY read port 0xFE bit 6 and time the edges.  This
//  emits the pulses a cassette would, from the TAP file's own block structure:
//
//      [len_lo len_hi] [flag data.. checksum]     (len counts flag+data+crc)
//
//      pilot   2168 T per pulse, 8063 pulses for a header (flag < 0x80)
//                                3223 for data (flag >= 0x80)
//      sync    667 T, then 735 T
//      bits    2 pulses per bit, 855 T for 0, 1710 T for 1, MSB first
//      pause   1000 ms
//
//  One T-state is one ce_t tick (3.5 MHz), so those are the real numbers.
//
//  Two blocks, each owning its own registers (a register written from two
//  always blocks is one of the ways to make a synthesiser guess):
//
//    * the byte fetcher owns rd_req, fetched, have_byte and the two-clock
//      request/latch handshake; the sequencer asks with fetch_want and
//      answers with byte_taken.
//    * the sequencer owns the TAP walk and the pulse generator.
// ============================================================================
`default_nettype none

module tap_player #(
    // Real TAP numbers.  The testbench shortens the counts, never the lengths.
    parameter [13:0] PILOT_HDR = 14'd8063,
    parameter [13:0] PILOT_DAT = 14'd3223,
    parameter [21:0] PAUSE_T   = 22'd3_500_000
) (
    input  wire       clk,
    input  wire       reset,
    input  wire       ce_t,           // 3.5 MHz T-state tick

    input  wire       start,          // pulse: begin at the top of the file
    output reg        playing = 1'b0,

    // the tape's next byte: rd_req takes it, rd_data has it two clocks later
    output reg        rd_req = 1'b0,
    input  wire [7:0] rd_data,
    input  wire       rd_ready,       // a byte is there to take

    output reg        ear = 1'b1,
    output reg        done = 1'b0
);
    localparam [3:0] S_IDLE  = 4'd0,
                     S_LEN0  = 4'd1,
                     S_LEN1  = 4'd2,
                     S_FLAG  = 4'd3,
                     S_PILOT = 4'd4,
                     S_SYNC1 = 4'd5,
                     S_SYNC2 = 4'd6,
                     S_NEXT  = 4'd7,
                     S_GET   = 4'd8,
                     S_BITS  = 4'd9,
                     S_PAUSE = 4'd10,
                     S_END   = 4'd11;

    reg [3:0]  st = S_IDLE;
    reg [7:0]  len_lo = 8'd0;
    reg [15:0] block_len = 16'd0;
    reg [15:0] bytes_left = 16'd0;
    reg [7:0]  cur_byte = 8'd0;
    reg [3:0]  bitn = 4'd0;
    reg        fetch_want = 1'b0;
    reg        byte_taken = 1'b0;

    // ---- byte fetcher: owns the request and the received byte ----------
    reg        have_byte = 1'b0;
    reg [7:0]  fetched = 8'd0;
    reg [1:0]  fstate = 2'd0;

    always @(posedge clk) begin
        rd_req <= 1'b0;
        if (reset) begin
            fstate <= 2'd0;
            have_byte <= 1'b0;
        end else if (byte_taken) begin
            have_byte <= 1'b0;
        end else if (fetch_want && !have_byte) begin
            if (fstate == 2'd0) begin
                // a request with nothing there would latch a stale byte (a
                // replay starts a clock after the rewind, before the store
                // has refilled)
                if (rd_ready) begin
                    rd_req <= 1'b1;
                    fstate <= 2'd1;
                end
            end else if (fstate == 2'd1) begin
                fstate <= 2'd2;            // the buffer registers the byte
            end else begin
                fetched <= rd_data;        // and it is here now
                have_byte <= 1'b1;
                fstate <= 2'd0;
            end
        end else
            fstate <= 2'd0;
    end

    // ---- pulse generator ----------------------------------------------
    reg [11:0] plen = 12'd0;          // T-states per half period
    reg [13:0] pcnt = 14'd0;          // pulses left
    reg        pbusy = 1'b0;
    reg [11:0] tcnt = 12'd0;

    // ---- 1 s pause, in T-states ---------------------------------------
    reg [21:0] pause_cnt = 22'd0;

    // ---- sequencer ----------------------------------------------------
    always @(posedge clk) begin
        byte_taken <= 1'b0;
        if (reset) begin
            st <= S_IDLE;
            playing <= 1'b0;
            done <= 1'b0;
            ear <= 1'b1;
            pbusy <= 1'b0;
            fetch_want <= 1'b0;
            bytes_left <= 16'd0;
        end else begin
            done <= 1'b0;

            // one half period every plen T-states, toggling EAR
            if (pbusy && ce_t) begin
                if (tcnt <= 12'd1) begin
                    ear <= ~ear;
                    tcnt <= plen;
                    if (pcnt <= 14'd1) pbusy <= 1'b0;
                    else pcnt <= pcnt - 14'd1;
                end else
                    tcnt <= tcnt - 12'd1;
            end

            case (st)
            S_IDLE: if (start) begin
                playing <= 1'b1;
                fetch_want <= 1'b1;
                st <= S_LEN0;
            end

            S_LEN0: if (have_byte && !byte_taken) begin
                len_lo <= fetched;
                byte_taken <= 1'b1;
                st <= S_LEN1;
            end

            S_LEN1: if (have_byte && !byte_taken) begin
                byte_taken <= 1'b1;
                block_len <= {fetched, len_lo};
                if (fetched == 8'h00 && len_lo == 8'h00)
                    st <= S_END;                       // len 0: end of file
                else
                    st <= S_FLAG;
            end

            S_FLAG: if (have_byte && !byte_taken) begin
                byte_taken <= 1'b1;
                fetch_want <= 1'b0;
                cur_byte   <= fetched;                 // the flag goes out first:
                bytes_left <= block_len;               // LD-BYTES reads it as byte 0
                plen  <= 12'd2168;
                tcnt  <= 12'd2168;
                pcnt  <= (fetched < 8'h80) ? PILOT_HDR : PILOT_DAT;
                pbusy <= 1'b1;
                st <= S_PILOT;
            end

            S_PILOT: if (!pbusy) begin
                plen <= 12'd667; tcnt <= 12'd667; pcnt <= 14'd1; pbusy <= 1'b1;
                st <= S_SYNC1;
            end

            S_SYNC1: if (!pbusy) begin
                plen <= 12'd735; tcnt <= 12'd735; pcnt <= 14'd1; pbusy <= 1'b1;
                st <= S_SYNC2;
            end

            S_SYNC2: if (!pbusy) begin
                bitn <= 4'd8;
                st <= S_BITS;
            end

            S_NEXT: if (bytes_left == 16'd0) st <= S_PAUSE;
                    else begin fetch_want <= 1'b1; st <= S_GET; end

            S_GET: if (have_byte && !byte_taken) begin
                cur_byte <= fetched;
                byte_taken <= 1'b1;
                fetch_want <= 1'b0;
                bitn <= 4'd8;
                st <= S_BITS;
            end

            S_BITS: if (!pbusy) begin
                if (bitn == 4'd0) begin
                    bytes_left <= bytes_left - 16'd1;
                    st <= S_NEXT;
                end else begin
                    plen <= cur_byte[7] ? 12'd1710 : 12'd855;
                    tcnt <= cur_byte[7] ? 12'd1710 : 12'd855;
                    pcnt <= 14'd2;
                    pbusy <= 1'b1;
                    cur_byte <= {cur_byte[6:0], 1'b0};
                    bitn <= bitn - 4'd1;
                end
            end

            S_PAUSE: begin
                if (pause_cnt == 22'd0) begin
                    pause_cnt <= PAUSE_T;
                    fetch_want <= 1'b1;
                    st <= S_LEN0;
                end else if (ce_t)
                    pause_cnt <= pause_cnt - 22'd1;
            end

            S_END: begin
                playing <= 1'b0;
                ear <= 1'b1;
                done <= 1'b1;
                fetch_want <= 1'b0;
                st <= S_IDLE;
            end

            default: st <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
