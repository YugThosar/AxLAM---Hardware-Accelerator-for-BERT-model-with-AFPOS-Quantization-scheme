// =============================================================================
// afpos_mac_unit.v  —  AxLAM Project
// Single AFPOS MAC unit: acc_out = acc_in + A * B
//
// Pipeline: 1 register stage
//   Stage 0 (comb): AFPOS multiply A*B, convert product to Q10.14
//   Stage 1 (reg) : add converted product to acc_in, register output
//
// Ports:
//   clk, rst_n   — clock / active-low reset
//   a, b         — 8-bit AFPOS operands
//   acc_in       — 24-bit Q10.14 running accumulator input
//   en           — enable (holds output when low)
//   clear        — synchronous clear of accumulator
//   acc_out      — 24-bit Q10.14 accumulated output  (registered)
//   product_raw  — 8-bit AFPOS product (for debug / bypass)
// =============================================================================
`timescale 1ns/1ps

module afpos_mac_unit (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  a,
    input  wire [7:0]  b,
    input  wire [23:0] acc_in,
    input  wire        en,
    input  wire        clear,
    output reg  [23:0] acc_out,
    output wire [7:0]  product_raw
);

    // ----- AFPOS multiply (combinational) ----
    wire [7:0]  prod_afpos;
    afpos_multiplier u_mul (
        .a (a),
        .b (b),
        .p (prod_afpos)
    );
    assign product_raw = prod_afpos;

    // ----- Convert product to Q10.14 --------
    wire [23:0] prod_fp;
    afpos_to_fixedpt u_conv (
        .afpos_in (prod_afpos),
        .fp_out   (prod_fp)
    );

    // ----- Accumulate (registered) ----------
    wire [23:0] sum = acc_in + prod_fp;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            acc_out <= 24'h000000;
        else if (clear)
            acc_out <= 24'h000000;
        else if (en)
            acc_out <= sum;
    end

endmodule
