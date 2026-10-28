// ============================================================================
//  zx_usb.v -- a USB keyboard or gamepad on the Dock's second USB-C (J8)
//
//  The USB3317 ULPI PHY is set up once over ULPI (LS host: 15k pull-downs on,
//  low-speed transceiver) and then switched to its 6-pin FS/LS serial mode,
//  where it is a plain D+/D- transceiver:
//
//      data[0] tx_enable   data[1] tx_dat   data[2] tx_se0     (link -> PHY)
//      data[4] rx_dp       data[5] rx_dm                       (PHY -> link)
//
//  That is the bus nand2mario's usb_hid_host (src/usb/, vendored) speaks, so
//  enumeration, keep-alive and report parsing are all its microcode.  It is
//  low-speed only, one device, no hubs: most keyboards and cheap gamepads.
//  J8 is a USB-C receptacle with VBUS tied to +5V; a keyboard needs a USB-C
//  OTG adapter (or a USB-C keyboard).
//
//  What arrives becomes membrane contacts (usb_keys, ORed with the web
//  keyboard's) and a Kempston joystick byte, mapped like the web page maps
//  the PC keyboard (web/src/zxkeys.js): left shift CAPS SHIFT, right
//  shift / right alt / ctrl SYMBOL SHIFT, a shifted symbol the Spectrum's own
//  SYMBOL SHIFT chord, Backspace DELETE, the arrows the cursor keys, Esc
//  BREAK.  A gamepad is Kempston (port 0x1F); START is ENTER, SELECT SPACE.
//
//  Clocks: clk (27 MHz) holds the PHY in reset after configuration; usb_clk60
//  (the PHY's CLKOUT) runs the register writes; clk_usb (12 MHz) the host.
//  The outputs are levels, resynchronised into clk.
// ============================================================================

