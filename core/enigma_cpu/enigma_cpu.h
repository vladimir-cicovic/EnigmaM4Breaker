#pragma once
#include "config.h"
#include <string>

class EnigmaCPU {
public:
    explicit EnigmaCPU(const EnigmaKey& key);

    // Encrypt/decrypt one character (must be 'A'-'Z'); advances rotor state.
    char encryptChar(char c);

    // Process full string, skipping non-alpha characters.
    std::string process(const std::string& text);

    // Re-initialize to the same key (identical initial state).
    void reset(const EnigmaKey& key);

private:
    int  fw[4][26];        // forward wiring table per slot
    int  bw[4][26];        // inverse wiring table per slot
    bool at_notch[4][26];  // at_notch[slot][pos] = true if notch fires here
    int  refl[26];         // reflector lookup
    int  plug[26];         // plugboard substitution
    int  pos[4];           // current rotor positions
    int  ring[4];          // ring settings

    void step();
    int  passForward (int c, int slot) const;
    int  passBackward(int c, int slot) const;
    void buildTables(const EnigmaKey& key);

    static void buildInverse(const int fwd[26], int inv[26]);
};
