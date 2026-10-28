// ============================================================================
//  zx_scr_cap.v -- Screen capture dumper over UART
//
//  When triggered by cap_req:
//    1. Raises `capturing`: zx_core stops the CPU's enable and gives this
//       module the RAM's read port.
//    2. Sends frame header: 0xF5 (SCR_FRAME).
//    3. Sends status byte: {4'd0, flash, border[2:0]}.
//    4. Streams all 6912 bytes of screen memory (6144 bitmap + 768 attributes)
//       from RAM addresses 16'd0 .. 16'd6911 (corresponding to CPU 0x4000..0x5AFF).
//       Prefetches each byte while UART TX transmits the previous byte, so
//       transmission runs at the full 1 Mbps wire rate without idle bubbles.
//       Respects vid_busy (vid_x < 64) so video HDMI prefetch is never disturbed.
//    5. Drops `capturing` once all bytes are sent.
// ============================================================================

`default_nettype none

module zx_scr_cap #(
    parameter integer SCR_BYTES = 6912
) (
    input  wire        clk,        // 27 MHz pixel clock
    input  wire        reset,      // active high
    input  wire        cap_req,    // 1-clock pulse to start capture

    input  wire [2:0]  border,     // current ULA border color (0..7)
    input  wire        flash,      // current flash phase (0 or 1)
    input  wire        vid_busy,   // 1 when video owns RAM (vid_x < 64)

    // RAM read port
    output reg  [15:0] ram_addr = 16'd0,
    input  wire [7:0]  ram_rdata,

    output reg         capturing = 1'b0,  // 1 while screen capture is in progress

    // UART TX interface
    output reg         tx_req = 1'b0,
    output reg  [7:0]  tx_data = 8'h00,
    input  wire        tx_busy
);

    localparam [2:0] S_IDLE     = 3'd0,
                     S_SEND_HDR = 3'd1,
                     S_SEND_ST  = 3'd2,
                     S_STREAM   = 3'd3,
                     S_FINISH   = 3'd4;

    reg [2:0]  state = S_IDLE;
    reg [12:0] byte_idx = 13'd0;    // 0 .. 6911
    reg [7:0]  prefetched = 8'h00;
    reg        have_next = 1'b0;
    reg [1:0]  rd_cnt = 2'd0;
    reg [2:0]  border_q = 3'd0;
    reg        flash_q = 1'b0;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state      <= S_IDLE;
            capturing  <= 1'b0;
            tx_req     <= 1'b0;
            tx_data    <= 8'h00;
            ram_addr   <= 16'd0;
            byte_idx   <= 13'd0;
            prefetched <= 8'h00;
            have_next  <= 1'b0;
            rd_cnt     <= 2'd0;
            border_q   <= 3'd0;
            flash_q    <= 1'b0;
        end else begin
            tx_req <= 1'b0;

            case (state)
                S_IDLE: begin
                    capturing <= 1'b0;
                    have_next <= 1'b0;
                    rd_cnt    <= 2'd0;
                    byte_idx  <= 13'd0;
                    if (cap_req) begin
                        capturing <= 1'b1;
                        border_q  <= border;
                        flash_q   <= flash;
                        state     <= S_SEND_HDR;
                    end
                end

                S_SEND_HDR: begin
                    if (!tx_busy) begin
                        tx_data <= 8'hF5;    // SCR_FRAME leader
                        tx_req  <= 1'b1;
                        state   <= S_SEND_ST;
                    end
                end

                S_SEND_ST: begin
                    // Send status byte once HDR starts transmitting
                    if (!tx_busy && !tx_req) begin
                        tx_data   <= {4'd0, flash_q, border_q};
                        tx_req    <= 1'b1;
                        byte_idx  <= 13'd0;
                        have_next <= 1'b0;
                        rd_cnt    <= 2'd0;
                        state     <= S_STREAM;
                    end
                end

                S_STREAM: begin
                    // If UART is free and we have prefetched the current byte, start transmission
                    if (!tx_busy && !tx_req && have_next) begin
                        tx_data   <= prefetched;
                        tx_req    <= 1'b1;
                        have_next <= 1'b0;
                        rd_cnt    <= 2'd0;

                        if (byte_idx == SCR_BYTES - 1) begin
                            state <= S_FINISH;
                        end else begin
                            byte_idx <= byte_idx + 13'd1;
                        end
                    end

                    // While UART TX is busy with the current byte, prefetch the
                    // next from RAM: address, the registered read, then the
                    // byte (3 clocks, none of them in the video's window)
                    if (!have_next) begin
                        case (rd_cnt)
                            2'd0: if (!vid_busy) begin ram_addr <= {3'd0, byte_idx}; rd_cnt <= 2'd1; end
                            2'd1: if (!vid_busy) rd_cnt <= 2'd2;
                            2'd2: if (!vid_busy) begin
                                prefetched <= ram_rdata;
                                have_next  <= 1'b1;
                                rd_cnt     <= 2'd0;
                            end
                            default: rd_cnt <= 2'd0;
                        endcase
                    end
                end

                S_FINISH: begin
                    // Wait for the final byte to clear the UART shifter
                    if (!tx_busy && !tx_req) begin
                        capturing <= 1'b0;
                        state     <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
