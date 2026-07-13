# =============================================================================
# run_sim.ps1  —  AxLAM Icarus Verilog Simulation Runner (PowerShell)
#
# Usage:
#   cd d:\all_documents\Others\Projects\AxLAM
#   .\sim\run_sim.ps1              # run all testbenches
#   .\sim\run_sim.ps1 -Target mul  # afpos_multiplier only
#   .\sim\run_sim.ps1 -Target vmac # vector_mac_16 only
#   .\sim\run_sim.ps1 -Target pe   # pe_qkv only
#   .\sim\run_sim.ps1 -GenOnly     # generate test vectors only
#
# Requirements:
#   - Icarus Verilog: winget install -e --id IcarusVerilog.IcarusVerilog
#     (or download from https://bleyer.org/icarus/)
#   - Python 3.x with: pip install torch transformers
# =============================================================================

param(
    [string] $Target  = "all",
    [switch] $GenOnly
)

$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

# --------------------------------------------------------------------------
# Colour helpers
# --------------------------------------------------------------------------
function Write-Pass { param($msg) Write-Host "[PASS] $msg" -ForegroundColor Green  }
function Write-Fail { param($msg) Write-Host "[FAIL] $msg" -ForegroundColor Red    }
function Write-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan   }
function Write-Step { param($msg) Write-Host "`n=== $msg ===" -ForegroundColor Yellow }

# --------------------------------------------------------------------------
# Check iverilog
# --------------------------------------------------------------------------
$iverilog = Get-Command iverilog -ErrorAction SilentlyContinue
if (-not $iverilog) {
    Write-Host ""
    Write-Host "  Icarus Verilog not found on PATH." -ForegroundColor Red
    Write-Host "  Install with:" -ForegroundColor Yellow
    Write-Host "    winget install -e --id IcarusVerilog.IcarusVerilog" -ForegroundColor White
    Write-Host "  Then re-open this terminal and re-run the script." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}
Write-Info "iverilog found: $($iverilog.Source)"

# --------------------------------------------------------------------------
# Ensure output directories exist
# --------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path sim\waves, sim\out, sim\vectors | Out-Null

# --------------------------------------------------------------------------
# RTL source file list
# --------------------------------------------------------------------------
$RTL = @(
    "rtl\afpos_multiplier.v",
    "rtl\afpos_to_fixedpt.v",
    "rtl\afpos_mac_unit.v",
    "rtl\vector_mac_16.v",
    "rtl\sram_sp.v",
    "rtl\sram_dp.v",
    "rtl\hbm3_model.v",
    "rtl\pe_qkv.v",
    "rtl\pe_ffn.v"
)

# --------------------------------------------------------------------------
# Step 1: Generate test vectors
# --------------------------------------------------------------------------
Write-Step "Generating test vectors"
python sim\gen_test_vectors.py
if ($LASTEXITCODE -ne 0) {
    Write-Host "  WARNING: Vector generation had errors. Continuing..." -ForegroundColor Yellow
}

if ($GenOnly) { Write-Info "GenOnly flag set — exiting after vector generation."; exit 0 }

# --------------------------------------------------------------------------
# Helper: compile + run one testbench
# --------------------------------------------------------------------------
function Run-TB {
    param([string]$Name, [string]$TBFile, [string]$Out)

    Write-Step "Compiling $Name"
    $args_list = @("-g2012", "-Wall", "-o", "sim\out\$Out") + $RTL + @($TBFile)
    & iverilog @args_list
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Compile failed: $Name"
        return $false
    }

    Write-Info "Running $Name ..."
    & vvp "sim\out\$Out"
    if ($LASTEXITCODE -eq 0) {
        Write-Pass "$Name simulation completed."
        return $true
    } else {
        Write-Fail "$Name simulation returned non-zero exit."
        return $false
    }
}

# --------------------------------------------------------------------------
# Run testbenches based on target
# --------------------------------------------------------------------------
$pass_all = $true

if ($Target -eq "all" -or $Target -eq "mul") {
    $ok = Run-TB "AFPOS Multiplier" "tb\tb_afpos_multiplier.v" "tb_afpos_mul.vvp"
    if (-not $ok) { $pass_all = $false }
}

if ($Target -eq "all" -or $Target -eq "vmac") {
    $ok = Run-TB "Vector MAC 16" "tb\tb_vector_mac_16.v" "tb_vmac.vvp"
    if (-not $ok) { $pass_all = $false }
}

if ($Target -eq "all" -or $Target -eq "pe") {
    $ok = Run-TB "PE-QKV" "tb\tb_pe_qkv.v" "tb_pe_qkv.vvp"
    if (-not $ok) { $pass_all = $false }
}

# --------------------------------------------------------------------------
# Final summary
# --------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor White
if ($pass_all) {
    Write-Host "  ALL SIMULATIONS PASSED" -ForegroundColor Green
} else {
    Write-Host "  ONE OR MORE SIMULATIONS FAILED" -ForegroundColor Red
}
Write-Host "  Waveforms: $Root\sim\waves\" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor White
