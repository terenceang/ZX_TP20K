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

    // ROM trap for Instant Load at 0x0556 (LD-BYTES)
    function [7:0] trap_rom_byte(input [4:0] off);
        case (off)
            5'd0:  trap_rom_byte = 8'h08; // EX AF, AF'
            5'd1:  trap_rom_byte = 8'h30; // JR NC, +24
            5'd2:  trap_rom_byte = 8'h18;
            5'd3:  trap_rom_byte = 8'hDB; // IN A, (5B)
            5'd4:  trap_rom_byte = 8'h5B;
            5'd5:  trap_rom_byte = 8'hDB; // IN A, (5B)
            5'd6:  trap_rom_byte = 8'h5B;
            5'd7:  trap_rom_byte = 8'hDB; // IN A, (5B) - flag
            5'd8:  trap_rom_byte = 8'h5B;
            // loop:
            5'd9:  trap_rom_byte = 8'h7A; // LD A, D
            5'd10: trap_rom_byte = 8'hB3; // OR E
            5'd11: trap_rom_byte = 8'h28; // JR Z, +10 (done)
            5'd12: trap_rom_byte = 8'h0A;
            5'd13: trap_rom_byte = 8'hDB; // IN A, (5B) - payload
            5'd14: trap_rom_byte = 8'h5B;
            5'd15: trap_rom_byte = 8'hDD; // LD (IX+0), A
            5'd16: trap_rom_byte = 8'h77;
            5'd17: trap_rom_byte = 8'h00;
            5'd18: trap_rom_byte = 8'hDD; // INC IX
            5'd19: trap_rom_byte = 8'h23;
            5'd20: trap_rom_byte = 8'h1B; // DEC DE
            5'd21: trap_rom_byte = 8'h18; // JR loop (-14)
            5'd22: trap_rom_byte = 8'hF2;
            // done:
            5'd23: trap_rom_byte = 8'hDB; // IN A, (5B) - checksum
            5'd24: trap_rom_byte = 8'h5B;
            5'd25: trap_rom_byte = 8'h37; // SCF
            5'd26: trap_rom_byte = 8'hC9; // RET
            // verify exit:
            5'd27: trap_rom_byte = 8'h37; // SCF
            5'd28: trap_rom_byte = 8'hC9; // RET
            default: trap_rom_byte = 8'h00; // NOP
        endcase
    endfunction

    wire in_trap_range = (a >= 16'h0556) && (a <= 16'h0572);
    wire [4:0] trap_offset = a[4:0] - 5'h16; // 0x556 & 0x1F = 0x16

    wire [7:0] effective_rom_q = (instant_active && in_trap_range) ?
                                 trap_rom_byte(trap_offset) : rom_q;

    assign mem_dout = (snap_boot_active && a < 16'd64) ? snap_boot_dout :
                      is_rom ? effective_rom_q : ram_q;

    // ------------------------------------------------------------------
    // ULA ports
    // ------------------------------------------------------------------
    wire [39:0] vk_matrix;

    zx_snap u_snap (
        .clk(clk),
        .reset(reset),
        .rx_valid(rx_valid_out),
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
        .boot_dout(snap_boot_dout)
    );

    wire tape_mon;
    zx_input u_keys (
        .clk(clk), .reset(reset), .uart_rx(uart_rx),
        .vk_matrix(vk_matrix), .key_hit(key_hit),
        .lib_list(lib_list), .lib_sel(lib_sel), .lib_idx(lib_idx),
        .lib_eject(lib_eject), .lib_play(lib_play),
        .lib_pause(lib_pause), .lib_rewind(lib_rewind),
        .cmd_instant(cmd_instant),
        .cmd_version(cmd_version),
        .tape_mon(tape_mon),
        .scr_req(scr_cap_req),
        .card_mode(card_mode),
        .rx_byte_out(rx_byte_out),
        .rx_valid_out(rx_valid_out)
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

    always @(posedge clk) begin
        if (reset) inst_pop <= 1'b0;
        else       inst_pop <= io_rd && port5b && ce && ts[2];
    end

    wire [7:0] io_dout = (io_rd && port5b) ? inst_byte :
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
