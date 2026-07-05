// ============================================================================
// CRACK U-264 - GPU plugboard-recovery attack (REAL full-plugboard HC)
// ============================================================================
//
// WHY THIS EXISTS:
//   Measurement (ioc_diag) shows that decrypting U-264 WITHOUT the plugboard
//   at the CORRECT key is statistically indistinguishable from random text
//   (IoC 0.040 ~ random 0.0385). That's why Stage A from enigma_breaker.cu
//   (trigram-HC on the OUTPUT side only) cannot surface the correct rotor
//   config for a message with 10 plug pairs - that's a mathematical limit,
//   not a bug.
//
//   The only discriminator is TRUE plugboard recovery: decrypt with the
//   plugboard on BOTH sides (plug -> rotors -> reflector -> rotors ->
//   plug) and measure how much the plugboard hill-climb raises the IoC. At
//   the correct (config, ring, position) the IoC jumps 0.040 -> ~0.058; at
//   wrong ones it stays ~0.040. THAT is the signal that works.
//
// WHAT THIS PROGRAM DOES:
//   Given the DAILY rotor key (wheel order + ring setting - what would in
//   practice be obtained from a key sheet or a bombe attack), the GPU
//   searches all 26^4 = 456,976 message positions. Each thread runs an
//   IoC-scored plugboard hill-climb (ADD-only, up to 10 pairs). The best
//   positions are passed to the CPU quadgram hill-climb (the verified
//   hillClimb from plugboard_hc.h), which recovers the exact 10/10 pairs
//   and the full plaintext.
//
//   The default key is U-264: Beta II IV I, B-thin, ring 01 01 01 22
//   (0-based 0,0,0,21). Expected result: VONVONJLOOKS...
//
// FEASIBILITY:
//   456,976 positions x plugboard-HC ~ seconds-minutes on an RTX 4080.
//   A full blind sweep (1344 wheel orders x 26^2 ring x 26^4 pos x
//   plug-HC) is a multi-day / multi-GPU job (architecture Phase 9) - see
//   the --sweep flag below.
//
// Build (see also build_crack.bat):
//   cl /std:c++17 /O2 /MT /c core\enigma_cpu\enigma_cpu.cpp /Fo:build\enigma_cpu.obj
//   cl /std:c++17 /O2 /MT /c filters\quadgram\quadgram_score.cpp /Fo:build\quadgram_score.obj
//   nvcc -ccbin <cl> -std=c++17 -arch=sm_89 -O3 --use_fast_math -I. \
//        -o build\crack_u264.exe crack_u264.cu build\enigma_cpu.obj build\quadgram_score.obj
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
#include "search/plugboard_search/plugboard_hc.h"

// ----------------------------------------------------------------------------
// GPU constant memory - wiring
// ----------------------------------------------------------------------------
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

// ----------------------------------------------------------------------------
// GPU Enigma core (identical to the verified brute_r4.cu / enigma_cpu.cpp)
// ----------------------------------------------------------------------------
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

static constexpr int CMAX = 300;   // max ciphertext length

// Decrypt WITH the plugboard (both sides) and return the IoC.
__device__ float decIoC(const unsigned char* cph,int clen,
                        int tr,int lr,int mr,int rr,int rf,
                        const int* ring,const int* pos0,const unsigned char* plug)
{
    int pos[4]={pos0[0],pos0[1],pos0[2],pos0[3]};
    int freq[26];
    #pragma unroll
    for(int i=0;i<26;i++) freq[i]=0;
    for(int i=0;i<clen;i++){
        int c=(int)cph[i];                 // already 0..25
        c=plug[c];                          // plug INPUT
        c=gEnc(c,pos,tr,lr,mr,rr,rf,ring);
        c=plug[c];                          // plug OUTPUT
        freq[c]++;
    }
    int s=0;
    #pragma unroll
    for(int i=0;i<26;i++) s+=freq[i]*(freq[i]-1);
    return (float)s/(float)(clen*(clen-1));
}

// IoC-scored plugboard hill-climb (ADD-only, up to max_pairs pairs).
__device__ float iocPlugHC(const unsigned char* cph,int clen,
                           int tr,int lr,int mr,int rr,int rf,
                           const int* ring,const int* pos0,int max_pairs)
{
    unsigned char plug[26];
    #pragma unroll
    for(int i=0;i<26;i++) plug[i]=(unsigned char)i;

    float cur=decIoC(cph,clen,tr,lr,mr,rr,rf,ring,pos0,plug);

    for(int p=0;p<max_pairs;p++){
        float best=cur; int ba=-1,bb=-1;
        for(int a=0;a<26;a++){
            if(plug[a]!=a) continue;               // a must be free
            for(int b=a+1;b<26;b++){
                if(plug[b]!=b) continue;           // b must be free
                plug[a]=(unsigned char)b; plug[b]=(unsigned char)a;
                float v=decIoC(cph,clen,tr,lr,mr,rr,rf,ring,pos0,plug);
                plug[a]=(unsigned char)a; plug[b]=(unsigned char)b;
                if(v>best){best=v;ba=a;bb=b;}
            }
        }
        if(ba<0) break;                            // no improvement
        plug[ba]=(unsigned char)bb; plug[bb]=(unsigned char)ba;
        cur=best;
    }
    return cur;
}

