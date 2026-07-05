#!/usr/bin/env python3
# Enigma M4 simulator + test message generator
# Verified against the authentic historical U-264 message, then generates 400+ synthetic ones.

import random, json, os

A = ord('A')

ROTORS = {
    'I':   ("EKMFLGDQVZNTOWYHXUSPAIBRCJ", "Q"),
    'II':  ("AJDKSIRUXBLHWTMCQGZNPYFVOE", "E"),
    'III': ("BDFHJLCPRTXVZNYEIWGAKMUSQO", "V"),
    'IV':  ("ESOVPZJAYQUIRHXLNFTGKDCMWB", "J"),
    'V':   ("VZBRGITYUPSDNHLXAWMJQOFECK", "Z"),
    'VI':  ("JPGVOUMFYQBENHZRDKASXLICTW", "ZM"),
    'VII': ("NZJHGRCXMYSWBOUFAIVLPEKQDT", "ZM"),
    'VIII':("FKQHTLXOCBJSPDZRAMEWNIUYGV", "ZM"),
}
THIN = {
    'Beta':  "LEYJVCNIXWPBQMDRTAKZGFUHOS",
    'Gamma': "FSOKANUERHMBTIYCWLQPZXVGJD",
}
REFLECTORS = {
    'B': "ENKQAUYWJICOPBLMDXZVFTHRGS",   # B-thin
    'C': "RDOBJNTKVEHMLFCWZAXGYIPSUQ",   # C-thin
}

def inv(wiring):
    out = [0]*26
    for i,c in enumerate(wiring):
        out[ord(c)-A] = i
    return out

class M4:
    # wheel order: [thin, left, middle, right]; rings/pos same order; 0-based
    def __init__(self, thin, left, mid, right, refl, rings, pos, plug):
        self.fw = [list(ord(c)-A for c in THIN[thin]),
                   list(ord(c)-A for c in ROTORS[left][0]),
                   list(ord(c)-A for c in ROTORS[mid][0]),
                   list(ord(c)-A for c in ROTORS[right][0])]
        self.bw = [inv(THIN[thin]), inv(ROTORS[left][0]),
                   inv(ROTORS[mid][0]), inv(ROTORS[right][0])]
        self.notch = [set(), set(ord(c)-A for c in ROTORS[left][1]),
                      set(ord(c)-A for c in ROTORS[mid][1]),
                      set(ord(c)-A for c in ROTORS[right][1])]
        self.refl = [ord(c)-A for c in REFLECTORS[refl]]
        self.rings = list(rings)
        self.pos = list(pos)
        # plugboard map
        self.plug = list(range(26))
        for a,b in plug:
            ia,ib = ord(a)-A, ord(b)-A
            self.plug[ia], self.plug[ib] = ib, ia

    def _step(self):
        # M4 double-stepping (thin rotor index 0 never steps)
        right_notch = self.pos[3] in self.notch[3]
        mid_notch   = self.pos[2] in self.notch[2]
        if mid_notch:
            self.pos[1] = (self.pos[1]+1) % 26
            self.pos[2] = (self.pos[2]+1) % 26
        elif right_notch:
            self.pos[2] = (self.pos[2]+1) % 26
        self.pos[3] = (self.pos[3]+1) % 26

    def _pass(self, c, wiring, i):
        off = (self.pos[i] - self.rings[i]) % 26
        c = (c + off) % 26
        c = wiring[c]
        c = (c - off) % 26
        return c

    def encrypt_char(self, c):
        self._step()
        c = self.plug[c]
        for i in (3,2,1,0):                 # right -> ... -> thin
            c = self._pass(c, self.fw[i], i)
        c = self.refl[c]
        for i in (0,1,2,3):                 # thin -> ... -> right
            c = self._pass(c, self.bw[i], i)
        c = self.plug[c]
        return c

    def process(self, text):
        out = []
        for ch in text:
            if 'A' <= ch <= 'Z':
                out.append(chr(self.encrypt_char(ord(ch)-A)+A))
        return "".join(out)

# ---------- VERIFICATION against the authentic U-264 message ----------
# Settings: Reflector Thin B, wheels Beta II IV I, rings 01 01 01 22, msg key VJNA
# Plugs: AT BL DF GJ HM NW OP QY RZ VX
u264_ct = ("NCZWVUSXPNYMINHZXMQXSFWXWLKJAHSHNMCOCCAKUQPMKCSMHKSEINJUSBLKIOSXCKUBHMLLXCSJ"
           "USRRDVKOHULXWCCBGVLIYXEOAHXRHKKFVDREWEZLXOBAFGYUJQUKGRTVUKAMEURBVEKSUHHVOYHA"
           "BCJWMAKLFKLMYFVNRIZRVVRTKOFDANJMOLBGFFLEOPRGTFLVRHOWOPBEKVWMUQFMPWPARMFHAGKXIIBG")
plugs = [("A","T"),("B","L"),("D","F"),("G","J"),("H","M"),
         ("N","W"),("O","P"),("Q","Y"),("R","Z"),("V","X")]
