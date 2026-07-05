// ============================================================================
// ENIGMA M4 BLIND-DEPTH - ciphertext-only, MULTIPLE messages same daily key
// ============================================================================
//
// Depth attack (historically: daily traffic). N messages share the wheel
// order + ring settings + PLUGBOARD; positions differ per message. The key
// insight is the shared plugboard:
//   - single-message blind fails because the plugboard hillclimb OVERFITS
//     (a false stecker pair boosts the IoC on one message) and the IoC signal
//     is weak over 200 letters.
//   - DEPTH: score a candidate as the SUM over messages. A false stecker pair
//     that helps message 1 HURTS message 2 -> the shared plugboard forces the
//     TRUE key; the signal grows with the total length. The correct wheel
//     order makes ALL messages come out as German.
//
// Pipeline:
//   1. For each wheel order w (CLI range) and for the SUBSET of longest
//      messages: GPU 26^4 position sweep (iocPlugHC) -> best position per
//      message.
//   2. CPU JOINT plugboard hillclimb: one shared plugboard maximizes the SUM
//      of quadgram scores over the subset (at the positions found above).
//   3. joint_score(w) = that sum. Rank the wheel orders. The correct one wins
//      decisively.
//   4. For the winner: print the daily key + decrypt the subset.
//
// Build: build_blind_depth.bat
// Run:   build\enigma_blind_depth.exe data <ct_lines.txt> [wStart] [wCount]
//                                     [r0 r1 r2 r3] [maxPairs] [nSub]
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
static constexpr int CMAX = 400;
__device__ float decIoC(const unsigned char* cph,int clen,
                        int tr,int lr,int mr,int rr,int rf,
                        const int* ring,const int* pos0,const unsigned char* plug){
    int pos[4]={pos0[0],pos0[1],pos0[2],pos0[3]};
    int freq[26];
    #pragma unroll
    for(int i=0;i<26;i++) freq[i]=0;
    for(int i=0;i<clen;i++){
        int c=(int)cph[i]; c=plug[c]; c=gEnc(c,pos,tr,lr,mr,rr,rf,ring); c=plug[c]; freq[c]++;
    }
    int s=0;
    #pragma unroll
    for(int i=0;i<26;i++) s+=freq[i]*(freq[i]-1);
    return (float)s/(float)(clen*(clen-1));
}
__device__ float iocPlugHC(const unsigned char* cph,int clen,
                           int tr,int lr,int mr,int rr,int rf,
                           const int* ring,const int* pos0,int max_pairs){
    unsigned char plug[26];
    #pragma unroll
    for(int i=0;i<26;i++) plug[i]=(unsigned char)i;
    float cur=decIoC(cph,clen,tr,lr,mr,rr,rf,ring,pos0,plug);
    for(int p=0;p<max_pairs;p++){
        float best=cur; int ba=-1,bb=-1;
        for(int a=0;a<26;a++){ if(plug[a]!=a) continue;
            for(int b=a+1;b<26;b++){ if(plug[b]!=b) continue;
                plug[a]=(unsigned char)b; plug[b]=(unsigned char)a;
                float v=decIoC(cph,clen,tr,lr,mr,rr,rf,ring,pos0,plug);
                plug[a]=(unsigned char)a; plug[b]=(unsigned char)b;
                if(v>best){best=v;ba=a;bb=b;} } }
        if(ba<0) break;
        plug[ba]=(unsigned char)bb; plug[bb]=(unsigned char)ba; cur=best;
    }
    return cur;
}
static constexpr int PK_BLK = 64;
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
            ssc[threadIdx.x]=ssc[threadIdx.x+s]; sps[threadIdx.x]=sps[threadIdx.x+s]; }
        __syncthreads();
    }
    if(threadIdx.x==0){ block_sc[blockIdx.x]=ssc[0]; block_pos[blockIdx.x]=sps[0]; }
}

