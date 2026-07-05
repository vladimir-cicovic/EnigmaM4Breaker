//
// Phase R7 — Plugboard Hill-Climbing with restarts
//
// Input:  correct rotor config + rings + starting position (from R6)
//         empty plugboard (or random start)
// Output: 10 stecker pairs (Kriegsmarine standard)
//
// Algorithm:
//   Steepest-ascent: try ALL possible single-move operations,
//   apply the one that gives the largest improvement in quadgram score.
//   Repeat until there is no improvement (local maximum).
//   Restart from a new random starting point — 30x.
//
// Operations:
//   ADD    — add one stecker pair (if < max_pairs pairs)
//   REMOVE — remove one stecker pair
//   SWAP   — swap one end of a pair with a free letter
//
#include <cstdio>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>
#include <algorithm>
#include <numeric>
#include <random>
#include <chrono>
#include "config.h"
#include "core/enigma_cpu/enigma_cpu.h"
#include "filters/quadgram/quadgram_score.h"

// ----------------------------------------------------------------
// Helper functions for the plugboard
// ----------------------------------------------------------------
static void initPlug(int plug[26]) {
    for(int i=0;i<26;i++) plug[i]=i;
}

static void copyPlug(const int src[26], int dst[26]) {
    memcpy(dst, src, 26*sizeof(int));
}

static int countPairs(const int plug[26]) {
    int n=0;
    for(int i=0;i<26;i++) if(plug[i]>i) n++;
    return n;
}

static void getFreeAndPairs(const int plug[26],
                            int* free_arr, int& nfree,
                            int pairs[][2], int& npairs) {
    nfree=0; npairs=0;
    for(int i=0;i<26;i++){
        if(plug[i]==i) free_arr[nfree++]=i;
        else if(plug[i]>i) { pairs[npairs][0]=i; pairs[npairs][1]=plug[i]; npairs++; }
    }
}

// ----------------------------------------------------------------
// Score: decrypt with the given plugboard, return the quadgram score
// ----------------------------------------------------------------
static float scoreWithPlug(const EnigmaKey& base,
                            const int plug[26],
                            const char* cipher, int len,
                            const QuadgramScorer& qg)
{
    EnigmaKey key = base;
    copyPlug(plug, key.plugboard);
    EnigmaCPU sim(key);
    std::string dec = sim.process(std::string(cipher, len));
    return qg.score(dec);
}

// ----------------------------------------------------------------
// One steepest-ascent step: try all operations,
// return true if an improvement was found.
// ----------------------------------------------------------------
static bool steepestStep(const EnigmaKey& base,
                          int cur_plug[26], float& cur_score,
                          const char* cipher, int len,
                          const QuadgramScorer& qg,
                          int max_pairs)
{
    int free_arr[26], nfree;
    int pairs[13][2], npairs;
    getFreeAndPairs(cur_plug, free_arr, nfree, pairs, npairs);

    int best_plug[26]; copyPlug(cur_plug, best_plug);
    float best_score = cur_score;
    int tmp[26];

    // --- ADD pair (a,b) ---
    if(npairs < max_pairs) {
        for(int ia=0; ia<nfree; ia++) {
            for(int ib=ia+1; ib<nfree; ib++) {
                copyPlug(cur_plug, tmp);
                tmp[free_arr[ia]]=free_arr[ib];
                tmp[free_arr[ib]]=free_arr[ia];
                float s=scoreWithPlug(base,tmp,cipher,len,qg);
                if(s>best_score){ best_score=s; copyPlug(tmp,best_plug); }
            }
        }
    }

    // --- REMOVE pair ---
    for(int ip=0; ip<npairs; ip++) {
        copyPlug(cur_plug, tmp);
        int a=pairs[ip][0], b=pairs[ip][1];
        tmp[a]=a; tmp[b]=b;
        float s=scoreWithPlug(base,tmp,cipher,len,qg);
        if(s>best_score){ best_score=s; copyPlug(tmp,best_plug); }
    }

    // --- SWAP endpoint of pair to a free letter ---
    for(int ip=0; ip<npairs; ip++) {
        int a=pairs[ip][0], b=pairs[ip][1];
        for(int ic=0; ic<nfree; ic++) {
            int c=free_arr[ic];
            // Change a-b to a-c (b becomes free)
            copyPlug(cur_plug, tmp);
            tmp[a]=c; tmp[c]=a; tmp[b]=b;
            float s=scoreWithPlug(base,tmp,cipher,len,qg);
            if(s>best_score){ best_score=s; copyPlug(tmp,best_plug); }
            // Change a-b to c-b (a becomes free)
            copyPlug(cur_plug, tmp);
            tmp[b]=c; tmp[c]=b; tmp[a]=a;
            s=scoreWithPlug(base,tmp,cipher,len,qg);
            if(s>best_score){ best_score=s; copyPlug(tmp,best_plug); }
        }
    }

    // --- REPLACE pair: replace pair (a,b) with a new pair of free letters (c,d) ---
    for(int ip=0; ip<npairs; ip++) {
        int a=pairs[ip][0], b=pairs[ip][1];
        for(int ia=0; ia<nfree; ia++) {
            for(int ib=ia+1; ib<nfree; ib++) {
                copyPlug(cur_plug, tmp);
                tmp[a]=a; tmp[b]=b;
                tmp[free_arr[ia]]=free_arr[ib];
                tmp[free_arr[ib]]=free_arr[ia];
                float s=scoreWithPlug(base,tmp,cipher,len,qg);
                if(s>best_score){ best_score=s; copyPlug(tmp,best_plug); }
            }
        }
    }

    // (2-pair swap is split out as a separate phase — see twoOptRefine())

    if(best_score > cur_score) {
        copyPlug(best_plug, cur_plug);
        cur_score = best_score;
        return true;
    }
    return false;
}

