// ============================================================================
//  zx_core.v -- a 48K ZX Spectrum: Z80, memory, ULA, keyboard, beeper
//
//  Memory map, exactly the 48K:
//      0x0000-0x3FFF  ROM (16K, roms/zx48.hex)
//      0x4000-0xFFFF  RAM (48K); the screen file and its attributes live at
//                     0x4000-0x5AFF inside it
//
//  One RAM for everything, one clock.  zx_video owns the RAM's address port
//  for the first 66 pixel clocks of each line (its 64-read prefetch window,
//  plus two settle clocks), and the CPU's 3.5 MHz enable is masked there --
//  about 7% of the frame, in the spirit of the real ULA's memory contention,
//  and invisible to the ROM.  Outside the window the address port belongs to
//  the CPU, whose address is stable for all 7-8 clocks between its enables:
//  that is what makes a synchronous (BSRAM) read work with tv80 -- the data
//  is always final by the T-state that samples it, so no wait states.
//
//  ULA (I/O on any even address, the real decoding is A0 = 0):
//      IN  0xFE   keyboard: bits 4:0 are the five columns of the row(s)
//                 selected by ~A[15:8], bit 6 the EAR (idle high), 5/7 = 1
//      OUT 0xFE   bits 2:0 border colour, bit 4 the beeper
//  Writes to ROM go nowhere, as on hardware.
//
//  Interrupts: 50 Hz from a 540 000-count divider, held for 32 T-states like
//  the ULA's /INT.  The video frame is 59.94 Hz, a different clock entirely,
//  which no 48K software can tell apart through BASIC.
// ============================================================================

