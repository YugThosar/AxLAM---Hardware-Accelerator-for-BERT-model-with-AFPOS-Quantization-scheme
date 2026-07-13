// =============================================================================
// pe_qkv.v  —  AxLAM Project  |  PE-A: QKV / Attention Family
//
// Handles matrix operations with LIMITED data reuse:
//   QKV projections, Attention score (QK^T), Attention output (AV)
//
// Dataflow: L-STATIONARY
//   - L-buffer  (8 KB): holds a tile of the LEFT matrix (e.g., hidden states)
//   - R-buffer  (8 KB): cycles tiles of the RIGHT matrix (e.g., weight columns)
//   - A.SRAM    (24-bit accumulators, 16 entries): caches partial products
//     for one output tile row
//
// Operation per cycle:
//   For each R tile:
//     Issue 16 AFPOS MACs (one vector_mac_16 call) and accumulate into A.SRAM
//
// FSM States:
//   IDLE      — wait for start
//   LOAD_L    — fill L-buffer from HBM3
//   LOAD_R    — fill R-buffer from HBM3 (one column tile)
//   COMPUTE   — run vector_mac_16 for TILE_K/16 cycles
//   WRITEBACK — write A.SRAM partial sums back to HBM3
//   DONE      — assert done, return to IDLE
//
// Parameters:
//   TILE_K    — inner dimension tile size  (must be multiple of 16)
//   TILE_M    — output rows per tile
//   TILE_N    — output cols per tile
// =============================================================================
`timescale 1ns/1ps

module pe_qkv #(
    parameter TILE_K = 64,      // inner dim tile (must be mult of 16)
    parameter TILE_M = 8,       // rows per output tile
    parameter TILE_N = 8        // cols per output tile
)(
    input  wire        clk,
    input  wire        rst_n,
    // Control
    input  wire        start,
    output reg         done,
    // Matrix dimensions (full)
    input  wire [15:0] mat_M,   // total rows of L
    input  wire [15:0] mat_N,   // total cols of R
    input  wire [15:0] mat_K,   // inner dimension

    // HBM3 channel interface (simplified: 16 x 8-bit words per transfer)
    input  wire        hbm_rd_valid,
    input  wire [127:0] hbm_rd_data,   // 16 x 8-bit AFPOS words
    output reg         hbm_rd_req,
    output reg  [13:0] hbm_rd_addr,
    output reg  [3:0]  hbm_ch_sel,     // channel select
    output reg         hbm_wr_req,
    output reg  [13:0] hbm_wr_addr,
    output reg  [127:0] hbm_wr_data    // 16 x 8-bit output words (truncated)
);

    // -----------------------------------------------------------------------
    // L-buffer: 8 KB dual-port SRAM (TILE_M * TILE_K / 8 words of 64 bits)
    // R-buffer: 8 KB dual-port SRAM
    // A.SRAM  : 16 x 24-bit registers (one row of output accumulators)
    // -----------------------------------------------------------------------
    localparam L_DEPTH = (TILE_M * TILE_K) / 8;  // 64-bit words
    localparam R_DEPTH = (TILE_N * TILE_K) / 8;
    localparam ASRAM_ENTRIES = TILE_N;

    // L-buffer
    reg  [9:0]  l_wr_addr, l_rd_addr;
    reg         l_we;
    reg  [63:0] l_din;
    wire [63:0] l_dout_a, l_dout_b;

    sram_dp #(.DEPTH(L_DEPTH), .WIDTH(64), .ADDR_W(10)) u_lbuf (
        .clk    (clk),
        .a_we   (l_we),
        .a_addr (l_wr_addr),
        .a_din  (l_din),
        .a_dout (l_dout_a),
        .b_we   (1'b0),
        .b_addr (l_rd_addr),
        .b_din  (64'b0),
        .b_dout (l_dout_b)
    );

    // R-buffer
    reg  [9:0]  r_wr_addr, r_rd_addr;
    reg         r_we;
    reg  [63:0] r_din;
    wire [63:0] r_dout_a, r_dout_b;

    sram_dp #(.DEPTH(R_DEPTH), .WIDTH(64), .ADDR_W(10)) u_rbuf (
        .clk    (clk),
        .a_we   (r_we),
        .a_addr (r_wr_addr),
        .a_din  (r_din),
        .a_dout (r_dout_a),
        .b_we   (1'b0),
        .b_addr (r_rd_addr),
        .b_din  (64'b0),
        .b_dout (r_dout_b)
    );

    // A.SRAM: 16 x 24-bit accumulator registers
    reg [23:0] asram [0:15];
    reg [23:0] asram_next [0:15];

    // -----------------------------------------------------------------------
    // Vector MAC instantiation
    // -----------------------------------------------------------------------
    reg  [7:0]  L_vec [0:15];
    reg  [7:0]  R_vec [0:15];
    reg  [23:0] acc_in_vec [0:15];
    wire [23:0] acc_out_vec [0:15];
    reg         mac_en, mac_clear;
    wire [23:0] tree_sum;
    wire        mac_valid;

    vector_mac_16 u_vmac (
        .clk      (clk),
        .rst_n    (rst_n),
        .L_vec    (L_vec),
        .R_vec    (R_vec),
        .acc_in   (acc_in_vec),
        .en       (mac_en),
        .clear    (mac_clear),
        .acc_out  (acc_out_vec),
        .tree_sum (tree_sum),
        .valid_out(mac_valid)
    );

    // -----------------------------------------------------------------------
    // FSM
    // -----------------------------------------------------------------------
    localparam  S_IDLE      = 3'd0,
                S_LOAD_L    = 3'd1,
                S_LOAD_R    = 3'd2,
                S_COMPUTE   = 3'd3,
                S_WRITEBACK = 3'd4,
                S_DONE      = 3'd5;

    reg [2:0]  state;
    reg [15:0] cnt;           // general counter
    reg [15:0] k_cnt;         // inner-dim tile counter (0..TILE_K/16-1)
    reg [15:0] n_tile;        // current output-col tile index
    reg [15:0] m_tile;        // current output-row tile index
    integer    idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            done         <= 1'b0;
            mac_en       <= 1'b0;
            mac_clear    <= 1'b0;
            hbm_rd_req   <= 1'b0;
            hbm_wr_req   <= 1'b0;
            cnt          <= 16'd0;
            k_cnt        <= 16'd0;
            n_tile       <= 16'd0;
            m_tile       <= 16'd0;
            l_we         <= 1'b0;
            r_we         <= 1'b0;
            for (idx = 0; idx < 16; idx = idx + 1)
                asram[idx] <= 24'h000000;
        end else begin
            // Defaults
            mac_en    <= 1'b0;
            mac_clear <= 1'b0;
            l_we      <= 1'b0;
            r_we      <= 1'b0;
            hbm_rd_req<= 1'b0;
            hbm_wr_req<= 1'b0;
            done      <= 1'b0;

            case (state)
                // ----- IDLE ------------------------------------------------
                S_IDLE: begin
                    if (start) begin
                        n_tile <= 16'd0;
                        m_tile <= 16'd0;
                        cnt    <= 16'd0;
                        state  <= S_LOAD_L;
                    end
                end

                // ----- LOAD L-buffer from HBM3 ----------------------------
                S_LOAD_L: begin
                    hbm_rd_req  <= 1'b1;
                    hbm_ch_sel  <= 4'd0;             // channel 0 for L matrix
                    hbm_rd_addr <= cnt[13:0];
                    if (hbm_rd_valid) begin
                        l_we     <= 1'b1;
                        l_wr_addr<= cnt[9:0];
                        l_din    <= hbm_rd_data[63:0];
                        cnt      <= cnt + 16'd1;
                        if (cnt == L_DEPTH - 1) begin
                            cnt   <= 16'd0;
                            state <= S_LOAD_R;
                        end
                    end
                end

                // ----- LOAD R-buffer from HBM3 ----------------------------
                S_LOAD_R: begin
                    hbm_rd_req  <= 1'b1;
                    hbm_ch_sel  <= 4'd1;             // channel 1 for R matrix
                    hbm_rd_addr <= (n_tile * R_DEPTH[13:0]) + cnt[13:0];
                    if (hbm_rd_valid) begin
                        r_we     <= 1'b1;
                        r_wr_addr<= cnt[9:0];
                        r_din    <= hbm_rd_data[63:0];
                        cnt      <= cnt + 16'd1;
                        if (cnt == R_DEPTH - 1) begin
                            cnt   <= 16'd0;
                            k_cnt <= 16'd0;
                            // Clear A.SRAM before computing this tile
                            mac_clear <= 1'b1;
                            for (idx = 0; idx < 16; idx = idx + 1)
                                asram[idx] <= 24'h000000;
                            state <= S_COMPUTE;
                        end
                    end
                end

                // ----- COMPUTE: fire vector MAC for TILE_K/16 steps -------
                S_COMPUTE: begin
                    // Fetch 16 L elements and 16 R elements from buffers
                    l_rd_addr <= k_cnt[9:0];
                    r_rd_addr <= k_cnt[9:0];

                    // Feed from buffer output (1-cycle SRAM latency already)
                    begin : unpack_operands
                        integer jj;
                        for (jj = 0; jj < 16; jj = jj + 1) begin
                            L_vec[jj]    <= l_dout_b[(jj*8) +: 8];
                            R_vec[jj]    <= r_dout_b[(jj*8) +: 8];
                            acc_in_vec[jj] <= asram[jj];
                        end
                    end
                    mac_en <= 1'b1;

                    // Latch accumulator results one cycle later (mac_valid)
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

                // ----- WRITEBACK: stream A.SRAM back to HBM3 --------------
                S_WRITEBACK: begin
                    hbm_wr_req  <= 1'b1;
                    hbm_ch_sel  <= 4'd2;             // channel 2 for output
                    hbm_wr_addr <= (m_tile * TILE_N[13:0]) + n_tile[13:0];
                    // Pack 16 x 24-bit -> 128-bit (MSByte per accumulator, truncated)
                    begin : pack_output
                        integer jj;
                        for (jj = 0; jj < 16; jj = jj + 1)
                            hbm_wr_data[(jj*8) +: 8] <= asram[jj][21:14]; // Q10.14 -> 8 MSBits
                    end

                    // Advance tile indices
                    n_tile <= n_tile + 16'd1;
                    if (n_tile == (mat_N / TILE_N) - 1) begin
                        n_tile <= 16'd0;
                        m_tile <= m_tile + 16'd1;
                        if (m_tile == (mat_M / TILE_M) - 1)
                            state <= S_DONE;
                        else
                            state <= S_LOAD_L;
                    end else begin
                        state <= S_LOAD_R;  // same L tile, next R tile column
                    end
                    cnt <= 16'd0;
                end

                // ----- DONE ------------------------------------------------
                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