// ----------------------------------------------------------------------------
// Kernel: thread = one message position (26^4). Fixed wheel order + ring.
// Block-max reduction: returns (best IoC, position) per block.
// ----------------------------------------------------------------------------
static constexpr int PK_BLK = 64;

__global__ void posSearchKernel(
    const unsigned char* cph,int clen,
    int tr,int lr,int mr,int rr,int rf,
    int r0,int r1,int r2,int r3,
    int max_pairs,
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

// ----------------------------------------------------------------------------
struct DayKey { int tr,lr,mr,rr,rf; int ring[4]; const char* label; };

int main(int argc,char* argv[]){
    const char* dataDir=(argc>1)?argv[1]:"data";
    const char* ctFile =(argc>2)?argv[2]:nullptr;
    int MAX_PAIRS      =(argc>3)?atoi(argv[3]):10;
    int TOPN           =(argc>4)?atoi(argv[4]):256;   // positions for CPU HC

    auto _wall0=std::chrono::high_resolution_clock::now();   // wall-clock timer
    printf("=============================================================\n");
    printf("  CRACK U-264 - GPU plugboard recovery (daily key known)\n");
    printf("=============================================================\n\n");

    cudaDeviceProp prop; CUDA_CHECK(cudaGetDeviceProperties(&prop,0));
    printf("GPU : %s  (CC %d.%d)\n\n",prop.name,prop.major,prop.minor);

    // Quadgram (final CPU HC)
    char qgp[512]; snprintf(qgp,sizeof(qgp),"%s/german_quadgrams.txt",dataDir);
    printf("Loading quadgram table... "); fflush(stdout);
    static QuadgramScorer qg;
    if(!qg.load(qgp)){fprintf(stderr,"ERROR: %s\n",qgp);return 1;}
    printf("OK\n");
    uploadWirings();

    // Ciphertext (default U-264)
    std::string ct;
    if(ctFile){
        FILE* f=fopen(ctFile,"r"); if(!f){fprintf(stderr,"ERROR: %s\n",ctFile);return 1;}
        int ch; while((ch=fgetc(f))!=EOF) if(ch>='A'&&ch<='Z') ct+=(char)ch;
        fclose(f);
    } else {
        ct="NCZWVUSXPNYMINHZXMQXSFWXWLKJAHSHNMCOCCAKUQPMKCSMHKSEINJUSBLK"
           "IOSXCKUBHMLLXCSJUSRRDVKOHULXWCCBGVLIYXEOAHXRHKKFVDREWEZLXOBA"
           "FGYUJQUKGRTVUKAMEURBVEKSUHHVOYHABCJWMAKLFKLMYFVNRIZRVVRTKOFD"
           "ANJMOLBGFFLEOPRGTFLVRHOWOPBEKVWMUQFMPWPARMFHAGKXIIBG";
    }
    int clen=(int)ct.size();
    if(clen>CMAX){fprintf(stderr,"ciphertext > %d\n",CMAX);return 1;}
    printf("Ciphertext: %.40s... (%d letters)\n\n",ct.c_str(),clen);

    // DAILY KEY (known) - U-264
    DayKey dk={THIN_BETA,ROT_II,ROT_IV,ROT_I,REF_B,{0,0,0,21},"U-264: Beta II IV I / B / 01 01 01 22"};
    printf("Daily key (known): %s\n",dk.label);
    printf("Searching message position (26^4=%d) + plugboard (up to %d pairs)\n\n",
           26*26*26*26,MAX_PAIRS);

    // cipher -> 0..25 for the GPU
    std::vector<unsigned char> cb(clen);
    for(int i=0;i<clen;i++) cb[i]=(unsigned char)(ct[i]-'A');
    unsigned char* d_c; CUDA_CHECK(cudaMalloc(&d_c,clen));
    CUDA_CHECK(cudaMemcpy(d_c,cb.data(),clen,cudaMemcpyHostToDevice));

    int SA4=26*26*26*26;
    int nblk=(SA4+PK_BLK-1)/PK_BLK;
    float* d_bsc; int* d_bps;
    CUDA_CHECK(cudaMalloc(&d_bsc,nblk*sizeof(float)));
    CUDA_CHECK(cudaMalloc(&d_bps,nblk*sizeof(int)));

    printf("[GPU position sweep] %d blocks x %d threads ...\n",nblk,PK_BLK);
    auto t0=std::chrono::high_resolution_clock::now();
    posSearchKernel<<<nblk,PK_BLK>>>(d_c,clen,
        dk.tr,dk.lr,dk.mr,dk.rr,dk.rf,
        dk.ring[0],dk.ring[1],dk.ring[2],dk.ring[3],MAX_PAIRS,d_bsc,d_bps);
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaDeviceSynchronize());
    auto t1=std::chrono::high_resolution_clock::now();
    double gpu_s=std::chrono::duration<double>(t1-t0).count();
    printf("  Done: %.2f s  (%.0f M pos/s)\n\n",gpu_s,SA4/gpu_s/1e6);

    std::vector<float> hsc(nblk); std::vector<int> hps(nblk);
    CUDA_CHECK(cudaMemcpy(hsc.data(),d_bsc,nblk*sizeof(float),cudaMemcpyDeviceToHost));
    CUDA_CHECK(cudaMemcpy(hps.data(),d_bps,nblk*sizeof(int),cudaMemcpyDeviceToHost));

    // Top-N block maxima by IoC
    int topn=std::min(TOPN,nblk);
    std::vector<int> idx(nblk); for(int i=0;i<nblk;i++) idx[i]=i;
    std::partial_sort(idx.begin(),idx.begin()+topn,idx.end(),
        [&](int a,int b){return hsc[a]>hsc[b];});

    printf("[GPU top-5 positions by IoC-HC]\n");
    for(int k=0;k<5&&k<topn;k++){
        int t=hps[idx[k]];
        int p0=t/17576,p1=(t/676)%26,p2=(t/26)%26,p3=t%26;
        printf("  #%d  IoC=%.5f  pos=%c%c%c%c\n",k+1,hsc[idx[k]],
               'A'+p0,'A'+p1,'A'+p2,'A'+p3);
    }
    printf("\n");

    // ---- CPU quadgram HC on top-N positions ----
    printf("[CPU quadgram HC] on top %d positions ...\n",topn);
    auto t2=std::chrono::high_resolution_clock::now();
    float best_score=-1e30f; int best_pos=-1; int best_plug[26]; initPlug(best_plug);
    for(int k=0;k<topn;k++){
        int t=hps[idx[k]];
        EnigmaKey base;
        base.rotor[0]=dk.tr;base.rotor[1]=dk.lr;base.rotor[2]=dk.mr;base.rotor[3]=dk.rr;
        base.reflector=dk.rf;
        for(int i=0;i<4;i++) base.ring[i]=dk.ring[i];
        base.position[0]=t/17576;base.position[1]=(t/676)%26;
        base.position[2]=(t/26)%26;base.position[3]=t%26;
        initPlug(base.plugboard);
        PlugResult pr=hillClimb(base,ct.c_str(),clen,qg,MAX_PAIRS,12);
        if(pr.score>best_score){best_score=pr.score;best_pos=t;copyPlug(pr.plug,best_plug);}
    }
    auto t3=std::chrono::high_resolution_clock::now();
    double cpu_s=std::chrono::duration<double>(t3-t2).count();
    printf("  Done: %.2f s\n\n",cpu_s);

    // ---- Result ----
    int p0=best_pos/17576,p1=(best_pos/676)%26,p2=(best_pos/26)%26,p3=best_pos%26;
    EnigmaKey key;
    key.rotor[0]=dk.tr;key.rotor[1]=dk.lr;key.rotor[2]=dk.mr;key.rotor[3]=dk.rr;
    key.reflector=dk.rf;
    for(int i=0;i<4;i++) key.ring[i]=dk.ring[i];
    key.position[0]=p0;key.position[1]=p1;key.position[2]=p2;key.position[3]=p3;
    copyPlug(best_plug,key.plugboard);
    EnigmaCPU sim(key);
    std::string plain=sim.process(ct);

    printf("=============================================================\n");
    printf("RESULT\n");
    printf("=============================================================\n");
    printf("  Msg key (position): %c%c%c%c\n",'A'+p0,'A'+p1,'A'+p2,'A'+p3);
    printf("  Plugboard         : %s\n",plugToStr(best_plug).c_str());
    printf("  Quadgram score    : %.2f  (%.4f/char)\n",best_score,best_score/(clen-3));
    printf("  Plaintext:\n");
    for(int i=0;i<(int)plain.size();i+=60) printf("    %s\n",plain.substr(i,60).c_str());

    bool ok=(plain.compare(0,12,"VONVONJLOOKS")==0) || (best_score/(clen-3) > -6.0f);
    printf("  Status: %s\n",ok?"SUCCESS":"FAILURE");

    double _wall=std::chrono::duration<double>(
        std::chrono::high_resolution_clock::now()-_wall0).count();
    printf("\n  Elapsed (wall-clock): %.1f s   (GPU %.1f + CPU %.1f)\n",_wall,gpu_s,cpu_s);

    cudaFree(d_c);cudaFree(d_bsc);cudaFree(d_bps);
    return ok?0:1;
}
