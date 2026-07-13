// =============================================================================
// tb_vector_mac_16.v  —  AxLAM Testbench
// Testbench for vector_mac_16.v
//
// Reads operand tiles from sim/vectors/vmac_test.hex and checks accumulated
// sums against Python golden (sim/vectors/vmac_expected.hex).
// =============================================================================
`timescale 1ns/1ps

module tb_vector_mac_16;

    reg        clk   = 0;
    reg        rst_n = 0;
    reg  [7:0] L_vec [0:15];
    reg  [7:0] R_vec [0:15];
    reg  [23:0] acc_in [0:15];
    reg        en    = 0;
    reg        clear = 0;

    wire [23:0] acc_out [0:15];
    wire [23:0] tree_sum;
    wire        valid_out;

    // DUT
    vector_mac_16 dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .L_vec    (L_vec),
        .R_vec    (R_vec),
        .acc_in   (acc_in),
        .en       (en),
        .clear    (clear),
        .acc_out  (acc_out),
        .tree_sum (tree_sum),
        .valid_out(valid_out)
    );

    // 500 MHz clock (2 ns period)
    always #1 clk = ~clk;

    integer i, pass_cnt = 0, fail_cnt = 0;
    integer vec_fd, exp_fd, scan_ret;
    integer test_num = 0;

    reg [23:0] expected_sum;
    reg [7:0]  l_tmp, r_tmp;
    integer    tmp;

    task apply_zero_vectors;
        integer jj;
        begin
            for (jj = 0; jj < 16; jj = jj + 1) begin
                L_vec[jj]    = 8'h00;
                R_vec[jj]    = 8'h00;
                acc_in[jj]   = 24'h000000;
            end
        end
    endtask

    initial begin
        $dumpfile("sim/waves/tb_vector_mac_16.vcd");
        $dumpvars(0, tb_vector_mac_16);
        apply_zero_vectors();

        // Reset
        @(posedge clk); rst_n = 0;
        @(posedge clk); rst_n = 1;
        @(posedge clk);

        // ----------------------------------------------------------------
        // Test 1: All zeros -> accumulated sum = 0
        // ----------------------------------------------------------------
        apply_zero_vectors();
        clear = 1; en = 1; @(posedge clk);
        clear = 0; en = 0;
        @(posedge clk); // wait for pipeline
        if (tree_sum === 24'h000000)
            $display("PASS [T%0d]: All-zero vector sum = 0", test_num);
        else begin
            $display("FAIL [T%0d]: Expected 0, got %06h", test_num, tree_sum);
            fail_cnt = fail_cnt + 1;
        end
        pass_cnt = pass_cnt + 1;
        test_num = test_num + 1;

        // ----------------------------------------------------------------
        // Test 2: 1.0 * 1.0 x16  -> tree_sum = 16 x fp(1.0)
        // 1.0 in AFPOS = 8'h38 (sign=0, exp=7, mant=0)
        // 1.0 in Q10.14 = 1 << 14 = 16384 = 24'h004000
        // 16 x 1.0 = 16384*16 = 262144 = 24'h040000
        // ----------------------------------------------------------------
        begin : t2
            integer jj;
            for (jj = 0; jj < 16; jj = jj + 1) begin
                L_vec[jj]  = 8'h38;
                R_vec[jj]  = 8'h38;
                acc_in[jj] = 24'h000000;
            end
        end
        clear = 1; @(posedge clk); clear = 0;
        en = 1; @(posedge clk); en = 0;
        @(posedge clk); // pipeline flush
        if (tree_sum === 24'h040000)
            $display("PASS [T%0d]: 16x(1.0*1.0) tree_sum = 0x040000", test_num);
        else begin
            $display("FAIL [T%0d]: 16x(1.0*1.0) tree_sum expected 0x040000, got 0x%06h",
                     test_num, tree_sum);
            fail_cnt = fail_cnt + 1;
        end
        pass_cnt = pass_cnt + 1;
        test_num = test_num + 1;

        // ----------------------------------------------------------------
        // File-based tests from Python golden model  (100 test vectors)
        // ----------------------------------------------------------------
        vec_fd = $fopen("sim/vectors/vmac_test.hex",     "r");
        exp_fd = $fopen("sim/vectors/vmac_expected.hex", "r");

        if (vec_fd == 0 || exp_fd == 0) begin
            $display("NOTE: Vector files not found, skipping file tests.");
            $display("      Run sim/gen_test_vectors.py first.");
        end else begin
            // Iterate exactly 100 times (one pass per vector pair in the file)
            begin : file_loop
                integer vec_idx;
                for (vec_idx = 0; vec_idx < 100; vec_idx = vec_idx + 1) begin
                    begin : load_vecs
                        integer jj;
                        for (jj = 0; jj < 16; jj = jj + 1) begin
                            scan_ret = $fscanf(vec_fd, "%h %h\n", l_tmp, r_tmp);
                            if (scan_ret < 2) begin
                                $display("NOTE: EOF reached after %0d vectors", vec_idx);
                                disable file_loop;
                            end
                            L_vec[jj]  = l_tmp;
                            R_vec[jj]  = r_tmp;
                            acc_in[jj] = 24'h000000;
                        end
                    end
                    $fscanf(exp_fd, "%h\n", expected_sum);
                    clear = 1; @(posedge clk); clear = 0;
                    en = 1; @(posedge clk); en = 0;
                    @(posedge clk);
                    if (tree_sum === expected_sum[23:0]) begin
                        pass_cnt = pass_cnt + 1;
                    end else begin
                        fail_cnt = fail_cnt + 1;
                        $display("FAIL [T%0d]: tree_sum=0x%06h expected=0x%06h",
                                 test_num, tree_sum, expected_sum);
                    end
                    test_num = test_num + 1;
                end
            end
            $fclose(vec_fd);
            $fclose(exp_fd);
        end

        $display("=== Vector MAC Summary: PASS=%0d FAIL=%0d ===", pass_cnt, fail_cnt);
        $finish;
    end

endmodule
