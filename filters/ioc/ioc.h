#pragma once

// Index of Coincidence for uppercase A-Z text.
// German plaintext:  ~0.0762
// Random ciphertext: ~0.0385 (= 1/26)
double computeIoC(const char* text, int len);
