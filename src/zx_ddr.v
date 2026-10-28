// ============================================================================
//  zx_ddr.v -- the Tang Primer 20K's DDR3 (H5TQ1G63EFR, 128 MB x16), wrapped
//
//  A trimmed adaptation of the sibling project's src/aux_ram.v, which is the
//  proven way to drive this board's DDR3: same encrypted IP netlist (src/
//  ddr3_memory_interface/, Gowin 1.9.8 generation -- see its README for why
//  that one), same reset sequencing, same self-test, same clock crossing.
//
//  The IP's user side runs on its own clk_out (memory clock / 4, ~100 MHz),
//  not phase-related to clk.  One operation at a time crosses between them
//  by a toggle handshake: the 27 MHz side holds we/addr/data steady, flips
//  req_t, and waits for ack_t to flip back, which the DDR side does only
//  after rdata is final.  Every multi-bit value that crosses is therefore
//  stable for at least two clocks of the receiving domain before use; the
//  .sdc declares the domains asynchronous.
//
//  One burst = one BL8 = 8 x 16-bit words = 128 bits per command.  A client
//  addresses whole 16-bit words (26 bits: the IP wants {rank, bank, row,
//  col}; its 14 row bits top out at 8K rows, so row bit 13 stays 0).
//
//  Word address map:
//      self-test burst     {4'b0011, 22'd0}    written at init, then read back
//      client requests     any word address (future: 128K banks, storage)
//
//  After calibration the self-test writes eight distinct words, reads them
//  back, overwrites word 3 through a byte mask and reads that back -- which
//  pins the beat order, the mask polarity and that writes land at all.  Only
//  then does `ready` rise.  A failure leaves it low (LED 1 stays lit).
// ============================================================================

