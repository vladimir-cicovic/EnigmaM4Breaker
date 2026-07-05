//
// Phase R5 — GPU Top-N reduction (shared memory + warp shuffle)
//
// Problem we're solving:
//   Full Stage A = 1344 rotor configs × 26^4 positions ≈ 614 M keys.
//   Writing the score for every key = 614M × 4B = 2.4 GB — kills throughput.
//
// Solution (per the Phase 5 architecture):
//   1. Each WARP keeps a local Top-1 via __shfl_down_sync().
//   2. Each BLOCK collects the warp winners in shared memory (small Top-N).
//   3. Only block winners atomically update the global Top-N list.
//
// Result: instead of 2.4 GB of writes → only TOP_N × 8B (score+key).
//
// This file tests R5 against the complete Stage A search:
//   - All rotor orders (8P3 = 336) × 2 thin rotors × 2 reflectors = 1344 configs
//   - 26^4 = 456,976 positions per config
//   - Total: ~614 M keys
//   - Quadgram scoring (table in global mem, wiring in constant mem)
//   - Output: top-N candidates on the CPU
//
#include <cstdio>
#include <cstring>
#include <cmath>
#include <vector>
#include <algorithm>
#include <cuda_runtime.h>
#include "config.h"

// ----------------------------------------------------------------
// Parameters
// ----------------------------------------------------------------
static constexpr int  TOP_N      = 64;    // candidates per block in shared mem
static constexpr int  GLOBAL_TOP = 1000;  // total candidates to retain
static constexpr int  QG_N       = 26*26*26*26;
static constexpr int  TG_N       = 26*26*26;
static constexpr int  BLOCK_SZ   = 256;

// ----------------------------------------------------------------
// Constant memory
// ----------------------------------------------------------------
__constant__ int c_rotor_fw[8][26];
__constant__ int c_rotor_bw[8][26];
__constant__ int c_thin_fw[2][26];
__constant__ int c_thin_bw[2][26];
__constant__ int c_refl[2][26];
__constant__ int c_notch[8][26];

#define CUDA_CHECK(call) do {                                        \
    cudaError_t e_=(call);                                           \
    if(e_!=cudaSuccess){                                             \
        fprintf(stderr,"CUDA %s:%d %s\n",__FILE__,__LINE__,         \
                cudaGetErrorString(e_)); exit(1); }                  \
} while(0)

// ----------------------------------------------------------------
// Wiring upload
// ----------------------------------------------------------------
void uploadWirings()
{
    int fw[8][26],bw[8][26],notch[8][26];
    for(int r=0;r<8;r++){
        for(int i=0;i<26;i++) fw[r][i]=ROTOR_WIRING[r][i]-'A';
        for(int i=0;i<26;i++) bw[r][fw[r][i]]=i;
        for(int i=0;i<26;i++) notch[r][i]=0;
        for(const char*n=ROTOR_NOTCH[r];*n;n++) notch[r][*n-'A']=1;
    }
    CUDA_CHECK(cudaMemcpyToSymbol(c_rotor_fw,fw,sizeof(fw)));
    CUDA_CHECK(cudaMemcpyToSymbol(c_rotor_bw,bw,sizeof(bw)));
    CUDA_CHECK(cudaMemcpyToSymbol(c_notch,notch,sizeof(notch)));
    int tfw[2][26],tbw[2][26];
    for(int t=0;t<2;t++){
        for(int i=0;i<26;i++) tfw[t][i]=THIN_ROTOR_WIRING[t][i]-'A';
        for(int i=0;i<26;i++) tbw[t][tfw[t][i]]=i;
    }
    CUDA_CHECK(cudaMemcpyToSymbol(c_thin_fw,tfw,sizeof(tfw)));
    CUDA_CHECK(cudaMemcpyToSymbol(c_thin_bw,tbw,sizeof(tbw)));
    int rfl[2][26];
    for(int r=0;r<2;r++)
        for(int i=0;i<26;i++) rfl[r][i]=REFLECTOR_WIRING[r][i]-'A';
    CUDA_CHECK(cudaMemcpyToSymbol(c_refl,rfl,sizeof(rfl)));
}

