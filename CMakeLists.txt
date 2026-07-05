cmake_minimum_required(VERSION 3.20)

project(EnigmaM4Breaker LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)

# Root in include path for #include "config.h"
include_directories(${CMAKE_SOURCE_DIR})

# ---- CPU shared libraries ----

add_library(filters STATIC
    filters/ioc/ioc.cpp
    filters/trigram/trigram_score.cpp
    filters/quadgram/quadgram_score.cpp
)

add_library(enigma_cpu STATIC
    core/enigma_cpu/enigma_cpu.cpp
)

# ---- Phase R1: CPU simulator ----
add_executable(verify_r1
    core/enigma_cpu/verify_main.cpp
)
target_link_libraries(verify_r1 PRIVATE enigma_cpu)

# ---- Phase R2: Scoring ----
add_executable(verify_r2
    core/enigma_cpu/verify_r2_main.cpp
)
target_link_libraries(verify_r2 PRIVATE enigma_cpu filters)

# ---- Phase R3: GPU kernel ----
add_executable(verify_r3
    core/enigma_gpu/brute_r3.cu
)
set_target_properties(verify_r3 PROPERTIES
    CUDA_ARCHITECTURES "89"          # RTX 4080 = SM 8.9
    CUDA_SEPARABLE_COMPILATION OFF
)
target_compile_options(verify_r3 PRIVATE
    $<$<COMPILE_LANGUAGE:CUDA>:-O3 --use_fast_math -Xcompiler /W3>
)

# ---- C++ compile options ----
foreach(tgt filters enigma_cpu verify_r1 verify_r2)
    target_compile_options(${tgt} PRIVATE
        $<$<CXX_COMPILER_ID:MSVC>:/W3 /O2>
        $<$<NOT:$<CXX_COMPILER_ID:MSVC>>:-Wall -O2>
    )
endforeach()
