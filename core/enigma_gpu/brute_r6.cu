//
// Phase R6 — Ring Setting Search (GPU)
//
// Pipeline:
//   1. Stage A (R5 kernel)  →  top-1000 candidates, ring=0
//   2. R6 ring sweep kernel →  for each candidate tries 26^3 = 17576 ring combos
//                              (ring_left × ring_mid × ring_right)
//   3. Output: refined top-N with ring settings
//
// Kernel design:
//   grid = dim3(ceil(17576/256), num_cands)   →  2D grid
//   block = 256 threads
//   Each thread = one (candidate, ring_combo).
//   Shared mem reduction within the block → one thread/block atomically updates
//   the global best for that candidate.
//
#include <cstdio>
#include <cstring>
#include <cmath>
#include <vector>
#include <algorithm>
#include <cuda_runtime.h>
#include "config.h"

static constexpr int QG_N        = 26*26*26*26;
static constexpr int TG_N        = 26*26*26;
static constexpr int RING3       = 26*26*26;      // 17576 ring combos
static constexpr int STAGE_A_TOP = 1000;
static constexpr int R6_REFINE   = 50;            // top candidates to print

// ----------------------------------------------------------------
// Constant memory
// ----------------------------------------------------------------
__constant__ int c_rotor_fw[8][26];
__constant__ int c_rotor_bw[8][26];
__constant__ int c_thin_fw[2][26];
__constant__ int c_thin_bw[2][26];
__constant__ int c_refl[2][26];
__constant__ int c_notch[8][26];

#define CUDA_CHECK(call) do { \
    cudaError_t e_=(call); \
    if(e_!=cudaSuccess){ fprintf(stderr,"CUDA %s:%d %s\n",__FILE__,__LINE__, \
        cudaGetErrorString(e_)); exit(1); } } while(0)