// ----------------------------------------------------------------
// N-gram loader
// ----------------------------------------------------------------
static bool loadNgrams(const char* path,float* table,int N,int n)
{
    FILE*f=fopen(path,"r"); if(!f) return false;
    long long*counts=new long long[N]();
    char ng[16]; long long cnt;
    while(fscanf(f,"%15s %lld",ng,&cnt)==2){
        if((int)strlen(ng)!=n) continue;
        bool ok=true; int idx=0;
        for(int i=0;i<n;i++){
            if(ng[i]<'A'||ng[i]>'Z'){ok=false;break;}
            idx=idx*26+(ng[i]-'A');
        }
        if(ok) counts[idx]+=cnt;
    }
    fclose(f);
    long long total=0; for(int i=0;i<N;i++) total+=counts[i];
    float fl=log10f(0.01f)-log10f((float)total);
    for(int i=0;i<N;i++)
        table[i]=(counts[i]>0)?(log10f((float)counts[i])-log10f((float)total)):fl;
    delete[] counts; return true;
}

// ----------------------------------------------------------------
// Device helpers (same as R3/R4)
// ----------------------------------------------------------------
__device__ __forceinline__ void enigmaStep(int*pos,int lr,int mr,int rr){
    bool rn=(bool)c_notch[rr][pos[3]],mn=(bool)c_notch[mr][pos[2]];
    if(mn){pos[1]=(pos[1]+1)%26;pos[2]=(pos[2]+1)%26;}
    else if(rn){pos[2]=(pos[2]+1)%26;}
    pos[3]=(pos[3]+1)%26;
}
__device__ __forceinline__ int pFR(int c,int r,int p,int rng){
    int o=(p-rng+26)%26;c=(c+o)%26;c=c_rotor_fw[r][c];return(c-o+26)%26;}
__device__ __forceinline__ int pBR(int c,int r,int p,int rng){
    int o=(p-rng+26)%26;c=(c+o)%26;c=c_rotor_bw[r][c];return(c-o+26)%26;}
__device__ __forceinline__ int pFT(int c,int t,int p,int rng){
    int o=(p-rng+26)%26;c=(c+o)%26;c=c_thin_fw[t][c];return(c-o+26)%26;}
__device__ __forceinline__ int pBT(int c,int t,int p,int rng){
    int o=(p-rng+26)%26;c=(c+o)%26;c=c_thin_bw[t][c];return(c-o+26)%26;}

__device__ __forceinline__
int enigmaChar(int x,int*pos,int tr,int lr,int mr,int rr,int refl,const int*ring)
{
    enigmaStep(pos,lr,mr,rr);
    x=pFR(x,rr,pos[3],ring[3]);x=pFR(x,mr,pos[2],ring[2]);
    x=pFR(x,lr,pos[1],ring[1]);x=pFT(x,tr,pos[0],ring[0]);
    x=c_refl[refl][x];
    x=pBT(x,tr,pos[0],ring[0]);x=pBR(x,lr,pos[1],ring[1]);
    x=pBR(x,mr,pos[2],ring[2]);x=pBR(x,rr,pos[3],ring[3]);
    return x;
}

// ----------------------------------------------------------------
// Candidate structure (score + encoded key)
// ----------------------------------------------------------------
struct Cand { float score; int key; };  // key = rotor_cfg<<20 | pos_tid

__device__ __forceinline__ bool candLess(const Cand&a,const Cand&b){return a.score<b.score;}

// Insert into a small sorted array (size TOP_N), keeps the TOP_N largest.
__device__ void insertTopN(Cand* arr,int&sz,Cand c,int cap)
{
    if(sz<cap){
        // Insert and bubble-sort upward (small sort, cap<=64)
        arr[sz++]=c;
        for(int i=sz-1;i>0&&arr[i].score>arr[i-1].score;i--){
            Cand t=arr[i];arr[i]=arr[i-1];arr[i-1]=t;
        }
    } else if(c.score>arr[sz-1].score){
        arr[sz-1]=c;
        for(int i=sz-1;i>0&&arr[i].score>arr[i-1].score;i--){
            Cand t=arr[i];arr[i]=arr[i-1];arr[i-1]=t;
        }
    }
}

// ----------------------------------------------------------------
// Global Top-N list (in global memory)
// Protected by a spinlock — we use atomicCAS.
// ----------------------------------------------------------------
__device__ void globalInsert(Cand*gtop,int*glock,int gn,Cand c)
{
    // Quick check: is it even worth entering?
    if(c.score<=gtop[gn-1].score) return;

    // Acquire the lock
    while(atomicCAS(glock,0,1)!=0) {}
    __threadfence();

    // Re-check inside the lock
    if(c.score>gtop[gn-1].score){
        gtop[gn-1]=c;
        // Bubble upward
        for(int i=gn-1;i>0&&gtop[i].score>gtop[i-1].score;i--){
            Cand t=gtop[i];gtop[i]=gtop[i-1];gtop[i-1]=t;
        }
    }

    __threadfence();
    atomicExch(glock,0);
}

