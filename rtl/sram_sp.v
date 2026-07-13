// =============================================================================
// sram_sp.v  —  AxLAM Project
// Generic Single-Port SRAM (behavioral model)
//
// Parameters:
//   DEPTH     — number of words  (default 1024 -> 8 KB when WIDTH=64)
//   WIDTH     — word bit-width   (default 64)
//   ADDR_W    — address bits     (default 10 = log2(1024))
//
// Port:
//   clk       — clock
//   we        — write enable
//   addr      — address
//   din       — write data
//   dout      — read data (1-cycle latency, synchronous read)
// =============================================================================
`timescale 1ns/1ps

module sram_sp #(
    parameter DEPTH  = 1024,
    parameter WIDTH  = 64,
    parameter ADDR_W = 10
)(
    input  wire              clk,
    input  wire              we,
    input  wire [ADDR_W-1:0] addr,
    input  wire [WIDTH-1:0]  din,
    output reg  [WIDTH-1:0]  dout
);
    reg [WIDTH-1:0] mem [0:DEPTH-1];

    // Initialise to zero
    integer j;
    initial begin
        for (j = 0; j < DEPTH; j = j + 1)
            mem[j] = {WIDTH{1'b0}};
        dout = {WIDTH{1'b0}};
    end

    always @(posedge clk) begin
        if (we)
            mem[addr] <= din;
        dout <= mem[addr];
    end
endmodule
