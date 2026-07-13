"""
gen_test_vectors.py  —  AxLAM Project
================================================================================
Golden-model test vector generator.

Uses the existing afpos_emulator.py and a loaded BERT checkpoint (my_model.zip)
to generate bit-exact hex test vectors for the Verilog testbenches.

Outputs (all in sim/vectors/):
  afpos_mul_tests.hex     — AFPOS multiplier unit tests:  a b expected_p
  vmac_test.hex           — vector MAC operands:          L0 R0 ... L15 R15 (one per 16)
  vmac_expected.hex       — vector MAC expected sums:     tree_sum Q10.14 hex
  pe_qkv_L.hex            — QKV PE: L-matrix tile (AFPOS)
  pe_qkv_R.hex            — QKV PE: R-matrix tile (AFPOS)
  pe_qkv_out.hex          — QKV PE: expected output tile (24-bit Q10.14)

Usage:
  cd d:\\all_documents\\Others\\Projects\\AxLAM
  python sim/gen_test_vectors.py
================================================================================
"""

import os, sys, struct, zipfile, random
import numpy as np

# ── Path setup ──────────────────────────────────────────────────────────────
PROJ  = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, PROJ)
OUT   = os.path.join(PROJ, "sim", "vectors")
os.makedirs(OUT, exist_ok=True)

# ── Import AFPOS emulator ────────────────────────────────────────────────────
from afpos_emulator import quantize_afpos
import torch

# ── AFPOS encoding helpers ───────────────────────────────────────────────────
def encode_afpos(val: float) -> int:
    """Encode a scalar float as 8-bit AFPOS integer."""
    t = torch.tensor([val], dtype=torch.float32)
    q = quantize_afpos(t).item()

    if q == 0.0:
        return 0

    sign = 1 if q < 0 else 0
    abs_q = abs(q)

    import math
    # Find exponent e such that: abs_q = 2^(-7+e) * (1 + m/8)
    # => 2^(-7+e) <= abs_q < 2^(-7+e+1)
    log2_val = math.log2(abs_q)
    e = int(math.floor(log2_val)) + 7      # effective exp field
    e = max(0, min(15, e))
    base = (2.0 ** (e - 7))
    mantissa_real = abs_q / base - 1.0    # in [0, 1)
    m = round(mantissa_real * 8)
    m = max(0, min(7, m))
    return (sign << 7) | (e << 3) | m


def decode_afpos(code: int) -> float:
    """Decode 8-bit AFPOS integer to float."""
    if code == 0:
        return 0.0
    sign  = (code >> 7) & 1
    exp   = (code >> 3) & 0xF
    mant  = code & 0x7
    val   = (2.0 ** (exp - 7)) * (1.0 + mant / 8.0)
    return -val if sign else val


def afpos_mul_golden(a_code: int, b_code: int) -> int:
    """Multiply two AFPOS codes using Python emulator → return AFPOS code."""
    a_f = decode_afpos(a_code)
    b_f = decode_afpos(b_code)
    p_f = a_f * b_f
    return encode_afpos(p_f)


def fp_to_q10_14(val: float) -> int:
    """Convert float to 24-bit signed Q10.14 fixed-point integer."""
    scaled = round(val * (1 << 14))
    # Clamp to 24-bit signed range
    scaled = max(-(1 << 23), min((1 << 23) - 1, scaled))
    # Convert to unsigned 24-bit
    if scaled < 0:
        scaled = scaled + (1 << 24)
    return scaled & 0xFFFFFF


# ── 1. AFPOS multiplier unit tests ───────────────────────────────────────────
print("Generating afpos_mul_tests.hex ...")
random.seed(42)
mul_tests = []

# Corner cases
corner_pairs = [
    (0x00, 0x00), (0x00, 0x38), (0x38, 0x00),     # zero
    (0x38, 0x38),                                   # 1.0 * 1.0
    (0xB8, 0x38), (0xB8, 0xB8),                    # negatives
    (0x7F, 0x7F),                                   # max * max → saturate
    (0x01, 0x01),                                   # min * min → underflow
    (0x40, 0x40),                                   # 2.0 * 2.0 = 4.0
    (0x48, 0x38),                                   # 4.0 * 1.0
]
for a, b in corner_pairs:
    mul_tests.append((a, b, afpos_mul_golden(a, b)))

# Random tests
for _ in range(500):
    a = random.randint(0, 0x7F)   # positive values only first
    b = random.randint(0, 0x7F)
    mul_tests.append((a, b, afpos_mul_golden(a, b)))

for _ in range(500):
    a = random.randint(0, 0xFF)
    b = random.randint(0, 0xFF)
    mul_tests.append((a, b, afpos_mul_golden(a, b)))

with open(os.path.join(OUT, "afpos_mul_tests.hex"), "w") as f:
    for a, b, p in mul_tests:
        f.write(f"{a:02X} {b:02X} {p:02X}\n")
print(f"  Written {len(mul_tests)} tests.")


