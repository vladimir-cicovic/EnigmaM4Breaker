// ============================================================================
// ENIGMA M4 CRIB SOLVER - GPU Turing-bombe (ciphertext + known crib)
// ============================================================================
//
// Attack for test_messages (and any M4 message with a known start):
//   1. Drag known phrases across "Enigma never encrypts a letter to itself" -> crib.
//   2. GPU bombe: for every (wheel order x offset setting) propagates plugboard
//      constraints from the crib; inconsistent settings are rejected (~100%).
//      Search space per wheel order: 26^5 = thinoff x leftoff x midoff x
//      pos_right x ring_right  (left/middle: within the crib window they don't
//      step cascadingly, so they enter as an offset; right: pos+ring explicit
//      because of notch timing).
//   3. CPU: for the candidates, recover the plugboard (bombe), resolve the ring
//      split (left/middle absolute position) via the full quadgram score, print
//      the key+plaintext.
//
// Validated (Python PoC) on id=1: bombe recovers all 10/10 plug pairs from
// the crib, 0/3000 false positives on a crib of 39 letters.
//
// Build: build_crib.bat
// Run:   build\enigma_crib_solver.exe data <ct_file|""> [wheel_start] [wheel_count]
//        (without wheel arguments -> sweep all 1344 wheel orders)
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

static const int  ROT5 = 26*26*26*26*26;     // 26^5 = 11,881,376
static const int  MAXL = 48;                  // max crib length
static const int  RMK  = 5;                   // #7: how many top ring_mid (by scoreXsplit) go into the expensive xSolve (instead of all 26)

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

// ---- GPU enigma core ----
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

// No-plug permutation M_i (realization: ring 0 for thin/left; right=rrr, middle=rmid).
// R6: the middle ring (rmid) DECOUPLES the wiring offset (pM-rmid) from the window
//     position pM (which via gStep still drives the left rotor's notch/step). rmid=0 -> old 26^5 behavior.
__device__ __forceinline__
int npEnc(int x,int pT,int pL,int pM,int pR,int rrr,int rmid,int tr,int lr,int mr,int rr,int rf){
    x=gFR(x,rr,pR,rrr); x=gFR(x,mr,pM,rmid); x=gFR(x,lr,pL,0); x=gFT(x,tr,pT,0);
    x=c_refl[rf][x];
    x=gBT(x,tr,pT,0); x=gBR(x,lr,pL,0); x=gBR(x,mr,pM,rmid); x=gBR(x,rr,pR,rrr);
    return x;
}

// setpair into partial involution S (255 = unknown). false = contradiction.
__device__ __forceinline__ bool dSet(unsigned char* S,int x,int y){
    if(x==y){ if(S[x]==255){S[x]=(unsigned char)x;return true;} return S[x]==x; }
    if(S[x]!=255 && S[x]!=y) return false;
    if(S[y]!=255 && S[y]!=x) return false;
    S[x]=(unsigned char)y; S[y]=(unsigned char)x; return true;
}

// Bombe: does a consistent plugboard exist for the crib at this setting?
__device__ bool bombeOK(const unsigned char* crib,const unsigned char* cipher,int L,
                        int pT,const unsigned char* pL,const unsigned char* pM,
                        const unsigned char* pR,int rrr,int rmid,int tr,int lr,int mr,int rr,int rf)
{
    for(int g=0; g<26; g++){
        unsigned char S[26];
        #pragma unroll
        for(int i=0;i<26;i++) S[i]=255;
        if(!dSet(S,crib[0],g)) continue;
        bool bad=false,changed=true;
        while(changed && !bad){
            changed=false;
            for(int i=0;i<L;i++){
                int a=crib[i], b=cipher[i];
                if(S[a]!=255){
                    int w=npEnc(S[a],pT,pL[i],pM[i],pR[i],rrr,rmid,tr,lr,mr,rr,rf);
                    if(S[b]==255){ if(!dSet(S,b,w)){bad=true;break;} changed=true; }
                    else if(S[b]!=w){ bad=true; break; }
                }
                if(S[b]!=255){
                    int w=npEnc(S[b],pT,pL[i],pM[i],pR[i],rrr,rmid,tr,lr,mr,rr,rf);
                    if(S[a]==255){ if(!dSet(S,a,w)){bad=true;break;} changed=true; }
                    else if(S[a]!=w){ bad=true; break; }
                }
            }
        }
        if(!bad) return true;
    }
    return false;
}

