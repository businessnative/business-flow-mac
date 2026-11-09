import re, math, sys, glob, os, xml.etree.ElementTree as ET
def tokens(d):
    for m in re.finditer(r'[MmLlHhVvCcSsQqTtAaZz]|-?(?:\d+\.?\d*|\.\d+)(?:e-?\d+)?', d):
        yield m.group(0)
def arc_to_cubic(x1,y1,rx,ry,phi,fa,fs,x2,y2):
    if rx==0 or ry==0: return [('L',x2,y2)]
    phi=math.radians(phi); c,s=math.cos(phi),math.sin(phi)
    dx,dy=(x1-x2)/2,(y1-y2)/2
    x1p=c*dx+s*dy; y1p=-s*dx+c*dy
    rx,ry=abs(rx),abs(ry)
    lam=x1p**2/rx**2+y1p**2/ry**2
    if lam>1: rx*=math.sqrt(lam); ry*=math.sqrt(lam)
    num=rx*rx*ry*ry-rx*rx*y1p*y1p-ry*ry*x1p*x1p
    den=rx*rx*y1p*y1p+ry*ry*x1p*x1p
    co=math.sqrt(max(0,num/den)) if den else 0
    if fa==fs: co=-co
    cxp=co*rx*y1p/ry; cyp=-co*ry*x1p/rx
    cx=c*cxp-s*cyp+(x1+x2)/2; cy=s*cxp+c*cyp+(y1+y2)/2
    def ang(ux,uy,vx,vy):
        a=math.atan2(ux*vy-uy*vx, ux*vx+uy*vy); return a
    t1=ang(1,0,(x1p-cxp)/rx,(y1p-cyp)/ry)
    dt=ang((x1p-cxp)/rx,(y1p-cyp)/ry,(-x1p-cxp)/rx,(-y1p-cyp)/ry)
    if not fs and dt>0: dt-=2*math.pi
    if fs and dt<0: dt+=2*math.pi
    n=max(1,int(math.ceil(abs(dt)/(math.pi/2)-1e-9))); d=dt/n
    out=[]; k=4/3*math.tan(d/4)
    for i in range(n):
        a1=t1+i*d; a2=a1+d
        p=lambda a:(cx+rx*math.cos(a)*c-ry*math.sin(a)*s, cy+rx*math.cos(a)*s+ry*math.sin(a)*c)
        dp=lambda a:(-rx*math.sin(a)*c-ry*math.cos(a)*s, -rx*math.sin(a)*s+ry*math.cos(a)*c)
        P1=p(a1);P2=p(a2);D1=dp(a1);D2=dp(a2)
        out.append(('C',P1[0]+k*D1[0],P1[1]+k*D1[1],P2[0]-k*D2[0],P2[1]-k*D2[1],P2[0],P2[1]))
    return out
