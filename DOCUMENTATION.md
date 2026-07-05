# Enigma M4 Breaker — History, Code, Mathematics

Reference document connecting the **historical facts** about the Enigma M4 with the
**techniques used in this code**, defining **what runs on the CPU vs. the GPU**, and
explaining **every concept** in detail (IoC, quadgram scoring, scoreXsplit, bombes,
hill-climbing, depth…) with **math** and **source links**.

> Authenticity note: the wiring, notches, double-stepping, and signal path in this code
> are verified by decrypting the authentic **U-264** message (it must yield
> `VONVONJLOOKS...`). That is the foundation — without an exact simulator, every
> optimization on top of it is worthless.

---

## Contents

1. [Historical Introduction — Enigma M4](#1-historical-introduction--enigma-m4)
2. [Machine Components ↔ `EnigmaKey`](#2-machine-components--enigmakey)
3. [Key Space — Mathematics](#3-key-space--mathematics)
4. [CPU ↔ GPU Split](#4-cpu--gpu-split)
5. [Statistical Tools (Every Concept in Detail)](#5-statistical-tools-every-concept-in-detail)
6. [Attack Algorithms (History + Code + Math)](#6-attack-algorithms-history--code--math)
7. [What Each Program Does](#7-what-each-program-does)
8. [Key Mathematical Finding of This Project](#8-key-mathematical-finding-of-this-project)
9. [Build & Run Reference](#9-build--run-reference)
10. [File Map](#10-file-map)
11. [Sources / Further Reading](#11-sources--further-reading)

---

## 1. Historical Introduction — Enigma M4

**Enigma M4** (German: *Schlüssel M / Funkschlüssel M4*) is the naval four-rotor Enigma
that the Kriegsmarine introduced on **1 February 1942** on the Atlantic U-boat network.
The Germans called it **"Triton"**, the Allies **"Shark"**. Its introduction caused the
*1942 blackout* — roughly 10 months during which Bletchley Park could not read U-boat
traffic, at the height of the Battle of the Atlantic.

The key novelty over the three-rotor M3 is a **fourth rotor**, but a special one:

- The fourth rotor is a **thin rotor** (*Zusatzwalze*) — **Beta** or **Gamma** — which
  **NEVER rotates** during encryption.
- It's paired with a **thin reflector** (*Umkehrwalze Dünn*): **B-thin** or **C-thin**.
- **Designed for compatibility (and this is also its weakness):** Beta at position `A` +
  thin reflector B produce a machine **functionally identical** to an M3 with a standard
  UKW-B. This let M4 U-boats communicate with M3-equipped surface ships — which is
  exactly why those wirings were chosen.

The turning point in breaking it was the **capture of the code books from U-559**
(30 Oct 1942, HMS Petard) — a short weather/signal cipher book — which led to the first
break of M4 in December 1942.

**Sources for this section:**
- Enigma (general): https://en.wikipedia.org/wiki/Enigma_machine
- Naval Enigma / M4 (most detailed): https://www.cryptomuseum.com/crypto/enigma/m4/index.htm
- Cryptanalysis of the Enigma: https://en.wikipedia.org/wiki/Cryptanalysis_of_the_Enigma
- Battle of the Atlantic: https://en.wikipedia.org/wiki/Battle_of_the_Atlantic
- Capture of U-559: https://en.wikipedia.org/wiki/German_submarine_U-559
- Bletchley Park / Tony Sale: http://www.codesandciphers.org.uk/

---

## 2. Machine Components ↔ `EnigmaKey`

The entire key is summarized in [`config.h`](config.h) as a single struct:

```c
struct EnigmaKey {
    int rotor[4];      // [0]=thin(Beta/Gamma), [1]=left, [2]=middle, [3]=right
    int ring[4];       // Ringstellung
    int position[4];   // Grundstellung (starting position)
    int reflector;     // B-thin / C-thin
    int plugboard[26]; // Steckerbrett (plug[i]=i => letter i is not stecker'ed)
};
```

### Signal path through the machine

![Signal path through the Enigma M4](diagram_signal.svg)

Path of a single character: `INPUT → plugboard → right → middle → left → thin →
REFLECTOR → thin → left → middle → right → plugboard → OUTPUT`. In the code this is
`EnigmaCPU::encryptChar()` (CPU) or `gEnc()` (GPU). Since the reflector is an
involution, the path is **reciprocal** — the same machine both encrypts and decrypts.

### Rotors, wirings, notches
`config.h` contains the **historical wirings** of rotors I–VIII, the thin rotors
Beta/Gamma, and reflectors B/C-thin:

- Rotors **I–V** (1930s, shared by the Wehrmacht and Kriegsmarine) have **one** notch
  (I=`Q`, II=`E`, III=`V`, IV=`J`, V=`Z`).
- Rotors **VI, VII, VIII** (naval-only, 1939) have **two** notches (`Z` and `M`) →
  `ROTOR_NOTCH[5..7]="ZM"`. Two notches make the middle rotor step twice as often
  (extra protection).
- The notch letter is the point at which a rotor "kicks" the next one — historically
  engraved on the ring.

**Sources:**
- All rotor/reflector wirings (the reference this code matches): https://www.cryptomuseum.com/crypto/enigma/wiring.htm
- Rotor details / turnover / notch: https://en.wikipedia.org/wiki/Enigma_rotor_details

### Thin rotor (Beta/Gamma) + thin reflector
`THIN_ROTOR_WIRING[2]`, `REFLECTOR_WIRING[2]`. In the code the thin rotor sits in
**slot 0** and is never stepped in `EnigmaCPU::step()`; its ring is effectively always 0.
The historical reason (M3 compatibility) is described in section 1.
- Thin reflector explained: https://www.cryptomuseum.com/crypto/enigma/wiring.htm

### Ringstellung (`ring`) — ring setting
An alphabet ring rotated relative to the internal wiring; it shifts the
position↔wiring relationship. In [`enigma_cpu.cpp`](core/enigma_cpu/enigma_cpu.cpp):
```c
int off = (pos[slot] - ring[slot] + 26) % 26;   // the heart of correctness — sign is critical
c = (c + off) % 26;  c = fw[slot][c];  c = (c - off + 26) % 26;
```
- https://en.wikipedia.org/wiki/Enigma_rotor_details

### Grundstellung (`position`) — starting position
The visible letters in the windows at the start. Historically: the operator sets the
base position, then encrypts the *message key*. For U-264: `VJNA`.

### Steckerbrett (`plugboard`) — plug panel
A cable pair swaps two letters before and after the rotors. Kriegsmarine standard:
typically **10 pairs**. The largest contributor to the key space (see section 3) and the
reason it must be *recovered statistically*. In the code it's an involution: pair (a,b)
⇒ `plug[a]=b, plug[b]=a`.
- https://en.wikipedia.org/wiki/Enigma_machine#Plugboard

### Double-stepping anomaly
Because of the pawl-and-ratchet mechanism, when the middle rotor is at its notch, the
*next* keypress steps **both itself and the left** rotor. A mechanical artifact, not a
design choice — the most common simulator bug. In
[`enigma_cpu.cpp`](core/enigma_cpu/enigma_cpu.cpp):
```c
void EnigmaCPU::step() {
    bool right_at_notch = at_notch[3][pos[3]];
    bool mid_at_notch   = at_notch[2][pos[2]];
    if (mid_at_notch)        { pos[1]++; pos[2]++; }  // double step
    else if (right_at_notch) { pos[2]++; }
    pos[3]++;                                         // right always steps; thin never does
}
```
The check happens **before** rotation.
- Explanation: https://en.wikipedia.org/wiki/Enigma_rotor_details#Normalized_Enigma_sequences
- Classic paper: David H. Hamer, *"Enigma: Actions Involved in the 'Double Stepping' of
  the Middle Rotor"*, Cryptologia 21(1), 1997. PDF: https://www.tandfonline.com/doi/abs/10.1080/0161-119791885896

### Reciprocity / "no letter to itself"
The reflector is a fixed-point-free involution ⇒ the whole machine is reciprocal and
**no letter is ever encrypted to itself**. Enigma's biggest weakness, and the foundation
of the bombe/crib attack (section 6.2). In the code: `sanityCipher()` and the clash
check while dragging a crib.

---

## 3. Key Space — Mathematics

| Component | Count | Calculation |
|---|---|---|
| Wheel order | **1344** | 8·7·6 (3 of 8, ordered) × 2 (Beta/Gamma) × 2 (reflector B/C) |
| Start positions (Grundstellung) | **456,976** | 26⁴ |
| Ring settings (effective) | **17,576** | 26³ (thin rotor's ring is irrelevant) |
| Plugboard, 10 pairs | **≈ 1.5 × 10¹⁴** | 26! / (6! · 2¹⁰ · 10!) |

**Plugboard formula** (for *p* pairs out of 26 letters):

```
N_plug(p) = 26! / ( (26 - 2p)! · 2^p · p! )
N_plug(10) = 150,738,274,937,250  ≈ 1.5 × 10^14
```

The total M4 key space is on the order of **~10²³**.

**Consequence (the whole philosophy of the code):**
- The rotor part (1344 × 26⁴ × 26³ ≈ **3 × 10¹⁰**) is **brute-forceable on a GPU**.
- The plugboard (10¹⁴) is **not** — it must be *recovered* via hill-climbing or a bombe
  attack.

That's why the space is *split*: the GPU sweeps rotors/positions with a cheap score;
the expensive plugboard is solved only on the few hundred surviving candidates, on the
CPU.

**Ring↔position degeneracy:** for a single message, the right rotor's ring and the
start position are nearly interchangeable (except around the notch). The code accepts
this for short messages.

**Sources:**
- Number of Enigma settings (incl. plugboard derivation): https://en.wikipedia.org/wiki/Enigma_machine#Mathematical_analysis
- Detailed derivation of plugboard combinatorics: https://en.wikipedia.org/wiki/Enigma_machine#Mathematical_analysis (key-count section)

---

## 4. CPU ↔ GPU Split

Central engineering principle: **"keep the millions on the GPU, promote only the top
20–100 to the CPU."**

![Pipeline: GPU coarse filter → CPU precise refinement](diagram_pipeline.svg)

### On the GPU (`__global__` / `__device__`)
1. **Massively parallel search** — one thread = one position (26⁴), or one thread = one
   (position × ring) setting for the bombe. Threads are independent → ideal for a GPU.
2. **Per-thread Enigma decryption** — `gEnc()` (the same core as the CPU, but
   `__forceinline__` and using constant memory).
3. **Cheap score + a plugboard mini-HC that fits in registers** — IoC (`decIoC` +
   `iocPlugHC`) or trigram (`triHC_direct`).
4. **Turing bombe** (`bombeKernel`/`bombeOK`).
5. **Per-block reduction** — block-max via shared memory (tree reduction) or warp
   shuffle `__shfl_down_sync`.
6. **Memory:** wirings → `__constant__` (<4 KB, broadcast); trigram table (70 KB) →
   `__device__` global (fits in L2 cache); quadgram (1.8 MB) → global.

### On the CPU (host)
1. **Loading** the quadgram/trigram tables and ciphertext; **uploading** wirings to the
   GPU.
2. **Orchestration** — looping over 1344 wheel orders, launching kernels, copying back
   block maxima.
3. **Selecting the top-N** (`std::partial_sort`, `std::sort`).
4. **Expensive precise final scoring** — a full quadgram hill-climb (`hillClimb`) with
   steepest-ascent + restarts + 2-opt, **only on the top-N**.
5. **The exact simulator** (`EnigmaCPU`) for verification and plaintext.
6. **CPU mirror of the bombe** (`cpuBombe`) to recover the actual plugboard;
   `xSolve`/`covHillClimb`; `jointHillClimb` for depth.

**Why this split:** the GPU excels at an *embarrassingly parallel coarse filter*
(billions of cheap, independent evaluations, small per-thread memory). The CPU is
better at *branch-heavy, precise refinement* on a few hundred survivors.

**Sources (CUDA techniques):**
- CUDA C++ Programming Guide: https://docs.nvidia.com/cuda/cuda-c-programming-guide/
- Constant & shared memory: https://developer.nvidia.com/blog/using-shared-memory-cuda-cc/
- Warp-level primitives (`__shfl_down_sync`): https://developer.nvidia.com/blog/using-cuda-warp-level-primitives/
- Mark Harris, *Optimizing Parallel Reduction in CUDA* (block reduction): https://developer.download.nvidia.com/assets/cuda/files/reduction.pdf

---

## 5. Statistical Tools (Every Concept in Detail)

### 5.1 Index of Coincidence (IoC)

**History:** introduced by **William F. Friedman, 1922** (*"The Index of Coincidence
and Its Applications in Cryptography"*) — a foundation of modern cryptanalysis.

**Definition** (the probability that two random letters are the same):

```
IoC = Σ f_i (f_i - 1) / ( N (N-1) )      (i = A..Z), N = text length
```

**Expected values:**
- Random text: 1/26 = **0.0385**
- English prose: ~0.0667
- German prose: ~**0.0762** (= Σ pᵢ²)
- German naval text (numbers, X-markers): ~**0.057** (not prose)

**Why it works:** meaningful language has uneven letter frequencies → higher IoC; a
wrong decryption → pseudo-random → IoC ≈ 0.0385. It's parameter-free and cheap (just
counting) → an ideal first filter. In the code: `decIoC` (GPU), `iocScore` (CPU).
Calibrated thresholds: **0.042** without a plugboard, **0.030** with ≥5 pairs.

**Sources:**
- https://en.wikipedia.org/wiki/Index_of_coincidence
- Tutorial + code: https://www.dcode.fr/index-coincidence
- Friedman 1922 (original monograph, digitized): https://www.britannica.com/topic/The-Index-of-Coincidence-and-Its-Applications-in-Cryptography

### 5.2 Trigram / quadgram log-probability

**Idea:** the probability of **sequences of 3 (trigram) / 4 (quadgram) letters**, drawn
from a large German corpus (`data/german_quadgrams.txt`: 291,654 entries;
`data/german_trigrams.txt`: 17,142 entries).

**Math (why the logarithm):** a text's score is the product of the probabilities of all
windows; a product of many small numbers → underflow. Hence the sum of logarithms:

```
S = Σ_k log10( P(gram_k) )      (negative; the goal is to MAXIMIZE it)
```

**Floor for unseen n-grams** (so that a single log(0) = −∞ doesn't wreck the score) —
[`enigma_breaker.cu`](enigma_breaker.cu):
```c
double floor_v = log10(0.01/tot);
out[i] = cnt[i]>0 ? log10(cnt[i]/tot) : floor_v;
```

**Trigram vs. quadgram:** quadgram is a sharper discriminator but larger and more
sensitive to short messages; trigram is denser/more robust. Hence: **trigram on the
GPU** (fast, 70 KB), **quadgram on the CPU** (precise). Reference values: correct
German text ≈ **−5.6/char** (quadgram); gibberish < −6.7.

**Sources:**
- Quadgram statistics and fitness functions: https://en.wikipedia.org/wiki/N-gram
- Breaking Enigma with n-grams (end-to-end example): https://www.bytereef.org/m4_project.html
- Source of this project's tables (`torognes/enigma`): https://github.com/torognes/enigma
- Heidi Williams, *Applying Statistical Language Recognition Techniques in the
  Ciphertext-only Cryptanalysis of Enigma*, Cryptologia 24(1), 2000: https://www.tandfonline.com/doi/abs/10.1080/0161-110091888745

### 5.3 `scoreXsplit` — quadgram scoring by X-segments

**Historical fact:** German operators used the letter **`X` as a space/period** and
spelled out punctuation/numbers (e.g. `VONXOBERKOMMANDOXDERXMARINE`, numbers as
`EINS ZWO DREI`). So `X` separates actual words.

**Code** ([`enigma_crib_solver.cu`](enigma_crib_solver.cu)):
```c
static float scoreXsplit(const std::string& p, const QuadgramScorer& qg){
    float s=0.f; size_t i=0,n=p.size();
    while(i<n){
        size_t j=i; while(j<n && p[j]!='X') j++;  // scan to the next X
        if(j-i>=4) s+=qg.score(p.substr(i,j-i));   // score ONLY the segment between X's
        i=j+1;
    }
    return s;
}
```
**How it works:** splits the plaintext at every `X`, scores only segments of length ≥4
with the quadgram model, and sums them.

**Why it's better than scoring the whole text:** a plain quadgram over the entire text
has an **X-bias** — hill-climbing is happy to introduce a spurious `X↔A` stecker to
"clean up" the X's and inflate the score, which breaks the correct decryption.
`scoreXsplit` rewards **correct segmentation** and ignores X's → no bias.
`scoreXsplitTri` does the same with trigrams and a ≥3 threshold (more robust on short
messages).

**Sources:**
- Message format and procedure (X, spelling out): https://www.cryptomuseum.com/crypto/enigma/m4/index.htm
- https://en.wikipedia.org/wiki/Enigma_machine#Operation

### 5.4 `phraseCoverage` — matched language model
```c
// fraction of plaintext letters covered by any of the 26 known phrases as a substring
```
**What it is:** for the synthetic test messages (built exactly from those phrases), a
correct decryption → coverage ≈ 1.0. **Limitation:** it's a *matched* model — it only
works on the test corpus; for real messages (unknown content) it's useless. Used as the
objective for `covHillClimb` because it gives a smooth gradient toward the correct
plugboard.

### 5.5 `FastEval` — a mathematical optimization for decryption
**Insight:** the rotor+reflector permutation **at a given position** is **independent
of the plugboard**:

```
c -> plug[ P_i[ plug[c] ] ]      (P_i = no-plug permutation at position i)
```

**What it does:** precomputes `P_i[x]` for every position (N×26) **once per key**; after
that, each decryption is just O(N) lookups instead of ~8 rotor passes per character.
Since hill-climbing runs hundreds of evaluations per key, this speeds it up several
times over. Assumption: thin/left ring = 0.

---

## 6. Attack Algorithms (History + Code + Math)

### 6.1 Plugboard hill-climbing
**What it is:** local optimization — from the current state, try all "neighbors", move
to the best one that improves the score, repeat. **Steepest ascent** = pick the best
neighbor (not the first improving one).

**Problem:** local maxima. Addressed in
[`plugboard_hc.h`](search/plugboard_search/plugboard_hc.h):
- **Restarts** (30) from random starting states → take the global best.
- **Operations:** add / remove / swap one end / replace a pair.
- **2-opt post-refinement** (`twoOptRefine`): changes **two pairs at once** (4 letters)
  — escapes maxima that a single swap can't; run as a post-processing step (not inside
  the main loop).

**Sources:**
- Hill climbing: https://en.wikipedia.org/wiki/Hill_climbing
- 2-opt: https://en.wikipedia.org/wiki/2-opt
- Simulated annealing (an alternative): https://en.wikipedia.org/wiki/Simulated_annealing
- Applied to Enigma (plugboard hill-climbing): https://www.bytereef.org/m4_project.html

### 6.2 Turing bombe (`bombeOK` / `cpuBombe`)
**History:** the Poles (**Marian Rejewski**, 1938) built the *bomba kryptologiczna*
first. **Alan Turing** redesigned it for a crib-based attack; **Gordon Welchman** added
the **diagonal board** (a drastic speedup). The first bombe, "Victory", was operational
in March 1940.

**Principle:** exploit reciprocity to *drag* a crib across the ciphertext only where no
letter clashes with itself; for every rotor setting, **propagate plugboard
implications**; if a **contradiction** appears → that setting is impossible (~100%
eliminated).

![Turing bombe — crib drag + plugboard constraint propagation](diagram_bombe.svg)

**Code** ([`enigma_crib_solver.cu`](enigma_crib_solver.cu)):
```c
__device__ bool bombeOK(...) {
    for(int g=0; g<26; g++){          // assume a stecker for the crib's first letter
        unsigned char S[26]; ...      // partial involution (255 = unknown)
        if(!dSet(S, crib[0], g)) continue;
        // for each i: if S[a] is known, compute where it goes through the rotors (npEnc)
        // -> it must equal S[b]; if S[b] is already set and disagrees -> contradiction (bad)
        while(changed && !bad){ ... }
        if(!bad) return true;          // a consistent plugboard exists
    }
    return false;
}
```
- `dSet` sets a pair in S; returns false on a contradiction — the software equivalent of
  Welchman's diagonal board (a↔b implies b↔a).
- `npEnc` = the no-plug permutation (rotors+reflector) — what the physical bombe did
  with its rotors.
- Search space: **26⁵** (standard) or **26⁶** in R6 mode (turnover-aware middle ring;
  ~309M, ~26× slower, ~100% accurate).
- `cpuBombe` recovers the **actual 10 pairs** on a surviving candidate.

**Sources:**
- Bombe (machine and logic): https://en.wikipedia.org/wiki/Bombe
- Diagonal board / Welchman: https://en.wikipedia.org/wiki/Bombe#The_principle_of_the_bombe
- Animated explanation (Graham Ellsbury): https://en.wikipedia.org/wiki/Bombe#The_principle_of_the_bombe
- Crib / known-plaintext: https://en.wikipedia.org/wiki/Known-plaintext_attack
- Rejewski and the Polish bomba: https://en.wikipedia.org/wiki/Cryptologic_bomb

### 6.3 Gillogly ciphertext-only attack
**History:** **Jim Gillogly, *"Ciphertext-only Cryptanalysis of Enigma"*, Cryptologia
19(4), 1995** — showed Enigma can be broken **without a crib**: first find the rotor
settings by maximizing IoC/n-gram score, then hill-climb to recover the plugboard.

**Two forms in the code:**
- `triHC_direct` ([`enigma_breaker.cu`](enigma_breaker.cu)): for each position, decrypts
  all characters, then runs a 3-pass trigram hill-climb tracking `plug[]` with a
  **streaming trigram delta** (only the score change on a swap, O(N)). Trigram is used
  because the German trigram distribution is more skewed (DER/EIN/UND) → better SNR.
- `iocPlugHC` ([`crack_u264.cu`](crack_u264.cu), [`enigma_blind.cu`](enigma_blind.cu)):
  the same idea, but the score is **IoC with the plugboard applied on both sides**,
  ADD-only up to 10 pairs; the first pass tries all 325 pairs (to escape the flat
  no-plug plateau).

**Sources:**
- Gillogly 1995 (Cryptologia): https://www.tandfonline.com/doi/abs/10.1080/0161-119591883944
- Overview of ciphertext-only approaches: https://www.bytereef.org/m4_project.html

### 6.4 Depth attack (`jointHillClimb`)
**History:** **"depth"** = multiple messages under the same daily key (differing only
in position). Bletchley used this extensively; **Banburismus** (Turing) is a sequential
Bayesian procedure (measured in *bans/decibans*) that narrows down rotor candidates from
depth.

**Math** ([`enigma_blind_depth.cu`](enigma_blind_depth.cu)): the single-message blind
attack fails because plugboard hill-climbing **overfits** (a spurious stecker inflates
IoC on one message). Depth scores a candidate as the **SUM over messages**:

```
S_joint(plug) = Σ_m  qg( decrypt(m, plug) )
```

A spurious stecker that helps message 1 **hurts** message 2 → a shared plugboard
**forces the TRUE key**, and the signal grows with the total combined length. That's why
depth works while a single message doesn't.

**Sources:**
- Banburismus: https://en.wikipedia.org/wiki/Banburismus
- Ban (unit of information): https://en.wikipedia.org/wiki/Ban_(unit)
- Depth (cryptanalysis): https://en.wikipedia.org/wiki/Cryptanalysis_of_the_Lorenz_cipher

---

## 7. What Each Program Does

| Program | Attacker's assumption | Pipeline (GPU → CPU) | Historical parallel |
|---|---|---|---|
| [`enigma_breaker.cu`](enigma_breaker.cu) | ciphertext only, 1 message | GPU: Stage A triHC over 1344×26⁴ → ring sweep 26³. CPU: quadgram HC on top-50 | Gillogly 1995 |
| [`crack_u264.cu`](crack_u264.cu) | known daily key (key sheet) | GPU: 26⁴ positions × IoC-plug-HC. CPU: quadgram HC on top-256 | reading with a known daily key |
| [`enigma_blind.cu`](enigma_blind.cu) | ciphertext only, blind | GPU: 1344×26⁴ × IoC-plug-HC. CPU: quadgram HC on the global top-N | Gillogly, full sweep |
| [`enigma_blind_depth.cu`](enigma_blind_depth.cu) | multiple messages, same key | GPU: find position per message. CPU: shared plugboard (joint HC) | depth / Banburismus |
| [`enigma_crib_solver.cu`](enigma_crib_solver.cu) | known crib | GPU: bombe 26⁵/26⁶. CPU: recover plugboard (cpuBombe) + xSolve + ring split | Turing/Welchman bombe |

**STEP 0 — verification (CPU):** [`enigma_cpu.cpp`](core/enigma_cpu/enigma_cpu.cpp) must
decrypt the authentic **U-264** message (Beta II IV I, B-thin, ring 01 01 01 22, key
VJNA, 10 plugboard pairs) into `VONVONJLOOKS...`. "von von Looks" is the signature of
Kptlt. **Hartwig Looks**, commander of U-264 (message from Nov. 1942).

**Sources:**
- M4 Project (distributed break of 3 authentic M4 messages, Stefan Krah): https://www.bytereef.org/m4_project.html
- Original intercepted M4 messages from 1942: https://www.bytereef.org/m4_project.html (the "messages" section)

---

## 8. Key Mathematical Finding of This Project

The most important result (documented in [`crack_u264.cu`](crack_u264.cu)):

> Decrypting with the **correct** key but **without the plugboard** is, for a message
> with 10 pairs, **statistically indistinguishable from random text** (IoC 0.040 ≈
> random's 0.0385).

**Why:** a no-plug decryption isn't `P(plaintext)` but rather
`M_i ∘ P ∘ M_i ∘ P(plaintext)` — where `P` is the real plugboard missing on both sides,
and `M_i` is the rotor permutation that changes with every character. This "smears" the
signal into pseudo-randomness.

**Consequence:** the only discriminator for hard plugboards is **actually recovering the
plugboard on both sides** (`iocPlugHC` / `cpuBombe`), not scoring the no-plug output.
That's why Stage A of the main breaker *by design* does not find the correct key in the
top-100 for 10 pairs — it returns the top-1000+, which the plugboard stage then filters
down. **This is not a bug — it's a mathematical limit.**

---

## 9. Build & Run Reference

Verified environment: RTX 4080 SUPER (CC 8.9), CUDA 12.4, MSVC 14.44, native VS ninja.

**CUDA `.exe` (direct nvcc):**
```bat
call "...\VC\Auxiliary\Build\vcvars64.bat"
nvcc -ccbin "...\14.44.35207\bin\Hostx64\x64\cl.exe" ^
     -std=c++17 -arch=sm_89 -O3 --use_fast_math -I. ^
     -o build\output.exe core\enigma_gpu\source.cu
```

Build scripts in this repo:
- [`build.bat`](build.bat) — unified build for all attack tools (`crack`, `crib`,
  `depth`, `blind`, `breaker`, `diag` targets)
- [`build.ps1`](build.ps1) — CMake/Ninja build for the core pipeline
  (`verify_r1`/`verify_r2`/`verify_r3`)

Core verification (CPU): `build\verify_r1.exe` (round-trip + U-264),
`build\verify_r2.exe data` (IoC/trigram/quadgram).

> Note: `extern __constant__` in a header plus its definition in a `.cu` file produces a
> C2086 error; that's why each `.exe` is self-contained (the core is copied into every
> `.cu` file). The cost is code duplication.

---

## 10. File Map

```
config.h                              Wirings, notches, EnigmaKey
core/enigma_cpu/enigma_cpu.{h,cpp}    Verified CPU M4 simulator (STEP 0)
core/enigma_gpu/brute_r3..r6.cu       GPU kernel development phases (IoC, multi-filter, top-N, ring)
filters/ioc, trigram, quadgram        CPU scorers
search/plugboard_search/plugboard_hc.h  CPU plugboard hill-climb (steepest+restart+2opt)
enigma_breaker.cu                     Main: Gillogly triHC + ring + quadgram HC
crack_u264.cu                         Full-plugboard IoC-HC (known daily key)
enigma_blind.cu                       Ciphertext-only, sweeps 1344 wheel orders
enigma_blind_depth.cu                 Depth (multiple messages, same key, shared plugboard)
enigma_crib_solver.cu                 GPU Turing bombe (known crib), R6 turnover-aware
data/german_{quadgrams,trigrams}.txt  Corpus frequency tables
```

---

## 11. Sources / Further Reading

> Links checked (June 2026). Academic papers on `tandfonline.com` (Gillogly, Williams,
> Hamer) **resolve but sit behind a paywall** — the abstract is public, full text via a
> library subscription / Google Scholar. The original Friedman 1922 monograph isn't
> publicly digitized (the link goes to Britannica's description of the publication).

**History and the machine**
- Enigma (general): https://en.wikipedia.org/wiki/Enigma_machine
- Enigma M4 (Crypto Museum): https://www.cryptomuseum.com/crypto/enigma/m4/index.htm
- Rotor/reflector wirings: https://www.cryptomuseum.com/crypto/enigma/wiring.htm
- Rotor details / turnover / double-step: https://en.wikipedia.org/wiki/Enigma_rotor_details
- Cryptanalysis of the Enigma: https://en.wikipedia.org/wiki/Cryptanalysis_of_the_Enigma
- Battle of the Atlantic: https://en.wikipedia.org/wiki/Battle_of_the_Atlantic
- Capture of U-559: https://en.wikipedia.org/wiki/German_submarine_U-559
- Bletchley Park (Tony Sale): http://www.codesandciphers.org.uk/

**Mathematics and statistics**
- Index of Coincidence: https://en.wikipedia.org/wiki/Index_of_coincidence
- IoC tutorial + code: https://www.dcode.fr/index-coincidence
- Friedman 1922 (original monograph): https://www.britannica.com/topic/The-Index-of-Coincidence-and-Its-Applications-in-Cryptography
- Quadgram statistics: https://en.wikipedia.org/wiki/N-gram
- Number of Enigma settings: https://en.wikipedia.org/wiki/Enigma_machine#Mathematical_analysis

**Attack algorithms**
- Breaking Enigma (end-to-end, n-gram + hill-climb): https://www.bytereef.org/m4_project.html
- Gillogly 1995 (ciphertext-only): https://www.tandfonline.com/doi/abs/10.1080/0161-119591883944
- Williams 2000 (statistical language model): https://www.tandfonline.com/doi/abs/10.1080/0161-110091888745
- Bombe: https://en.wikipedia.org/wiki/Bombe
- Bombe — animated: https://en.wikipedia.org/wiki/Bombe#The_principle_of_the_bombe
- Banburismus: https://en.wikipedia.org/wiki/Banburismus
- Hill climbing: https://en.wikipedia.org/wiki/Hill_climbing
- 2-opt: https://en.wikipedia.org/wiki/2-opt

**GPU / CUDA**
- CUDA C++ Programming Guide: https://docs.nvidia.com/cuda/cuda-c-programming-guide/
- Shared memory: https://developer.nvidia.com/blog/using-shared-memory-cuda-cc/
- Warp-level primitives: https://developer.nvidia.com/blog/using-cuda-warp-level-primitives/
- Parallel reduction (Mark Harris): https://developer.download.nvidia.com/assets/cuda/files/reduction.pdf

**Practical / projects**
- M4 Project (Stefan Krah, distributed break): https://www.bytereef.org/m4_project.html
- Source of the corpus tables (`torognes/enigma`): https://github.com/torognes/enigma
- Online Enigma simulator (for experiments): https://www.boxentriq.com/ciphers/enigma-machine

---

*This document was generated as a reference alongside the source code. Terms, formulas,
and links are tied to specific files and functions in this repo.*
