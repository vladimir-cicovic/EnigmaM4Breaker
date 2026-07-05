//
// Faza R3 — GPU brute-force (basic, correct before fast)
// One thread = one starting-position combination (26^4 = 456,976).
// Stage A: fixed rotor order, empty plugboard, IoC scoring.
//
#include <cstdio>
#include <cstring>
#include <cmath>
#include <vector>
#include <algorithm>
#include <cuda_runtime.h>
#include "config.h"

// ----------------------------------------------------------------
// Constant memory (small wiring tables, loaded once from host)
// ----------------------------------------------------------------
__constant__ int c_rotor_fw[8][26];    // regular rotors I-VIII forward
__constant__ int c_rotor_bw[8][26];    // inverse
__constant__ int c_thin_fw[2][26];     // Beta, Gamma forward
__constant__ int c_thin_bw[2][26];     // inverse
__constant__ int c_refl[2][26];        // B-thin, C-thin
__constant__ int c_notch[8][26];       // 1 if notch fires at this position

// ----------------------------------------------------------------
// CUDA error check macro
// ----------------------------------------------------------------
#define CUDA_CHECK(call) do {                                         \
    cudaError_t e_ = (call);                                          \
    if (e_ != cudaSuccess) {                                          \
        fprintf(stderr, "CUDA error %s:%d  %s\n",                    \
                __FILE__, __LINE__, cudaGetErrorString(e_));          \
        exit(1);                                                      \
    }                                                                 \
} while(0)

// ----------------------------------------------------------------
// Upload wiring tables to constant memory (host function)
// ----------------------------------------------------------------
void uploadWirings()
{
    int fw[8][26], bw[8][26], notch_h[8][26];
    for (int r = 0; r < 8; r++) {
        for (int i = 0; i < 26; i++) fw[r][i] = ROTOR_WIRING[r][i] - 'A';
        for (int i = 0; i < 26; i++) bw[r][fw[r][i]] = i;
        for (int i = 0; i < 26; i++) notch_h[r][i] = 0;
        for (const char* n = ROTOR_NOTCH[r]; *n; n++)
            notch_h[r][*n - 'A'] = 1;
    }
    CUDA_CHECK(cudaMemcpyToSymbol(c_rotor_fw, fw,      sizeof(fw)));
    CUDA_CHECK(cudaMemcpyToSymbol(c_rotor_bw, bw,      sizeof(bw)));
    CUDA_CHECK(cudaMemcpyToSymbol(c_notch,    notch_h, sizeof(notch_h)));

    int tfw[2][26], tbw[2][26];
    for (int t = 0; t < 2; t++) {
        for (int i = 0; i < 26; i++) tfw[t][i] = THIN_ROTOR_WIRING[t][i] - 'A';
        for (int i = 0; i < 26; i++) tbw[t][tfw[t][i]] = i;
    }
    CUDA_CHECK(cudaMemcpyToSymbol(c_thin_fw, tfw, sizeof(tfw)));
    CUDA_CHECK(cudaMemcpyToSymbol(c_thin_bw, tbw, sizeof(tbw)));

    int rfl[2][26];
    for (int r = 0; r < 2; r++)
        for (int i = 0; i < 26; i++) rfl[r][i] = REFLECTOR_WIRING[r][i] - 'A';
    CUDA_CHECK(cudaMemcpyToSymbol(c_refl, rfl, sizeof(rfl)));
}

// ----------------------------------------------------------------
// Device helpers — all forceinline for zero call overhead
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
        pos[2] = (pos[2] + 1) % 26;   // middle steps normally
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

// One character, empty plugboard (IoC is plugboard-invariant → omit in Stage A).
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

// ----------------------------------------------------------------
// IoC kernel — one thread per 4-rotor starting position
// ----------------------------------------------------------------
__global__ void iocKernel(
    const unsigned char* cipher,
    int cipher_len,
    int sample_len,
    int thin_r, int left_r, int mid_r, int right_r,
    int reflector,
    int ring0, int ring1, int ring2, int ring3,
    float* d_scores)
{
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid >= 26 * 26 * 26 * 26) return;

    // Decode starting position from linear index
    int pr = tid % 26;
    int pm = (tid /   26) % 26;
    int pl = (tid /  676) % 26;
    int pt =  tid / 17576;

    int pos[4]  = {pt, pl, pm, pr};
    int ring[4] = {ring0, ring1, ring2, ring3};

    int N = (sample_len < cipher_len) ? sample_len : cipher_len;

    int freq[26] = {};
    for (int i = 0; i < N; i++) {
        int c = (int)cipher[i] - 'A';
        if ((unsigned)c >= 26u) continue;
        int p = enigmaCharGPU(c, pos, thin_r, left_r, mid_r, right_r, reflector, ring);
        freq[p]++;
    }

    // IoC = Σ(f*(f-1)) / (N*(N-1))
    int num = 0;
    for (int i = 0; i < 26; i++) num += freq[i] * (freq[i] - 1);
    d_scores[tid] = (N >= 2) ? (float)num / (float)(N * (N - 1)) : 0.0f;
}

