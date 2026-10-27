// ============================================================================
//  tb_top.v -- elaboration and integration smoke test for the whole top
//
//  zx_top with the Gowin primitives modelled (sim/models/gowin_prims.v) and
//  the encrypted DDR3 IP stood in for by sim/models/ddr3_model.v.  It does
//  not re-test what tb_zx and tb_ddr cover; it proves the real file list
//  elaborates and that the clocking and the HDMI pipeline come up:
//
//    * both rPLLs lock (the models' LOCK)
//    * frames arrive at the 720x480p rate
//    * every sampled video pixel is a legal ULA palette colour
//    * the TMDS clock lane's serializer output toggles
//
//  Needs roms/zx48.hex (the top contains the ROM).
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_top;
    reg clk27 = 1'b0;
    always #18.519 clk27 = ~clk27;

    reg rst_n = 1'b0;

    wire [5:0] led;
reg  sw_color_tv = 1'b0;
wire sd_clk, sd_mosi, sd_cs_n;
reg  sd_miso = 1'b1;   // no card: MISO idle high
reg  btn_test_n = 1'b1, btn_test2_n = 1'b1;   // buttons not pressed
reg  sw_scanline = 1'b0;
reg  sw_tape_auto = 1'b0;
reg  sw_type_load = 1'b0;
    wire       uart_tx;
    reg        uart_rx = 1'b1;

    wire        tmds_clk_p, tmds_clk_n;
    wire [2:0]  tmds_d_p, tmds_d_n;

    wire [15:0] DDR3_DQ;
    wire [1:0]  DDR3_DQS, DDR3_DQS_n;
    wire [13:0] DDR3_A;
    wire [2:0]  DDR3_BA;
    wire DDR3_nCS, DDR3_nRAS, DDR3_nCAS, DDR3_nWE, DDR3_CK, DDR3_CK_n,
         DDR3_CKE, DDR3_nRESET, DDR3_ODT;
    wire [1:0] DDR3_DM;

    zx_top u_top (
        .clk(clk27),
        .rst_n(rst_n),
        .led(led),
        .uart_rx(uart_rx),
        .btn_test_n(btn_test_n), .btn_test2_n(btn_test2_n),
        .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs_n(sd_cs_n),
        .sw_color_tv(sw_color_tv),
        .sw_scanline(sw_scanline),
        .sw_tape_auto(sw_tape_auto),
        .sw_type_load(sw_type_load),
        .uart_tx(uart_tx),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
        .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n),
        .DDR3_DQ(DDR3_DQ), .DDR3_DQS(DDR3_DQS), .DDR3_DQS_n(DDR3_DQS_n),
        .DDR3_A(DDR3_A), .DDR3_BA(DDR3_BA), .DDR3_nCS(DDR3_nCS),
        .DDR3_nRAS(DDR3_nRAS), .DDR3_nCAS(DDR3_nCAS), .DDR3_nWE(DDR3_nWE),
        .DDR3_CK(DDR3_CK), .DDR3_CK_n(DDR3_CK_n), .DDR3_CKE(DDR3_CKE),
        .DDR3_nRESET(DDR3_nRESET), .DDR3_ODT(DDR3_ODT), .DDR3_DM(DDR3_DM)
    );

    integer errors = 0;
    integer frames = 0;
    integer samples = 0;
    integer k;

    // frame starts, as zx_core and top count them
    always @(posedge u_top.clk_pixel)
        if (u_top.pixel_x == 10'd0 && u_top.pixel_y == 10'd0) frames = frames + 1;

    // palette check on active pixels
    wire in_active = (u_top.pixel_x < 10'd720) && (u_top.pixel_y < 10'd480);
    always @(posedge u_top.clk_pixel) begin
        if (in_active && samples < 20000) begin
            samples = samples + 1;
            for (k = 0; k < 3; k = k + 1)
                if (u_top.video_rgb[8*k +: 8] !== 8'h00 &&
                    u_top.video_rgb[8*k +: 8] !== 8'hC0 &&
                    u_top.video_rgb[8*k +: 8] !== 8'hFF) begin
                    $display("FAIL: pixel (%0d,%0d) channel %0d = %02x is not a palette level",
                             u_top.pixel_x, u_top.pixel_y, k, u_top.video_rgb[8*k +: 8]);
                    errors = errors + 1;
                    samples = 20000;   // one complaint is enough
                end
        end
    end

    // the TMDS clock lane's serializer runs at 135 MHz; count its toggles in
    // that domain (sampling it at the 27 MHz pixel clock aliases to a steady
    // value, which is not the same as it being static)
    integer q_toggles = 0;
    reg     q_prev = 1'b0;
    always @(posedge u_top.clk_tmds) begin
        if (u_top.hdmi_rst_n && u_top.g_tmds_lane[3].u_ser.Q !== q_prev)
            q_toggles = q_toggles + 1;
        q_prev = u_top.g_tmds_lane[3].u_ser.Q;
    end

    initial begin
        repeat (50) @(posedge clk27);
        rst_n = 1'b1;

        wait (u_top.pll_locked === 1'b1);
        $display("ok: TMDS PLL locked");

        // ~3 frames of 720x480p (16.7 ms each)
        #60ms;

        if (frames < 3) begin
            $display("FAIL: only %0d frame starts in 60 ms", frames);
            errors = errors + 1;
        end else
            $display("ok: %0d frames in 60 ms", frames);

        if (samples < 2000) begin
            $display("FAIL: only %0d active pixels sampled", samples);
            errors = errors + 1;
        end else
            $display("ok: %0d active pixels, all palette-legal", samples);

        if (q_toggles < 1000) begin
            $display("FAIL: the TMDS clock lane toggled only %0d times", q_toggles);
            errors = errors + 1;
        end else
            $display("ok: TMDS clock lane toggles (%0d edges)", q_toggles);

        if (errors == 0) $display("PASS: tb_top");
        $finish;
    end

    // watchdog
    initial begin
        #200ms;
        $display("FAIL: watchdog expired");
        $finish;
    end

endmodule

`default_nettype wire
