// ============================================================================
// ENIGMA M4 BLIND - ciphertext-only (WITHOUT a crib, WITHOUT a known key)
// ============================================================================
//
// #3 (blind mode). Generalization of crack_u264.cu: instead of a KNOWN daily
// key, sweep over ALL wheel orders (1344). For each (wheel order, ring) the
// GPU searches 26^4 message positions; each thread runs an IoC-scored
// plugboard hill-climb (= #2 GPU hillclimb; the first ADD-pass tries all 325
// pairs = implicit partial exhaustion from #4, which escapes the flat
// no-plug plateau, finding A). The global top-N candidates (by IoC) go to a
// CPU quadgram hill-climb which returns the full plugboard + plaintext.
//
// SCOPE (honestly):
//   A full R6-correct blind search = 1344 x 26^2(mid+right ring) x 26^4(pos) x plugHC
//   -> multi-day / multi-GPU (Phase 9). On a SINGLE GPU a Krah-style approach
//   is feasible: mid ring fixed (default 0), so 1344 x 26^4 (x optional right-ring) x plugHC.
//   crack_u264: 26^4 pos ~11 s on an RTX 4080 -> 1344 wheel orders ~ 4 h (ring fixed).
//   Hence the CLI knobs for wheel/ring range (validation on a limited sweep).
//
// Build: build_blind.bat
// Run:   build\enigma_blind.exe data <ct.txt> [wheelStart] [wheelCount]
//                                    [r0 r1 r2 r3] [maxPairs] [topN]
//        (without ring arguments -> ring=0; wheelStart/Count -> subset of wheel orders)
// ============================================================================
#include <cstdio>
#include <cstring>
#include <cmath>
#include <vector>
#include <algorithm>
#include <string>
#include <chrono>
#include <cuda_runtime.h>
#include "config.h"
#include "core/enigma_cpu/enigma_cpu.h"
#include "filters/quadgram/quadgram_score.h"
#include "filters/trigram/trigram_score.h"
#include "search/plugboard_search/plugboard_hc.h"

__constant__ int c_rotor_fw[8][26];
__constant__ int c_rotor_bw[8][26];
__constant__ int c_thin_fw[2][26];
__constant__ int c_thin_bw[2][26];
__constant__ int c_refl[2][26];
__constant__ int c_notch[8][26];

#define CUDA_CHECK(x) do{cudaError_t e_=(x);if(e_!=cudaSuccess){            \
    fprintf(stderr,"CUDA %s:%d %s\n",__FILE__,__LINE__,                      \
    cudaGetErrorString(e_));exit(1);}}while(0)

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

// ---- GPU Enigma core (verbatim from crack_u264.cu, verified) ----
__device__ __forceinline__ void gStep(int*p,int mr,int rr){
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
    gStep(p,mr,rr);
    x=gFR(x,rr,p[3],ring[3]);x=gFR(x,mr,p[2],ring[2]);
    x=gFR(x,lr,p[1],ring[1]);x=gFT(x,tr,p[0],ring[0]);
    x=c_refl[rf][x];
    x=gBT(x,tr,p[0],ring[0]);x=gBR(x,lr,p[1],ring[1]);
    x=gBR(x,mr,p[2],ring[2]);x=gBR(x,rr,p[3],ring[3]);
    return x;
}

static constexpr int CMAX = 300;

__device__ float decIoC(const unsigned char* cph,int clen,
                        int tr,int lr,int mr,int rr,int rf,
                        const int* ring,const int* pos0,const unsigned char* plug){
    int pos[4]={pos0[0],pos0[1],pos0[2],pos0[3]};
    int freq[26];
    #pragma unroll
    for(int i=0;i<26;i++) freq[i]=0;
    for(int i=0;i<clen;i++){
        int c=(int)cph[i];
        c=plug[c];
        c=gEnc(c,pos,tr,lr,mr,rr,rf,ring);
        c=plug[c];
        freq[c]++;
    }
    int s=0;
    #pragma unroll
    for(int i=0;i<26;i++) s+=freq[i]*(freq[i]-1);
    return (float)s/(float)(clen*(clen-1));
}