// ----------------------------------------------------------------
// Host utilities
// ----------------------------------------------------------------
struct ScoredPos { float ioc; int tid; };
static bool cmpDesc(const ScoredPos& a, const ScoredPos& b) { return a.ioc > b.ioc; }

static void decodePos(int tid, int out[4]) {
    out[3] = tid % 26;
    out[2] = (tid /   26) % 26;
    out[1] = (tid /  676) % 26;
    out[0] =  tid / 17576;
}

// ----------------------------------------------------------------
// Run one IoC brute-force pass and return rank of target position
// ----------------------------------------------------------------
static int runIoCTest(
    const char* label,
    const char* cipher_str,
    int thin_r, int left_r, int mid_r, int right_r,
    int reflector,
    int ring0, int ring1, int ring2, int ring3,
    int target_tid,
    int sample_len,
    float* h_scores_out,   // caller-alloc 456976 floats
    int total_pos)
{
    int cipher_len = (int)strlen(cipher_str);
    unsigned char* d_cipher;
    CUDA_CHECK(cudaMalloc(&d_cipher, cipher_len));
    CUDA_CHECK(cudaMemcpy(d_cipher, cipher_str, cipher_len, cudaMemcpyHostToDevice));

    float* d_scores;
    CUDA_CHECK(cudaMalloc(&d_scores, total_pos * sizeof(float)));

    const int BLOCK = 256;
    int grid = (total_pos + BLOCK - 1) / BLOCK;

    cudaEvent_t t0, t1;
    CUDA_CHECK(cudaEventCreate(&t0));
    CUDA_CHECK(cudaEventCreate(&t1));
    CUDA_CHECK(cudaEventRecord(t0));

    iocKernel<<<grid, BLOCK>>>(d_cipher, cipher_len, sample_len,
                               thin_r, left_r, mid_r, right_r, reflector,
                               ring0, ring1, ring2, ring3, d_scores);
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaEventRecord(t1));
    CUDA_CHECK(cudaEventSynchronize(t1));
    float ms = 0;
    CUDA_CHECK(cudaEventElapsedTime(&ms, t0, t1));

    CUDA_CHECK(cudaMemcpy(h_scores_out, d_scores,
                          total_pos * sizeof(float), cudaMemcpyDeviceToHost));
    CUDA_CHECK(cudaFree(d_cipher));
    CUDA_CHECK(cudaFree(d_scores));
    CUDA_CHECK(cudaEventDestroy(t0));
    CUDA_CHECK(cudaEventDestroy(t1));

    // Rank the target position
    std::vector<ScoredPos> results(total_pos);
    for (int i = 0; i < total_pos; i++) results[i] = {h_scores_out[i], i};
    std::partial_sort(results.begin(), results.begin() + 200,
                      results.end(), cmpDesc);

    printf("\n--- %s | kernel %.2f ms | %.0f M pos/s ---\n",
           label, ms, (double)total_pos / ms / 1000.0);
    printf("Top 10 pozicija (IoC, uzorak %d znakova):\n", sample_len);

    int correct_rank = -1;
    for (int i = 0; i < 10; i++) {
        int dec[4]; decodePos(results[i].tid, dec);
        bool hit = (results[i].tid == target_tid);
        if (hit) correct_rank = i + 1;
        printf("  #%-2d  IoC=%.5f  [%c%c%c%c] %s\n",
               i+1, results[i].ioc,
               'A'+dec[0], 'A'+dec[1], 'A'+dec[2], 'A'+dec[3],
               hit ? "<-- TACAN" : "");
    }
    if (correct_rank < 0) {
        for (int i = 10; i < 200; i++) {
            if (results[i].tid == target_tid) { correct_rank = i+1; break; }
        }
    }
    float correct_ioc = h_scores_out[target_tid];
    int dec[4]; decodePos(target_tid, dec);
    printf("Tacan kljuc [%c%c%c%c]: IoC=%.5f  rank=#%d\n",
           'A'+dec[0], 'A'+dec[1], 'A'+dec[2], 'A'+dec[3],
           correct_ioc, correct_rank > 0 ? correct_rank : 200);
    return correct_rank;
}

