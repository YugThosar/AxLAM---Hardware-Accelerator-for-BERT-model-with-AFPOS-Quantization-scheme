@echo off
REM ============================================================
REM view_waves.bat  —  AxLAM GTKWave Visualizer Launcher
REM ============================================================

cd /d "%~dp0\.."

set GTKWAVE_PATH=C:\iverilog\gtkwave\bin\gtkwave.exe

if not exist "%GTKWAVE_PATH%" (
    where gtkwave >nul 2>&1
    if ERRORLEVEL 1 (
        echo ERROR: GTKWave not found at default location or on system PATH.
        echo Expected: %GTKWAVE_PATH%
        echo Please ensure GTKWave is installed.
        pause
        exit /b 1
    ) else (
        set GTKWAVE_PATH=gtkwave
    )
)

echo ============================================================
echo           AxLAM GTKWave Waveform Visualizer
echo ============================================================
echo.
echo Select the waveform you want to view:
echo [1] AFPOS Multiplier Testbench (tb_afpos_mul.vcd)
echo [2] Vector MAC 16 Testbench    (tb_vector_mac_16.vcd)
echo [3] PE QKV Testbench           (tb_pe_qkv.vcd)
echo.

set /p Choice="Enter selection (1-3): "

if "%Choice%"=="1" (
    if not exist sim\waves\tb_afpos_mul.vcd (
        echo WAVEFORM NOT FOUND: sim\waves\tb_afpos_mul.vcd
        pause
        exit /b 1
    )
    echo Launching GTKWave with tb_afpos_mul.vcd...
    start "" "%GTKWAVE_PATH%" sim\waves\tb_afpos_mul.vcd
) else if "%Choice%"=="2" (
    if not exist sim\waves\tb_vector_mac_16.vcd (
        echo WAVEFORM NOT FOUND: sim\waves\tb_vector_mac_16.vcd
        pause
        exit /b 1
    )
    echo Launching GTKWave with tb_vector_mac_16.vcd...
    start "" "%GTKWAVE_PATH%" sim\waves\tb_vector_mac_16.vcd
) else if "%Choice%"=="3" (
    if not exist sim\waves\tb_pe_qkv.vcd (
        echo WAVEFORM NOT FOUND: sim\waves\tb_pe_qkv.vcd
        echo Please run the PE QKV simulation first to generate this waveform.
        pause
        exit /b 1
    )
    echo Launching GTKWave with tb_pe_qkv.vcd...
    start "" "%GTKWAVE_PATH%" sim\waves\tb_pe_qkv.vcd
) else (
    echo Invalid choice.
    pause
)

exit /b 0
