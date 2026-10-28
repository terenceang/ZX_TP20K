// ============================================================================
//  tb_scr_cap.v -- unit test for zx_scr_cap
// ============================================================================

`timescale 1ns/1ps

module tb_scr_cap;

    reg clk = 0;
    always #18.518 clk = ~clk; // 27 MHz (period ~37.037 ns)

    reg reset = 1;
    reg cap_req = 0;
    reg [2:0] border = 3'd7;
    reg flash = 1'b0;
    reg vid_busy = 0;

    wire [15:0] ram_addr;
    reg  [7:0]  ram [0:8191];
    reg  [7:0]  ram_rdata = 8'h00;
    always @(posedge clk) ram_rdata <= ram[ram_addr];

    wire capturing;
    wire tx_req;
    wire [7:0] tx_data;
    reg  tx_busy = 0;

    // Simulated UART transmitter with 10 clocks busy per byte
    reg [4:0] busy_cnt = 0;
    always @(posedge clk) begin
        if (reset) begin
            tx_busy  <= 0;
            busy_cnt <= 0;
        end else if (tx_req) begin
            tx_busy  <= 1;
            busy_cnt <= 10;
        end else if (busy_cnt > 0) begin
            busy_cnt <= busy_cnt - 1;
            if (busy_cnt == 1) tx_busy <= 0;
        end
    end

    // Use smaller SCR_BYTES = 16 for quick verification
    zx_scr_cap #(.SCR_BYTES(16)) dut (
        .clk(clk),
        .reset(reset),
        .cap_req(cap_req),
        .border(border),
        .flash(flash),
        .vid_busy(vid_busy),
        .ram_addr(ram_addr),
        .ram_rdata(ram_rdata),
        .capturing(capturing),
        .tx_req(tx_req),
        .tx_data(tx_data),
        .tx_busy(tx_busy)
    );

    integer i;
    reg [7:0] received [0:31];
    integer rx_count = 0;

    always @(posedge clk) begin
        if (tx_req) begin
            received[rx_count] = tx_data;
            rx_count = rx_count + 1;
        end
    end

    initial begin
        for (i = 0; i < 8192; i = i + 1) ram[i] = 8'hA0 + i[7:0];

        #100;
        reset = 0;
        #100;

        // Trigger capture with border 3 (magenta), flash 1
        border = 3'd3;
        flash = 1'b1;
        cap_req = 1;
        #37.037;
        cap_req = 0;

        // Wait until capturing finishes
        wait (capturing == 1);
        wait (capturing == 0);

        #100;

        if (rx_count != 18) begin
            $display("FAIL: expected 18 bytes (1 hdr + 1 status + 16 data), got %0d", rx_count);
            $finish(1);
        end

        if (received[0] != 8'hF5) begin
            $display("FAIL: expected hdr 0xF5, got 0x%02X", received[0]);
            $finish(1);
        end

        if (received[1] != {4'd0, 1'b1, 3'd3}) begin
            $display("FAIL: expected status 0x%02X, got 0x%02X", {4'd0, 1'b1, 3'd3}, received[1]);
            $finish(1);
        end

        for (i = 0; i < 16; i = i + 1) begin
            if (received[2 + i] != (8'hA0 + i[7:0])) begin
                $display("FAIL: byte %0d expected 0x%02X, got 0x%02X", i, 8'hA0 + i[7:0], received[2 + i]);
                $finish(1);
            end
        end

        $display("PASS: zx_scr_cap");
        $finish(0);
    end

endmodule
