@echo off
REM ============================================================
REM run_sim.bat  —  AxLAM Icarus Verilog Simulation Runner
REM
REM Usage:
REM   sim\run_sim.bat              (run all testbenches)
REM   sim\run_sim.bat mul          (run afpos_multiplier TB only)
REM   sim\run_sim.bat vmac         (run vector_mac_16 TB only)
REM   sim\run_sim.bat pe_qkv       (run pe_qkv TB only)
REM
REM Requirements:
REM   - Icarus Verilog (iverilog) on PATH
REM   - Python with torch + transformers (for vector generation)
REM ============================================================

cd /d "%~dp0\.."

REM ── Generate test vectors ────────────────────────────────────
echo [1/4] Generating test vectors...
python sim\gen_test_vectors.py
if ERRORLEVEL 1 (
    echo WARNING: Vector generation had errors. Continuing with existing vectors.
)

REM ── Create output directories ────────────────────────────────
if not exist sim\waves mkdir sim\waves
if not exist sim\vectors mkdir sim\vectors

REM ── Parse argument ───────────────────────────────────────────
set TARGET=%1
if "%TARGET%"=="" set TARGET=all

REM ── RTL source list ─────────────────────────────────────────
set RTL=rtl\afpos_multiplier.v rtl\afpos_to_fixedpt.v rtl\afpos_mac_unit.v ^
        rtl\vector_mac_16.v rtl\sram_sp.v rtl\sram_dp.v ^
        rtl\hbm3_model.v rtl\pe_qkv.v rtl\pe_ffn.v

echo.

REM ── AFPOS Multiplier Testbench ───────────────────────────────
if "%TARGET%"=="all" goto run_mul
if "%TARGET%"=="mul" goto run_mul
goto skip_mul

:run_mul
echo [2/4] Compiling tb_afpos_multiplier...
iverilog -g2012 -o sim\out\tb_afpos_mul.vvp ^
    %RTL% tb\tb_afpos_multiplier.v
if ERRORLEVEL 1 ( echo COMPILE ERROR: tb_afpos_multiplier & goto skip_mul )
echo Running tb_afpos_multiplier...
vvp sim\out\tb_afpos_mul.vvp
echo.
:skip_mul

REM ── Vector MAC Testbench ──────────────────────────────────────
if "%TARGET%"=="all" goto run_vmac
if "%TARGET%"=="vmac" goto run_vmac
goto skip_vmac

:run_vmac
echo [3/4] Compiling tb_vector_mac_16...
if not exist sim\out mkdir sim\out
iverilog -g2012 -o sim\out\tb_vmac.vvp ^
    %RTL% tb\tb_vector_mac_16.v
if ERRORLEVEL 1 ( echo COMPILE ERROR: tb_vector_mac_16 & goto skip_vmac )
echo Running tb_vector_mac_16...
vvp sim\out\tb_vmac.vvp
echo.
:skip_vmac

REM ── PE-QKV Testbench (placeholder) ───────────────────────────
if "%TARGET%"=="all" goto run_peqkv
if "%TARGET%"=="pe_qkv" goto run_peqkv
goto skip_peqkv

:run_peqkv
echo [4/4] Compiling tb_pe_qkv...
if not exist sim\out mkdir sim\out
iverilog -g2012 -o sim\out\tb_pe_qkv.vvp ^
    %RTL% tb\tb_pe_qkv.v
if ERRORLEVEL 1 ( echo COMPILE ERROR: tb_pe_qkv & goto skip_peqkv )
echo Running tb_pe_qkv...
vvp sim\out\tb_pe_qkv.vvp
echo.
:skip_peqkv

echo.
echo ============================
echo  Simulation run complete.
echo  Waveform files in sim\waves\
echo ============================