struct RotorCfg{int thin_r,left_r,mid_r,right_r,reflector;};
static std::vector<RotorCfg> buildConfigs(){
    std::vector<RotorCfg> v;
    for(int rf=0;rf<2;rf++) for(int th=0;th<2;th++)
    for(int l=0;l<8;l++) for(int m=0;m<8;m++) if(m!=l)
    for(int r=0;r<8;r++) if(r!=l&&r!=m) v.push_back({th,l,m,r,rf});
    return v;
}

// ---- CPU JOINT plugboard hillclimb over the message subset ----
// score(plug) = SUM over m of qg.score(decrypt of message m at pos_m with shared plug).
struct SubMsg { EnigmaKey base; std::string ct; };  // base = wheel+ring+pos, without plug
static double jointScore(const std::vector<SubMsg>& sub,const int* plug,const QuadgramScorer& qg){
    double s=0.0;
    for(const auto& m : sub){ EnigmaKey k=m.base; copyPlug(plug,k.plugboard);
        EnigmaCPU sim(k); s+=qg.score(sim.process(m.ct)); }
    return s;
}
static double jointHillClimb(const std::vector<SubMsg>& sub,const QuadgramScorer& qg,
                             int* outPlug,int max_pairs){
    int plug[26]; initPlug(plug);
    double cur=jointScore(sub,plug,qg);
    bool imp=true; int tmp[26],best[26];
    while(imp){
        imp=false; copyPlug(plug,best); double bc=cur;
        int fr[26],nf=0; for(int i=0;i<26;i++) if(plug[i]==i) fr[nf++]=i;
        int np=0; for(int i=0;i<26;i++) if(plug[i]>i) np++;
        if(np<max_pairs)
            for(int a=0;a<nf;a++) for(int b=a+1;b<nf;b++){
                copyPlug(plug,tmp); tmp[fr[a]]=fr[b]; tmp[fr[b]]=fr[a];
                double v=jointScore(sub,tmp,qg); if(v>bc){bc=v;copyPlug(tmp,best);} }
        for(int i=0;i<26;i++) if(plug[i]>i){ int a=i,b=plug[i];
            copyPlug(plug,tmp); tmp[a]=a; tmp[b]=b;
            double v=jointScore(sub,tmp,qg); if(v>bc){bc=v;copyPlug(tmp,best);}
            for(int c=0;c<nf;c++){ int f=fr[c];
                copyPlug(plug,tmp); tmp[a]=a;tmp[b]=b; tmp[a]=f;tmp[f]=a;
                v=jointScore(sub,tmp,qg); if(v>bc){bc=v;copyPlug(tmp,best);}
                copyPlug(plug,tmp); tmp[a]=a;tmp[b]=b; tmp[b]=f;tmp[f]=b;
                v=jointScore(sub,tmp,qg); if(v>bc){bc=v;copyPlug(tmp,best);} } }
        if(bc>cur){cur=bc;copyPlug(best,plug);imp=true;}
    }
    copyPlug(plug,outPlug); return cur;
}

