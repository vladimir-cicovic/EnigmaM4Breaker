# Enigma M4 Breaker

GPU-ubrzani kriptoanalitički paket (C++ / CUDA, Windows) koji razbija nemačku
mornaričku šifru **Enigma M4** — četvororotorsku mašinu „Shark"/„Triton" koju je
Kriegsmarine koristio na U-boot floti od 1942. Na jednom modernom GPU-u reprodukuje
istorijske napade koje je Bletchley Park koristio protiv saobraćaja podmornica:
crib-dragging (Turingova bomba), depth napad i pun plugboard hill-climbing.

> 🇬🇧 For the English version of this README, see [README.md](README.md).

Ožičenje, koračanje na zarezu i anomalija dvostrukog koraka provereni su dekripcijom
autentične istorijske poruke **U-264** (25. novembar 1942.), koju ovaj kod dešifruje u
`VONVONJLOOKS…` — isti rezultat kao *M4 Project* (Stefan Krah, 2006).

## Zašto ovo postoji

Prostor ključeva Enigme M4 je reda **10²³**. Najveći deo tog prostora (raspored rotora ×
pozicije × prstenovi, ≈ 3×10¹⁰) je dovoljno jeftin da se brute-force-uje na GPU-u.
Plugboard (10 parova ≈ 1,5×10¹⁴ kombinacija) nije — mora se *vratiti statistički*
hill-climbingom, baš kao što je istorijska bomba to radila elektromehaničkom logikom
umesto CUDA jezgara. Ovaj projekat deli problem na isti način: GPU prečešljava jeftini
deo, CPU hill-climbuje plugboard na preživelim kandidatima.

## Šta razbija

| Komponenta | Broj | Napomena |
|---|---|---|
| Raspored rotora | 1344 | 3 od 8 rotora (uređeno) × 2 grčka rotora (Beta/Gamma) × 2 reflektora (B/C-thin) |
| Početne pozicije (Grundstellung) | 456 976 | 26⁴ |
| Postavke prstena (efektivno) | 17 576 | 26³ (prsten tankog rotora je irelevantan) |
| Plugboard, 10 parova | ≈ 1,5 × 10¹⁴ | `26! / ((26-2p)! · 2^p · p!)`, p=10 |

## Attack alati

| Alat | Scenario | Treba | Vraća |
|---|---|---|---|
| `crack_u264` | Dnevni ključ već poznat (npr. zaplenjen šifrarnik) | Raspored rotora + prstenovi | Poziciju poruke + pun plugboard |
| `enigma_crib_solver` | Poznat/pretpostavljen fragment teksta (crib) | Crib ≥ ~20 slova | Pun ključ (GPU Turingova bomba) |
| `enigma_blind_depth` | Dnevni saobraćaj sa istim ključem | Više poruka, prstenovi | Raspored rotora + plugboard |
| `enigma_blind` | Jedna poruka, ništa poznato | — | Ne radi pouzdano (vidi [UPUTSTVO_SR.md](UPUTSTVO_SR.md)) |
| `enigma_breaker` | Ciphertext-only preko jeftine heuristike | — | Stari/legacy — samo referenca |

Zašto slepi napad na jednu poruku ne radi, a ostali rade: dekripcija ispravnim ključem
bez plugboarda ima Index of Coincidence ≈ 0,040 — neraspoznatljivo od slučajnog teksta.
Nijedna jeftina statistika ne može naći ispravan ključ samo iz šifrata; signal se
pojavljuje tek kad se plugboard (delimično) vrati. Puni tehnički detalji, matematika i
izvori: [DOKUMENTACIJA_BHS.md](DOKUMENTACIJA_BHS.md) (najpotpunije; engleska verzija:
[DOCUMENTATION.md](DOCUMENTATION.md)) i [UPUTSTVO_SR.md](UPUTSTVO_SR.md).

## Dijagrami

**Tok signala** — jedan pritisak tastera, jedan pun prolaz kroz mašinu: plugboard →
desni → srednji → lijevi → thin rotor → reflektor → nazad kroz iste rotore → plugboard.
Reflektor je involucija bez fiksnih tačaka, pa je putanja recipročna (ista mašina
šifruje i dešifruje) i nijedno slovo se nikad ne šifruje u samo sebe — ta pukotina u
oklopu Enigme je ono što bomba/crib napad koristi.

