#include "quadgram_score.h"
#include <cstdio>
#include <cstring>
#include <cmath>
#include <algorithm>

QuadgramScorer::QuadgramScorer() : table_(new float[N]), floor_(0.0f) {
    std::fill(table_, table_ + N, 0.0f);
}

QuadgramScorer::~QuadgramScorer() {
    delete[] table_;
}

bool QuadgramScorer::load(const char* path) {
    FILE* f = fopen(path, "r");
    if (!f) return false;

    // Heap-alloc temp counts (456976 * 8 bytes = ~3.5 MB)
    long long* counts = new long long[N]();
    char ng[16];
    long long cnt;
    while (fscanf(f, "%15s %lld", ng, &cnt) == 2) {
        if (strlen(ng) != 4) continue;
        bool ok = true;
        int idx = 0;
        for (int i = 0; i < 4; i++) {
            if (ng[i] < 'A' || ng[i] > 'Z') { ok = false; break; }
            idx = idx * 26 + (ng[i] - 'A');
        }
        if (ok) counts[idx] += cnt;
    }
    fclose(f);

    long long total = 0;
    for (int i = 0; i < N; i++) total += counts[i];

    float log_total = std::log10f((float)total);
    floor_ = std::log10f(0.01f) - log_total;

    for (int i = 0; i < N; i++)
        table_[i] = (counts[i] > 0) ? (std::log10f((float)counts[i]) - log_total) : floor_;

    delete[] counts;
    return true;
}

float QuadgramScorer::score(const char* text, int len) const {
    float s = 0.0f;
    for (int i = 0; i + 3 < len; i++) {
        unsigned char a = (unsigned char)text[i]   - 'A';
        unsigned char b = (unsigned char)text[i+1] - 'A';
        unsigned char c = (unsigned char)text[i+2] - 'A';
        unsigned char d = (unsigned char)text[i+3] - 'A';
        if (a > 25 || b > 25 || c > 25 || d > 25) continue;
        s += table_[a * 17576 + b * 676 + c * 26 + d];
    }
    return s;
}

float QuadgramScorer::score(const std::string& text) const {
    return score(text.c_str(), (int)text.size());
}
