// ENIGMA M4 BREAKER - Gillogly+TriHC v3
//
// Stage A: trigram streaming HC (not a bigram matrix).
// Trigram gives much better separation: the German trigram distribution is
// skewed (~DER,EIN,UND dominate), whereas bigrams are more uniform.
// Key: d_tri[17576] lives in L2-cached global memory (70KB < 30MB L2).
//
// Fixes vs v2:
//  - bigHC_matrix -> triHC_direct (plug tracking + streaming trigram delta)
//  - d_tri as __device__ global (not constant, since 70KB > 64KB limit)
//  - N_HC = full ciphertext (all characters) to maximize signal
//  - N_PASS = 3 passes (on the correct rotors this converges to ~5-8 pairs)
//
#include <cstdio>
#include <cstring>
#include <cmath>
#include <vector>
#include <algorithm>
#include <string>
#include <fstream>
#include <chrono>
#include <cuda_runtime.h>
#include "config.h"
#include "core/enigma_cpu/enigma_cpu.h"
#include "filters/quadgram/quadgram_score.h"
#include "search/plugboard_search/plugboard_hc.h"

// ================================================================
// GPU constant + device memory
// ================================================================
__constant__ int   c_rotor_fw[8][26];
__constant__ int   c_rotor_bw[8][26];
__constant__ int   c_thin_fw[2][26];
__constant__ int   c_thin_bw[2][26];
__constant__ int   c_refl[2][26];
__constant__ int   c_notch[8][26];

// Trigram log-prob table - in L2-cached global memory (70KB)
__device__ float d_tri[17576];   // 26^3 = 17576

#define CUDA_CHECK(x) do{cudaError_t e_=(x);if(e_!=cudaSuccess){         \
    fprintf(stderr,"CUDA %s:%d %s\n",__FILE__,__LINE__,                   \
    cudaGetErrorString(e_));exit(1);}}while(0)

// ================================================================
// Wiring upload
// ================================================================
static void uploadWirings(){
    int fw[8][26],bw[8][26],nt[8][26];
    for(int r=0;r<8;r++){
        for(int i=0;i<26;i++) fw[r][i]=ROTOR_WIRING[r][i]-'A';
        for(int i=0;i<26;i++) bw[r][fw[r][i]]=i;
        for(int i=0;i<26;i++) nt[r][i]=0;
        for(const char*n=ROTOR_NOTCH[r];*n;n++) nt[r][*n-'A']=1;
    }
    CUDA_CHECK(cudaMemcpyToSymbol(c_rotor_fw,fw,sizeof(fw)));
    CUDA_CHECK(cudaMemcpyToSymbol(c_rotor_bw,bw,sizeof(bw)));
    CUDA_CHECK(cudaMemcpyToSymbol(c_notch,nt,sizeof(nt)));
    int tfw[2][26],tbw[2][26];
    for(int t=0;t<2;t++){
        for(int i=0;i<26;i++) tfw[t][i]=THIN_ROTOR_WIRING[t][i]-'A';
        for(int i=0;i<26;i++) tbw[t][tfw[t][i]]=i;
    }
    CUDA_CHECK(cudaMemcpyToSymbol(c_thin_fw,tfw,sizeof(tfw)));
    CUDA_CHECK(cudaMemcpyToSymbol(c_thin_bw,tbw,sizeof(tbw)));
    int rfl[2][26];
    for(int r=0;r<2;r++) for(int i=0;i<26;i++) rfl[r][i]=REFLECTOR_WIRING[r][i]-'A';
    CUDA_CHECK(cudaMemcpyToSymbol(c_refl,rfl,sizeof(rfl)));
}

// ================================================================
// Trigram table from file (same format: "ABC 12345")
// ================================================================
static bool loadTrigrams(const char* path, float out[17576]){
    double cnt[17576]={};
    FILE* f=fopen(path,"r");
    if(!f) return false;
    char tri[8]; long long freq;
    while(fscanf(f,"%7s %lld",tri,&freq)==2){
        if((int)strlen(tri)!=3) continue;
        int a=tri[0]-'A',b=tri[1]-'A',c=tri[2]-'A';
        if((unsigned)a<26u&&(unsigned)b<26u&&(unsigned)c<26u)
            cnt[a*676+b*26+c]+=(double)freq;
    }
    fclose(f);
    double tot=0; for(int i=0;i<17576;i++) tot+=cnt[i];
    double floor_v=log10(0.01/tot);
    for(int i=0;i<17576;i++)
        out[i]=(float)(cnt[i]>0 ? log10(cnt[i]/tot) : floor_v);
    return true;
}

