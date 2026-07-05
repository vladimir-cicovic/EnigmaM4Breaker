#include "enigma_cpu.h"
#include <cstring>

// --- Static helpers ---

void EnigmaCPU::buildInverse(const int fwd[26], int inv[26]) {
    for (int i = 0; i < 26; i++)
        inv[fwd[i]] = i;
}

void EnigmaCPU::buildTables(const EnigmaKey& key) {
    // Slot 0: thin rotor (Beta or Gamma) — never steps, no notch
    {
        const char* w = THIN_ROTOR_WIRING[key.rotor[0]];
        for (int i = 0; i < 26; i++) fw[0][i] = w[i] - 'A';
        buildInverse(fw[0], bw[0]);
        memset(at_notch[0], 0, sizeof(at_notch[0]));
    }

    // Slots 1-3: left, middle, right regular rotors
    for (int slot = 1; slot <= 3; slot++) {
        int r = key.rotor[slot];
        const char* w = ROTOR_WIRING[r];
        for (int i = 0; i < 26; i++) fw[slot][i] = w[i] - 'A';
        buildInverse(fw[slot], bw[slot]);
        memset(at_notch[slot], 0, sizeof(at_notch[slot]));
        for (const char* n = ROTOR_NOTCH[r]; *n; n++)
            at_notch[slot][*n - 'A'] = true;
    }

    // Reflector
    const char* r = REFLECTOR_WIRING[key.reflector];
    for (int i = 0; i < 26; i++) refl[i] = r[i] - 'A';

    // Plugboard and initial state
    memcpy(plug, key.plugboard, sizeof(plug));
    memcpy(pos,  key.position,  sizeof(pos));
    memcpy(ring, key.ring,      sizeof(ring));
}

// --- Constructor / reset ---

EnigmaCPU::EnigmaCPU(const EnigmaKey& key) {
    buildTables(key);
}

void EnigmaCPU::reset(const EnigmaKey& key) {
    buildTables(key);
}

// --- Stepping (M4 double-step, checked BEFORE rotation) ---

void EnigmaCPU::step() {
    bool right_at_notch = at_notch[3][pos[3]];
    bool mid_at_notch   = at_notch[2][pos[2]];

    if (mid_at_notch) {
        pos[1] = (pos[1] + 1) % 26;   // left steps
        pos[2] = (pos[2] + 1) % 26;   // middle double-steps
    } else if (right_at_notch) {
        pos[2] = (pos[2] + 1) % 26;   // middle steps normally
    }
    pos[3] = (pos[3] + 1) % 26;       // right always steps
    // pos[0] (thin) never steps
}

// --- Rotor pass (ring-offset formula) ---

int EnigmaCPU::passForward(int c, int slot) const {
    int off = (pos[slot] - ring[slot] + 26) % 26;
    c = (c + off) % 26;
    c = fw[slot][c];
    c = (c - off + 26) % 26;
    return c;
}

int EnigmaCPU::passBackward(int c, int slot) const {
    int off = (pos[slot] - ring[slot] + 26) % 26;
    c = (c + off) % 26;
    c = bw[slot][c];
    c = (c - off + 26) % 26;
    return c;
}

// --- Encryption (signal path: plug -> R->M->L->thin -> refl -> thin->L->M->R -> plug) ---

char EnigmaCPU::encryptChar(char ch) {
    step();
    int x = ch - 'A';

    x = plug[x];
    for (int i = 3; i >= 0; i--) x = passForward(x, i);   // right..thin
    x = refl[x];
    for (int i = 0; i <= 3; i++) x = passBackward(x, i);   // thin..right
    x = plug[x];

    return static_cast<char>('A' + x);
}

std::string EnigmaCPU::process(const std::string& text) {
    std::string out;
    out.reserve(text.size());
    for (char c : text)
        if (c >= 'A' && c <= 'Z')
            out += encryptChar(c);
    return out;
}
