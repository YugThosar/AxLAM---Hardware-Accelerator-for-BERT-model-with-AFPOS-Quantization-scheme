# AxLAM HW Accelerator — Task Tracker

## Decisions Locked
- Simulation: Icarus Verilog → Xilinx FPGA → Cadence ASIC
- HBM3: Behavioral SRAM model
- PE-A: QKV + Attention family  |  PE-B: FFN / BtlCont / BtlExp / MHead family
- Accumulator: 24-bit signed fixed-point (Q10.14)
- AFPOS format: 8-bit {sign[7], exp[6:3], mantissa[2:0]}

## Phase 1 — AFPOS Arithmetic Core
- [x] `rtl/afpos_multiplier.v`       — 8-bit × 8-bit AFPOS multiplier
- [x] `rtl/afpos_to_fixedpt.v`       — AFPOS → 24-bit Q10.14 converter
- [x] `rtl/afpos_mac_unit.v`         — Single pipelined MAC (acc += A×B)
- [x] `tb/tb_afpos_multiplier.v`     — Unit testbench

## Phase 2 — 16-Wide Vector MAC
- [x] `rtl/vector_mac_16.v`          — 16-wide parallel MAC + adder tree
- [x] `tb/tb_vector_mac_16.v`        — Vector MAC testbench

## Phase 3 — SRAM Buffers
- [x] `rtl/sram_sp.v`                — Generic single-port SRAM
- [x] `rtl/sram_dp.v`                — Generic dual-port SRAM

## Phase 4 — PE Designs
- [x] `rtl/pe_qkv.v`                 — PE-A: QKV/Attention (L-stationary)
- [x] `rtl/pe_ffn.v`                 — PE-B: FFN/BtlCont/BtlExp/MHead (R-stationary)
- [x] `rtl/hbm3_model.v`             — Behavioral HBM3 SRAM model

## Phase 5 — Simulation
- [x] `sim/gen_test_vectors.py`       — Python golden-model vector generator
- [x] `sim/run_sim.bat`               — Icarus Verilog runner
- [x] `tb/tb_pe_qkv.v`               — PE-A top-level testbench
