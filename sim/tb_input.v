// ============================================================================
//  tb_input.v -- the web keyboard's UART path
//
//  Drives zx_input's RX pin at 1 Mbps 8N1 with the packets the web page
//  sends, and checks the 40-bit virtual matrix the ULA will read:
//
//    FE <pos> <down>   down sets, up clears the bit
//    FF 04             all keys up
//    anything else     ignored -- the board only takes matrix key events,
//                      like the real membrane (translation is the page's job)
//
//  plusarg +quiet=1 keeps the noise down.
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_input;
    reg clk = 1'b0;
    always #18.519 clk = ~clk;      // 27 MHz

    reg reset = 1'b1;
    reg uart_rx = 1'b1;
    reg hold = 1'b0;
    wire        cmd_instant;
    wire [23:0] inst_off;
    reg         saw_inst = 1'b0;
    reg  [23:0] saw_off = 24'd0;
    always @(posedge clk) if (cmd_instant) begin saw_inst <= 1'b1; saw_off <= inst_off; end
    reg [39:0] keys_before;

    wire [39:0] vk_matrix;
    wire        key_hit;
    wire        lib_list, lib_sel, lib_eject, lib_play;
    wire [4:0]  lib_idx;
    wire        tape_mon;

    zx_input u_dut (
        .clk(clk), .reset(reset), .uart_rx(uart_rx),
        .vk_matrix(vk_matrix), .key_hit(key_hit),
        .card_mode(1'b0), .hold(hold),
        .cmd_instant(cmd_instant), .inst_off(inst_off),
        .lib_list(lib_list), .lib_sel(lib_sel), .lib_idx(lib_idx),
        .lib_eject(lib_eject), .lib_play(lib_play),
        .tape_mon(tape_mon)
    );

    // the library commands are one-clock pulses: keep what was seen
    reg        saw_list = 1'b0, saw_sel = 1'b0, saw_eject = 1'b0, saw_play = 1'b0;
    reg [4:0]  saw_idx = 5'd0;
    always @(posedge clk) begin
        if (lib_list)  saw_list  <= 1'b1;
        if (lib_sel)   begin saw_sel <= 1'b1; saw_idx <= lib_idx; end
        if (lib_eject) saw_eject <= 1'b1;
        if (lib_play)  saw_play  <= 1'b1;
    end

    task lib_clear;
        begin
            saw_list = 1'b0; saw_sel = 1'b0; saw_eject = 1'b0; saw_play = 1'b0;
            saw_idx = 5'd0;
        end
    endtask

    integer quiet = 0;
    initial if (!$value$plusargs("quiet=%d", quiet)) quiet = 0;

    integer errors = 0;

    task check(input [39:0] got, input [39:0] want, input [127:0] what);
        if (got !== want) begin
            $display("FAIL: %0s: matrix %010x, expected %010x", what, got, want);
            errors = errors + 1;
        end else if (!quiet)
            $display("ok: %0s", what);
    endtask

    // one byte, 8N1, LSB first, 27 clocks per bit
    task send_byte(input [7:0] b);
        integer k;
        begin
            uart_rx = 1'b0;                       // start
            repeat (27) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                uart_rx = b[k];
                repeat (27) @(posedge clk);
            end
            uart_rx = 1'b1;                       // stop
            repeat (27) @(posedge clk);
        end
    endtask

    task key(input [5:0] pos, input down);
        begin
            send_byte(8'hFE);
            send_byte({2'b00, pos});
            send_byte({7'b0, down});
        end
    endtask

    // let the receiver's stop-bit detection land, then settle a frame
    task settle;
        begin
            repeat (100) @(posedge clk);
            if (!quiet) $display("   last rx byte=%02x vk=%010x", u_dut.urx_byte, vk_matrix);
        end
    endtask

    initial begin
        repeat (100) @(posedge clk);
        reset = 1'b0;
        repeat (50) @(posedge clk);

        // a down/up pair: CAPS SHIFT (pos 0) and X (pos 2), like a chord
        key(6'd0, 1'b1);  settle;
        key(6'd2, 1'b1);  settle;
        check(vk_matrix, 40'h5, "CAPS SHIFT + X down");

        key(6'd2, 1'b0);  settle;
        check(vk_matrix, 40'h1, "X up, CAPS SHIFT still held");

        // out-of-range positions are ignored, and the packet still completes
        send_byte(8'hFE); send_byte(8'd99); send_byte(8'd1); settle;
        check(vk_matrix, 40'h1, "bogus position ignored");

        // all keys up
        send_byte(8'hFF); send_byte(8'h04); settle;
        check(vk_matrix, 40'd0, "FF 04 all up");

        // a plain ASCII byte is NOT translated: the board only takes matrix
        // key events, like the real membrane (translation is the page's job)
        send_byte(8'h41); settle;
        check(vk_matrix, 40'd0, "ASCII byte ignored");

        // ---- the tape library's commands --------------------------------
        lib_clear;
        send_byte(8'hFB); send_byte(8'h4C); settle;
        if (!saw_list || saw_sel || saw_eject || saw_play) begin
            $display("FAIL: FB 4C should be a list request alone");
            errors = errors + 1;
        end else if (!quiet) $display("ok: FB 4C list");

        lib_clear;
        send_byte(8'hFB); send_byte(8'h53); send_byte(8'd7); settle;
        if (!saw_sel || saw_idx != 5'd7 || saw_list || saw_eject) begin
            $display("FAIL: FB 53 07 should select 7 (got sel=%b idx=%0d)",
                     saw_sel, saw_idx);
            errors = errors + 1;
        end else if (!quiet) $display("ok: FB 53 07 select");

        lib_clear;
        send_byte(8'hFB); send_byte(8'h43); settle;
        if (!saw_eject) begin $display("FAIL: FB 43 eject"); errors = errors + 1; end
        else if (!quiet) $display("ok: FB 43 eject");

        lib_clear;
        send_byte(8'hFB); send_byte(8'h50); settle;
        if (!saw_play) begin $display("FAIL: FB 50 play"); errors = errors + 1; end
        else if (!quiet) $display("ok: FB 50 play");

        // tape audio: a level, 'A' on, 'a' off, and a key packet leaves it be
        send_byte(8'hFB); send_byte(8'h41); key(6'd5, 1'b1); settle;
        if (tape_mon !== 1'b1) begin $display("FAIL: FB 41 tape audio on"); errors = errors + 1; end
        send_byte(8'hFB); send_byte(8'h61); settle;
        if (tape_mon !== 1'b0) begin $display("FAIL: FB 61 tape audio off"); errors = errors + 1; end
        else if (!quiet) $display("ok: FB 41/61 tape audio");

        // instant: FB 49 and a 24-bit offset, low byte first; a select's
        // index or a key packet after it is parsed normally again
        lib_clear;
        send_byte(8'hFB); send_byte(8'h49);
        send_byte(8'h42); send_byte(8'h00); settle;
        if (saw_inst) begin $display("FAIL: FB 49 fired before its offset"); errors = errors + 1; end
        send_byte(8'h01); settle;
        if (!saw_inst || saw_off !== 24'h010042) begin
            $display("FAIL: FB 49 42 00 01 should arm at 0x010042 (got %b %06x)", saw_inst, saw_off);
            errors = errors + 1;
        end else if (!quiet) $display("ok: FB 49 <off> instant at 0x%06x", saw_off);
        send_byte(8'hFB); send_byte(8'h53); send_byte(8'd4); settle;
        if (!saw_sel || saw_idx != 5'd4) begin $display("FAIL: parser lost after FB 49"); errors = errors + 1; end

        // held (zx_snap inside a packet): snapshot bytes that look like
        // commands -- a key, a select, an eject -- must do nothing
        lib_clear;
        keys_before = vk_matrix;
        hold = 1'b1;
        key(6'd3, 1'b1);
        send_byte(8'hFB); send_byte(8'h53); send_byte(8'd2);
        send_byte(8'hFB); send_byte(8'h43); settle;
        hold = 1'b0;
        if (saw_sel || saw_eject || vk_matrix !== keys_before) begin
            $display("FAIL: held bytes were parsed (sel=%b eject=%b keys=%010x)",
                     saw_sel, saw_eject, vk_matrix);
            errors = errors + 1;
        end else if (!quiet) $display("ok: held stream ignored");

        if (errors == 0) $display("PASS: zx_input");
        $finish;
    end

    // watchdog
    initial begin
        #100ms;
        $display("FAIL: watchdog expired");
        $finish;
    end

endmodule

`default_nettype wire