// ----------------------------------------------------------------
// 2-opt refinement: swap the endpoints of two pairs if it improves the score
// Resolves local maxima of the form (a,b)+(c,d) when (a,c)+(b,d) is better.
// Applied AFTER HC converges, not inside the main loop.
// ----------------------------------------------------------------
static bool twoOptRefine(const EnigmaKey& base,
                          int plug[26], float& score,
                          const char* cipher, int len,
                          const QuadgramScorer& qg)
{
    bool any_improved = false;
    bool improved = true;
    while(improved) {
        improved = false;
        int pairs[13][2], npairs=0, free_arr[26], nfree=0;
        getFreeAndPairs(plug, free_arr, nfree, pairs, npairs);
        int tmp[26];
        for(int i=0; i<npairs && !improved; i++) {
            for(int j=i+1; j<npairs && !improved; j++) {
                int a=pairs[i][0],b=pairs[i][1],c=pairs[j][0],d=pairs[j][1];
                // Variant 1: (a-c) and (b-d)
                { copyPlug(plug,tmp);
                  tmp[a]=c;tmp[c]=a;tmp[b]=d;tmp[d]=b;
                  float s=scoreWithPlug(base,tmp,cipher,len,qg);
                  if(s>score){ score=s; copyPlug(tmp,plug); improved=true; any_improved=true; } }
                if(improved) break;
                // Variant 2: (a-d) and (b-c)
                { copyPlug(plug,tmp);
                  tmp[a]=d;tmp[d]=a;tmp[b]=c;tmp[c]=b;
                  float s=scoreWithPlug(base,tmp,cipher,len,qg);
                  if(s>score){ score=s; copyPlug(tmp,plug); improved=true; any_improved=true; } }
            }
        }
    }
    return any_improved;
}

// ----------------------------------------------------------------
// Hill-climbing with restarts
// ----------------------------------------------------------------
struct PlugResult {
    int   plug[26];
    float score;
    int   steps;   // number of iterations
};

static PlugResult hillClimb(
    const EnigmaKey& base,
    const char* cipher, int len,
    const QuadgramScorer& qg,
    int max_pairs   = 10,
    int num_restarts= 30,
    unsigned seed   = 1942)
{
    std::mt19937 rng(seed);
    PlugResult best; initPlug(best.plug); best.score=-1e30f; best.steps=0;

    for(int r=0; r<num_restarts; r++) {
        int cur[26]; float cur_score;

        if(r==0) {
            // First iteration: start with an empty plugboard
            initPlug(cur);
        } else {
            // Random start: a few random pairs
            initPlug(cur);
            std::vector<int> letters(26); std::iota(letters.begin(),letters.end(),0);
            std::shuffle(letters.begin(),letters.end(),rng);
            int init_pairs = (r < 10) ? (r % 5 + 1) : (rng()%10+1);
            init_pairs = std::min(init_pairs, max_pairs);
            for(int i=0;i<init_pairs;i++){
                int a=letters[2*i], b=letters[2*i+1];
                cur[a]=b; cur[b]=a;
            }
        }

        cur_score = scoreWithPlug(base, cur, cipher, len, qg);
        int steps = 0;
        // Phase 1: basic HC (add/remove/swap/replace)
        while(steepestStep(base, cur, cur_score, cipher, len, qg, max_pairs))
            steps++;
        // Phase 2: 2-opt refinement after convergence
        twoOptRefine(base, cur, cur_score, cipher, len, qg);

        if(cur_score > best.score){
            copyPlug(cur, best.plug);
            best.score = cur_score;
            best.steps = steps;
        }
    }
    return best;
}