// ================================================================
// GPU Enigma helpers
// ================================================================
__device__ __forceinline__ void gStep(int*p,int lr,int mr,int rr){
    bool rn=(bool)c_notch[rr][p[3]],mn=(bool)c_notch[mr][p[2]];
    if(mn){p[1]=(p[1]+1)%26;p[2]=(p[2]+1)%26;}else if(rn){p[2]=(p[2]+1)%26;}
    p[3]=(p[3]+1)%26;
}
__device__ __forceinline__ int gFR(int c,int r,int p,int rg){
    int o=(p-rg+26)%26;c=(c+o)%26;c=c_rotor_fw[r][c];return(c-o+26)%26;}
__device__ __forceinline__ int gBR(int c,int r,int p,int rg){
    int o=(p-rg+26)%26;c=(c+o)%26;c=c_rotor_bw[r][c];return(c-o+26)%26;}
__device__ __forceinline__ int gFT(int c,int t,int p,int rg){
    int o=(p-rg+26)%26;c=(c+o)%26;c=c_thin_fw[t][c];return(c-o+26)%26;}
__device__ __forceinline__ int gBT(int c,int t,int p,int rg){
    int o=(p-rg+26)%26;c=(c+o)%26;c=c_thin_bw[t][c];return(c-o+26)%26;}

__device__ __forceinline__
int gEnc(int x,int*p,int tr,int lr,int mr,int rr,int rf,const int*ring){
    gStep(p,lr,mr,rr);
    x=gFR(x,rr,p[3],ring[3]);x=gFR(x,mr,p[2],ring[2]);
    x=gFR(x,lr,p[1],ring[1]);x=gFT(x,tr,p[0],ring[0]);
    x=c_refl[rf][x];
    x=gBT(x,tr,p[0],ring[0]);x=gBR(x,lr,p[1],ring[1]);
    x=gBR(x,mr,p[2],ring[2]);x=gBR(x,rr,p[3],ring[3]);
    return x;
}

// ================================================================
// triHC_direct: decrypt all characters, run a 3-pass trigram HC
// while tracking the plug[] state.
//
// Key difference from bigHC_matrix:
//   - Trigram distribution is much more skewed than bigram -> higher SNR
//   - plug[] tracking (not a matrix) -> O(N) per swap (N~clen)
//   - On the correct rotors, HC converges to the correct plug pairs
//   - On incorrect rotors it stays close to noise
// ================================================================
static constexpr int N_HC_MAX = 250;  // max ciphertext length for the local buffer
static constexpr int N_PASS   = 3;