// #2/#4: IoC plugboard hill-climb (ADD-only). The first pass tries all 325 pairs
// = partial exhaustion of the first plug pair (escapes the flat no-plug plateau, finding A).
__device__ float iocPlugHC(const unsigned char* cph,int clen,
                           int tr,int lr,int mr,int rr,int rf,
                           const int* ring,const int* pos0,int max_pairs){
    unsigned char plug[26];
    #pragma unroll
    for(int i=0;i<26;i++) plug[i]=(unsigned char)i;
    float cur=decIoC(cph,clen,tr,lr,mr,rr,rf,ring,pos0,plug);
    for(int p=0;p<max_pairs;p++){
        float best=cur; int ba=-1,bb=-1;
        for(int a=0;a<26;a++){
            if(plug[a]!=a) continue;
            for(int b=a+1;b<26;b++){
                if(plug[b]!=b) continue;
                plug[a]=(unsigned char)b; plug[b]=(unsigned char)a;
                float v=decIoC(cph,clen,tr,lr,mr,rr,rf,ring,pos0,plug);
                plug[a]=(unsigned char)a; plug[b]=(unsigned char)b;
                if(v>best){best=v;ba=a;bb=b;}
            }
        }
        if(ba<0) break;
        plug[ba]=(unsigned char)bb; plug[bb]=(unsigned char)ba;
        cur=best;
    }
    return cur;
}

static constexpr int PK_BLK = 64;

// Thread = one position (26^4). Fixed wheel+ring. Block-max -> (IoC,pos).
__global__ void posSearchKernel(
    const unsigned char* cph,int clen,
    int tr,int lr,int mr,int rr,int rf,
    int r0,int r1,int r2,int r3,int max_pairs,
    float* block_sc,int* block_pos)
{
    int tid=(int)blockIdx.x*PK_BLK+(int)threadIdx.x;
    float my=-1.f; int mypos=tid;
    if(tid<26*26*26*26){
        int ring[4]={r0,r1,r2,r3};
        int pos[4]={tid/17576,(tid/676)%26,(tid/26)%26,tid%26};
        my=iocPlugHC(cph,clen,tr,lr,mr,rr,rf,ring,pos,max_pairs);
    }
    __shared__ float ssc[PK_BLK];
    __shared__ int   sps[PK_BLK];
    ssc[threadIdx.x]=my; sps[threadIdx.x]=mypos;
    __syncthreads();
    for(int s=PK_BLK/2;s>0;s>>=1){
        if(threadIdx.x<s && ssc[threadIdx.x+s]>ssc[threadIdx.x]){
            ssc[threadIdx.x]=ssc[threadIdx.x+s];
            sps[threadIdx.x]=sps[threadIdx.x+s];
        }
        __syncthreads();
    }
    if(threadIdx.x==0){ block_sc[blockIdx.x]=ssc[0]; block_pos[blockIdx.x]=sps[0]; }
}

// ---- 1344 wheel orders (same order as crib solver buildConfigs) ----
struct RotorCfg{int thin_r,left_r,mid_r,right_r,reflector;};
static std::vector<RotorCfg> buildConfigs(){
    std::vector<RotorCfg> v;
    for(int rf=0;rf<2;rf++) for(int th=0;th<2;th++)
    for(int l=0;l<8;l++) for(int m=0;m<8;m++) if(m!=l)
    for(int r=0;r<8;r++) if(r!=l&&r!=m) v.push_back({th,l,m,r,rf});
    return v;
}

struct Cand{ float ioc; int wheel; int pos; int ring[4]; };

