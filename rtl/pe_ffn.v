// =============================================================================
// pe_ffn.v  —  AxLAM Project  |  PE-B: FFN / BtlCont / BtlExp / MHead Family
//
// Handles matrix operations with HIGH data reuse:
//   Feed-Forward Network (FFN), Bottleneck Contraction, Bottleneck Expansion,
//   Multi-Head concatenation (MHead)
//
// Dataflow: R-STATIONARY
//   - R-buffer (8 KB): holds a weight tile STATIONARY across many input vectors
//   - L-buffer (8 KB): cycles through input tiles (activations)
//   - A.SRAM  (24-bit accumulators): caches partial products
//
// Key difference from PE-A:
//   - R-buffer is loaded ONCE; L-buffer is cycled over all input rows
//   - Exploits the high data reuse of FFN/BtlCont layers (up to 1024:1)
//   - Each R element participates in TILE_M output rows (amortised read cost)
//
// FSM States:
//   IDLE      — wait for start
//   LOAD_R    — load weight tile (done once per N-tile)
//   LOAD_L    — load next activation tile into L-buffer
//   COMPUTE   — run TILE_K/16 MAC cycles
//   WRITEBACK — write output tile to HBM3
//   DONE
// =============================================================================
`timescale 1ns/1ps

module pe_ffn #(
    parameter TILE_K = 64,      // inner dim tile (mult of 16)
    parameter TILE_M = 16,      // rows per output tile  (more reuse → larger)
    parameter TILE_N = 8        // cols per output tile
)(
    input  wire        clk,
    input  wire        rst_n,
    // Control
    input  wire        start,
    output reg         done,
    // Matrix dimensions
    input  wire [15:0] mat_M,
    input  wire [15:0] mat_N,
    input  wire [15:0] mat_K,
    // HBM3 simplified interface
    input  wire        hbm_rd_valid,
    input  wire [127:0] hbm_rd_data,
    output reg         hbm_rd_req,
    output reg  [13:0] hbm_rd_addr,
    output reg  [3:0]  hbm_ch_sel,
    output reg         hbm_wr_req,
    output reg  [13:0] hbm_wr_addr,
    output reg  [127:0] hbm_wr_data
);

    // -----------------------------------------------------------------------
    // Buffer sizing
    // -----------------------------------------------------------------------
    localparam L_DEPTH = (TILE_M * TILE_K) / 8;
    localparam R_DEPTH = (TILE_N * TILE_K) / 8;
    localparam ASRAM_E = TILE_N;

    // L-buffer (dual-port)
    reg  [9:0]  l_wr_addr, l_rd_addr;
    reg         l_we;
    reg  [63:0] l_din;
    wire [63:0] l_dout_a, l_dout_b;

    sram_dp #(.DEPTH(L_DEPTH), .WIDTH(64), .ADDR_W(10)) u_lbuf (
        .clk(clk),
        .a_we(l_we), .a_addr(l_wr_addr), .a_din(l_din), .a_dout(l_dout_a),
        .b_we(1'b0), .b_addr(l_rd_addr), .b_din(64'b0), .b_dout(l_dout_b)
    );

    // R-buffer (dual-port — stays stationary)
    reg  [9:0]  r_wr_addr, r_rd_addr;
    reg         r_we;
    reg  [63:0] r_din;
    wire [63:0] r_dout_a, r_dout_b;

    sram_dp #(.DEPTH(R_DEPTH), .WIDTH(64), .ADDR_W(10)) u_rbuf (
        .clk(clk),
        .a_we(r_we), .a_addr(r_wr_addr), .a_din(r_din), .a_dout(r_dout_a),
        .b_we(1'b0), .b_addr(r_rd_addr), .b_din(64'b0), .b_dout(r_dout_b)
    );

    // A.SRAM: TILE_N x 24-bit accumulators
    reg [23:0] asram [0:15];

    // -----------------------------------------------------------------------
    // Vector MAC
    // -----------------------------------------------------------------------
    reg  [7:0]  L_vec [0:15];
    reg  [7:0]  R_vec [0:15];
    reg  [23:0] acc_in_vec [0:15];
    wire [23:0] acc_out_vec[0:15];
    reg         mac_en, mac_clear;
    wire [23:0] tree_sum;
    wire        mac_valid;

    vector_mac_16 u_vmac (
        .clk(clk), .rst_n(rst_n),
        .L_vec(L_vec), .R_vec(R_vec),
        .acc_in(acc_in_vec), .en(mac_en), .clear(mac_clear),
        .acc_out(acc_out_vec), .tree_sum(tree_sum), .valid_out(mac_valid)
    );

    // -----------------------------------------------------------------------
    // FSM
    // -----------------------------------------------------------------------
    localparam  S_IDLE      = 3'd0,
                S_LOAD_R    = 3'd1,   // load weight tile (R stationary)
                S_LOAD_L    = 3'd2,   // load next activation tile
                S_COMPUTE   = 3'd3,
                S_WRITEBACK = 3'd4,
                S_DONE      = 3'd5;

    reg [2:0]  state;
    reg [15:0] cnt, k_cnt, n_tile, m_tile;
    integer    idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            done       <= 1'b0;
            mac_en     <= 1'b0;
            mac_clear  <= 1'b0;
            hbm_rd_req <= 1'b0;
            hbm_wr_req <= 1'b0;
            cnt        <= 16'd0;
            k_cnt      <= 16'd0;
            n_tile     <= 16'd0;
            m_tile     <= 16'd0;
            l_we       <= 1'b0;
            r_we       <= 1'b0;
            for (idx = 0; idx < 16; idx = idx + 1)
                asram[idx] <= 24'h000000;
        end else begin
            mac_en     <= 1'b0;
            mac_clear  <= 1'b0;
            l_we       <= 1'b0;
            r_we       <= 1'b0;
            hbm_rd_req <= 1'b0;
            hbm_wr_req <= 1'b0;
            done       <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        n_tile <= 16'd0; m_tile <= 16'd0;
                        cnt    <= 16'd0;
                        state  <= S_LOAD_R;
                    end
                end

                // Load weight tile once per N column tile
                S_LOAD_R: begin
                    hbm_rd_req  <= 1'b1;
                    hbm_ch_sel  <= 4'd1;
                    hbm_rd_addr <= (n_tile * R_DEPTH[13:0]) + cnt[13:0];
                    if (hbm_rd_valid) begin
                        r_we      <= 1'b1;
                        r_wr_addr <= cnt[9:0];
                        r_din     <= hbm_rd_data[63:0];
                        cnt       <= cnt + 16'd1;
                        if (cnt == R_DEPTH - 1) begin
                            cnt   <= 16'd0;
                            state <= S_LOAD_L;
                        end
                    end
                end

                // Cycle through all L (activation) tiles against this R tile
                S_LOAD_L: begin
                    hbm_rd_req  <= 1'b1;
                    hbm_ch_sel  <= 4'd0;
                    hbm_rd_addr <= (m_tile * L_DEPTH[13:0]) + cnt[13:0];
                    if (hbm_rd_valid) begin
                        l_we      <= 1'b1;
                        l_wr_addr <= cnt[9:0];
                        l_din     <= hbm_rd_data[63:0];
                        cnt       <= cnt + 16'd1;
                        if (cnt == L_DEPTH - 1) begin
                            cnt   <= 16'd0;
                            k_cnt <= 16'd0;
                            mac_clear <= 1'b1;
                            for (idx = 0; idx < 16; idx = idx + 1)
                                asram[idx] <= 24'h000000;
                            state <= S_COMPUTE;
                        end
                    end
                end

                S_COMPUTE: begin
                    l_rd_addr <= k_cnt[9:0];
                    r_rd_addr <= k_cnt[9:0];
                    begin : unpack
                        integer jj;
                        for (jj = 0; jj < 16; jj = jj + 1) begin
                            L_vec[jj]      <= l_dout_b[(jj*8) +: 8];
                            R_vec[jj]      <= r_dout_b[(jj*8) +: 8];
                            acc_in_vec[jj] <= asram[jj];
                        end
                    end
                    mac_en <= 1'b1;

                    if (mac_valid) begin
                        for (idx = 0; idx < 16; idx = idx + 1)
                            asram[idx] <= acc_out_vec[idx];
                        k_cnt <= k_cnt + 16'd1;
                        if (k_cnt == (TILE_K/16 - 1)) begin
                            k_cnt <= 16'd0;
                            state <= S_WRITEBACK;
                        end
                    end
                end

                S_WRITEBACK: begin
                    hbm_wr_req  <= 1'b1;
                    hbm_ch_sel  <= 4'd2;
                    hbm_wr_addr <= (m_tile * TILE_N[13:0]) + n_tile[13:0];
                    begin : pack
                        integer jj;
                        for (jj = 0; jj < 16; jj = jj + 1)
                            hbm_wr_data[(jj*8) +: 8] <= asram[jj][21:14];
                    end

                    // R-stationary: advance M (rows) first, then N (cols)
                    m_tile <= m_tile + 16'd1;
                    if (m_tile == (mat_M / TILE_M) - 1) begin
                        m_tile <= 16'd0;
                        n_tile <= n_tile + 16'd1;
                        if (n_tile == (mat_N / TILE_N) - 1)
                            state <= S_DONE;
                        else
                            state <= S_LOAD_R;   // new N-tile -> reload R
                    end else begin
                        state <= S_LOAD_L;        // same R tile, next M tile
                    end
                    cnt <= 16'd0;
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
