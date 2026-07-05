@echo off
REM ============================================================
REM  EnigmaM4Breaker - unified build script for the attack tools
REM  (crack_u264, enigma_crib_solver, enigma_blind_depth, enigma_blind,
REM   enigma_breaker, ioc_diag). For the CMake core/verify_r1..r3
REM  pipeline use build.ps1 instead.
REM
REM  Usage:
REM    build.bat [target] [arch]
REM      target : all | objs | crack | crib | depth | blind | breaker | diag
REM               (default: all)
REM      arch   : CUDA SM architecture, e.g. sm_89, sm_86, sm_75
REM               (default: sm_89, or %ENIGMA_ARCH% if set)
REM
REM  Toolchain overrides (set as environment variables if your machine
REM  differs from the defaults below):
REM    VS_VCVARS   - full path to vcvars64.bat
REM    MSVC_CLPATH - full path to the cl.exe used as nvcc's host compiler
REM
REM  Examples:
REM    build.bat                      REM build everything, sm_89
REM    build.bat crack sm_86           REM just crack_u264, RTX 30-series
REM    set ENIGMA_ARCH=sm_75 & build.bat all
REM ============================================================
setlocal EnableDelayedExpansion

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set "BUILD=%ROOT%\build"

set "TARGET=%~1"
if "%TARGET%"=="" set "TARGET=all"

set "ARCH=%~2"
if "%ARCH%"=="" set "ARCH=%ENIGMA_ARCH%"
if "%ARCH%"=="" set "ARCH=sm_89"

if not defined VS_VCVARS set "VS_VCVARS=C:\Program Files\Microsoft Visual Studio\18\Insiders\VC\Auxiliary\Build\vcvars64.bat"
if not defined MSVC_CLPATH set "MSVC_CLPATH=C:\Program Files\Microsoft Visual Studio\18\Insiders\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\cl.exe"

if not exist "%VS_VCVARS%" (
    echo [FAIL] vcvars64.bat not found: %VS_VCVARS%
    echo         Set the VS_VCVARS environment variable to your Visual Studio install.
    exit /b 1
)
if not exist "%MSVC_CLPATH%" (
    echo [FAIL] cl.exe not found: %MSVC_CLPATH%
    echo         Set the MSVC_CLPATH environment variable to your MSVC toolset's cl.exe.
    exit /b 1
)

call "%VS_VCVARS%" >nul 2>&1
if not exist "%BUILD%" mkdir "%BUILD%"
cd /d "%ROOT%"

echo === EnigmaM4Breaker build   target=%TARGET%   arch=%ARCH% ===

cl.exe /std:c++17 /O2 /MT /c /I"%ROOT%" core\enigma_cpu\enigma_cpu.cpp /Fo:"%BUILD%\enigma_cpu.obj"
if errorlevel 1 goto :fail
cl.exe /std:c++17 /O2 /MT /c /I"%ROOT%" filters\quadgram\quadgram_score.cpp /Fo:"%BUILD%\quadgram_score.obj"
if errorlevel 1 goto :fail
cl.exe /std:c++17 /O2 /MT /c /I"%ROOT%" filters\trigram\trigram_score.cpp /Fo:"%BUILD%\trigram_score.obj"
if errorlevel 1 goto :fail
echo [OK] shared CPU objects

if /I "%TARGET%"=="objs" goto :done
if /I "%TARGET%"=="all" goto :do_all
if /I "%TARGET%"=="crack" goto :do_crack
if /I "%TARGET%"=="crib" goto :do_crib
if /I "%TARGET%"=="depth" goto :do_depth
if /I "%TARGET%"=="blind" goto :do_blind
if /I "%TARGET%"=="breaker" goto :do_breaker
if /I "%TARGET%"=="diag" goto :do_diag

echo [FAIL] unknown target: %TARGET%
echo         valid targets: all objs crack crib depth blind breaker diag
exit /b 1

