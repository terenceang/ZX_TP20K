// ============================================================================
//  tb_tv80.v -- directed tests of tv80 against the strobe scheme zx_core uses
//
//  Two programs run back to back, each against the same 64K byte-wide memory
//  and the same di_q latch / write strobe zx_core has:
//
//  1. EXX / shadow registers, the ED-group stores (LD (nn),BC/DE/HL) and
//     LD DE,(nn) -- the bookkeeping the 48K ROM's RAM test uses.
//  2. Indexed BIT/SET/RES on IY -- the print-position routing the ROM's
//     editor depends on (FLAGS/TV_FLAG bits drive lower/upper screen output).
//
//  The Z80's block moves and read-modify-writes do a read and a write in one
//  machine cycle with the address changing between them, which is the one
//  place the wrapper's T-state choices matter.
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_tv80;
    reg clk = 0;
    always #18.519 clk = ~clk;

    reg [5:0] acc = 6'd0;
    reg       ce  = 1'b0;
    always @(posedge clk) begin
        if (acc + 6'd7 >= 6'd54) begin acc <= acc + 6'd7 - 6'd54; ce <= 1'b1; end
        else begin acc <= acc + 6'd7; ce <= 1'b0; end
    end

    reg reset = 1'b1;

    wire [15:0] a;
    wire [7:0]  dout;
    wire        m1_n, iorq, no_read, write, rfsh_n, halt_n, busak_n, intcycle_n, IntE, stop;
    wire [6:0]  mc, ts;

    reg  [7:0]  mem [0:65535];
    reg  [7:0]  mem_q = 8'h00;
    reg  [7:0]  di_q = 8'h00;
    wire [7:0]  mem_dout = mem_q;
    wire        is_rd = !write && (mc[0] ? intcycle_n : (!iorq ? !no_read : 1'b1));
    wire        rd_strobe = ce && ts[2] && is_rd;
    wire        wr_pulse  = ce && ts[2] && write && !mc[0] && !iorq;
    wire [7:0]  di_bus = rd_strobe ? mem_dout : di_q;

    always @(posedge clk) begin
        mem_q <= mem[a];
        if (wr_pulse) mem[a] <= dout;
        if (reset) di_q <= 8'h00; else if (rd_strobe) di_q <= mem_dout;
    end

    tv80_core #(.Mode(0), .IOWait(1)) u_cpu (
        .reset_n(~reset), .clk(clk), .cen(ce),
        .wait_n(1'b1), .int_n(1'b1), .nmi_n(1'b1), .busrq_n(1'b1),
        .m1_n(m1_n), .iorq(iorq), .no_read(no_read), .write(write),
        .rfsh_n(rfsh_n), .halt_n(halt_n), .busak_n(busak_n),
        .A(a), .dinst(di_bus), .di(di_bus), .dout(dout),
        .mc(mc), .ts(ts), .intcycle_n(intcycle_n), .IntE(IntE), .stop(stop)
    );

    integer i;
    integer errors = 0;

    // program 1: EXX round trip + ED-group stores + LD DE,(nn)
    //   0000  21 34 12     LD HL,$1234
    //   0003  11 56 78     LD DE,$7856
    //   0006  01 9A BC     LD BC,$BC9A
    //   0009  D9           EXX
    //   000A  21 11 22     LD HL,$2211
    //   000D  11 33 44     LD DE,$4433
    //   0010  01 55 66     LD BC,$6655
    //   0013  D9           EXX
    //   0014  ED 43 00 40  LD (4000),BC
    //   0018  ED 53 02 40  LD (4002),DE
    //   001C  22 04 40     LD (4004),HL
    //   001F  D9           EXX
    //   0020  ED 43 06 40  LD (4006),BC   ; the shadow BC
    //   0024  ED 5B 08 40  LD DE,(4006)   ; read back into DE
    //   0028  76           HALT
    task load_prog1;
        begin
            for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
            mem[16'h0000] = 8'h21; mem[16'h0001] = 8'h34; mem[16'h0002] = 8'h12;
            mem[16'h0003] = 8'h11; mem[16'h0004] = 8'h56; mem[16'h0005] = 8'h78;
            mem[16'h0006] = 8'h01; mem[16'h0007] = 8'h9A; mem[16'h0008] = 8'hBC;
            mem[16'h0009] = 8'hD9;
            mem[16'h000A] = 8'h21; mem[16'h000B] = 8'h11; mem[16'h000C] = 8'h22;
            mem[16'h000D] = 8'h11; mem[16'h000E] = 8'h33; mem[16'h000F] = 8'h44;
            mem[16'h0010] = 8'h01; mem[16'h0011] = 8'h55; mem[16'h0012] = 8'h66;
            mem[16'h0013] = 8'hD9;
            mem[16'h0014] = 8'hED; mem[16'h0015] = 8'h43; mem[16'h0016] = 8'h00; mem[16'h0017] = 8'h40;
            mem[16'h0018] = 8'hED; mem[16'h0019] = 8'h53; mem[16'h001A] = 8'h02; mem[16'h001B] = 8'h40;
            mem[16'h001C] = 8'h22; mem[16'h001D] = 8'h04; mem[16'h001E] = 8'h40;
            mem[16'h001F] = 8'hD9;
            mem[16'h0020] = 8'hED; mem[16'h0021] = 8'h43; mem[16'h0022] = 8'h06; mem[16'h0023] = 8'h40;
            mem[16'h0024] = 8'hED; mem[16'h0025] = 8'h5B; mem[16'h0026] = 8'h06; mem[16'h0027] = 8'h40;
            mem[16'h0028] = 8'hED; mem[16'h0029] = 8'h53; mem[16'h002A] = 8'h08; mem[16'h002B] = 8'h40;
            mem[16'h002C] = 8'h76;
        end
    endtask

    // program 2: indexed BIT/SET/RES on IY, with distinct error markers
    //   0000  FD 21 00 40  LD IY,$4000
    //   0004  FD 36 01 01  LD (IY+1),$01
    //   0008  FD CB 01 46  BIT 0,(IY+1)   ; expect NZ (bit is 1)
    //   000C  20 06        JR NZ,$0014    ; ok
    //   000E  3E 0D        LD A,$0D       ; marker: first BIT broke
    //   0010  32 51 40     LD (4051),A
    //   0013  76           HALT
    //   0014  FD CB 01 86  RES 0,(IY+1)
    //   0018  FD CB 01 46  BIT 0,(IY+1)   ; expect Z (bit is 0)
    //   001C  28 06        JR Z,$0024     ; ok
    //   001E  3E 0E        LD A,$0E       ; marker: second BIT broke
    //   0020  32 51 40     LD (4051),A
    //   0023  76           HALT
    //   0024  3E 01        LD A,$01       ; success
    //   0026  32 50 40     LD (4050),A
    //   0029  76           HALT
    task load_prog2;
        begin
            for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
            mem[16'h0000] = 8'hFD; mem[16'h0001] = 8'h21;
            mem[16'h0002] = 8'h00; mem[16'h0003] = 8'h40;
            mem[16'h0004] = 8'hFD; mem[16'h0005] = 8'h36;
            mem[16'h0006] = 8'h01; mem[16'h0007] = 8'h01;
            mem[16'h0008] = 8'hFD; mem[16'h0009] = 8'hCB;
            mem[16'h000A] = 8'h01; mem[16'h000B] = 8'h46;
            mem[16'h000C] = 8'h20; mem[16'h000D] = 8'h06;
            mem[16'h000E] = 8'h3E; mem[16'h000F] = 8'h0D;
            mem[16'h0010] = 8'h32; mem[16'h0011] = 8'h51; mem[16'h0012] = 8'h40;
            mem[16'h0013] = 8'h76;
            mem[16'h0014] = 8'hFD; mem[16'h0015] = 8'hCB;
            mem[16'h0016] = 8'h01; mem[16'h0017] = 8'h86;
            mem[16'h0018] = 8'hFD; mem[16'h0019] = 8'hCB;
            mem[16'h001A] = 8'h01; mem[16'h001B] = 8'h46;
            mem[16'h001C] = 8'h28; mem[16'h001D] = 8'h06;
            mem[16'h001E] = 8'h3E; mem[16'h001F] = 8'h0E;
            mem[16'h0020] = 8'h32; mem[16'h0021] = 8'h51; mem[16'h0022] = 8'h40;
            mem[16'h0023] = 8'h76;
            mem[16'h0024] = 8'h3E; mem[16'h0025] = 8'h01;
            mem[16'h0026] = 8'h32; mem[16'h0027] = 8'h50; mem[16'h0028] = 8'h40;
            mem[16'h0029] = 8'h76;
        end
    endtask

    initial begin
        // ---------------- program 1 ----------------
        load_prog1;
        repeat (100) @(posedge clk);
        reset = 1'b0;
        #200us;

        $display("ED stores at 4000/4002/4004 (BC,DE,HL = BC9A,7856,1234): %02x %02x %02x %02x %02x %02x",
                 mem[16'h4000], mem[16'h4001], mem[16'h4002], mem[16'h4003],
                 mem[16'h4004], mem[16'h4005]);
        $display("shadow BC at 4006 (expect 55 66): %02x %02x; DE round trip at 4008: %02x %02x",
                 mem[16'h4006], mem[16'h4007], mem[16'h4008], mem[16'h4009]);

        if (mem[16'h4000] !== 8'h9A || mem[16'h4001] !== 8'hBC ||
            mem[16'h4002] !== 8'h56 || mem[16'h4003] !== 8'h78 ||
            mem[16'h4004] !== 8'h34 || mem[16'h4005] !== 8'h12) begin
            $display("FAIL: ED-group register stores are wrong");
            errors = errors + 1;
        end else
            $display("ok: ED-group stores");

        if (mem[16'h4006] !== 8'h55 || mem[16'h4007] !== 8'h66) begin
            $display("FAIL: the shadow BC did not survive EXX round trips");
            errors = errors + 1;
        end else
            $display("ok: shadow BC round trip");

        if (mem[16'h4008] !== 8'h55 || mem[16'h4009] !== 8'h66) begin
            $display("FAIL: LD DE,(nn) / LD (nn),DE round trip wrong");
            errors = errors + 1;
        end else
            $display("ok: LD DE,(nn) / LD (nn),DE");

        // ---------------- program 2 ----------------
        load_prog2;
        repeat (100) @(posedge clk);
        reset = 1'b1;
        repeat (100) @(posedge clk);
        reset = 1'b0;
        #200us;

        $display("IY bit ops: (IY+1)=%02x (expect 00 after SET then RES), A=%02x (expect 01)",
                 mem[16'h4001], u_cpu.ACC);
        $display("marker at 4050: %02x (expect 01 = success, 0D/0E = which BIT broke)",
                 mem[16'h4050]);

        if (mem[16'h4001] !== 8'h00 || mem[16'h4050] !== 8'h01) begin
            $display("FAIL: indexed BIT/SET/RES on IY misbehaved");
            errors = errors + 1;
        end else
            $display("ok: indexed BIT/SET/RES on IY");

        if (errors == 0) $display("PASS: tv80 directed tests");
        else $display("FAIL: %0d errors", errors);
        $finish;
    end

    initial begin
        #600us;
        $display("FAIL: watchdog (halt_n=%b)", halt_n);
        $finish;
    end

endmodule

`default_nettype wire