`default_nettype none

module zx_core #(
    // where the 512x384 picture starts on the raster.  zx_top subtracts the
    // TV effect stage's pipeline latency (3 pixel clocks) here, so the picture
    // lands at x = 104..615 after the delay.
    parameter integer VID_X0 = 104
) (
    input  wire        clk,        // 27 MHz pixel clock
    input  wire        reset,      // active high
    input  wire        ce_cpu,     // 3.5 MHz enable (clk_gen)
    input  wire        ce_48k,     // 48 kHz enable (clk_gen)

    // the web keyboard (zx_input)
    input  wire        uart_rx,
    output wire        key_hit,

    // the tape player's EAR line (1 = idle high)
    input  wire        ear,
    input  wire [6:0]  tape_vol,     // the EAR's audio level, percent (ZXCONFIG.TXT VOL=)

    // the tape library's commands from the page (0xFB packets)
    output wire        lib_list,
    output wire        lib_sel,
    output wire [4:0]  lib_idx,
    output wire        lib_eject,
    output wire        lib_play,
    output wire        lib_pause,
    output wire        lib_rewind,
    output wire        cmd_instant,
    output wire [23:0] inst_off,
    output wire        cmd_version,

    // instant load interface from zx_tape_lib
    input  wire        instant_active,
    output reg         inst_pop = 1'b0,
    input  wire [7:0]  inst_byte,
    input  wire        inst_rd_empty,

    // the ROM has just entered LD-BYTES (0x0556): LOAD "" is running, so the
    // cassette should roll.  One pulse per entry.
    output wire        tape_load,

    // video: hdmi_tx's active-pixel coordinates and the picture
    input  wire [9:0]  vid_x,
    input  wire [9:0]  vid_y,
    output wire [23:0] vid_rgb,
    output wire        flash,

    // the beeper, sampled for HDMI audio
    output wire        audio_valid,
    output wire [15:0] audio_l,
    output wire [15:0] audio_r,

    // diagnostics
    output wire        halt_n,
    output wire        frame_tick,

    // screen capture over UART
    output wire        scr_capturing,
    output wire        scr_tx_req,
    output wire [7:0]  scr_tx_data,
    input  wire        scr_tx_busy,

    // SD card raw bridge
    input  wire        card_mode,
    output wire [7:0]  rx_byte_out,
    output wire        rx_valid_out
);
    // ------------------------------------------------------------------
    // CPU
    // ------------------------------------------------------------------
    wire [15:0] a;
    wire [7:0]  cpu_dout;
    wire        m1_n, iorq, no_read, write, rfsh_n, busak_n, intcycle_n, IntE, stop;
    wire [6:0]  mc, ts;
    wire        int_n;
    reg  [7:0]  rom_q = 8'hFF, ram_q = 8'hFF;
    wire [7:0]  mem_dout;     // opcode/data reads: final by the T-state that samples it
    wire [15:0] vram_addr;    // zx_video's screen-file address
    wire [7:0]  di_bus;       // what the CPU reads this T-state

    // The ULA owns the RAM while zx_video prefetches (x = 0..63).  Two
    // different boundaries, and they are not the same clock:
    //   * the ADDRESS MUX hands back to the CPU at x = 64 (the last video
    //     read is at x = 63);
    //   * the CPU's enable waits until x = 66, because the data a T-state
    //     samples at its edge was registered on the clock before it: with
    //     the mux switching at 64, the read is valid at 65 and the CPU may
    //     sample it from 66 on.  Gating both at the same x is the bug that
    //     corrupts one byte per line (the CPU latches the video's byte).
    wire        vid_window = (vid_x < 10'd64);
    wire        ce         = ce_cpu && (vid_x >= 10'd66) && !scr_capturing;

    // Snapshot (.Z80) Loader signals
    wire        snap_pause_cpu;
    wire        snap_cpu_reset_req;
    wire        snap_ram_wr;
    wire [15:0] snap_ram_addr;
    wire [7:0]  snap_ram_data;
    wire [2:0]  snap_border;
    wire        snap_border_set;
    wire        snap_boot_active;
    wire [7:0]  snap_boot_dout;
    wire        snap_busy;    // inside an FC packet: the stream is snapshot data
    wire        rx_valid_raw;

    wire port5b = (a[7:0] == 8'h5B);
    wire wait_tape_fifo = port5b && inst_rd_empty && iorq && !write && instant_active;

    tv80_core #(
        .Mode(0),      // Z80
        .IOWait(1)     // standard I/O cycle length
    ) u_cpu (
        .reset_n(~(reset | snap_cpu_reset_req)), .clk(clk), .cen(ce),
        .wait_n(~wait_tape_fifo),
        .int_n(int_n), .nmi_n(1'b1), .busrq_n(~snap_pause_cpu),
        .m1_n(m1_n), .iorq(iorq), .no_read(no_read), .write(write),
        .rfsh_n(rfsh_n), .halt_n(halt_n), .busak_n(busak_n),
        .A(a), .dinst(di_bus), .di(di_bus), .dout(cpu_dout),
        .mc(mc), .ts(ts), .intcycle_n(intcycle_n), .IntE(IntE), .stop(stop)
    );

    // ------------------------------------------------------------------
    // The tape trigger: the ROM's LD-BYTES entry (0x0556) fetched as an
    // opcode.  LOAD "", LOAD "name", VERIFY and MERGE all pass through it, so
    // this is "the Spectrum is asking for the tape now".
    // ------------------------------------------------------------------
    assign tape_load = !m1_n && (a == 16'h0556);

    // ------------------------------------------------------------------
    // Memory
    // ------------------------------------------------------------------
    reg [7:0] rom [0:16383];
    reg [7:0] ram [0:49151];

    initial $readmemh("roms/zx48.hex", rom);

    // RAM contents at power-up: real chips come up with random bits, emulators
    // come up zeroed, and the ROM boots on either (it reads 0xFFFF before it
    // writes -- on sim's X that read would poison the CPU).  Zeroed, like Fuse.
    // Simulation only: real BSRAM powers up zeroed anyway, and Gowin unrolls
    // initial loops with a 2000-iteration cap.
    // synthesis translate_off
    integer ri;
    initial for (ri = 0; ri < 49152; ri = ri + 1) ram[ri] = 8'h00;
    // synthesis translate_on

    wire is_rom = (a[15:14] == 2'b00);

    // clamped so a ROM-addressed read cannot index past the array in sim
    wire in_ram = a[15] | a[14];
    wire [15:0] cpu_ram_a = in_ram ? (a - 16'h4000) : 16'd0;
    wire [15:0] vid_ram_a = vram_addr - 16'h4000;
    wire        scr_cap_req;
    wire [15:0] scr_ram_a;
    reg  [2:0]  border = 3'd0;
    reg         flash_r = 1'b0;

    zx_scr_cap u_scr_cap (
        .clk(clk),
        .reset(reset),
        .cap_req(scr_cap_req),
        .border(border),
        .flash(flash_r),
        .vid_busy(vid_window),
        .ram_addr(scr_ram_a),
        .ram_rdata(ram_q),
        .capturing(scr_capturing),
        .pause_cpu(),
        .tx_req(scr_tx_req),
        .tx_data(scr_tx_data),
        .tx_busy(scr_tx_busy)
    );

    wire [15:0] ram_raddr = vid_window ? vid_ram_a : (scr_capturing ? scr_ram_a : cpu_ram_a);

    // one write strobe per machine cycle, on its T3 -- `write` is a
    // machine-cycle constant from the microcode, so ts[2] catches it once
    wire wr_pulse = ce && ts[2] && write && !mc[0] && !iorq;

    always @(posedge clk) begin
        rom_q <= rom[a[13:0]];
        ram_q <= ram[ram_raddr];
        if (snap_ram_wr)
            ram[snap_ram_addr] <= snap_ram_data;
        else if (wr_pulse && !is_rom)
            ram[cpu_ram_a] <= cpu_dout;
    end

    // ------------------------------------------------------------------
    // Instant load, DivMMC style: while it is armed, LD-BYTES from 0x0562
    // reads as this routine, which takes the .TAP's bytes from port 0x5B
    // instead of timing edges.  0x0562 is DivMMC's load trap too: by then the
    // ROM has put the flag and CF = LOAD (NC VERIFY) in AF', done DI, set the
    // border and pushed SA/LD-RET (0x053F: border back, BREAK check, EI), so
    // the routine only moves DE bytes to IX and RETs with CF = ok.  A block whose flag does not
    // match, or that VERIFY rejects, is read to its end and fails, so the
    // next call starts on the next block -- LOAD "name" passes over other
    // files as on a real tape.  Past the end the port reads 00 00 as the
    // length: NC, and the ROM keeps looking until BREAK.
    // ponytail: ROM loads only -- a custom loader that jumps into the middle
    // of LD-BYTES lands in this routine.  The page arms it at the part of
    // the .TAP its own run stopped at (web/src/tape-snapshot.js).
    // ------------------------------------------------------------------
    function [7:0] trap_byte(input [6:0] off);
        case (off)
            7'h00: trap_byte = 8'hDB;  // IN A,($5B)       ; block length
            7'h01: trap_byte = 8'h5B;
            7'h02: trap_byte = 8'h4F;  // LD C,A
            7'h03: trap_byte = 8'hDB;  // IN A,($5B)
            7'h04: trap_byte = 8'h5B;
            7'h05: trap_byte = 8'h47;  // LD B,A
            7'h06: trap_byte = 8'hB1;  // OR C
            7'h07: trap_byte = 8'hC8;  // RET Z            ; the tape's end (NC)
            7'h08: trap_byte = 8'hDB;  // IN A,($5B)       ; the block's flag
            7'h09: trap_byte = 8'h5B;
            7'h0A: trap_byte = 8'h0B;  // DEC BC
            7'h0B: trap_byte = 8'h6F;  // LD L,A
            7'h0C: trap_byte = 8'h08;  // EX AF,AF'
            7'h0D: trap_byte = 8'h67;  // LD H,A           ; wanted flag, and the xor's seed
            7'h0E: trap_byte = 8'h9F;  // SBC A,A          ; FF load, 00 verify
            7'h0F: trap_byte = 8'h08;  // EX AF,AF'
            7'h10: trap_byte = 8'h7C;  // LD A,H
            7'h11: trap_byte = 8'hBD;  // CP L
            7'h12: trap_byte = 8'h20;  // JR NZ,skip
            7'h13: trap_byte = 8'h3A;
            7'h14: trap_byte = 8'h08;  // EX AF,AF'
            7'h15: trap_byte = 8'hB7;  // OR A
            7'h16: trap_byte = 8'h28;  // JR Z,verify
            7'h17: trap_byte = 8'h14;
            // load: DE bytes to (IX+)
            7'h18: trap_byte = 8'h7A;  // LD A,D
            7'h19: trap_byte = 8'hB3;  // OR E
            7'h1A: trap_byte = 8'h28;  // JR Z,done
            7'h1B: trap_byte = 8'h28;
            7'h1C: trap_byte = 8'h78;  // LD A,B
            7'h1D: trap_byte = 8'hB1;  // OR C
            7'h1E: trap_byte = 8'hC8;  // RET Z            ; block too short (NC)
            7'h1F: trap_byte = 8'hDB;  // IN A,($5B)
            7'h20: trap_byte = 8'h5B;
            7'h21: trap_byte = 8'h0B;  // DEC BC
            7'h22: trap_byte = 8'hDD;  // LD (IX+0),A
            7'h23: trap_byte = 8'h77;
            7'h24: trap_byte = 8'h00;
            7'h25: trap_byte = 8'hAC;  // XOR H
            7'h26: trap_byte = 8'h67;  // LD H,A
            7'h27: trap_byte = 8'hDD;  // INC IX
            7'h28: trap_byte = 8'h23;
            7'h29: trap_byte = 8'h1B;  // DEC DE
            7'h2A: trap_byte = 8'h18;  // JR load
            7'h2B: trap_byte = 8'hEC;
            // verify: DE bytes against (IX+)
            7'h2C: trap_byte = 8'h7A;  // LD A,D
            7'h2D: trap_byte = 8'hB3;  // OR E
            7'h2E: trap_byte = 8'h28;  // JR Z,done
            7'h2F: trap_byte = 8'h14;
            7'h30: trap_byte = 8'h78;  // LD A,B
            7'h31: trap_byte = 8'hB1;  // OR C
            7'h32: trap_byte = 8'hC8;  // RET Z
            7'h33: trap_byte = 8'hDB;  // IN A,($5B)
            7'h34: trap_byte = 8'h5B;
            7'h35: trap_byte = 8'h0B;  // DEC BC
            7'h36: trap_byte = 8'h6F;  // LD L,A
            7'h37: trap_byte = 8'hAC;  // XOR H
            7'h38: trap_byte = 8'h67;  // LD H,A
            7'h39: trap_byte = 8'hDD;  // LD A,(IX+0)
            7'h3A: trap_byte = 8'h7E;
            7'h3B: trap_byte = 8'h00;
            7'h3C: trap_byte = 8'hBD;  // CP L
            7'h3D: trap_byte = 8'h20;  // JR NZ,skip
            7'h3E: trap_byte = 8'h0F;
            7'h3F: trap_byte = 8'hDD;  // INC IX
            7'h40: trap_byte = 8'h23;
            7'h41: trap_byte = 8'h1B;  // DEC DE
            7'h42: trap_byte = 8'h18;  // JR verify
            7'h43: trap_byte = 8'hE8;
            // done: the checksum byte
            7'h44: trap_byte = 8'h78;  // LD A,B
            7'h45: trap_byte = 8'hB1;  // OR C
            7'h46: trap_byte = 8'hC8;  // RET Z            ; no checksum (NC)
            7'h47: trap_byte = 8'hDB;  // IN A,($5B)
            7'h48: trap_byte = 8'h5B;
            7'h49: trap_byte = 8'h0B;  // DEC BC
            7'h4A: trap_byte = 8'hAC;  // XOR H
            7'h4B: trap_byte = 8'h67;  // LD H,A           ; 0 when the parity is good
            7'h4C: trap_byte = 8'h18;  // JR drain
            7'h4D: trap_byte = 8'h02;
            // skip: fail, once the block is read out
            7'h4E: trap_byte = 8'h26;  // LD H,$FF
            7'h4F: trap_byte = 8'hFF;
            // drain: the rest of the block
            7'h50: trap_byte = 8'h78;  // LD A,B
            7'h51: trap_byte = 8'hB1;  // OR C
            7'h52: trap_byte = 8'h28;  // JR Z,fin
            7'h53: trap_byte = 8'h05;
            7'h54: trap_byte = 8'hDB;  // IN A,($5B)
            7'h55: trap_byte = 8'h5B;
            7'h56: trap_byte = 8'h0B;  // DEC BC
            7'h57: trap_byte = 8'h18;  // JR drain
            7'h58: trap_byte = 8'hF7;
            // fin: CF = (H == 0), as the ROM ends LD-BYTES
            7'h59: trap_byte = 8'h7C;  // LD A,H
            7'h5A: trap_byte = 8'hFE;  // CP $01
            7'h5B: trap_byte = 8'h01;
            7'h5C: trap_byte = 8'hC9;  // RET
            default: trap_byte = 8'hC9;  // RET
        endcase
    endfunction

    wire [15:0] trap_off = a - 16'h0562;
    wire        in_trap  = instant_active && (trap_off < 16'd93);

    wire [7:0] effective_rom_q = in_trap ? trap_byte(trap_off[6:0]) : rom_q;

    assign mem_dout = (snap_boot_active && a < 16'd64) ? snap_boot_dout :
                      is_rom ? effective_rom_q : ram_q;

    // ------------------------------------------------------------------
    // ULA ports
    // ------------------------------------------------------------------
    wire [39:0] vk_matrix;

    zx_snap u_snap (
        .clk(clk),
        .reset(reset),
        .rx_valid(rx_valid_raw),
        .rx_byte(rx_byte_out),
        .pause_cpu(snap_pause_cpu),
        .cpu_reset_req(snap_cpu_reset_req),
        .ram_wr(snap_ram_wr),
        .ram_addr(snap_ram_addr),
        .ram_data(snap_ram_data),
        .border(snap_border),
        .border_set(snap_border_set),
        .cpu_addr(a),
        .cpu_m1_n(m1_n),
        .boot_active(snap_boot_active),
        .boot_dout(snap_boot_dout),
        .busy(snap_busy)
    );

    // the card bridge downstream must not see snapshot data either
    assign rx_valid_out = rx_valid_raw && !snap_busy;

    wire tape_mon;
    zx_input u_keys (
        .clk(clk), .reset(reset), .uart_rx(uart_rx),
        .vk_matrix(vk_matrix), .key_hit(key_hit),
        .lib_list(lib_list), .lib_sel(lib_sel), .lib_idx(lib_idx),
        .lib_eject(lib_eject), .lib_play(lib_play),
        .lib_pause(lib_pause), .lib_rewind(lib_rewind),
        .cmd_instant(cmd_instant), .inst_off(inst_off),
        .cmd_version(cmd_version),
        .tape_mon(tape_mon),
        .scr_req(scr_cap_req),
        .card_mode(card_mode),
        .hold(snap_busy),
        .rx_byte_out(rx_byte_out),
        .rx_valid_out(rx_valid_raw)
    );

    // pressed keys of every row the address selects (bit low = row driven);
    // 1 = pressed, as the columns of a real matrix read back
    reg [4:0] keys_c;
    integer r;
    always @* begin
        keys_c = 5'd0;
        for (r = 0; r < 8; r = r + 1)
            if (!a[8 + r]) keys_c = keys_c | vk_matrix[5*r +: 5];
    end

    wire io_rd  = iorq && intcycle_n && !write && !no_read;
    wire io_wr  = iorq && intcycle_n &&  write && ce && ts[2];
    wire ula    = !a[0];

    // one pop per IN A,($5B), as its I/O cycle ends: ts[2] repeats through
    // tv80's I/O wait state and through a wait_n stall, so it cannot count
    wire io5b = io_rd && port5b && instant_active;
    reg  io5b_q = 1'b0;
    always @(posedge clk) begin
        io5b_q   <= io5b && !reset;
        inst_pop <= io5b_q && !io5b && !reset;
    end

    wire [7:0] io_dout = io5b ? inst_byte :
                         (io_rd && ula) ? {1'b1, ear, 1'b1, ~keys_c} : 8'hFF;   // EAR is bit 6: LD-SAMPLE does RRA, AND $20

    // ------------------------------------------------------------------
    // The read bus
    //
    // tv80 takes a read's byte home one T-state after the data phase, from
    // DI_Reg -- which is `di` live, not a latched value.  By then the address
    // has moved on to the next fetch, so `di` must be LIVE during the read's
    // T3 and HELD afterwards: exactly the latch the sibling project's SoftCard
    // wraps around tv80.  Without it every register load takes the next
    // opcode as its data (the RAM fill's `LD (HL),n` then writes opcode bytes,
    // and `LD A,n` loads them).
    // ------------------------------------------------------------------
    reg  [7:0] di_q = 8'h00;
    wire [7:0] bus_now = iorq ? io_dout : mem_dout;
    wire       is_rd = !write &&
                       (mc[0] ? intcycle_n :
                        (!iorq ? !no_read : (intcycle_n && !no_read)));
    wire       rd_strobe = ce && ts[2] && is_rd;

    assign di_bus = rd_strobe ? bus_now : di_q;

    always @(posedge clk) begin
        if (reset)          di_q <= 8'h00;
        else if (rd_strobe) di_q <= bus_now;
    end


    reg       beeper = 1'b0;
    always @(posedge clk) begin
        if (reset) begin
            border <= 3'd0;
            beeper <= 1'b0;
        end else if (snap_border_set) begin
            border <= snap_border;
        end else if (io_wr && ula) begin
            border <= cpu_dout[2:0];
            beeper <= cpu_dout[4];
        end
    end

    // ------------------------------------------------------------------
    // Interrupts: 50 Hz, held 32 T-states
    // ------------------------------------------------------------------
    localparam [19:0] FRAME_CLKS = 20'd540000;   // 27 MHz / 50 Hz
    reg  [19:0] frame_cnt = 20'd0;
    reg  [5:0]  int_cnt   = 6'd0;

    assign frame_tick = (frame_cnt == FRAME_CLKS - 20'd1);

    always @(posedge clk) begin
        if (reset) begin
            frame_cnt <= 20'd0;
            int_cnt   <= 6'd0;
        end else if (frame_tick) begin
            frame_cnt <= 20'd0;
            int_cnt   <= 6'd32;
        end else begin
            frame_cnt <= frame_cnt + 20'd1;
            if (ce && int_cnt != 6'd0) int_cnt <= int_cnt - 6'd1;
        end
    end
    assign int_n = (int_cnt == 6'd0);

    // ------------------------------------------------------------------
    // Video
    // ------------------------------------------------------------------

    // FLASH blinks ~1.5 Hz: every 16 video frames (the frame rate is
    // 59.94 Hz, close enough to the ULA's 25 Hz toggle to be the same thing).
    reg [4:0] flash_cnt = 5'd0;
    always @(posedge clk) begin
        if (reset) begin
            flash_cnt <= 5'd0;
            flash_r   <= 1'b0;
        end else if (vid_x == 10'd0 && vid_y == 10'd0) begin
            flash_cnt <= flash_cnt + 5'd1;
            if (flash_cnt == 5'd15) flash_r <= ~flash_r;
        end
    end
    assign flash = flash_r;

    zx_video #(.X0(VID_X0)) u_video (
        .clk(clk), .x(vid_x), .y(vid_y),
        .border(border), .flash(flash_r),
        .vram_addr(vram_addr), .vram_data(ram_q),
        .rgb(vid_rgb)
    );

    // ------------------------------------------------------------------
    // Beeper -> HDMI audio: one stereo frame per 48 kHz enable, the 1-bit
    // speaker as a square wave
    // ------------------------------------------------------------------
    // With the page's monitor switch on, the EAR is mixed in at tape_vol
    // percent of full scale (327 a percent), as the ULA feeds EAR to the
    // speaker; the sum saturates, since 100% plus the beeper overflows.
    wire        [15:0] tape_amp = tape_vol * 9'd327;
    wire signed [17:0] tape_lvl = !tape_mon ? 18'sd0 : ear ? $signed({2'b00, tape_amp}) : -$signed({2'b00, tape_amp});
    wire signed [17:0] mix      = (beeper ? 18'sd7000 : -18'sd7000) + tape_lvl;
    reg audio_valid_r = 1'b0;
    reg [15:0] audio_lvl = -16'sd7000;
    always @(posedge clk) begin
        if (reset) begin
            audio_valid_r <= 1'b0;
            audio_lvl     <= -16'sd7000;
        end else begin
            audio_valid_r <= 1'b0;
            if (ce_48k) begin
                audio_valid_r <= 1'b1;
                audio_lvl     <= mix > 18'sd32767  ? 16'h7FFF :
                                 mix < -18'sd32768 ? 16'h8000 : mix[15:0];
            end
        end
    end
    assign audio_valid = audio_valid_r;
    assign audio_l     = audio_lvl;
    assign audio_r     = audio_lvl;

endmodule

`default_nettype wire
