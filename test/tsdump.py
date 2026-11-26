import sys
d=open(sys.argv[1],'rb').read()
pmt=None; vpid=None; pes=-1; out=[]
for i in range(0,len(d)-187,188):
    p=d[i:i+188]
    if p[0]!=0x47: print("SYNC LOST at",i); break
    pid=((p[1]&0x1f)<<8)|p[2]; pusi=bool(p[1]&0x40); afc=(p[3]>>4)&3; cc=p[3]&15
    off=4; afl=None
    if afc&2: afl=p[4]; off+=1+p[4]
    if pid==0 and pusi:
        t=p[5+p[4]:] if False else p[off+1+p[off]:]
        pmt=((t[10]&0x1f)<<8)|t[11]
    elif pid==pmt and pusi and vpid is None:
        t=p[off+1+p[off]:]; pil=((t[10]&15)<<8)|t[11]; j=12+pil
        while j+5<=len(t):
            st=t[j]; ep=((t[j+1]&0x1f)<<8)|t[j+2]; es=((t[j+3]&15)<<8)|t[j+4]
            if st==0x1b: vpid=ep
            j+=5+es
    elif pid==vpid:
        if pusi: pes+=1
        if 1<=pes<=3: out.append(f"pes{pes} pk@{i//188} pusi={int(pusi)} afc={afc} afl={afl} pay={188-off if afc&1 else 0} cc={cc}" + (f" hdr={p[off:off+20].hex()}" if pusi else "") + (f" tail={p[-6:].hex()}" if not pusi else ""))
print("vpid",vpid)
for o in out:
    if 'pusi=1' in o or 'afl=' in o and 'afl=None' not in o: print(o)
print("pes2 packets:", sum(1 for o in out if o.startswith('pes2')))
print("\n".join(o for o in out if o.startswith('pes2'))[-1500:])
