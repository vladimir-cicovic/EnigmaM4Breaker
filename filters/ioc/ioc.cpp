#include "ioc.h"

double computeIoC(const char* text, int len) {
    long long freq[26] = {};
    long long N = 0;
    for (int i = 0; i < len; i++) {
        char c = text[i];
        if (c >= 'A' && c <= 'Z') { freq[c - 'A']++; N++; }
    }
    if (N < 2) return 0.0;
    long long num = 0;
    for (int i = 0; i < 26; i++) num += freq[i] * (freq[i] - 1);
    return (double)num / (double)(N * (N - 1));
}