// ----------------------------------------------------------------
// Main — R3 verification
// ----------------------------------------------------------------
int main()
{
    printf("========================================\n");
    printf("Enigma M4 GPU — Verifikacija (Faza R3)\n");
    printf("========================================\n\n");

    cudaDeviceProp prop;
    CUDA_CHECK(cudaGetDeviceProperties(&prop, 0));
    printf("GPU: %s  (CC %d.%d,  %.0f MB VRAM)\n",
           prop.name, prop.major, prop.minor,
           prop.totalGlobalMem / 1048576.0);

    uploadWirings();
    printf("Wiring tabele uploadovane u constant memoriju.\n");

    const int total_pos = 26 * 26 * 26 * 26;   // 456 976
    std::vector<float> h_scores(total_pos);

    // ---- Test 1: EMPTY PLUGBOARD (real kernel correctness test) ----
    // Ciphertext encrypted with Beta I II III, Ref B, rings AAAA,
    // starting pos ENIG (4,13,8,6), NO plugboard.
    // Kernel should find this position as top IoC candidate.
    const char* ct_noplug =
        "IYMJNTOMOJGQKWGUNXNVCMQPQEZKTFJAKXMXWWDNSPXMFDTEADKLPXENPRQ"
        "JONWZEXSYNUVQPHNAZAURBWFTOJBTHJQJEASEDABXIVZLOZMNWBFKIBSJNCW"
        "MDJZHKKZYSNVIYWNEOLABVQVMDPAXCLQZSTLXIRBWNYZKECSUCALIRCRSONB"
        "XBLGJXNJLXCHXGWUQSGALAEUFGSEGDIWMRJFNRXWWMKKKNSXMVROAVFCGAQPC";

    // Target: ENIG = thin=4(E), left=13(N), mid=8(I), right=6(G)
    int tid_noplug = 4*17576 + 13*676 + 8*26 + 6;   // 79306

    int rank1 = runIoCTest(
        "Test 1 — bez plugboarda (Beta I II III, Ref B, rings AAAA)",
        ct_noplug,
        THIN_BETA, ROT_I, ROT_II, ROT_III, REF_B,
        0, 0, 0, 0,
        tid_noplug, 120, h_scores.data(), total_pos);

    // ---- Test 2: U-264 (10 plug pairs) — IoC does NOT work without a plugboard ----
    // This is EXPECTED behavior. Stage A for messages with a plugboard
    // uses QUADGRAM scoring (implemented in Phase R4).
    const char* ct_u264 =
        "NCZWVUSXPNYMINHZXMQXSFWXWLKJAHSHNMCOCCAKUQPMKCSMHKSEINJUSBLK"
        "IOSXCKUBHMLLXCSJUSRRDVKOHULXWCCBGVLIYXEOAHXRHKKFVDREWEZLXOBA"
        "FGYUJQUKGRTVUKAMEURBVEKSUHHVOYHABCJWMAKLFKLMYFVNRIZRVVRTKOFD"
        "ANJMOLBGFFLEOPRGTFLVRHOWOPBEKVWMUQFMPWPARMFHAGKXIIBG";

    int tid_u264 = 21*17576 + 9*676 + 13*26 + 0;   // 375518  (VJNA)

    int rank2 = runIoCTest(
        "Test 2 — U-264 sa 10 plug parova (ocekivano: IoC NE nalazi VJNA)",
        ct_u264,
        THIN_BETA, ROT_II, ROT_IV, ROT_I, REF_B,
        0, 0, 0, 21,
        tid_u264, 100, h_scores.data(), total_pos);

    // ---- Conclusion ----
    printf("\n========================================\n");
    printf("ZAKLJUCAK:\n");
    printf("  Test 1 (bez plug): tacan kljuc rank #%d  -> %s\n",
           rank1, rank1 > 0 && rank1 <= 20 ? "PROSLA (IoC radi)" : "NIJE U TOP-20");
    printf("  Test 2 (U-264):    tacan kljuc rank #%d  -> %s\n",
           rank2, "IoC bez plugboarda ne radi za teske plugboarde");
    printf("\n  Stage A ce koristiti QUADGRAM scoring (Faza R4)\n");
    printf("  koji radi i za poruke s plugboardom.\n");

    bool ok = (rank1 > 0 && rank1 <= 20);
    if (ok) {
        printf("\nPROSLA — GPU kernel je tacan.\n");
        printf("Nastavi na Fazu R4.\n");
    } else {
        printf("\nPALA — greska u kernelu ili pogresni test parametri.\n");
    }
    return ok ? 0 : 1;
}
