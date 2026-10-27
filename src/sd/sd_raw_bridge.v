// ============================================================================
//  sd_raw_bridge.v -- Raw SD card sector read/write bridge for FAT32 upload
//
//  Ported from apple2e_TP20K (serial_debugger.v) for ZX_TP20K.
//  Exposes raw 512-byte sector operations over 1 Mbps UART so the web page's
//  fat32.js can upload files directly to the SD card.
//
//  Commands (active when card_mode is 1, toggled by Ctrl+B 0x02):
//    i            -> "\r\nH:00 S:ssss Q:00\r\n" (ssss = 16-bit status in hex)
//    b<lba:8><n:4>-> "\r\nSECTORS\r\n" <n*512 raw bytes> "\r\ndone\r\n"
//    u<lba:8>     -> "\r\nUPLOAD HD\r\n"
//                    Followed by records:
//                      0x01 + 512 data bytes -> 0x06 (ACK)
//                      0x00 + 2 bytes run of zeros -> 0x06 (ACK)
//                      0x02 -> "\r\ndone\r\n"
//    c            -> exits card_mode (back to Spectrum keyboard)
// ============================================================================

`default_nettype none
`include "src/version.vh"

module sd_raw_bridge (
    input  wire        clk,
    input  wire        reset,

    // UART RX stream
    input  wire [7:0]  rx_byte,
    input  wire        rx_valid,

    // Query version command (e.g. 0xFB 'V' from zx_input)
    input  wire        cmd_version,

    // Active status: when 1, suppresses virtual keys in zx_input
    output reg         card_mode = 1'b0,

    // UART TX stream
    output reg         tx_req = 1'b0,
    output reg  [7:0]  tx_data = 8'h00,
    input  wire        tx_busy,

    // SD controller status & interface from sd_vol
    input  wire [15:0] sd_stat,
    input  wire        sd_busy,
    input  wire        sd_err,
    input  wire        sd_fs_ok,

    // Write interface to sd_vol
    output reg         sd_x_go = 1'b0,
    output reg  [31:0] sd_x_lba = 32'd0,
    output reg         sd_x_zero = 1'b0,
    output reg  [7:0]  sd_x_byte = 8'd0,
    output reg         sd_x_valid = 1'b0,
    input  wire        sd_x_take,

    // Read interface from sd_vol
    output reg         sd_r_go = 1'b0,
    output reg  [31:0] sd_r_lba = 32'd0,
    output reg  [15:0] sd_r_cnt = 16'd0,
    input  wire [7:0]  sd_r_byte,
    input  wire        sd_r_valid,
    output reg         sd_r_take = 1'b0,
    input  wire        sd_r_done,
    input  wire        sd_r_ok
);

    function is_hex(input [7:0] b);
        is_hex = (b >= "0" && b <= "9") || (b >= "A" && b <= "F") || (b >= "a" && b <= "f");
    endfunction

    function [3:0] hex_val(input [7:0] b);
        if (b >= "0" && b <= "9") hex_val = b[3:0];
        else if (b >= "A" && b <= "F") hex_val = b[3:0] + 4'd9;
        else if (b >= "a" && b <= "f") hex_val = b[3:0] + 4'd9;
        else hex_val = 4'd0;
    endfunction

    function [7:0] to_hex(input [3:0] nib);
        to_hex = (nib < 4'd10) ? ("0" + {4'd0, nib}) : ("A" + {4'd0, nib - 4'd10});
    endfunction

    localparam [8*`FW_VER_LEN-1:0] VER_TEXT = `FW_VER_TEXT;

    // String ROM table
    function [7:0] rom_byte(input [6:0] idx, input [15:0] stat);
        if (idx >= 7'd64 && idx < 7'd64 + `FW_VER_LEN) begin
            rom_byte = VER_TEXT[8 * (`FW_VER_LEN - 7'd1 - (idx - 7'd64)) +: 8];
        end else case (idx[5:0])
            // 0..19: \r\nH:00 S:ssss Q:00\r\n
            6'd0:  rom_byte = "\r";
            6'd1:  rom_byte = "\n";
            6'd2:  rom_byte = "H";
            6'd3:  rom_byte = ":";
            6'd4:  rom_byte = "0";
            6'd5:  rom_byte = "0";
            6'd6:  rom_byte = " ";
            6'd7:  rom_byte = "S";
            6'd8:  rom_byte = ":";
            6'd9:  rom_byte = to_hex(stat[15:12]);
            6'd10: rom_byte = to_hex(stat[11:8]);
            6'd11: rom_byte = to_hex(stat[7:4]);
            6'd12: rom_byte = to_hex(stat[3:0]);
            6'd13: rom_byte = " ";
            6'd14: rom_byte = "Q";
            6'd15: rom_byte = ":";
            6'd16: rom_byte = "0";
            6'd17: rom_byte = "0";
            6'd18: rom_byte = "\r";
            6'd19: rom_byte = "\n";

            // 20..30: \r\nSECTORS\r\n
            6'd20: rom_byte = "\r";
            6'd21: rom_byte = "\n";
            6'd22: rom_byte = "S";
            6'd23: rom_byte = "E";
            6'd24: rom_byte = "C";
            6'd25: rom_byte = "T";
            6'd26: rom_byte = "O";
            6'd27: rom_byte = "R";
            6'd28: rom_byte = "S";
            6'd29: rom_byte = "\r";
            6'd30: rom_byte = "\n";

            // 31..43: \r\nUPLOAD HD\r\n
            6'd31: rom_byte = "\r";
            6'd32: rom_byte = "\n";
            6'd33: rom_byte = "U";
            6'd34: rom_byte = "P";
            6'd35: rom_byte = "L";
            6'd36: rom_byte = "O";
            6'd37: rom_byte = "A";
            6'd38: rom_byte = "D";
            6'd39: rom_byte = " ";
            6'd40: rom_byte = "H";
            6'd41: rom_byte = "D";
            6'd42: rom_byte = "\r";
            6'd43: rom_byte = "\n";

            // 44..51: \r\ndone\r\n
            6'd44: rom_byte = "\r";
            6'd45: rom_byte = "\n";
            6'd46: rom_byte = "d";
            6'd47: rom_byte = "o";
            6'd48: rom_byte = "n";
            6'd49: rom_byte = "e";
            6'd50: rom_byte = "\r";
            6'd51: rom_byte = "\n";

            // 52..59: \r\nlost\r\n
            6'd52: rom_byte = "\r";
            6'd53: rom_byte = "\n";
            6'd54: rom_byte = "l";
            6'd55: rom_byte = "o";
            6'd56: rom_byte = "s";
            6'd57: rom_byte = "t";
            6'd58: rom_byte = "\r";
            6'd59: rom_byte = "\n";

            // 60: 0x06 (ACK)
            6'd60: rom_byte = 8'h06;

            default: rom_byte = 8'h00;
        endcase
    endfunction

    localparam [3:0]
        ST_IDLE         = 4'd0,
        ST_SAY          = 4'd1,
        ST_B_HEX        = 4'd2,
        ST_READ_STREAM  = 4'd3,
        ST_U_HEX        = 4'd4,
        ST_WAIT_REC     = 4'd5,
        ST_WRITE_DATA   = 4'd6,
        ST_WAIT_BLOCK   = 4'd7,
        ST_ZERO_HI      = 4'd8,
        ST_ZERO_LO      = 4'd9,
        ST_ZERO_GO      = 4'd10;

    reg [3:0]  state = ST_IDLE;
    reg [3:0]  ret_state = ST_IDLE;
    reg [6:0]  str_pos = 7'd0;
    reg [6:0]  str_left = 7'd0;
    reg [15:0] str_stat = 16'd0;

    reg [3:0]  hex_cnt = 4'd0;
    reg [9:0]  byte_cnt = 10'd0;
    reg [1:0]  x_hold = 2'd0;
    reg [15:0] x_zn = 16'd0;
    reg        x_zrun = 1'b0;
    reg        r_fin = 1'b0;

    task say(input [6:0] pos, input [6:0] len, input [3:0] next_st);
        begin
            str_pos   <= pos;
            str_left  <= len;
            str_stat  <= sd_stat;
            ret_state <= next_st;
            state     <= ST_SAY;
        end
    endtask

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            card_mode   <= 1'b0;
            state       <= ST_IDLE;
            ret_state   <= ST_IDLE;
            str_pos     <= 7'd0;
            str_left    <= 7'd0;
            str_stat    <= 16'd0;
            tx_req      <= 1'b0;
            tx_data     <= 8'h00;
            sd_x_go     <= 1'b0;
            sd_x_lba    <= 32'd0;
            sd_x_zero   <= 1'b0;
            sd_x_byte   <= 8'h00;
            sd_x_valid  <= 1'b0;
            sd_r_go     <= 1'b0;
            sd_r_lba    <= 32'd0;
            sd_r_cnt    <= 16'd0;
            sd_r_take   <= 1'b0;
            hex_cnt     <= 4'd0;
            byte_cnt    <= 10'd0;
            x_hold      <= 2'd0;
            x_zn        <= 16'd0;
            x_zrun      <= 1'b0;
            r_fin       <= 1'b0;
        end else begin
            tx_req    <= 1'b0;
            sd_x_go   <= 1'b0;
            sd_r_go   <= 1'b0;
            sd_r_take <= 1'b0;

            // Global mode toggle on Ctrl+B (suppressed while an upload write is in progress)
            if (rx_valid && rx_byte == 8'h02 && state != ST_WAIT_REC && state != ST_WRITE_DATA && state != ST_WAIT_BLOCK) begin
                if (!card_mode) begin
                    card_mode <= 1'b1;
                    state     <= ST_IDLE;
                end else begin
                    card_mode <= 1'b0;
                    state     <= ST_IDLE;
                end
            end else if (cmd_version && state == ST_IDLE) begin
                say(7'd64, `FW_VER_LEN, ST_IDLE);
            end else if (card_mode) begin
                case (state)
                    ST_IDLE: begin
                        sd_x_valid <= 1'b0;
                        if (rx_valid) begin
                            if (rx_byte == "c" || rx_byte == "C") begin
                                card_mode <= 1'b0;
                            end else if (rx_byte == "i" || rx_byte == "I") begin
                                say(7'd0, 7'd20, ST_IDLE);  // "\r\nH:00 S:ssss Q:00\r\n"
                            end else if (rx_byte == "v" || rx_byte == "V") begin
                                say(7'd64, `FW_VER_LEN, ST_IDLE);  // "\r\nFW:v... (hash)\r\n"
                            end else if (rx_byte == "b" || rx_byte == "B") begin
                                hex_cnt <= 4'd12;
                                state   <= ST_B_HEX;
                            end else if (rx_byte == "u" || rx_byte == "U") begin
                                hex_cnt <= 4'd8;
                                state   <= ST_U_HEX;
                            end
                        end
                    end

                    ST_SAY: begin
                        if (!tx_busy && !tx_req) begin
                            tx_data  <= rom_byte(str_pos, str_stat);
                            tx_req   <= 1'b1;
                            str_pos  <= str_pos + 7'd1;
                            str_left <= str_left - 7'd1;
                            if (str_left == 7'd1) begin
                                state <= ret_state;
                            end
                        end
                    end

                    // b<lba:8><n:4>
                    ST_B_HEX: begin
                        if (rx_valid) begin
                            if (is_hex(rx_byte)) begin
                                if (hex_cnt > 4'd4)
                                    sd_r_lba <= {sd_r_lba[27:0], hex_val(rx_byte)};
                                else
                                    sd_r_cnt <= {sd_r_cnt[11:0], hex_val(rx_byte)};

                                if (hex_cnt == 4'd1) begin
                                    hex_cnt <= 4'd0;
                                    if (sd_busy || !sd_fs_ok) begin
                                        say(6'd52, 6'd8, ST_IDLE); // lost
                                    end else begin
                                        sd_r_go <= 1'b1;
                                        r_fin   <= 1'b0;
                                        say(6'd20, 6'd11, ST_READ_STREAM); // "\r\nSECTORS\r\n"
                                    end
                                end else begin
                                    hex_cnt <= hex_cnt - 4'd1;
                                end
                            end else begin
                                state <= ST_IDLE;
                            end
                        end
                    end

                    ST_READ_STREAM: begin
                        if (sd_r_done) r_fin <= 1'b1;

                        if (sd_r_valid && !sd_r_take && !tx_busy && !tx_req) begin
                            tx_data   <= sd_r_byte;
                            tx_req    <= 1'b1;
                            sd_r_take <= 1'b1;
                        end else if (r_fin && !sd_r_valid && !tx_busy && !tx_req) begin
                            if (sd_r_ok) say(6'd44, 6'd8, ST_IDLE); // done
                            else         say(6'd52, 6'd8, ST_IDLE); // lost
                        end
                    end

                    // u<lba:8>
                    ST_U_HEX: begin
                        if (rx_valid) begin
                            if (is_hex(rx_byte)) begin
                                sd_x_lba <= {sd_x_lba[27:0], hex_val(rx_byte)};
                                if (hex_cnt == 4'd1) begin
                                    hex_cnt <= 4'd0;
                                    if (sd_busy || !sd_fs_ok) begin
                                        say(6'd52, 6'd8, ST_IDLE); // lost
                                    end else begin
                                        say(6'd31, 6'd13, ST_WAIT_REC); // "\r\nUPLOAD HD\r\n"
                                    end
                                end else begin
                                    hex_cnt <= hex_cnt - 4'd1;
                                end
                            end else begin
                                state <= ST_IDLE;
                            end
                        end
                    end

                    ST_WAIT_REC: begin
                        if (rx_valid) begin
                            if (rx_byte == 8'h01) begin
                                sd_x_go    <= 1'b1;
                                sd_x_zero  <= 1'b0;
                                x_zrun     <= 1'b0;
                                byte_cnt   <= 10'd0;
                                x_hold     <= 2'd3;
                                state      <= ST_WRITE_DATA;
                            end else if (rx_byte == 8'h00) begin
                                state      <= ST_ZERO_HI;
                            end else if (rx_byte == 8'h02) begin
                                say(6'd44, 6'd8, ST_IDLE); // done
                            end else begin
                                say(6'd52, 6'd8, ST_IDLE); // lost
                            end
                        end
                    end

                    ST_WRITE_DATA: begin
                        if (x_hold != 2'd0) x_hold <= x_hold - 1'b1;
                        if (sd_x_take) sd_x_valid <= 1'b0;

                        if (rx_valid) begin
                            sd_x_byte  <= rx_byte;
                            sd_x_valid <= 1'b1;
                        end

                        if (sd_x_take) begin
                            byte_cnt <= byte_cnt + 10'd1;
                            if (byte_cnt == 10'd511) state <= ST_WAIT_BLOCK;
                        end
                    end

                    ST_WAIT_BLOCK: begin
                        if (x_hold != 2'd0) x_hold <= x_hold - 1'b1;
                        if (sd_x_take) sd_x_valid <= 1'b0;

                        if (x_hold == 2'd0 && !sd_busy) begin
                            sd_x_lba <= sd_x_lba + 32'd1;
                            if (sd_err) begin
                                say(6'd52, 6'd8, ST_IDLE); // lost
                            end else if (x_zrun && x_zn != 16'd0) begin
                                x_zn  <= x_zn - 16'd1;
                                state <= ST_ZERO_GO;
                            end else begin
                                say(6'd60, 6'd1, ST_WAIT_REC); // 0x06 ACK
                            end
                        end
                    end

                    ST_ZERO_HI: begin
                        if (rx_valid) begin
                            x_zn[15:8] <= rx_byte;
                            state      <= ST_ZERO_LO;
                        end
                    end

                    ST_ZERO_LO: begin
                        if (rx_valid) begin
                            x_zn[7:0] <= rx_byte;
                            state     <= ST_ZERO_GO;
                        end
                    end

                    ST_ZERO_GO: begin
                        if (!sd_busy && x_hold == 2'd0) begin
                            sd_x_go   <= 1'b1;
                            sd_x_zero <= 1'b1;
                            x_zrun    <= 1'b1;
                            x_hold    <= 2'd3;
                            state     <= ST_WAIT_BLOCK;
                        end
                    end

                    default: state <= ST_IDLE;
                endcase
            end
        end
    end

endmodule

`default_nettype wire