`default_nettype none

module zx_usb (
    input  wire        clk,          // 27 MHz (clk_pixel)
    input  wire        clk_usb,      // 12 MHz, usb_hid_host's bit clock

    // USB3317 ULPI (Dock J8)
    input  wire        usb_clk60,    // CLKOUT, 60 MHz while not in serial mode
    output wire        usb_reset_n,  // RESETB (F10, shared with the Ethernet PHY)
    input  wire        usb_dir,
    input  wire        usb_nxt,
    output reg         usb_stp = 1'b0,
    inout  wire [7:0]  usb_data,

    output wire [39:0] usb_keys,     // 1 = pressed, pos = row*5+col
    output wire [4:0]  kempston,     // {fire, up, down, left, right}
    output wire        usb_hit       // pulse: a report arrived (LED)
);

    // ------------------------------------------------------------------
    // PHY reset: ~1.2 ms low after configuration, then released for good.
    // ------------------------------------------------------------------
    reg [15:0] rst_cnt = 16'd0;
    always @(posedge clk) if (!rst_cnt[15]) rst_cnt <= rst_cnt + 16'd1;
    assign usb_reset_n = rst_cnt[15];

    // ------------------------------------------------------------------
    // ULPI register writes (usb_clk60): wait for the PHY to drop DIR, then
    //   04 Function Control  46  SuspendM, TermSelect, XcvrSelect = LS
    //   0A OTG Control       06  DpPulldown, DmPulldown (host)
    //   07 Interface Control 01  6-pin FsLsSerialMode
    // Each: TXCMD 10_aaaaaa until NXT, the data until NXT, then STP.  If the
    // PHY takes the bus (DIR) mid-write, the write starts again.
    // ------------------------------------------------------------------
    reg [1:0] rel = 2'b00;           // reset release, into usb_clk60
    always @(posedge usb_clk60 or negedge usb_reset_n)
        if (!usb_reset_n) rel <= 2'b00;
        else              rel <= {rel[0], 1'b1};

    localparam W_IDLE = 2'd0, W_CMD = 2'd1, W_DATA = 2'd2, W_STP = 2'd3;
    reg [1:0] wst    = W_IDLE;
    reg [1:0] reg_n  = 2'd0;         // which write
    reg [6:0] idle_n = 7'd0;         // DIR-low clocks seen
    reg       serial = 1'b0;         // set after the last write: pins are serial now
    reg       ulpi_oe = 1'b0;
    reg [7:0] ulpi_o  = 8'h00;

    wire [7:0] wr_addr = (reg_n == 2'd0) ? 8'h04 : (reg_n == 2'd1) ? 8'h0A : 8'h07;
    wire [7:0] wr_data = (reg_n == 2'd0) ? 8'h46 : (reg_n == 2'd1) ? 8'h06 : 8'h01;

    always @(posedge usb_clk60) begin
        usb_stp <= 1'b0;
        if (!rel[1]) begin
            wst <= W_IDLE; reg_n <= 2'd0; idle_n <= 7'd0;
            serial <= 1'b0; ulpi_oe <= 1'b0; ulpi_o <= 8'h00;
        end else if (!serial) begin
            if (usb_dir && wst != W_STP) begin   // the PHY has the bus
                ulpi_oe <= 1'b0;
                idle_n  <= 7'd0;
                wst     <= W_IDLE;
            end else case (wst)
                W_IDLE:
                    if (idle_n[6]) begin         // 64 clocks of DIR low
                        ulpi_oe <= 1'b1;
                        ulpi_o  <= 8'h80 | wr_addr;
                        wst     <= W_CMD;
                    end else idle_n <= idle_n + 7'd1;
                W_CMD:
                    if (usb_nxt) begin ulpi_o <= wr_data; wst <= W_DATA; end
                W_DATA:
                    if (usb_nxt) begin
                        ulpi_o  <= 8'h00;
                        usb_stp <= 1'b1;
                        wst     <= W_STP;
                    end
                W_STP: begin
                    ulpi_oe <= 1'b0;
                    idle_n  <= 7'd0;
                    wst     <= W_IDLE;
                    if (reg_n == 2'd2) serial <= 1'b1;
                    else reg_n <= reg_n + 2'd1;
                end
            endcase
        end
    end

    // ------------------------------------------------------------------
    // The host, on the serial pins once they are serial.  (serial is static
    // from then on, so its crossing into clk_usb is a constant.)
    // ------------------------------------------------------------------
    wire dp_o, dm_o, oe;
    wire [7:0] ser_o = {5'b0, oe & ~dp_o & ~dm_o, dp_o, oe};   // se0, dat, enable
    assign usb_data[2:0] = serial ? ser_o[2:0] : ulpi_oe ? ulpi_o[2:0] : 3'bzzz;
    assign usb_data[7:3] = (!serial && ulpi_oe) ? ulpi_o[7:3] : 5'bzzzzz;

    reg [1:0] ser_q = 2'b00;
    always @(posedge clk_usb) ser_q <= {ser_q[0], serial};

    wire [1:0] typ;
    wire       report;
    wire [7:0] kmod, k1, k2, k3, k4;
    wire       g_l, g_r, g_u, g_d, g_a, g_b, g_x, g_y, g_sel, g_sta;

    usb_hid_host u_hid (
        .usbclk(clk_usb), .usbrst_n(ser_q[1]),
        .usb_dp_i(usb_data[4]), .usb_dm_i(usb_data[5]),
        .usb_dp_o(dp_o), .usb_dm_o(dm_o), .usb_oe(oe),
        .typ(typ), .report(report), .conerr(),
        .key_modifiers(kmod), .key1(k1), .key2(k2), .key3(k3), .key4(k4),
        .mouse_btn(), .mouse_dx(), .mouse_dy(),
        .game_l(g_l), .game_r(g_r), .game_u(g_u), .game_d(g_d),
        .game_a(g_a), .game_b(g_b), .game_x(g_x), .game_y(g_y),
        .game_sel(g_sel), .game_sta(g_sta),
        .dbg_hid_report()
    );

    wire [39:0] map_keys;
    wire [4:0]  map_kemp;
    zx_usb_map u_map (
        .typ(typ), .kmod(kmod), .k1(k1), .k2(k2), .k3(k3), .k4(k4),
        .pad({g_a | g_b | g_x | g_y, g_u, g_d, g_l, g_r}), .pad_sel(g_sel), .pad_sta(g_sta),
        .keys(map_keys), .kemp(map_kemp)
    );

    // latch on each report (the host's registers change byte by byte while
    // one arrives); nothing once the device goes
    reg [39:0] keys_u = 40'd0;
    reg [4:0]  kemp_u = 5'd0;
    reg        hit_t  = 1'b0;
    always @(posedge clk_usb) begin
        if (typ == 2'd0) begin
            keys_u <= 40'd0;
            kemp_u <= 5'd0;
        end else if (report) begin
            keys_u <= map_keys;
            kemp_u <= map_kemp;
            hit_t  <= ~hit_t;
        end
    end

    // into clk: levels, two flops each (a key a clock late is no matter)
    reg [39:0] keys_a = 40'd0, keys_b = 40'd0;
    reg [4:0]  kemp_a = 5'd0,  kemp_b = 5'd0;
    reg [2:0]  hit_s  = 3'b000;
    always @(posedge clk) begin
        keys_a <= keys_u; keys_b <= keys_a;
        kemp_a <= kemp_u; kemp_b <= kemp_a;
        hit_s  <= {hit_s[1:0], hit_t};
    end
    assign usb_keys = keys_b;
    assign kempston = kemp_b;
    assign usb_hit  = hit_s[2] ^ hit_s[1];

endmodule

// ============================================================================
//  zx_usb_map -- a HID report as membrane contacts and a Kempston byte
//  (combinational; sim/tb_usb.v checks it)
// ============================================================================
module zx_usb_map (
    input  wire [1:0]  typ,          // 1 keyboard, 3 gamepad
    input  wire [7:0]  kmod,         // HID modifiers: LCtl LSh LAlt LGui RCtl RSh RAlt RGui
    input  wire [7:0]  k1, k2, k3, k4,
    input  wire [4:0]  pad,          // {fire, up, down, left, right}
    input  wire        pad_sel, pad_sta,
    output reg  [39:0] keys,
    output wire [4:0]  kemp
);
    localparam CAPS = 0, SYM = 36, ENTER = 30, SPACE = 35;

    wire shift = kmod[1] | kmod[5];

    // one HID usage: {ok, caps, sym, pos[5:0]}.  Shifted digits and
    // punctuation are the US-layout character, as web/src/zxkeys.js types it.
    function [8:0] hid;
        input [7:0] u;
        input       sh;
        begin
            hid = 9'd0;
            case (u)
                // letters a..z
                8'h04: hid = {3'b100, 6'd5};   8'h05: hid = {3'b100, 6'd39};
                8'h06: hid = {3'b100, 6'd3};   8'h07: hid = {3'b100, 6'd7};
                8'h08: hid = {3'b100, 6'd12};  8'h09: hid = {3'b100, 6'd8};
                8'h0A: hid = {3'b100, 6'd9};   8'h0B: hid = {3'b100, 6'd34};
                8'h0C: hid = {3'b100, 6'd27};  8'h0D: hid = {3'b100, 6'd33};
                8'h0E: hid = {3'b100, 6'd32};  8'h0F: hid = {3'b100, 6'd31};
                8'h10: hid = {3'b100, 6'd37};  8'h11: hid = {3'b100, 6'd38};
                8'h12: hid = {3'b100, 6'd26};  8'h13: hid = {3'b100, 6'd25};
                8'h14: hid = {3'b100, 6'd10};  8'h15: hid = {3'b100, 6'd13};
                8'h16: hid = {3'b100, 6'd6};   8'h17: hid = {3'b100, 6'd14};
                8'h18: hid = {3'b100, 6'd28};  8'h19: hid = {3'b100, 6'd4};
                8'h1A: hid = {3'b100, 6'd11};  8'h1B: hid = {3'b100, 6'd2};
                8'h1C: hid = {3'b100, 6'd29};  8'h1D: hid = {3'b100, 6'd1};
                // digits 1..9 0, shifted: ! @ # $ % ^ & * ( )
                8'h1E: hid = {2'b10, sh, 6'd15};
                8'h1F: hid = {2'b10, sh, 6'd16};
                8'h20: hid = {2'b10, sh, 6'd17};
                8'h21: hid = {2'b10, sh, 6'd18};
                8'h22: hid = {2'b10, sh, 6'd19};
                8'h23: hid = sh ? {3'b101, 6'd34} : {3'b100, 6'd24};   // ^ = SYM+H
                8'h24: hid = sh ? {3'b101, 6'd24} : {3'b100, 6'd23};   // & = SYM+6
                8'h25: hid = sh ? {3'b101, 6'd39} : {3'b100, 6'd22};   // * = SYM+B
                8'h26: hid = sh ? {3'b101, 6'd22} : {3'b100, 6'd21};   // ( = SYM+8
                8'h27: hid = sh ? {3'b101, 6'd21} : {3'b100, 6'd20};   // ) = SYM+9
                8'h28, 8'h58: hid = {3'b100, 6'd30};                   // Enter, keypad Enter
                8'h29: hid = {3'b110, 6'd35};                          // Esc = BREAK
                8'h2A: hid = {3'b110, 6'd20};                          // Backspace = DELETE
                8'h2C: hid = {3'b100, 6'd35};                          // Space
                8'h2D: hid = {3'b101, sh ? 6'd20 : 6'd33};             // - _
                8'h2E: hid = {3'b101, sh ? 6'd32 : 6'd31};             // = +
                8'h33: hid = {3'b101, sh ? 6'd1  : 6'd26};             // ; :
                8'h34: hid = {3'b101, sh ? 6'd25 : 6'd23};             // ' "
                8'h36: hid = {3'b101, sh ? 6'd13 : 6'd38};             // , <
                8'h37: hid = {3'b101, sh ? 6'd14 : 6'd37};             // . >
                8'h38: hid = {3'b101, sh ? 6'd3  : 6'd4};              // / ?
                8'h39: hid = {3'b110, 6'd16};                          // Caps Lock = CAPS+2
                8'h4F: hid = {3'b110, 6'd22};                          // Right = CAPS+8
                8'h50: hid = {3'b110, 6'd19};                          // Left  = CAPS+5
                8'h51: hid = {3'b110, 6'd24};                          // Down  = CAPS+6
                8'h52: hid = {3'b110, 6'd23};                          // Up    = CAPS+7
                default: hid = 9'd0;
            endcase
        end
    endfunction

    wire [8:0] m1 = hid(k1, shift), m2 = hid(k2, shift), m3 = hid(k3, shift), m4 = hid(k4, shift);

    integer i;
    reg [8:0] m;
    reg       symchar;                // a held key is a SYMBOL SHIFT character
    always @* begin
        keys    = 40'd0;
        symchar = 1'b0;
        if (typ == 2'd1) begin
            for (i = 0; i < 4; i = i + 1) begin
                m = (i == 0) ? m1 : (i == 1) ? m2 : (i == 2) ? m3 : m4;
                if (m[8]) begin
                    keys[m[5:0]] = 1'b1;
                    if (m[7]) keys[CAPS] = 1'b1;
                    if (m[6]) begin keys[SYM] = 1'b1; symchar = 1'b1; end
                end
            end
            // shift picks the symbol for those, so it is not CAPS SHIFT too
            if (kmod[1] && !symchar) keys[CAPS] = 1'b1;
            if (kmod[0] | kmod[4] | kmod[5] | kmod[6]) keys[SYM] = 1'b1;
        end else if (typ == 2'd3) begin
            keys[ENTER] = pad_sta;
            keys[SPACE] = pad_sel;
        end
    end

    assign kemp = (typ == 2'd3) ? pad : 5'd0;
endmodule

`default_nettype wire
