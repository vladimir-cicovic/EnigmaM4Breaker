#!/usr/bin/env python3
# DEPTH test message generator: several messages with the SAME daily key (wheel order +
# rings + plugboard), DIFFERENT positions per message (like historical daily traffic).
# Goal: depth blind attack (shared plugboard as discriminator).
import os, sys, json, random
sys.stdout.reconfigure(encoding="utf-8")
A = ord('A')

ROTORS = {
 'I':("EKMFLGDQVZNTOWYHXUSPAIBRCJ","Q"),'II':("AJDKSIRUXBLHWTMCQGZNPYFVOE","E"),
 'III':("BDFHJLCPRTXVZNYEIWGAKMUSQO","V"),'IV':("ESOVPZJAYQUIRHXLNFTGKDCMWB","J"),
 'V':("VZBRGITYUPSDNHLXAWMJQOFECK","Z"),'VI':("JPGVOUMFYQBENHZRDKASXLICTW","ZM"),
 'VII':("NZJHGRCXMYSWBOUFAIVLPEKQDT","ZM"),'VIII':("FKQHTLXOCBJSPDZRAMEWNIUYGV","ZM"),
}
THIN={'Beta':"LEYJVCNIXWPBQMDRTAKZGFUHOS",'Gamma':"FSOKANUERHMBTIYCWLQPZXVGJD"}
REFLECTORS={'B':"ENKQAUYWJICOPBLMDXZVFTHRGS",'C':"RDOBJNTKVEHMLFCWZAXGYIPSUQ"}
def inv(w):
    o=[0]*26
    for i,c in enumerate(w): o[ord(c)-A]=i
    return o

class M4:
    def __init__(s,thin,left,mid,right,refl,rings,pos,plug):
        s.fw=[[ord(c)-A for c in THIN[thin]],[ord(c)-A for c in ROTORS[left][0]],
              [ord(c)-A for c in ROTORS[mid][0]],[ord(c)-A for c in ROTORS[right][0]]]
        s.bw=[inv(THIN[thin]),inv(ROTORS[left][0]),inv(ROTORS[mid][0]),inv(ROTORS[right][0])]
        s.notch=[set(),set(ord(c)-A for c in ROTORS[left][1]),
                 set(ord(c)-A for c in ROTORS[mid][1]),set(ord(c)-A for c in ROTORS[right][1])]
        s.refl=[ord(c)-A for c in REFLECTORS[refl]]; s.rings=list(rings); s.pos=list(pos)
        s.plug=list(range(26))
        for a,b in plug:
            ia,ib=ord(a)-A,ord(b)-A; s.plug[ia],s.plug[ib]=ib,ia
    def _step(s):
        rn=s.pos[3] in s.notch[3]; mn=s.pos[2] in s.notch[2]
        if mn: s.pos[1]=(s.pos[1]+1)%26; s.pos[2]=(s.pos[2]+1)%26
        elif rn: s.pos[2]=(s.pos[2]+1)%26
        s.pos[3]=(s.pos[3]+1)%26
    def _pass(s,c,w,i):
        off=(s.pos[i]-s.rings[i])%26; c=(c+off)%26; c=w[c]; return (c-off)%26
    def enc(s,c):
        s._step(); c=s.plug[c]
        for i in (3,2,1,0): c=s._pass(c,s.fw[i],i)
        c=s.refl[c]
        for i in (0,1,2,3): c=s._pass(c,s.bw[i],i)
        return s.plug[c]
    def process(s,t):
        return "".join(chr(s.enc(ord(ch)-A)+A) for ch in t if 'A'<=ch<='Z')

phrases=[
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
    s=""
    while len(s)<n: s+=random.choice(phrases)+"X"
    return s[:n]

# wheel-index in buildConfigs order: for rf(0,1) for th(0,1) for l(0..7) for m!=l for r!=l,m
RIDX={n:i for i,n in enumerate(['I','II','III','IV','V','VI','VII','VIII'])}
TIDX={'Beta':0,'Gamma':1}; FIDX={'B':0,'C':1}
def wheel_index(thin,left,mid,right,refl):
    th=TIDX[thin]; l=RIDX[left]; m=RIDX[mid]; r=RIDX[right]; rf=FIDX[refl]
    idx=0
    for RF in range(2):
        for TH in range(2):
            for L in range(8):
                for M in range(8):
                    if M==L: continue
                    for R in range(8):
                        if R==L or R==M: continue
                        if (RF,TH,L,M,R)==(rf,th,l,m,r): return idx
                        idx+=1
    return -1

LENGTHS=[150,165,180,200,220,250,280,300,330,360]
OUTROOT=os.path.dirname(os.path.abspath(__file__))

def gen_day(day, seed):
    random.seed(seed)
    names=list(ROTORS.keys()); random.shuffle(names)
    left,mid,right=names[0],names[1],names[2]
    thin=random.choice(list(THIN.keys())); refl=random.choice(list(REFLECTORS.keys()))
    rings=[0,0,random.randint(0,25),random.randint(0,25)]   # thin/left=0 (degenerate), mid/right are part of the key
    letters=list(range(26)); random.shuffle(letters)
    plug=[(chr(letters[2*i]+A),chr(letters[2*i+1]+A)) for i in range(10)]
    nmsg=random.randint(60,120)
    widx=wheel_index(thin,left,mid,right,refl)

    d=os.path.join(OUTROOT,f"test_messages_day{day}")
    os.makedirs(d,exist_ok=True)
    msgs=[]
    for i in range(nmsg):
        pos=[random.randint(0,25) for _ in range(4)]
        L=random.choice(LENGTHS)
        pt=rand_text(L)
        ct=M4(thin,left,mid,right,refl,list(rings),list(pos),plug).process(pt)
        msgs.append({"id":i+1,"pos":pos,"len":len(ct),"ct":ct,"pt":pt})

    # ciphertexts: one message per line
    with open(os.path.join(d,"ciphertexts.txt"),"w") as f:
        for m in msgs: f.write(m["ct"]+"\n")
    # solution (daily key + per-message positions)
    with open(os.path.join(d,"solution.txt"),"w") as f:
        f.write(f"DAILY KEY day{day}\n")
        f.write(f"  reflector : {refl}\n")
        f.write(f"  wheels    : {thin} {left} {mid} {right}   (wheel_index={widx})\n")
        f.write(f"  rings     : {rings}\n")
        f.write(f"  plugboard : {' '.join(a+b for a,b in plug)}\n")
        f.write(f"  #messages : {nmsg}\n\n")
        for m in msgs:
            f.write(f"  id {m['id']:3d} | len {m['len']:3d} | pos {m['pos']} | {m['pt'][:40]}...\n")
    with open(os.path.join(d,"messages.json"),"w") as f:
        json.dump({"day":day,"reflector":refl,"wheels":[thin,left,mid,right],
                   "wheel_index":widx,"rings":rings,
                   "plugboard":[a+b for a,b in plug],"messages":msgs},f,indent=1)
    print(f"day{day}: {nmsg} messages | {thin} {left} {mid} {right}/{refl} widx={widx} "
          f"rings={rings} plug={' '.join(a+b for a,b in plug)}")
    print(f"        -> {d}")
    return widx

# round-trip self-check (the U-264 mechanism is already verified in gen_messages.py)
for day,seed in [(1,19420501),(2,19420815),(3,19421101)]:
    gen_day(day,seed)
print("\nDONE. Each day: ciphertexts.txt (1 message/line) + solution.txt + messages.json")
