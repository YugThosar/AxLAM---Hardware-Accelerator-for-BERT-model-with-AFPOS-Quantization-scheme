// =============================================================================
// afpos_multiplier.v  —  AxLAM Project
// 8-bit AFPOS Multiplier  (N=10, es=4, beta=-7)
//
// Encoding:  { sign[7], exp[6:3], mantissa[2:0] }
// Value   =  (-1)^sign  *  2^(-7)  *  2^exp  *  (1 + mantissa/8)
//
// Synthesis target (65 nm, Cadence Genus):
//   Latency ~465 ps  |  Area ~766 um2  |  Energy ~0.51 pJ
//
// Source: rsta.2023.0395, Table 2 (APOS 8-bit, config 10,4)
// =============================================================================
`timescale 1ns/1ps

module afpos_multiplier (
    input  wire [7:0] a,    // Operand A — AFPOS 8-bit
    input  wire [7:0] b,    // Operand B — AFPOS 8-bit
    output wire [7:0] p     // Product   — AFPOS 8-bit
);

    // -----------------------------------------------------------------------
    // Field extraction
    // -----------------------------------------------------------------------
    wire        a_sign = a[7];
    wire [3:0]  a_exp  = a[6:3];
    wire [2:0]  a_mant = a[2:0];

    wire        b_sign = b[7];
    wire [3:0]  b_exp  = b[6:3];
    wire [2:0]  b_mant = b[2:0];

    // -----------------------------------------------------------------------
    // Zero detection  (AFPOS zero = 8'h00 only)
    // -----------------------------------------------------------------------
    wire is_zero = (a == 8'h00) | (b == 8'h00);

    // -----------------------------------------------------------------------
    // Sign  (XOR)
    // -----------------------------------------------------------------------
    wire p_sign = a_sign ^ b_sign;

    // -----------------------------------------------------------------------
    // Mantissa multiplication
    //   (1.a_mant) x (1.b_mant)  with implicit leading 1
    //   Input format: 4-bit unsigned {1, mant[2:0]}   range [8,15]
    //   Product: 8-bit unsigned                        range [64,225]
    //
    //   Bit 7 set  => product >= 128  => result >= 2.0  (need normalisation)
    //   Bit 6 set  => product >= 64   => result >= 1.0  (always true)
    // -----------------------------------------------------------------------
    wire [3:0] ma = {1'b1, a_mant};
    wire [3:0] mb = {1'b1, b_mant};
    wire [7:0] mant_prod = ma * mb;            // combinational 4x4 multiply

    wire norm_shift = mant_prod[7];            // 1 => product >= 2.0

    // Extract 3 mantissa bits after the (implicit) leading 1
    // norm=1: leading 1 is at bit 7 -> take bits [6:4], round on bit 3
    // norm=0: leading 1 is at bit 6 -> take bits [5:3], round on bit 2
    wire [2:0] mant_trunc = norm_shift ? mant_prod[6:4] : mant_prod[5:3];
    wire       round_bit  = norm_shift ? mant_prod[3]   : mant_prod[2];

    // Round-to-nearest (tie-to-even not required for this precision)
    wire [3:0] mant_rounded = {1'b0, mant_trunc} + {3'b000, round_bit};

    // Rounding overflow: mantissa becomes 4'b1000  => carry into exponent
    wire mant_ovf = mant_rounded[3];
    wire [2:0] p_mant_pre = mant_ovf ? 3'b000 : mant_rounded[2:0];

    // -----------------------------------------------------------------------
    // Exponent computation
    //   Product value = (-1)^s * 2^(-7) * 2^ea * (1+ma/8)
    //                 * 2^(-7) * 2^eb * (1+mb/8)
    //                 = (-1)^s * 2^(-14+ea+eb) * mant_product
    //
    //   After normalisation shift (0 or 1) and optional rounding overflow:
    //   effective_exp = ea + eb - 7 + norm_shift + mant_ovf
    //   (the -7 re-biases so beta remains 2^-7 in the output)
    //
    //   6-bit signed arithmetic covers range [-7, 38]; clamp to [0,15].
    // -----------------------------------------------------------------------
    wire [5:0] exp_sum = {2'b00, a_exp} + {2'b00, b_exp};
    wire [5:0] exp_adj = {4'b0000, norm_shift} + {4'b0000, mant_ovf};
    wire signed [5:0] p_exp_raw = $signed(exp_sum) + $signed(exp_adj) - 6'sd7;

    wire p_exp_uf = p_exp_raw[5];                    // negative => underflow
    wire p_exp_of = (~p_exp_raw[5]) & (p_exp_raw > 6'sd15); // > 15 => overflow

    wire [3:0] p_exp_clamped = p_exp_uf ? 4'h0 :
                               p_exp_of ? 4'hF :
                               p_exp_raw[3:0];

    // Saturate mantissa on overflow, flush on underflow
    wire [2:0] p_mant_final = p_exp_of ? 3'b111 :
                              p_exp_uf ? 3'b000 :
                              p_mant_pre;

    // -----------------------------------------------------------------------
    // Pack result
    // -----------------------------------------------------------------------
    wire [7:0] p_packed = {p_sign, p_exp_clamped, p_mant_final};

    assign p = is_zero ? 8'h00 : p_packed;

endmodule
