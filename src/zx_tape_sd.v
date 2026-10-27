// ============================================================================
//  zx_tape_sd.v -- TAPE.TAP off the microSD card, played into the ULA's EAR
//
//  The FAT32 work is the sibling project's (src/sd/sd_vol.v, vendored and
//  patched only where a .TAP replaces a floppy image): it mounts the card,
//  finds the file named by A2CONFIG.TXT's S6D1= entry and streams it byte for
//  byte on its f_up_* port, stalling whenever f_up_busy is high.  That port is
//  a byte stream with flow control, which is exactly a cassette.
//
//  So this wrapper is only the join:
//
//      card setup:  A2CONFIG.TXT   ->   S6D1=TAPE.TAP
//                   TAPE.TAP       ->   the tape image (8.3 name, < 1 MB)
//
//      sd_vol f_up_* --4-byte FIFO--> tap_player --EAR--> ULA port 0xFE bit 6
//
//  The FIFO is held empty (f_up_busy) until the start timer expires, so the
//  stream begins *at the file's first byte* when the tape should roll: reset
//  the Spectrum, type LOAD "" and press ENTER inside the leader tone.  The
//  timer is deliberately long: the ZX needs ~2 s to boot and the pilot is ~5 s.
// ============================================================================
`default_nettype none

module zx_tape_sd (
    input  wire        clk,                  // 27 MHz
    input  wire        reset,
    input  wire        ce_cpu,               // 3.5 MHz T-state tick
    input  wire        tape_load,            // pulse: the ROM entered LD-BYTES
    input  wire        auto_play,            // DIP5: roll without waiting

    input  wire        sd_miso,
    output wire        sd_clk,
    output wire        sd_mosi,
    output wire        sd_cs_n,

    output wire        ear,
    output wire        playing,
    output wire        card_ok,
    output wire        tape_ok,
    output wire        busy
);
    // ---- when the tape starts rolling --------------------------------
    // The cassette is on hold: the stream begins when the ROM runs LD-BYTES
    // (i.e. LOAD "" was entered), which is the normal cassette behaviour --
    // press LOAD, the deck starts.  DIP5 skips the wait and rolls from reset.
    reg load_seen = 1'b0;
    always @(posedge clk) begin
        if (reset)          load_seen <= 1'b0;
        else if (tape_load) load_seen <= 1'b1;
    end
    wire start_ok = auto_play | load_seen;

    // ---- the byte stream: 4-deep FIFO with flow control --------------
    reg [7:0]  fifo [0:3];
    reg [1:0]  f_rd = 2'd0, f_wr = 2'd0;
    wire [1:0] f_cnt = f_wr - f_rd;
    wire       f_empty = (f_cnt == 2'd0);
    wire       f_full  = (f_cnt == 2'd3);

    reg        up_done = 1'b0;
    // stall the card until the tape is due, and whenever the FIFO is full
    wire       up_busy = !start_ok || f_full;

    // ---- the vendored FAT32 volume manager ---------------------------
    wire        f_up_go;
    wire        f_up_drive;
    wire [19:0] f_up_addr;
    wire [7:0]  f_up_data;
    wire        f_up_last;
    wire        f_up_ro, f_up_bad;
    wire [3:0]  present, fail;
    wire        fs_ok, loading, sd_busy, sd_err;
    wire [2:0]  estage;
    wire [15:0] hd_size0, hd_size1;
    wire        rb_ok, x_take, r_valid, r_done, r_ok;
    wire [7:0]  r_byte;

    sd_vol #(
        .PWR_BITS(20),                       // ~39 ms card power-up wait
        .FAST_HALF(7'd0)                     // 13.5 MHz SPI after init
    ) u_sd (
        .clk(clk), .reset(reset),
        .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs_n(sd_cs_n),

        // no DDR3 client, no floppy store: answer everything immediately
        .ddr_ready(1'b1),
        .m_go(), .m_addr(), .m_we(), .m_wdata(), .m_rdata(16'h0000), .m_ack(1'b1),

        .f_up_go(f_up_go), .f_up_drive(f_up_drive), .f_up_addr(f_up_addr),
        .f_up_data(f_up_data), .f_up_last(f_up_last),
        .f_up_ro(f_up_ro), .f_up_bad(f_up_bad),
        .f_up_busy(up_busy), .f_up_done(up_done),
        .f_dn_go(), .f_dn_drive(), .f_dn_addr(), .f_dn_data(8'h00), .f_dn_valid(1'b0),
        .fl_wr(1'b0), .fl_wr_drv(1'b0), .fl_wr_blk(11'd0), .bg_hold(1'b1),

        .present(present), .fail(fail), .fs_ok(fs_ok),
        .loading(loading), .busy(sd_busy), .err(sd_err), .estage(estage),

        .wb_go(1'b0), .wb_drv(1'b0), .wb_blk(16'd0), .rb_go(1'b0), .rb_ok(rb_ok),
        .hd_size0(hd_size0), .hd_size1(hd_size1),
        .mnt_go(1'b0), .mnt_drv(2'd0),

        .x_go(1'b0), .x_lba(32'd0), .x_zero(1'b0), .x_byte(8'd0), .x_valid(1'b0),
        .x_take(x_take),

        .r_go(1'b0), .r_lba(32'd0), .r_cnt(16'd0), .r_byte(r_byte),
        .r_valid(r_valid), .r_take(1'b1), .r_done(r_done), .r_ok(r_ok)
    );

    always @(posedge clk) begin
        up_done <= 1'b0;
        if (f_up_go && !f_full && start_ok) begin
            fifo[f_wr] <= f_up_data;
            f_wr <= f_wr + 2'd1;
            up_done <= 1'b1;                 // sd_vol drops f_up_go on this
        end
    end

    // ---- the player --------------------------------------------------
    reg  [7:0]  rd_hold = 8'h00;
    reg         tap_start = 1'b0;
    reg         started = 1'b0;
    wire        tap_rd_req;
    wire [9:0]  tap_idx;
    wire        tap_sector_done;

    always @(posedge clk) begin
        if (tap_rd_req && !f_empty) begin
            rd_hold <= fifo[f_rd];
            f_rd    <= f_rd + 2'd1;
        end
    end

    tap_player u_player (
        .clk(clk), .reset(reset), .ce_t(ce_cpu),
        .start(tap_start), .playing(playing),
        .idx(tap_idx), .rd_req(tap_rd_req), .rd_data(rd_hold),
        .buf_ready(!f_empty), .sector_done(tap_sector_done),
        .ear(ear), .done()
    );

    // start the player once, when the tape is due
    always @(posedge clk) begin
        if (reset) begin
            tap_start <= 1'b0;
            started   <= 1'b0;
        end else begin
            tap_start <= 1'b0;
            if (start_ok && !started) begin
                tap_start <= 1'b1;
                started   <= 1'b1;
            end
        end
    end

    assign card_ok = fs_ok;
    assign tape_ok = present[0];
    assign busy    = loading | sd_busy;

endmodule

`default_nettype wire
