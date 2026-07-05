#pragma once
#include <cuda_runtime.h>

// ----------------------------------------------------------------
// Constant memory — defined in brute_r3.cu (one TU only).
// Other .cu files that need these must redeclare as extern.
// ----------------------------------------------------------------
extern __constant__ int c_rotor_fw[8][26];   // regular rotors I-VIII forward
extern __constant__ int c_rotor_bw[8][26];   // inverse
extern __constant__ int c_thin_fw[2][26];    // Beta, Gamma forward
extern __constant__ int c_thin_bw[2][26];    // inverse
extern __constant__ int c_refl[2][26];       // B-thin, C-thin
extern __constant__ int c_notch[8][26];      // 1 if notch at that position, else 0

// Upload all wiring tables to device constant memory (call once from host)
void uploadWirings();

// ----------------------------------------------------------------
// Device helpers — all forceinline to eliminate call overhead
// ----------------------------------------------------------------

__device__ __forceinline__
void enigmaStep(int* pos, int left_r, int mid_r, int right_r)
{
    bool rn = (bool)c_notch[right_r][pos[3]];
    bool mn = (bool)c_notch[mid_r  ][pos[2]];
    if (mn) {
        pos[1] = (pos[1] + 1) % 26;   // left steps
        pos[2] = (pos[2] + 1) % 26;   // middle double-steps
    } else if (rn) {
        pos[2] = (pos[2] + 1) % 26;   // middle steps
    }
    pos[3] = (pos[3] + 1) % 26;       // right always steps
    // pos[0] (thin) never steps
}

__device__ __forceinline__
int passFwdReg(int c, int r, int pos, int ring)
{
    int off = (pos - ring + 26) % 26;
    c = (c + off) % 26;
    c = c_rotor_fw[r][c];
    return (c - off + 26) % 26;
}

__device__ __forceinline__
int passBwdReg(int c, int r, int pos, int ring)
{
    int off = (pos - ring + 26) % 26;
    c = (c + off) % 26;
    c = c_rotor_bw[r][c];
    return (c - off + 26) % 26;
}

__device__ __forceinline__
int passFwdThin(int c, int t, int pos, int ring)
{
    int off = (pos - ring + 26) % 26;
    c = (c + off) % 26;
    c = c_thin_fw[t][c];
    return (c - off + 26) % 26;
}

__device__ __forceinline__
int passBwdThin(int c, int t, int pos, int ring)
{
    int off = (pos - ring + 26) % 26;
    c = (c + off) % 26;
    c = c_thin_bw[t][c];
    return (c - off + 26) % 26;
}

// Encrypt one character.  pos[4] is modified in-place (stepping).
// No plugboard — IoC is plugboard-invariant, so Stage A skips it.
__device__ __forceinline__
int enigmaCharGPU(int x, int* pos,
                  int thin_r, int left_r, int mid_r, int right_r,
                  int reflector, const int* ring)
{
    enigmaStep(pos, left_r, mid_r, right_r);

    x = passFwdReg (x, right_r, pos[3], ring[3]);
    x = passFwdReg (x, mid_r,   pos[2], ring[2]);
    x = passFwdReg (x, left_r,  pos[1], ring[1]);
    x = passFwdThin(x, thin_r,  pos[0], ring[0]);
    x = c_refl[reflector][x];
    x = passBwdThin(x, thin_r,  pos[0], ring[0]);
    x = passBwdReg (x, left_r,  pos[1], ring[1]);
    x = passBwdReg (x, mid_r,   pos[2], ring[2]);
    x = passBwdReg (x, right_r, pos[3], ring[3]);
    return x;
}