__global__ void bombeKernel(const unsigned char* crib,const unsigned char* cipher,int L,int off,
                            int tr,int lr,int mr,int rr,int rf,int wheelIdx,
                            int ringMidSpan,long long total,
                            int* candWheel,int* candTid,int* candCount,int maxCand)
{
    long long tid=(long long)blockIdx.x*blockDim.x+threadIdx.x;
    if(tid>=total) return;
    // Decode: rrr,posR | ringMid (R6: 0..25, legacy: always 0) | mido(window),lefto,thino
    long long base=676LL*ringMidSpan;
    int rrr    = (int)(tid%26);
    int posR   = (int)((tid/26)%26);
    int ringMid= (int)((tid/676)%ringMidSpan);
    int mido   = (int)((tid/base)%26);
    int lefto  = (int)((tid/(base*26))%26);
    int thino  = (int)((tid/(base*676))%26);

    unsigned char pL[MAXL],pM[MAXL],pR[MAXL];
    int p[4]={thino,lefto,mido,posR};
    for(int i=0;i<off;i++) gStep(p,mr,rr);                 // step up to the crib offset
    for(int i=0;i<L;i++){ gStep(p,mr,rr); pL[i]=(unsigned char)p[1];
        pM[i]=(unsigned char)p[2]; pR[i]=(unsigned char)p[3]; }

    // cipher pointer is already shifted to the offset (host sends d_ct+off)
    if(bombeOK(crib,cipher,L,thino,pL,pM,pR,rrr,ringMid,tr,lr,mr,rr,rf)){
        int idx=atomicAdd(candCount,1);
        if(idx<maxCand){ candWheel[idx]=wheelIdx; candTid[idx]=(int)tid; }
    }
}

// ====================== CPU side ======================
struct RotorCfg{int thin_r,left_r,mid_r,right_r,reflector;};
static std::vector<RotorCfg> buildConfigs(){
    std::vector<RotorCfg> v;
    for(int rf=0;rf<2;rf++) for(int th=0;th<2;th++)
    for(int l=0;l<8;l++) for(int m=0;m<8;m++) if(m!=l)
    for(int r=0;r<8;r++) if(r!=l&&r!=m) v.push_back({th,l,m,r,rf});
    return v;
}

// 27 known phrases
static const char* PHRASES[]={
"VONXOBERKOMMANDOXDERXMARINE","ANXALLEXUBOOTEXIMXNORDATLANTIK","FEINDXKONVOIXGESICHTETXQUADRAT",
"WETTERXBERICHTXFUERXDIEXNAECHSTENXSTUNDEN","ANGRIFFXBEFOHLENXBEIXTAGESANBRUCH","POSITIONXMELDENXSOFORT",
"TREIBSTOFFXKNAPPXRUECKKEHRXZUMXSTUETZPUNKT","FUNKSTILLEXEINHALTENXBISXWEITERERXBEFEHL","GELEITZUGXVERSENKTXVIERXSCHIFFE",
"TORPEDOSXVERSCHOSSENXALLEXTREFFER","UBOOTXBESCHAEDIGTXTAUCHENXNICHTXMOEGLICH","NEUEXKOORDINATENXFOLGENXIMXNAECHSTENXFUNKSPRUCH",
"LUFTAUFKLAERUNGXMELDETXFEINDXFLOTTE","NACHSCHUBXERFORDERLICHXDRINGEND","SCHWERESXWETTERXBEHINDERTXANGRIFF",
"GEHEIMEXOPERATIONXBEGINNTXUMXMITTERNACHT","ALLEXBOOTEXSAMMELNXBEIXTREFFPUNKTXANTON","MELDUNGXUEBERXFEINDXBEWEGUNGEN",
"VERSORGUNGSSCHIFFXERWARTETXMORGENXFRUEH","KURSXAENDERNXAUFXNORDXNORDOST","TIEFEXWASSERBOMBENXANGRIFFXUEBERSTANDEN",
"MASCHINENXSCHADENXBEHOBENXFAHRTXAUFGENOMMEN","GEFANGENEXANXBORDXGENOMMEN","SICHTXVERHAELTNISSEXSCHLECHTXNEBEL",
"BEFEHLXBESTAETIGTXFUEHREXAUSXSOFORT","RESERVENXAUFGEBRAUCHTXBITTEXUMXANWEISUNG"};
static const int NPHRASES=26;   // exact number of phrases in the array (was a bug: 27 -> OOB read)

// Dictionary of GENERAL German military/naval cribs (authentic style, long >=18 due to
// the ~20 threshold). For "DICT" mode: each one is dragged over all positions until one breaks.
// (Short words like WETTER/EINS flood on their own so they're not here; a long chunk of known text is needed.)
static const char* DICT_EXTRA[]={
"KEINEBESONDERENEREIGNISSE","OBERKOMMANDODERWEHRMACHT","OBERKOMMANDODERKRIEGSMARINE",
"WETTERVORHERSAGEFUERDIENACHT","ANGRIFFAUFGELEITZUGBEFOHLEN","RUECKKEHRZUMSTUETZPUNKT",
"FEINDFLUGZEUGINSICHTQUADRAT","FUNKSPRUCHWIRDWIEDERHOLT","MARINEGRUPPENKOMMANDONORD",
"BEFEHLAUSGEFUEHRTMELDESOFORT","UBOOTMELDETKEINENFEINDKONTAKT","NACHSCHUBANGEFORDERTDRINGEND"};
static const int NDICT_EXTRA=12;

