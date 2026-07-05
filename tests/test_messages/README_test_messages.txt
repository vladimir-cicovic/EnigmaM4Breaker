========================================================================
TEST PORUKE ZA ENIGMA M4 BREAKER
========================================================================

SADRZAJ OVOG SKUPA:
  - m4_messages.json          420 sintetickih poruka, pun format
                              (ciphertext + KOMPLETAN kljuc + plaintext)
  - m4_ciphertexts_only.txt   samo sifrati (za batch ucitavanje u breaker)
  - m4_solutions.txt          kljucevi/rjesenja za provjeru breakera
  - authentic_U264.txt        autenticna istorijska M4 poruka (zlatni standard)


------------------------------------------------------------------------
ZASTO SINTETICKE PORUKE?
------------------------------------------------------------------------
Javni skup od preko 400 AUTENTICNIH M4 sifrata sa potvrdjenim kljucevima
NE postoji. Istorijski razbijenih originalnih M4 poruka ima svega
nekoliko desetina (M4 Project je radio na 3 poruke; razni projekti
ukupno ~70 M3+M4). To je sav postojeci autenticni materijal.

Zato je ovaj skup napravljen sopstvenim M4 simulatorom koji je
VERIFIKOVAN na autenticnoj istorijskoj poruci U-264 (vidi dolje) —
dekriptovao ju je tacno, sto dokazuje da su ozicenja, double-stepping i
prolaz signala ispravni. Sve 420 poruka su prema tome validni M4
sifrati.

Za testiranje breakera su sinteticke poruke ZAPRAVO BOLJE: za svaku
imas ground-truth kljuc i plaintext, pa mozes precizno mjeriti uspjeh
(da li je breaker nasao tacan kljuc), sto sa istorijskim porukama
najcesce ne mozes.


------------------------------------------------------------------------
AUTENTICNA PORUKA ZA VERIFIKACIJU (U-264, 25.11.1942)
------------------------------------------------------------------------
Ovo je prava poruka poslata sa U-boota, razbijena u sklopu M4 Projecta.
Koristi je kao PRVI test da provjeris da tvoj C++/CUDA simulator radi
tacno (mora dekriptovati u tekst koji pocinje sa "VONVONJLOOKS...").

  Reflector:     Thin B
  Wheel order:   Beta II IV I      (thin, lijevi, sredina, desni)
  Ring settings: 01 01 01 22       (0-based: 0 0 0 21)
  Message key:   VJNA              (pozicije: 21 9 13 0)
  Plugs:         AT BL DF GJ HM NW OP QY RZ VX

  Ciphertext:
  NCZWVUSXPNYMINHZXMQXSFWXWLKJAHSHNMCOCCAKUQPMKCSMHKSEINJUSBLK
  IOSXCKUBHMLLXCSJUSRRDVKOHULXWCCBGVLIYXEOAHXRHKKFVDREWEZLXOBA
  FGYUJQUKGRTVUKAMEURBVEKSUHHVOYHABCJWMAKLFKLMYFVNRIZRVVRTKOFD
  ANJMOLBGFFLEOPRGTFLVRHOWOPBEKVWMUQFMPWPARMFHAGKXIIBG

  Ocekivani pocetak plaintexta:
  VONVONJLOOKSJHFFTTTEINSEINSDREIZWOYYQNNSNEUNINHALTXXBEIANGRI...
  (von von "Looks" ... = od kapetana Looksa)


------------------------------------------------------------------------
FORMAT m4_messages.json
------------------------------------------------------------------------
[
  {
    "id": 1,
    "ciphertext": "....",
    "key": {
      "reflector": "B" ili "C",
      "wheel_order": ["Beta/Gamma","lijevi","sredina","desni"],
      "rings":     [thin, left, mid, right],     // 0-based, thin uvijek 0
      "positions": [thin, left, mid, right],     // 0-based pocetne pozicije
      "plugboard": ["AT","BL", ...]              // 10 parova
    },
    "plaintext": "....",
    "length": 180
  },
  ...
]

NAPOMENE:
  - Pozicije i ringovi su 0-based (A=0 ... Z=25).
  - Thin rotor (Beta/Gamma) ring je uvijek 0 i ne rotira se.
  - Plugboard ima 10 parova (istorijski tipicno za Kriegsmarine).
  - Duzine poruka: 120-250 znakova (sve >= 60, pouzdano za quadgram napad).


------------------------------------------------------------------------
KAKO KORISTITI ZA TESTIRANJE BREAKERA
------------------------------------------------------------------------
1. Prvo provjeri simulator na U-264 (gore) — mora dati tacan plaintext.
2. Uzmi ciphertext iz m4_messages.json, pusti breaker.
3. Uporedi nadjeni kljuc sa "key" poljem (ili m4_solutions.txt).
4. Mjeri: koliko poruka je tacno razbijeno, prosjecno vrijeme po poruci,
   da li su rotori/pozicije/plugboard tacni.

SAVJET: pocni sa duzim porukama (200-250 znakova) — lakse se razbijaju.
Kratke poruke (~120) su tezi test i provjera robusnosti scoringa.
