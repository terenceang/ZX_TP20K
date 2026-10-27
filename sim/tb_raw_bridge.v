`timescale 1ns/1ps
`default_nettype none

module tb_raw_bridge;

    reg clk = 1'b0;
    always #18.5 clk = ~clk; // ~27 MHz

    reg reset = 1'b1;
    reg [7:0] rx_byte = 8'h00;
    reg rx_valid = 1'b0;
    wire card_mode;

    wire tx_req;
    wire [7:0] tx_data;
    reg tx_busy = 1'b0;

    reg [15:0] sd_stat = 16'h0200; // fs_ok=1
    reg sd_busy = 1'b0;
    reg sd_err = 1'b0;
    reg sd_fs_ok = 1'b1;

    wire sd_x_go;
    wire [31:0] sd_x_lba;
    wire sd_x_zero;
    wire [7:0] sd_x_byte;
    wire sd_x_valid;
    reg sd_x_take = 1'b0;

    wire sd_r_go;
    wire [31:0] sd_r_lba;
    wire [15:0] sd_r_cnt;
    reg [7:0] sd_r_byte = 8'hA5;
    reg sd_r_valid = 1'b0;
    wire sd_r_take;
    reg sd_r_done = 1'b0;
    reg sd_r_ok = 1'b1;

    sd_raw_bridge dut (
        .clk(clk),
        .reset(reset),
        .rx_byte(rx_byte),
        .rx_valid(rx_valid),
        .card_mode(card_mode),
        .tx_req(tx_req),
        .tx_data(tx_data),
        .tx_busy(tx_busy),
        .sd_stat(sd_stat),
        .sd_busy(sd_busy),
        .sd_err(sd_err),
        .sd_fs_ok(sd_fs_ok),
        .sd_x_go(sd_x_go),
        .sd_x_lba(sd_x_lba),
        .sd_x_zero(sd_x_zero),
        .sd_x_byte(sd_x_byte),
        .sd_x_valid(sd_x_valid),
        .sd_x_take(sd_x_take),
        .sd_r_go(sd_r_go),
        .sd_r_lba(sd_r_lba),
        .sd_r_cnt(sd_r_cnt),
        .sd_r_byte(sd_r_byte),
        .sd_r_valid(sd_r_valid),
        .sd_r_take(sd_r_take),
        .sd_r_done(sd_r_done),
        .sd_r_ok(sd_r_ok)
    );

    // TX busy emulator
    always @(posedge clk) begin
        if (tx_req) begin
            tx_busy <= 1'b1;
        end else if (tx_busy) begin
            tx_busy <= 1'b0;
        end
    end

    reg x_go_seen = 1'b0;
    always @(posedge clk) begin
        if (sd_x_go) x_go_seen <= 1'b1;
    end

    task send_rx(input [7:0] b);
        begin
            @(posedge clk);
            rx_byte  <= b;
            rx_valid <= 1'b1;
            @(posedge clk);
            rx_valid <= 1'b0;
            @(posedge clk);
        end
    endtask

    initial begin
        #100;
        reset = 1'b0;
        #100;

        if (card_mode !== 1'b0) $fatal(1, "card_mode should be 0 at reset");

        // Send Ctrl+B
        send_rx(8'h02);
        if (card_mode !== 1'b1) $fatal(1, "card_mode should be 1 after Ctrl+B");

        // Send 'i'
        send_rx("i");
        repeat (100) @(posedge clk);

        // Send 'c'
        send_rx("c");
        if (card_mode !== 1'b0) $fatal(1, "card_mode should be 0 after 'c'");

        // Re-enter card_mode
        send_rx(8'h02);
        if (card_mode !== 1'b1) $fatal(1, "card_mode should be 1");

        // Send 'u00000800'
        send_rx("u");
        send_rx("0"); send_rx("0"); send_rx("0"); send_rx("0");
        send_rx("0"); send_rx("8"); send_rx("0"); send_rx("0");
        repeat (100) @(posedge clk);

        if (sd_x_lba !== 32'h00000800) $fatal(1, "sd_x_lba should be 0x00000800, got %h", sd_x_lba);

        // Send record 01
        x_go_seen = 1'b0;
        send_rx(8'h01);
        @(posedge clk);
        if (!x_go_seen) $fatal(1, "sd_x_go should pulse on 0x01");

        $display("PASS: sd_raw_bridge");
        $finish;
    end

endmodule
