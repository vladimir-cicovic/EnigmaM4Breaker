# EnigmaM4Breaker build script (CMake/Ninja path)
# Builds the core pipeline: verify_r1 (CPU simulator), verify_r2 (scoring),
# verify_r3 (GPU kernel). For the standalone attack tools
# (crack_u264, enigma_crib_solver, enigma_blind_depth, ...) use build.bat instead.
#
# Usage:
#   .\build.ps1                  # build all CMake targets
#   .\build.ps1 verify_r1        # build a single target
#   .\build.ps1 -VsDir "C:\Program Files\Microsoft Visual Studio\2022\Community"
#
# Note: CUDA 12.4's nvcc only accepts MSVC toolsets up to ~14.4x as host
# compiler. If your VS install's *default* toolset is newer (e.g. a
# Preview/Insiders VS with a 14.5x toolset), a plain `cmake -G Ninja` configure
# fails with "unsupported Microsoft Visual Studio version" (C1189) even though
# cl.exe itself runs fine for ordinary C++. -MsvcClPath pins the CUDA host
# compiler to a known-good older toolset explicitly.
param(
    [string]$Target = "",
    [string]$VsDir = "C:\Program Files\Microsoft Visual Studio\18\Insiders",
    [string]$MsvcClPath = "C:\Program Files\Microsoft Visual Studio\18\Insiders\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\cl.exe"
)

if (-not $VsDir) { $VsDir = $env:ENIGMA_VS_DIR }

$vcvars  = "$VsDir\VC\Auxiliary\Build\vcvars64.bat"
$cmake   = "$VsDir\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
$projDir = $PSScriptRoot
$buildDir = "$projDir\build"

if (-not (Test-Path $vcvars)) {
    Write-Error "vcvars64.bat not found at: $vcvars`nPass -VsDir, or set `$env:ENIGMA_VS_DIR, to point at your Visual Studio install."
    exit 1
}
if (-not (Test-Path $cmake)) {
    Write-Error "cmake not found at: $cmake`nEither install the 'C++ CMake tools for Windows' VS component, or install CMake separately and adjust this script."
    exit 1
}
if (-not (Test-Path $MsvcClPath)) {
    Write-Error "cl.exe not found at: $MsvcClPath`nPass -MsvcClPath pointing at an MSVC toolset cl.exe that your CUDA Toolkit version supports (see NVIDIA's supported-host-compiler table)."
    exit 1
}

New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

$buildArg = if ($Target) { "--target $Target" } else { "" }
$nativeNinja = "$VsDir\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja"
$runnerBat = "$buildDir\_run_build.bat"

@"
@echo off
set PATH=$nativeNinja;%PATH%
call "$vcvars" >nul 2>&1
"$cmake" -S "$projDir" -B "$buildDir" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_HOST_COMPILER="$MsvcClPath"
if errorlevel 1 exit /b 1
"$cmake" --build "$buildDir" $buildArg
"@ | Set-Content -Encoding ascii $runnerBat

Write-Host "=== Building EnigmaM4Breaker ===" -ForegroundColor Cyan
& cmd /c "`"$runnerBat`""
exit $LASTEXITCODE