__device__ float triHC_direct(
    const unsigned char* cipher, int clen,
    int tr, int lr, int mr, int rr, int rf,
    const int* ring, const int* pos_in)
{
    int pos[4]={pos_in[0],pos_in[1],pos_in[2],pos_in[3]};
    int N=(clen<N_HC_MAX)?clen:N_HC_MAX;

    // Decrypt all characters (without the plugboard)
    unsigned char out[N_HC_MAX];
    for(int i=0;i<N;i++){
        int ci=(int)cipher[i]-'A';
        out[i]=(unsigned char)((unsigned)ci<26u ? gEnc(ci,pos,tr,lr,mr,rr,rf,ring) : 255);
    }

    // Track plug state - starts from the identity
    unsigned char plug[26];
    for(int i=0;i<26;i++) plug[i]=(unsigned char)i;

    // Base trigram score (plug = identity)
    float score=0.f;
    for(int i=0;i<N-2;i++){
        int a=out[i],b=out[i+1],c=out[i+2];
        if(a<26&&b<26&&c<26) score+=d_tri[a*676+b*26+c];
    }

    // N_PASS passes of greedy single-swap HC
    for(int pass=0;pass<N_PASS;pass++){
        float best_d=-1e30f; int ba=0,bb=1;
        for(int a=0;a<26;a++){
            for(int b=a+1;b<26;b++){
                float d=0.f;
                for(int i=0;i<N-2;i++){
                    int p0=plug[out[i]],p1=plug[out[i+1]],p2=plug[out[i+2]];
                    if(p0>=26||p1>=26||p2>=26) continue;
                    // Apply the virtual swap (a,b) to p0,p1,p2
                    int n0=(p0==a)?b:(p0==b)?a:p0;
                    int n1=(p1==a)?b:(p1==b)?a:p1;
                    int n2=(p2==a)?b:(p2==b)?a:p2;
                    if(n0!=p0||n1!=p1||n2!=p2)
                        d+=d_tri[n0*676+n1*26+n2]-d_tri[p0*676+p1*26+p2];
                }
                if(d>best_d){best_d=d;ba=a;bb=b;}
            }
        }
        if(best_d<=0.f) break;
        score+=best_d;
        // Apply the swap ba<->bb to plug[]
        for(int i=0;i<26;i++){
            if(plug[i]==(unsigned char)ba) plug[i]=(unsigned char)bb;
            else if(plug[i]==(unsigned char)bb) plug[i]=(unsigned char)ba;
        }
    }
    return score;
}

// ================================================================
// Stage A kernel: SA_BLK=32 (smaller block so out[] fits in L1)
// Block-max reduction, no spinlock.
// ================================================================
static constexpr int SA_BLK = 32;

__global__ void stageAKernel(
    const unsigned char* cipher, int clen,
    int tr, int lr, int mr, int rr, int rf,
    float* block_sc, int* block_pos)
{
    int tid=(int)blockIdx.x*SA_BLK+(int)threadIdx.x;

    float my_sc=-1e30f;
    int   my_pos=tid;
    if(tid<26*26*26*26){
        int ring[4]={0,0,0,0};
        int pos[4]={tid/17576,(tid/676)%26,(tid/26)%26,tid%26};
        my_sc=triHC_direct(cipher,clen,tr,lr,mr,rr,rf,ring,pos);
    }

    __shared__ float ssc[SA_BLK];
    __shared__ int   sps[SA_BLK];
    ssc[threadIdx.x]=my_sc;
    sps[threadIdx.x]=my_pos;
    __syncthreads();
    for(int s=SA_BLK/2;s>0;s>>=1){
        if(threadIdx.x<s&&ssc[threadIdx.x+s]>ssc[threadIdx.x]){
            ssc[threadIdx.x]=ssc[threadIdx.x+s];
            sps[threadIdx.x]=sps[threadIdx.x+s];
        }
        __syncthreads();
    }
    if(threadIdx.x==0){
        block_sc[blockIdx.x]=ssc[0];
        block_pos[blockIdx.x]=sps[0];
    }
}

// ================================================================
// Ring sweep kernel: RS_BLK=128
// ================================================================
static constexpr int RING3  = 17576;  // 26^3
static constexpr int RS_BLK = 128;