![Tok signala kroz Enigmu M4](dijagram_signal.svg)

**Pipeline napada** — centralna inženjerska ideja ovog projekta: GPU prečešljava
milione jeftinih rotorsko-pozicionih kandidata paralelno (IoC ili trigram skor), a samo
top 20–100 preživelih ide na CPU na skupo, precizno quadgram hill-climbing i pun
plugboard.

![Pipeline: GPU grubi filter → CPU precizna dorada](dijagram_pipeline.svg)

**Turingova bomba / crib napad** — kako `enigma_crib_solver` vraća ključ iz poznatog
fragmenta teksta: prevuci crib preko šifrata (preskačući pozicije gde bi se slovo
mapiralo u samo sebe), pa za svaki preživeli offset i rotorsku postavku propagiraj
plugboard implikacije dok kontradikcija ne odbaci postavku ili ceo crib ne prođe —
ostavljajući konzistentan kandidat za plugboard.

![Turing bombe — crib drag + propagacija plugboard ograničenja](dijagram_bombe.svg)

## Struktura repozitorijuma

```
config.h                 Ožičenja rotora/reflektora, zarezi, EnigmaKey struktura
core/enigma_cpu/          Verifikovani CPU M4 simulator (temelj tačnosti)
core/enigma_gpu/          Razvojne faze GPU kernela (IoC -> multi-filter -> ring search)
filters/                  CPU skoreri: Index of Coincidence, trigram, quadgram
search/plugboard_search/  CPU plugboard hill-climb (steepest-ascent + restartovi)
crack_u264.cu             Attack alat: poznat dnevni ključ -> poruka ključ + plugboard
enigma_crib_solver.cu     Attack alat: crib-dragging GPU Turingova bomba
enigma_blind_depth.cu     Attack alat: depth (deljeni dnevni ključ preko poruka)
enigma_blind.cu           Attack alat: ciphertext-only za jednu poruku (nepouzdano)
enigma_breaker.cu         Legacy ciphertext-only kreker (samo referenca)
ioc_diag.cpp              Dijagnostika: IoC za U-264 sa/bez plugboarda
data/                     Nemačke quadgram/trigram frekvencijske tabele + U-264 šifrat
tests/test_messages/      420 sintetičkih test poruka + autentična U-264 poruka
tests/test_messages_day1/2/3/  Depth korpusi: jednodnevni saobraćaj sa istim ključem
dijagram_*.svg            Dijagrami toka signala / pipeline-a / bombe (srpski nazivi)
diagram_*.svg             Isti dijagrami, engleske oznake (koristi ih README.md)
build.bat                 Kompajlira attack alate (cl.exe + nvcc)
build.ps1                 Kompajlira CMake/Ninja jezgro (verify_r1..r3)
CMakeLists.txt            CMake projekat za simulator/skoring/GPU-kernel testove
```

## Šta je potrebno

| Komponenta | Verzija korišćena | Napomena |
|---|---|---|
| GPU | NVIDIA, Compute Capability ≥ 6.0 (testirano: RTX 4080 SUPER, CC 8.9) | CUDA-sposoban |
| CUDA Toolkit | 12.4 | daje `nvcc`; mora biti na `PATH` |
| Host C++ kompajler | MSVC 14.4x (Visual Studio 2022 ili noviji) | CUDA 12.4 traži MSVC ≤ 14.4x |
| OS | Windows 10/11 x64 | |

## Kompajliranje

```
git clone <ovaj-repo>
cd EnigmaM4Breaker

REM attack alati (crack_u264, enigma_crib_solver, enigma_blind_depth, ...)
build.bat

REM jezgro (verify_r1, verify_r2, verify_r3) preko CMake/Ninja
powershell -File build.ps1
```

