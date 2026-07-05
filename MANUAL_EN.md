# Enigma M4 Breaker — User Manual (English)

A GPU-accelerated cryptanalysis suite (C++/CUDA, Windows) that breaks the German
naval **Enigma M4** cipher. It reproduces, on a single modern GPU, the historical
attacks that Bletchley Park used against U-boat traffic.

- Repo root: this repository (every path below is relative to it)
- Built executables: `build\`

---

## PART I — HISTORY

### The Enigma machine
Enigma was an electro-mechanical rotor cipher used by Nazi Germany. A keypress sends
current through a **plugboard (Steckerbrett)**, three or four **rotors**, a
**reflector**, and back, lighting a different letter. Because the rotors step on every
keypress, the substitution changes constantly (polyalphabetic). Two properties matter:
- **No letter ever encrypts to itself** (consequence of the reflector). This is the
  single biggest weakness — it powers the "crib-dragging" filter.
- The **plugboard** is a fixed letter-swap applied at input and output.

### Enigma M4 — "Triton" / "Shark"
- **What:** a 4-rotor naval Enigma. The 4th rotor is a thin **Greek rotor**
  (**Beta** or **Gamma**) that does **not** rotate, paired with a thin reflector
  (**B-thin** or **C-thin**). The three normal rotors are chosen from **I–VIII**.
  Plugboard: typically **10 cable pairs**.
- **Who used it:** the **Kriegsmarine**, specifically the **U-boat fleet** in the
  Atlantic (network code-named *Triton*; called *Shark* by the Allies).
- **When:** introduced **1 February 1942**. The extra rotor caused an Allied
  **"blackout"** of roughly 10 months, during which U-boats sank Allied convoys
  with near impunity.
- **Keyspace:** wheel order (8·7·6 = 336) × Greek rotor (2) × reflector (2) ×
  ring settings × 26⁴ start positions × plugboard. The wheel-order part alone is
  **1344** combinations.

### What was secret vs. what was transmitted
Both sender and receiver shared a **monthly key sheet** (from the *K-book*). The
**daily key** was secret and **never transmitted**:
- **Walzenlage** — wheel order (which rotors, in which order)
- **Ringstellung** — ring settings
- **Steckerverbindungen** — plugboard
Only the **per-message start position** (the *message key*) changed per message, and
it was sent **encrypted** in an indicator (naval M4 hid it with secret **bigram
substitution tables**). So an interceptor saw only ciphertext + a disguised position —
never the rotor order, rings, or plugboard. All of those had to be **broken**.

Example of what went on the air (U-264, illustrative indicator):
```
PYR DE UAK  2105 = 192 =        <- preamble (clear): call signs, time, letter count
QF LY                          <- indicator: the encrypted start position (= VJNA)
NCZW VUSX PNYM INHZ ...        <- ciphertext, in 4-letter groups
```
The wheel order `Beta II IV I` appears nowhere in the transmission.

### How M4 was actually broken
1. **Captures (pinches).** Weather ships *München*/*Lauenburg* (1941), *U-110* (1941),
   and crucially **U-559 (Oct 1942)** — sailors retrieved the **weather short-signal
   book** and **bigram tables** as the boat sank (two men died doing it). This restored
   the entry into Shark.
2. **Cribs (known plaintext).** Stereotyped messages (weather reports, `WETTER`,
   `VONVON`, grid squares) gave guessable plaintext.
3. **Turing-Welchman Bombe.** Given a crib, the bombe found rotor settings + plugboard
   consistent with it, rejecting wrong settings by contradiction.
4. **Banburismus & depth.** Decoded indicators revealed message positions; messages on
   the same/near positions formed **depth**, dramatically narrowing the search.

The famous test message used throughout this project, **U-264 (25 Nov 1942)**, was
broken as part of the modern *M4 Project* (Stefan Krah, 2006) and decrypts to
`VONVONJLOOKS…`.

---

## PART II — WHAT THIS PROJECT BREAKS

This suite breaks **Enigma M4** exactly as specified above:
- Rotors I–VIII, Greek **Beta/Gamma**, thin reflectors **B/C**, **10-pair** plugboard.
- The wiring/double-stepping is **verified** against the authentic **U-264** message.
- A synthetic test corpus (`tests/test_messages/`, 420 messages) provides ground-truth
  keys so success can be measured. Plaintext is built from 27 fixed German military
  phrases (with `X` as the word separator, as the Germans did), and every message starts
  with one — which makes crib attacks possible and measurable.
- "Depth" corpora (`tests/test_messages_day1/2/3`) simulate one day's traffic that
  shares a daily key — the scenario for the depth attack.

---

## PART III — ATTACK TYPES (and how they connect)

| Tool | Scenario it models | What it needs | What it recovers |
|---|---|---|---|
| `crack_u264` | Daily key already recovered (e.g. from a captured key sheet) | Wheel order + rings | Message position + full plugboard |
| `enigma_crib_solver` | Known/guessed plaintext fragment | A crib ≥ ~20 letters | Wheel order + ring + plugboard (full key) |
| `enigma_blind_depth` | A day's traffic sharing one daily key | Several messages (same key), rings | Wheel order + plugboard (depth) |
| `enigma_blind` | One message, nothing known | — | (Does **not** work reliably — see below) |
| `enigma_breaker` (old) | Single-message ciphertext-only via cheap heuristic | — | Fails for 10 plugs (kept for reference) |

**Why single-message blind fails, but the others work.** With 10 plugboard pairs, a
no-plugboard decryption of the correct key has Index-of-Coincidence ≈ **0.040** — the
same as random text. So no cheap statistic can pick the right rotor order from ciphertext
alone. The signal only appears once you **recover the plugboard**. The working tools each
supply a different way to get that signal:
- **crack_u264** assumes the rotors/rings are known, so it can afford a full plugboard
  hill-climb at each candidate position.
- **crib solver** uses a crib + a GPU Turing-bombe: the crib constrains the plugboard so
  wrong settings contradict.
- **depth** uses many messages: one **shared** plugboard must make *all* of them German;
  a wrong wheel order cannot, so the correct one stands out (joint score ≈ −5.6/char vs
  ≈ −8.3/char for everything else).

**Historical connection.** Capture → bigram tables → read indicators → message positions
→ **depth** (`enigma_blind_depth`). Capture → weather book → **cribs**
(`enigma_crib_solver`). Recovered daily key → trivial message-key recovery
(`crack_u264`). The suite is the same attack tree, on a GPU.

---

## PART IV — COMMAND-LINE USAGE

Run all tools from the repository root (the folder containing `build.bat`):
```
cd path\to\EnigmaM4Breaker
```
Every tool prints a **wall-clock elapsed time** at the end.

### 1) crack_u264 — break a message given the daily rotor key
```
build\crack_u264.exe data [ciphertext.txt] [maxPairs] [topN]
```
- `data` — folder with `german_quadgrams.txt`, `german_trigrams.txt`
- `ciphertext.txt` — optional; if omitted, the built-in **U-264** message is used
- `maxPairs` — plugboard pairs to search (default 10)
- `topN` — candidate positions sent to CPU refinement (default 256)
- **Example:** `build\crack_u264.exe data`
- **Expected:** message key `VJNA`, plugboard `AT BL DF GJ HM NW OP QY RZ VX`,
  plaintext `VONVONJLOOKS…`, ~4 min.

### 2) enigma_crib_solver — blind crib + Turing-bombe attack
```
build\enigma_crib_solver.exe data <ciphertext.txt> [wheelStart] [wheelCount] [crib] [flags]
```
- `ciphertext.txt` — the message (letters A–Z; non-letters ignored)
- `wheelStart wheelCount` — limit the 1344 wheel orders (e.g. `0 1344` = all,
  or `79 1` = only wheel index 79 for a quick test on a known order)
- `crib` (5th positional) — three modes:
  - *(omitted)* **phrase mode**: tries the 26 built-in corpus phrases at offset 0
  - `DICT` **dictionary mode**: a dictionary of phrases + general German cribs, each
    dragged across all positions until one breaks (for real messages)
  - `<WORD>` **general mode**: that one crib, dragged across every position (option B)
- **Flags** (anywhere in argv):
  - `R6` — 26⁶ ring-search (turnover-aware; solves the hard "edge-case" messages;
    ~26× slower per full sweep)
  - `TRI` — score with trigrams instead of quadgrams (more robust on short messages)
- **Examples:**
  - Full blind solve: `build\enigma_crib_solver.exe data msg.txt 0 1344`
  - Quick check on a known wheel: `build\enigma_crib_solver.exe data id6.txt 430 1 R6`
  - Real message, unknown content: `build\enigma_crib_solver.exe data msg.txt 0 1344 DICT`
- **Expected:** `=== SOLVED ===` with reflector, wheels, rings, positions, plugboard,
  and plaintext. ~3–20 min depending on where the correct crib lands.

### 3) enigma_blind_depth — ciphertext-only DEPTH attack (no crib)
```
build\enigma_blind_depth.exe data <ct_lines.txt> [wStart wCount] [r0 r1 r2 r3] [maxPairs] [nSub]
```
- `ct_lines.txt` — **one ciphertext per line** (a day's traffic sharing one daily key)
- `wStart wCount` — wheel-order range (e.g. `0 1344` = all)
- `r0 r1 r2 r3` — ring settings (read **only if all four are given**)
- `maxPairs` — plugboard pairs (default 10), `nSub` — number of longest messages used
  in the joint hill-climb (default 8)
- **Example (proven case):**
  ```
  build\enigma_blind_depth.exe data tests\test_messages_day1\ciphertexts.txt 189 24 0 0 9 19 10 6
  ```
- **Expected:** wheel **201** (`Beta V VII IV / B`), joint score ≈ −5.6/char vs ≈ −8.3
  for all wrong orders, full 10-pair plugboard recovered. ~48 min for 24 wheel orders;
  a full 1344 sweep is multi-hour.

### 4) Diagnostics / reference
- `build\ioc_diag.exe` — shows U-264 IoC with/without plugboard (proves the 0.040 limit)
- `build\verify_r1.exe`, `verify_r2.exe`, `verify_r3.exe` (via `build.ps1`) —
  component self-tests (simulator, scoring, GPU kernel)
- `build\enigma_breaker.exe data` — old integrated breaker (does **not** crack 10-plug
  messages; kept for reference)

---

## PART V — COMPILATION & INSTALLATION

### Requirements
| Component | Version used | Notes |
|---|---|---|
| GPU | NVIDIA, Compute Capability ≥ 6.0 (tested RTX 4080 SUPER, CC 8.9) | CUDA-capable |
| CUDA Toolkit | **12.4** | provides `nvcc`; must be on `PATH` |
| Host C++ compiler | **MSVC 14.44.35207** (Visual Studio 2022/18) | CUDA 12.4 needs MSVC ≤ 14.4x |
| OS | Windows 10/11 x64 | |
| Language data | `data\german_quadgrams.txt`, `german_trigrams.txt` | included |

### Installation steps
1. **Install Visual Studio** (2022 or newer) with the **"Desktop development with C++"**
   workload. This provides `cl.exe` and `vcvars64.bat`. Note the MSVC version folder
   (e.g. `…\VC\Tools\MSVC\14.44.35207\`).
2. **Install the CUDA Toolkit 12.4.** Confirm with `nvcc --version`. Ensure
   `…\CUDA\v12.4\bin` is on `PATH`.
3. **Install a recent NVIDIA driver** that supports CUDA 12.4.
4. Clone/place the repository anywhere — the build scripts locate the source tree from
   their own location, no path editing required for that part. You only need to point
   them at your VS/MSVC install if it differs from the defaults (see below).

### Building
Two build paths, covering different parts of the suite:

**`build.bat`** — the attack tools (`crack_u264`, `enigma_crib_solver`,
`enigma_blind_depth`, `enigma_blind`, `enigma_breaker`, `ioc_diag`). Compiles the shared
CPU objects with `cl.exe`, then links each `.cu` with
`nvcc -ccbin <cl.exe> -arch=sm_89 -O3 --use_fast_math`. Run from the repo root:
```
build.bat                REM build everything into build\
build.bat crack          REM just crack_u264.exe
build.bat crib sm_86     REM just enigma_crib_solver.exe, RTX 30-series arch
```
Valid targets: `all` (default) `objs` `crack` `crib` `depth` `blind` `breaker` `diag`.
If your Visual Studio install or MSVC toolset version differs from the defaults baked
into the script, override them with environment variables before running:
```
set VS_VCVARS=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat
set MSVC_CLPATH=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.40.33807\bin\Hostx64\x64\cl.exe
build.bat
```

**`build.ps1`** — the CMake/Ninja core pipeline (`verify_r1`, `verify_r2`, `verify_r3`).
```
.\build.ps1                # build all CMake targets
.\build.ps1 verify_r1      # build a single target
.\build.ps1 -VsDir "C:\Program Files\Microsoft Visual Studio\2022\Community"
```
Note: `verify_r3`'s CUDA architecture is hardcoded to `89` (RTX 40-series) in
`CMakeLists.txt` — edit `CUDA_ARCHITECTURES` there if you're on a different GPU.

- Change the arch argument/flag to match your GPU (e.g. `sm_86` for RTX 30-series,
  `sm_75` for RTX 20-series/GTX 16-series).

### Troubleshooting
- **`LNK1104: cannot open file …exe`** — the previous run is still using the file:
  `Stop-Process -Name enigma_crib_solver,crack_u264,enigma_blind_depth -Force`.
- **`nvcc` not found** — CUDA `bin` not on `PATH`.
- **`cl` not found / wrong version** — `build.bat`/`build.ps1` call `vcvars64.bat`;
  ensure `VS_VCVARS`/`MSVC_CLPATH` (or `-VsDir`) point at your actual install.
- **Wrong results / crashes on a different GPU** — set the correct `-arch=sm_XX`.

---

## PART VI — KEY FINDINGS & LIMITATIONS
- No-plugboard IoC of the correct key ≈ random (0.040) → single-message blind is
  infeasible on one GPU; you need a crib or depth.
- Minimum useful crib length ≈ **20 letters** of connected known text. Short common
  words alone flood the search.
- The simulator fires rotor turnover on the **absolute** window position (historically
  correct), so ring and position are **not** degenerate — the ring must be searched
  (`R6` toggle for the hard cases).
- The German n-gram table is real German (no `X` separators); the solver scores with an
  **X-segment** scheme so it isn't fooled by the corpus convention.

For full technical detail and the development log see `informacije_enigma.txt`.
