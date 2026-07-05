//
// Phase R4 — Multi-stage GPU filter: IoC -> trigram -> quadgram
//
// One thread = one starting position (26^4 = 456,976).
// Quadgram table (~1.8 MB) in GPU global memory.
// Trigram table (~69 KB) in GPU global memory (fits the L1 cache).
// Wiring tables in __constant__ memory.
//
#include <cstdio>
#include <cstring>
#include <cmath>
#include <vector>
#include <algorithm>
#include <cuda_runtime.h>
#include "config.h"

// ----------------------------------------------------------------
// Constant memory — wiring tables
// ----------------------------------------------------------------
__constant__ int c_rotor_fw[8][26];
__constant__ int c_rotor_bw[8][26];
__constant__ int c_thin_fw[2][26];
__constant__ int c_thin_bw[2][26];
__constant__ int c_refl[2][26];
__constant__ int c_notch[8][26];

static constexpr int QG_N = 26*26*26*26;   // 456 976
static constexpr int TG_N = 26*26*26;       //  17 576

#define CUDA_CHECK(call) do {                                         \
    cudaError_t e_ = (call);                                          \
    if (e_ != cudaSuccess) {                                          \
        fprintf(stderr, "CUDA error %s:%d  %s\n",                    \
                __FILE__, __LINE__, cudaGetErrorString(e_));          \
        exit(1);                                                      \
    }                                                                 \
} while(0)

