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

    // after the banner: one caller byte at a time (library frames, captures)
    input  wire       tx_req,
    input  wire [7:0] tx_data,
    output wire       tx_busy
);
    localparam [8:0] CLKS_PER_BIT = `UART_CLKS_PER_BIT;

    // the banner, then the firmware version (src/version.vh).  CR/LF are
    // octal escapes: Verilog-2001 has no \r, and Gowin emits the letter r.
    localparam [7:0] TOTAL_LEN = 8'd21 + `FW_VER_LEN;
    localparam [8*TOTAL_LEN-1:0] TEXT = {"[ ZX Spectrum 20K ]\015\012", `FW_VER_TEXT};

    function [7:0] banner(input [7:0] i);
        banner = TEXT[8 * (TOTAL_LEN - 8'd1 - i) +: 8];
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