:do_all
call :build_crack
if errorlevel 1 goto :fail
call :build_crib
if errorlevel 1 goto :fail
call :build_depth
if errorlevel 1 goto :fail
call :build_blind
if errorlevel 1 goto :fail
call :build_breaker
if errorlevel 1 goto :fail
call :build_diag
if errorlevel 1 goto :fail
goto :done

:do_crack
call :build_crack
if errorlevel 1 goto :fail
goto :done

:do_crib
call :build_crib
if errorlevel 1 goto :fail
goto :done

:do_depth
call :build_depth
if errorlevel 1 goto :fail
goto :done

:do_blind
call :build_blind
if errorlevel 1 goto :fail
goto :done

:do_breaker
call :build_breaker
if errorlevel 1 goto :fail
goto :done

:do_diag
call :build_diag
if errorlevel 1 goto :fail
goto :done

REM ---------------- builder subroutines ----------------

:build_crack
nvcc -ccbin "%MSVC_CLPATH%" -std=c++17 -arch=%ARCH% -O3 --use_fast_math -I"%ROOT%" -o "%BUILD%\crack_u264.exe" crack_u264.cu "%BUILD%\enigma_cpu.obj" "%BUILD%\quadgram_score.obj"
if errorlevel 1 ( echo [FAIL] crack_u264 & exit /b 1 )
echo [OK] build\crack_u264.exe
exit /b 0

:build_crib
nvcc -ccbin "%MSVC_CLPATH%" -std=c++17 -arch=%ARCH% -O3 --use_fast_math -I"%ROOT%" -o "%BUILD%\enigma_crib_solver.exe" enigma_crib_solver.cu "%BUILD%\enigma_cpu.obj" "%BUILD%\quadgram_score.obj" "%BUILD%\trigram_score.obj"
if errorlevel 1 ( echo [FAIL] enigma_crib_solver & exit /b 1 )
echo [OK] build\enigma_crib_solver.exe
exit /b 0

:build_depth
nvcc -ccbin "%MSVC_CLPATH%" -std=c++17 -arch=%ARCH% -O3 --use_fast_math -I"%ROOT%" -o "%BUILD%\enigma_blind_depth.exe" enigma_blind_depth.cu "%BUILD%\enigma_cpu.obj" "%BUILD%\quadgram_score.obj" "%BUILD%\trigram_score.obj"
if errorlevel 1 ( echo [FAIL] enigma_blind_depth & exit /b 1 )
echo [OK] build\enigma_blind_depth.exe
exit /b 0

:build_blind
nvcc -ccbin "%MSVC_CLPATH%" -std=c++17 -arch=%ARCH% -O3 --use_fast_math -I"%ROOT%" -o "%BUILD%\enigma_blind.exe" enigma_blind.cu "%BUILD%\enigma_cpu.obj" "%BUILD%\quadgram_score.obj" "%BUILD%\trigram_score.obj"
if errorlevel 1 ( echo [FAIL] enigma_blind & exit /b 1 )
echo [OK] build\enigma_blind.exe
exit /b 0

:build_breaker
nvcc -ccbin "%MSVC_CLPATH%" -std=c++17 -arch=%ARCH% -O3 --use_fast_math -I"%ROOT%" -o "%BUILD%\enigma_breaker.exe" enigma_breaker.cu "%BUILD%\enigma_cpu.obj" "%BUILD%\quadgram_score.obj"
if errorlevel 1 ( echo [FAIL] enigma_breaker & exit /b 1 )
echo [OK] build\enigma_breaker.exe  (legacy - kept for reference, does not crack 10-plug messages)
exit /b 0

:build_diag
cl.exe /std:c++17 /O2 /MT /I"%ROOT%" ioc_diag.cpp core\enigma_cpu\enigma_cpu.cpp /Fe:"%BUILD%\ioc_diag.exe" /Fo"%BUILD%\\"
if errorlevel 1 ( echo [FAIL] ioc_diag & exit /b 1 )
echo [OK] build\ioc_diag.exe
exit /b 0

:fail
echo === BUILD FAILED ===
exit /b 1

:done
echo === BUILD OK ===
exit /b 0
