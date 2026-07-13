// =============================================================================
// sram_dp.v  —  AxLAM Project
// Generic Dual-Port SRAM (behavioral model)
//   Port A: read/write  (used by HBM3 controller to load data)
//   Port B: read/write  (used by vector MAC to access operands)
//
// Parameters:
//   DEPTH   — number of words
//   WIDTH   — word width in bits
//   ADDR_W  — address width
// =============================================================================
`timescale 1ns/1ps

module sram_dp #(
    parameter DEPTH  = 1024,
    parameter WIDTH  = 64,
    parameter ADDR_W = 10
)(
    input  wire              clk,
    // Port A (HBM3 fill)
    input  wire              a_we,
    input  wire [ADDR_W-1:0] a_addr,
    input  wire [WIDTH-1:0]  a_din,
    output reg  [WIDTH-1:0]  a_dout,
    // Port B (MAC access)
    input  wire              b_we,
    input  wire [ADDR_W-1:0] b_addr,
    input  wire [WIDTH-1:0]  b_din,
    output reg  [WIDTH-1:0]  b_dout
);
    reg [WIDTH-1:0] mem [0:DEPTH-1];

    integer j;
    initial begin
        for (j = 0; j < DEPTH; j = j + 1)
            mem[j] = {WIDTH{1'b0}};
        a_dout = {WIDTH{1'b0}};
        b_dout = {WIDTH{1'b0}};
    end

    // Port A
    always @(posedge clk) begin
        if (a_we) mem[a_addr] <= a_din;
        a_dout <= mem[a_addr];
    end

    // Port B — write wins on same-address conflict (Port A priority)
    always @(posedge clk) begin
        if (b_we) mem[b_addr] <= b_din;
        b_dout <= mem[b_addr];
    end
endmodule
