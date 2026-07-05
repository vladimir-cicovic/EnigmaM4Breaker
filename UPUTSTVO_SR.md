# Enigma M4 Breaker — Uputstvo za korišćenje (srpski)

GPU-ubrzani kriptoanalitički paket (C++/CUDA, Windows) koji razbija nemačku mornaričku
šifru **Enigma M4**. Na jednom modernom GPU reprodukuje istorijske napade koje je
Bletchley Park koristio protiv saobraćaja podmornica.

- Koren repozitorijuma: ovaj repo (sve putanje ispod su relativne u odnosu na njega)
- Iskompajlirani programi: `build\`

---

## DEO I — ISTORIJAT

### Mašina Enigma
Enigma je elektromehanička rotorska šifra nacističke Nemačke. Pritisak na taster šalje
struju kroz **plugboard (Steckerbrett)**, tri ili četiri **rotora**, **reflektor** i
nazad, paleći drugo slovo. Pošto rotori koraknu pri svakom pritisku, supstitucija se
stalno menja (polialfabetska). Dve osobine su ključne:
- **Nijedno slovo se nikad ne šifruje u samo sebe** (posledica reflektora). To je
  najveća slabost — pokreće „crib-dragging" filter.
- **Plugboard** je fiksna zamena slova, primenjena na ulazu i izlazu.

### Enigma M4 — „Triton" / „Shark"
- **Šta:** 4-rotorska mornarička Enigma. Četvrti rotor je tanki **grčki rotor**
  (**Beta** ili **Gamma**) koji se **NE okreće**, uparen sa tankim reflektorom
  (**B-thin** ili **C-thin**). Tri obična rotora biraju se iz **I–VIII**. Plugboard:
  obično **10 parova kablova**.
- **Ko je koristio:** **Kriegsmarine**, konkretno **flota podmornica** u Atlantiku
  (mreža kodnog imena *Triton*; Saveznici je zvali *Shark*).
- **Kada:** uvedena **1. februara 1942.** Dodatni rotor izazvao je savezničku
  **„tamu" (blackout)** od oko 10 meseci, tokom koje su podmornice potapale konvoje
  gotovo nekažnjeno.
- **Prostor ključeva:** raspored rotora (8·7·6 = 336) × grčki rotor (2) × reflektor (2)
  × ringovi × 26⁴ početnih pozicija × plugboard. Samo deo sa rasporedom rotora je
  **1344** kombinacija.

### Šta je bilo tajno, a šta se slalo
I pošiljalac i primalac delili su **mesečnu tablicu ključeva** (iz *K-knjige*).
**Dnevni ključ** je bio tajan i **nikad se nije slao**:
- **Walzenlage** — raspored rotora (koji rotori, kojim redom)
- **Ringstellung** — ringovi
- **Steckerverbindungen** — plugboard
Po poruci se menjala samo **početna pozicija** (*message key*), i ona se slala
**šifrovano** u indikatoru (M4 ju je krio tajnim **bigramskim tablicama**). Presretač je
video samo šifrat + zamaskiranu poziciju — nikad raspored, ring ili plugboard. Sve to se
moralo **provaliti**.

Primer onoga što je išlo u eter (U-264, ilustrativan indikator):
```
PYR DE UAK  2105 = 192 =        <- preambula (otvoreno): pozivni, vreme, broj slova
QF LY                          <- indikator: šifrovana početna pozicija (= VJNA)
NCZW VUSX PNYM INHZ ...        <- šifrat, u grupama po 4 slova
```
Raspored rotora `Beta II IV I` se nigde u poruci ne pojavljuje.

### Kako je M4 stvarno probijen
1. **Zaplene (pinches).** Vremenski brodovi *München*/*Lauenburg* (1941), *U-110* (1941),
   i ključno **U-559 (okt 1942)** — mornari su izvadili **kratki vremenski šifarnik** i
   **bigramske tablice** dok je podmornica tonula (dvojica su poginula). To je vratilo
   ulaz u Shark.
2. **Cribovi (poznat plaintext).** Stereotipne poruke (vremenski izveštaji, `WETTER`,
   `VONVON`, kvadrati) davale su pogodljiv tekst.
3. **Turing-Welchman bombe.** Uz crib, bombe je nalazila postavke rotora + plugboard
   konzistentne s cribom, odbacujući pogrešne kontradikcijom.
4. **Banburismus i depth.** Dekodirani indikatori su otkrivali pozicije; poruke na
   istim/bliskim pozicijama činile su **depth**, što je drastično sužavalo pretragu.

Poznata test-poruka kroz ceo projekat, **U-264 (25. nov 1942)**, razbijena je u sklopu
modernog *M4 Project* (Stefan Krah, 2006) i dešifruje se u `VONVONJLOOKS…`.

---

## DEO II — ŠTA OVAJ PROJEKAT RAZBIJA

Paket razbija **Enigma M4** tačno kako je opisano:
- Rotori I–VIII, grčki **Beta/Gamma**, tanki reflektori **B/C**, **10-parni** plugboard.
- Ožičenje/double-stepping je **verifikovano** na autentičnoj poruci **U-264**.
- Sintetički test-skup (`tests/test_messages/`, 420 poruka) daje ključeve istine pa se
  uspeh može meriti. Plaintext je sastavljen od 27 fiksnih nemačkih vojnih fraza (sa `X`
  kao razmakom, kako su Nemci radili), i svaka poruka počinje jednom — što omogućava i
  meri crib napade.
- „Depth" skupovi (`tests/test_messages_day1/2/3`) simuliraju jednodnevni saobraćaj koji
  deli dnevni ključ — scenario za depth napad.

---

## DEO III — VRSTE NAPADA (i kako su povezani)

| Alat | Scenario | Šta mu treba | Šta vraća |
|---|---|---|---|
| `crack_u264` | Dnevni ključ već provaljen (npr. zaplenjena tablica) | Raspored + ring | Poziciju poruke + ceo plugboard |
| `enigma_crib_solver` | Poznat/pogođen deo teksta | Crib ≥ ~20 slova | Raspored + ring + plugboard (ceo ključ) |
| `enigma_blind_depth` | Dnevni saobraćaj sa istim ključem | Više poruka (isti ključ), ringovi | Raspored + plugboard (depth) |
| `enigma_blind` | Jedna poruka, ništa poznato | — | (Ne radi pouzdano — vidi dole) |
| `enigma_breaker` (stari) | Single-message preko jeftine heuristike | — | Pada za 10 parova (referenca) |

**Zašto single-message blind pada, a ostali rade.** Sa 10 plug parova, dekripcija BEZ
plugboarda tačnog ključa ima Index of Coincidence ≈ **0.040** — isto kao slučajan tekst.
Nijedna jeftina statistika ne može izabrati tačan raspored samo iz šifrata. Signal se
javi tek kad **vratiš plugboard**. Svaki alat koji radi daje drugačiji način da se taj
signal dobije:
- **crack_u264** pretpostavlja poznate rotore/ringove, pa može da radi pun plugboard
  hill-climb na svakoj kandidat-poziciji.
- **crib solver** koristi crib + GPU Turing-bombe: crib ograniči plugboard pa pogrešne
  postavke kontradiktorne.
- **depth** koristi više poruka: jedan **zajednički** plugboard mora sve da ih učini
  nemačkim; pogrešan raspored ne može, pa tačan sija (joint skor ≈ −5.6/znak naspram
  ≈ −8.3/znak za sve ostalo).

**Istorijska veza.** Zaplena → bigramske tablice → čitaš indikatore → pozicije poruka
→ **depth** (`enigma_blind_depth`). Zaplena → vremenski šifarnik → **cribovi**
(`enigma_crib_solver`). Provaljen dnevni ključ → trivijalan oporavak message-key-a
(`crack_u264`). Paket je isto stablo napada, na GPU.

---

## DEO IV — KORIŠĆENJE IZ KOMANDNE LINIJE

Sve alate pokreći iz korena repozitorijuma (folder u kom je `build.bat`):
```
cd putanja\do\EnigmaM4Breaker
```
Svaki alat na kraju štampa **proteklo vreme (wall-clock)**.

### 1) crack_u264 — razbij poruku dat dnevni rotorski ključ
```
build\crack_u264.exe data [sifrat.txt] [maxPairs] [topN]
```
- `data` — folder sa `german_quadgrams.txt`, `german_trigrams.txt`
- `sifrat.txt` — opciono; ako se izostavi, koristi se ugrađena **U-264**
- `maxPairs` — broj plug parova za pretragu (podrazumevano 10)
- `topN` — kandidat-pozicija na CPU dораду (podrazumevano 256)
- **Primer:** `build\crack_u264.exe data`
- **Očekivano:** message key `VJNA`, plugboard `AT BL DF GJ HM NW OP QY RZ VX`,
  plaintext `VONVONJLOOKS…`, ~4 min.

### 2) enigma_crib_solver — slepi crib + Turing-bombe napad
```
build\enigma_crib_solver.exe data <sifrat.txt> [wheelStart] [wheelCount] [crib] [flagovi]
```
- `sifrat.txt` — poruka (slova A–Z; ostalo se ignoriše)
- `wheelStart wheelCount` — ograniči 1344 rasporeda (npr. `0 1344` = svi, ili `79 1` =
  samo raspored 79 za brzu proveru na poznatom rasporedu)
- `crib` (5. pozicioni) — tri režima:
  - *(izostavljeno)* **phrase-mod**: probaj 26 ugrađenih korpus-fraza na offsetu 0
  - `DICT` **dict-mod**: rečnik fraza + opštih nemačkih cribova, svaki drag-ovan preko
    svih pozicija dok jedan ne razbije (za prave poruke)
  - `<REC>` **general-mod**: ta jedna reč, drag-ovana preko svake pozicije (opcija B)
- **Flagovi** (bilo gde u argv):
  - `R6` — 26⁶ pretraga ringa (turnover-aware; rešava teške „edge-case" poruke;
    ~26× sporiji pun sweep)
  - `TRI` — skor trigramima umesto quadgramima (robusniji na kratkim porukama)
- **Primeri:**
  - Pun slepi lom: `build\enigma_crib_solver.exe data poruka.txt 0 1344`
  - Brza provera na poznatom rasporedu: `build\enigma_crib_solver.exe data id6.txt 430 1 R6`
  - Prava poruka, nepoznat sadržaj: `build\enigma_crib_solver.exe data poruka.txt 0 1344 DICT`
- **Očekivano:** `=== SOLVED ===` sa reflektorom, rotorima, ringovima, pozicijama,
  plugboardom i plaintextom. ~3–20 min zavisno od toga gde upadne tačan crib.

### 3) enigma_blind_depth — ciphertext-only DEPTH napad (bez criba)
```
build\enigma_blind_depth.exe data <ct_linije.txt> [wStart wCount] [r0 r1 r2 r3] [maxPairs] [nSub]
```
- `ct_linije.txt` — **jedan šifrat po liniji** (dnevni saobraćaj sa istim ključem)
- `wStart wCount` — opseg rasporeda (npr. `0 1344` = svi)
- `r0 r1 r2 r3` — ringovi (čitaju se **samo ako daš sva četiri**)
- `maxPairs` — plug parovi (podrazumevano 10), `nSub` — broj najdužih poruka u joint
  hill-climbu (podrazumevano 8)
- **Primer (dokazan slučaj):**
  ```
  build\enigma_blind_depth.exe data tests\test_messages_day1\ciphertexts.txt 189 24 0 0 9 19 10 6
  ```
- **Očekivano:** raspored **201** (`Beta V VII IV / B`), joint skor ≈ −5.6/znak naspram
  ≈ −8.3 za sve pogrešne, vraćen ceo 10-parni plugboard. ~48 min za 24 rasporeda; pun
  1344 sweep traje više sati.

### 4) Dijagnostika / referenca
- `build\ioc_diag.exe` — IoC U-264 sa/bez plugboarda (dokaz granice 0.040)
- `build\verify_r1.exe`, `verify_r2.exe`, `verify_r3.exe` (preko `build.ps1`) —
  testovi komponenti (simulator, skoring, GPU kernel)
- `build\enigma_breaker.exe data` — stari integrisani kreker (NE razbija 10-parne
  poruke; referenca)

---

## DEO V — KOMPAJLIRANJE I INSTALACIJA

### Šta je potrebno
| Komponenta | Verzija korišćena | Napomena |
|---|---|---|
| GPU | NVIDIA, Compute Capability ≥ 6.0 (testirano RTX 4080 SUPER, CC 8.9) | CUDA-sposoban |
| CUDA Toolkit | **12.4** | daje `nvcc`; mora biti na `PATH` |
| Host C++ kompajler | **MSVC 14.44.35207** (Visual Studio 2022/18) | CUDA 12.4 traži MSVC ≤ 14.4x |
| OS | Windows 10/11 x64 | |
| Jezički podaci | `data\german_quadgrams.txt`, `german_trigrams.txt` | uključeno |

### Koraci instalacije
1. **Instaliraj Visual Studio** (2022 ili noviji) sa workload-om
   **„Desktop development with C++"**. To daje `cl.exe` i `vcvars64.bat`. Zapamti verziju
   MSVC foldera (npr. `…\VC\Tools\MSVC\14.44.35207\`).
2. **Instaliraj CUDA Toolkit 12.4.** Proveri sa `nvcc --version`. Osiguraj da je
   `…\CUDA\v12.4\bin` na `PATH`.
3. **Instaliraj novi NVIDIA drajver** koji podržava CUDA 12.4.
4. Kloniraj/postavi repozitorijum bilo gde — build skripte same nalaze koren projekta
   (u odnosu na svoju lokaciju), tu ne treba ništa da menjaš. Podešavaš samo VS/MSVC
   putanje ako se razlikuju od podrazumevanih (vidi ispod).

### Build
Dva puta za build, za različite delove paketa:

**`build.bat`** — attack alati (`crack_u264`, `enigma_crib_solver`,
`enigma_blind_depth`, `enigma_blind`, `enigma_breaker`, `ioc_diag`). Kompajlira
zajedničke CPU objekte sa `cl.exe`, pa linkuje svaki `.cu` sa
`nvcc -ccbin <cl.exe> -arch=sm_89 -O3 --use_fast_math`. Pokreni iz korena repoa:
```
build.bat                REM sve, u build\
build.bat crack          REM samo crack_u264.exe
build.bat crib sm_86     REM samo enigma_crib_solver.exe, RTX 30-serija
```
Validni targeti: `all` (podrazumevano) `objs` `crack` `crib` `depth` `blind` `breaker` `diag`.
Ako se tvoj Visual Studio/MSVC razlikuje od podrazumevanog u skripti, override-uj
environment varijablama pre pokretanja:
```
set VS_VCVARS=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat
set MSVC_CLPATH=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.40.33807\bin\Hostx64\x64\cl.exe
build.bat
```

**`build.ps1`** — CMake/Ninja jezgro (`verify_r1`, `verify_r2`, `verify_r3`).
```
.\build.ps1                # svi CMake targeti
.\build.ps1 verify_r1      # samo jedan target
.\build.ps1 -VsDir "C:\Program Files\Microsoft Visual Studio\2022\Community"
```
Napomena: `verify_r3` CUDA arhitektura je hardkodovana na `89` (RTX 40-serija) u
`CMakeLists.txt` — izmeni `CUDA_ARCHITECTURES` tamo ako imaš drugačiji GPU.

- Promeni arch parametar da odgovara tvom GPU (npr. `sm_86` za RTX 30-seriju, `sm_75`
  za RTX 20-seriju/GTX 16-seriju).

### Rešavanje problema
- **`LNK1104: cannot open file …exe`** — prethodni run još drži fajl:
  `Stop-Process -Name enigma_crib_solver,crack_u264,enigma_blind_depth -Force`.
- **`nvcc` nije nađen** — CUDA `bin` nije na `PATH`.
- **`cl` nije nađen / pogrešna verzija** — skripta zove `vcvars64.bat`; proveri putanju i
  MSVC verziju u skripti.
- **Pogrešni rezultati / pad na drugom GPU** — postavi tačan `-arch=sm_XX`.

---

## DEO VI — KLJUČNI NALAZI I OGRANIČENJA
- No-plugboard IoC tačnog ključa ≈ random (0.040) → single-message blind je neizvodljiv
  na jednom GPU; treba ti crib ili depth.
- Minimalna korisna dužina criba ≈ **20 slova** povezanog poznatog teksta. Kratke česte
  reči same flood-uju pretragu.
- Simulator okida turnover na **apsolutnoj** poziciji prozora (istorijski tačno), pa ring
  i pozicija **nisu** degenerisani — ring se mora tražiti (`R6` za teške slučajeve).
- Nemačka n-gram tabela je pravi nemački (bez `X` separatora); solver skoruje po
  **X-segmentima** da ga konvencija korpusa ne zavara.

Za pun tehnički detalj i razvojni dnevnik vidi `informacije_enigma.txt`.