def path(d):
    t=list(tokens(d)); i=0; cmd=None; x=y=sx=sy=0; lc=None; ops=[]
    def num():
        nonlocal i; v=float(t[i]); i+=1; return v
    def flag():
        nonlocal i
        tok=t[i]
        if len(tok)>1 and tok[0] in '01':
            t[i]=tok[1:]; return int(tok[0])
        i+=1; return int(float(tok))
    while i<len(t):
        if re.match(r'[A-Za-z]',t[i]): cmd=t[i]; i+=1
        rel=cmd.islower(); C=cmd.upper()
        ox,oy=(x,y) if rel else (0,0)
        if C=='M':
            x,y=num()+ox,num()+oy; sx,sy=x,y; ops.append(('M',x,y)); cmd='l' if rel else 'L'; lc=None
        elif C=='L': x,y=num()+ox,num()+oy; ops.append(('L',x,y)); lc=None
        elif C=='H': x=num()+(x if rel else 0); ops.append(('L',x,y)); lc=None
        elif C=='V': y=num()+(y if rel else 0); ops.append(('L',x,y)); lc=None
        elif C=='C':
            a=[num()+(ox if j%2==0 else oy) for j in range(6)]; ops.append(('C',*a)); lc=(a[2],a[3]); x,y=a[4],a[5]
        elif C=='S':
            a=[num()+(ox if j%2==0 else oy) for j in range(4)]
            c1=(2*x-lc[0],2*y-lc[1]) if lc else (x,y)
            ops.append(('C',c1[0],c1[1],*a)); lc=(a[0],a[1]); x,y=a[2],a[3]
        elif C=='Q':
            a=[num()+(ox if j%2==0 else oy) for j in range(4)]
            ops.append(('C',x+2/3*(a[0]-x),y+2/3*(a[1]-y),a[2]+2/3*(a[0]-a[2]),a[3]+2/3*(a[1]-a[3]),a[2],a[3])); lc=None; x,y=a[2],a[3]
        elif C=='A':
            rx,ry,ph=num(),num(),num(); fa=flag(); fs=flag(); x2,y2=num()+ox,num()+oy
            ops+=arc_to_cubic(x,y,rx,ry,ph,int(fa),int(fs),x2,y2); x,y=x2,y2; lc=None
        elif C=='Z': ops.append(('Z',)); x,y=sx,sy; lc=None
        else: raise Exception(cmd)
    return ops
def circle(cx,cy,r): return path(f"M{cx-r} {cy}a{r} {r} 0 1 0 {2*r} 0a{r} {r} 0 1 0 {-2*r} 0z")
def rect(x,y,w,h,rx):
    if rx==0: return path(f"M{x} {y}h{w}v{h}h{-w}z")
    return path(f"M{x+rx} {y}h{w-2*rx}a{rx} {rx} 0 0 1 {rx} {rx}v{h-2*rx}a{rx} {rx} 0 0 1 {-rx} {rx}h{-(w-2*rx)}a{rx} {rx} 0 0 1 {-rx} {-rx}v{-(h-2*rx)}a{rx} {rx} 0 0 1 {rx} {-rx}z")
code={'M':0,'L':1,'C':2,'Z':3}
out=["// Generált fájl (scripts/lucide-conv.py): Lucide ikonok (ISC licenc, lucide-static 1.63.0), 24×24 viewBox.","// Copyright (c) Lucide Icons and Contributors — lásd Resources/LICENSE-lucide.txt.","enum LucideData {","    static let icons: [String: [Double]] = ["]
for f in sorted(glob.glob(sys.argv[1]+'/*.svg')):
    name=os.path.basename(f)[:-4]
    root=ET.fromstring(re.sub(r'<!--.*?-->','',open(f).read(),flags=re.S))
    ops=[]
    for el in root.iter():
        tag=el.tag.split('}')[-1]; g=lambda k,d=0: float(el.get(k,d))
        if tag=='path': ops+=path(el.get('d'))
        elif tag=='circle': ops+=circle(g('cx'),g('cy'),g('r'))
        elif tag=='rect': ops+=rect(g('x'),g('y'),g('width'),g('height'),g('rx',el.get('ry',0)))
        elif tag=='line': ops+=[('M',g('x1'),g('y1')),('L',g('x2'),g('y2'))]
        elif tag in('polyline','polygon'):
            p=[float(v) for v in re.split(r'[ ,]+',el.get('points').strip())]
            ops.append(('M',p[0],p[1])); ops+=[('L',p[j],p[j+1]) for j in range(2,len(p),2)]
            if tag=='polygon': ops.append(('Z',))
        elif tag in('svg',): pass
        else: raise Exception(name+tag)
    flat=[]
    for o in ops: flat.append(code[o[0]]); flat+= [round(v,3) for v in o[1:]]
    out.append(f'        "{name}": [{", ".join(("%g"%v) for v in flat)}],')
out+=["    ]","}"]
print("\n".join(out))
