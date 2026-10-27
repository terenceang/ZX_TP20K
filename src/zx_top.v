// ============================================================================
//  zx_top.v -- a Sinclair ZX Spectrum 48K on the Sipeed Tang Primer 20K
//
//  HDMI out (720x480p, the ULA picture doubled to 512x384 inside its border),
//  the 48K boots its ROM to the BASIC prompt; the keyboard is the web page
//  over the BL702 UART (1 Mbps, web/), tapes come off the microSD card into
//  the DDR3, where the deck plays them (docs/tape-library.md).
//
//  Clocks, all off the 27 MHz oscillator (src/clk_gen.v):
//      clk_pixel 27 MHz   everything ZX, and the HDMI pixel clock
//      clk_tmds 135 MHz   the OSER10 serial clock (5 bits per pixel)
//      ddr_memory_clk 398.25 MHz   the DDR3 IP
//
//  Inputs: S0 (T10, active low) is the Spectrum's reset; S1/S2 the test
//  pattern.  Everything else arrives over the UART.
// ============================================================================

`default_nettype none
`include "src/hdmi/hdmi_defs.vh"

module zx_top (
    input  wire        clk,          // 27.0 MHz SOM oscillator (H11)
    input  wire        rst_n,        // S0 (T10, active low; also FPGA_RST)

    output wire [5:0]  led,          // Dock LEDs, active low


    // test-pattern buttons (active low, 10k pull-ups): S1 T3 and S2 T2.
    // Holding either forces HDMI to colour bars + a 1 kHz tone, which checks
    // the whole TMDS/audio path with no CPU, RAM or video in the way.
    input  wire        btn_test_n,    // S1  T3
    input  wire        btn_test2_n,   // S2  T2

    input  wire        uart_rx,      // T13, from the BL702 USB-C debugger
    output wire        uart_tx,      // M11

    // microSD (J2) in SPI mode: CLK N10, CMD R14 = MOSI, D0 M8 = MISO,
    // D3 N11 = /CS.  (M8 is an SSPI config pin; build.ps1 sets
    // use_sspi_as_gpio, which frees it.)
    output wire        sd_clk,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output wire        sd_cs_n,

    // HDMI (J3): TMDS clock + 3 data lanes, true LVDS pairs
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_d_p,
    output wire [2:0]  tmds_d_n,

    // DDR3 (on the SOM)
    inout  wire [15:0] DDR3_DQ,
    inout  wire [1:0]  DDR3_DQS,
    inout  wire [1:0]  DDR3_DQS_n,
    output wire [13:0] DDR3_A,
    output wire [2:0]  DDR3_BA,
    output wire        DDR3_nCS,
    output wire        DDR3_nRAS,
    output wire        DDR3_nCAS,
    output wire        DDR3_nWE,
    output wire        DDR3_CK,
    output wire        DDR3_CK_n,
    output wire        DDR3_CKE,
    output wire        DDR3_nRESET,
    output wire        DDR3_ODT,
    output wire [1:0]  DDR3_DM
);


    // ------------------------------------------------------------------
    // Clocks
    // ------------------------------------------------------------------
    wire clk_tmds, clk_pixel, pll_locked, ddr_memory_clk, ddr_lock;
    wire ce_cpu, ce_48k;

    clk_gen u_clk_gen (
        .clk_in(clk),
        .rst_in(1'b0),                 // the PLLs run from power-up
        .clk_tmds(clk_tmds),
        .clk_pixel(clk_pixel),
        .pll_locked(pll_locked),
        .ddr_memory_clk(ddr_memory_clk),
        .ddr_lock(ddr_lock),
        .ce_cpu(ce_cpu),
        .ce_48k(ce_48k)
    );

    // ------------------------------------------------------------------
    // Reset: S0, synchronised; POR counter so the machine starts cleanly
    // after the PLL locks.  Button resets hit the Spectrum only -- the DDR3
    // IP is not re-initialised (calibration takes ~half a second) and its
    // contents survive, as on the sibling project.
    // ------------------------------------------------------------------
    reg [1:0] btn_sync = 2'b11;
    always @(posedge clk_pixel) btn_sync <= {btn_sync[0], rst_n};

    reg [19:0] por_cnt = 20'd0;
    wire       por_done = por_cnt[19];
    always @(posedge clk_pixel or negedge pll_locked) begin
        if (!pll_locked)     por_cnt <= 20'd0;
        else if (!por_done)  por_cnt <= por_cnt + 20'd1;
    end

    wire sys_reset = ~btn_sync[1] | ~por_done;

    // HDMI release: 128 pixel clocks after PLL lock, before any active video.
    reg [7:0] hdmi_rst_cnt = 8'd0;
    wire      hdmi_rst_n   = hdmi_rst_cnt[7];
    always @(posedge clk_pixel or negedge pll_locked) begin
        if (!pll_locked)       hdmi_rst_cnt <= 8'd0;
        else if (!hdmi_rst_n)  hdmi_rst_cnt <= hdmi_rst_cnt + 8'd1;
    end

    // ------------------------------------------------------------------
    // The Spectrum
    // ------------------------------------------------------------------
    wire [9:0]  pixel_x, pixel_y;
    wire [23:0] video_rgb;
    wire        audio_valid;
    wire [15:0] audio_l, audio_r;
    wire        halt_n, flash, key_hit, frame_tick;

    // ---- tape: the same player, fed from the card --------------------
    wire tape_ear, tape_playing;
    wire tape_load;
    wire [6:0] tape_vol;               // percent, ZXCONFIG.TXT's VOL=

    // the page's tape-library commands, out of zx_input (inside zx_core)
    wire        lib_list, lib_sel, lib_eject, lib_play, lib_pause, lib_rewind, cmd_instant, cmd_version;
    wire [23:0] inst_off;
    wire [4:0]  lib_idx;
    wire        instant_active, inst_pop, inst_rd_empty;
    wire [7:0]  inst_byte;

    // the DDR3 client port: the tape store owns it
    wire        ddr_go;
    wire [25:0] ddr_addr;
    wire        ddr_we;
    wire [1:0]  ddr_be;
    wire [15:0] ddr_wdata, ddr_rdata;
    wire        ddr_ack, ddr_idle;

    // the card's tape list over the UART, the chosen tape streamed into
    // DDR3, and the player reading it from there (docs/tape-library.md)
    wire        lib_tx_req, uart_tx_busy;
    wire [7:0]  urx_byte_out;
    wire        urx_valid_out;
    wire        card_mode;
    wire [7:0]  lib_tx_data;
    wire        store_clear, store_rewind, store_wr_valid, store_wr_ready, store_rd_pop;
    wire [7:0]  store_wr_byte, store_rd_byte;
    wire [23:0] store_img_len, store_wr_count, store_rd_count;
    wire        store_img_ready, store_rd_empty;

    zx_tape_lib u_tape (
        .clk(clk_pixel), .reset(sys_reset), .ce_cpu(ce_cpu),
        .tape_load(tape_load),
        .cmd_list(lib_list), .cmd_select(lib_sel), .cmd_idx(lib_idx),
        .cmd_eject(lib_eject), .cmd_play(lib_play),
        .cmd_pause(lib_pause), .cmd_rewind(lib_rewind),
        .cmd_instant(cmd_instant), .inst_off(inst_off), .cmd_version(cmd_version), .inst_pop(inst_pop),
        .inst_byte(inst_byte), .inst_rd_empty(inst_rd_empty), .instant_active(instant_active),
        .sd_miso(sd_miso), .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_cs_n(sd_cs_n),
        .store_clear(store_clear), .store_rewind(store_rewind),
        .wr_valid(store_wr_valid), .wr_byte(store_wr_byte), .wr_ready(store_wr_ready),
        .img_len(store_img_len), .wr_count(store_wr_count), .img_ready(store_img_ready),
        .rd_empty(store_rd_empty), .rd_byte(store_rd_byte), .rd_pop(store_rd_pop),
        .rd_count(store_rd_count),
        .tx_req(lib_tx_req), .tx_data(lib_tx_data), .tx_busy(uart_tx_busy),
        .rx_byte(urx_byte_out), .rx_valid(urx_valid_out), .card_mode(card_mode),
        .ear(tape_ear), .playing(tape_playing), .vol(tape_vol)
    );

    zx_tape_mem u_store (
        .clk(clk_pixel), .reset(sys_reset), .clear(store_clear),
        .ddr_go(ddr_go), .ddr_addr(ddr_addr), .ddr_we(ddr_we), .ddr_be(ddr_be),
        .ddr_wdata(ddr_wdata), .ddr_rdata(ddr_rdata), .ddr_ack(ddr_ack),
        .ddr_idle(ddr_idle),
        .wr_valid(store_wr_valid), .wr_byte(store_wr_byte), .wr_ready(store_wr_ready),
        .wr_count(store_wr_count), .img_len(store_img_len), .rewind(store_rewind),
        .rd_count(store_rd_count), .img_ready(store_img_ready), .rd_empty(store_rd_empty),
        .rd_pop(store_rd_pop), .rd_byte(store_rd_byte)
    );

    wire       scr_capturing, scr_tx_req;
    wire [7:0] scr_tx_data;
    wire       scr_tx_busy;

    zx_core #(.VID_X0(104)) u_core (
        .clk(clk_pixel),
        .reset(sys_reset),
        .ce_cpu(ce_cpu),
        .ce_48k(ce_48k),
        .uart_rx(uart_rx),
        .key_hit(key_hit),
        .lib_list(lib_list), .lib_sel(lib_sel), .lib_idx(lib_idx),
        .lib_eject(lib_eject), .lib_play(lib_play),
        .lib_pause(lib_pause), .lib_rewind(lib_rewind),
        .cmd_instant(cmd_instant), .inst_off(inst_off),
        .cmd_version(cmd_version),
        .instant_active(instant_active),
        .inst_pop(inst_pop),
        .inst_byte(inst_byte),
        .inst_rd_empty(inst_rd_empty),
        .ear(tape_ear),
        .tape_vol(tape_vol),
        .tape_load(tape_load),
        .vid_x(pixel_x),
        .vid_y(pixel_y),
        .vid_rgb(video_rgb),
        .flash(flash),
        .audio_valid(audio_valid),
        .audio_l(audio_l),
        .audio_r(audio_r),
        .halt_n(halt_n),
        .frame_tick(frame_tick),
        .scr_capturing(scr_capturing),
        .scr_tx_req(scr_tx_req),
        .scr_tx_data(scr_tx_data),
        .scr_tx_busy(scr_tx_busy),
        .card_mode(card_mode),
        .rx_byte_out(urx_byte_out),
        .rx_valid_out(urx_valid_out)
    );

    // ------------------------------------------------------------------
    // HDMI
    // ------------------------------------------------------------------

    // ---- HDMI bring-up test pattern (hold S1 or S2) -------------------
    reg [1:0] btn1_sync = 2'b11, btn2_sync = 2'b11;
    always @(posedge clk_pixel) begin
        btn1_sync <= {btn1_sync[0], btn_test_n};
        btn2_sync <= {btn2_sync[0], btn_test2_n};
    end
    wire test_mode = ~(btn1_sync[1] & btn2_sync[1]);

    wire [23:0] bar_rgb;

    colorbar_gen u_colorbar (
        .clk_pixel(clk_pixel),
        .reset(sys_reset),
        .x(pixel_x),
        .y(pixel_y),
        .rgb(bar_rgb)
    );

    wire [23:0] hdmi_rgb = test_mode ? bar_rgb : video_rgb;

    // 1 kHz square wave on the 48 kHz sample strobe (24 samples per half
    // period), the same level as the beeper so the sink sees a normal stream.
    reg [4:0]  tone_cnt = 5'd0;
    reg        tone_hi  = 1'b0;
    always @(posedge clk_pixel) begin
        if (audio_valid) begin
            if (tone_cnt == 5'd23) begin
                tone_cnt <= 5'd0;
                tone_hi  <= ~tone_hi;
            end else
                tone_cnt <= tone_cnt + 5'd1;
        end
    end
    wire [15:0] test_pcm = tone_hi ? 16'sd7000 : -16'sd7000;

    wire [15:0] hdmi_audio_l = test_mode ? test_pcm : audio_l;
    wire [15:0] hdmi_audio_r = test_mode ? test_pcm : audio_r;

    wire [39:0] tmds;

    hdmi_tx #(
        .RGB_QUANT(2'b10)              // full-range RGB (see hdmi_tx's AVI note)
    ) u_hdmi (
        .clk_pixel(clk_pixel),
        .rst_n(hdmi_rst_n),
        .pixel_x(pixel_x),
        .pixel_y(pixel_y),
        .video_rgb(hdmi_rgb),
        .audio_valid(audio_valid),
        .audio_l(hdmi_audio_l),
        .audio_r(hdmi_audio_r),
        .tmds(tmds[29:0])
    );

    // Lane 3 is the TMDS clock: the constant 0000011111, one pixel period.
    assign tmds[39:30] = 10'b0000011111;

    // Serializers: OSER10 shifts D0 first (TMDS bit 0 first), DDR on
    // clk_tmds (5x), 270 Mbit/s per lane.  The Dock's HDMI balls are true
    // LVDS pairs (TLVDS_OBUF + LVDS25) -- the arrangement the sibling
    // project verified on this hardware.
    wire [3:0] tmds_pad_p, tmds_pad_n;
    assign {tmds_clk_p, tmds_d_p} = tmds_pad_p;
    assign {tmds_clk_n, tmds_d_n} = tmds_pad_n;

    genvar lane;
    generate
        for (lane = 0; lane < 4; lane = lane + 1) begin : g_tmds_lane
            wire [9:0] sym = tmds[10*lane +: 10];
            wire       q;
            OSER10 #(.GSREN("false"), .LSREN("true")) u_ser (
                .D0(sym[0]), .D1(sym[1]), .D2(sym[2]), .D3(sym[3]), .D4(sym[4]),
                .D5(sym[5]), .D6(sym[6]), .D7(sym[7]), .D8(sym[8]), .D9(sym[9]),
                .PCLK(clk_pixel), .FCLK(clk_tmds), .RESET(~hdmi_rst_n), .Q(q)
            );
            TLVDS_OBUF u_obuf (.I(q), .O(tmds_pad_p[lane]), .OB(tmds_pad_n[lane]));
        end
    endgenerate

    // ------------------------------------------------------------------
    // DDR3: calibrated and self-tested; its one client port is the tape
    // store's (zx_tape_mem).
    // ------------------------------------------------------------------
    wire ddr_ready;
    wire [31:0] ddr_diag;

    zx_ddr u_ddr (
        .clk(clk_pixel),
        .reset(sys_reset),
        .ddr_ref_clk(clk),
        .go(ddr_go), .addr(ddr_addr), .we(ddr_we), .be(ddr_be), .wdata(ddr_wdata),
        .rdata(ddr_rdata), .ack(ddr_ack), .idle(ddr_idle),
        .ready(ddr_ready),
        .diag(ddr_diag),
        .ddr_memory_clk(ddr_memory_clk),
        .ddr_lock(ddr_lock),
        .DDR3_DQ(DDR3_DQ), .DDR3_DQS(DDR3_DQS), .DDR3_DQS_n(DDR3_DQS_n),
        .DDR3_A(DDR3_A), .DDR3_BA(DDR3_BA), .DDR3_nCS(DDR3_nCS),
        .DDR3_nRAS(DDR3_nRAS), .DDR3_nCAS(DDR3_nCAS), .DDR3_nWE(DDR3_nWE),
        .DDR3_CK(DDR3_CK), .DDR3_CK_n(DDR3_CK_n), .DDR3_CKE(DDR3_CKE),
        .DDR3_nRESET(DDR3_nRESET), .DDR3_ODT(DDR3_ODT), .DDR3_DM(DDR3_DM)
    );

    // ------------------------------------------------------------------
    // UART TX: boot banner, tape traffic, and screen capture
    // ------------------------------------------------------------------
    wire       raw_uart_tx_busy;

    assign scr_tx_busy  = raw_uart_tx_busy;
    assign uart_tx_busy = scr_capturing ? 1'b1 : raw_uart_tx_busy;

    wire       mux_tx_req  = scr_capturing ? scr_tx_req  : lib_tx_req;
    wire [7:0] mux_tx_data = scr_capturing ? scr_tx_data : lib_tx_data;

    zx_uart_tx u_banner (
        .clk(clk_pixel), .reset(sys_reset), .uart_tx(uart_tx),
        .tx_req(mux_tx_req), .tx_data(mux_tx_data), .tx_busy(raw_uart_tx_busy)
    );

    // ------------------------------------------------------------------
    // LEDs (active low): 0 PLL, 1 DDR3 not ready, 2 CPU HALT (the editor
    // HALTs between 50 Hz interrupts, so it breathes), 3 FLASH phase,
    // 4 lights for ~1/4 s after keyboard traffic, 5 tape playing
    // ------------------------------------------------------------------
    reg [3:0] key_led_frames = 4'd0;
    always @(posedge clk_pixel) begin
        if (key_hit)                                        key_led_frames <= 4'd12;
        else if (frame_tick && key_led_frames != 4'd0)      key_led_frames <= key_led_frames - 4'd1;
    end

    assign led[0] = ~pll_locked;
    assign led[1] = ~ddr_ready;
    assign led[2] = halt_n;
    assign led[3] = ~flash;
    assign led[4] = (key_led_frames != 4'd0);
    assign led[5] = ~tape_playing;     // on while the tape plays

endmodule

`default_nettype wire
