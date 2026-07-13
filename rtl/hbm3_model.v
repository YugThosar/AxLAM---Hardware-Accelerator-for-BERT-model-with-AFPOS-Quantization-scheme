// =============================================================================
// hbm3_model.v  —  AxLAM Project
// Behavioral HBM3 Memory Model (simple SRAM abstraction)
//
// Models 16 independent HBM3 channels, each with:
//   - 512-bit wide data bus (64 bytes/transfer)
//   - Bandwidth: 512 GB/s total → 32 GB/s per channel
//   - Access energy: 4.2 pJ/bit  (vs DDR4 46 pJ/bit)
//
// This model uses a flat SRAM array and adds a configurable latency
// (default 4 cycles) to approximate HBM3 access latency.
//
// Parameters:
//   CH_DEPTH   — words per channel (512-bit words)  default 16384 (= 1 MB/ch)
//   LATENCY    — read latency in clock cycles       default 4
//   N_CH       — number of HBM3 channels            default 16
// =============================================================================
`timescale 1ns/1ps

module hbm3_model #(
    parameter CH_DEPTH = 16384,   // words per channel
    parameter LATENCY  = 4,       // read latency (cycles)
    parameter N_CH     = 16       // channels
)(
    input  wire        clk,
    input  wire        rst_n,
    // Request interface (one channel at a time, arbitrated externally)
    input  wire [3:0]  ch_sel,           // channel select (0..15)
    input  wire        req_valid,        // request strobe
    input  wire        req_wr,           // 1=write, 0=read
    input  wire [13:0] req_addr,         // word address within channel
    input  wire [511:0] wr_data,         // write data
    // Response interface
    output reg  [511:0] rd_data,         // read data
    output reg          rd_valid         // read data valid
);

    // Flat memory: N_CH banks each CH_DEPTH × 512-bit
    reg [511:0] mem [0:N_CH-1][0:CH_DEPTH-1];

    // Initialise
    integer c, a;
    initial begin
        for (c = 0; c < N_CH; c = c + 1)
            for (a = 0; a < CH_DEPTH; a = a + 1)
                mem[c][a] = 512'b0;
        rd_data  = 512'b0;
        rd_valid = 1'b0;
    end

    // Latency shift register for read pipeline
    reg [511:0] lat_data  [0:LATENCY-1];
    reg         lat_valid [0:LATENCY-1];

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_data  <= 512'b0;
            rd_valid <= 1'b0;
            for (k = 0; k < LATENCY; k = k + 1) begin
                lat_data[k]  <= 512'b0;
                lat_valid[k] <= 1'b0;
            end
        end else begin
            // Write path (0-cycle latency for writes)
            if (req_valid && req_wr)
                mem[ch_sel][req_addr] <= wr_data;

            // Read path: stage 0
            lat_data[0]  <= (req_valid && !req_wr) ? mem[ch_sel][req_addr] : 512'b0;
            lat_valid[0] <= req_valid && !req_wr;

            // Shift through latency pipeline
            for (k = 1; k < LATENCY; k = k + 1) begin
                lat_data[k]  <= lat_data[k-1];
                lat_valid[k] <= lat_valid[k-1];
            end

            // Output
            rd_data  <= lat_data[LATENCY-1];
            rd_valid <= lat_valid[LATENCY-1];
        end
    end

endmodule
