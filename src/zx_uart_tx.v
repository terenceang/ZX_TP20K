// ============================================================================
//  zx_uart_tx.v -- the boot banner and firmware version
//
//  One string, once, after reset: the web keyboard uses it to confirm it has
//  the FPGA's UART and not some other port on the USB device (web/src/
//  serial-link.js probes for exactly this text), and a terminal user sees
//  something at 1 Mbps 8N1 instead of silence.
//
//  The same 27-clocks-per-bit divisor as the receiver (src/uart_defs.vh).
// ============================================================================

`default_nettype none
`include "src/uart_defs.vh"
`include "src/version.vh"

module zx_uart_tx (
    input  wire       clk,        // 27 MHz (clk_pixel)
    input  wire       reset,
    output wire       uart_tx,    // idle high

    // after the banner: one caller byte at a time (the tape's credit byte)
    input  wire       tx_req,
    input  wire [7:0] tx_data,
    output wire       tx_busy
);
    localparam [8:0] CLKS_PER_BIT = `UART_CLKS_PER_BIT;

    localparam [8*`FW_VER_LEN-1:0] VER_TEXT = `FW_VER_TEXT;
    localparam [7:0] BANNER_PREFIX_LEN = 8'd21;
    localparam [7:0] TOTAL_LEN = BANNER_PREFIX_LEN + `FW_VER_LEN;

    // The banner followed by FW version
    function [7:0] banner(input [7:0] i);
        if (i < BANNER_PREFIX_LEN) begin
            case (i[4:0])
                5'd0:  banner = "[";       5'd1:  banner = " ";
                5'd2:  banner = "Z";       5'd3:  banner = "X";
                5'd4:  banner = " ";       5'd5:  banner = "S";
                5'd6:  banner = "p";       5'd7:  banner = "e";
                5'd8:  banner = "c";       5'd9:  banner = "t";
                5'd10: banner = "r";       5'd11: banner = "u";
                5'd12: banner = "m";       5'd13: banner = " ";
                5'd14: banner = "2";       5'd15: banner = "0";
                5'd16: banner = "K";       5'd17: banner = " ";
                5'd18: banner = "]";       5'd19: banner = 8'h0D; // CR ("\r" is not a Verilog escape)
                5'd20: banner = 8'h0A;     // LF
                default: banner = 8'd0;
            endcase
        end else begin
            banner = VER_TEXT[8 * (TOTAL_LEN - 8'd1 - i) +: 8];
        end
    endfunction

    reg [9:0]  sh   = 10'h3FF;       // {2 stop, 8 data, start}; LSB goes first
    reg [8:0]  cnt  = 9'd0;
    reg [7:0]  idx  = 8'd0;
    reg [3:0]  bitn = 4'd0;         // 11 bit times: start + 8 data + 2 stop
    reg        busy = 1'b0;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            sh   <= 10'h3FF;
            cnt  <= 9'd0;
            idx  <= 8'd0;
            bitn <= 4'd0;
            busy <= 1'b0;
        end else if (!busy) begin
            if (idx < TOTAL_LEN) begin
                sh   <= {2'b11, banner(idx), 1'b0};   // start bit at sh[0]
                idx  <= idx + 8'd1;
                bitn <= 4'd0;
                cnt  <= 9'd0;
                busy <= 1'b1;
            end else if (tx_req) begin
                sh   <= {2'b11, tx_data, 1'b0};
                bitn <= 4'd0;
                cnt  <= 9'd0;
                busy <= 1'b1;
            end
        end else if (cnt == CLKS_PER_BIT - 9'd1) begin
            cnt <= 9'd0;
            sh  <= {1'b1, sh[9:1]};
            if (bitn == 4'd10) busy <= 1'b0;
            else bitn <= bitn + 4'd1;
        end else cnt <= cnt + 9'd1;
    end

    assign uart_tx = sh[0];
    assign tx_busy = busy;

endmodule

`default_nettype wire
