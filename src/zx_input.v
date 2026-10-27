// ============================================================================
//  zx_input.v -- the web keyboard's end of the UART
//
//  Host-to-Spectrum protocol (web/src/protocol.js is the other end), all at
//  1 Mbps 8N1 (27 clocks per bit, exact):
//
//    0xFE <pos> <down>   one key event: <pos> = ZX matrix position, row*5+col
//                        (0..39, row 0 is the CAPS SHIFT row), <down> bit0 =
//                        pressed.  Every key -- CAPS SHIFT and SYMBOL SHIFT
//                        included -- is an ordinary key, so a chord like
//                        SYMBOL SHIFT+P for '"' is just two held keys.
//    0xFF 0x04           all keys up (the page sends it on blur/tab-out).
//
//  The board does no translation: it only opens and closes membrane
//  contacts, exactly like the real keyboard.  What a key or chord *types*
//  is the sender's business -- the page's typist is web/src/zxkeys.js.
//
//  The web keys latch: down sets the bit, up clears it, so the ROM sees a
//  real key hold no matter how fast the packets arrive.  Hold and gap timing
//  (the ROM scans at 50 Hz and needs a key stable across a frame or two) is
//  the sender's pacing problem: typeText() holds each chord ~45 ms and gaps
//  ~35 ms.
//
//  The ULA reads the keyboard by driving one row of the 8x5 matrix low and
//  reading five columns; pressed keys read 0.  This module supplies the
//  virtual keys as a 40-bit pressed-map that zx_core ORs into the read.
// ============================================================================

`default_nettype none
`include "src/uart_defs.vh"