__global__ void ringSweepKernel(
    const unsigned char* cipher, int clen,
    const int* cfg_tr,const int* cfg_lr,const int* cfg_mr,
    const int* cfg_rr,const int* cfg_rf,
    const int* cand_cfg,const int* cand_pos,
    float* best_sc,int* best_ring,int* lock,
    int num_cands)
{
    int ci=(int)blockIdx.y;
    if(ci>=num_cands) return;
    int ri=(int)blockIdx.x*RS_BLK+(int)threadIdx.x;

    __shared__ float ssc[RS_BLK];
    __shared__ int   srs[RS_BLK];
    ssc[threadIdx.x]=-1e30f;
    srs[threadIdx.x]=ri;
    __syncthreads();

    if(ri<RING3){
        int rl=ri/676,rm=(ri/26)%26,rr_r=ri%26;
        int ptid=cand_pos[ci];
        int pr=ptid%26,pm_=(ptid/26)%26,pl_=(ptid/676)%26,pt=ptid/17576;
        int pos[4]={pt,(pl_+rl)%26,(pm_+rm)%26,(pr+rr_r)%26};
        int ring[4]={0,rl,rm,rr_r};
        int cfg=cand_cfg[ci];
        float sc=triHC_direct(cipher,clen,
            cfg_tr[cfg],cfg_lr[cfg],cfg_mr[cfg],cfg_rr[cfg],cfg_rf[cfg],
            ring,pos);
        ssc[threadIdx.x]=sc;
    }
    __syncthreads();

    for(int s=RS_BLK/2;s>0;s>>=1){
        if(threadIdx.x<s&&ssc[threadIdx.x+s]>ssc[threadIdx.x]){
            ssc[threadIdx.x]=ssc[threadIdx.x+s];
            srs[threadIdx.x]=srs[threadIdx.x+s];
        }
        __syncthreads();
    }
    if(threadIdx.x==0&&ssc[0]>-1e29f){
        while(atomicCAS(&lock[ci],0,1)!=0){}
        __threadfence();
        if(ssc[0]>best_sc[ci]){best_sc[ci]=ssc[0];best_ring[ci]=srs[0];}
        __threadfence();
        atomicExch(&lock[ci],0);
    }
}

// ================================================================
// Rotor configurations
// ================================================================
struct RotorCfg{int thin_r,left_r,mid_r,right_r,reflector;};
static std::vector<RotorCfg> buildConfigs(){
    std::vector<RotorCfg> v;
    for(int rf=0;rf<2;rf++) for(int th=0;th<2;th++)
    for(int l=0;l<8;l++) for(int m=0;m<8;m++) if(m!=l)
    for(int r=0;r<8;r++) if(r!=l&&r!=m)
        v.push_back({th,l,m,r,rf});
    return v;
}

static bool sanityCipher(const std::string& pl,const char* ct,int n){
    for(int i=0;i<(int)pl.size()&&i<n;i++) if(pl[i]==ct[i]) return false;
    return true;
}

struct FinalKey{float score;int cfg;int pos[4];int rings[4];int plug[26];};

static void printKey(const FinalKey& k,const std::vector<RotorCfg>& cfgs){
    static const char* RN[]={"I","II","III","IV","V","VI","VII","VIII"};
    static const char* TN[]={"Beta","Gamma"};
    static const char* RF[]={"B-thin","C-thin"};
    auto& c=cfgs[k.cfg];
    printf("  Reflector  : %s\n",RF[c.reflector]);
    printf("  Wheel order: %s %s %s %s\n",TN[c.thin_r],RN[c.left_r],RN[c.mid_r],RN[c.right_r]);
    printf("  Ring (1-based): %02d %02d %02d %02d\n",
           k.rings[0]+1,k.rings[1]+1,k.rings[2]+1,k.rings[3]+1);
    printf("  Msg key    : %c%c%c%c\n",
           'A'+k.pos[0],'A'+k.pos[1],'A'+k.pos[2],'A'+k.pos[3]);
    printf("  Plugboard  : %s\n",plugToStr(k.plug).c_str());
}