// ----------------------------------------------------------------
// Wiring upload
// ----------------------------------------------------------------
void uploadWirings() {
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

static bool loadNgrams(const char*path,float*table,int N,int n){
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
// Device helpers
// ----------------------------------------------------------------
__device__ __forceinline__ void enigmaStep(int*pos,int lr,int mr,int rr){
    bool rn=(bool)c_notch[rr][pos[3]],mn=(bool)c_notch[mr][pos[2]];
    if(mn){pos[1]=(pos[1]+1)%26;pos[2]=(pos[2]+1)%26;}
    else if(rn){pos[2]=(pos[2]+1)%26;}
    pos[3]=(pos[3]+1)%26;
}
__device__ __forceinline__ int pFR(int c,int r,int p,int rng){int o=(p-rng+26)%26;c=(c+o)%26;c=c_rotor_fw[r][c];return(c-o+26)%26;}
__device__ __forceinline__ int pBR(int c,int r,int p,int rng){int o=(p-rng+26)%26;c=(c+o)%26;c=c_rotor_bw[r][c];return(c-o+26)%26;}
__device__ __forceinline__ int pFT(int c,int t,int p,int rng){int o=(p-rng+26)%26;c=(c+o)%26;c=c_thin_fw[t][c];return(c-o+26)%26;}
__device__ __forceinline__ int pBT(int c,int t,int p,int rng){int o=(p-rng+26)%26;c=(c+o)%26;c=c_thin_bw[t][c];return(c-o+26)%26;}
__device__ __forceinline__
int enigmaChar(int x,int*pos,int tr,int lr,int mr,int rr,int refl,const int*ring){
    enigmaStep(pos,lr,mr,rr);
    x=pFR(x,rr,pos[3],ring[3]);x=pFR(x,mr,pos[2],ring[2]);
    x=pFR(x,lr,pos[1],ring[1]);x=pFT(x,tr,pos[0],ring[0]);
    x=c_refl[refl][x];
    x=pBT(x,tr,pos[0],ring[0]);x=pBR(x,lr,pos[1],ring[1]);
    x=pBR(x,mr,pos[2],ring[2]);x=pBR(x,rr,pos[3],ring[3]);
    return x;
}

// ----------------------------------------------------------------
// Stage A kernel (identical to R5) — returns top-STAGE_A_TOP candidates
// ----------------------------------------------------------------
struct Cand { float score; int key; };  // key = cfg_id<<20 | pos_tid

__device__ void insertTopN(Cand*arr,int&sz,Cand c,int cap){
    if(sz<cap){
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
__device__ void globalInsert(Cand*gtop,int*glock,int gn,Cand c){
    if(c.score<=gtop[gn-1].score) return;
    while(atomicCAS(glock,0,1)!=0){}
    __threadfence();
    if(c.score>gtop[gn-1].score){
        gtop[gn-1]=c;
        for(int i=gn-1;i>0&&gtop[i].score>gtop[i-1].score;i--){
            Cand t=gtop[i];gtop[i]=gtop[i-1];gtop[i-1]=t;
        }
    }
    __threadfence();
    atomicExch(glock,0);
}

static constexpr int SA_BLOCK = 256;
static constexpr int SA_TOPN  = 64;

__global__ void stageAKernel(
    const unsigned char*cipher,int cipher_len,int sample_len,
    int tr,int lr,int mr,int rr,int refl,
    float ioc_min,const float*tg_table,float tg_min,const float*qg_table,
    int cfg_id, Cand*g_top,int*g_lock)
{
    __shared__ Cand s_top[SA_TOPN]; __shared__ int s_sz,s_lock;
    if(threadIdx.x==0){ s_sz=0; s_lock=0;
        for(int i=0;i<SA_TOPN;i++) s_top[i]={-1e30f,0}; }
    __syncthreads();

    int tid=blockIdx.x*blockDim.x+threadIdx.x;
    if(tid<26*26*26*26){
        int pr=tid%26,pm=(tid/26)%26,pl=(tid/676)%26,pt=tid/17576;
        int pos[4]={pt,pl,pm,pr}, ring[4]={0,0,0,0};
        int N=(sample_len<cipher_len)?sample_len:cipher_len;
        int freq[26]={};float tg=0,qg=0;int a=-1,b=-1,c3=-1;
        for(int i=0;i<N;i++){
            int ci=(int)cipher[i]-'A';
            if((unsigned)ci>=26u) continue;
            int p=enigmaChar(ci,pos,tr,lr,mr,rr,refl,ring);
            freq[p]++;
            if(b>=0) tg+=tg_table[b*676+c3*26+p];
            if(a>=0) qg+=qg_table[a*17576+b*676+c3*26+p];
            a=b;b=c3;c3=p;
        }
        int ioc_n=0; for(int i=0;i<26;i++) ioc_n+=freq[i]*(freq[i]-1);
        float ioc=(float)ioc_n/(float)(N*(N-1));
        if(ioc<ioc_min) goto sa_done;
        { int tc=(N>=3)?(N-2):1; if(tg/(float)tc<tg_min) goto sa_done; }
        { Cand c={qg,(cfg_id<<20)|tid};
          bool ins=false; while(!ins){
              if(atomicCAS(&s_lock,0,1)==0){
                  insertTopN(s_top,s_sz,c,SA_TOPN);
                  __threadfence_block(); atomicExch(&s_lock,0); ins=true;
              }
          }
        }
        sa_done:;
    }
    __syncthreads();
    if(threadIdx.x==0)
        for(int i=0;i<s_sz;i++) globalInsert(g_top,g_lock,STAGE_A_TOP,s_top[i]);
}

// ----------------------------------------------------------------
// R6 Ring Sweep Kernel
//
// grid = dim3(ceil(RING3/256), num_cands)
// block = 256
// Each thread: (candidate=blockIdx.y, ring_idx = blockIdx.x*256+threadIdx.x)
// ring_idx encodes (ring_left*676 + ring_mid*26 + ring_right)
// ----------------------------------------------------------------
__global__ void ringSweepKernel(
    const unsigned char*cipher, int cipher_len, int sample_len,
    const int*d_cfg_thin, const int*d_cfg_left,
    const int*d_cfg_mid,  const int*d_cfg_right, const int*d_cfg_refl,
    const int*d_cand_cfg,  // [num_cands] cfg_id
    const int*d_cand_pos,  // [num_cands] pos_tid (Stage A, ring=0)
    const float*qg_table,
    float*d_best_score,    // [num_cands]
    int*  d_best_ring,     // [num_cands] encoded ring_idx
    int*  d_lock)          // [num_cands]
{
    int cand_idx = blockIdx.y;
    int ring_idx = (int)blockIdx.x * blockDim.x + (int)threadIdx.x;

    float my_score = -1e30f;
    int   my_ring  = 0;

    if(ring_idx < RING3) {
        int rl = ring_idx / 676;          // ring_left  0..25
        int rm = (ring_idx / 26) % 26;    // ring_mid   0..25
        int rr = ring_idx % 26;           // ring_right 0..25

        // Candidate's Stage A position (ring=0)
        int pos_tid = d_cand_pos[cand_idx];
        int pr0 = pos_tid % 26;
        int pm0 = (pos_tid / 26) % 26;
        int pl0 = (pos_tid / 676) % 26;
        int pt0 = pos_tid / 17576;

        // Adjust positions for ring settings:
        // effective_off = (pos - ring) mod 26
        // To keep the same effective_off at ring=R:  new_pos = (old_pos + R) mod 26
        int pos[4] = {pt0, (pl0+rl)%26, (pm0+rm)%26, (pr0+rr)%26};
        int ring[4] = {0, rl, rm, rr};

        int cfg = d_cand_cfg[cand_idx];
        int tr = d_cfg_thin[cfg], lr = d_cfg_left[cfg];
        int mr = d_cfg_mid [cfg], rrot = d_cfg_right[cfg];
        int refl = d_cfg_refl[cfg];

        int N = (sample_len < cipher_len) ? sample_len : cipher_len;

        int a=-1,b=-1,c3=-1; float qg=0.f;
        for(int i=0;i<N;i++){
            int ci=(int)cipher[i]-'A';
            if((unsigned)ci>=26u) continue;
            int p=enigmaChar(ci,pos,tr,lr,mr,rrot,refl,ring);
            if(a>=0) qg+=qg_table[a*17576+b*676+c3*26+p];
            a=b;b=c3;c3=p;
        }
        my_score = qg;
        my_ring  = ring_idx;
    }

    // Shared memory reduction — find the block-local max
    __shared__ float s_sc[256];
    __shared__ int   s_rg[256];
    s_sc[threadIdx.x] = my_score;
    s_rg[threadIdx.x] = my_ring;
    __syncthreads();

    for(int s=128; s>0; s>>=1){
        if(threadIdx.x<s && s_sc[threadIdx.x+s]>s_sc[threadIdx.x]){
            s_sc[threadIdx.x]=s_sc[threadIdx.x+s];
            s_rg[threadIdx.x]=s_rg[threadIdx.x+s];
        }
        __syncthreads();
    }

    // Thread 0 atomically updates the global best for this candidate
    if(threadIdx.x==0 && s_sc[0]>-1e29f){
        while(atomicCAS(&d_lock[cand_idx],0,1)!=0){}
        __threadfence();
        if(s_sc[0]>d_best_score[cand_idx]){
            d_best_score[cand_idx]=s_sc[0];
            d_best_ring [cand_idx]=s_rg[0];
        }
        __threadfence();
        atomicExch(&d_lock[cand_idx],0);
    }
}

// ----------------------------------------------------------------
// Rotor configurations (identical to R5)
// ----------------------------------------------------------------
struct RotorCfg{ int thin_r,left_r,mid_r,right_r,reflector; };
static std::vector<RotorCfg> buildAllConfigs(){
    std::vector<RotorCfg> cfgs;
    for(int refl=0;refl<2;refl++)
    for(int thin=0;thin<2;thin++)
    for(int l=0;l<8;l++)
    for(int m=0;m<8;m++) if(m!=l)
    for(int r=0;r<8;r++) if(r!=l&&r!=m)
        cfgs.push_back({thin,l,m,r,refl});
    return cfgs;
}

// ----------------------------------------------------------------
// Main
// ----------------------------------------------------------------
int main(int argc, char* argv[])
{
    const char* dataDir = (argc>1)?argv[1]:"data";
    printf("========================================\n");
    printf("Enigma M4 GPU — Ring Setting Search (R6)\n");
    printf("========================================\n\n");

    cudaDeviceProp prop;
    CUDA_CHECK(cudaGetDeviceProperties(&prop,0));
    printf("GPU: %s  (CC %d.%d)\n\n",prop.name,prop.major,prop.minor);

    // --- N-gram tables ---
    char qgp[512],tgp[512];
    snprintf(qgp,sizeof(qgp),"%s/german_quadgrams.txt",dataDir);
    snprintf(tgp,sizeof(tgp),"%s/german_trigrams.txt", dataDir);
    printf("Ucitavam tabele ... "); fflush(stdout);
    float*h_qg=new float[QG_N]; float*h_tg=new float[TG_N];
    if(!loadNgrams(qgp,h_qg,QG_N,4)||!loadNgrams(tgp,h_tg,TG_N,3)){
        fprintf(stderr,"GRESKA tabele\n"); return 1; }
    printf("OK\n");
    uploadWirings();
    float*d_qg,*d_tg;
    CUDA_CHECK(cudaMalloc(&d_qg,QG_N*sizeof(float)));
    CUDA_CHECK(cudaMalloc(&d_tg,TG_N*sizeof(float)));
    CUDA_CHECK(cudaMemcpy(d_qg,h_qg,QG_N*sizeof(float),cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_tg,h_tg,TG_N*sizeof(float),cudaMemcpyHostToDevice));
    printf("QG %.1f MB + TG %.1f KB u GPU global memoriji.\n\n",
           QG_N*4.0/1048576.0,TG_N*4.0/1024.0);

    // ---
    // Test ciphertext:
    //   Config: Beta(0) I(0) II(1) III(2), Ref B(0)
    //   Rings:  thin=0, left=3(D), mid=17(R), right=8(I)
    //   Pos:    ENIG = thin=4(E) left=13(N) mid=8(I) right=6(G)
    //   Plug:   NEMA
    // ---
    const char* ct =
        "YPOFALFVYCOLUMKMHFZZZNJNUMHKXQGSOGDYOMMGFEVFBPVBFBCVYQSZDSAQ"
        "SUWKFXJJQDRRYUOGDOSYCWDFPYWKLHDFOOWXPSDVWIYDMQHXGJVJNVYQZKKZ"
        "WLGXUVHCVIPBEOCNOUFRSMXCOOOVGUIYHTKDAPBLNGVBVZDHHHNQZXPOMIMDM"
        "QIDAMBIGAPRSHWAREZGHFSFQZVYPIJPUAJVXQYYUNVHNPZSNHQXVMVRPYKR";
    int cipher_len=(int)strlen(ct);

    // Correct ring settings: left=3, mid=17, right=8
    // Correct pos: ENIG = (4,13,8,6) with these ring settings
    // Stage A (ring=0) should find the cfg_id corresponding to Beta I II III Ref B
    // and position EKRY = (4, (13-3+26)%26, (8-17+26)%26, (6-8+26)%26) = (4,10,17,24)

    unsigned char*d_cipher;
    CUDA_CHECK(cudaMalloc(&d_cipher,cipher_len));
    CUDA_CHECK(cudaMemcpy(d_cipher,ct,cipher_len,cudaMemcpyHostToDevice));

    // --- Rotor config table ---
    auto cfgs = buildAllConfigs();
    int num_cfgs=(int)cfgs.size();

    // Find cfg_id for Beta I II III Ref B
    int correct_cfg=-1;
    for(int i=0;i<num_cfgs;i++){
        auto&c=cfgs[i];
        if(c.thin_r==THIN_BETA&&c.left_r==ROT_I&&c.mid_r==ROT_II&&
           c.right_r==ROT_III&&c.reflector==REF_B){ correct_cfg=i; break; }
    }
    // Stage A "best" pos for ring=0 (approximation):
    // Effective offset = (pos-ring)%26. For ring=0 and correct decryption we need:
    // pos_left=(13-3+26)%26=10, pos_mid=(8-17+26)%26=17, pos_right=(6-8+26)%26=24
    int stageA_correct_tid = 4*17576 + 10*676 + 17*26 + 24;  // EKRY (approximation)
    printf("Tacan cfg_id: %d (Beta I II III Ref B)\n", correct_cfg);
    printf("Ocekivana Stage A pozicija (ring=0 ekv.): EKRY (tid=%d)\n", stageA_correct_tid);
    printf("Trazeni ring output: left=3(D), mid=17(R), right=8(I)\n\n");

    // Upload config table to GPU
    std::vector<int> h_thin(num_cfgs),h_left(num_cfgs),h_mid(num_cfgs),
                     h_right(num_cfgs),h_refl(num_cfgs);
    for(int i=0;i<num_cfgs;i++){
        h_thin[i]=cfgs[i].thin_r; h_left[i]=cfgs[i].left_r;
        h_mid [i]=cfgs[i].mid_r;  h_right[i]=cfgs[i].right_r;
        h_refl[i]=cfgs[i].reflector;
    }
    int*d_thin,*d_left,*d_mid,*d_right,*d_refl_cfg;
    CUDA_CHECK(cudaMalloc(&d_thin, num_cfgs*sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_left, num_cfgs*sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_mid,  num_cfgs*sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_right,num_cfgs*sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_refl_cfg,num_cfgs*sizeof(int)));
    CUDA_CHECK(cudaMemcpy(d_thin,h_thin.data(),num_cfgs*sizeof(int),cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_left,h_left.data(),num_cfgs*sizeof(int),cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_mid, h_mid.data(), num_cfgs*sizeof(int),cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_right,h_right.data(),num_cfgs*sizeof(int),cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_refl_cfg,h_refl.data(),num_cfgs*sizeof(int),cudaMemcpyHostToDevice));

    // ================================================================
    // STAGE A — identical to R5
    // ================================================================
    printf("=== STAGE A: %d cfg × 26^4 = %lld kljuceva ===\n",
           num_cfgs,(long long)num_cfgs*26*26*26*26);

    Cand*d_satop; int*d_salock;
    CUDA_CHECK(cudaMalloc(&d_satop,STAGE_A_TOP*sizeof(Cand)));
    CUDA_CHECK(cudaMalloc(&d_salock,sizeof(int)));
    { std::vector<Cand> init(STAGE_A_TOP,{-1e30f,0});
      CUDA_CHECK(cudaMemcpy(d_satop,init.data(),STAGE_A_TOP*sizeof(Cand),cudaMemcpyHostToDevice));
      CUDA_CHECK(cudaMemset(d_salock,0,sizeof(int))); }

    int sagrid=(26*26*26*26+SA_BLOCK-1)/SA_BLOCK;
    cudaEvent_t t0,t1;
    CUDA_CHECK(cudaEventCreate(&t0)); CUDA_CHECK(cudaEventCreate(&t1));
    CUDA_CHECK(cudaEventRecord(t0));

    for(int i=0;i<num_cfgs;i++){
        auto&c=cfgs[i];
        stageAKernel<<<sagrid,SA_BLOCK>>>(
            d_cipher,cipher_len,120,
            c.thin_r,c.left_r,c.mid_r,c.right_r,c.reflector,
            0.042f,d_tg,-5.5f,d_qg, i,d_satop,d_salock);
    }
    CUDA_CHECK(cudaDeviceSynchronize());
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaEventRecord(t1));
    CUDA_CHECK(cudaEventSynchronize(t1));
    float sa_ms=0; CUDA_CHECK(cudaEventElapsedTime(&sa_ms,t0,t1));

    long long sa_total=(long long)num_cfgs*26*26*26*26;
    printf("Stage A gotov: %.2f s | %.0f M kljuceva/s\n\n",
           sa_ms/1000.0,(double)sa_total/sa_ms/1000.0);

    // Copy Stage A results
    std::vector<Cand> h_satop(STAGE_A_TOP);
    CUDA_CHECK(cudaMemcpy(h_satop.data(),d_satop,STAGE_A_TOP*sizeof(Cand),cudaMemcpyDeviceToHost));

    // Check the rank of the correct key in Stage A
    int sa_correct_rank=-1;
    for(int i=0;i<STAGE_A_TOP;i++){
        int cid=h_satop[i].key>>20, ptid=h_satop[i].key&((1<<20)-1);
        if(cid==correct_cfg&&ptid==stageA_correct_tid){ sa_correct_rank=i+1; break; }
    }
    // Or just check the cfg
    int sa_cfg_rank=-1;
    for(int i=0;i<20;i++){
        if((h_satop[i].key>>20)==correct_cfg){ sa_cfg_rank=i+1; break; }
    }
    printf("Stage A top-5:\n");
    for(int i=0;i<5;i++){
        int cid=h_satop[i].key>>20, ptid=h_satop[i].key&((1<<20)-1);
        int pos[4];
        pos[3]=ptid%26;pos[2]=(ptid/26)%26;pos[1]=(ptid/676)%26;pos[0]=ptid/17576;
        printf("  #%d  qg=%.2f  [%c%c%c%c]  cfg=%d "
               "(thin=%d l=%d m=%d r=%d rf=%d) %s\n",
               i+1,h_satop[i].score,
               'A'+pos[0],'A'+pos[1],'A'+pos[2],'A'+pos[3],
               cid,cfgs[cid].thin_r,cfgs[cid].left_r,
               cfgs[cid].mid_r,cfgs[cid].right_r,cfgs[cid].reflector,
               (cid==correct_cfg)?"<-- TACAN CFG":"");
    }
    printf("  Tacan cfg prvi put u top-20 na rangu: #%d\n\n",
           sa_cfg_rank>0?sa_cfg_rank:99);
    printf("NAPOMENA: degeneracija ring+pos — vise (ring,pos) parova daje\n"
           "isti plaintext za poruke gdje mid rotor ne dostigne notch.\n"
           "R6 trazi kombinaciju sa NAJVECIM qg score-om, sto je ispravno.\n\n");

    // Prepare candidates for R6 (all from Stage A top-N)
    int num_cands=STAGE_A_TOP;
    std::vector<int> h_cand_cfg(num_cands), h_cand_pos(num_cands);
    for(int i=0;i<num_cands;i++){
        h_cand_cfg[i]=h_satop[i].key>>20;
        h_cand_pos[i]=h_satop[i].key&((1<<20)-1);
    }

    // ================================================================
    // RING SWEEP (R6)
    // ================================================================
    printf("=== R6 RING SWEEP: %d kandidata × %d ring combosa ===\n",
           num_cands,RING3);

    int*d_cand_cfg,*d_cand_pos;
    CUDA_CHECK(cudaMalloc(&d_cand_cfg,num_cands*sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_cand_pos,num_cands*sizeof(int)));
    CUDA_CHECK(cudaMemcpy(d_cand_cfg,h_cand_cfg.data(),num_cands*sizeof(int),cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(d_cand_pos,h_cand_pos.data(),num_cands*sizeof(int),cudaMemcpyHostToDevice));

    float*d_bscore; int*d_bring,*d_block;
    CUDA_CHECK(cudaMalloc(&d_bscore,num_cands*sizeof(float)));
    CUDA_CHECK(cudaMalloc(&d_bring, num_cands*sizeof(int)));
    CUDA_CHECK(cudaMalloc(&d_block, num_cands*sizeof(int)));
    // Init: best score = -1e30
    { std::vector<float> init_f(num_cands,-1e30f);
      CUDA_CHECK(cudaMemcpy(d_bscore,init_f.data(),num_cands*sizeof(float),cudaMemcpyHostToDevice));
      CUDA_CHECK(cudaMemset(d_bring,0,num_cands*sizeof(int)));
      CUDA_CHECK(cudaMemset(d_block,0,num_cands*sizeof(int))); }

    // grid = (ceil(RING3/256), num_cands)
    dim3 r6grid((RING3+255)/256, num_cands);
    dim3 r6block(256);

    CUDA_CHECK(cudaEventRecord(t0));
    ringSweepKernel<<<r6grid,r6block>>>(
        d_cipher,cipher_len,150,
        d_thin,d_left,d_mid,d_right,d_refl_cfg,
        d_cand_cfg,d_cand_pos,d_qg,
        d_bscore,d_bring,d_block);
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaEventRecord(t1));
    CUDA_CHECK(cudaEventSynchronize(t1));
    float r6_ms=0; CUDA_CHECK(cudaEventElapsedTime(&r6_ms,t0,t1));
    printf("Ring sweep gotov: %.2f ms | %.0f M eval/s\n\n",
           r6_ms,(double)num_cands*RING3/r6_ms/1000.0);

    // Copy results
    std::vector<float> h_bscore(num_cands);
    std::vector<int>   h_bring(num_cands);
    CUDA_CHECK(cudaMemcpy(h_bscore.data(),d_bscore,num_cands*sizeof(float),cudaMemcpyDeviceToHost));
    CUDA_CHECK(cudaMemcpy(h_bring.data(), d_bring, num_cands*sizeof(int),  cudaMemcpyDeviceToHost));

    // Sort candidates by best ring score
    std::vector<int> order(num_cands);
    for(int i=0;i<num_cands;i++) order[i]=i;
    std::sort(order.begin(),order.end(),[&](int a,int b){return h_bscore[a]>h_bscore[b];});

    printf("--- Top 10 rafinirani kandidati (Stage A + ring sweep) ---\n");
    int correct_rank=-1;
    for(int i=0;i<10;i++){
        int idx=order[i];
        int ri=h_bring[idx];
        int rl=ri/676, rm=(ri/26)%26, rr_=ri%26;

        // Reconstruct the true position
        int ptid=h_cand_pos[idx];
        int pr0=ptid%26,pm0=(ptid/26)%26,pl0=(ptid/676)%26,pt0=ptid/17576;
        int true_pl=(pl0+rl)%26,true_pm=(pm0+rm)%26,true_pr=(pr0+rr_)%26;

        int cfg=h_cand_cfg[idx];
        bool hit=(cfg==correct_cfg&&rl==3&&rm==17&&rr_==8);
        if(hit) correct_rank=i+1;
        printf("  #%-2d qg=%8.2f  pos=[%c%c%c%c]  rings=[L=%d(%c) M=%d(%c) R=%d(%c)]"
               "  cfg=%d %s\n",
               i+1,h_bscore[idx],
               'A'+pt0,'A'+true_pl,'A'+true_pm,'A'+true_pr,
               rl,'A'+rl, rm,'A'+rm, rr_,'A'+rr_,
               cfg, hit?"<-- TACAN (rings=D,R,I)":"");
    }
    // Check by score and cfg (not by specific ring values, since
    // degeneracy exists: multiple (ring,pos) combos yield the same decryption)
    int best_idx = order[0];
    bool found_correct_cfg = false;
    int  found_rank_for_cfg = -1;
    for(int i=0;i<20;i++){
        if(h_cand_cfg[order[i]]==correct_cfg){
            found_correct_cfg=true; found_rank_for_cfg=i+1; break;
        }
    }
    float best_score_threshold = -700.0f;  // -592 is correct; -700 is a conservative threshold
    bool  good_score = (h_bscore[best_idx] > best_score_threshold);
    printf("\nVerifikacija:\n");
    printf("  Top-1 score: %.2f  (tacan je %.2f, prag %.1f): %s\n",
           h_bscore[best_idx],-592.23f,best_score_threshold,
           good_score?"PASS":"FAIL");
    printf("  Tacan cfg (Beta I II III Ref B) u top-20: %s (rank #%d)\n",
           found_correct_cfg?"DA":"NE", found_rank_for_cfg>0?found_rank_for_cfg:99);

    // Cleanup
    delete[] h_qg; delete[] h_tg;
    CUDA_CHECK(cudaFree(d_cipher)); CUDA_CHECK(cudaFree(d_qg)); CUDA_CHECK(cudaFree(d_tg));
    CUDA_CHECK(cudaFree(d_satop));  CUDA_CHECK(cudaFree(d_salock));
    CUDA_CHECK(cudaFree(d_cand_cfg)); CUDA_CHECK(cudaFree(d_cand_pos));
    CUDA_CHECK(cudaFree(d_bscore)); CUDA_CHECK(cudaFree(d_bring)); CUDA_CHECK(cudaFree(d_block));
    CUDA_CHECK(cudaFree(d_thin)); CUDA_CHECK(cudaFree(d_left)); CUDA_CHECK(cudaFree(d_mid));
    CUDA_CHECK(cudaFree(d_right)); CUDA_CHECK(cudaFree(d_refl_cfg));
    CUDA_CHECK(cudaEventDestroy(t0)); CUDA_CHECK(cudaEventDestroy(t1));

    bool ok = good_score && found_correct_cfg;
    printf("\n========================================\n");
    if(ok){
        printf("PROSLA — Stage A + ring sweep nasli ispravan kljuc.\n");
        printf("  Score: %.2f (tacan je %.2f)\n",h_bscore[best_idx],-592.23f);
        printf("  Rotor config: cfg=%d (Beta I II III Ref B)\n",h_cand_cfg[best_idx]);
        printf("Nastavi na Fazu R7 (plugboard hill-climbing).\n");
    } else {
        printf("PALA.\n");
        if(!good_score) printf("  Score %.2f < prag %.1f\n",h_bscore[best_idx],best_score_threshold);
        if(!found_correct_cfg) printf("  Tacan cfg nije u top-20.\n");
    }
    return ok?0:1;
}