// ---- CPU mirror of the bombe (for recovering the plugboard from the crib) ----
static int H_fw[8][26],H_bw[8][26],H_tfw[2][26],H_tbw[2][26],H_refl[2][26],H_notch[8][26];
static void cpuBuildWiring(){
    for(int r=0;r<8;r++){
        for(int i=0;i<26;i++) H_fw[r][i]=ROTOR_WIRING[r][i]-'A';
        for(int i=0;i<26;i++) H_bw[r][H_fw[r][i]]=i;
        for(int i=0;i<26;i++) H_notch[r][i]=0;
        for(const char*n=ROTOR_NOTCH[r];*n;n++) H_notch[r][*n-'A']=1;
    }
    for(int t=0;t<2;t++){
        for(int i=0;i<26;i++) H_tfw[t][i]=THIN_ROTOR_WIRING[t][i]-'A';
        for(int i=0;i<26;i++) H_tbw[t][H_tfw[t][i]]=i;
    }
    for(int r=0;r<2;r++) for(int i=0;i<26;i++) H_refl[r][i]=REFLECTOR_WIRING[r][i]-'A';
}
static inline int hFR(int c,int r,int p,int rg){int o=(p-rg+26)%26;c=(c+o)%26;c=H_fw[r][c];return(c-o+26)%26;}
static inline int hBR(int c,int r,int p,int rg){int o=(p-rg+26)%26;c=(c+o)%26;c=H_bw[r][c];return(c-o+26)%26;}
static inline int hFT(int c,int t,int p,int rg){int o=(p-rg+26)%26;c=(c+o)%26;c=H_tfw[t][c];return(c-o+26)%26;}
static inline int hBT(int c,int t,int p,int rg){int o=(p-rg+26)%26;c=(c+o)%26;c=H_tbw[t][c];return(c-o+26)%26;}
static inline int cpuNp(int x,int pT,int pL,int pM,int pR,int rrr,int rmid,int tr,int lr,int mr,int rr,int rf){
    x=hFR(x,rr,pR,rrr);x=hFR(x,mr,pM,rmid);x=hFR(x,lr,pL,0);x=hFT(x,tr,pT,0);
    x=H_refl[rf][x];
    x=hBT(x,tr,pT,0);x=hBR(x,lr,pL,0);x=hBR(x,mr,pM,rmid);x=hBR(x,rr,pR,rrr);
    return x;
}
static inline void cpuStep(int*p,int mr,int rr){
    bool rn=H_notch[rr][p[3]],mn=H_notch[mr][p[2]];
    if(mn){p[1]=(p[1]+1)%26;p[2]=(p[2]+1)%26;}else if(rn){p[2]=(p[2]+1)%26;}
    p[3]=(p[3]+1)%26;
}
static inline bool cpuSetPair(int*S,int x,int y){
    if(x==y){ if(S[x]==-1){S[x]=x;return true;} return S[x]==x;}
    if(S[x]!=-1&&S[x]!=y)return false; if(S[y]!=-1&&S[y]!=x)return false;
    S[x]=y;S[y]=x;return true;
}
// Returns true + outS (involution, -1->identity) if a consistent plugboard exists.
static bool cpuBombe(const unsigned char*crib,const unsigned char*cipher,int L,int off,
                     int thino,int lefto,int mido,int posR,int rrr,int rmid,
                     int tr,int lr,int mr,int rr,int rf,int* outS){
    unsigned char pL[MAXL],pM[MAXL],pR[MAXL];
    int p[4]={thino,lefto,mido,posR};
    for(int i=0;i<off;i++) cpuStep(p,mr,rr);            // step up to the crib offset
    for(int i=0;i<L;i++){cpuStep(p,mr,rr);pL[i]=(unsigned char)p[1];pM[i]=(unsigned char)p[2];pR[i]=(unsigned char)p[3];}
    for(int g=0;g<26;g++){
        int S[26]; for(int i=0;i<26;i++)S[i]=-1;
        if(!cpuSetPair(S,crib[0],g))continue;
        bool bad=false,ch=true;
        while(ch&&!bad){ ch=false;
            for(int i=0;i<L;i++){
                int a=crib[i],b=cipher[off+i];
                if(S[a]!=-1){int w=cpuNp(S[a],thino,pL[i],pM[i],pR[i],rrr,rmid,tr,lr,mr,rr,rf);
                    if(S[b]==-1){if(!cpuSetPair(S,b,w)){bad=true;break;}ch=true;}else if(S[b]!=w){bad=true;break;}}
                if(S[b]!=-1){int w=cpuNp(S[b],thino,pL[i],pM[i],pR[i],rrr,rmid,tr,lr,mr,rr,rf);
                    if(S[a]==-1){if(!cpuSetPair(S,a,w)){bad=true;break;}ch=true;}else if(S[a]!=w){bad=true;break;}}
            }
        }
        if(!bad){ for(int i=0;i<26;i++) outS[i]=(S[i]==-1)?i:S[i]; return true; }
    }
    return false;
}