// ----------------------------------------------------------------
// Wiring upload (identical to R3)
// ----------------------------------------------------------------
void uploadWirings()
{
    int fw[8][26], bw[8][26], notch_h[8][26];
    for (int r = 0; r < 8; r++) {
        for (int i = 0; i < 26; i++) fw[r][i] = ROTOR_WIRING[r][i] - 'A';
        for (int i = 0; i < 26; i++) bw[r][fw[r][i]] = i;
        for (int i = 0; i < 26; i++) notch_h[r][i] = 0;
        for (const char* n = ROTOR_NOTCH[r]; *n; n++) notch_h[r][*n-'A'] = 1;
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
// N-gram file loader (A-Z only; ignores umlauts)
// ----------------------------------------------------------------
static bool loadNgrams(const char* path, float* table, int N, int n)
{
    FILE* f = fopen(path, "r");
    if (!f) return false;
    long long* counts = new long long[N]();
    char ng[16]; long long cnt;
    while (fscanf(f, "%15s %lld", ng, &cnt) == 2) {
        if ((int)strlen(ng) != n) continue;
        bool ok = true; int idx = 0;
        for (int i = 0; i < n; i++) {
            if (ng[i]<'A'||ng[i]>'Z') { ok=false; break; }
            idx = idx*26 + (ng[i]-'A');
        }
        if (ok) counts[idx] += cnt;
    }
    fclose(f);
    long long total = 0;
    for (int i = 0; i < N; i++) total += counts[i];
    float floor_lp = log10f(0.01f) - log10f((float)total);
    for (int i = 0; i < N; i++)
        table[i] = (counts[i]>0) ? (log10f((float)counts[i]) - log10f((float)total)) : floor_lp;
    delete[] counts;
    return true;
}

// ----------------------------------------------------------------
// Device helpers (same as R3)
// ----------------------------------------------------------------
__device__ __forceinline__
void enigmaStep(int* pos, int left_r, int mid_r, int right_r)
{
    bool rn = (bool)c_notch[right_r][pos[3]];
    bool mn = (bool)c_notch[mid_r  ][pos[2]];
    if (mn) { pos[1]=(pos[1]+1)%26; pos[2]=(pos[2]+1)%26; }
    else if (rn) { pos[2]=(pos[2]+1)%26; }
    pos[3]=(pos[3]+1)%26;
}

__device__ __forceinline__
int passFwdReg(int c,int r,int pos,int ring){
    int off=(pos-ring+26)%26; c=(c+off)%26; c=c_rotor_fw[r][c]; return(c-off+26)%26; }
__device__ __forceinline__
int passBwdReg(int c,int r,int pos,int ring){
    int off=(pos-ring+26)%26; c=(c+off)%26; c=c_rotor_bw[r][c]; return(c-off+26)%26; }
__device__ __forceinline__
int passFwdThin(int c,int t,int pos,int ring){
    int off=(pos-ring+26)%26; c=(c+off)%26; c=c_thin_fw[t][c]; return(c-off+26)%26; }
__device__ __forceinline__
int passBwdThin(int c,int t,int pos,int ring){
    int off=(pos-ring+26)%26; c=(c+off)%26; c=c_thin_bw[t][c]; return(c-off+26)%26; }

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
// Multi-stage filter kernel
// Single decryption pass: IoC + trigram + quadgram computed together.
//
// Output d_scores[tid]:
//   quadgram score (sum of log-probs)  if all filters pass
//   -1e30f                              if IoC or trigram filter rejects
// ----------------------------------------------------------------
__global__ void multiStageKernel(
    const unsigned char* cipher,
    int cipher_len,
    int sample_len,
    int thin_r, int left_r, int mid_r, int right_r,
    int reflector,
    int ring0, int ring1, int ring2, int ring3,
    float ioc_min,            // Stage 1: reject below this
    const float* tg_table,   // Stage 2: trigram log-probs
    float tg_min_per_char,    // Stage 2: reject if trigram/char below this
    const float* qg_table,   // Stage 3: quadgram log-probs
    float* d_scores)
{
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid >= 26*26*26*26) return;

    int pr = tid % 26;
    int pm = (tid /   26) % 26;
    int pl = (tid /  676) % 26;
    int pt =  tid / 17576;

    int pos[4]  = {pt, pl, pm, pr};
    int ring[4] = {ring0, ring1, ring2, ring3};

    int N = (sample_len < cipher_len) ? sample_len : cipher_len;

    // --- Single pass: decrypt + all three scores ---
    int freq[26] = {};
    float tg_score = 0.0f;
    float qg_score = 0.0f;
    int a = -1, b = -1, c3 = -1;   // sliding window (oldest → newest)

    for (int i = 0; i < N; i++) {
        int ci = (int)cipher[i] - 'A';
        if ((unsigned)ci >= 26u) continue;
        int p = enigmaCharGPU(ci, pos, thin_r, left_r, mid_r, right_r, reflector, ring);
        freq[p]++;

        // Trigram needs 3 chars (b, c3, p) → available from i≥2
        if (b >= 0)
            tg_score += tg_table[b*676 + c3*26 + p];

        // Quadgram needs 4 chars (a, b, c3, p) → available from i≥3
        if (a >= 0)
            qg_score += qg_table[a*17576 + b*676 + c3*26 + p];

        a = b; b = c3; c3 = p;
    }

    // --- Stage 1: IoC ---
    int ioc_num = 0;
    for (int i = 0; i < 26; i++) ioc_num += freq[i]*(freq[i]-1);
    float ioc = (float)ioc_num / (float)(N*(N-1));
    if (ioc < ioc_min) { d_scores[tid] = -1e30f; return; }

    // --- Stage 2: trigram/char ---
    int tg_count = (N >= 3) ? (N - 2) : 1;
    if (tg_score / (float)tg_count < tg_min_per_char)
        { d_scores[tid] = -1e30f; return; }

    // --- Stage 3: quadgram score ---
    d_scores[tid] = qg_score;
}

// ----------------------------------------------------------------
// Host utilities
// ----------------------------------------------------------------
struct ScoredPos { float score; int tid; };
static bool cmpDesc(const ScoredPos& a,const ScoredPos& b){return a.score>b.score;}
static void decodePos(int tid,int out[4]){
    out[3]=tid%26; out[2]=(tid/26)%26; out[1]=(tid/676)%26; out[0]=tid/17576; }

// ----------------------------------------------------------------
// Main — R4 verification
// ----------------------------------------------------------------
int main(int argc, char* argv[])
{
    const char* dataDir = (argc > 1) ? argv[1] : "data";
    printf("========================================\n");
    printf("Enigma M4 GPU — Višestepeni filter (R4)\n");
    printf("========================================\n\n");

    cudaDeviceProp prop;
    CUDA_CHECK(cudaGetDeviceProperties(&prop, 0));
    printf("GPU: %s  (CC %d.%d)\n\n", prop.name, prop.major, prop.minor);

    // --- Load n-gram tables from disk ---
    char qg_path[512], tg_path[512];
    snprintf(qg_path, sizeof(qg_path), "%s/german_quadgrams.txt", dataDir);
    snprintf(tg_path, sizeof(tg_path), "%s/german_trigrams.txt",  dataDir);

    printf("Ucitavam quadgram tabelu ... "); fflush(stdout);
    float* h_qg = new float[QG_N];
    if (!loadNgrams(qg_path, h_qg, QG_N, 4)) {
        fprintf(stderr, "GRESKA: ne mogu otvoriti %s\n", qg_path); return 1; }
    printf("OK\n");

    printf("Ucitavam trigram tabelu  ... "); fflush(stdout);
    float* h_tg = new float[TG_N];
    if (!loadNgrams(tg_path, h_tg, TG_N, 3)) {
        fprintf(stderr, "GRESKA: ne mogu otvoriti %s\n", tg_path); return 1; }
    printf("OK\n\n");

    // --- Upload to GPU ---
    uploadWirings();
    float *d_qg, *d_tg;
    CUDA_CHECK(cudaMalloc(&d_qg, QG_N * sizeof(float)));
    CUDA_CHECK(cudaMalloc(&d_tg, TG_N * sizeof(float)));
    CUDA_CHECK(cudaMemcpy(d_qg, h_qg, QG_N*sizeof(float), cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_tg, h_tg, TG_N*sizeof(float), cudaMemcpyHostToDevice));
    printf("Tabele uploadovane: QG %.1f MB + TG %.1f KB u global memoriji.\n\n",
           QG_N*4.0/1048576.0, TG_N*4.0/1024.0);

    // --- Test: no-plugboard ciphertext ---
    // Encrypted with: Beta I II III, Ref B, rings AAAA, pos ENIG=(4,13,8,6), NO plugboard.
    // Stage A with an empty plugboard WORKS here because there's no plugboard interaction.
    // U-264 (10 plug pairs) needs Stage B+C refinement after Stage A
    // (Stage A returns the top-1000+, Stage C plugboard hill-climbing finds the correct key).
    const char* cipher_str =
        "IYMJNTOMOJGQKWGUNXNVCMQPQEZKTFJAKXMXWWDNSPXMFDTEADKLPXENPRQ"
        "JONWZEXSYNUVQPHNAZAURBWFTOJBTHJQJEASEDABXIVZLOZMNWBFKIBSJNCW"
        "MDJZHKKZYSNVIYWNEOLABVQVMDPAXCLQZSTLXIRBWNYZKECSUCALIRCRSONB"
        "XBLGJXNJLXCHXGWUQSGALAEUFGSEGDIWMRJFNRXWWMKKKNSXMVROAVFCGAQPC";
    int cipher_len = (int)strlen(cipher_str);

    unsigned char* d_cipher;
    CUDA_CHECK(cudaMalloc(&d_cipher, cipher_len));
    CUDA_CHECK(cudaMemcpy(d_cipher, cipher_str, cipher_len, cudaMemcpyHostToDevice));

    // Rotor config: Beta(0) I(0) II(1) III(2), Ref B, rings all 0
    int thin_r=THIN_BETA, left_r=ROT_I, mid_r=ROT_II, right_r=ROT_III, reflector=REF_B;
    int ring0=0, ring1=0, ring2=0, ring3=0;

    // Correct position: ENIG = (E=4, N=13, I=8, G=6)
    int correct_tid = 4*17576 + 13*676 + 8*26 + 6;   // 79306

    // --- Allocate score array ---
    int total_pos = 26*26*26*26;
    float* d_scores;
    CUDA_CHECK(cudaMalloc(&d_scores, total_pos*sizeof(float)));

    // --- Filter thresholds ---
    // Without a plugboard: German plaintext IoC ~0.07+, trigram normal
    float ioc_min        = 0.042f;   // Stage 1: reject random (<0.038 is random)
    float tg_min_per_char= -5.5f;    // Stage 2: reject weak candidates
    int   sample_len     = 150;

    printf("Konfiguracija: Beta I II III | Ref B | Rings AAAA | BEZ plugboarda\n");
    printf("Trazimo ENIG (tid=%d) na %d znakova\n", correct_tid, sample_len);
    printf("Filteri: IoC>%.3f, trigram/c>%.2f, quadgram max\n\n",
           ioc_min, tg_min_per_char);

    // --- Launch kernel ---
    const int BLOCK = 256;
    int grid = (total_pos + BLOCK - 1) / BLOCK;

    cudaEvent_t t0, t1;
    CUDA_CHECK(cudaEventCreate(&t0));
    CUDA_CHECK(cudaEventCreate(&t1));
    CUDA_CHECK(cudaEventRecord(t0));

    multiStageKernel<<<grid, BLOCK>>>(
        d_cipher, cipher_len, sample_len,
        thin_r, left_r, mid_r, right_r, reflector,
        ring0, ring1, ring2, ring3,
        ioc_min, d_tg, tg_min_per_char, d_qg,
        d_scores);
    CUDA_CHECK(cudaGetLastError());

    CUDA_CHECK(cudaEventRecord(t1));
    CUDA_CHECK(cudaEventSynchronize(t1));
    float ms = 0;
    CUDA_CHECK(cudaEventElapsedTime(&ms, t0, t1));
    printf("Kernel: %.2f ms  |  %.0f M pozicija/s\n\n",
           ms, (double)total_pos/ms/1000.0);

    // --- Copy back and analyse ---
    std::vector<float> h_scores(total_pos);
    CUDA_CHECK(cudaMemcpy(h_scores.data(), d_scores,
                          total_pos*sizeof(float), cudaMemcpyDeviceToHost));

    // Count survivors (passed all filters)
    int survivors = 0;
    for (int i = 0; i < total_pos; i++)
        if (h_scores[i] > -1e29f) survivors++;

    printf("Prezivjeli filtere: %d / %d  (%.2f%%)\n\n",
           survivors, total_pos, 100.0f*survivors/total_pos);

    // Rank all
    std::vector<ScoredPos> results(total_pos);
    for (int i = 0; i < total_pos; i++) results[i] = {h_scores[i], i};
    std::partial_sort(results.begin(),
                      results.begin() + std::min(200, total_pos),
                      results.end(), cmpDesc);

    printf("--- Top 20 pozicija (quadgram score) ---\n");
    int correct_rank = -1;
    for (int i = 0; i < 20; i++) {
        int dec[4]; decodePos(results[i].tid, dec);
        bool hit = (results[i].tid == correct_tid);
        if (hit) correct_rank = i + 1;
        printf("  #%-2d  qg=%.2f  [%c%c%c%c] %s\n",
               i+1, results[i].score,
               'A'+dec[0],'A'+dec[1],'A'+dec[2],'A'+dec[3],
               hit ? "<-- TACAN KLJUC (VJNA)" : "");
    }
    if (correct_rank < 0) {
        for (int i = 20; i < 200; i++)
            if (results[i].tid == correct_tid) { correct_rank = i+1; break; }
    }

    float correct_qg  = h_scores[correct_tid];
    float best_qg     = results[0].score;
    float median_qg   = results[survivors/2].score;

    printf("\nTacan kljuc VJNA:\n");
    printf("  Quadgram score: %.2f  (best: %.2f, median survivors: %.2f)\n",
           correct_qg, best_qg, median_qg);
    printf("  Rank: #%d od %d prezivelih\n",
           correct_rank > 0 ? correct_rank : 999, survivors);

    // Cleanup
    CUDA_CHECK(cudaFree(d_cipher));
    CUDA_CHECK(cudaFree(d_scores));
    CUDA_CHECK(cudaFree(d_qg));
    CUDA_CHECK(cudaFree(d_tg));
    CUDA_CHECK(cudaEventDestroy(t0));
    CUDA_CHECK(cudaEventDestroy(t1));
    delete[] h_qg;
    delete[] h_tg;

    bool ok = (correct_rank >= 1 && correct_rank <= 100);
    printf("\n========================================\n");
    if (ok) {
        printf("PROSLA — tacan kljuc u top-100 po quadgramu.\n");
        printf("Nastavi na Fazu R5 (GPU Top-N redukcija).\n");
    } else {
        printf("PALA — rank #%d (ocekivano <= 100).\n",
               correct_rank > 0 ? correct_rank : 999);
        printf("Napomena: Sa jakim plugboardom Stage A\n");
        printf("mozda treba veci sample_len ili blazi pragovi.\n");
    }
    return ok ? 0 : 1;
}
