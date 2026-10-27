// ============================================================================
//  zx_snap.v -- Z80 Snapshot (.Z80) Loader for ZX Spectrum 48K
//
//  Receives snapshot data over UART packets (0xFC leader):
//    0xFC 0x01                          : Enter snapshot mode, pause CPU
//    0xFC 0x02 <a_lo> <a_hi> <l_lo> <l_hi> <data...> : Write RAM chunk
//    0xFC 0x03 <border>                 : Set border color (0..7)
//    0xFC 0x04 <28 register bytes>      : Set CPU registers trampoline
//    0xFC 0x05                          : Release CPU, execute trampoline to PC
// ============================================================================
`default_nettype none

module zx_snap (
    input  wire        clk,
    input  wire        reset,

    // UART byte stream from zx_input / UART RX
    input  wire        rx_valid,
    input  wire [7:0]  rx_byte,

    // CPU control & RAM interface
    output reg         pause_cpu = 1'b0,
    output reg         cpu_reset_req = 1'b0,
    output reg         ram_wr = 1'b0,
    output reg  [15:0] ram_addr = 16'd0,
    output reg  [7:0]  ram_data = 8'h00,

    // Border override
    output reg  [2:0]  border = 3'd0,
    output reg         border_set = 1'b0,

    // Boot trampoline overlay (at 0x0000..0x003F)
    input  wire [15:0] cpu_addr,
    input  wire        cpu_m1_n,
    output reg         boot_active = 1'b0,
    output wire [7:0]  boot_dout
);

    localparam [3:0] S_IDLE      = 4'd0,
                     S_SUBCMD    = 4'd1,
                     S_RAM_A0    = 4'd2,
                     S_RAM_A1    = 4'd3,
                     S_RAM_L0    = 4'd4,
                     S_RAM_L1    = 4'd5,
                     S_RAM_DATA  = 4'd6,
                     S_BORDER    = 4'd7,
                     S_REG_BYTE  = 4'd8;

    reg [3:0]  st = S_IDLE;
    reg [15:0] cur_addr = 16'd0;
    reg [15:0] cur_len  = 16'd0;
    reg [4:0]  reg_idx  = 5'd0;

    // Registers received in 0xFC 0x04:
    // 0..1: PC, 2..3: SP, 4..5: AF, 6..7: BC, 8..9: DE, 10..11: HL
    // 12..13: AF', 14..15: BC', 16..17: DE', 18..19: HL'
    // 20..21: IX, 22..23: IY
    // 24: I, 25: R, 26: IM (0, 1, 2), 27: IFF1 (0: DI, 1: EI)
    reg [7:0] snap_regs [0:27];

    // Trampoline buffer (up to 64 bytes at 0x0000)
    reg [7:0] tramp [0:63];

    assign boot_dout = (cpu_addr < 16'd64) ? tramp[cpu_addr[5:0]] : 8'h00;

    // Reset CPU pulse generation
    reg [3:0] rst_cnt = 4'd0;

    task build_trampoline;
        integer i;
        begin
            for (i = 0; i < 64; i = i + 1) tramp[i] = 8'h00; // NOPs

            // 0: DI (0xF3)
            tramp[0]  = 8'hF3;
            // 1..3: LD SP, <sp> (31 lo hi)
            tramp[1]  = 8'h31;
            tramp[2]  = snap_regs[2];
            tramp[3]  = snap_regs[3];
            // 4..6: LD BC, <bc'> (01 lo hi)
            tramp[4]  = 8'h01;
            tramp[5]  = snap_regs[14];
            tramp[6]  = snap_regs[15];
            // 7..9: LD DE, <de'> (11 lo hi)
            tramp[7]  = 8'h11;
            tramp[8]  = snap_regs[16];
            tramp[9]  = snap_regs[17];
            // 10..12: LD HL, <hl'> (21 lo hi)
            tramp[10] = 8'h21;
            tramp[11] = snap_regs[18];
            tramp[12] = snap_regs[19];
            // 13: EXX (0xD9)
            tramp[13] = 8'hD9;
            // 14..16: LD BC, <af'> (01 lo hi) then PUSH BC (C5) POP AF (F1) EX AF,AF' (08)
            tramp[14] = 8'h01;
            tramp[15] = snap_regs[12];
            tramp[16] = snap_regs[13];
            tramp[17] = 8'hC5; // PUSH BC
            tramp[18] = 8'hF1; // POP AF
            tramp[19] = 8'h08; // EX AF, AF'
            // 20..23: LD IX, <ix> (DD 21 lo hi)
            tramp[20] = 8'hDD;
            tramp[21] = 8'h21;
            tramp[22] = snap_regs[20];
            tramp[23] = snap_regs[21];
            // 24..27: LD IY, <iy> (FD 21 lo hi)
            tramp[24] = 8'hFD;
            tramp[25] = 8'h21;
            tramp[26] = snap_regs[22];
            tramp[27] = snap_regs[23];
            // 28..30: LD HL, <hl> (21 lo hi)
            tramp[28] = 8'h21;
            tramp[29] = snap_regs[10];
            tramp[30] = snap_regs[11];
            // 31..33: LD DE, <de> (11 lo hi)
            tramp[31] = 8'h11;
            tramp[32] = snap_regs[8];
            tramp[33] = snap_regs[9];
            // 34..36: LD BC, <af> (01 lo hi) then PUSH BC (C5) POP AF (F1)
            tramp[34] = 8'h01;
            tramp[35] = snap_regs[4];
            tramp[36] = snap_regs[5];
            tramp[37] = 8'hC5; // PUSH BC
            tramp[38] = 8'hF1; // POP AF
            // 39..41: LD BC, <bc> (01 lo hi)
            tramp[39] = 8'h01;
            tramp[40] = snap_regs[6];
            tramp[41] = snap_regs[7];
            // 42..43: LD A, <I> (3E lo), LD I, A (ED 47)
            tramp[42] = 8'h3E;
            tramp[43] = snap_regs[24];
            tramp[44] = 8'hED;
            tramp[45] = 8'h47;
            // 46..49: LD A, <R> (3E lo), LD R, A (ED 4F)
            tramp[46] = 8'h3E;
            tramp[47] = snap_regs[25];
            tramp[48] = 8'hED;
            tramp[49] = 8'h4F;
            // 50..51: IM mode (ED 46 for IM0, ED 56 for IM1, ED 5E for IM2)
            tramp[50] = 8'hED;
            tramp[51] = (snap_regs[26] == 8'd2) ? 8'h5E : (snap_regs[26] == 8'd0) ? 8'h46 : 8'h56;
            // 52: EI (0xFB) if iff1!=0, else DI (0xF3)
            tramp[52] = (snap_regs[27] != 8'd0) ? 8'hFB : 8'hF3;
            // 53..55: JP <PC> (C3 lo hi)
            tramp[53] = 8'hC3;
            tramp[54] = snap_regs[0];
            tramp[55] = snap_regs[1];
        end
    endtask

    always @(posedge clk) begin
        ram_wr        <= 1'b0;
        border_set    <= 1'b0;
        cpu_reset_req <= 1'b0;

        if (reset) begin
            st          <= S_IDLE;
            pause_cpu   <= 1'b0;
            boot_active <= 1'b0;
            rst_cnt     <= 4'd0;
        end else begin
            // Deassert boot_active when CPU leaves the 0x0000..0x003F region
            if (boot_active && !cpu_m1_n && (cpu_addr >= 16'd64)) begin
                boot_active <= 1'b0;
            end

            if (rst_cnt != 4'd0) begin
                rst_cnt       <= rst_cnt - 4'd1;
                cpu_reset_req <= 1'b1;
            end

            if (rx_valid) begin
                case (st)
                    S_IDLE: begin
                        if (rx_byte == 8'hFC) st <= S_SUBCMD;
                    end
                    S_SUBCMD: begin
                        case (rx_byte)
                            8'h01: begin // Enter snapshot mode
                                pause_cpu <= 1'b1;
                                st        <= S_IDLE;
                            end
                            8'h02: st <= S_RAM_A0;
                            8'h03: st <= S_BORDER;
                            8'h04: begin
                                reg_idx <= 5'd0;
                                st      <= S_REG_BYTE;
                            end
                            8'h05: begin // Execute!
                                build_trampoline();
                                boot_active   <= 1'b1;
                                pause_cpu     <= 1'b0;
                                rst_cnt       <= 4'd8; // 8-clock reset pulse to Z80
                                st            <= S_IDLE;
                            end
                            default: st <= S_IDLE;
                        endcase
                    end
                    S_RAM_A0: begin
                        cur_addr[7:0] <= rx_byte;
                        st <= S_RAM_A1;
                    end
                    S_RAM_A1: begin
                        cur_addr[15:8] <= rx_byte;
                        st <= S_RAM_L0;
                    end
                    S_RAM_L0: begin
                        cur_len[7:0] <= rx_byte;
                        st <= S_RAM_L1;
                    end
                    S_RAM_L1: begin
                        cur_len[15:8] <= rx_byte;
                        st <= S_RAM_DATA;
                    end
                    S_RAM_DATA: begin
                        ram_addr <= cur_addr;
                        ram_data <= rx_byte;
                        ram_wr   <= 1'b1;
                        cur_addr <= cur_addr + 16'd1;
                        if (cur_len <= 16'd1) begin
                            st <= S_IDLE;
                        end else begin
                            cur_len <= cur_len - 16'd1;
                        end
                    end
                    S_BORDER: begin
                        border     <= rx_byte[2:0];
                        border_set <= 1'b1;
                        st         <= S_IDLE;
                    end
                    S_REG_BYTE: begin
                        snap_regs[reg_idx] <= rx_byte;
                        if (reg_idx == 5'd27) st <= S_IDLE;
                        else reg_idx <= reg_idx + 5'd1;
                    end
                    default: st <= S_IDLE;
                endcase
            end
        end
    end

endmodule
`default_nettype wire
