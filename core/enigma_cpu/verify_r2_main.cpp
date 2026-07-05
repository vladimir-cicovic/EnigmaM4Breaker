#include <iostream>
#include <iomanip>
#include <string>
#include <cstring>
#include "config.h"
#include "enigma_cpu.h"
#include "filters/ioc/ioc.h"
#include "filters/trigram/trigram_score.h"
#include "filters/quadgram/quadgram_score.h"

// ---- U-264 test vectors (identical to R1) ----
static const std::string U264_CIPHER =
    "NCZWVUSXPNYMINHZXMQXSFWXWLKJAHSHNMCOCCAKUQPMKCSMHKSEINJUSBLK"
    "IOSXCKUBHMLLXCSJUSRRDVKOHULXWCCBGVLIYXEOAHXRHKKFVDREWEZLXOBA"
    "FGYUJQUKGRTVUKAMEURBVEKSUHHVOYHABCJWMAKLFKLMYFVNRIZRVVRTKOFD"
    "ANJMOLBGFFLEOPRGTFLVRHOWOPBEKVWMUQFMPWPARMFHAGKXIIBG";

static std::string decryptU264() {
    EnigmaKey key;
    key.rotor[0] = THIN_BETA; key.rotor[1] = ROT_II;
    key.rotor[2] = ROT_IV;    key.rotor[3] = ROT_I;
    key.reflector = REF_B;
    key.ring[0]=0; key.ring[1]=0; key.ring[2]=0; key.ring[3]=21;
    key.position[0]=21; key.position[1]=9; key.position[2]=13; key.position[3]=0;
    int plugs[][2] = {{0,19},{1,11},{3,5},{6,9},{7,12},{13,22},{14,15},{16,24},{17,25},{21,23}};
    for (int i = 0; i < 26; i++) key.plugboard[i] = i;
    for (auto& p : plugs) { key.plugboard[p[0]] = p[1]; key.plugboard[p[1]] = p[0]; }
    EnigmaCPU m4(key);
    return m4.process(U264_CIPHER);
}

// ---- Helpers ----
static void printBar(float val, float lo, float hi, int width = 30) {
    float frac = (val - lo) / (hi - lo);
    if (frac < 0) frac = 0;
    if (frac > 1) frac = 1;
    int filled = (int)(frac * width);
    std::cout << "[";
    for (int i = 0; i < width; i++) std::cout << (i < filled ? '#' : '.');
    std::cout << "]";
}