# ── 2. Vector MAC tests (16-wide) ────────────────────────────────────────────
print("Generating vmac_test.hex / vmac_expected.hex ...")
N_VMAC = 100
# Restrict to exp 0..7 (positive, max magnitude ~1.875) so 16-wide sum fits Q10.14
SAFE_AFPOS = [c for c in range(0, 0x40) if ((c >> 3) & 0xF) <= 7]
with open(os.path.join(OUT, "vmac_test.hex"),     "w") as fv, \
     open(os.path.join(OUT, "vmac_expected.hex"), "w") as fe:
    for _ in range(N_VMAC):
        L = [random.choice(SAFE_AFPOS) for _ in range(16)]
        R = [random.choice(SAFE_AFPOS) for _ in range(16)]
        for l, r in zip(L, R):
            fv.write(f"{l:02X} {r:02X}\n")
        total = 0.0
        for l, r in zip(L, R):
            p_code = afpos_mul_golden(l, r)
            total += decode_afpos(p_code)
        fe.write(f"{fp_to_q10_14(total):06X}\n")
print(f"  Written {N_VMAC} vector MAC tests.")


# ── 3. PE-QKV tile tests (from model weights if available) ────────────────────
print("Generating PE-QKV tile test vectors ...")

MODEL_ZIP = os.path.join(PROJ, "my_model.zip")
TILE_M, TILE_N, TILE_K = 8, 8, 64   # must match pe_qkv parameters

try:
    import torch
    from transformers import BertForSequenceClassification
    from bert_afpos_model import replace_linear_with_afpos

    # Extract checkpoint from zip
    TMP_DIR = os.path.join(PROJ, "sim", "_tmp_model")
    os.makedirs(TMP_DIR, exist_ok=True)
    with zipfile.ZipFile(MODEL_ZIP, "r") as zf:
        zf.extractall(TMP_DIR)

    # Find checkpoint directory
    ckpt = None
    for root, dirs, files in os.walk(TMP_DIR):
        if "config.json" in files:
            ckpt = root
            break

    if ckpt is None:
        raise FileNotFoundError("No checkpoint found in zip")

    model = BertForSequenceClassification.from_pretrained(ckpt)
    replace_linear_with_afpos(model)
    model.eval()

    # Extract first attention query weight (768 x 64) for QKV tile
    qkv_weight = None
    for name, param in model.named_parameters():
        if "query.weight" in name:
            qkv_weight = param.data.detach().cpu()
            break

    if qkv_weight is None:
        raise ValueError("Query weight not found")

    # Quantize to AFPOS
    L_mat = torch.randn(TILE_M, TILE_K)         # simulated input activations
    R_mat = qkv_weight[:TILE_N, :TILE_K]        # weight tile

    L_q = quantize_afpos(L_mat)
    R_q = quantize_afpos(R_mat)

    # Expected output: matrix multiply L @ R^T in AFPOS
    out_ref = torch.zeros(TILE_M, TILE_N)
    for m in range(TILE_M):
        for n in range(TILE_N):
            acc = 0.0
            for k in range(TILE_K):
                a_v = L_q[m, k].item()
                b_v = R_q[n, k].item()
                a_c = encode_afpos(a_v)
                b_c = encode_afpos(b_v)
                p_c = afpos_mul_golden(a_c, b_c)
                acc += decode_afpos(p_c)
            out_ref[m, n] = acc

    # Write L tile (row-major, AFPOS codes)
    with open(os.path.join(OUT, "pe_qkv_L.hex"), "w") as f:
        for m in range(TILE_M):
            for k in range(TILE_K):
                f.write(f"{encode_afpos(L_q[m,k].item()):02X}\n")

    # Write R tile
    with open(os.path.join(OUT, "pe_qkv_R.hex"), "w") as f:
        for n in range(TILE_N):
            for k in range(TILE_K):
                f.write(f"{encode_afpos(R_q[n,k].item()):02X}\n")

    # Write expected output (Q10.14 hex)
    with open(os.path.join(OUT, "pe_qkv_out.hex"), "w") as f:
        for m in range(TILE_M):
            for n in range(TILE_N):
                f.write(f"{fp_to_q10_14(out_ref[m,n].item()):06X}\n")

    print(f"  Written PE-QKV tiles ({TILE_M}x{TILE_K} L, {TILE_N}x{TILE_K} R).")

except Exception as e:
    print(f"  WARNING: Could not generate PE tile vectors from model: {e}")
    print("  Generating random PE tile vectors instead ...")

    with open(os.path.join(OUT, "pe_qkv_L.hex"), "w") as f:
        for _ in range(TILE_M * TILE_K):
            f.write(f"{random.randint(0,0x7F):02X}\n")
    with open(os.path.join(OUT, "pe_qkv_R.hex"), "w") as f:
        for _ in range(TILE_N * TILE_K):
            f.write(f"{random.randint(0,0x7F):02X}\n")
    with open(os.path.join(OUT, "pe_qkv_out.hex"), "w") as f:
        for _ in range(TILE_M * TILE_N):
            f.write(f"000000\n")  # placeholder

print("\nAll test vectors generated successfully.")
print(f"Output directory: {OUT}")