`default_nettype none

module zx_ddr (
    input  wire        clk,          // 27 MHz: client side (clk_pixel)
    input  wire        reset,
    input  wire        ddr_ref_clk,   // 27 MHz crystal: the IP's reference clock

    // one general client: latch-on-go, ack pulse when done (rdata valid on reads)
    input  wire        go,
    input  wire [25:0] addr,         // word address
    input  wire        we,
    input  wire [1:0]  be,           // bytes of the word a write changes (bit0 = low)
    input  wire [15:0] wdata,
    output reg  [15:0] rdata = 16'hFFFF,
    output reg         ack = 1'b0,
    output wire        idle,         // no request waiting

    // 1 once the DDR3 has calibrated and passed its self-test (clk domain)
    output wire        ready,

    input  wire        ddr_memory_clk,   // 398.25 MHz from clk_gen's rPLL
    input  wire        ddr_lock,

    // DDR3 pins
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

    // =====================================================================
    // 27 MHz side: request latch and handshake
    // =====================================================================

    reg         req_t = 1'b0;          // flips once per operation
    reg         req_we = 1'b0;
    reg  [25:0] req_addr = 26'd0;
    reg  [15:0] req_wdata = 16'd0;
    reg  [1:0]  req_be = 2'b11;
    wire        ack_t_m;               // ack_t from the DDR side, synced below
    reg  [2:0]  ack_s = 3'd0;
    reg  [1:0]  rdy_s = 2'd0;
    wire        ddr_ready;
    wire [15:0] ddr_rdata;

    always @(posedge clk) begin
        ack_s <= {ack_s[1:0], ack_t_m};
        rdy_s <= {rdy_s[0], ddr_ready};
    end
    assign ready = rdy_s[1];
    wire ack_edge = ack_s[2] ^ ack_s[1];

    reg        pend = 1'b0;            // a request is waiting to be sent
    reg        a_we = 1'b0;
    reg [25:0] a_addr = 26'd0;
    reg [1:0]  a_be = 2'b11;
    reg [15:0] a_wdata = 16'd0;
    assign idle = !pend;

    reg op_busy = 1'b0;

    always @(posedge clk) begin
        ack <= 1'b0;
        if (reset) begin
            pend <= 1'b0;              // an in-flight op is never abandoned
        end

        if (go && ready) begin
            pend    <= 1'b1;
            a_we    <= we;
            a_addr  <= addr;
            a_be    <= be;
            a_wdata <= wdata;
        end

        if (op_busy) begin
            if (ack_edge) begin
                op_busy <= 1'b0;
                rdata   <= ddr_rdata;
                ack     <= 1'b1;
                pend    <= 1'b0;
            end
        end else if (ready && pend && !go) begin   // a new go waits a clock
            req_we    <= a_we;
            req_addr  <= a_addr;
            req_wdata <= a_wdata;
            req_be    <= a_be;
            op_busy   <= 1'b1;
            req_t     <= ~req_t;
        end
    end

    // =====================================================================
    // DDR side (mclk, the IP's clk_out): one operation per request
    // =====================================================================

    wire        mclk;
    reg  [1:0]  req_s = 2'd0;
    reg         req_seen = 1'b0;       // req_t as of the last request taken
    reg         ack_t = 1'b0;
    reg  [15:0] rdata_m = 16'd0;
    assign ack_t_m   = ack_t;
    assign ddr_rdata = rdata_m;

    wire         m_calib, m_cmd_ready, m_wr_rdy, m_rd_valid;
    wire [127:0] m_rd_data;
    reg          m_wr = 1'b0;          // the command is a write (else a read)
    reg  [25:0]  m_addr = 26'd0;       // word address; the burst is m_addr[25:3]
    reg  [15:0]  m_wd = 16'd0;         // write data, in every word of the burst
    reg  [15:0]  m_mask = 16'h0000;    // 1 = byte not written

    // E_IDLE: wait for a request.  E_CMD: a command is ready and presented
    // until the IP takes it (cmd_en is combinational on its ready signals).
    // E_RD: a read has gone; wait for its burst.
    localparam [1:0] E_IDLE = 2'd0, E_CMD = 2'd1, E_RD = 2'd2;
    reg [1:0] e = E_IDLE;

    wire        m_cmd_en = (e == E_CMD) && m_cmd_ready && (!m_wr || m_wr_rdy);
    wire [15:0] m_word   = m_rd_data[{m_addr[2:0], 4'd0} +: 16];

    // Init: after calibration, write one burst of eight distinct words, read
    // it back, overwrite word 3 alone with a byte mask, and read it back
    // again.  A failure leaves the DDR3 not ready.
    reg         init_done = 1'b0;
    reg  [1:0]  tst = 2'd0;            // 0 burst write, 1 read, 2 masked write, 3 read
    reg         tbad = 1'b0;
    function [15:0] pat(input [2:0] i);
        pat = 16'h5AA5 ^ ({13'd0, i} * 16'h1111);
    endfunction
    reg [127:0] t_want;                // what the self-test expects back, and writes
    integer k;
    always @* for (k = 0; k < 8; k = k + 1)
        t_want[16*k +: 16] = (tst[1] && k == 3) ? 16'hC33C : pat(k[2:0]);
    wire t_ok = (m_rd_data == t_want);
    wire testing = !init_done;

    wire [127:0] m_wr_data = testing ? t_want : {8{m_wd}};

    always @(posedge mclk) begin
        req_s <= {req_s[0], req_t};

        case (e)
            E_IDLE:
                if (testing) begin
                    if (m_calib && !tbad) begin
                        m_addr <= {4'b0011, 22'd0};
                        m_wr   <= !tst[0];                           // steps 0, 2 write
                        m_mask <= (tst == 2'd2) ? 16'hFF3F : 16'h0000; // step 2: word 3 only
                        e <= E_CMD;
                    end
                end else if (req_s[1] != req_seen) begin
                    // req_t flipped at least two clocks ago; the request
                    // fields were already steady when it did.
                    req_seen <= req_s[1];
                    m_addr <= req_addr;
                    m_wd   <= req_wdata;
                    m_wr   <= req_we;
                    m_mask <= ~({14'd0, req_be} << {req_addr[2:0], 1'b0});
                    e <= E_CMD;
                end
            E_CMD:
                if (m_cmd_en) begin
                    if (!m_wr) e <= E_RD;
                    else begin
                        e <= E_IDLE;
                        if (testing) tst <= tst + 1'b1;
                        else ack_t <= ~ack_t;
                    end
                end
            E_RD:
                if (m_rd_valid) begin
                    e <= E_IDLE;
                    if (testing) begin
                        tst <= tst + 1'b1;
                        if (!t_ok) tbad <= 1'b1;
                        else if (tst == 2'd3) init_done <= 1'b1;
                    end else begin
                        rdata_m <= m_word;
                        ack_t <= ~ack_t;
                    end
                end
            default: e <= E_IDLE;
        endcase
    end
    assign ddr_ready = init_done;


    // The IP's reset: held low while PLL is locking, then held low for
    // 128 cycles of ddr_clk after pll_lock is high, before releasing.
    reg [7:0] ip_rst_cnt = 8'd0;
    wire      ip_rst_n   = ip_rst_cnt[7];
    always @(posedge ddr_memory_clk or negedge ddr_lock) begin
        if (!ddr_lock)
            ip_rst_cnt <= 8'd0;
        else if (!ip_rst_n)
            ip_rst_cnt <= ip_rst_cnt + 1'b1;
    end

    DDR3_Memory_Interface_Top u_ip (
        .clk(ddr_ref_clk), .memory_clk(ddr_memory_clk), .pll_lock(ddr_lock), .rst_n(ip_rst_n),
        .app_burst_number(6'd0),             // one burst per command
        .clk_out(mclk), .ddr_rst(), .init_calib_complete(m_calib),
        .cmd_ready(m_cmd_ready), .cmd(m_wr ? 3'd0 : 3'd1), .cmd_en(m_cmd_en),
        .addr({1'b0, m_addr[25:23], 1'b0, m_addr[22:3], 3'b000}),   // {rank, bank, row[13:0], col}
        .wr_data_rdy(m_wr_rdy), .wr_data(m_wr_data), .wr_data_en(m_cmd_en && m_wr),
        .wr_data_end(m_cmd_en && m_wr), .wr_data_mask(m_mask),
        .rd_data(m_rd_data), .rd_data_valid(m_rd_valid), .rd_data_end(),
        .sr_req(1'b0), .ref_req(1'b0), .sr_ack(), .ref_ack(), .burst(1'b1),
        .O_ddr_addr(DDR3_A), .O_ddr_ba(DDR3_BA), .O_ddr_cs_n(DDR3_nCS),
        .O_ddr_ras_n(DDR3_nRAS), .O_ddr_cas_n(DDR3_nCAS), .O_ddr_we_n(DDR3_nWE),
        .O_ddr_clk(DDR3_CK), .O_ddr_clk_n(DDR3_CK_n), .O_ddr_cke(DDR3_CKE),
        .O_ddr_odt(DDR3_ODT), .O_ddr_reset_n(DDR3_nRESET), .O_ddr_dqm(DDR3_DM),
        .IO_ddr_dq(DDR3_DQ), .IO_ddr_dqs(DDR3_DQS), .IO_ddr_dqs_n(DDR3_DQS_n)
    );

endmodule

`default_nettype wire