int main(int argc, char* argv[]) {
    std::cout << "========================================\n";
    std::cout << "Enigma M4 — Scoring verifikacija (R2)\n";
    std::cout << "========================================\n\n";

    // Resolve data path (argv[1] or default relative to exe)
    const char* dataDir = (argc > 1) ? argv[1] : "data";
    std::string qgPath = std::string(dataDir) + "/german_quadgrams.txt";
    std::string tgPath = std::string(dataDir) + "/german_trigrams.txt";

    // --- Load scorers ---
    std::cout << "Ucitavam german_quadgrams.txt ... ";
    std::cout.flush();
    static QuadgramScorer qg;   // static: 1.8 MB table, avoid stack overflow
    if (!qg.load(qgPath.c_str())) {
        std::cerr << "GRESKA: ne mogu otvoriti " << qgPath << "\n";
        return 1;
    }
    std::cout << "OK  (floor=" << std::fixed << std::setprecision(4) << qg.floor_score() << ")\n";

    std::cout << "Ucitavam german_trigrams.txt  ... ";
    std::cout.flush();
    static TrigramScorer tg;
    if (!tg.load(tgPath.c_str())) {
        std::cerr << "GRESKA: ne mogu otvoriti " << tgPath << "\n";
        return 1;
    }
    std::cout << "OK  (floor=" << std::fixed << std::setprecision(4) << tg.floor_score() << ")\n\n";

    // --- Decrypt U-264 ---
    std::string plain  = decryptU264();
    const std::string& cipher = U264_CIPHER;
    int len = (int)plain.size();

    std::cout << "Tekst (prvih 60): " << plain.substr(0, 60) << "\n";
    std::cout << "Sifrat (prvih 60): " << cipher.substr(0, 60) << "\n\n";

    // --- IoC ---
    std::cout << "--- IoC (njemacki ocekivano ~0.0762, slucajni ~0.0385) ---\n";
    double ioc_plain  = computeIoC(plain.c_str(),  len);
    double ioc_cipher = computeIoC(cipher.c_str(), (int)cipher.size());
    std::cout << "  Plaintext IoC : " << std::fixed << std::setprecision(4) << ioc_plain  << " ";
    printBar((float)ioc_plain, 0.035f, 0.085f); std::cout << "\n";
    std::cout << "  Ciphertext IoC: " << std::fixed << std::setprecision(4) << ioc_cipher << " ";
    printBar((float)ioc_cipher, 0.035f, 0.085f); std::cout << "\n";
    // Naval M4 signals are structured military text (numbers spelled out, markers),
    // so their IoC is ~0.055-0.065 rather than the prose ~0.0762.
    // Threshold tuned for ~200-char Kriegsmarine messages.
    bool ioc_ok = (ioc_plain > 0.050) && (ioc_cipher < 0.055);
    std::cout << "  => " << (ioc_ok ? "PROSLA (razlikuje plaintext od ciphertexta)" : "PALA") << "\n\n";

    // --- Trigram ---
    std::cout << "--- Trigram score (per karakter) ---\n";
    float tg_plain  = tg.score(plain)  / (float)(len - 2);
    float tg_cipher = tg.score(cipher) / (float)((int)cipher.size() - 2);
    std::cout << "  Plaintext  tg/c: " << std::fixed << std::setprecision(4) << tg_plain  << " ";
    printBar(tg_plain, -4.5f, -2.5f); std::cout << "\n";
    std::cout << "  Ciphertext tg/c: " << std::fixed << std::setprecision(4) << tg_cipher << " ";
    printBar(tg_cipher, -4.5f, -2.5f); std::cout << "\n";
    bool tg_ok = (tg_plain > tg_cipher + 0.3f);
    std::cout << "  => " << (tg_ok ? "PROSLA (plaintext znatno bolji skor)" : "PALA") << "\n\n";

    // --- Quadgram ---
    std::cout << "--- Quadgram score (per karakter) ---\n";
    float qg_plain  = qg.score(plain)  / (float)(len - 3);
    float qg_cipher = qg.score(cipher) / (float)((int)cipher.size() - 3);
    std::cout << "  Plaintext  qg/c: " << std::fixed << std::setprecision(4) << qg_plain  << " ";
    printBar(qg_plain, -5.5f, -2.5f); std::cout << "\n";
    std::cout << "  Ciphertext qg/c: " << std::fixed << std::setprecision(4) << qg_cipher << " ";
    printBar(qg_cipher, -5.5f, -2.5f); std::cout << "\n";
    bool qg_ok = (qg_plain > qg_cipher + 0.5f);
    std::cout << "  => " << (qg_ok ? "PROSLA (plaintext znatno bolji skor)" : "PALA") << "\n\n";

    // --- Threshold demo: would IoC filter have kept U-264? ---
    std::cout << "--- Simulacija IoC filtera na uzorku od 80 znakova ---\n";
    std::string plain80  = plain.substr(0, 80);
    std::string cipher80 = cipher.substr(0, 80);
    double ioc80_p = computeIoC(plain80.c_str(),  80);
    double ioc80_c = computeIoC(cipher80.c_str(), 80);
    double threshold = 0.048;  // gentler threshold for a short sample (~80 characters)
    std::cout << "  Prag: " << threshold << "\n";
    std::cout << "  Plaintext IoC(80):  " << std::fixed << std::setprecision(4) << ioc80_p
              << "  => " << (ioc80_p > threshold ? "PRODJE filter (tacan kljuc zadrzan)" : "ODBACEN!") << "\n";
    std::cout << "  Ciphertext IoC(80): " << std::fixed << std::setprecision(4) << ioc80_c
              << "  => " << (ioc80_c < threshold ? "ODBACEN (ispravno)" : "Prodje (lazni pozitiv)") << "\n\n";

    // --- Summary ---
    bool all_ok = ioc_ok && tg_ok && qg_ok;
    std::cout << "========================================\n";
    if (all_ok) {
        std::cout << "SVE PROVJERE PROSLE — scoring sistem spreman.\n";
        std::cout << "Nastavi na Fazu R3 (GPU kernel).\n";
    } else {
        std::cout << "NEKA PROVJERA PALA — vidi detalje gore.\n";
    }
    return all_ok ? 0 : 1;
}
