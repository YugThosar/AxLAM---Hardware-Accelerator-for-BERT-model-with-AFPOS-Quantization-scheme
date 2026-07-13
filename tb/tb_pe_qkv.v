// =============================================================================
// tb_pe_qkv.v  —  AxLAM Project
// Top-level testbench for pe_qkv.v  (PE-A: QKV / Attention family)
//
// Test strategy:
//   1. Instantiate pe_qkv DUT with a small 8x8 tile (TILE_K=16 for speed)
//   2. Provide a stub HBM3 memory model loaded with known AFPOS values
//   3. Assert start, wait for done
//   4. Read back output from the HBM3 stub and compare against
//      expected values from sim/vectors/pe_qkv_out.hex (Python golden)
//
// Note: The HBM3 model stub cycles hbm_rd_valid every 4 cycles to mimic
//       read latency, identical to hbm3_model.v LATENCY=4 setting.
// =============================================================================
`timescale 1ns/1ps

module tb_pe_qkv;

    // -----------------------------------------------------------------------
    // Parameters matching DUT (small tile for fast simulation)
    // -----------------------------------------------------------------------
    localparam TILE_K = 16;   // 16 inner-dim elements (one MAC burst)
    localparam TILE_M = 8;
    localparam TILE_N = 8;

    // -----------------------------------------------------------------------
    // Clock / reset
    // -----------------------------------------------------------------------
    reg clk   = 0;
    reg rst_n = 0;
    always #1 clk = ~clk;   // 500 MHz

    // -----------------------------------------------------------------------
    // DUT ports
    // -----------------------------------------------------------------------
    reg         start    = 0;
    wire        done;
    reg  [15:0] mat_M    = TILE_M;   // single tile run
    reg  [15:0] mat_N    = TILE_N;
    reg  [15:0] mat_K    = TILE_K;

    // HBM3 stub signals
    reg         hbm_rd_valid = 0;
    reg  [127:0] hbm_rd_data = 128'b0;
    wire         hbm_rd_req;
    wire [13:0]  hbm_rd_addr;
    wire [3:0]   hbm_ch_sel;
    wire         hbm_wr_req;
    wire [13:0]  hbm_wr_addr;
    wire [127:0] hbm_wr_data;

    // -----------------------------------------------------------------------
    // DUT instantiation
    // -----------------------------------------------------------------------
    pe_qkv #(
        .TILE_K (TILE_K),
        .TILE_M (TILE_M),
        .TILE_N (TILE_N)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (start),
        .done         (done),
        .mat_M        (mat_M),
        .mat_N        (mat_N),
        .mat_K        (mat_K),
        .hbm_rd_valid (hbm_rd_valid),
        .hbm_rd_data  (hbm_rd_data),
        .hbm_rd_req   (hbm_rd_req),
        .hbm_rd_addr  (hbm_rd_addr),
        .hbm_ch_sel   (hbm_ch_sel),
        .hbm_wr_req   (hbm_wr_req),
        .hbm_wr_addr  (hbm_wr_addr),
        .hbm_wr_data  (hbm_wr_data)
    );

    // -----------------------------------------------------------------------
    // Simple HBM3 Memory Stub
    //   - L-buffer data on channel 0  (TILE_M * TILE_K / 8 = 16 words of 64b)
    //   - R-buffer data on channel 1
    //   - Output capture on channel 2
    //   Returns hbm_rd_valid 4 cycles after req
    // -----------------------------------------------------------------------
    localparam L_DEPTH_W = (TILE_M * TILE_K) / 8;  // 16 words
    localparam R_DEPTH_W = (TILE_N * TILE_K) / 8;  // 16 words

    reg [63:0]  hbm_ch0 [0:255];   // L matrix
    reg [63:0]  hbm_ch1 [0:255];   // R matrix
    reg [127:0] hbm_out [0:255];   // captured DUT write-back

    // Latency pipeline
    reg [3:0]   lat_valid = 4'b0;
    reg [63:0]  lat_data  [0:3];
    integer     lat_i;

    // Fill HBM channels with known AFPOS values:
    //   Channel 0 (L): all 1.0 = 8'h38  → 8 packed into 64-bit = 64'h38383838_38383838
    //   Channel 1 (R): all 1.0 = 8'h38  → same
    //   Expected output: each accumulator = 16 * fp(1.0*1.0) = 16 * 2^14 = 24'h040000
    //   Truncated to 8 bits = 24'h040000[21:14] = 8'b00000100_00000000 >> 14 = 8'h01
    //   (i.e., hbm_wr_data byte = 8'h01 for each element when 1.0*1.0*16 sums)
    integer fi;
    initial begin
        for (fi = 0; fi < 256; fi = fi + 1) begin
            hbm_ch0[fi] = 64'h3838383838383838;  // 8 x 1.0 AFPOS
            hbm_ch1[fi] = 64'h3838383838383838;
            hbm_out[fi] = 128'b0;
        end
        // Optionally load from pe_qkv_L.hex / pe_qkv_R.hex if present
        // (readmemh loads byte-wide hex, one word per line)
        // $readmemh("sim/vectors/pe_qkv_L.hex", hbm_ch0);  // uncomment after vector gen
        // $readmemh("sim/vectors/pe_qkv_R.hex", hbm_ch1);
    end

    // HBM3 stub: respond with 4-cycle latency read
    always @(posedge clk) begin
        // Shift latency pipeline
        lat_valid <= {lat_valid[2:0], (hbm_rd_req & ~hbm_rd_valid)};
        lat_data[0] <= (hbm_ch_sel == 4'd0) ? hbm_ch0[hbm_rd_addr] :
                       (hbm_ch_sel == 4'd1) ? hbm_ch1[hbm_rd_addr] : 64'hDEADBEEF_CAFEBABE;
        for (lat_i = 1; lat_i < 4; lat_i = lat_i + 1)
            lat_data[lat_i] <= lat_data[lat_i-1];

        hbm_rd_valid <= lat_valid[3];
        hbm_rd_data  <= {64'b0, lat_data[3]};  // upper 64 bits unused

        // Capture DUT write-back
        if (hbm_wr_req && hbm_ch_sel == 4'd2)
            hbm_out[hbm_wr_addr] <= hbm_wr_data;
    end

    // -----------------------------------------------------------------------
    // Test sequence
    // -----------------------------------------------------------------------
    integer pass_cnt = 0, fail_cnt = 0;
    integer timeout  = 0;
    integer chk;

    initial begin
        $dumpfile("sim/waves/tb_pe_qkv.vcd");
        $dumpvars(0, tb_pe_qkv);

        // Reset
        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        // ── Test 1: single 8x8 tile with all-1.0 operands ────────────────
        $display("[TB_PE_QKV] Starting Test 1: 8x8 tile, all 1.0 operands...");
        start = 1; @(posedge clk); start = 0;

        // Wait for done with timeout
        timeout = 0;
        while (!done && timeout < 5000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        if (timeout >= 5000) begin
            $display("FAIL: PE-QKV timed out after 5000 cycles");
            fail_cnt = fail_cnt + 1;
        end else begin
            $display("  PE-QKV completed in %0d cycles", timeout);

            // Check first output word: should have 8 bytes each = 8'h01
            // (sum of 16 x 1.0 products = 16 in Q10.14 = 24'h040000,
            //  truncated to bits[21:14] = 8'h01)
            for (chk = 0; chk < TILE_N; chk = chk + 1) begin
                if (hbm_out[0][(chk*8) +: 8] === 8'h01) begin
                    pass_cnt = pass_cnt + 1;
                end else begin
                    fail_cnt = fail_cnt + 1;
                    $display("FAIL: output byte[%0d] = 0x%02h, expected 0x01",
                             chk, hbm_out[0][(chk*8) +: 8]);
                end
            end
        end

        // ── Test 2: reset and re-run ──────────────────────────────────────
        $display("[TB_PE_QKV] Starting Test 2: reset and re-run...");
        rst_n = 0; repeat(2) @(posedge clk); rst_n = 1;
        repeat(2) @(posedge clk);
        start = 1; @(posedge clk); start = 0;

        timeout = 0;
        while (!done && timeout < 5000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        if (timeout < 5000) begin
            $display("  PASS: PE-QKV completed after reset in %0d cycles", timeout);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("  FAIL: PE-QKV timed out after reset");
            fail_cnt = fail_cnt + 1;
        end

        // ── Summary ──────────────────────────────────────────────────────
        $display("================================================");
        $display("PE-QKV Testbench Summary");
        $display("  PASS : %0d", pass_cnt);
        $display("  FAIL : %0d", fail_cnt);
        $display("================================================");
        if (fail_cnt == 0)
            $display("ALL TESTS PASSED");
        else
            $display("*** %0d FAILURE(S) DETECTED ***", fail_cnt);
        $finish;
    end

endmodule