// Coverage by known phrases (matched language model for the synthetic corpus):
// fraction of letters covered by one of the 27 phrases as a substring. Correct plaintext ~1.0.
static double phraseCoverage(const std::string& p){
    int n=(int)p.size(); if(n==0) return 0.0;
    std::vector<char> cov(n,0);
    for(int s=0;s<NPHRASES;s++){
        std::string ph=PHRASES[s]; size_t pos=0;
        while((pos=p.find(ph,pos))!=std::string::npos){
            for(size_t k=0;k<ph.size();k++) cov[pos+k]=1; pos++;
        }
    }
    int c=0; for(int i=0;i<n;i++) c+=cov[i]; return (double)c/n;
}
// Quadgram over X-segments: split on 'X' (space), score each segment >=4.
// Smooth (every correct pair raises the score) AND X-aware (rewards correct segmentation)
// -> avoids both the plateau (coverage) and X-bias (a plain quadgram prefers the X<->A substitution).
static float scoreXsplit(const std::string& p, const QuadgramScorer& qg){
    float s=0.f; size_t i=0,n=p.size();
    while(i<n){
        size_t j=i; while(j<n && p[j]!='X') j++;
        if(j-i>=4) s+=qg.score(p.substr(i,j-i));
        i=j+1;
    }
    return s;
}
// #5: Trigram over X-segments (segment >=3). A smaller/denser table than the quadgram ->
// more robust on SHORT messages; the same X-aware split (avoids X<->A bias, finding D).
static float scoreXsplitTri(const std::string& p, const TrigramScorer& tg){
    float s=0.f; size_t i=0,n=p.size();
    while(i<n){
        size_t j=i; while(j<n && p[j]!='X') j++;
        if(j-i>=3) s+=tg.score(p.substr(i,j-i));
        i=j+1;
    }
    return s;
}
// Index of Coincidence: parameter-free, allocation-free cheap signal of "Germanness".
// German ~0.076, random ~0.0385 (see the enigma_ioc_thresholds memo). Used
// as a cheap pre-filter (rank ring_mid / rotor settings before the expensive hillclimb) and
// as a primitive for blind mode. Does NOT discriminate rotor config on the NO-PLUG output (finding A).
static double iocScore(const std::string& p){
    int n=(int)p.size(); if(n<2) return 0.0;
    long long f[26]={0};
    for(char ch:p){ if(ch>='A'&&ch<='Z') f[ch-'A']++; }
    long long s=0; for(int i=0;i<26;i++) s+=f[i]*(f[i]-1);
    return (double)s/((double)n*(n-1));
}
// #6: Fast plug evaluator. The rotor+reflector permutation BY POSITION is independent
// of the plugboard, so we precompute it ONCE per key (cpuStep+cpuNp mirror,
// the same thing EnigmaCPU does). After that, decryption is an O(N) lookup: out=plug[P_i[plug[c]]],
// instead of ~8 rotor passes per character => the hillclimb (hundreds of evals per key) is ~much faster.
// Assumption: thin/left ring = 0 (cpuNp hardcodes them to 0; reconstruction always keeps them that way).
struct FastEval {
    int N=0; std::vector<unsigned char> P;            // N*26 (no-plug permutation by position)
    void build(const EnigmaKey& k,int n){
        N=n; P.resize((size_t)n*26);
        int tr=k.rotor[0],lr=k.rotor[1],mr=k.rotor[2],rr=k.rotor[3],rf=k.reflector;
        int rrr=k.ring[3], rmid=k.ring[2];
        int p[4]={k.position[0],k.position[1],k.position[2],k.position[3]};
        for(int i=0;i<n;i++){
            cpuStep(p,mr,rr);                          // step BEFORE encryption (like EnigmaCPU)
            unsigned char* Pi=&P[(size_t)i*26];
            for(int x=0;x<26;x++) Pi[x]=(unsigned char)cpuNp(x,p[0],p[1],p[2],p[3],rrr,rmid,tr,lr,mr,rr,rf);
        }
    }
    void decode(const std::string& ct,const int* plug,std::string& out) const {
        out.resize(ct.size());
        for(size_t i=0;i<ct.size();i++){
            int c=ct[i]-'A'; out[i]=(char)('A'+plug[ P[i*26 + plug[c]] ]);
        }
    }
};
// Plugboard steepest-ascent by PHRASE COVERAGE (X-aware, without X-bias),
// seeded from the partial S (bombe). Plateau (when >=2 pairs are missing) is resolved by xSolve restarts.
static double covHillClimb(const EnigmaKey& base,const std::string& ct,int* plug,const QuadgramScorer& qg){
    (void)qg;
    FastEval fe; fe.build(base,(int)ct.size());        // #6: precompute once per key
    std::string buf;
    auto eval=[&](int* pg)->double{ fe.decode(ct,pg,buf); return phraseCoverage(buf); };
    double cur=eval(plug);
    bool imp=true; int tmp[26],best[26];
    while(imp){
        imp=false; copyPlug(plug,best); double bc=cur;
        int fr[26],nf=0; for(int i=0;i<26;i++) if(plug[i]==i) fr[nf++]=i;
        // ADD pair
        for(int a=0;a<nf;a++) for(int b=a+1;b<nf;b++){
            copyPlug(plug,tmp); tmp[fr[a]]=fr[b]; tmp[fr[b]]=fr[a];
            double v=eval(tmp); if(v>bc){bc=v;copyPlug(tmp,best);} }
        // REMOVE pair + SWAP end
        for(int i=0;i<26;i++) if(plug[i]>i){ int a=i,b=plug[i];
            copyPlug(plug,tmp); tmp[a]=a; tmp[b]=b;
            double v=eval(tmp); if(v>bc){bc=v;copyPlug(tmp,best);}
            for(int c=0;c<nf;c++){ int f=fr[c];
                copyPlug(plug,tmp); tmp[a]=a;tmp[b]=b; tmp[a]=f;tmp[f]=a;
                v=eval(tmp); if(v>bc){bc=v;copyPlug(tmp,best);}
                copyPlug(plug,tmp); tmp[a]=a;tmp[b]=b; tmp[b]=f;tmp[f]=b;
                v=eval(tmp); if(v>bc){bc=v;copyPlug(tmp,best);} } }
        if(bc>cur){cur=bc;copyPlug(best,plug);imp=true;}
    }
    return cur;
}

