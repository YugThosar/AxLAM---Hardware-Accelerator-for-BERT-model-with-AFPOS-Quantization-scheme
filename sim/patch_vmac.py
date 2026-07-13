"""patch_vmac.py — patch gen_test_vectors.py VMAC section"""
import re

src = open('sim/gen_test_vectors.py', encoding='utf-8').read()

old = '''N_VMAC = 100
with open(os.path.join(OUT, "vmac_test.hex"),     "w") as fv, \\
     open(os.path.join(OUT, "vmac_expected.hex"), "w") as fe:
    for _ in range(N_VMAC):
        L = [random.randint(0, 0x7F) for _ in range(16)]
        R = [random.randint(0, 0x7F) for _ in range(16)]
        # Write operand pairs
        for l, r in zip(L, R):
            fv.write(f"{l:02X} {r:02X}\\n")
        # Compute expected tree_sum in Q10.14
        total = 0.0
        for l, r in zip(L, R):
            p_code = afpos_mul_golden(l, r)
            total += decode_afpos(p_code)
        fe.write(f"{fp_to_q10_14(total):06X}\\n")'''

new = '''N_VMAC = 100
# Restrict to exp 0..7 (positive, max magnitude ~1.875) so 16-wide sum fits Q10.14
SAFE_AFPOS = [c for c in range(0, 0x40) if ((c >> 3) & 0xF) <= 7]
with open(os.path.join(OUT, "vmac_test.hex"),     "w") as fv, \\
     open(os.path.join(OUT, "vmac_expected.hex"), "w") as fe:
    for _ in range(N_VMAC):
        L = [random.choice(SAFE_AFPOS) for _ in range(16)]
        R = [random.choice(SAFE_AFPOS) for _ in range(16)]
        for l, r in zip(L, R):
            fv.write(f"{l:02X} {r:02X}\\n")
        total = 0.0
        for l, r in zip(L, R):
            p_code = afpos_mul_golden(l, r)
            total += decode_afpos(p_code)
        fe.write(f"{fp_to_q10_14(total):06X}\\n")'''

if old in src:
    src = src.replace(old, new, 1)
    open('sim/gen_test_vectors.py', 'w', encoding='utf-8').write(src)
    print("Patched successfully")
else:
    print("Pattern not found — printing first 200 chars of VMAC section:")
    idx = src.find('N_VMAC')
    print(repr(src[idx:idx+400]))