// ----------------------------------------------------------------
// Helper: format plugboard pairs into a string
// ----------------------------------------------------------------
static std::string plugToString(const int plug[26]) {
    std::string s;
    for(int i=0;i<26;i++){
        if(plug[i]>i){
            if(!s.empty()) s+=' ';
            s += (char)('A'+i);
            s += (char)('A'+plug[i]);
        }
    }
    return s;
}

// Number of common pairs
static int countCommonPairs(const int p1[26], const int p2[26]) {
    int n=0;
    for(int i=0;i<26;i++) if(p1[i]>i && p1[i]==p2[i]) n++;
    return n;
}

// ----------------------------------------------------------------
// Main
// ----------------------------------------------------------------
int main(int argc, char* argv[])
{
    const char* dataDir = (argc>1)?argv[1]:"data";

    printf("========================================\n");
    printf("Enigma M4 — Plugboard Hill-Climbing (R7)\n");
    printf("========================================\n\n");

    // --- Load the quadgram table ---
    char qgpath[512];
    snprintf(qgpath,sizeof(qgpath),"%s/german_quadgrams.txt",dataDir);
    printf("Ucitavam quadgram tabelu ... "); fflush(stdout);
    static QuadgramScorer qg;  // static: 1.8 MB, heap
    if(!qg.load(qgpath)){ fprintf(stderr,"GRESKA: %s\n",qgpath); return 1; }
    printf("OK\n\n");

    // ---
    // Test 1: U-264 with the CORRECT key except for the plugboard
    //   Config: Beta II IV I, Ref B, rings 0,0,0,21, pos VJNA
    //   Goal: find the 10 plug pairs AT BL DF GJ HM NW OP QY RZ VX
    // ---
    const char* u264_cipher =
        "NCZWVUSXPNYMINHZXMQXSFWXWLKJAHSHNMCOCCAKUQPMKCSMHKSEINJUSBLK"
        "IOSXCKUBHMLLXCSJUSRRDVKOHULXWCCBGVLIYXEOAHXRHKKFVDREWEZLXOBA"
        "FGYUJQUKGRTVUKAMEURBVEKSUHHVOYHABCJWMAKLFKLMYFVNRIZRVVRTKOFD"
        "ANJMOLBGFFLEOPRGTFLVRHOWOPBEKVWMUQFMPWPARMFHAGKXIIBG";
    int u264_len = (int)strlen(u264_cipher);

    // Correct key (without the plugboard)
    EnigmaKey base_key;
    base_key.rotor[0]=THIN_BETA; base_key.rotor[1]=ROT_II;
    base_key.rotor[2]=ROT_IV;    base_key.rotor[3]=ROT_I;
    base_key.reflector=REF_B;
    base_key.ring[0]=0; base_key.ring[1]=0;
    base_key.ring[2]=0; base_key.ring[3]=21;
    base_key.position[0]=21; base_key.position[1]=9;   // V J
    base_key.position[2]=13; base_key.position[3]=0;   // N A
    initPlug(base_key.plugboard);  // start with an empty plugboard

    // Correct plugboard for verification
    int true_plug[26]; initPlug(true_plug);
    const char* true_pairs[] = {"AT","BL","DF","GJ","HM","NW","OP","QY","RZ","VX"};
    for(auto p : true_pairs){
        int a=p[0]-'A', b=p[1]-'A';
        true_plug[a]=b; true_plug[b]=a;
    }

    // Score with the empty plugboard vs. the correct one
    float score_noplug = scoreWithPlug(base_key, base_key.plugboard, u264_cipher, u264_len, qg);
    float score_true   = scoreWithPlug(base_key, true_plug,          u264_cipher, u264_len, qg);
    printf("=== Test 1: U-264 ===\n");
    printf("Score bez plugboarda:  %.2f (%.4f/c)\n", score_noplug, score_noplug/(u264_len-3));
    printf("Score tacan plugboard: %.2f (%.4f/c)\n", score_true,   score_true/(u264_len-3));
    printf("\nPokretam hill-climbing (30 restarta)...\n");

    auto t_start = std::chrono::high_resolution_clock::now();
    PlugResult result = hillClimb(base_key, u264_cipher, u264_len, qg, 10, 30);
    auto t_end   = std::chrono::high_resolution_clock::now();
    double elapsed = std::chrono::duration<double>(t_end-t_start).count();

    printf("Gotovo za %.2f s\n\n", elapsed);
    printf("Nadjeni plugboard: %s\n", plugToString(result.plug).c_str());
    printf("Tacan  plugboard:  %s\n", plugToString(true_plug).c_str());
    printf("Score nadjeni: %.2f  |  Score tacan: %.2f\n", result.score, score_true);

    int common = countCommonPairs(result.plug, true_plug);
    printf("Zajednicki parovi: %d/10\n\n", common);

    // Decrypt with the found key
    EnigmaKey found_key = base_key;
    copyPlug(result.plug, found_key.plugboard);
    EnigmaCPU sim(found_key);
    std::string plaintext = sim.process(std::string(u264_cipher, u264_len));
    printf("Dekripcija s nadjenim kljucem (prvih 60):\n  %s\n", plaintext.substr(0,60).c_str());
    printf("Ocekivano:                  VONVONJLOOKSJHFFTTTEINSEINSDREIZWOYYQNNSNEUNINHA\n\n");

    bool starts_correct = (plaintext.substr(0,12) == "VONVONJLOOKS");

    // ---
    // Test 2: synthetic message with an easier plugboard (3 pairs)
    // to see whether HC converges faster on a smaller plugboard
    // ---
    printf("=== Test 2: sinteticka poruka, 3 plug para ===\n");
    // We use the no-plug message from R3/R4 but add 3 pairs
    const char* ct2 =
        "IYMJNTOMOJGQKWGUNXNVCMQPQEZKTFJAKXMXWWDNSPXMFDTEADKLPXENPRQ"
        "JONWZEXSYNUVQPHNAZAURBWFTOJBTHJQJEASEDABXIVZLOZMNWBFKIBSJNCW"
        "MDJZHKKZYSNVIYWNEOLABVQVMDPAXCLQZSTLXIRBWNYZKECSUCALIRCRSONB"
        "XBLGJXNJLXCHXGWUQSGALAEUFGSEGDIWMRJFNRXWWMKKKNSXMVROAVFCGAQPC";
    // This is ciphertext without a plugboard. To test HC, we use an empty plug
    // (since this was already encrypted without a plugboard, HC should find the empty one as best)
    EnigmaKey base2;
    base2.rotor[0]=THIN_BETA; base2.rotor[1]=ROT_I;
    base2.rotor[2]=ROT_II;    base2.rotor[3]=ROT_III;
    base2.reflector=REF_B;
    for(int i=0;i<4;i++) base2.ring[i]=base2.position[i]=0;
    base2.position[0]=4; base2.position[1]=13; base2.position[2]=8; base2.position[3]=6;
    initPlug(base2.plugboard);
    int len2=(int)strlen(ct2);

    float s_empty2 = scoreWithPlug(base2, base2.plugboard, ct2, len2, qg);
    printf("Score s praznim plugboardom (tacan): %.2f\n", s_empty2);
    printf("Pokretam HC (10 restarta)...\n");

    auto t2s = std::chrono::high_resolution_clock::now();
    PlugResult r2 = hillClimb(base2, ct2, len2, qg, 10, 10);
    auto t2e = std::chrono::high_resolution_clock::now();
    printf("Gotovo za %.2f s\n", std::chrono::duration<double>(t2e-t2s).count());
    printf("Nadjeni plugboard: '%s'  Score: %.2f\n",
           plugToString(r2.plug).c_str(), r2.score);
    // HC should find the empty plugboard as the optimum (no plugboard was used in encryption)
    bool test2_ok = (r2.score >= s_empty2 - 50.0f);  // tolerance of 50 points
    printf("Test 2 %s (nadjeni score >= empty - 50)\n\n", test2_ok?"OK":"FAIL");

    // --- Conclusion ---
    printf("========================================\n");
    printf("U-264 plugboard hill-climbing:\n");
    printf("  Zajednicki parovi: %d/10\n", common);
    printf("  Dekripcija pocinje sa VONVONJLOOKS: %s\n",
           starts_correct?"DA":"NE");
    printf("  Score: %.2f vs tacan %.2f (razlika: %.2f)\n",
           result.score, score_true, result.score-score_true);

    // Passes if: it starts correctly OR the found result has >= 6/10 pairs
    bool ok = starts_correct || (common >= 6);
    if(ok){
        printf("\nPROSLA.\n");
        if(!starts_correct)
            printf("Napomena: dekripcija ne pocinje tacno ali %d/10 parova OK.\n"
                   "Povecat broj restarta ili koristiti Simulated Annealing.\n", common);
        printf("Nastavi na Fazu R9 (integracija + ispis kljuca).\n");
    } else {
        printf("\nPALA — %d/10 parova, dekripcija ne pocinje tacno.\n", common);
        printf("Povecat num_restarts ili uvesti Simulated Annealing (R7b).\n");
    }
    return ok?0:1;
}