# rings/pos order = [thin,left,mid,right]; ring 01 01 01 22 -> 0,0,0,21
# msg key VJNA -> positions V J N A -> 21,9,13,0
m = M4("Beta","II","IV","I","B",[0,0,0,21],[21,9,13,0],plugs)
dec = m.process(u264_ct)
print("U-264 dekript (prvih 60):", dec[:60])
expected_start = "VONVONJLOOKSJHFFTTTEINSEINSDREIZWOYYQNNS"  # known start
ok = dec.startswith("VONVONJLOOKS")
print("VERIFIKACIJA U-264:", "PROSLA" if ok else "PALA")
print()
assert ok, "Simulator nije tacan - prekidam."

# ---------- GENERATOR for synthetic messages ----------
# German plaintext fragments (military style, X=space convention)
phrases = [
 "VONXOBERKOMMANDOXDERXMARINE","ANXALLEXUBOOTEXIMXNORDATLANTIK","FEINDXKONVOIXGESICHTETXQUADRAT",
 "WETTERXBERICHTXFUERXDIEXNAECHSTENXSTUNDEN","ANGRIFFXBEFOHLENXBEIXTAGESANBRUCH","POSITIONXMELDENXSOFORT",
 "TREIBSTOFFXKNAPPXRUECKKEHRXZUMXSTUETZPUNKT","FUNKSTILLEXEINHALTENXBISXWEITERERXBEFEHL","GELEITZUGXVERSENKTXVIERXSCHIFFE",
 "TORPEDOSXVERSCHOSSENXALLEXTREFFER","UBOOTXBESCHAEDIGTXTAUCHENXNICHTXMOEGLICH","NEUEXKOORDINATENXFOLGENXIMXNAECHSTENXFUNKSPRUCH",
 "LUFTAUFKLAERUNGXMELDETXFEINDXFLOTTE","NACHSCHUBXERFORDERLICHXDRINGEND","SCHWERESXWETTERXBEHINDERTXANGRIFF",
 "GEHEIMEXOPERATIONXBEGINNTXUMXMITTERNACHT","ALLEXBOOTEXSAMMELNXBEIXTREFFPUNKTXANTON","MELDUNGXUEBERXFEINDXBEWEGUNGEN",
 "VERSORGUNGSSCHIFFXERWARTETXMORGENXFRUEH","KURSXAENDERNXAUFXNORDXNORDOST","TIEFEXWASSERBOMBENXANGRIFFXUEBERSTANDEN",
 "MASCHINENXSCHADENXBEHOBENXFAHRTXAUFGENOMMEN","GEFANGENEXANXBORDXGENOMMEN","SICHTXVERHAELTNISSEXSCHLECHTXNEBEL",
 "BEFEHLXBESTAETIGTXFUEHREXAUSXSOFORT","RESERVENXAUFGEBRAUCHTXBITTEXUMXANWEISUNG",
]

def rand_text(n):
    s = ""
    while len(s) < n:
        s += random.choice(phrases) + "X"
    return s[:n]

def rand_key():
    names = list(ROTORS.keys())
    random.shuffle(names)
    left, mid, right = names[0], names[1], names[2]
    thin = random.choice(list(THIN.keys()))
    refl = random.choice(list(REFLECTORS.keys()))
    rings = [0, random.randint(0,25), random.randint(0,25), random.randint(0,25)]
    pos   = [random.randint(0,25) for _ in range(4)]
    # random plugboard: 10 pairs
    letters = list(range(26)); random.shuffle(letters)
    plug = [(chr(letters[2*i]+A), chr(letters[2*i+1]+A)) for i in range(10)]
    return thin,left,mid,right,refl,rings,pos,plug

random.seed(1942)
N = 420
messages = []
for idx in range(N):
    thin,left,mid,right,refl,rings,pos,plug = rand_key()
    length = random.choice([120,150,180,200,250])
    pt = rand_text(length)
    enc = M4(thin,left,mid,right,refl,rings,list(pos),plug)
    ct = enc.process(pt)
    messages.append({
        "id": idx+1,
        "ciphertext": ct,
        "key": {
            "reflector": refl,
            "wheel_order": [thin,left,mid,right],
            "rings": rings,
            "positions": pos,
            "plugboard": ["".join(p) for p in plug],
        },
        "plaintext": pt,
        "length": len(ct),
    })

# round-trip self-check on the first 5
for msgd in messages[:5]:
    k = msgd["key"]
    thin,left,mid,right = k["wheel_order"]
    plug = [(p[0],p[1]) for p in k["plugboard"]]
    dec_m = M4(thin,left,mid,right,k["reflector"],list(k["rings"]),list(k["positions"]),plug)
    back = dec_m.process(msgd["ciphertext"])
    assert back == msgd["plaintext"], f"round-trip FAIL on id {msgd['id']}"
print(f"Round-trip provjera na uzorku: PROSLA")
print(f"Generisano {len(messages)} sintetickih M4 poruka.")

with open(os.path.join(os.path.dirname(os.path.abspath(__file__)),"m4_messages.json"),"w") as f:
    json.dump(messages, f, indent=2)
print("Sacuvano u m4_messages.json")
