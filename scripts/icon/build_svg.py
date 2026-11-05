"""Builds EditMax/Resources/AppIcon.svg: python3 scripts/icon/build_svg.py scripts/icon/plate_mask.raw EditMax/Resources/AppIcon.svg
Builds the EditMax app icon SVG. The plate (dark squircle, shading, rim light, drop shadow) is a bitmap whose shape
comes from a real macOS app icon's alpha channel (apple_alpha.raw, 1024x1024 bytes, top row first), so size, corner
curve and shadow match the system icons exactly; vector gradients would also band. The glyph is vector on top."""
import math, zlib, struct, base64, random, sys
W=1024; cx=cy=512.0
alpha=open(sys.argv[1],"rb").read(); out=sys.argv[2]
random.seed(3)
ap=[a/255 for a in alpha]
# body = the opaque shape with its anti-aliased edge; everything fainter is Apple's soft outer shadow
body=[max(0.0,min(1.0,(v-0.18)/0.82)) for v in ap]
shadow=[min(v,0.18)/0.18*0.18 for v in ap]
# 2 px erosion of the body (separable min) → the edge band for the rim light
def erode(src,rad):
    tmp=[0.0]*(W*W); dst=[0.0]*(W*W)
    for y in range(W):
        row=src[y*W:(y+1)*W]
        for x in range(W): tmp[y*W+x]=min(row[max(0,x-rad):x+rad+1])
    for x in range(W):
        col=tmp[x::W]
        for y in range(W): dst[y*W+x]=min(col[max(0,y-rad):y+rad+1])
    return dst
inner=erode(body,2)
top=(0x30,0x30,0x33); mid=(0x19,0x19,0x1b); bot=(0x0d,0x0d,0x0e)
def lerp(a,b,t): return a+(b-a)*t
rows=[]
for iy in range(W):
    row=bytearray([0]); t=max(0,min(1,(iy-100)/824))
    base=tuple(lerp(top[i],mid[i],t/0.5) if t<0.5 else lerp(mid[i],bot[i],(t-0.5)/0.5) for i in range(3))
    for ix in range(W):
        k=iy*W+ix; b=body[k]; sh=shadow[k]
        if b==0 and sh==0: row+=b"\0\0\0\0"; continue
        sx=(ix-cx)/(0.9*824); sy=(iy-(100+0.05*824))/(0.9*824); s=max(0,1-math.sqrt(sx*sx+sy*sy))
        sheen=0.13*max(0,(s-0.45)/0.55)**1.4
        hx=(ix-(cx+18))/430; hy=(iy-(cy+30))/340; hh=max(0,1-math.sqrt(hx*hx+hy*hy)); halo=0.12*hh*hh
        rim=(b-inner[k])*(0.55*(1-t)**3+0.05)        # bright edge, strongest along the top
        light=min(1,sheen+halo+rim)
        rgb=[]
        for i in range(3):
            v=base[i]*(1-light)+255*light + (random.random()-0.5)*2.2
            rgb.append(max(0,min(255,v)))
        a=b+sh*(1-b)                                  # plate over its own black shadow
        if a<=0: row+=b"\0\0\0\0"; continue
        row+=bytes(int(round(c*b/a)) for c in rgb)+bytes([int(round(a*255))])
    rows.append(bytes(row))
raw=b"".join(rows)
def chunk(t,d): return struct.pack(">I",len(d))+t+d+struct.pack(">I",zlib.crc32(t+d)&0xffffffff)
png=b"\x89PNG\r\n\x1a\n"+chunk(b"IHDR",struct.pack(">IIBBBBB",W,W,8,6,0,0,0))+chunk(b"IDAT",zlib.compress(raw,9))+chunk(b"IEND",b"")
plate64=base64.b64encode(png).decode()

h=392.0; w=h*0.90; ox=18
P=[(cx-w*0.42+ox, cy-h/2),(cx+w*0.58+ox, cy),(cx-w*0.42+ox, cy+h/2)]
poly=" ".join(f"{x:.1f},{y:.1f}" for x,y in P)
tri=f'<polygon points="{poly}" stroke-width="54" stroke-linejoin="round"/>'
gap=26; band=178; clips=[]; strips=[]
for i,off in enumerate([-band-gap, 0, band+gap]):
    clips.append(f'<clipPath id="s{i}"><rect x="{cx-900}" y="{cy+off-band/2:.1f}" width="1800" height="{band}" transform="rotate(-45 {cx} {cy})"/></clipPath>')
    dx, dy = (i-1)*8, (i-1)*-8
    strips.append(f'''
  <g filter="url(#bevel)"><g clip-path="url(#s{i})"><g transform="translate({dx},{dy})">
    <g fill="url(#metal)" stroke="url(#metal)">{tri}</g>
    <g clip-path="url(#glyph)"><rect x="0" y="0" width="1024" height="1024" fill="url(#spec)"/></g>
  </g></g></g>''')
svg=f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
  <linearGradient id="metal" x1="0.1" y1="0" x2="0.6" y2="1"><stop offset="0" stop-color="#ffffff"/><stop offset="0.38" stop-color="#e4e4e8"/><stop offset="0.72" stop-color="#adadb3"/><stop offset="1" stop-color="#76767d"/></linearGradient>
  <linearGradient id="spec" x1="0" y1="0" x2="1" y2="1"><stop offset="0.22" stop-color="#ffffff" stop-opacity="0"/><stop offset="0.40" stop-color="#ffffff" stop-opacity="0.30"/><stop offset="0.49" stop-color="#ffffff" stop-opacity="0.04"/><stop offset="1" stop-color="#ffffff" stop-opacity="0"/></linearGradient>
  <filter id="glyphShadow" x="-40%" y="-40%" width="180%" height="180%"><feDropShadow dx="0" dy="16" stdDeviation="14" flood-color="#000" flood-opacity="0.75"/><feDropShadow dx="0" dy="2" stdDeviation="1.5" flood-color="#000" flood-opacity="0.6"/></filter>
  <filter id="bevel" x="-10%" y="-10%" width="120%" height="120%">
    <feOffset in="SourceAlpha" dx="2.4" dy="2.4" result="oa"/><feComposite in="SourceAlpha" in2="oa" operator="out" result="hiM"/>
    <feFlood flood-color="#ffffff" flood-opacity="0.9" result="hiC"/><feComposite in="hiC" in2="hiM" operator="in" result="hi"/><feGaussianBlur in="hi" stdDeviation="0.5" result="hib"/>
    <feOffset in="SourceAlpha" dx="-2.4" dy="-2.4" result="ob"/><feComposite in="SourceAlpha" in2="ob" operator="out" result="loM"/>
    <feFlood flood-color="#24242a" flood-opacity="0.8" result="loC"/><feComposite in="loC" in2="loM" operator="in" result="lo"/><feGaussianBlur in="lo" stdDeviation="0.5" result="lob"/>
    <feMerge><feMergeNode in="SourceGraphic"/><feMergeNode in="hib"/><feMergeNode in="lob"/></feMerge>
  </filter>
  <clipPath id="glyph">{tri}</clipPath>
  {''.join(clips)}
</defs>
<image x="0" y="0" width="1024" height="1024" href="data:image/png;base64,{plate64}"/>
<g filter="url(#glyphShadow)">{''.join(strips)}
</g>
</svg>'''
open(out,"w").write(svg); print("svg", len(svg)//1024, "KB")
