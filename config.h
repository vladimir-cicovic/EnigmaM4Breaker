#pragma once

// Enigma M4 wiring tables (all verified against authentic sources)
// Format: position = input (A=0..Z=25), char at that pos = output letter

static constexpr const char* ROTOR_WIRING[8] = {
    "EKMFLGDQVZNTOWYHXUSPAIBRCJ",   // I
    "AJDKSIRUXBLHWTMCQGZNPYFVOE",   // II
    "BDFHJLCPRTXVZNYEIWGAKMUSQO",   // III
    "ESOVPZJAYQUIRHXLNFTGKDCMWB",   // IV
    "VZBRGITYUPSDNHLXAWMJQOFECK",   // V
    "JPGVOUMFYQBENHZRDKASXLICTW",   // VI
    "NZJHGRCXMYSWBOUFAIVLPEKQDT",   // VII
    "FKQHTLXOCBJSPDZRAMEWNIUYGV"    // VIII
};

// Notch: position(s) at which THIS rotor triggers the next rotor to step
// Rotors VI/VII/VIII have two notches (Z and M)
static constexpr const char* ROTOR_NOTCH[8] = {
    "Q",    // I
    "E",    // II
    "V",    // III
    "J",    // IV
    "Z",    // V
    "ZM",   // VI
    "ZM",   // VII
    "ZM"    // VIII
};

// Thin rotors (slot 0, leftmost, NEVER step)
static constexpr const char* THIN_ROTOR_WIRING[2] = {
    "LEYJVCNIXWPBQMDRTAKZGFUHOS",   // Beta
    "FSOKANUERHMBTIYCWLQPZXVGJD"    // Gamma
};

// Thin reflectors for M4
static constexpr const char* REFLECTOR_WIRING[2] = {
    "ENKQAUYWJICOPBLMDXZVFTHRGS",   // B-thin (UKW-B)
    "RDOBJNTKVEHMLFCWZAXGYIPSUQ"    // C-thin (UKW-C)
};

enum RotorIndex { ROT_I=0, ROT_II, ROT_III, ROT_IV, ROT_V, ROT_VI, ROT_VII, ROT_VIII };
enum ThinRotor  { THIN_BETA=0, THIN_GAMMA };
enum Reflector  { REF_B=0, REF_C };

// Key layout: indices [0]=thin, [1]=left, [2]=middle, [3]=right
struct EnigmaKey {
    int rotor[4];      // rotor index (thin uses THIN_* enum, others ROT_*)
    int ring[4];       // Ringstellung, 0-25 (A=0)
    int position[4];   // Grundstellung, 0-25 (A=0)
    int reflector;     // REF_B or REF_C
    int plugboard[26]; // plugboard[i]=i means no stecker pair for letter i
};