module zx_input (
    input  wire        clk,        // 27 MHz (clk_pixel)
    input  wire        reset,
    input  wire        uart_rx,

    output wire [39:0] vk_matrix,  // 8 rows x 5 cols, 1 = key pressed
    output wire        key_hit,    // a byte landed (diagnostic)

    // the tape library's commands: 0xFB <sub> [idx]
    output reg         lib_list,     // 'L'  send the card's library
    output reg         lib_sel,      // 'S'  <idx> follows
    output reg  [4:0]  lib_idx,
    output reg         lib_eject,    // 'C'
    output reg         lib_play,     // 'P'
    output reg         lib_pause,    // 'H'  hold: pause / resume
    output reg         lib_rewind,   // 'R'  back to the start, stopped
    output reg         cmd_instant,  // 'I'  <off le24>: arm the trap at that byte
    output reg  [23:0] inst_off = 24'd0,
    output reg         cmd_version,  // 'V'  query version
    output reg         tape_mon = 1'b0, // 'A' on / 'a' off: tape audio to HDMI

    // Screen capture trigger: 0xFA or 0xFF 0x05
    output reg         scr_req = 1'b0,

    // Raw UART stream for SD card bridge
    input  wire        card_mode,
    input  wire        hold,         // zx_snap is inside a packet: not ours
    output wire [7:0]  rx_byte_out,
    output wire        rx_valid_out
);

    localparam [8:0] CLKS_PER_BIT = `UART_CLKS_PER_BIT;
    localparam [8:0] HALF_BIT     = `UART_CLKS_HALF_BIT;

    // =====================================================================
    // UART RX, 1 Mbps 8N1
    // =====================================================================
    reg [2:0] rx_sync = 3'b111;
    always @(posedge clk) rx_sync <= {rx_sync[1:0], uart_rx};
    wire rx_bit = rx_sync[2];

    localparam URX_IDLE = 2'd0, URX_START = 2'd1, URX_DATA = 2'd2, URX_STOP = 2'd3;
    reg [1:0] urx_state = URX_IDLE;
    reg [8:0] urx_cnt   = 9'd0;
    reg [2:0] urx_idx   = 3'd0;
    reg [7:0] urx_byte  = 8'd0;
    reg       urx_valid = 1'b0;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            urx_state <= URX_IDLE;
            urx_cnt   <= 9'd0;
            urx_idx   <= 3'd0;
            urx_byte  <= 8'd0;
            urx_valid <= 1'b0;
        end else begin
            urx_valid <= 1'b0;
            case (urx_state)
                URX_IDLE:
                    if (!rx_bit) begin              // start bit edge
                        urx_cnt   <= 9'd0;
                        urx_state <= URX_START;
                    end
                URX_START:
                    if (urx_cnt == HALF_BIT) begin
                        if (!rx_bit) begin          // confirmed start bit
                            urx_cnt   <= 9'd0;
                            urx_idx   <= 3'd0;
                            urx_state <= URX_DATA;
                        end else                    // glitch
                            urx_state <= URX_IDLE;
                    end else urx_cnt <= urx_cnt + 9'd1;
                URX_DATA:
                    if (urx_cnt == CLKS_PER_BIT - 9'd1) begin
                        urx_cnt  <= 9'd0;
                        urx_byte <= {rx_bit, urx_byte[7:1]};  // LSB first
                        if (urx_idx == 3'd7) urx_state <= URX_STOP;
                        else urx_idx <= urx_idx + 3'd1;
                    end else urx_cnt <= urx_cnt + 9'd1;
                URX_STOP:
                    if (urx_cnt == CLKS_PER_BIT - 9'd1) begin
                        urx_valid <= rx_bit;        // framing: stop must be 1
                        urx_state <= URX_IDLE;
                    end else urx_cnt <= urx_cnt + 9'd1;
                default: urx_state <= URX_IDLE;
            endcase
        end
    end

    // =====================================================================
    // Keys: one always block owns everything below the UART
    // =====================================================================
    // Parser states.  PK_KEY_POS expects the FE packet's position byte,
    // PK_KEY_DOWN its down byte, PK_FF the FF packet's kind byte.
    localparam [2:0] PK_NONE = 3'd0, PK_KEY_POS = 3'd1, PK_KEY_DOWN = 3'd2,
                     PK_FF = 3'd3, PK_LIB = 3'd4, PK_LIB_IDX = 3'd5,
                     PK_INST = 3'd6;

    reg [2:0]  pk        = PK_NONE;
    reg [1:0]  inst_n    = 2'd0;     // offset bytes still to come
    reg        have_pos  = 1'b0;
    reg [5:0]  pos_q     = 6'd0;
    reg [39:0] web_matrix = 40'd0;   // latched web keys

    wire       rx_valid = urx_valid;
    wire [7:0] rx_byte  = urx_byte;

    assign rx_byte_out  = urx_byte;
    assign rx_valid_out = urx_valid;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            pk          <= PK_NONE;
            lib_list    <= 1'b0;
            lib_sel     <= 1'b0;
            lib_eject   <= 1'b0;
            lib_play    <= 1'b0;
            lib_pause   <= 1'b0;
            lib_rewind  <= 1'b0;
            cmd_instant <= 1'b0;
            cmd_version <= 1'b0;
            scr_req     <= 1'b0;
            lib_idx     <= 5'd0;
            have_pos    <= 1'b0;
            web_matrix  <= 40'd0;
        end else begin
            lib_list    <= 1'b0;
            lib_sel     <= 1'b0;
            lib_eject   <= 1'b0;
            lib_play    <= 1'b0;
            lib_pause   <= 1'b0;
            lib_rewind  <= 1'b0;
            cmd_instant <= 1'b0;
            cmd_version <= 1'b0;
            scr_req     <= 1'b0;
            // ---- a byte from the host ------------------------------------
            if (rx_valid && card_mode !== 1'b1 && !hold) begin
                case (pk)
                    PK_NONE: begin
                        if (rx_byte == 8'hFE)       pk <= PK_KEY_POS;
                        else if (rx_byte == 8'hFF)  pk <= PK_FF;
                        else if (rx_byte == 8'hFB)  pk <= PK_LIB;
                        else if (rx_byte == 8'hFA)  scr_req <= 1'b1;
                    end
                    // Both blocks below read `pk` before this edge, so the
                    // position byte is still visible here as pk transitions.
                    PK_KEY_POS: begin
                        if (rx_byte < 8'd40) begin
                            pos_q    <= rx_byte[5:0];
                            have_pos <= 1'b1;
                        end
                        pk <= PK_KEY_DOWN;
                    end
                    PK_KEY_DOWN: begin
                        if (have_pos) begin
                            if (rx_byte[0]) web_matrix[pos_q] <= 1'b1;
                            else             web_matrix[pos_q] <= 1'b0;
                        end
                        have_pos <= 1'b0;
                        pk       <= PK_NONE;
                    end
                    PK_LIB: begin
                        // 0xFB 'L' list, 'S' <idx> select, 'C' eject, 'P' play,
                        // 'H' pause/resume, 'R' rewind, 'I' instant, 'A'/'a'
                        // tape audio on/off (tape_mon, below)
                        case (rx_byte)
                            8'h4C: lib_list    <= 1'b1;
                            8'h53: pk <= PK_LIB_IDX;
                            8'h43: lib_eject   <= 1'b1;
                            8'h50: lib_play    <= 1'b1;
                            8'h48: lib_pause   <= 1'b1;   // 'H'
                            8'h52: lib_rewind  <= 1'b1;   // 'R'
                            8'h49: begin pk <= PK_INST; inst_n <= 2'd2; end   // 'I'
                            8'h56: cmd_version <= 1'b1;   // 'V'
                            default: ;
                        endcase
                        if (rx_byte != 8'h53 && rx_byte != 8'h49) pk <= PK_NONE;
                    end
                    PK_INST: begin               // low byte first
                        inst_off <= {rx_byte, inst_off[23:8]};
                        inst_n   <= inst_n - 2'd1;
                        if (inst_n == 2'd0) begin
                            cmd_instant <= 1'b1;
                            pk          <= PK_NONE;
                        end
                    end
                    PK_LIB_IDX: begin
                        lib_idx <= rx_byte[4:0];
                        lib_sel <= 1'b1;
                        pk <= PK_NONE;
                    end
                    PK_FF: begin
                        if (rx_byte == 8'h04) web_matrix <= 40'd0;
                        else if (rx_byte == 8'h05) scr_req <= 1'b1;
                        pk <= PK_NONE;
                    end
                    default: pk <= PK_NONE;
                endcase
            end
        end
    end

    // The page's monitor switch: kept across S0 resets, like a deck's knob.
    always @(posedge clk)
        if (rx_valid && card_mode !== 1'b1 && !hold && pk == PK_LIB && (rx_byte | 8'h20) == 8'h61)
            tape_mon <= ~rx_byte[5];

    assign vk_matrix = web_matrix;
    assign key_hit   = urx_valid;

endmodule

`default_nettype wire