// ================================================================
// Main
// ================================================================
int main(int argc, char* argv[])
{
    const char* dataDir=(argc>1)?argv[1]:"data";
    const char* ctFile =(argc>2)?argv[2]:nullptr;

    printf("=============================================================\n");
    printf("     ENIGMA M4 BREAKER  (Gillogly+TriHC v3)\n");
    printf("=============================================================\n\n");

    cudaDeviceProp prop;
    CUDA_CHECK(cudaGetDeviceProperties(&prop,0));
    printf("GPU : %s  (CC %d.%d)\n\n",prop.name,prop.major,prop.minor);

    // Trigram table
    char tgp[512]; snprintf(tgp,sizeof(tgp),"%s/german_trigrams.txt",dataDir);
    printf("Loading trigram table... "); fflush(stdout);
    static float h_tri[17576];
    if(!loadTrigrams(tgp,h_tri)){fprintf(stderr,"ERROR: %s\n",tgp);return 1;}
    CUDA_CHECK(cudaMemcpyToSymbol(d_tri,h_tri,sizeof(h_tri)));
    printf("OK\n");

    // Quadgram (for CPU HC)
    char qgp[512]; snprintf(qgp,sizeof(qgp),"%s/german_quadgrams.txt",dataDir);
    printf("Loading quadgram table... "); fflush(stdout);
    static QuadgramScorer qg_host;
    if(!qg_host.load(qgp)){fprintf(stderr,"ERROR: %s\n",qgp);return 1;}
    printf("OK\n\n");
    uploadWirings();

    // Ciphertext
    std::string ct_str;
    if(ctFile){
        std::ifstream f(ctFile);
        if(!f){fprintf(stderr,"ERROR: %s\n",ctFile);return 1;}
        std::string ln;
        while(std::getline(f,ln)) for(char c:ln) if(c>='A'&&c<='Z') ct_str+=c;
    } else {
        // Built-in U-264
        ct_str="NCZWVUSXPNYMINHZXMQXSFWXWLKJAHSHNMCOCCAKUQPMKCSMHKSEINJUSBLK"
               "IOSXCKUBHMLLXCSJUSRRDVKOHULXWCCBGVLIYXEOAHXRHKKFVDREWEZLXOBAF"
               "GYUJQUKGRTVUKAMEURBVEKSUHHVOYHABCJWMAKLFKLMYFVNRIZRVVRTKOFDANJ"
               "MOLBGFFLEOPRGTFLVRHOWOPBEKVWMUQFMPWPARMFHAGKXIIBG";
        printf("Using built-in U-264.\n\n");
    }
    int clen=(int)ct_str.size();
    printf("Ciphertext: %.40s... (%d letters)\n\n",ct_str.c_str(),clen);

    unsigned char* d_cipher;
    CUDA_CHECK(cudaMalloc(&d_cipher,clen));
    CUDA_CHECK(cudaMemcpy(d_cipher,ct_str.c_str(),clen,cudaMemcpyHostToDevice));

    auto cfgs=buildConfigs(); int ncfg=(int)cfgs.size();
    std::vector<int> h_tr(ncfg),h_lr(ncfg),h_mr(ncfg),h_rr(ncfg),h_rf(ncfg);
    for(int i=0;i<ncfg;i++){
        h_tr[i]=cfgs[i].thin_r; h_lr[i]=cfgs[i].left_r;
        h_mr[i]=cfgs[i].mid_r;  h_rr[i]=cfgs[i].right_r; h_rf[i]=cfgs[i].reflector;
    }
    int *d_tr,*d_lr,*d_mr,*d_rr_,*d_rf_;
    CUDA_CHECK(cudaMalloc(&d_tr ,ncfg*4));CUDA_CHECK(cudaMemcpy(d_tr ,h_tr.data(),ncfg*4,cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMalloc(&d_lr ,ncfg*4));CUDA_CHECK(cudaMemcpy(d_lr ,h_lr.data(),ncfg*4,cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMalloc(&d_mr ,ncfg*4));CUDA_CHECK(cudaMemcpy(d_mr ,h_mr.data(),ncfg*4,cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMalloc(&d_rr_,ncfg*4));CUDA_CHECK(cudaMemcpy(d_rr_,h_rr.data(),ncfg*4,cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMalloc(&d_rf_,ncfg*4));CUDA_CHECK(cudaMemcpy(d_rf_,h_rf.data(),ncfg*4,cudaMemcpyHostToDevice));

    // ============================================================
    // STAGE A
    // ============================================================
    static constexpr int SA4   = 26*26*26*26;  // 456976
    static constexpr int K_PER = 10;
    int nblocks=(SA4+SA_BLK-1)/SA_BLK;
    int total_cands=ncfg*K_PER;

    float* d_bsc; int* d_bpos;
    CUDA_CHECK(cudaMalloc(&d_bsc, nblocks*sizeof(float)));
    CUDA_CHECK(cudaMalloc(&d_bpos,nblocks*sizeof(int)));

    std::vector<float> h_bsc(nblocks);
    std::vector<int>   h_bpos(nblocks);
    std::vector<int>   h_cc(total_cands),h_cp(total_cands);
    std::vector<float> h_cs(total_cands,-1e30f);

    printf("[Stage A]  %d configs x %d pos  (trigram HC N=%d, %d pass)\n",
           ncfg,SA4,clen<N_HC_MAX?clen:N_HC_MAX,N_PASS);

    auto t0=std::chrono::high_resolution_clock::now();

    for(int i=0;i<ncfg;i++){
        auto& c=cfgs[i];
        stageAKernel<<<nblocks,SA_BLK>>>(d_cipher,clen,
            c.thin_r,c.left_r,c.mid_r,c.right_r,c.reflector,
            d_bsc,d_bpos);
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaDeviceSynchronize());

        CUDA_CHECK(cudaMemcpy(h_bsc.data(), d_bsc, nblocks*sizeof(float),cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaMemcpy(h_bpos.data(),d_bpos,nblocks*sizeof(int),  cudaMemcpyDeviceToHost));

        // CPU: top-K_PER block maxima
        std::vector<int> bidx(nblocks);
        for(int b=0;b<nblocks;b++) bidx[b]=b;
        std::partial_sort(bidx.begin(),bidx.begin()+K_PER,bidx.end(),
            [&](int a_,int b_){return h_bsc[a_]>h_bsc[b_];});
        for(int k=0;k<K_PER;k++){
            int off=i*K_PER+k;
            h_cc[off]=i; h_cs[off]=h_bsc[bidx[k]]; h_cp[off]=h_bpos[bidx[k]];
        }

        if((i+1)%100==0||i==ncfg-1){
            auto t1=std::chrono::high_resolution_clock::now();
            double s=std::chrono::duration<double>(t1-t0).count();
            long long done=(long long)(i+1)*SA4;
            printf("  cfg %4d/%d  %.1fs  %.0f M/s\n",i+1,ncfg,s,done/s/1e6);
            fflush(stdout);
        }
    }
    CUDA_CHECK(cudaDeviceSynchronize());
    auto t1=std::chrono::high_resolution_clock::now();
    double sa_s=std::chrono::duration<double>(t1-t0).count();
    printf("  Done: %.2f s\n\n",sa_s);

    // Diagnostics for cfg=54 (B-thin Beta II IV I)
    {
        float best54=-1e30f; int pos54=-1;
        for(int k=0;k<K_PER;k++){
            int off=54*K_PER+k;
            if(h_cs[off]>best54){best54=h_cs[off];pos54=h_cp[off];}
        }
        if(pos54>=0){
            int p3=pos54%26,p2=(pos54/26)%26,p1=(pos54/676)%26,p0=pos54/17576;
            printf("[Stage A] cfg=54 top-1: triHC=%.4f pos=%c%c%c%c  (U-264: VJNF)\n\n",
                   best54,'A'+p0,'A'+p1,'A'+p2,'A'+p3);
        }
    }

    // ============================================================
    // RING SWEEP
    // ============================================================
    int* d_cc2; int* d_cp2;
    CUDA_CHECK(cudaMalloc(&d_cc2,total_cands*4));
    CUDA_CHECK(cudaMemcpy(d_cc2,h_cc.data(),total_cands*4,cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMalloc(&d_cp2,total_cands*4));
    CUDA_CHECK(cudaMemcpy(d_cp2,h_cp.data(),total_cands*4,cudaMemcpyHostToDevice));

    float* d_best_sc; int* d_best_ring; int* d_lock;
    CUDA_CHECK(cudaMalloc(&d_best_sc,  total_cands*4));
    CUDA_CHECK(cudaMalloc(&d_best_ring,total_cands*4));
    CUDA_CHECK(cudaMalloc(&d_lock,     total_cands*4));
    {
        std::vector<float> ini(total_cands,-1e30f);
        CUDA_CHECK(cudaMemcpy(d_best_sc,ini.data(),total_cands*4,cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemset(d_best_ring,0,total_cands*4));
        CUDA_CHECK(cudaMemset(d_lock,0,total_cands*4));
    }

    printf("[Ring sweep]  %d cand x %d ring combos\n",total_cands,RING3);
    int rsgrid=(RING3+RS_BLK-1)/RS_BLK;
    dim3 rg2(rsgrid,total_cands);
    t0=std::chrono::high_resolution_clock::now();
    ringSweepKernel<<<rg2,RS_BLK>>>(d_cipher,clen,
        d_tr,d_lr,d_mr,d_rr_,d_rf_,
        d_cc2,d_cp2,d_best_sc,d_best_ring,d_lock,total_cands);
    CUDA_CHECK(cudaDeviceSynchronize());
    t1=std::chrono::high_resolution_clock::now();
    double rs_s=std::chrono::duration<double>(t1-t0).count();
    printf("  Done: %.2f s\n\n",rs_s);

    std::vector<float> h_best_sc(total_cands);
    std::vector<int>   h_best_ring(total_cands);
    CUDA_CHECK(cudaMemcpy(h_best_sc.data(),  d_best_sc,  total_cands*4,cudaMemcpyDeviceToHost));
    CUDA_CHECK(cudaMemcpy(h_best_ring.data(),d_best_ring,total_cands*4,cudaMemcpyDeviceToHost));

    std::vector<int> order(total_cands);
    for(int i=0;i<total_cands;i++) order[i]=i;
    std::sort(order.begin(),order.end(),
        [&](int a,int b){return h_best_sc[a]>h_best_sc[b];});

    {
        static const char* RN[]={"I","II","III","IV","V","VI","VII","VIII"};
        static const char* TN[]={"Beta","Gamma"};
        static const char* RF[]={"B-thin","C-thin"};
        printf("[Ring sweep] Top-3:\n");
        for(int j=0;j<3&&j<total_cands;j++){
            int idx=order[j],cfg=h_cc[idx];
            int ri=h_best_ring[idx];
            int rl=ri/676,rm=(ri/26)%26,rr_r=ri%26;
            auto& rc=cfgs[cfg];
            printf("  #%d triHC=%.4f %s %s %s %s %s  ring(%02d/%02d/%02d)\n",
                j+1,h_best_sc[idx],RF[rc.reflector],TN[rc.thin_r],
                RN[rc.left_r],RN[rc.mid_r],RN[rc.right_r],rl+1,rm+1,rr_r+1);
        }
        for(int j=0;j<total_cands;j++){
            if(h_cc[order[j]]==54){
                int ri=h_best_ring[order[j]];
                int rl=ri/676,rm=(ri/26)%26,rr_r=ri%26;
                printf("  cfg=54 na rangu #%d: ring(%02d/%02d/%02d) triHC=%.4f"
                       "  (U-264: 01/01/22)\n",
                    j+1,rl+1,rm+1,rr_r+1,h_best_sc[order[j]]);
                break;
            }
        }
        printf("\n");
    }

    // ============================================================
    // CPU QUADGRAM HC
    // ============================================================
    static constexpr int HC_CANDS=50;
    int hc_count=std::min(HC_CANDS,(int)order.size());
    printf("[CPU HC]  top %d x 30 restarts\n",hc_count);

    std::vector<FinalKey> finals;
    t0=std::chrono::high_resolution_clock::now();

    for(int ii=0;ii<hc_count;ii++){
        int idx=order[ii];
        int ri=h_best_ring[idx];
        int rl=ri/676,rm=(ri/26)%26,rr_=(ri%26);
        int ptid=h_cp[idx];
        int pr=ptid%26,pm_=(ptid/26)%26,pl_=(ptid/676)%26,pt=ptid/17576;
        int cfg=h_cc[idx];
        auto& rc=cfgs[cfg];

        EnigmaKey base;
        base.rotor[0]=rc.thin_r; base.rotor[1]=rc.left_r;
        base.rotor[2]=rc.mid_r;  base.rotor[3]=rc.right_r;
        base.reflector=rc.reflector;
        base.ring[0]=0;   base.ring[1]=rl;
        base.ring[2]=rm;  base.ring[3]=rr_;
        base.position[0]=pt;
        base.position[1]=(pl_+rl)%26;
        base.position[2]=(pm_+rm)%26;
        base.position[3]=(pr+rr_)%26;
        initPlug(base.plugboard);

        PlugResult pr2=hillClimb(base,ct_str.c_str(),clen,qg_host,10,30);

        FinalKey fk;
        fk.score=pr2.score; fk.cfg=cfg;
        fk.rings[0]=0; fk.rings[1]=rl; fk.rings[2]=rm; fk.rings[3]=rr_;
        fk.pos[0]=pt; fk.pos[1]=(pl_+rl)%26;
        fk.pos[2]=(pm_+rm)%26; fk.pos[3]=(pr+rr_)%26;
        copyPlug(pr2.plug,fk.plug);
        finals.push_back(fk);
        printf("  cand %2d/%d  qg=%.2f\n",ii+1,hc_count,pr2.score);
        fflush(stdout);
    }
    std::sort(finals.begin(),finals.end(),
        [](const FinalKey& a,const FinalKey& b){return a.score>b.score;});
    t1=std::chrono::high_resolution_clock::now();
    double hc_s=std::chrono::duration<double>(t1-t0).count();
    printf("  Done: %.2f s\n\n",hc_s);

    // ============================================================
    // RESULTS
    // ============================================================
    printf("=============================================================\n");
    printf("RESULTS\n");
    printf("=============================================================\n\n");

    int show=std::min((int)finals.size(),3);
    for(int i=0;i<show;i++){
        auto& fk=finals[i];
        printf("--- #%d  (qg=%.2f) ---\n",i+1,fk.score);
        printKey(fk,cfgs);
        EnigmaKey key;
        key.rotor[0]=cfgs[fk.cfg].thin_r; key.rotor[1]=cfgs[fk.cfg].left_r;
        key.rotor[2]=cfgs[fk.cfg].mid_r;  key.rotor[3]=cfgs[fk.cfg].right_r;
        key.reflector=cfgs[fk.cfg].reflector;
        for(int j=0;j<4;j++){key.ring[j]=fk.rings[j];key.position[j]=fk.pos[j];}
        copyPlug(fk.plug,key.plugboard);
        EnigmaCPU sim(key);
        std::string plain=sim.process(ct_str);
        printf("  Plaintext (%zu letters):\n",plain.size());
        for(int ci=0;ci<(int)plain.size();ci+=60)
            printf("    %s\n",plain.substr(ci,60).c_str());
        printf("  Sanity: %s\n\n",sanityCipher(plain,ct_str.c_str(),clen)?"OK":"FAIL");
    }

    double tot=sa_s+rs_s+hc_s;
    printf("=============================================================\n");
    printf("Total: %.1f s  (A:%.1f | Ring:%.1f | HC:%.1f)\n",tot,sa_s,rs_s,hc_s);
    // qg.score() is the SUM of log10(P) over the (clen-3) quadgram window. The
    // threshold must be relative to the message length: correct German text
    // yields ~ -5.6/char (U-264 reference: -5.60), whereas gibberish is
    // < -6.7/char. The old fixed threshold of -1100 was rejecting even the
    // CORRECT decryption (U-264 correct = -1282.73).
    float qg_per_char = finals.empty() ? -1e30f
                                       : finals[0].score / (float)(clen - 3);
    bool ok = !finals.empty() && qg_per_char > -6.2f;
    printf("Best qg/char: %.4f  (German ~ -5.6, threshold -6.2)\n", qg_per_char);
    printf("Status: %s\n",ok?"SUCCESS":"FAILURE");

    CUDA_CHECK(cudaFree(d_cipher));
    CUDA_CHECK(cudaFree(d_bsc));CUDA_CHECK(cudaFree(d_bpos));
    CUDA_CHECK(cudaFree(d_cc2));CUDA_CHECK(cudaFree(d_cp2));
    CUDA_CHECK(cudaFree(d_best_sc));CUDA_CHECK(cudaFree(d_best_ring));CUDA_CHECK(cudaFree(d_lock));
    CUDA_CHECK(cudaFree(d_tr));CUDA_CHECK(cudaFree(d_lr));
    CUDA_CHECK(cudaFree(d_mr));CUDA_CHECK(cudaFree(d_rr_));CUDA_CHECK(cudaFree(d_rf_));
    return ok?0:1;
}