int main(int argc,char* argv[]){
    const char* dataDir=(argc>1)?argv[1]:"data";
    const char* ctFile =(argc>2 && argv[2][0])?argv[2]:nullptr;
    int wheelStart=(argc>3)?atoi(argv[3]):0;
    int wheelCount=(argc>4)?atoi(argv[4]):-1;
    // optional ring r0..r3 (argv 5-8); otherwise 0. maxPairs/topN after the ring.
    int ring[4]={0,0,0,0};
    bool ringGiven = (argc>8);
    if(ringGiven) for(int i=0;i<4;i++) ring[i]=atoi(argv[5+i]);
    int MAX_PAIRS = (argc> (ringGiven?9:5)) ? atoi(argv[ringGiven?9:5]) : 10;
    int TOPN      = (argc> (ringGiven?10:6))? atoi(argv[ringGiven?10:6]): 256;

    printf("=============================================================\n");
    printf("  ENIGMA M4 BLIND - ciphertext-only (no crib/key)\n");
    printf("=============================================================\n\n");
    cudaDeviceProp prop; CUDA_CHECK(cudaGetDeviceProperties(&prop,0));
    printf("GPU : %s  (CC %d.%d)\n",prop.name,prop.major,prop.minor);

    char qgp[512]; snprintf(qgp,sizeof(qgp),"%s/german_quadgrams.txt",dataDir);
    static QuadgramScorer qg;
    if(!qg.load(qgp)){fprintf(stderr,"ERROR quadgram: %s\n",qgp);return 1;}
    char tgp[512]; snprintf(tgp,sizeof(tgp),"%s/german_trigrams.txt",dataDir);
    static TrigramScorer tg;
    if(!tg.load(tgp)){fprintf(stderr,"ERROR trigram: %s\n",tgp);return 1;}
    uploadWirings();

    std::string ct;
    if(ctFile){ FILE* f=fopen(ctFile,"r"); if(!f){fprintf(stderr,"ERROR: %s\n",ctFile);return 1;}
        int ch; while((ch=fgetc(f))!=EOF) if(ch>='A'&&ch<='Z') ct+=(char)ch; fclose(f);
    } else { fprintf(stderr,"Provide ciphertext file as 2nd arg.\n"); return 1; }
    int clen=(int)ct.size();
    if(clen>CMAX){fprintf(stderr,"ciphertext > %d\n",CMAX);return 1;}

    auto cfgs=buildConfigs(); int ncfg=(int)cfgs.size();
    if(wheelCount<0) wheelCount=ncfg-wheelStart;
    int wheelEnd=std::min(ncfg,wheelStart+wheelCount);

    printf("Ciphertext (%d): %.46s...\n",clen,ct.c_str());
    printf("Wheel orders: [%d, %d)  of %d   ring=%d %d %d %d %s\n",
           wheelStart,wheelEnd,ncfg,ring[0],ring[1],ring[2],ring[3],
           ringGiven?"(given)":"(default 0)");
    printf("maxPairs=%d  topN=%d   (26^4 pos/wheel-order)\n\n",MAX_PAIRS,TOPN);

    std::vector<unsigned char> cb(clen);
    for(int i=0;i<clen;i++) cb[i]=(unsigned char)(ct[i]-'A');
    unsigned char* d_c; CUDA_CHECK(cudaMalloc(&d_c,clen));
    CUDA_CHECK(cudaMemcpy(d_c,cb.data(),clen,cudaMemcpyHostToDevice));

    int SA4=26*26*26*26;
    int nblk=(SA4+PK_BLK-1)/PK_BLK;
    float* d_bsc; int* d_bps;
    CUDA_CHECK(cudaMalloc(&d_bsc,nblk*sizeof(float)));
    CUDA_CHECK(cudaMalloc(&d_bps,nblk*sizeof(int)));
    std::vector<float> hsc(nblk); std::vector<int> hps(nblk);

    std::vector<Cand> pool;          // global candidates (top-K per wheel order)
    const int PERWHEEL=256;          // how many best pos-blocks per wheel order to keep
                                     // (crack_u264: the correct position only lands in ~top-256 by IoC)
    auto t0=std::chrono::high_resolution_clock::now();

    for(int w=wheelStart; w<wheelEnd; w++){
        auto&c=cfgs[w];
        posSearchKernel<<<nblk,PK_BLK>>>(d_c,clen,c.thin_r,c.left_r,c.mid_r,c.right_r,c.reflector,
            ring[0],ring[1],ring[2],ring[3],MAX_PAIRS,d_bsc,d_bps);
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaDeviceSynchronize());
        CUDA_CHECK(cudaMemcpy(hsc.data(),d_bsc,nblk*sizeof(float),cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaMemcpy(hps.data(),d_bps,nblk*sizeof(int),cudaMemcpyDeviceToHost));
        std::vector<int> idx(nblk); for(int i=0;i<nblk;i++) idx[i]=i;
        int kk=std::min(PERWHEEL,nblk);
        std::partial_sort(idx.begin(),idx.begin()+kk,idx.end(),
            [&](int a,int b){return hsc[a]>hsc[b];});
        for(int i=0;i<kk;i++){
            Cand cd; cd.ioc=hsc[idx[i]]; cd.wheel=w; cd.pos=hps[idx[i]];
            cd.ring[0]=ring[0];cd.ring[1]=ring[1];cd.ring[2]=ring[2];cd.ring[3]=ring[3];
            pool.push_back(cd);
        }
        if(((w-wheelStart)%64)==0 || w==wheelEnd-1){
            auto tn=std::chrono::high_resolution_clock::now();
            double el=std::chrono::duration<double>(tn-t0).count();
            printf("\r  wheel-order %d/%d  (%.0f s, %.2f s/wo)   ",
                   w-wheelStart+1,wheelEnd-wheelStart,el,el/std::max(1,w-wheelStart+1));
            fflush(stdout);
        }
    }
    auto t1=std::chrono::high_resolution_clock::now();
    double gpu_s=std::chrono::duration<double>(t1-t0).count();
    printf("\n[GPU sweep] done: %.1f s\n\n",gpu_s);

    // Global top-N by IoC -> CPU quadgram hill-climb
    int topn=std::min((int)pool.size(),TOPN);
    std::partial_sort(pool.begin(),pool.begin()+topn,pool.end(),
        [](const Cand&a,const Cand&b){return a.ioc>b.ioc;});
    printf("[CPU quadgram HC] on global top-%d (IoC) candidates ...\n",topn);

    static const char* RN[]={"I","II","III","IV","V","VI","VII","VIII"};
    static const char* TN[]={"Beta","Gamma"}; static const char* RF[]={"B","C"};
    auto t2=std::chrono::high_resolution_clock::now();
    float best_score=-1e30f; EnigmaKey bestKey; std::string bestPlain; bool have=false;
    for(int k=0;k<topn;k++){
        Cand&cd=pool[k]; auto&c=cfgs[cd.wheel]; int t=cd.pos;
        EnigmaKey base;
        base.rotor[0]=c.thin_r;base.rotor[1]=c.left_r;base.rotor[2]=c.mid_r;base.rotor[3]=c.right_r;
        base.reflector=c.reflector;
        for(int i=0;i<4;i++) base.ring[i]=cd.ring[i];
        base.position[0]=t/17576;base.position[1]=(t/676)%26;base.position[2]=(t/26)%26;base.position[3]=t%26;
        initPlug(base.plugboard);
        PlugResult pr=hillClimb(base,ct.c_str(),clen,qg,MAX_PAIRS,12);
        if(pr.score>best_score){
            best_score=pr.score; EnigmaKey kk=base; copyPlug(pr.plug,kk.plugboard);
            EnigmaCPU sim(kk); bestPlain=sim.process(ct); bestKey=kk; have=true;
        }
    }
    auto t3=std::chrono::high_resolution_clock::now();
    double cpu_s=std::chrono::duration<double>(t3-t2).count();

    printf("\n=============================================================\n");
    printf("RESULT (blind, ciphertext-only)\n");
    printf("=============================================================\n");
    if(have){
        printf("  Reflector : %s\n",RF[bestKey.reflector]);
        printf("  Wheels    : %s %s %s %s\n",TN[bestKey.rotor[0]],RN[bestKey.rotor[1]],RN[bestKey.rotor[2]],RN[bestKey.rotor[3]]);
        printf("  Rings     : %d %d %d %d\n",bestKey.ring[0],bestKey.ring[1],bestKey.ring[2],bestKey.ring[3]);
        printf("  Positions : %d %d %d %d\n",bestKey.position[0],bestKey.position[1],bestKey.position[2],bestKey.position[3]);
        printf("  Plugboard : %s\n",plugToStr(bestKey.plugboard).c_str());
        printf("  qg/char   : %.3f   tg/char %.3f\n",best_score/(clen-3),tg.score(bestPlain)/(clen-2));
        printf("  Plaintext : %s\n",bestPlain.c_str());
    } else printf("  (no result)\n");
    printf("\n  Elapsed (wall-clock): GPU %.1f s + CPU %.1f s = %.1f s\n",gpu_s,cpu_s,gpu_s+cpu_s);

    cudaFree(d_c);cudaFree(d_bsc);cudaFree(d_bps);
    return have?0:1;
}
