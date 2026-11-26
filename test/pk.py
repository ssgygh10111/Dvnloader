import sys
d=open(sys.argv[1],'rb').read()
for k in list(range(478,490))+list(range(504,512)):
    p=d[k*188:(k+1)*188]
    pid=((p[1]&0x1f)<<8)|p[2]; afc=(p[3]>>4)&3
    print(f"pk{k} pid={pid} pusi={int(bool(p[1]&0x40))} afc={afc} cc={p[3]&15} afl={p[4] if afc&2 else '-'} head={p[4:16].hex()}")
