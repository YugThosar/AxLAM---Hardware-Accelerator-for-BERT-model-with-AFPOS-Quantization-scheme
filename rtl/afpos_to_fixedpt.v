// =============================================================================
// afpos_to_fixedpt.v  —  AxLAM Project
// AFPOS (8-bit) -> 24-bit Signed Fixed-Point Converter
//
// Output format: Q10.14  (signed, 24 bits)
//   bit[23]       = sign
//   bits[22:14]   = integer part  (9 bits, range 0..480)
//   bits[13:0]    = fractional part  (14 bits, resolution 2^-14)
//
// Conversion:
//   value = (-1)^s * (8 + mant) * 2^(exp - 10)
//   In Q10.14:  fp24 = (8+mant) << (exp + 4)       [for positive]
//               fp24 = ~((8+mant) << (exp+4)) + 1   [for negative]
//
//   shift range: exp=0  -> shift=4   | exp=15 -> shift=19
//   max mag: 15 << 19 = 7,864,320 < 2^23 = 8,388,608  (fits in 24-bit signed)
// =============================================================================
`timescale 1ns/1ps

module afpos_to_fixedpt (
    input  wire [7:0]  afpos_in,
    output reg  [23:0] fp_out       // Signed Q10.14 fixed-point
);

    wire        sign = afpos_in[7];
    wire [3:0]  exp  = afpos_in[6:3];
    wire [2:0]  mant = afpos_in[2:0];
    wire        zero = (afpos_in == 8'h00);

    wire [3:0]  mag  = {1'b1, mant};          // 4-bit mantissa {1, m2, m1, m0}
    wire [4:0]  shft = {1'b0, exp} + 5'd4;    // shift = exp + 4  (range 4..19)

    // Barrel shift: place 4-bit mag into 24-bit unsigned word
    reg [23:0] mag_shifted;
    always @(*) begin
        mag_shifted = 24'b0;
        case (shft)
            5'd4:  mag_shifted = {16'b0, mag,  4'b0};
            5'd5:  mag_shifted = {15'b0, mag,  5'b0};
            5'd6:  mag_shifted = {14'b0, mag,  6'b0};
            5'd7:  mag_shifted = {13'b0, mag,  7'b0};
            5'd8:  mag_shifted = {12'b0, mag,  8'b0};
            5'd9:  mag_shifted = {11'b0, mag,  9'b0};
            5'd10: mag_shifted = {10'b0, mag, 10'b0};
            5'd11: mag_shifted = { 9'b0, mag, 11'b0};
            5'd12: mag_shifted = { 8'b0, mag, 12'b0};
            5'd13: mag_shifted = { 7'b0, mag, 13'b0};
            5'd14: mag_shifted = { 6'b0, mag, 14'b0};
            5'd15: mag_shifted = { 5'b0, mag, 15'b0};
            5'd16: mag_shifted = { 4'b0, mag, 16'b0};
            5'd17: mag_shifted = { 3'b0, mag, 17'b0};
            5'd18: mag_shifted = { 2'b0, mag, 18'b0};
            5'd19: mag_shifted = { 1'b0, mag, 19'b0};
            default: mag_shifted = 24'b0;
        endcase
    end

    // Apply sign (two's complement negation for negative values)
    always @(*) begin
        if (zero)
            fp_out = 24'h000000;
        else if (sign)
            fp_out = (~mag_shifted) + 24'h000001;  // negate
        else
            fp_out = mag_shifted;
    end

endmodule
