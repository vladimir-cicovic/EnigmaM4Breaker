// Diagnostic: what is the IoC for U-264 without the plugboard?
// Compile with: cl.exe /std:c++17 /O2 /MT /I"." ioc_diag.cpp core\enigma_cpu\enigma_cpu.cpp /Fe:build\ioc_diag.exe
#include <cstdio>
#include <cstring>
#include <chrono>
#include "config.h"
#include "core/enigma_cpu/enigma_cpu.h"

static const char* U264_CT =
    "NCZWVUSXPNYMINHZXMQXSFWXWLKJAHSHNMCOCCAKUQPMKCSMHKSEINJUSBLK"
    "IOSXCKUBHMLLXCSJUSRRDVKOHULXWCCBGVLIYXEOAHXRHKKFVDREWEZLXOBAF"
    "GYUJQUKGRTVUKAMEURBVEKSUHHVOYHABCJWMAKLFKLMYFVNRIZRVVRTKOFDANJ"
    "MOLBGFFLEOPRGTFLVRHOWOPBEKVWMUQFMPWPARMFHAGKXIIBG";

// Complete key for U-264 (with plugboard)
static const int PLUG_U264[26] = {
//  A  B  C  D  E  F  G  H  I  J  K  L  M  N  O  P  Q  R  S  T  U  V  W  X  Y  Z
//  AT BL DF GJ HM NW OP QY RZ VX
    19, 11, 2, 5, 4, 3, 9, 12, 8, 6, 10, 1, 7, 22, 15, 14, 24, 25, 18, 0, 20, 23, 13, 21, 16, 17
};

static float ioc(const char* text, int N) {
    int freq[26] = {};
    for (int i = 0; i < N; i++) {
        int c = text[i] - 'A';
        if (c >= 0 && c < 26) freq[c]++;
    }
    int s = 0; for (int i = 0; i < 26; i++) s += freq[i]*(freq[i]-1);
    return (float)s / (float)(N*(N-1));
}

int main() {
    auto _wall0=std::chrono::high_resolution_clock::now();
    int clen = (int)strlen(U264_CT);
    printf("Ciphertext len = %d\n", clen);
    printf("Ciphertext IoC = %.5f\n\n", ioc(U264_CT, clen));

    // 1. Decrypt WITH plugboard (correct plaintext)
    EnigmaKey key_full;
    key_full.rotor[0]=0; key_full.rotor[1]=1; key_full.rotor[2]=3; key_full.rotor[3]=0;
    key_full.ring[0]=0; key_full.ring[1]=0; key_full.ring[2]=0; key_full.ring[3]=21;
    key_full.position[0]=21; key_full.position[1]=9; key_full.position[2]=13; key_full.position[3]=0;
    key_full.reflector=0;
    memcpy(key_full.plugboard, PLUG_U264, sizeof(PLUG_U264));

    EnigmaCPU sim1(key_full);
    char plain_full[300] = {};
    int j = 0;
    for (int i = 0; i < clen; i++) {
        if (U264_CT[i] >= 'A' && U264_CT[i] <= 'Z')
            plain_full[j++] = sim1.encryptChar(U264_CT[i]);
    }
    plain_full[j] = 0;
    printf("With plugboard (correct plaintext):\n  %.60s\n", plain_full);
    printf("  IoC = %.5f  (N=%d)\n\n", ioc(plain_full, j), j);

    // 2. Decrypt WITHOUT plugboard (Stage A simulation)
    EnigmaKey key_noplug = key_full;
    for (int i = 0; i < 26; i++) key_noplug.plugboard[i] = i; // identity

    EnigmaCPU sim2(key_noplug);
    char plain_noplug[300] = {};
    j = 0;
    for (int i = 0; i < clen; i++) {
        if (U264_CT[i] >= 'A' && U264_CT[i] <= 'Z')
            plain_noplug[j++] = sim2.encryptChar(U264_CT[i]);
    }
    plain_noplug[j] = 0;
    printf("Without plugboard (Stage A simulation):\n  %.60s\n", plain_noplug);
    printf("  IoC = %.5f  (N=%d)\n\n", ioc(plain_noplug, j), j);

    // 3. Check for different sample sizes
    printf("IoC by sample length (without plugboard):\n");
    for (int n : {50, 100, 150, 200, 232}) {
        int nn = (n < j) ? n : j;
        float v = ioc(plain_noplug, nn);
        printf("  N=%3d: IoC=%.5f\n", nn, v);
    }

    // 4. Check ring[3]=0 (old Stage A)
    EnigmaKey key_ring0 = key_full;
    for (int i = 0; i < 26; i++) key_ring0.plugboard[i] = i;
    key_ring0.ring[3] = 0;
    key_ring0.position[3] = (0 + 21) % 26; // compensation for ring=0

    EnigmaCPU sim3(key_ring0);
    char plain_r0[300] = {};
    j = 0;
    for (int i = 0; i < clen; i++) {
        if (U264_CT[i] >= 'A' && U264_CT[i] <= 'Z')
            plain_r0[j++] = sim3.encryptChar(U264_CT[i]);
    }
    printf("\nRing[3]=0, pos[3]=21 (old Stage A equivalent):\n");
    printf("  IoC = %.5f  (N=%d)\n\n", ioc(plain_r0, j), j);

    printf("\nElapsed (wall-clock): %.3f s\n",
        std::chrono::duration<double>(std::chrono::high_resolution_clock::now()-_wall0).count());
    return 0;
}