int main(int argc,char* argv[]){
    const char* dataDir=(argc>1)?argv[1]:"data";
    const char* ctFile =(argc>2 && argv[2][0])?argv[2]:nullptr;
    int wheelStart=(argc>3)?atoi(argv[3]):0;
    int wheelCount=(argc>4)?atoi(argv[4]):-1;
    int ring[4]={0,0,0,0}; bool ringGiven=(argc>8);
    if(ringGiven) for(int i=0;i<4;i++) ring[i]=atoi(argv[5+i]);
    int MAX_PAIRS=(argc>(ringGiven?9:5))?atoi(argv[ringGiven?9:5]):10;
    int NSUB     =(argc>(ringGiven?10:6))?atoi(argv[ringGiven?10:6]):8;

    printf("=============================================================\n");
    printf("  ENIGMA M4 BLIND-DEPTH - multiple messages, same daily key\n");
    printf("=============================================================\n\n");
    cudaDeviceProp prop; CUDA_CHECK(cudaGetDeviceProperties(&prop,0));
    printf("GPU : %s\n",prop.name);

    char qgp[512]; snprintf(qgp,sizeof(qgp),"%s/german_quadgrams.txt",dataDir);
    static QuadgramScorer qg;
    if(!qg.load(qgp)){fprintf(stderr,"ERROR quadgram: %s\n",qgp);return 1;}
    uploadWirings();

    // Load MULTIPLE messages (1 per line)
    std::vector<std::string> msgs;
    { FILE* f=fopen(ctFile,"r"); if(!f){fprintf(stderr,"ERROR: %s\n",ctFile);return 1;}
      char line[2048];
      while(fgets(line,sizeof(line),f)){ std::string s;
          for(char* p=line;*p;p++) if(*p>='A'&&*p<='Z') s+=*p;
          if((int)s.size()>=20 && (int)s.size()<=CMAX) msgs.push_back(s); }
      fclose(f); }
    if(msgs.empty()){fprintf(stderr,"No messages.\n");return 1;}

    // Subset = NSUB longest (most signal)
    std::vector<int> order(msgs.size()); for(size_t i=0;i<msgs.size();i++) order[i]=(int)i;
    std::sort(order.begin(),order.end(),[&](int a,int b){return msgs[a].size()>msgs[b].size();});
    int nsub=std::min((int)msgs.size(),NSUB);

    auto cfgs=buildConfigs(); int ncfg=(int)cfgs.size();
    if(wheelCount<0) wheelCount=ncfg-wheelStart;
    int wheelEnd=std::min(ncfg,wheelStart+wheelCount);

    printf("Total messages: %zu   subset(longest): %d   ring=%d %d %d %d %s\n",
           msgs.size(),nsub,ring[0],ring[1],ring[2],ring[3],ringGiven?"(given)":"(0)");
    printf("Wheel orders: [%d,%d) of %d   maxPairs=%d\n\n",wheelStart,wheelEnd,ncfg,MAX_PAIRS);

    // GPU buffers for a single message (max CMAX)
    int SA4=26*26*26*26; int nblk=(SA4+PK_BLK-1)/PK_BLK;
    unsigned char* d_c; CUDA_CHECK(cudaMalloc(&d_c,CMAX));
    float* d_bsc; int* d_bps;
    CUDA_CHECK(cudaMalloc(&d_bsc,nblk*sizeof(float)));
    CUDA_CHECK(cudaMalloc(&d_bps,nblk*sizeof(int)));
    std::vector<float> hsc(nblk); std::vector<int> hps(nblk);

    // Best position per (wheel order, subset message): helper function
    auto bestPos=[&](const std::string& ct,const RotorCfg& c)->int{
        int clen=(int)ct.size();
        std::vector<unsigned char> cb(clen);
        for(int i=0;i<clen;i++) cb[i]=(unsigned char)(ct[i]-'A');
        CUDA_CHECK(cudaMemcpy(d_c,cb.data(),clen,cudaMemcpyHostToDevice));
        posSearchKernel<<<nblk,PK_BLK>>>(d_c,clen,c.thin_r,c.left_r,c.mid_r,c.right_r,c.reflector,
            ring[0],ring[1],ring[2],ring[3],MAX_PAIRS,d_bsc,d_bps);
        CUDA_CHECK(cudaGetLastError()); CUDA_CHECK(cudaDeviceSynchronize());
        CUDA_CHECK(cudaMemcpy(hsc.data(),d_bsc,nblk*sizeof(float),cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaMemcpy(hps.data(),d_bps,nblk*sizeof(int),cudaMemcpyDeviceToHost));
        int bi=0; for(int i=1;i<nblk;i++) if(hsc[i]>hsc[bi]) bi=i; return hps[bi];
    };

    double bestJoint=-1e30; int bestW=-1; int bestPlug[26]; std::vector<int> bestPosV(nsub);
    auto t0=std::chrono::high_resolution_clock::now();
    for(int w=wheelStart; w<wheelEnd; w++){
        auto&c=cfgs[w];
        std::vector<SubMsg> sub(nsub); std::vector<int> posV(nsub);
        for(int i=0;i<nsub;i++){
            const std::string& ct=msgs[order[i]];
            int t=bestPos(ct,c);
            EnigmaKey base; base.rotor[0]=c.thin_r;base.rotor[1]=c.left_r;base.rotor[2]=c.mid_r;base.rotor[3]=c.right_r;
            base.reflector=c.reflector;
            base.ring[0]=ring[0];base.ring[1]=ring[1];base.ring[2]=ring[2];base.ring[3]=ring[3];
            base.position[0]=t/17576;base.position[1]=(t/676)%26;base.position[2]=(t/26)%26;base.position[3]=t%26;
            initPlug(base.plugboard);
            sub[i].base=base; sub[i].ct=ct; posV[i]=t;
        }
        int plug[26]; double js=jointHillClimb(sub,qg,plug,MAX_PAIRS);
        double perChar=js / (double)( [&]{int s=0;for(int i=0;i<nsub;i++)s+=(int)sub[i].ct.size()-3;return s;}() );
        if(js>bestJoint){ bestJoint=js; bestW=w; copyPlug(plug,bestPlug); bestPosV=posV; }
        auto tn=std::chrono::high_resolution_clock::now();
        double el=std::chrono::duration<double>(tn-t0).count();
        printf("\r  w %d/%d  joint/char=%.3f  best w=%d (%.3f)   (%.0fs)      ",
               w-wheelStart+1,wheelEnd-wheelStart,perChar,bestW,
               bestJoint/((double)nsub* (msgs[order[0]].size())),el);
        fflush(stdout);
    }
    auto t1=std::chrono::high_resolution_clock::now();
    double el=std::chrono::duration<double>(t1-t0).count();
    printf("\n\n[Sweep done: %.1f s]\n",el);

    static const char* RN[]={"I","II","III","IV","V","VI","VII","VIII"};
    static const char* TN[]={"Beta","Gamma"}; static const char* RF[]={"B","C"};
    auto&bc=cfgs[bestW];
    printf("\n=============================================================\n");
    printf("RECOVERED DAILY KEY (blind-depth, ciphertext-only)\n");
    printf("=============================================================\n");
    printf("  Wheel idx : %d\n",bestW);
    printf("  Reflector : %s\n",RF[bc.reflector]);
    printf("  Wheels    : %s %s %s %s\n",TN[bc.thin_r],RN[bc.left_r],RN[bc.mid_r],RN[bc.right_r]);
    printf("  Rings     : %d %d %d %d\n",ring[0],ring[1],ring[2],ring[3]);
    printf("  Plugboard : %s\n",plugToStr(bestPlug).c_str());
    printf("  joint qg  : %.1f\n\n",bestJoint);

    // Decrypt the subset with the winner (show that they are German)
    printf("Decrypt of subset (winner):\n");
    for(int i=0;i<nsub && i<6;i++){
        EnigmaKey k; k.rotor[0]=bc.thin_r;k.rotor[1]=bc.left_r;k.rotor[2]=bc.mid_r;k.rotor[3]=bc.right_r;
        k.reflector=bc.reflector; for(int j=0;j<4;j++)k.ring[j]=ring[j];
        int t=bestPosV[i]; k.position[0]=t/17576;k.position[1]=(t/676)%26;k.position[2]=(t/26)%26;k.position[3]=t%26;
        copyPlug(bestPlug,k.plugboard);
        EnigmaCPU sim(k); std::string pl=sim.process(msgs[order[i]]);
        printf("  [%d] %.70s\n",i+1,pl.c_str());
    }
    printf("\n  Elapsed (wall-clock): %.1f s\n",el);
    cudaFree(d_c);cudaFree(d_bsc);cudaFree(d_bps);
    return 0;
}
