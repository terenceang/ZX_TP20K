// ============================================================================
//  zx_tape_lib.v -- the card's tape library, and the deck that plays it
//
//  The card holds the tapes; the DDR3 holds the one in the player.  This
//  module is the join:
//
//      card  â”€â”€ sd_vol (FAT32) â”€â”€ list every .TAP â”€â”€â–¶ UART to the page
//                                 â”‚
//                                 â””â”€ stream the chosen file â”€â”€â–¶ zx_tape_mem
//                                                                   â”‚
//                                    tap_player â—€â”€â”€ one byte at a time
//                                        â”‚
//                                       EAR â”€â”€â–¶ zx_core
//
//  The page may only pick from what the card holds: 0xFB 53 <idx> names an
//  entry the board itself listed.  Nothing is pushed from the computer.
//
//  Board -> page frames (web/src/protocol.js is the other end):
//
//      0xF7 <len> <nameâ€¦> <size le32>   one library entry
//      0xF6 <count>                     end of the list
//      0xF8 <state>                     the deck's state (6: paused)
//      0xF9 <idx> <pos le24> <len le32> how far the tape has got
// ============================================================================
`default_nettype none

module zx_tape_lib (
    input  wire        clk,                  // 27 MHz
    input  wire        reset,
    input  wire        ce_cpu,               // 3.5 MHz T-state tick

    input  wire        tape_load,            // pulse: the ROM entered LD-BYTES
    input  wire        auto_play,            // DIP5: roll without waiting

    // the page's commands (pulses from zx_input)
    input  wire        cmd_list,
    input  wire        cmd_select,
    input  wire [4:0]  cmd_idx,
    input  wire        cmd_eject,
    input  wire        cmd_play,
    input  wire        cmd_pause,            // toggle: hold the tape where it is
    input  wire        cmd_rewind,           // back to the start, stopped (READY)

    // instant load commands and data interface
    input  wire        cmd_instant,
    input  wire [23:0] inst_off,             // where the trap starts reading
    input  wire        cmd_version,
    input  wire        inst_pop,
    output wire [7:0]  inst_byte,
    output wire        inst_rd_empty,
    output reg         instant_active = 1'b0,

    // SD card
    input  wire        sd_miso,
    output wire        sd_clk,
    output wire        sd_mosi,
    output wire        sd_cs_n,

    // the image in DDR3 (zx_tape_mem)
    output wire        store_clear,
    output wire        store_rewind,
    output wire        wr_valid,
    output wire [7:0]  wr_byte,
    input  wire        wr_ready,
    output reg  [23:0] img_len,
    input  wire [23:0] wr_count,
    input  wire        img_ready,
    input  wire        rd_empty,
    input  wire [7:0]  rd_byte,
    output wire        rd_pop,
    input  wire [23:0] rd_count,

    // UART transmitter (zx_uart_tx)
    output wire        tx_req,
    output wire [7:0]  tx_data,
    input  wire        tx_busy,

    // Raw UART stream and mode from/to zx_core
    input  wire [7:0]  rx_byte,
    input  wire        rx_valid,
    output wire        card_mode,

    // to the rest of the machine
    output wire        ear,
    output wire        playing,
    output wire        card_ok,
    output wire [6:0]  vol,          // ZXCONFIG.TXT's VOL=, percent (5 by default)
    output wire        busy
);
    // deck states, the same numbers the page draws
    localparam [2:0] S_EMPTY = 3'd0, S_LOAD = 3'd1, S_READY = 3'd2,
                     S_PLAY = 3'd3, S_END = 3'd4, S_ERR = 3'd5, S_PAUSE = 3'd6;

    // ==================================================================
    // The card: sd_vol in its library build
    // ==================================================================
    reg         lib_go = 1'b0, lib_find = 1'b0;
    reg  [4:0]  sel_idx = 5'd0;
    wire [4:0]  lib_count;
    wire [87:0] lib_name;
    wire [31:0] lib_size;
    wire        lib_ent, lib_done, lib_found, lib_fail;
    wire [87:0] d0_name;
    wire [31:0] d0_size;

    wire        f_up_go;
    wire        f_up_drive;
    wire [19:0] f_up_addr;
    wire [7:0]  f_up_data;
    wire        f_up_last;
    wire        f_up_ro, f_up_bad;
    reg         f_up_done = 1'b0;
    wire        f_up_busy = !wr_ready;      // the store sets the pace

    wire [3:0]  present, fail;
    wire        fs_ok, sd_loading, sd_busy, sd_err;
    wire [2:0]  estage;
    wire [15:0] hd_size0, hd_size1;
    wire        rb_ok, x_take, r_valid, r_done, r_ok;
    wire [7:0]  r_byte;

    // Queue state declarations needed for lib_busy
    reg [2:0]   q_n = 3'd0;
    wire        lib_busy = (q_n >= 3'd2);

    // Reinit SD controller if cmd_list arrives while not mounted

    wire        sd_reset = reset;

    // sd_raw_bridge connections
    wire        bridge_card_mode;
    wire        bridge_tx_req;
    wire [7:0]  bridge_tx_data;
    wire        bridge_x_go;
    wire [31:0] bridge_x_lba;
    wire        bridge_x_zero;
    wire [7:0]  bridge_x_byte;
    wire        bridge_x_valid;
    wire        bridge_r_go;
    wire [31:0] bridge_r_lba;
    wire [15:0] bridge_r_cnt;
    wire        bridge_r_take;

    wire [15:0] sd_stat = {sd_loading, sd_busy, sd_err, estage[2:0], fs_ok, 1'b0, fail[3:0], present[3:0]};

    sd_raw_bridge u_bridge (
        .clk(clk), .reset(reset),
        .rx_byte(rx_byte), .rx_valid(rx_valid),
        .cmd_version(cmd_version),
        .card_mode(bridge_card_mode),
        .tx_req(bridge_tx_req), .tx_data(bridge_tx_data), .tx_busy(tx_busy),
        .sd_stat(sd_stat), .sd_busy(sd_busy), .sd_err(sd_err), .sd_fs_ok(fs_ok),
        .sd_x_go(bridge_x_go), .sd_x_lba(bridge_x_lba), .sd_x_zero(bridge_x_zero),
        .sd_x_byte(bridge_x_byte), .sd_x_valid(bridge_x_valid), .sd_x_take(x_take),
        .sd_r_go(bridge_r_go), .sd_r_lba(bridge_r_lba), .sd_r_cnt(bridge_r_cnt),
        .sd_r_byte(r_byte), .sd_r_valid(r_valid), .sd_r_take(bridge_r_take),
        .sd_r_done(r_done), .sd_r_ok(r_ok)
    );
    sd_vol #(
        .PWR_BITS(20),
        .FAST_HALF(7'd1)
    ) u_sd (
        .clk(clk), .reset(sd_reset),
        .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs_n(sd_cs_n),

        .ddr_ready(1'b1),
        .m_go(), .m_addr(), .m_we(), .m_wdata(), .m_rdata(16'h0000), .m_ack(1'b1),

        .f_up_go(f_up_go), .f_up_drive(f_up_drive), .f_up_addr(f_up_addr),
        .f_up_data(f_up_data), .f_up_last(f_up_last),
        .f_up_ro(f_up_ro), .f_up_bad(f_up_bad),
        .f_up_busy(f_up_busy), .f_up_done(f_up_done),
        .f_dn_go(), .f_dn_drive(), .f_dn_addr(), .f_dn_data(8'h00), .f_dn_valid(1'b0),
        .fl_wr(1'b0), .fl_wr_drv(1'b0), .fl_wr_blk(11'd0), .bg_hold(1'b1),

        .present(present), .fail(fail), .fs_ok(fs_ok), .vol(vol),
        .loading(sd_loading), .busy(sd_busy), .err(sd_err), .estage(estage),

        .wb_go(1'b0), .wb_drv(1'b0), .wb_blk(16'd0), .rb_go(1'b0), .rb_ok(rb_ok),
        .hd_size0(hd_size0), .hd_size1(hd_size1),
        .mnt_go(1'b0), .mnt_drv(2'd0),

        .x_go(bridge_x_go), .x_lba(bridge_x_lba), .x_zero(bridge_x_zero),
        .x_byte(bridge_x_byte), .x_valid(bridge_x_valid),
        .x_take(x_take),

        .r_go(bridge_r_go), .r_lba(bridge_r_lba), .r_cnt(bridge_r_cnt), .r_byte(r_byte),
        .r_valid(r_valid), .r_take(bridge_r_take), .r_done(r_done), .r_ok(r_ok),

        // ZX tape: the library
        .lib_go(lib_go), .lib_find(lib_find), .lib_idx(sel_idx),
        .lib_count(lib_count), .lib_name(lib_name), .lib_size(lib_size),
        .lib_ent(lib_ent), .lib_done(lib_done), .lib_found(lib_found),
        .lib_fail(lib_fail),
        .lib_busy(lib_busy),
        .d0_name(d0_name), .d0_size(d0_size)
    );

    // ---- one byte at a time into the store ---------------------------
    // f_up_go stays high until f_up_done, so the accept pulse is ours to
    // make: exactly one clock per byte, and only when the store has room.
    // sd_vol drops f_up_go the clock after it sees f_up_done, so on that
    // clock the byte is still offered (and the store's wr_ready has not
    // fallen after a word's first half): taking it again doubled every byte.
    reg wr_take = 1'b0;
    assign wr_valid = wr_take;
    assign wr_byte  = f_up_data;

    always @(posedge clk) begin
        wr_take   <= 1'b0;
        f_up_done <= 1'b0;
        if (reset) begin
            wr_take   <= 1'b0;
            f_up_done <= 1'b0;
        end else if (f_up_go && wr_ready && !f_up_done) begin
            wr_take   <= 1'b1;
            f_up_done <= 1'b1;
        end
    end

    // ==================================================================
    // The deck
    // ==================================================================
    reg [2:0]  state = S_EMPTY, state_q = S_EMPTY;
    reg        sel_pending = 1'b0;
    reg        eject_pulse = 1'b0;
    reg        rewind_pulse = 1'b0;
    reg        tap_start = 1'b0;
    reg        start_pending = 1'b0;
    reg        started = 1'b0;
    reg        boot_open = 1'b1;    // ZXCONFIG.TXT's tape may still arrive
    wire       tap_done;            // the player reached the end of the image

    wire       tap_rd_req;
    wire [9:0] tap_idx;
    wire       tap_sector_done;
    reg  [7:0] rd_hold = 8'h00;

    wire       tap_eof = (img_len != 24'd0) && (rd_count >= img_len);

    assign store_clear  = sel_pending | eject_pulse;
    assign store_rewind = rewind_pulse;
    // arming at an offset: the store is rewound, then this many bytes popped
    // unread (the store sees the rewind while rewind_pulse is high)
    reg  [23:0] skip_left = 24'd0;
    wire        skip_pop  = (skip_left != 24'd0) && !rewind_pulse;
    assign rd_pop       = (tap_rd_req | inst_pop | skip_pop) && !rd_empty;
    // the trap reads the store directly; past the image's end it reads 00
    // without waiting, which it takes as a zero block length (the tape's end)
    assign inst_byte     = tap_eof ? 8'h00 : rd_byte;
    assign inst_rd_empty = (rd_empty || skip_left != 24'd0) && !tap_eof;
    assign card_ok      = fs_ok;
    assign busy         = sd_busy | sd_loading;

    // past the image's last byte the player is asking for the next block's
    // length: a .TAP has no end marker, so answer 00 00 (its end of file)
    always @(posedge clk) begin
        if (tap_rd_req && tap_eof)        rd_hold <= 8'h00;
        else if (tap_rd_req && !rd_empty) rd_hold <= rd_byte;
    end

    // paused: no T-states reach the player, so EAR holds its level and the
    // head stays put; rewind restarts the player itself as well as the store
    tap_player u_player (
        .clk(clk), .reset(reset | rewind_pulse), .ce_t(ce_cpu && state != S_PAUSE),
        .start(tap_start), .playing(playing),
        .idx(tap_idx), .rd_req(tap_rd_req), .rd_data(rd_hold),
        .buf_ready(!rd_empty), .sector_done(tap_sector_done),
        .ear(ear), .done(tap_done)
    );

    // ---- a first list, ~1 s after reset, once the card has mounted ----
    reg [15:0] boot_cnt = 16'd0;
    reg        auto_listed = 1'b0;

    // ---- progress reporting: every ~39 ms -----------------------------
    reg [19:0] rep_cnt = 20'd0;
    wire       rep_tick = (rep_cnt == 20'd0);

    always @(posedge clk) begin
        if (reset) rep_cnt <= 20'd0;
        else       rep_cnt <= rep_cnt + 20'd1;
    end

    // ==================================================================
    // What goes up the UART: four queued frames, one at a time
    // ==================================================================
    reg [1:0]  q_kind [0:3];
    reg [87:0] q_name [0:3];
    reg [31:0] q_size [0:3];
    reg [1:0]  q_wr = 2'd0, q_rd = 2'd0;
    reg [4:0]  listed = 5'd0;
    reg        push_now = 1'b0;      // a frame went into the queue last cycle
    reg        pushed;               // ...or already this cycle (blocking): one slot a clock
    reg        fail0_q = 1'b0;       // fail[0] is sticky: only its rise is news
    reg        q_pop    = 1'b0;      // the transmitter took one this cycle

    task push_frame(input [1:0] k, input [87:0] nm, input [31:0] sz);
        begin
            if (q_n < 3'd4 && !push_now && !pushed) begin
                q_kind[q_wr] <= k;
                q_name[q_wr] <= nm;
                q_size[q_wr] <= sz;
                q_wr     <= q_wr + 2'd1;
                push_now <= 1'b1;
                pushed    = 1'b1;
            end
        end
    endtask

    always @(posedge clk) begin
        pushed       = 1'b0;
        push_now    <= 1'b0;
        fail0_q     <= fail[0];
        lib_go      <= 1'b0;
        tap_start   <= 1'b0;
        eject_pulse <= 1'b0;
        rewind_pulse <= 1'b0;

        if (reset) begin
            state        <= S_EMPTY;
            state_q      <= S_EMPTY;
            instant_active <= 1'b0;
            skip_left    <= 24'd0;
            sel_pending  <= 1'b0;
            boot_open    <= 1'b1;
            boot_cnt     <= 16'd0;
            auto_listed  <= 1'b0;

            img_len      <= 24'd0;
            started      <= 1'b0;
            start_pending <= 1'b0;
            q_wr         <= 2'd0;
            q_rd         <= 2'd0;
            q_n          <= 3'd0;
        end else begin
            // ---- the first list once the card has mounted ----
            if (!auto_listed) begin
                if (fs_ok) begin
                    boot_cnt <= boot_cnt + 16'd1;
                    if (&boot_cnt) begin
                        auto_listed <= 1'b1;
                        lib_find    <= 1'b0;
                        lib_go      <= 1'b1;
                    end
                end else if (sd_err) begin
                    auto_listed <= 1'b1;
                    lib_find    <= 1'b0;
                    lib_go      <= 1'b1;
                end
            end

            // ---- the tape ZXCONFIG.TXT names: sd_vol streams it at boot,
            // so it goes in the player as if the page had picked it
            if (boot_open && f_up_go) begin
                boot_open <= 1'b0;
                img_len   <= d0_size[23:0];
                state     <= S_LOAD;
            end

            // ---- the page's commands
            if (cmd_list) begin
                lib_find <= 1'b0;
                lib_go   <= 1'b1;
                state_q  <= 3'd7;              // a fresh page hears the deck again
            end

            if (cmd_select || cmd_eject) boot_open <= 1'b0;

            if (cmd_select) begin
                sel_idx     <= cmd_idx;
                sel_pending <= 1'b1;
                img_len     <= 24'd0;
                state       <= S_LOAD;
                started     <= 1'b0;
            end

            if (sel_pending) begin
                sel_pending <= 1'b0;
                lib_find <= 1'b1;              // find entry sel_idx and stream it
                lib_go   <= 1'b1;
            end

            if (lib_found) begin
                img_len <= lib_size[23:0];
                state   <= S_LOAD;
            end
            // drive 0 failing to mount is an error only while we are loading it:
            // a boot-time failure (ZXCONFIG.TXT naming a missing file) stays set
            // until the next find clears it, and must not poison every load
            if (lib_fail || (fail[0] && !fail0_q && state == S_LOAD) ||
                (sd_err && (state == S_LOAD || sel_pending))) begin
                state   <= S_ERR;
                img_len <= 24'd0;
                instant_active <= 1'b0;     // or the trap waits on an empty store
            end

            // ---- instant: the page has run the tape up to inst_off (the first
            // part its program did not take) and injected the machine; the
            // head goes there and zx_core's trap serves the ROM's next loads.
            // The player stays stopped -- Play starts it from the head (a
            // custom loader's next part), and Play, rewind, a new tape or
            // eject disarm the trap.  Still loading is fine: the skip and the
            // trap wait for the bytes.
            // (rd_count is the old head's until the rewind has landed)
            if (skip_pop && !rd_empty) skip_left <= skip_left - 24'd1;
            if (tap_eof && !rewind_pulse) skip_left <= 24'd0;
            if (cmd_instant && state != S_EMPTY && state != S_ERR) begin
                instant_active <= 1'b1;
                rewind_pulse   <= 1'b1;
                skip_left      <= inst_off;
                started        <= 1'b0;
                if (state != S_LOAD) state <= S_READY;
            end
            if (cmd_play || cmd_rewind || cmd_select || cmd_eject) begin
                instant_active <= 1'b0;
                skip_left      <= 24'd0;
            end

            if (cmd_eject) begin
                eject_pulse <= 1'b1;
                img_len <= 24'd0;
                state   <= S_EMPTY;
                started <= 1'b0;
            end

            // ---- the whole image is in DDR3: hold it for LOAD ""
            if (state == S_LOAD && img_ready) state <= S_READY;

            // ---- play: the ROM's LD-BYTES, DIP5, or the page's button
            if (state == S_READY && (cmd_play || (!instant_active && (tape_load || auto_play)))) begin
                // the head is already at the start after a load; a restart
                // rewinds it first and starts one clock later
                if (started) begin
                    rewind_pulse  <= 1'b1;
                    start_pending <= 1'b1;
                end else begin
                    tap_start <= 1'b1;
                    started   <= 1'b1;
                end
                state <= S_PLAY;
            end
            // ---- pause holds, play or pause again resumes
            if (cmd_pause && state == S_PLAY)  state <= S_PAUSE;
            // ...and so does the ROM's next LOAD (Stop on the page is this
            // hold): a multi-load game's next part runs on from the head
            if ((cmd_pause || cmd_play || tape_load) && state == S_PAUSE) state <= S_PLAY;

            // ---- rewind: head to the start, stopped, waiting for LOAD "" or play
            if (cmd_rewind && (state == S_READY || state == S_PLAY ||
                               state == S_PAUSE || state == S_END)) begin
                rewind_pulse <= 1'b1;
                started      <= 1'b0;
                state        <= S_READY;
            end

            if (state == S_END && cmd_play) begin
                rewind_pulse  <= 1'b1;
                start_pending <= 1'b1;
                state         <= S_PLAY;
            end

            if (start_pending) begin
                start_pending <= 1'b0;
                tap_start     <= 1'b1;
            end

            if (tap_done && state == S_PLAY) state <= S_END;

            // ---- the card's listing comes in (one-shot pulses: first claim)
            if (lib_ent) begin
                push_frame(2'd0, lib_name, lib_size);
                listed <= listed + 5'd1;
                // the player's row, by name: the boot tape has no index, and a
                // delete above it moves it
                if (state != S_EMPTY && lib_name == d0_name) sel_idx <= listed;
            end
            if (lib_done) begin
                push_frame(2'd1, 88'd0, {27'd0, listed});
                listed <= 5'd0;
            end

            // ---- one frame when the deck changes; retried until it is queued
            if (state != state_q && q_n < 3'd4 && !push_now && !pushed) begin
                state_q <= state;
                push_frame(2'd2, {85'd0, state}, 32'd0);
            end

            // ---- where the tape has got to, while it matters
            // (held states too, so a page that connects late learns the row)
            if (rep_tick && state != S_EMPTY && state != S_ERR)
                push_frame(2'd3, {56'd0, (state == S_LOAD) ? wr_count : rd_count},
                           {8'd0, img_len});

            // ---- the queue's pointers move here, once ------------------
            if (q_pop && q_n != 3'd0) q_rd <= q_rd + 2'd1;
            q_n <= q_n + {2'd0, push_now} - {2'd0, q_pop};
        end
    end

    // ---- the frame generator ------------------------------------------
    reg [4:0]  fi = 5'd0;
    reg [4:0]  flen = 5'd0;
    reg [1:0]  fkind = 2'd0;
    reg [87:0] fname = 88'd0;
    reg [31:0] fsize = 32'd0;
    reg        fbusy = 1'b0;
    reg        fwait = 1'b0;

    function [7:0] frame_byte(input [1:0] k, input [4:0] i,
                              input [87:0] nm, input [31:0] sz, input [7:0] ix);
        begin
            case (k)
                2'd0: case (i)                          // K_ENTRY
                    5'd0:    frame_byte = 8'hF7;
                    5'd1:    frame_byte = 8'd11;
                    default: if (i <= 5'd12) frame_byte = nm[8 * (5'd12 - i) +: 8];
                             else            frame_byte = sz[8 * (i - 5'd13) +: 8];
                endcase
                2'd1: frame_byte = (i == 5'd0) ? 8'hF6 : sz[7:0];          // K_END
                2'd2: frame_byte = (i == 5'd0) ? 8'hF8 : nm[7:0];          // K_STATE
                default: case (i)                                          // K_PROG
                    5'd0: frame_byte = 8'hF9;
                    5'd1: frame_byte = ix;
                    5'd2: frame_byte = nm[7:0];
                    5'd3: frame_byte = nm[15:8];
                    5'd4: frame_byte = nm[23:16];
                    default: frame_byte = sz[8 * (i - 5'd5) +: 8];
                endcase
            endcase
        end
    endfunction

    reg        lib_tx_req = 1'b0;
    reg  [7:0] lib_tx_data = 8'h00;
    assign tx_req    = (bridge_card_mode || bridge_tx_req) ? bridge_tx_req  : lib_tx_req;
    assign tx_data   = (bridge_card_mode || bridge_tx_req) ? bridge_tx_data : lib_tx_data;
    assign card_mode = bridge_card_mode;

    always @(posedge clk) begin
        lib_tx_req <= 1'b0;
        q_pop      <= 1'b0;
        if (reset) begin
            fbusy <= 1'b0;
            fwait <= 1'b0;
            fi    <= 5'd0;
        end else if (!fbusy) begin
            if (q_n != 3'd0 && !tx_busy && !bridge_card_mode) begin
                fkind <= q_kind[q_rd];
                fname <= q_name[q_rd];
                fsize <= q_size[q_rd];
                case (q_kind[q_rd])
                    2'd0:    flen <= 5'd17;
                    2'd1, 2'd2: flen <= 5'd2;
                    default: flen <= 5'd9;
                endcase
                q_pop <= 1'b1;
                fi    <= 5'd0;
                fbusy <= 1'b1;
            end
        end else if (!fwait) begin
            if (!tx_busy && !bridge_card_mode) begin
                lib_tx_data <= frame_byte(fkind, fi, fname, fsize, {3'd0, sel_idx});
                lib_tx_req  <= 1'b1;
                fwait       <= 1'b1;
            end
        end else if (tx_busy) begin
            fwait <= 1'b0;
            if (fi + 5'd1 >= flen) fbusy <= 1'b0;
            fi <= fi + 5'd1;
        end
    end

endmodule

`default_nettype wire
