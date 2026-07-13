// =============================================================================
// vector_mac_16.v  —  AxLAM Project
// 16-Wide Parallel AFPOS Vector MAC  with Parallel Adder Tree
//
// Each cycle: computes 16 AFPOS products and adds them to 16 running
// accumulators stored in A.SRAM (provided externally via acc_in/acc_out).
//
// The 16 products are ALSO summed via a 4-level binary adder tree to
// produce a single partial-sum output (for reduction across columns/rows).
//
// Ports:
//   L_vec[15:0][7:0]  — 16 x 8-bit AFPOS (left-matrix operands)
//   R_vec[15:0][7:0]  — 16 x 8-bit AFPOS (right-matrix operands)
//   acc_in[15:0][23:0]— 16 x 24-bit Q10.14 accumulator inputs from A.SRAM
//   en                — enable computation
//   clear             — synchronous accumulator clear
//   acc_out[15:0][23:0]— 16 x 24-bit Q10.14 accumulator outputs to A.SRAM
//   tree_sum[23:0]    — adder-tree reduction of the 16 products (Q10.14)
//   valid_out         — registered valid flag (1 cycle after en)
//
// Pipeline depth: 1 register stage (same as afpos_mac_unit)
// =============================================================================
`timescale 1ns/1ps

module vector_mac_16 (
    input  wire        clk,
    input  wire        rst_n,
    // Operand vectors
    input  wire [7:0]  L_vec  [0:15],
    input  wire [7:0]  R_vec  [0:15],
    // Accumulator I/O (from/to A.SRAM)
    input  wire [23:0] acc_in [0:15],
    input  wire        en,
    input  wire        clear,
    // Outputs
    output wire [23:0] acc_out [0:15],
    output reg  [23:0] tree_sum,
    output reg         valid_out
);

    // -----------------------------------------------------------------------
    // 16 parallel MAC units
    // -----------------------------------------------------------------------
    wire [23:0] mac_sum   [0:15];
    wire [7:0]  prod_afpos[0:15];

    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : gen_mac
            afpos_mac_unit u_mac (
                .clk        (clk),
                .rst_n      (rst_n),
                .a          (L_vec[i]),
                .b          (R_vec[i]),
                .acc_in     (acc_in[i]),
                .en         (en),
                .clear      (clear),
                .acc_out    (mac_sum[i]),
                .product_raw(prod_afpos[i])
            );
            assign acc_out[i] = mac_sum[i];
        end
    endgenerate

    // -----------------------------------------------------------------------
    // 4-level binary adder tree for cross-lane reduction
    // Converts each AFPOS product to Q10.14, then sums all 16
    // -----------------------------------------------------------------------
    wire [23:0] fp_prod [0:15];
    generate
        for (i = 0; i < 16; i = i + 1) begin : gen_conv
            afpos_to_fixedpt u_conv (
                .afpos_in (prod_afpos[i]),
                .fp_out   (fp_prod[i])
            );
        end
    endgenerate

    // Level 1: 8 sums of pairs
    wire [23:0] lvl1 [0:7];
    generate
        for (i = 0; i < 8; i = i + 1) begin : gen_l1
            assign lvl1[i] = fp_prod[2*i] + fp_prod[2*i+1];
        end
    endgenerate

    // Level 2: 4 sums
    wire [23:0] lvl2 [0:3];
    generate
        for (i = 0; i < 4; i = i + 1) begin : gen_l2
            assign lvl2[i] = lvl1[2*i] + lvl1[2*i+1];
        end
    endgenerate

    // Level 3: 2 sums
    wire [23:0] lvl3_0 = lvl2[0] + lvl2[1];
    wire [23:0] lvl3_1 = lvl2[2] + lvl2[3];

    // Level 4: final sum
    wire [23:0] tree_comb = lvl3_0 + lvl3_1;

    // Register tree output
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tree_sum  <= 24'h000000;
            valid_out <= 1'b0;
        end else begin
            tree_sum  <= en ? tree_comb : tree_sum;
            valid_out <= en;
        end
    end

endmodule
