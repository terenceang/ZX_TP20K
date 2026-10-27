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
//    anything else       a single ASCII keystroke from a dumb terminal: the
//                        FPGA maps it to a matrix press (CAPS SHIFT for upper
//                        case, SYMBOL SHIFT for the red legends) and holds it
//                        long enough for the ROM's 50 Hz keyboard scan.
//
//  0xFE is a packet leader, so a terminal that sends a raw 0xFE starts a key
//  packet instead of typing anything; the page's paste box has the same rule.
//
//  The web keys latch: down sets the bit, up clears it, so the ROM sees a
//  real key hold no matter how fast the packets arrive.  The ASCII fallback
//  uses a hold timer instead (40 ms down, 30 ms up) and replaces a still-held
//  key, because a terminal has no release events.
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
    output reg         cmd_instant,  // 'I'  instant load
    output reg         cmd_version,  // 'V'  query version

    // Screen capture trigger: 0xFA or 0xFF 0x05
    output reg         scr_req = 1'b0,

    // Raw UART stream for SD card bridge
    input  wire        card_mode,
    input  wire        snap_busy,
    output wire [7:0]  rx_byte_out,
    output wire        rx_valid_out,

    // "type LOAD \"\" and press ENTER" -- a pulse here makes the board type
    // the command itself, through exactly the path a terminal uses
    input  wire        type_go
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
                     PK_FF = 3'd3, PK_LIB = 3'd4, PK_LIB_IDX = 3'd5;
    // ASCII fallback hold states
    localparam AH_IDLE = 2'd0, AH_DOWN = 2'd1, AH_UP = 2'd2;

    // 40 ms down / 30 ms up at 27 MHz -- the ROM scans the keyboard at 50 Hz,
    // so a key must span at least a frame or two to be seen.
    localparam [23:0] HOLD_DOWN = 24'd1_080_000, HOLD_UP = 24'd810_000;

    reg [2:0]  pk        = PK_NONE;
    reg        have_pos  = 1'b0;
    reg [5:0]  pos_q     = 6'd0;
    reg [39:0] web_matrix = 40'd0;   // latched web keys
    reg [39:0] ah_matrix  = 40'd0;   // the ASCII fallback's one held key
    reg [1:0]  ah_state   = AH_IDLE;
    reg [23:0] ah_cnt     = 24'd0;

    // ------------------------------------------------------------------
    // The built-in typer: LOAD "" + ENTER, one ASCII key every 100 ms (the
    // fallback holds each key 40 ms then releases it for 30 ms).
    // ------------------------------------------------------------------
    localparam [23:0] TYPE_GAP = 24'd2_700_000;      // 100 ms at 27 MHz

    reg        ty_run  = 1'b0;
    reg        ty_trigger = 1'b0;
    reg [3:0]  ty_idx  = 4'd0;
    reg [23:0] ty_cnt  = 24'd0;
    reg        ty_v    = 1'b0;
    reg [7:0]  ty_b    = 8'h00;

    function [7:0] ty_char(input [3:0] i);           // LOAD "" CR
        case (i)
            4'd0: ty_char = "L";
            4'd1: ty_char = "O";
            4'd2: ty_char = "A";
            4'd3: ty_char = "D";
            4'd4: ty_char = " ";
            4'd5: ty_char = 8'h22;                   // "
            4'd6: ty_char = 8'h22;                   // "
            4'd7: ty_char = 8'h0D;                   // ENTER
            default: ty_char = 8'h00;
        endcase
    endfunction

    always @(posedge clk) begin
        ty_v <= 1'b0;
        if (reset) begin
            ty_run <= 1'b0;
            ty_idx <= 4'd0;
            ty_cnt <= 24'd0;
        end else if ((type_go || ty_trigger) && !ty_run) begin
            ty_run <= 1'b1;
            ty_idx <= 4'd0;
            ty_cnt <= 24'd0;
        end else if (ty_run) begin
            if (ty_cnt == 24'd0) begin
                if (ty_idx == 4'd8) begin
                    ty_run <= 1'b0;                  // done
                end else begin
                    ty_b  <= ty_char(ty_idx);
                    ty_v  <= 1'b1;
                    ty_idx <= ty_idx + 4'd1;
                    ty_cnt <= TYPE_GAP;
                end
            end else
                ty_cnt <= ty_cnt - 24'd1;
        end
    end

    // the parser sees the typer's bytes exactly like the UART's
    wire       rx_valid = urx_valid | ty_v;
    wire [7:0] rx_byte  = ty_v ? ty_b : urx_byte;

    assign rx_byte_out  = urx_byte;
    assign rx_valid_out = urx_valid;

    wire [8:0] mapped = keymap(rx_byte);

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            pk          <= PK_NONE;
            lib_list    <= 1'b0;
            lib_sel     <= 1'b0;
            lib_eject   <= 1'b0;
            lib_play    <= 1'b0;
            cmd_instant <= 1'b0;
            cmd_version <= 1'b0;
            scr_req     <= 1'b0;
            ty_trigger  <= 1'b0;
            lib_idx     <= 5'd0;
            have_pos    <= 1'b0;
            web_matrix  <= 40'd0;
            ah_matrix   <= 40'd0;
            ah_state    <= AH_IDLE;
            ah_cnt      <= 24'd0;
        end else begin
            lib_list    <= 1'b0;
            lib_sel     <= 1'b0;
            lib_eject   <= 1'b0;
            lib_play    <= 1'b0;
            cmd_instant <= 1'b0;
            cmd_version <= 1'b0;
            scr_req     <= 1'b0;
            ty_trigger  <= 1'b0;
            // ---- a byte from the host ------------------------------------
            if (rx_valid && card_mode !== 1'b1) begin
                case (pk)
                    PK_NONE: begin
                        if (rx_byte == 8'hFE)       pk <= PK_KEY_POS;
                        else if (rx_byte == 8'hFF)  pk <= PK_FF;
                        else if (rx_byte == 8'hFB)  pk <= PK_LIB;
                        else if (rx_byte == 8'hFA)  scr_req <= 1'b1;
                        else if (rx_byte == 8'hFC)  ; // snapshot packet leader
                        else if (!snap_busy && mapped[8]) begin    // plain ASCII keystroke
                            ah_matrix <= keybits(mapped);
                            ah_state  <= AH_DOWN;
                            ah_cnt    <= HOLD_DOWN;
                        end
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
                        // 0xFB 'L' list, 'S' <idx> select, 'C' eject, 'P' play, 'I' instant, 'T' type LOAD ""
                        case (rx_byte)
                            8'h4C: lib_list    <= 1'b1;
                            8'h53: pk <= PK_LIB_IDX;
                            8'h43: lib_eject   <= 1'b1;
                            8'h50: lib_play    <= 1'b1;
                            8'h49: cmd_instant <= 1'b1;   // 'I'
                            8'h56: cmd_version <= 1'b1;   // 'V'
                            8'h54: ty_trigger  <= 1'b1;   // 'T'
                            default: ;
                        endcase
                        if (rx_byte != 8'h53) pk <= PK_NONE;
                    end
                    PK_LIB_IDX: begin
                        lib_idx <= rx_byte[4:0];
                        lib_sel <= 1'b1;
                        pk <= PK_NONE;
                    end
                    PK_FF: begin
                        if (rx_byte == 8'h04) web_matrix <= 40'd0;
                        else if (rx_byte == 8'h05) scr_req <= 1'b1;
                        else if (rx_byte == 8'h06) ty_trigger <= 1'b1; // Type LOAD "" macro
                        pk <= PK_NONE;
                    end
                    default: pk <= PK_NONE;
                endcase
            end

            // ---- the ASCII fallback's hold timer -------------------------
            case (ah_state)
                AH_DOWN:
                    if (ah_cnt == 24'd0) begin
                        ah_matrix <= 40'd0;          // the gap between keys
                        ah_cnt    <= HOLD_UP;
                        ah_state  <= AH_UP;
                    end else ah_cnt <= ah_cnt - 24'd1;
                AH_UP:
                    if (ah_cnt == 24'd0) begin
                        ah_state <= AH_IDLE;
                    end else ah_cnt <= ah_cnt - 24'd1;
                default: ;
            endcase
        end
    end

    assign vk_matrix = web_matrix | ah_matrix;
    assign key_hit   = urx_valid;

    // =====================================================================
    // ASCII -> ZX key.  Matrix layout (row, col), both 0-based:
    //   row0: CAPS SHIFT Z X C V      row1: A S D F G
    //   row2: Q W E R T               row3: 1 2 3 4 5
    //   row4: 0 9 8 7 6               row5: P O I U Y
    //   row6: ENTER L K J H           row7: SPACE SYMBOL-SHIFT M N B
    // Red legends need SYMBOL SHIFT ((7,1)); capitals need CAPS SHIFT ((0,0)).
    // =====================================================================

    // Where the letters and digits live, {row, col}.  Only the unshifted
    // identities; keymap adds the shifts.
    function [5:0] keypos(input [7:0] c);
        case (c)
            8'h61: keypos = {3'd1, 3'd0}; // a
            8'h62: keypos = {3'd7, 3'd4}; // b
            8'h63: keypos = {3'd0, 3'd3}; // c
            8'h64: keypos = {3'd1, 3'd2}; // d
            8'h65: keypos = {3'd2, 3'd2}; // e
            8'h66: keypos = {3'd1, 3'd3}; // f
            8'h67: keypos = {3'd1, 3'd4}; // g
            8'h68: keypos = {3'd6, 3'd4}; // h
            8'h69: keypos = {3'd5, 3'd2}; // i
            8'h6a: keypos = {3'd6, 3'd3}; // j
            8'h6b: keypos = {3'd6, 3'd2}; // k
            8'h6c: keypos = {3'd6, 3'd1}; // l
            8'h6d: keypos = {3'd7, 3'd2}; // m
            8'h6e: keypos = {3'd7, 3'd3}; // n
            8'h6f: keypos = {3'd5, 3'd1}; // o
            8'h70: keypos = {3'd5, 3'd0}; // p
            8'h71: keypos = {3'd2, 3'd0}; // q
            8'h72: keypos = {3'd2, 3'd3}; // r
            8'h73: keypos = {3'd1, 3'd1}; // s
            8'h74: keypos = {3'd2, 3'd4}; // t
            8'h75: keypos = {3'd5, 3'd3}; // u
            8'h76: keypos = {3'd0, 3'd4}; // v
            8'h77: keypos = {3'd2, 3'd1}; // w
            8'h78: keypos = {3'd0, 3'd2}; // x
            8'h79: keypos = {3'd5, 3'd4}; // y
            8'h7a: keypos = {3'd0, 3'd1}; // z
            8'h30: keypos = {3'd4, 3'd0}; // 0
            8'h31: keypos = {3'd3, 3'd0}; // 1
            8'h32: keypos = {3'd3, 3'd1}; // 2
            8'h33: keypos = {3'd3, 3'd2}; // 3
            8'h34: keypos = {3'd3, 3'd3}; // 4
            8'h35: keypos = {3'd3, 3'd4}; // 5
            8'h36: keypos = {3'd4, 3'd4}; // 6
            8'h37: keypos = {3'd4, 3'd3}; // 7
            8'h38: keypos = {3'd4, 3'd2}; // 8
            8'h39: keypos = {3'd4, 3'd1}; // 9
            default: keypos = 6'h3F;
        endcase
    endfunction

    // {valid, caps, sym, row[2:0], col[2:0]} for a host byte.
    function [8:0] keymap(input [7:0] c);
        reg [5:0] p;
        reg       caps, sym, valid;
        begin
            p = keypos(c);
            caps = 1'b0; sym = 1'b0; valid = 1'b1;
            if (c >= "A" && c <= "Z") begin
                p = keypos(c + 8'h20); caps = 1'b1;   // capitals: CAPS SHIFT
            end else if (c >= "a" && c <= "z") begin
                // p already right
            end else begin
                case (c)
                    8'h20:            p = {3'd7, 3'd0}; // space
                    8'h0d, 8'h0a:     p = {3'd6, 3'd0}; // ENTER
                    8'h2e:            p = {3'd7, 3'd2}; // .   sym+M
                    8'h2c:            p = {3'd7, 3'd3}; // ,   sym+N
                    8'h3a:            p = {3'd0, 3'd1}; // :   sym+Z
                    8'h3b:            p = {3'd5, 3'd1}; // ;   sym+O
                    8'h22:            p = {3'd5, 3'd0}; // "   sym+P
                    8'h27:            p = {3'd4, 3'd3}; // '   sym+7
                    8'h21:            p = {3'd3, 3'd0}; // !   sym+1
                    8'h3f:            p = {3'd0, 3'd3}; // ?   sym+C
                    8'h23:            p = {3'd3, 3'd2}; // #   sym+3
                    8'h24:            p = {3'd3, 3'd3}; // $   sym+4
                    8'h25:            p = {3'd3, 3'd4}; // %   sym+5
                    8'h26:            p = {3'd4, 3'd4}; // &   sym+6
                    8'h40:            p = {3'd3, 3'd1}; // @   sym+2
                    8'h2b:            p = {3'd6, 3'd2}; // +   sym+K
                    8'h2d:            p = {3'd6, 3'd3}; // -   sym+J
                    8'h2a:            p = {3'd7, 3'd4}; // *   sym+B
                    8'h2f:            p = {3'd0, 3'd4}; // /   sym+V
                    8'h28:            p = {3'd4, 3'd2}; // (   sym+8
                    8'h29:            p = {3'd4, 3'd1}; // )   sym+9
                    8'h3c:            p = {3'd2, 3'd3}; // <   sym+R
                    8'h3e:            p = {3'd2, 3'd4}; // >   sym+T
                    8'h3d:            p = {3'd6, 3'd1}; // =   sym+L
                    8'h5e:            p = {3'd6, 3'd4}; // ^   sym+H
                    8'h5f:            p = {3'd4, 3'd0}; // _   sym+0
                    default: valid = 1'b0;
                endcase
                if (valid && !(c == 8'h20 || c == 8'h0d || c == 8'h0a))
                    sym = 1'b1;                          // red legends
            end
            keymap = {valid, caps, sym, p[5:3], p[2:0]};
        end
    endfunction

    // A mapped key as a 40-bit one-hot: the key itself, plus CAPS SHIFT
    // (position 0) or SYMBOL SHIFT (position 37) when the map says so.
    function [39:0] keybits(input [8:0] m);
        reg [39:0] v;
        integer pos;
        begin
            v   = 40'd0;
            pos = m[5:3] * 5 + m[2:0];   // {row, col} -> row*5 + col
            v[pos] = 1'b1;
            if (m[7]) v[0]  = 1'b1;   // CAPS SHIFT
            if (m[6]) v[36] = 1'b1;   // SYMBOL SHIFT
            keybits = v;
        end
    endfunction

endmodule

`default_nettype wire
