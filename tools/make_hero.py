import sys, numpy as np, struct
sys.path.insert(0,"C:/Users/Command/AppData/Local/Temp/claude/E--UZDXREMA/4db00efe-d4d4-45ee-b2b0-214623695aeb/scratchpad")
from iqmrender import IQM, mat_from_trs, render
m=IQM(sys.argv[1]); out=sys.argv[2]
def cstr(t,o):
    e=t.find(b"\0",o); return t[o:e].decode()
names=[cstr(m.txt,struct.unpack_from("<I",m.b,m.ofs_joints+i*48)[0]) for i in range(m.num_joints)]
mid=[i for i,n in enumerate(names) if n.startswith("MIDDLE_F")]
def raw(f):
    row=m.framedata[f*m.num_fc:(f+1)*m.num_fc]; k=0; o=[]
    for i,(par,mask,co,cs) in enumerate(m.poses):
        v=[0.0]*10
        for c in range(10):
            v[c]=co[c]
            if mask&(1<<c): v[c]+=float(row[k])*cs[c]; k+=1
        o.append(v)
    return o
R0, R3 = raw(0), raw(3)                 # 0 = open (all straight), 3 = fist
V=[list(v) for v in R3]                 # start from the fist
for j in mid:                           # middle finger takes ITS OWN straight rotations
    V[j][3:7]=list(R0[j][3:7])
loc=[mat_from_trs(v[0:3],v[3:7],v[7:10]) for v in V]
A=[]
for i in range(m.num_joints):
    p=m.jparent[i]; A.append(loc[i] if p<0 else A[p]@loc[i])
Sm=np.stack([A[i]@m.invbind[i] for i in range(m.num_joints)])
P=np.concatenate([m.pos,np.ones((len(m.pos),1))],1)
o=np.zeros((len(m.pos),3)); w=m.bw.copy(); t=w.sum(1,keepdims=True); t[t==0]=1; w=w/t
for j in range(4):
    M=Sm[m.bi[:,j]]; o+=np.einsum('vij,vj->vi',M[:,:3,:],P)*w[:,j:j+1]
render(o,m.tris,900,az=6,el=76).save(out); print("wrote",out)