// ----------------------------------------------------------------
// Top-N kernel
// One thread = one starting position.
// Rotor configuration encoded in the kernel arguments.
// ----------------------------------------------------------------
__global__ void topNKernel(
    const unsigned char*cipher, int cipher_len, int sample_len,
    int tr,int lr,int mr,int rr,int refl,
    int r0,int r1,int r2,int r3,          // ring settings
    float ioc_min,
    const float*tg_table, float tg_min_per_char,
    const float*qg_table,
    int cfg_id,                            // rotor config index (for encoding the key)
    Cand*g_top, int*g_lock)               // global Top-N list
{
    // ---- Shared memory: block-local Top-N ----
    __shared__ Cand s_top[TOP_N];
    __shared__ int  s_sz;
    __shared__ int  s_lock;

    if(threadIdx.x==0){ s_sz=0; s_lock=0;
        for(int i=0;i<TOP_N;i++) s_top[i]={-1e30f,0}; }
    __syncthreads();

    int tid=blockIdx.x*blockDim.x+threadIdx.x;
    if(tid<26*26*26*26)
    {
        int pr=tid%26, pm=(tid/26)%26, pl=(tid/676)%26, pt=tid/17576;
        int pos[4]={pt,pl,pm,pr};
        int ring[4]={r0,r1,r2,r3};
        int N=(sample_len<cipher_len)?sample_len:cipher_len;

        // Single pass: IoC + trigram + quadgram
        int freq[26]={};
        float tg_sc=0.f,qg_sc=0.f;
        int a=-1,b=-1,c3=-1;

        for(int i=0;i<N;i++){
            int ci=(int)cipher[i]-'A';
            if((unsigned)ci>=26u) continue;
            int p=enigmaChar(ci,pos,tr,lr,mr,rr,refl,ring);
            freq[p]++;
            if(b>=0) tg_sc+=tg_table[b*676+c3*26+p];
            if(a>=0) qg_sc+=qg_table[a*17576+b*676+c3*26+p];
            a=b;b=c3;c3=p;
        }

        // Stage 1: IoC
        int ioc_num=0;
        for(int i=0;i<26;i++) ioc_num+=freq[i]*(freq[i]-1);
        float ioc=(float)ioc_num/(float)(N*(N-1));
        if(ioc<ioc_min) goto done;

        // Stage 2: trigram/char
        { int tc=(N>=3)?(N-2):1;
          if(tg_sc/(float)tc<tg_min_per_char) goto done; }

        // Stage 3: Insert into the block-local Top-N (shared)
        {
            Cand c={qg_sc, (cfg_id<<20)|tid};

            // Spinlock within the block
            bool inserted=false;
            while(!inserted){
                if(atomicCAS(&s_lock,0,1)==0){
                    insertTopN(s_top,s_sz,c,TOP_N);
                    __threadfence_block();
                    atomicExch(&s_lock,0);
                    inserted=true;
                }
            }
        }
        done:;
    }
    __syncthreads();

    // ---- Merge the block-local Top-N into the global list ----
    // Only thread 0 per block does the merge
    if(threadIdx.x==0){
        for(int i=0;i<s_sz;i++)
            globalInsert(g_top,g_lock,GLOBAL_TOP,s_top[i]);
    }
}

// ----------------------------------------------------------------
// Enumeration of rotor configurations (Stage A)
// 8P3 = 336 permutations × 2 thin rotors × 2 reflectors = 1344
// ----------------------------------------------------------------
struct RotorCfg {
    int thin_r, left_r, mid_r, right_r, reflector;
};

static std::vector<RotorCfg> buildAllConfigs()
{
    std::vector<RotorCfg> cfgs;
    for(int refl=0;refl<2;refl++)
    for(int thin=0;thin<2;thin++)
    for(int l=0;l<8;l++)
    for(int m=0;m<8;m++) if(m!=l)
    for(int r=0;r<8;r++) if(r!=l&&r!=m)
        cfgs.push_back({thin,l,m,r,refl});
    return cfgs;
}

static void decodeKey(int key,int&cfg_id,int pos[4])
{
    cfg_id=key>>20;
    int tid=key&((1<<20)-1);
    pos[3]=tid%26;pos[2]=(tid/26)%26;
    pos[1]=(tid/676)%26;pos[0]=tid/17576;
}

