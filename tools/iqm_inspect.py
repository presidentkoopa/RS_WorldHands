import struct, sys, numpy as np
from PIL import Image, ImageDraw

HDR="<16s27I"

def mat_from_trs(t,q,s):
    x,y,z,w=q; n=(x*x+y*y+z*z+w*w)**0.5
    if n==0: x,y,z,w=0,0,0,1
    else: x,y,z,w=x/n,y/n,z/n,w/n
    R=np.array([
        [1-2*(y*y+z*z), 2*(x*y-w*z),   2*(x*z+w*y)],
        [2*(x*y+w*z),   1-2*(x*x+z*z), 2*(y*z-w*x)],
        [2*(x*z-w*y),   2*(y*z+w*x),   1-2*(x*x+y*y)]],dtype=np.float64)
    M=np.eye(4); M[:3,:3]=R*np.array(s,dtype=np.float64)[None,:]; M[:3,3]=t
    return M

class IQM:
    def __init__(self,path):
        b=open(path,"rb").read(); self.b=b
        h=struct.unpack_from(HDR,b,0)
        (self.num_text,self.ofs_text,self.num_meshes,self.ofs_meshes,self.num_va,self.num_vt,self.ofs_va,
         self.num_tri,self.ofs_tri,_,self.num_joints,self.ofs_joints,self.num_poses,self.ofs_poses,
         self.num_anims,self.ofs_anims,self.num_frames,self.num_fc,self.ofs_frames,self.ofs_bounds,
         _,_,_,_)=h[4:28]
        self.txt=b[self.ofs_text:self.ofs_text+self.num_text]
        # vertex arrays
        self.pos=self.nrm=self.bi=self.bw=None
        for i in range(self.num_va):
            t,fl,fmt,size,off=struct.unpack_from("<5I",b,self.ofs_va+i*20)
            if   t==0: self.pos=np.frombuffer(b,np.float32,self.num_vt*3,off).reshape(-1,3).astype(np.float64)
            elif t==2: self.nrm=np.frombuffer(b,np.float32,self.num_vt*3,off).reshape(-1,3).astype(np.float64)
            elif t==4: self.bi =np.frombuffer(b,np.uint8, self.num_vt*4,off).reshape(-1,4).astype(np.int32)
            elif t==5: self.bw =np.frombuffer(b,np.uint8, self.num_vt*4,off).reshape(-1,4).astype(np.float64)/255.0
        self.tris=np.frombuffer(b,np.uint32,self.num_tri*3,self.ofs_tri).reshape(-1,3).astype(np.int32)
        # joints
        self.jparent=[];self.jbase=[]
        for i in range(self.num_joints):
            o=self.ofs_joints+i*48
            par=struct.unpack_from("<i",b,o+4)[0]
            t=struct.unpack_from("<3f",b,o+8); q=struct.unpack_from("<4f",b,o+20); s=struct.unpack_from("<3f",b,o+36)
            self.jparent.append(par); self.jbase.append(mat_from_trs(t,q,s))
        self.absbind=[]; self.invbind=[]
        for i in range(self.num_joints):
            p=self.jparent[i]
            M=self.jbase[i] if p<0 else self.absbind[p]@self.jbase[i]
            self.absbind.append(M); self.invbind.append(np.linalg.inv(M))
        # poses
        self.poses=[]
        for i in range(self.num_poses):
            o=self.ofs_poses+i*88
            par,mask=struct.unpack_from("<iI",b,o)
            co=struct.unpack_from("<10f",b,o+8); cs=struct.unpack_from("<10f",b,o+48)
            self.poses.append((par,mask,co,cs))
        self.framedata=np.frombuffer(b,np.uint16,self.num_frames*self.num_fc,self.ofs_frames) if self.num_frames else None

    def frame_matrices(self,frame):
        row=self.framedata[frame*self.num_fc:(frame+1)*self.num_fc]; k=0
        loc=[]
        for i,(par,mask,co,cs) in enumerate(self.poses):
            v=[0.0]*10
            for c in range(10):
                v[c]=co[c]
                if mask&(1<<c):
                    v[c]+=float(row[k])*cs[c]; k+=1
            loc.append(mat_from_trs(v[0:3],v[3:7],v[7:10]))
        absa=[]
        for i in range(self.num_joints):
            p=self.jparent[i]
            absa.append(loc[i] if p<0 else absa[p]@loc[i])
        return [absa[i]@self.invbind[i] for i in range(self.num_joints)]

    def skin(self,frame):
        if frame is None or self.framedata is None: return self.pos.copy()
        S=np.stack(self.frame_matrices(frame))            # J,4,4
        P=np.concatenate([self.pos,np.ones((len(self.pos),1))],1)  # V,4
        out=np.zeros((len(self.pos),3))
        w=self.bw.copy(); tot=w.sum(1,keepdims=True); tot[tot==0]=1; w=w/tot
        for j in range(4):
            M=S[self.bi[:,j]]                              # V,4,4
            out+=np.einsum('vij,vj->vi',M[:,:3,:],P)*w[:,j:j+1]
        return out

def render(v,tris,size=440,az=0.0,el=0.0):
    a,e=np.radians(az),np.radians(el)
    Ry=np.array([[np.cos(a),0,np.sin(a)],[0,1,0],[-np.sin(a),0,np.cos(a)]])
    Rx=np.array([[1,0,0],[0,np.cos(e),-np.sin(e)],[0,np.sin(e),np.cos(e)]])
    p=v@Ry.T@Rx.T
    mn,mx=p.min(0),p.max(0); c=(mn+mx)/2; sc=(mx-mn).max()
    if sc==0: sc=1
    q=(p-c)/sc
    xs=(q[:,0]*size*0.80+size/2); ys=(-q[:,1]*size*0.80+size/2); zs=q[:,2]
    img=Image.new("RGB",(size,size),(17,19,23)); d=ImageDraw.Draw(img)
    A,B,C=v[tris[:,0]],v[tris[:,1]],v[tris[:,2]]
    n=np.cross(B-A,C-A); ln=np.linalg.norm(n,axis=1); ln[ln==0]=1; n=n/ln[:,None]
    nr=n@Ry.T@Rx.T
    L=np.array([0.35,0.55,0.75]); L=L/np.linalg.norm(L)
    sh=np.clip(np.abs(nr@L),0,1)*0.78+0.22
    depth=zs[tris].mean(1); order=np.argsort(depth)
    for t in order:
        i,j,k=tris[t]; s=sh[t]
        col=(int(232*s),int(206*s),int(184*s))
        d.polygon([(xs[i],ys[i]),(xs[j],ys[j]),(xs[k],ys[k])],fill=col)
    return img

if __name__=="__main__":
    src,out=sys.argv[1],sys.argv[2]
    frames=[(int(f.split(':')[0]),f.split(':')[1]) for f in sys.argv[3:]]
    m=IQM(src)
    S=440; pad=10
    W=S*len(frames)+pad*(len(frames)+1); H=S+pad*2+30
    sheet=Image.new("RGB",(W,H),(11,12,15)); dr=ImageDraw.Draw(sheet)
    for n,(fr,label) in enumerate(frames):
        v=m.skin(fr)
        im=render(v,m.tris,S,az=35,el=18)
        sheet.paste(im,(pad+n*(S+pad),pad))
        dr.text((pad+n*(S+pad)+8,S+pad+6),"frame %d  -  %s"%(fr,label),fill=(190,200,215))
    sheet.save(out); print("wrote",out,sheet.size)