Obe skripte same nalaze koren repozitorijuma prema sopstvenoj lokaciji — nije potrebno
menjati apsolutne putanje da bi se samo build pokrenuo. Ako se tvoj Visual Studio/MSVC
razlikuje od podrazumevanog, override-uj environment varijablama (`build.bat`) ili
`-VsDir` (`build.ps1`) — vidi vrh svake skripte, ili
[UPUTSTVO_SR.md § Kompajliranje i instalacija](UPUTSTVO_SR.md#deo-v--kompajliranje-i-instalacija)
za pun vodič i rešavanje problema.

## Primeri korišćenja

Svaki alat pokreni iz korena repozitorijuma (folder u kom je `build.bat`); svaki na
kraju štampa proteklo vreme (wall-clock).

**1) `crack_u264`** — razbij poruku dat poznat dnevni rotorski ključ:
```
build\crack_u264.exe data
REM Očekivano: message key VJNA, plugboard AT BL DF GJ HM NW OP QY RZ VX,
REM            plaintext VONVONJLOOKS..., ~4 min na GPU klase RTX 4080.
```

**2) `enigma_crib_solver`** — slepi crib + Turingova bomba napad:
```
REM Pun slepi solve, sve 1344 rasporeda:
build\enigma_crib_solver.exe data poruka.txt 0 1344

REM Brza provera na jednom poznatom rasporedu (indeks 79):
build\enigma_crib_solver.exe data poruka.txt 79 1

REM Prava poruka, nepoznat sadržaj - prevuci rečnik nemačkih criba preko nje:
build\enigma_crib_solver.exe data poruka.txt 0 1344 DICT
```
Očekivano: `=== SOLVED ===` sa reflektorom, rasporedom, prstenovima, pozicijama,
plugboardom i plaintekstom. ~3–20 min u zavisnosti gde tačan crib padne.

**3) `enigma_blind_depth`** — ciphertext-only DEPTH napad (bez criba, više poruka sa
istim dnevnim ključem):
```
build\enigma_blind_depth.exe data tests\test_messages_day1\ciphertexts.txt 189 24 0 0 9 19 10 6
```
Očekivano: raspored **201** (`Beta V VII IV / B`), joint skor ≈ −5,6/znak naspram
≈ −8,3 za sve pogrešne, vraćen ceo 10-parni plugboard. ~48 min za ovih 24 rasporeda.

**4) Dijagnostika** — `ioc_diag` pokazuje IoC za U-264 sa/bez plugboarda, dokazujući
granicu 0,040 pomenutu gore:
```
build\ioc_diag.exe
```

Pun opis argumenata (svaki flag, mod, podrazumevana vrednost) za sve alate:
[UPUTSTVO_SR.md](UPUTSTVO_SR.md) (srpski) ili [MANUAL_EN.md](MANUAL_EN.md) (engleski).

## Ključni nalazi i ograničenja

- IoC ispravnog ključa bez plugboarda ≈ slučajan (0,040) → ciphertext-only napad na
  jednu poruku nije izvodljiv na jednom GPU-u; potreban je crib ili depth (više poruka,
  deljeni ključ).
- Minimalna korisna dužina criba ≈ 20 povezanih slova poznatog teksta.
- Rotor koračanje se okida na **apsolutnoj** poziciji prozora (istorijski tačno), pa
  prsten i početna pozicija **nisu** degenerisani za kratke poruke — prsten se mora
  pretraživati u teškim slučajevima (`R6` flag na crib solveru).

## Dokumentacija

- [DOKUMENTACIJA_BHS.md](DOKUMENTACIJA_BHS.md) / [DOCUMENTATION.md](DOCUMENTATION.md) —
  puni tehnički deep-dive (srpski / engleski): istorija, matematika, svaki pojam
  objašnjen (IoC, quadgram scoring, bomba, hill-climbing, depth), sa izvorima.
- [UPUTSTVO_SR.md](UPUTSTVO_SR.md) / [MANUAL_EN.md](MANUAL_EN.md) — korisnička uputstva
  (srpski / engleski): istorija, korišćenje, build i instalacija, rešavanje problema.
- [informacije_enigma.txt](informacije_enigma.txt) — razvojni log / beleške o projektu.

## Licenca

Trenutno nema LICENSE fajla — podrazumevano su sva prava zadržana dok se ne doda
licenca. Ako planiraš da ovo javno objaviš, dodaj `LICENSE` (npr. MIT ili Apache-2.0)
pre nego što računaš na to da drugi mogu legalno da koriste kod.
