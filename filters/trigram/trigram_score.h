#pragma once
#include <string>

// Trigram log-probability scorer.
// score() returns sum of log10(P) for every consecutive 3-letter window.
// Higher score = more German-like text.
class TrigramScorer {
public:
    static constexpr int N = 26 * 26 * 26;   // 17576

    TrigramScorer();
    ~TrigramScorer();

    // Load from file with format: "XXX count" per line (A-Z only; others skipped).
    bool load(const char* path);

    float score(const char* text, int len) const;
    float score(const std::string& text) const;

    float floor_score() const { return floor_; }

private:
    float* table_;
    float  floor_;
};