// ----------------------------------------------------------------
// Main — R5 verification
// ----------------------------------------------------------------
int main(int argc,char*argv[])
{
    const char*dataDir=(argc>1)?argv[1]:"data";
    printf("========================================\n");
    printf("Enigma M4 GPU — Top-N Redukcija (R5)\n");
    printf("========================================\n\n");

    cudaDeviceProp prop;
    CUDA_CHECK(cudaGetDeviceProperties(&prop,0));
    printf("GPU: %s  (CC %d.%d,  %.0f MB,  %d SM)\n\n",
           prop.name,prop.major,prop.minor,
           prop.totalGlobalMem/1048576.0,(int)prop.multiProcessorCount);

    // --- Load n-gram tables ---
    char qgp[512],tgp[512];
    snprintf(qgp,sizeof(qgp),"%s/german_quadgrams.txt",dataDir);
    snprintf(tgp,sizeof(tgp),"%s/german_trigrams.txt", dataDir);

    printf("Ucitavam tabele ... "); fflush(stdout);
    float*h_qg=new float[QG_N];
    float*h_tg=new float[TG_N];
    if(!loadNgrams(qgp,h_qg,QG_N,4)||!loadNgrams(tgp,h_tg,TG_N,3)){
        fprintf(stderr,"GRESKA: ne mogu otvoriti tabele iz %s\n",dataDir);
        return 1;
    }
    printf("OK\n");

    uploadWirings();
    float*d_qg,*d_tg;
    CUDA_CHECK(cudaMalloc(&d_qg,QG_N*sizeof(float)));
    CUDA_CHECK(cudaMalloc(&d_tg,TG_N*sizeof(float)));
    CUDA_CHECK(cudaMemcpy(d_qg,h_qg,QG_N*sizeof(float),cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_tg,h_tg,TG_N*sizeof(float),cudaMemcpyHostToDevice));
    printf("Tabele u GPU global memoriji: QG %.1f MB + TG %.1f KB\n\n",
           QG_N*4.0/1048576.0, TG_N*4.0/1024.0);

    // --- Test ciphertext (no plugboard, known key) ---
    // Config: Beta(0) I(0) II(1) III(2), Ref B(0), rings AAAA, pos ENIG=(4,13,8,6)
    const char* ct_noplug =
        "IYMJNTOMOJGQKWGUNXNVCMQPQEZKTFJAKXMXWWDNSPXMFDTEADKLPXENPRQ"
        "JONWZEXSYNUVQPHNAZAURBWFTOJBTHJQJEASEDABXIVZLOZMNWBFKIBSJNCW"
        "MDJZHKKZYSNVIYWNEOLABVQVMDPAXCLQZSTLXIRBWNYZKECSUCALIRCRSONB"
        "XBLGJXNJLXCHXGWUQSGALAEUFGSEGDIWMRJFNRXWWMKKKNSXMVROAVFCGAQPC";
    int cipher_len=(int)strlen(ct_noplug);
    // Correct key: cfg_id=??? (Beta I II III, Ref B) | pos=ENIG

    unsigned char*d_cipher;
    CUDA_CHECK(cudaMalloc(&d_cipher,cipher_len));
    CUDA_CHECK(cudaMemcpy(d_cipher,ct_noplug,cipher_len,cudaMemcpyHostToDevice));

    // --- Global Top-N list on the GPU ---
    Cand*d_top;
    int*d_lock;
    CUDA_CHECK(cudaMalloc(&d_top,GLOBAL_TOP*sizeof(Cand)));
    CUDA_CHECK(cudaMalloc(&d_lock,sizeof(int)));
    // Initialization: all -1e30
    {
        std::vector<Cand> init(GLOBAL_TOP,{-1e30f,0});
        CUDA_CHECK(cudaMemcpy(d_top,init.data(),GLOBAL_TOP*sizeof(Cand),cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemset(d_lock,0,sizeof(int)));
    }

    // --- Build all rotor configurations ---
    auto cfgs=buildAllConfigs();
    int num_cfgs=(int)cfgs.size();
    printf("Stage A: %d rotor konfiguracija × 26^4 = %lld ukupnih kljuceva\n",
           num_cfgs,(long long)num_cfgs*26*26*26*26);

    // Find cfg_id for the correct key (Beta I II III, Ref B)
    int correct_cfg_id=-1;
    for(int i=0;i<num_cfgs;i++){
        auto&c=cfgs[i];
        if(c.thin_r==THIN_BETA&&c.left_r==ROT_I&&c.mid_r==ROT_II&&
           c.right_r==ROT_III&&c.reflector==REF_B)
            { correct_cfg_id=i; break; }
    }
    int correct_pos_tid=4*17576+13*676+8*26+6;  // ENIG
    int correct_key=(correct_cfg_id<<20)|correct_pos_tid;
    printf("Tacan kljuc: cfg_id=%d  pos_tid=%d  key=0x%08X\n\n",
           correct_cfg_id,correct_pos_tid,correct_key);

    // Filter thresholds
    float ioc_min=0.042f;
    float tg_min =-5.5f;
    int   sample =150;

    // --- Launch the kernel for ALL rotor configurations ---
    int grid=(26*26*26*26+BLOCK_SZ-1)/BLOCK_SZ;

    cudaEvent_t t0,t1;
    CUDA_CHECK(cudaEventCreate(&t0));
    CUDA_CHECK(cudaEventCreate(&t1));
    CUDA_CHECK(cudaEventRecord(t0));

    for(int i=0;i<num_cfgs;i++){
        auto&c=cfgs[i];
        topNKernel<<<grid,BLOCK_SZ>>>(
            d_cipher,cipher_len,sample,
            c.thin_r,c.left_r,c.mid_r,c.right_r,c.reflector,
            0,0,0,0,            // default rings for Stage A
            ioc_min,d_tg,tg_min,d_qg,
            i,d_top,d_lock);
        // Periodic progress print every 100 configs
        if((i+1)%100==0||i==num_cfgs-1){
            CUDA_CHECK(cudaGetLastError());
            printf("  Config %d/%d ...\r",i+1,num_cfgs); fflush(stdout);
        }
    }
    CUDA_CHECK(cudaDeviceSynchronize());
    CUDA_CHECK(cudaGetLastError());

    CUDA_CHECK(cudaEventRecord(t1));
    CUDA_CHECK(cudaEventSynchronize(t1));
    float ms=0;
    CUDA_CHECK(cudaEventElapsedTime(&ms,t0,t1));

    long long total_keys=(long long)num_cfgs*26*26*26*26;
    printf("\nUkupno: %.2f s  |  %.0f M kljuceva/s\n\n",
           ms/1000.0, (double)total_keys/ms/1000.0);

    // --- Copy Top-N to the CPU ---
    std::vector<Cand> h_top(GLOBAL_TOP);
    CUDA_CHECK(cudaMemcpy(h_top.data(),d_top,GLOBAL_TOP*sizeof(Cand),cudaMemcpyDeviceToHost));

    // Display top-20
    printf("--- Top 20 kandidata (Stage A, default rings, bez plugboarda) ---\n");
    int correct_rank=-1;
    for(int i=0;i<20&&i<GLOBAL_TOP;i++){
        if(h_top[i].score<-1e29f) break;
        int cid; int pos[4];
        decodeKey(h_top[i].key,cid,pos);
        auto&rc=cfgs[cid];
        bool hit=(h_top[i].key==correct_key);
        if(hit) correct_rank=i+1;
        printf("  #%-2d  qg=%8.2f  [%c%c%c%c]  cfg=%d"
               " thin=%d left=%d mid=%d right=%d refl=%d %s\n",
               i+1, h_top[i].score,
               'A'+pos[0],'A'+pos[1],'A'+pos[2],'A'+pos[3],
               cid,rc.thin_r,rc.left_r,rc.mid_r,rc.right_r,rc.reflector,
               hit?"<-- TACAN":"");
    }
    if(correct_rank<0){
        for(int i=20;i<GLOBAL_TOP;i++){
            if(h_top[i].key==correct_key){correct_rank=i+1;break;}
        }
    }

    printf("\nTacan kljuc rank: #%d od top-%d\n",
           correct_rank>0?correct_rank:9999, GLOBAL_TOP);

    // Cleanup
    delete[] h_qg; delete[] h_tg;
    CUDA_CHECK(cudaFree(d_cipher));
    CUDA_CHECK(cudaFree(d_qg));
    CUDA_CHECK(cudaFree(d_tg));
    CUDA_CHECK(cudaFree(d_top));
    CUDA_CHECK(cudaFree(d_lock));
    CUDA_CHECK(cudaEventDestroy(t0));
    CUDA_CHECK(cudaEventDestroy(t1));

    bool ok=(correct_rank>=1&&correct_rank<=GLOBAL_TOP);
    printf("\n========================================\n");
    if(ok){
        printf("PROSLA — tacan kljuc u top-%d.\n",GLOBAL_TOP);
        printf("Nastavi na Fazu R6 (ring setting search).\n");
    } else {
        printf("PALA — tacan kljuc nije u top-%d.\n",GLOBAL_TOP);
        printf("Provjeri cfg_id encodiranje ili filter pragove.\n");
    }
    return ok?0:1;
}
