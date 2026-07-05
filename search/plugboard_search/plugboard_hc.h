#pragma once
// Plugboard hill-climbing (inline — safe to include in both .cu and .cpp)
#include <cstring>
#include <numeric>
#include <vector>
#include <algorithm>
#include <random>
#include "config.h"
#include "core/enigma_cpu/enigma_cpu.h"
#include "filters/quadgram/quadgram_score.h"

inline void initPlug(int p[26]){for(int i=0;i<26;i++)p[i]=i;}
inline void copyPlug(const int s[26],int d[26]){memcpy(d,s,26*sizeof(int));}
inline int  countPairs(const int p[26]){int n=0;for(int i=0;i<26;i++)if(p[i]>i)n++;return n;}

inline void getFreeAndPairs(const int plug[26],
                             int* fr,int& nfr,int pairs[][2],int& npairs){
    nfr=0;npairs=0;
    for(int i=0;i<26;i++){
        if(plug[i]==i)fr[nfr++]=i;
        else if(plug[i]>i){pairs[npairs][0]=i;pairs[npairs][1]=plug[i];npairs++;}
    }
}

inline float scoreWithPlug(const EnigmaKey& base,const int plug[26],
                             const char* cipher,int len,const QuadgramScorer& qg){
    EnigmaKey key=base; copyPlug(plug,key.plugboard);
    EnigmaCPU sim(key);
    return qg.score(sim.process(std::string(cipher,len)));
}

inline bool steepestStep(const EnigmaKey& base,int cur[26],float& cur_sc,
                          const char* cipher,int len,const QuadgramScorer& qg,int max_p=10){
    int fr[26],nfr,pairs[13][2],np; getFreeAndPairs(cur,fr,nfr,pairs,np);
    int best[26]; copyPlug(cur,best); float bsc=cur_sc; int tmp[26];

    if(np<max_p)
        for(int ia=0;ia<nfr;ia++) for(int ib=ia+1;ib<nfr;ib++){
            copyPlug(cur,tmp);tmp[fr[ia]]=fr[ib];tmp[fr[ib]]=fr[ia];
            float s=scoreWithPlug(base,tmp,cipher,len,qg);
            if(s>bsc){bsc=s;copyPlug(tmp,best);}
        }
    for(int ip=0;ip<np;ip++){
        int a=pairs[ip][0],b=pairs[ip][1];
        copyPlug(cur,tmp);tmp[a]=a;tmp[b]=b;
        float s=scoreWithPlug(base,tmp,cipher,len,qg);if(s>bsc){bsc=s;copyPlug(tmp,best);}
        for(int ic=0;ic<nfr;ic++){
            int c=fr[ic];
            {copyPlug(cur,tmp);tmp[a]=c;tmp[c]=a;tmp[b]=b;
             float s=scoreWithPlug(base,tmp,cipher,len,qg);if(s>bsc){bsc=s;copyPlug(tmp,best);}}
            {copyPlug(cur,tmp);tmp[b]=c;tmp[c]=b;tmp[a]=a;
             float s=scoreWithPlug(base,tmp,cipher,len,qg);if(s>bsc){bsc=s;copyPlug(tmp,best);}}
        }
    }
    for(int ip=0;ip<np;ip++){
        int a=pairs[ip][0],b=pairs[ip][1];
        for(int ia=0;ia<nfr;ia++) for(int ib=ia+1;ib<nfr;ib++){
            copyPlug(cur,tmp);tmp[a]=a;tmp[b]=b;
            tmp[fr[ia]]=fr[ib];tmp[fr[ib]]=fr[ia];
            float s=scoreWithPlug(base,tmp,cipher,len,qg);if(s>bsc){bsc=s;copyPlug(tmp,best);}
        }
    }
    if(bsc>cur_sc){copyPlug(best,cur);cur_sc=bsc;return true;}
    return false;
}

inline bool twoOptRefine(const EnigmaKey& base,int plug[26],float& sc,
                          const char* cipher,int len,const QuadgramScorer& qg){
    bool any=false,improved=true;
    while(improved){
        improved=false;
        int fr[26],nfr,pairs[13][2],np; getFreeAndPairs(plug,fr,nfr,pairs,np);
        int tmp[26];
        for(int i=0;i<np&&!improved;i++) for(int j=i+1;j<np&&!improved;j++){
            int a=pairs[i][0],b=pairs[i][1],c=pairs[j][0],d=pairs[j][1];
            {copyPlug(plug,tmp);tmp[a]=c;tmp[c]=a;tmp[b]=d;tmp[d]=b;
             float s=scoreWithPlug(base,tmp,cipher,len,qg);
             if(s>sc){sc=s;copyPlug(tmp,plug);improved=true;any=true;}}
            if(!improved){
            copyPlug(plug,tmp);tmp[a]=d;tmp[d]=a;tmp[b]=c;tmp[c]=b;
             float s=scoreWithPlug(base,tmp,cipher,len,qg);
             if(s>sc){sc=s;copyPlug(tmp,plug);improved=true;any=true;}}
        }
    }
    return any;
}

struct PlugResult { int plug[26]; float score; };

inline PlugResult hillClimb(const EnigmaKey& base,const char* cipher,int len,
                              const QuadgramScorer& qg,
                              int max_pairs=10,int restarts=30,unsigned seed=1942){
    std::mt19937 rng(seed);
    PlugResult best; initPlug(best.plug); best.score=-1e30f;

    for(int r=0;r<restarts;r++){
        int cur[26]; float csc;
        if(r==0){initPlug(cur);}
        else{
            initPlug(cur);
            std::vector<int> v(26); std::iota(v.begin(),v.end(),0);
            std::shuffle(v.begin(),v.end(),rng);
            int ip=std::min(max_pairs,(r<10?r%5+1:(int)(rng()%max_pairs+1)));
            for(int i=0;i<ip;i++){cur[v[2*i]]=v[2*i+1];cur[v[2*i+1]]=v[2*i];}
        }
        csc=scoreWithPlug(base,cur,cipher,len,qg);
        while(steepestStep(base,cur,csc,cipher,len,qg,max_pairs)){}
        twoOptRefine(base,cur,csc,cipher,len,qg);
        if(csc>best.score){best.score=csc;copyPlug(cur,best.plug);}
    }
    return best;
}

inline std::string plugToStr(const int p[26]){
    std::string s;
    for(int i=0;i<26;i++) if(p[i]>i){
        if(!s.empty())s+=' ';
        s+=(char)('A'+i); s+=(char)('A'+p[i]);
    }
    return s;
}
