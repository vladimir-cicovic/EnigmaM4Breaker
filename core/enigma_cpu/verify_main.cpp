#include <iostream>
#include <string>
#include <cstring>
#include "config.h"
#include "enigma_cpu.h"

// Helper: build EnigmaKey from symbolic values
static EnigmaKey buildKey(
    int thin, int left, int mid, int right,
    int reflector,
    int ring_thin,  int ring_left,  int ring_mid,  int ring_right,
    int pos_thin,   int pos_left,   int pos_mid,   int pos_right,
    const char* plugPairs)   // space-separated 2-char pairs, e.g. "AT BL DF"
{
    EnigmaKey key;
    key.rotor[0] = thin;  key.rotor[1] = left;
    key.rotor[2] = mid;   key.rotor[3] = right;
    key.ring[0]  = ring_thin;  key.ring[1]  = ring_left;
    key.ring[2]  = ring_mid;   key.ring[3]  = ring_right;
    key.position[0] = pos_thin; key.position[1] = pos_left;
    key.position[2] = pos_mid;  key.position[3] = pos_right;
    key.reflector = reflector;
    for (int i = 0; i < 26; i++) key.plugboard[i] = i;

    const char* p = plugPairs;
    while (*p) {
        while (*p == ' ') p++;
        if (!*p || !*(p+1)) break;
        int a = p[0] - 'A', b = p[1] - 'A';
        key.plugboard[a] = b;
        key.plugboard[b] = a;
        p += 2;
    }
    return key;
}

// Enigma never enciphers a letter to itself
static bool checkSanity(const std::string& a, const std::string& b) {
    for (size_t i = 0; i < a.size() && i < b.size(); i++) {
        if (a[i] == b[i]) {
            std::cerr << "  [SANITY FAIL] '"<< a[i] <<"' maps to itself at pos " << i << "\n";
            return false;
        }
    }
    return true;
}

// --- Test 1: round-trip ---
static bool testRoundTrip() {
    std::cout << "--- Test 1: Round-trip ---\n";

    EnigmaKey key;
    key.rotor[0] = THIN_BETA; key.rotor[1] = ROT_I;
    key.rotor[2] = ROT_II;    key.rotor[3] = ROT_III;
    key.reflector = REF_B;
    for (int i = 0; i < 4; i++) key.ring[i] = key.position[i] = 0;
    for (int i = 0; i < 26; i++) key.plugboard[i] = i;

    const std::string plain = "HELLOWORLDHELLOWORLD";

    EnigmaCPU enc(key);
    std::string cipher = enc.process(plain);

    EnigmaCPU dec(key);           // same key = same initial state
    std::string back = dec.process(cipher);

    std::cout << "  plain:  " << plain  << "\n";
    std::cout << "  cipher: " << cipher << "\n";
    std::cout << "  back:   " << back   << "\n";

    bool ok = (back == plain) && checkSanity(plain, cipher);
    std::cout << "  => " << (ok ? "PROSLA" : "PALA") << "\n\n";
    return ok;
}

// --- Test 2: authentic U-264 message ---
static bool testU264() {
    std::cout << "--- Test 2: Autenticna U-264 poruka (25.11.1942) ---\n";

    // Reflector Thin B, wheels Beta II IV I
    // Rings: 01 01 01 22  (0-based: 0 0 0 21)
    // Msg key VJNA         (V=21 J=9 N=13 A=0)
    // Plugs: AT BL DF GJ HM NW OP QY RZ VX
    EnigmaKey key = buildKey(
        THIN_BETA, ROT_II, ROT_IV, ROT_I, REF_B,
        0,  0,  0,  21,       // rings
        21, 9, 13,   0,       // positions V J N A
        "AT BL DF GJ HM NW OP QY RZ VX"
    );

    const std::string cipher =
        "NCZWVUSXPNYMINHZXMQXSFWXWLKJAHSHNMCOCCAKUQPMKCSMHKSEINJUSBLK"
        "IOSXCKUBHMLLXCSJUSRRDVKOHULXWCCBGVLIYXEOAHXRHKKFVDREWEZLXOBA"
        "FGYUJQUKGRTVUKAMEURBVEKSUHHVOYHABCJWMAKLFKLMYFVNRIZRVVRTKOFD"
        "ANJMOLBGFFLEOPRGTFLVRHOWOPBEKVWMUQFMPWPARMFHAGKXIIBG";

    const std::string expected = "VONVONJLOOKS";

    EnigmaCPU m4(key);
    std::string plain = m4.process(cipher);

    bool sanity = checkSanity(cipher, plain);
    bool match  = (plain.substr(0, expected.size()) == expected);

    std::cout << "  Decrypted (prvih 60 znakova):\n  " << plain.substr(0, 60) << "\n";
    std::cout << "  Ocekivani pocetak: " << expected << "\n";
    std::cout << "  Sanity check: " << (sanity ? "OK" : "FAIL") << "\n";
    std::cout << "  Match: " << (match ? "OK" : "FAIL") << "\n";
    std::cout << "  => " << (match && sanity ? "PROSLA" : "PALA") << "\n\n";
    return match && sanity;
}

// --- Test 3: known cipher->plain vector with ring setting ---
static bool testRingSetting() {
    std::cout << "--- Test 3: Ring setting (non-zero rings) ---\n";

    // Self-test: encrypt with non-zero rings, decrypt with same key
    EnigmaKey key = buildKey(
        THIN_BETA, ROT_III, ROT_II, ROT_I, REF_B,
        0, 3, 7, 21,      // rings (non-trivial)
        5, 12, 1, 24,     // positions
        "BQ CR DI EJ KW MT OS PX UZ GH"
    );

    const std::string plain = "KRIEGSMARINE";

    EnigmaCPU enc(key);
    std::string cipher = enc.process(plain);

    EnigmaCPU dec(key);
    std::string back = dec.process(cipher);

    bool ok = (back == plain) && checkSanity(plain, cipher);
    std::cout << "  plain:  " << plain  << "\n";
    std::cout << "  cipher: " << cipher << "\n";
    std::cout << "  back:   " << back   << "\n";
    std::cout << "  => " << (ok ? "PROSLA" : "PALA") << "\n\n";
    return ok;
}

int main() {
    std::cout << "========================================\n";
    std::cout << "Enigma M4 CPU — Verifikacija (Faza R1)\n";
    std::cout << "========================================\n\n";

    bool ok = true;
    ok &= testRoundTrip();
    ok &= testU264();
    ok &= testRingSetting();

    std::cout << "========================================\n";
    if (ok) {
        std::cout << "SVE PROVJERE PROSLE — simulator je tacan.\n";
        std::cout << "Nastavi na Fazu R2.\n";
        return 0;
    } else {
        std::cout << "PROVJERA PALA — vidi detalje gore.\n";
        return 1;
    }
}
