`timescale 1ns/1ps
`default_nettype none
module tb_mem_min;
    reg clk = 0;
    always #10 clk = ~clk;

    reg reset = 1;
    reg wr_valid = 0;
    reg [7:0] wr_byte = 0;
    wire wr_ready;
    wire [23:0] wr_count;
    reg [23:0] img_len = 0;
    reg rewind = 0;
    wire [23:0] rd_count;
    wire img_ready, rd_empty;
    reg rd_pop = 0;
    wire [7:0] rd_byte;
    wire ddr_go;
    wire [25:0] ddr_addr;
    wire ddr_we;
    wire [1:0] ddr_be;
    wire [15:0] ddr_wdata;

    // a fake DDR: every request acks after two clocks
    reg ack = 0, we_r = 0;
    reg [15:0] mem [0:1023];
    always @(posedge clk) begin
        ack <= 0;
        if (ddr_go) begin
            ack <= 1;
            if (ddr_we) mem[ddr_addr[9:0]] <= ddr_wdata;
        end
    end
    wire [15:0] ddr_rdata = mem[ddr_addr[9:0]];
    wire ddr_idle = !ack;

    zx_tape_mem u (
        .clk(clk), .reset(reset),
        .ddr_go(ddr_go), .ddr_addr(ddr_addr), .ddr_we(ddr_we), .ddr_be(ddr_be),
        .ddr_wdata(ddr_wdata), .ddr_rdata(ddr_rdata), .ddr_ack(ack), .ddr_idle(ddr_idle),
        .wr_valid(wr_valid), .wr_byte(wr_byte), .wr_ready(wr_ready), .wr_count(wr_count),
        .img_len(img_len), .rewind(rewind), .rd_count(rd_count),
        .img_ready(img_ready), .rd_empty(rd_empty),
        .rd_pop(rd_pop), .rd_byte(rd_byte), .clear(1'b0)
    );

    integer i;
    reg [7:0] got;
    integer errors = 0;

    task send(input [7:0] b);
        begin
            @(posedge clk);
            while (!wr_ready) @(posedge clk);
            wr_valid <= 1; wr_byte <= b;
            @(posedge clk);
            wr_valid <= 0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;
        repeat (2) @(posedge clk);
        for (i = 0; i < 5; i = i + 1) send(8'h10 + i);
        img_len = 5;
        repeat (5) @(posedge clk);
        $display("wr_count=%0d ready=%b", wr_count, img_ready);
        for (i = 0; i < 5; i = i + 1) begin
            @(negedge clk);
            while (rd_empty) @(negedge clk);
            got = rd_byte;
            rd_pop <= 1;
            @(negedge clk);
            rd_pop <= 0;
            if (got !== (8'h10 + i)) begin
                $display("bad %0d: %02x want %02x", i, got, 8'h10 + i);
                errors = errors + 1;
            end
        end
        if (errors) $display("FAIL: minimal store");
        else $display("PASS: minimal store");
        $finish;
    end
    initial begin #20us; $display("timeout"); $finish; end
endmodule
`default_nettype wire
