#pragma once
#include <string>

// Quadgram log-probability scorer (~1.8 MB table, heap-allocated).
// score() returns sum of log10(P) for every consecutive 4-letter window.
// Higher (less negative) score = more German-like text.
//
// NOTE: Do NOT create on the stack — table is ~1.8 MB.
//       Use as a global, static, or heap-allocated object.
class QuadgramScorer {
public:
    static constexpr int N = 26 * 26 * 26 * 26;   // 456976

    QuadgramScorer();
    ~QuadgramScorer();

    // Load from file with format: "XXXX count" per line (A-Z only; others skipped).
    bool load(const char* path);

    float score(const char* text, int len) const;
    float score(const std::string& text) const;

    float floor_score() const { return floor_; }

private:
    float* table_;
    float  floor_;
};