// Completion with restarts around the bombe-S: escapes the plateau when more pairs are missing (short crib).
static double xSolve(const EnigmaKey& base,const std::string& ct,const int* seedS,
                     const QuadgramScorer& qg,int* outBest,int restarts){
    std::mt19937 rng(1942);
    int cur[26]; copyPlug(seedS,cur);
    double bestsc=covHillClimb(base,ct,cur,qg);
    copyPlug(cur,outBest);
    for(int r=1;r<restarts;r++){
        copyPlug(seedS,cur);
        int fr[26],nf=0; for(int i=0;i<26;i++) if(cur[i]==i) fr[nf++]=i;
        if(nf>=2){
            for(int i=nf-1;i>0;i--){int j=rng()%(i+1);int t=fr[i];fr[i]=fr[j];fr[j]=t;}
            int k=1+(int)(rng()%(unsigned)std::max(1,nf/2));
            for(int i=0;i<k && 2*i+1<nf;i++){int a=fr[2*i],b=fr[2*i+1];cur[a]=b;cur[b]=a;}
        }
        double sc=covHillClimb(base,ct,cur,qg);
        if(sc>bestsc){bestsc=sc;copyPlug(cur,outBest);}
    }
    return bestsc;
}

int main(int argc,char* argv[]){
    const char* dataDir=(argc>1)?argv[1]:"data";
    const char* ctFile =(argc>2 && argv[2][0])?argv[2]:nullptr;
    int wheelStart=(argc>3)?atoi(argv[3]):0;
    int wheelCount=(argc>4)?atoi(argv[4]):-1;
    auto _wall0=std::chrono::high_resolution_clock::now();
    // R6 flag (anywhere in argv): enables the 6th dimension ring_mid (26^6, ~26x slower, ~100% accuracy).
    // "R6" must not be interpreted as a crib, so we strip it out of argv before fixedCrib.
    bool r6=false, triMode=false;
    for(int i=1;i<argc;i++){
        if(strcmp(argv[i],"R6")==0||strcmp(argv[i],"r6")==0) r6=true;
        if(strcmp(argv[i],"TRI")==0||strcmp(argv[i],"tri")==0) triMode=true;
    }
    const char* a5=(argc>5 && argv[5][0])?argv[5]:nullptr;
    if(a5 && (strcmp(a5,"R6")==0||strcmp(a5,"r6")==0||strcmp(a5,"TRI")==0||strcmp(a5,"tri")==0)) a5=nullptr;
    const char* fixedCrib=a5;                                       // for measuring the length threshold
    const int ringMidSpan = r6?26:1;

    printf("=============================================================\n");
    printf("  ENIGMA M4 CRIB SOLVER - GPU Turing bombe\n");
    printf("=============================================================\n\n");
    cudaDeviceProp prop; CUDA_CHECK(cudaGetDeviceProperties(&prop,0));
    printf("GPU : %s\n",prop.name);
    printf("Mode: %s (ring_mid span=%d, %s settings/wheel-order)  scorer=%s\n\n",
           r6?"R6 (26^6 turnover-aware)":"standard (26^5)", ringMidSpan,
           r6?"308.9M":"11.9M", triMode?"TRIGRAM-Xsplit":"QUADGRAM-Xsplit");

    char qgp[512]; snprintf(qgp,sizeof(qgp),"%s/german_quadgrams.txt",dataDir);
    static QuadgramScorer qg;
    if(!qg.load(qgp)){fprintf(stderr,"ERROR quadgram: %s\n",qgp);return 1;}
    char tgp[512]; snprintf(tgp,sizeof(tgp),"%s/german_trigrams.txt",dataDir);
    static TrigramScorer tg;
    if(!tg.load(tgp)){fprintf(stderr,"ERROR trigram: %s\n",tgp);return 1;}
    uploadWirings();
    cpuBuildWiring();

    std::string ct;
    if(ctFile){ FILE* f=fopen(ctFile,"r"); if(!f){fprintf(stderr,"ERROR: %s\n",ctFile);return 1;}
        int c; while((c=fgetc(f))!=EOF) if(c>='A'&&c<='Z') ct+=(char)c; fclose(f);
    } else { fprintf(stderr,"Provide ciphertext file as 2nd arg.\n"); return 1; }
    int clen=(int)ct.size();
    printf("Ciphertext (%d): %.50s...\n\n",clen,ct.c_str());

    // ---- Step 1: cribs ----
    // Three modes (argv[5]):
    //   (empty)   Phrase mode: 26 corpus phrases at offset 0 (synthetic test_messages set).
    //   "DICT"    Dict mode: dictionary (corpus phrases + general German cribs), each DRAGGED
    //             across all positions until one breaks (for REAL messages with unknown content).
    //   <word>    General mode: that single word DRAGGED across all positions (option B).
    bool dictMode = (fixedCrib && strcmp(fixedCrib,"DICT")==0);
    bool general  = (fixedCrib!=nullptr) && !dictMode;
    std::vector<std::string> cribs;
    if(dictMode){
        for(int p=0;p<NPHRASES;p++)     cribs.push_back(PHRASES[p]);
        for(int p=0;p<NDICT_EXTRA;p++)  cribs.push_back(DICT_EXTRA[p]);
        std::sort(cribs.begin(),cribs.end(),
                  [](const std::string&a,const std::string&b){return a.size()>b.size();});  // longest first
        general=true;   // every crib is dragged across positions
        printf("[Dict mode] %zu cribs from dictionary, dragged over all positions.\n\n",cribs.size());
    }
    else if(general){ cribs.push_back(fixedCrib);
        printf("[General crib] \"%s\" (L=%zu) - dragged over all positions\n\n",fixedCrib,strlen(fixedCrib)); }
    else {
        for(int p=0;p<NPHRASES;p++){
            const char* ph=PHRASES[p]; int n=(int)strlen(ph); bool clash=false;
            for(int i=0;i<n&&i<clen;i++) if(ph[i]==ct[i]){clash=true;break;}
            if(!clash) cribs.push_back(ph);
        }
        std::sort(cribs.begin(),cribs.end(),
                  [](const std::string&a,const std::string&b){return a.size()>b.size();});
        printf("[Step 1] %zu/%d phrases survived (offset 0).\n\n",cribs.size(),NPHRASES);
    }

    auto cfgs=buildConfigs(); int ncfg=(int)cfgs.size();
    if(wheelCount<0) wheelCount=ncfg-wheelStart;
    int wheelEnd=std::min(ncfg,wheelStart+wheelCount);

    std::vector<unsigned char> cbf(clen);              // whole cipher as 0-25 (for drag + verify)
    for(int i=0;i<clen;i++) cbf[i]=(unsigned char)(ct[i]-'A');
    unsigned char *d_crib,*d_ct;
    CUDA_CHECK(cudaMalloc(&d_crib,MAXL));
    CUDA_CHECK(cudaMalloc(&d_ct,clen));                 // whole cipher on the GPU
    CUDA_CHECK(cudaMemcpy(d_ct,cbf.data(),clen,cudaMemcpyHostToDevice));
    int *d_cw,*d_ctid,*d_cc; const int MAXCAND=(ringMidSpan>1)?65536:8192;
    CUDA_CHECK(cudaMalloc(&d_cw,MAXCAND*4));
    CUDA_CHECK(cudaMalloc(&d_ctid,MAXCAND*4));
    CUDA_CHECK(cudaMalloc(&d_cc,4));
    int blk=256; long long total=(long long)ROT5*ringMidSpan; long long grid=(total+blk-1)/blk;

    bool solved=false;
    for(size_t ci=0; ci<cribs.size() && !solved; ci++){
        std::string cs=cribs[ci];
        int L=std::min((int)cs.size(),MAXL);
        unsigned char hc[MAXL];
        for(int i=0;i<L;i++) hc[i]=(unsigned char)(cs[i]-'A');
        CUDA_CHECK(cudaMemcpy(d_crib,hc,L,cudaMemcpyHostToDevice));

        std::vector<int> offs;                          // positions to try
        if(general){ for(int off=0; off+L<=clen; off++){ bool clash=false;
            for(int i=0;i<L;i++) if(hc[i]==cbf[off+i]){clash=true;break;}
            if(!clash) offs.push_back(off); } }
        else offs.push_back(0);
        printf("[Crib %zu/%zu] \"%.30s\" (L=%d) - %zu positions (no-clash)\n",
               ci+1,cribs.size(),cs.c_str(),L,offs.size());

        for(size_t oi=0; oi<offs.size() && !solved; oi++){
            int off=offs[oi];
            CUDA_CHECK(cudaMemset(d_cc,0,4));
            auto t0=std::chrono::high_resolution_clock::now();
            for(int w=wheelStart; w<wheelEnd; w++){ auto&c=cfgs[w];
                bombeKernel<<<(unsigned)grid,blk>>>(d_crib,d_ct+off,L,off,
                    c.thin_r,c.left_r,c.mid_r,c.right_r,c.reflector,w,
                    ringMidSpan,total,
                    d_cw,d_ctid,d_cc,MAXCAND); }
            CUDA_CHECK(cudaDeviceSynchronize()); CUDA_CHECK(cudaGetLastError());
            auto t1=std::chrono::high_resolution_clock::now();
            int cc; CUDA_CHECK(cudaMemcpy(&cc,d_cc,4,cudaMemcpyDeviceToHost));
            double s=std::chrono::duration<double>(t1-t0).count();
            printf("  off=%d: bombe candidates %d  (%.1f s)\n",off,cc,s);
            if(cc==0) continue;
            int ncand=std::min(cc,MAXCAND);
            std::vector<int> cw(ncand),ctid(ncand);
            CUDA_CHECK(cudaMemcpy(cw.data(),d_cw,ncand*4,cudaMemcpyDeviceToHost));
            CUDA_CHECK(cudaMemcpy(ctid.data(),d_ctid,ncand*4,cudaMemcpyDeviceToHost));

            double bestCov=-1.0; float bestX=-1e30f; EnigmaKey bestKey; std::string bestPlain; bool haveBest=false;
            struct Lead{float q;int wheel;int t;int S[26];int rm[RMK];};   // #7: rm[] = top-RMK ring_mid
            std::vector<Lead> leads;
            int proc=std::min(ncand,2000);
            long long base=676LL*ringMidSpan;
            for(int k=0;k<proc;k++){
                int t=ctid[k]; auto&c=cfgs[cw[k]];
                int rrr=t%26, posR=(t/26)%26;
                int ringMid=(t/676)%ringMidSpan;
                int mido=(int)((t/base)%26), lefto=(int)((t/(base*26))%26), thino=(int)((t/(base*676))%26);
                int offMid=(mido-ringMid+26)%26;            // mid wiring offset (window - ring)
                int S[26];
                if(!cpuBombe(hc,cbf.data(),L,off,thino,lefto,mido,posR,rrr,ringMid,
                             c.thin_r,c.left_r,c.mid_r,c.right_r,c.reflector,S)) continue;
                // #7: score all 26 ring_mid values (cheap decode+scoreXsplit, WITHOUT hillclimb),
                //     then remember the top-RMK -> only those go into the expensive xSolve in loop B.
                float qrm[26];
                for(int rm=0;rm<26;rm++){
                    EnigmaKey key; key.rotor[0]=c.thin_r;key.rotor[1]=c.left_r;key.rotor[2]=c.mid_r;key.rotor[3]=c.right_r;
                    key.reflector=c.reflector; key.ring[0]=0;key.ring[1]=0;key.ring[2]=rm;key.ring[3]=rrr;
                    key.position[0]=thino;key.position[1]=lefto;key.position[2]=(offMid+rm)%26;key.position[3]=posR;
                    copyPlug(S,key.plugboard);
                    EnigmaCPU sim(key); std::string txt=sim.process(ct);
                    qrm[rm]= triMode ? scoreXsplitTri(txt,tg) : scoreXsplit(txt,qg);
                }
                int idx[26]; for(int i=0;i<26;i++) idx[i]=i;
                std::partial_sort(idx,idx+RMK,idx+26,[&](int a,int b){return qrm[a]>qrm[b];});
                Lead ld; ld.q=qrm[idx[0]]; ld.wheel=cw[k]; ld.t=t; copyPlug(S,ld.S);
                for(int i=0;i<RMK;i++) ld.rm[i]=idx[i];
                leads.push_back(ld);
            }
            std::sort(leads.begin(),leads.end(),[](const Lead&a,const Lead&b){return a.q>b.q;});
            int K=std::min((int)leads.size(),8);
            for(int j=0;j<K;j++){
                Lead&ld=leads[j]; auto&c=cfgs[ld.wheel];
                int t=ld.t; int rrr=t%26, posR=(t/26)%26;
                int ringMid=(t/676)%ringMidSpan;
                int mido=(int)((t/base)%26), lefto=(int)((t/(base*26))%26), thino=(int)((t/(base*676))%26);
                int offMid=(mido-ringMid+26)%26;
                for(int ri=0; ri<RMK; ri++){               // #7: only top-RMK ring_mid (pre-filter)
                    int rm=ld.rm[ri];
                    EnigmaKey key; key.rotor[0]=c.thin_r;key.rotor[1]=c.left_r;key.rotor[2]=c.mid_r;key.rotor[3]=c.right_r;
                    key.reflector=c.reflector; key.ring[0]=0;key.ring[1]=0;key.ring[2]=rm;key.ring[3]=rrr;
                    key.position[0]=thino;key.position[1]=lefto;key.position[2]=(offMid+rm)%26;key.position[3]=posR;
                    int plug[26];
                    double cov=xSolve(key,ct,ld.S,qg,plug,8);
                    EnigmaKey kk=key; copyPlug(plug,kk.plugboard);
                    EnigmaCPU sim(kk); std::string pl=sim.process(ct);
                    if((float)cov>bestX){bestX=(float)cov;bestKey=kk;bestPlain=pl;haveBest=true;}
                }
            }
            if(haveBest){   // re-sweep ring_mid by quadgram (see id=7 fix)
                int mido=(bestKey.position[2]-bestKey.ring[2]+26)%26;
                float bestq=-1e30f; EnigmaKey bk=bestKey; std::string bp=bestPlain;
                for(int rm=0;rm<26;rm++){
                    EnigmaKey key=bestKey; key.ring[2]=rm; key.position[2]=(mido+rm)%26;
                    EnigmaCPU sim(key); std::string pl=sim.process(ct);
                    float q= triMode ? tg.score(pl) : qg.score(pl);
                    if(q>bestq){bestq=q;bk=key;bp=pl;}
                }
                bestKey=bk; bestPlain=bp; bestCov=phraseCoverage(bestPlain);
            }
            float qgpc = haveBest ? qg.score(bestPlain)/(clen-3) : -99.0f;
            float tgpc = haveBest ? tg.score(bestPlain)/(clen-2) : -99.0f;
            double ioc = haveBest ? iocScore(bestPlain) : 0.0;
            printf("    coverage %.1f%%  qg/char %.3f  tg/char %.3f  IoC %.4f\n",
                   haveBest?bestCov*100.0:0.0,qgpc,tgpc,ioc); fflush(stdout);
            if(bestCov > 0.7){
                solved=true;
                static const char* RN[]={"I","II","III","IV","V","VI","VII","VIII"};
                static const char* TN[]={"Beta","Gamma"}; static const char* RF[]={"B","C"};
                printf("\n=== SOLVED (crib at offset %d) ===\n",off);
                printf("  Reflector : %s\n",RF[bestKey.reflector]);
                printf("  Wheels    : %s %s %s %s\n",TN[bestKey.rotor[0]],RN[bestKey.rotor[1]],RN[bestKey.rotor[2]],RN[bestKey.rotor[3]]);
                printf("  Rings     : %d %d %d %d\n",bestKey.ring[0],bestKey.ring[1],bestKey.ring[2],bestKey.ring[3]);
                printf("  Positions : %d %d %d %d\n",bestKey.position[0],bestKey.position[1],bestKey.position[2],bestKey.position[3]);
                printf("  Plugboard : %s\n",plugToStr(bestKey.plugboard).c_str());
                printf("  Plaintext : %s\n",bestPlain.c_str());
            }
        }
    }
    if(!solved) printf("\nNot solved in the given range.\n");
    printf("\n  Elapsed (wall-clock): %.1f s\n",
        std::chrono::duration<double>(std::chrono::high_resolution_clock::now()-_wall0).count());
    return solved?0:1;
}
