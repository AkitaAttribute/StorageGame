"""Bake modular garments onto Shino's existing glTF skin at asset-build time."""
import copy
import hashlib
import json
import math
import struct
import urllib.request

BASE = "https://raw.githubusercontent.com/madjin/vrm-samples/e16eb187100149a315ad92c3c9968f1d5baa6c7d/vroid/beta/"
DONORS = {
    "Sendagaya_Shibu.vrm": (17049284, "233c9070f7bc3e13d2e162774dacccf72baaf566"),
    "HairSample_Male.vrm": (18481892, "46e8c583ce5df3b8ee167141b59ba3ad583a2687"),
}
FORMATS = {5120:"b",5121:"B",5122:"h",5123:"H",5125:"I",5126:"f"}
WIDTH = {"SCALAR":1,"VEC2":2,"VEC3":3,"VEC4":4,"MAT4":16}

def source(cache, name):
    size, sha = DONORS[name]
    p = cache / name
    def valid(raw):
        return len(raw)==size and hashlib.sha1(b"blob "+str(len(raw)).encode()+b"\0"+raw).hexdigest()==sha
    if not p.exists() or not valid(p.read_bytes()):
        req=urllib.request.Request(BASE+name,headers={"User-Agent":"StorageGame wardrobe"})
        raw=urllib.request.urlopen(req,timeout=90).read(size+1)
        if not valid(raw):
            raise RuntimeError("Unexpected wardrobe source: "+name)
        p.write_bytes(raw)
    raw=p.read_bytes()
    n=struct.unpack_from("<I",raw,12)[0]
    d=json.loads(raw[20:20+n])
    if d["extensions"]["VRM"]["meta"]["licenseName"] != "CC0":
        raise RuntimeError("Wardrobe donor is not CC0")
    return d,raw[28+n:]

def read(d,buf,idx):
    a=d["accessors"][idx]
    v=d["bufferViews"][a["bufferView"]]
    fmt="<"+FORMATS[a["componentType"]]*WIDTH[a["type"]]
    step=v.get("byteStride",struct.calcsize(fmt))
    off=v.get("byteOffset",0)+a.get("byteOffset",0)
    vals=[struct.unpack_from(fmt,buf,off+i*step) for i in range(a["count"])]
    if a.get("normalized") and a["componentType"] != 5126:
        div={5120:127,5121:255,5122:32767,5123:65535}[a["componentType"]]
        vals=[tuple(max(-1,x/div) for x in row) for row in vals]
    return vals

def body(d):
    return next((i,n) for i,n in enumerate(d["nodes"]) if n.get("name")=="Body" and "skin" in n)

def garment(d,node,category):
    return next(p for p in d["meshes"][node["mesh"]]["primitives"]
                if "_"+category+"_" in d["materials"][p["material"]].get("name",""))

def inverse(m):
    rows=[[m[c*4+r] for c in range(4)]+[float(r==c) for c in range(4)] for r in range(4)]
    for i in range(4):
        p=max(range(i,4),key=lambda j:abs(rows[j][i]))
        rows[i],rows[p]=rows[p],rows[i]
        z=rows[i][i]
        if abs(z)<1e-10: raise RuntimeError("Singular garment bind")
        rows[i]=[x/z for x in rows[i]]
        for j in range(4):
            if j!=i:
                z=rows[j][i]
                rows[j]=[x-z*y for x,y in zip(rows[j],rows[i])]
    return [rows[r][4+c] for c in range(4) for r in range(4)]

def point(m,v):
    return tuple(sum(m[c*4+r]*v[c] for c in range(3))+m[12+r] for r in range(3))

def add_wardrobe(doc, raw_bin, cache):
    buf=bytearray(raw_bin[:doc["buffers"][0]["byteLength"]])
    base_id,base=body(doc)
    target_skin=doc["skins"][base["skin"]]
    target_nodes=target_skin["joints"]
    target_human={x["bone"]:x["node"] for x in doc["extensions"]["VRM"]["humanoid"]["humanBones"]}
    target_joint={node:i for i,node in enumerate(target_nodes)}
    target_bind=read(doc,buf,target_skin["inverseBindMatrices"])
    target_rest=[inverse(m) for m in target_bind]
    def view(data,target=None):
        buf.extend(b"\0"*((-len(buf))%4))
        idx=len(doc["bufferViews"])
        info={"buffer":0,"byteOffset":len(buf),"byteLength":len(data)}
        if target:info["target"]=target
        doc["bufferViews"].append(info)
        buf.extend(data)
        return idx
    def accessor(vals,kind,ctype,target):
        fmt="<"+FORMATS[ctype]*WIDTH[kind]
        i=len(doc["accessors"])
        a={"bufferView":view(b"".join(struct.pack(fmt,*v) for v in vals),target),
           "componentType":ctype,"count":len(vals),"type":kind}
        if kind=="VEC3" and ctype==5126:
            a.update(min=[min(x[j] for x in vals) for j in range(3)],max=[max(x[j] for x in vals) for j in range(3)])
        doc["accessors"].append(a)
        return i
    def material(d,srcbuf,mi,name):
        mat=copy.deepcopy(d["materials"][mi])
        # Use glTF fallback material only; no donor-specific shader extensions.
        mat.pop("extensions",None)
        mat["name"]=name
        def texture(info):
            tex=copy.deepcopy(d["textures"][info["index"]])
            img=copy.deepcopy(d["images"][tex["source"]])
            bv=d["bufferViews"][img["bufferView"]]
            off=bv.get("byteOffset",0)
            img["bufferView"]=view(srcbuf[off:off+bv["byteLength"]])
            tex["source"]=len(doc["images"])
            doc["images"].append(img)
            if "sampler" in tex:
                sampler=copy.deepcopy(d["samplers"][tex["sampler"]])
                tex["sampler"]=len(doc.setdefault("samplers",[]))
                doc["samplers"].append(sampler)
            tex.pop("extensions",None)
            info["index"]=len(doc["textures"])
            doc["textures"].append(tex)
        for key in ["baseColorTexture","metallicRoughnessTexture"]:
            if key in mat.get("pbrMetallicRoughness",{}):texture(mat["pbrMetallicRoughness"][key])
        for key in ["normalTexture","occlusionTexture","emissiveTexture"]:
            if key in mat:texture(mat[key])
        i=len(doc["materials"])
        doc["materials"].append(mat)
        return i
    def add_mesh(name,prim):
        # The donor mesh shares the original Body skin and parent transform.
        # No extra skeleton or duplicate avatar is imported.
        mesh=len(doc["meshes"])
        doc["meshes"].append({"name":name,"primitives":prim if isinstance(prim,list) else [prim]})
        node=copy.deepcopy(base)
        node.pop("children",None)
        node.pop("weights",None)
        node.update(name=name,mesh=mesh)
        idx=len(doc["nodes"])
        doc["nodes"].append(node)
        for parent in doc["nodes"][:idx]:
            if base_id in parent.get("children",[]):
                parent["children"].append(idx)
                break
        else:
            scene=doc["scenes"][doc.get("scene",0)]
            if base_id not in scene["nodes"]:raise RuntimeError("Body parent missing")
            scene["nodes"].append(idx)
    # Same female template: import the alternate uniform textures onto
    # Shino's own original clothing geometry, including her skirt bones.
    d,srcbuf=source(cache,"Sendagaya_Shibu.vrm")
    _,donor=body(d)
    for category,name in [("Tops","WardrobeTopUniform"),("Bottoms","WardrobeBottomUniform")]:
        old=garment(doc,base,category)
        p=copy.deepcopy(old)
        p.pop("targets",None)
        p["material"]=material(d,srcbuf,garment(d,donor,category)["material"],name)
        add_mesh(name,p)
    def smooth(a,b,x):
        t=max(0.,min(1.,(x-a)/(b-a)))
        return t*t*(3.-2.*t)
    hips=target_rest[target_joint[target_human["hips"]]][12:15]
    # Measure only vertices indexed by each clothing primitive, not the
    # shared Body accessor (which also includes hair, shoes and fingers).
    def indexed_triangles(prim):
        pos=read(doc,buf,prim["attributes"]["POSITION"])
        ids=[v[0] for v in read(doc,buf,prim["indices"])]
        return [tuple(pos[k] for k in ids[i:i+3]) for i in range(0,len(ids),3)]
    top_tri=indexed_triangles(garment(doc,base,"Tops"))
    skirt_tri=indexed_triangles(garment(doc,base,"Bottoms"))
    torso_top=[v for tri in top_tri for v in tri if abs(v[0]-hips[0])<.21]
    skirt_pts=[v for tri in skirt_tri for v in tri]
    shirt_hem=min(v[1] for v in torso_top)
    skirt_waist=max(v[1] for v in skirt_pts)
    pants_waist=shirt_hem+.085
    hoodie_hem=skirt_waist-.050
    print("WARDROBE_SEAMS", "shirt_hem",shirt_hem,"skirt_waist",skirt_waist,
          "pants_waist",pants_waist,"hoodie_hem",hoodie_hem)
    if not (.65<shirt_hem<1.15 and .65<skirt_waist<1.15):
        raise RuntimeError("Unexpected original garment seams")
    def cross2(a,b):
        return a[0]*b[1]-a[1]*b[0]
    def section_radius(tris,y,dx,dz):
        # Intersect the horizontal plane with actual cloth triangles, then
        # measure along the requested radial ray. No bounding box inflation.
        direction=(dx,dz)
        far=0.
        for tri in tris:
            if not min(v[1] for v in tri)<=y<=max(v[1] for v in tri):continue
            hits=[]
            for a,b in zip(tri,tri[1:]+tri[:1]):
                if (a[1]<=y<b[1]) or (b[1]<=y<a[1]):
                    t=(y-a[1])/(b[1]-a[1])
                    hits.append((a[0]+t*(b[0]-a[0])-hips[0],a[2]+t*(b[2]-a[2])-hips[2]))
            if len(hits)!=2:continue
            a,b=hits
            edge=(b[0]-a[0],b[1]-a[1])
            den=cross2(direction,edge)
            if abs(den)<1e-9:continue
            radius=cross2(a,edge)/den
            u=cross2(a,direction)/den
            if 0<=u<=1 and 0<radius<.27:far=max(far,radius)
        return far
    hip_joint=target_joint[target_human["hips"]]
    leg_centers={}
    for side in ("left","right"):
        leg_centers[side]=[target_rest[target_joint[target_human[side+k]]][12:15]
                           for k in ("UpperLeg","LowerLeg","Foot")]
    def trouser_ease(v):
        x,y,z=v
        side=min(leg_centers,key=lambda k:abs(x-leg_centers[k][0][0]))
        a,b,c=leg_centers[side]
        hi,lo=(a,b) if y>=b[1] else (b,c)
        t=max(0.,min(1.,(hi[1]-y)/max(.001,hi[1]-lo[1])))
        cx=hi[0]+(lo[0]-hi[0])*t
        cz=hi[2]+(lo[2]-hi[2])*t
        waist=smooth(hips[1]-.19,hips[1]-.065,y)
        cx=cx*(1.-waist)+hips[0]*waist
        cz=cz*(1.-waist)+hips[2]*waist
        ease=1.045+.015*waist
        return (cx+(x-cx)*ease,y,cz+(z-cz)*ease)

    # Different geometry: transfer the original weighted hoodie/trouser
    # vertices onto Shino's skin using the matching humanoid bind matrices.
    d,srcbuf=source(cache,"HairSample_Male.vrm")
    _,donor=body(d)
    donor_skin=d["skins"][donor["skin"]]
    donor_human={x["node"]:x["bone"] for x in d["extensions"]["VRM"]["humanoid"]["humanBones"]}
    parents={child:i for i,node in enumerate(d["nodes"]) for child in node.get("children",[])}
    mapping={}
    for i,node in enumerate(donor_skin["joints"]):
        j=node
        while j not in donor_human and j in parents:j=parents[j]
        key=donor_human.get(j)
        if key in target_human and target_human[key] in target_joint:
            mapping[i]=target_joint[target_human[key]]
    donor_bind=read(d,srcbuf,donor_skin["inverseBindMatrices"])
    # Fit the inner trousers first, so the outer hoodie can be fitted to both bottoms.
    pants_tri=[]
    for category,name in [("Bottoms","WardrobeBottomTrousers"),("Tops","WardrobeTopHoodie")]:
        p=garment(d,donor,category)
        attrs=p["attributes"]
        indexes=[v[0] for v in read(d,srcbuf,p["indices"])]
        selected=sorted(set(indexes))
        remap={v:i for i,v in enumerate(selected)}
        pos=read(d,srcbuf,attrs["POSITION"])
        normals=read(d,srcbuf,attrs["NORMAL"])
        uv=read(d,srcbuf,attrs["TEXCOORD_0"])
        joints=read(d,srcbuf,attrs["JOINTS_0"])
        weights=read(d,srcbuf,attrs["WEIGHTS_0"])
        out_pos=[];out_joints=[];out_weights=[]
        for v in selected:
            combined={}
            result=[0.,0.,0.]
            total=0.
            for j,w in zip(joints[v],weights[v]):
                if w<1e-6:continue
                if j not in mapping:raise RuntimeError("Unmapped garment joint: "+name+" "+str(j))
                k=mapping[j]
                local=point(donor_bind[j],pos[v])
                # Narrow the male cut moderately while retaining fabric ease.
                if category=="Tops":
                    local=(local[0]*0.97,local[1],local[2]*0.97)
                fitted=point(target_rest[k],local)
                for a in range(3):result[a]+=fitted[a]*w
                total+=w
                combined[k]=combined.get(k,0.)+w
            if total<1e-6:raise RuntimeError("Unweighted garment vertex")
            pairs=sorted(combined.items(),key=lambda x:-x[1])[:4]
            norm=sum(w for _,w in pairs)
            fitted=tuple(x/total for x in result)
            out_pos.append(trouser_ease(fitted) if category=="Bottoms" else fitted)
            out_joints.append(tuple([j for j,w in pairs]+[0]*(4-len(pairs))))
            out_weights.append(tuple([w/norm for j,w in pairs]+[0.]*(4-len(pairs))))
        if len(selected)<100:raise RuntimeError("Garment geometry unexpectedly small")
        def pin_waist(i,amount):
            # Match the stable pelvis at the shared seam. Blend back into
            # original weights above/below it; do not modify the skeleton.
            if amount<=0:return
            weights={}
            for j,w in zip(out_joints[i],out_weights[i]):
                if w>1e-6:weights[j]=weights.get(j,0.)+w*(1-amount)
            weights[hip_joint]=weights.get(hip_joint,0.)+amount
            pairs=sorted(weights.items(),key=lambda x:-x[1])[:4]
            total=sum(w for j,w in pairs)
            out_joints[i]=tuple([j for j,w in pairs]+[0]*(4-len(pairs)))
            out_weights[i]=tuple([w/total for j,w in pairs]+[0.]*(4-len(pairs)))
        if category=="Bottoms":
            old_waist=max(v[1] for v in out_pos)
            for i,(x,y,z) in enumerate(out_pos):
                band=smooth(old_waist-.20,old_waist,y)
                y+=(pants_waist-old_waist)*band
                dx,dz=x-hips[0],z-hips[2]
                radius=math.hypot(dx,dz)
                if radius>1e-6 and y>=shirt_hem-.015:
                    # Fit the high edge INSIDE the uniform top, never
                    # expand the top of the trousers through the shirt.
                    outer=section_radius(top_tri,max(y,shirt_hem+.005),dx/radius,dz/radius)
                    if outer>0:
                        target=min(radius,max(.025,outer-.009))
                        amount=smooth(shirt_hem-.015,shirt_hem+.012,y)
                        radius2=radius+(target-radius)*amount
                        x,z=hips[0]+dx/radius*radius2,hips[2]+dz/radius*radius2
                    pin_waist(i,smooth(shirt_hem-.05,pants_waist,y)*.85)
                out_pos[i]=(x,y,z)
            pants_tri=[tuple(out_pos[remap[k]] for k in indexes[i:i+3]) for i in range(0,len(indexes),3)]
            pants_positions=list(out_pos)
        else:
            # Preserve the full donor hoodie for trousers. The prior
            # per-vertex hem fit shortened only some neighboring vertices,
            # and its cubic easing could reverse the vertical derivative.
            # A separate skirt cut is generated below from this same mesh.
            hoodie_positions=list(out_pos)
            hoodie_joints=list(out_joints)
            hoodie_weights=list(out_weights)
        # Preserve the donor normal orientation; rebuild deformed normals
        # from the mesh without merging unrelated coincident vertices.
        def fitted_normals(positions):
            sums=[[0.,0.,0.] for _ in positions]
            for k in range(0,len(indexes),3):
                ids=[remap[v] for v in indexes[k:k+3]]
                a,b,c=[positions[v] for v in ids]
                ab=[b[j]-a[j] for j in range(3)]
                ac=[c[j]-a[j] for j in range(3)]
                normal=(ab[1]*ac[2]-ab[2]*ac[1],ab[2]*ac[0]-ab[0]*ac[2],ab[0]*ac[1]-ab[1]*ac[0])
                for v in ids:
                    original=normals[selected[v]]
                    sign=1. if sum(x*z for x,z in zip(original,normal))>=0 else -1.
                    for j in range(3):sums[v][j]+=sign*normal[j]
            result=[]
            for i,normal in enumerate(sums):
                length=math.sqrt(sum(v*v for v in normal))
                result.append(tuple(v/length for v in normal) if length>1e-9 else normals[selected[i]])
            return result
        out_normals=fitted_normals(out_pos) if category=="Bottoms" else [normals[v] for v in selected]
        q={"attributes":{
            "POSITION":accessor(out_pos,"VEC3",5126,34962),
            "NORMAL":accessor(out_normals,"VEC3",5126,34962),
            "TEXCOORD_0":accessor([uv[v] for v in selected],"VEC2",5126,34962),
            "JOINTS_0":accessor(out_joints,"VEC4",5123,34962),
            "WEIGHTS_0":accessor(out_weights,"VEC4",5126,34962)},
            "indices":accessor([(remap[i],) for i in indexes],"SCALAR",5125,34963),
            "material":material(d,srcbuf,p["material"],name),"mode":4}
        add_mesh(name,q)
        if category=="Tops":
            # A continuous, monotonic mapping for the entire lower torso.
            # The skirt cut ends just below its waistband; the trousers
            # version retains the longer, original donor silhouette.
            low=min(v[1] for v in out_pos if abs(v[0]-hips[0])<.24)
            high=max(1.22,hoodie_hem+.18)
            ratio=(high-hoodie_hem)/(high-low)
            if not 0.25<ratio<=1.0:
                raise RuntimeError("Unexpected hoodie skirt hem mapping")
            def mapped_y(y):
                if y>=high:return y
                t=max(0.,(y-low)/(high-low))
                # Cubic Hermite with positive derivative; no foldback.
                m0=min(.2,ratio)
                m1=min(1.,3.*ratio-m0)
                return ((2*t**3-3*t*t+1)*hoodie_hem+(t**3-2*t*t+t)*(high-low)*m0
                        +(-2*t**3+3*t*t)*high+(t**3-t*t)*(high-low)*m1)
            prev=mapped_y(low)
            for i in range(1,101):
                value=mapped_y(low+(high-low)*i/100.)
                if value<=prev:raise RuntimeError("Nonmonotonic hoodie hem fit")
                prev=value
            skirt_hoodie=[]
            for x,y,z in out_pos:
                lateral=1.-smooth(.23,.34,abs(x-hips[0]))
                skirt_hoodie.append((x,y+(mapped_y(y)-y)*lateral,z))
            # Uniformly fit the whole hem ring to the widest overlapping
            # skirt section, not individual vertices (which caused spikes).
            required=1.
            count=0
            for x,y,z in skirt_hoodie:
                dx,dz=x-hips[0],z-hips[2]
                rad=math.hypot(dx,dz)
                if y>skirt_waist+.012 or y<hoodie_hem-.005 or rad<.035 or rad>.26:continue
                outer=section_radius(skirt_tri,y,dx/rad,dz/rad)
                if outer>0:
                    required=max(required,(outer+.018)/rad)
                    count+=1
            if count<8 or required>1.65:
                raise RuntimeError("Unexpected skirt hoodie hem envelope")
            ring_scale=max(1.06,required)
            for i,(x,y,z) in enumerate(skirt_hoodie):
                band=(1.-smooth(skirt_waist+.012,high,y))*(1.-smooth(.23,.34,abs(x-hips[0])))
                factor=1.+(ring_scale-1.)*band
                skirt_hoodie[i]=(hips[0]+(x-hips[0])*factor,y,hips[2]+(z-hips[2])*factor)
                # Uniform pelvis weighting across the complete overlap band,
                # taper gradually above it; no disjoint vertex selection.
                pin_waist(i,(1.-smooth(skirt_waist+.012,high,y))*(1.-smooth(.23,.34,abs(x-hips[0])))*.90)
            short=copy.deepcopy(q)
            short["attributes"]["POSITION"]=accessor(skirt_hoodie,"VEC3",5126,34962)
            short["attributes"]["NORMAL"]=accessor(fitted_normals(skirt_hoodie),"VEC3",5126,34962)
            short["attributes"]["JOINTS_0"]=accessor(out_joints,"VEC4",5123,34962)
            short["attributes"]["WEIGHTS_0"]=accessor(out_weights,"VEC4",5126,34962)
            mat=copy.deepcopy(doc["materials"][q["material"]])
            mat["name"]="WardrobeTopHoodieSkirt"
            short["material"]=len(doc["materials"])
            doc["materials"].append(mat)
            add_mesh("WardrobeTopHoodieSkirt",short)
            print("WARDROBE_MONOTONIC_HEM",low,hoodie_hem,high,"ring_scale",ring_scale,"sections",count)
        print("WARDROBE_GEOMETRY",name,len(selected),"vertices",len(indexes)//3,"triangles",
              "bounds",q["attributes"]["POSITION"],doc["accessors"][q["attributes"]["POSITION"]]["min"],doc["accessors"][q["attributes"]["POSITION"]]["max"])
    # Physically separate original skirt and body skin from the multi-
    # surface body, so visibility is node-level, not fragment discard.
    original=doc["meshes"][base["mesh"]]["primitives"]
    skin_prims=[v for v in original if "_Body_" in doc["materials"][v["material"]].get("name","") and "_SKIN" in doc["materials"][v["material"]].get("name","")]
    skirt_prim=garment(doc,base,"Bottoms")
    def split_original(name,prims):
        copied=copy.deepcopy(prims)
        for prim in copied:prim.pop("targets",None)
        add_mesh(name,copied)
    split_original("OriginalSkirt",[skirt_prim])
    split_original("OriginalSkin",skin_prims)
    doc["meshes"][base["mesh"]]["primitives"]=[v for v in original if v not in skin_prims and v is not skirt_prim]
    # Three coverage masks: trousers, hoodie with skirt, and both. Hide
    # only covered triangles; keep head/neck, hands and exposed lower leg.
    # The physical body underneath is never reshaped or rescaled.
    waist=max(v[1] for v in pants_positions)-.010
    cuff=min(v[1] for v in pants_positions)+.025
    neck_y=target_rest[target_joint[target_human["neck"]]][13]
    hand_x=min(abs(target_rest[target_joint[target_human[side+"Hand"]]][12]-hips[0]) for side in ("left","right"))
    arm_joints={target_joint[target_human[side+k]] for side in ("left","right") for k in ("UpperArm","LowerArm","Shoulder")}
    for mask,pants,hood in [("Trousers",True,False),("Hoodie",False,True),("Both",True,True)]:
        kept_primitives=[]
        removed=retained=0
        hood_bottom=(min(v[1] for v in hoodie_positions if abs(v[0]-hips[0])<.24)+.035) if pants else hoodie_hem+.020
        for prim in skin_prims:
            mat=doc["materials"][prim["material"]]
            attrs=prim["attributes"]
            pos=read(doc,buf,attrs["POSITION"])
            joints=read(doc,buf,attrs["JOINTS_0"])
            weights=read(doc,buf,attrs["WEIGHTS_0"])
            ids=[v[0] for v in read(doc,buf,prim["indices"])]
            kept=[]
            for i in range(0,len(ids),3):
                tri=ids[i:i+3]
                center=[sum(pos[k][j] for k in tri)/3. for j in range(3)]
                x,y,z=center
                covered=pants and cuff<y<waist and abs(x-hips[0])<.30
                if hood:
                    arm=sum(w for k in tri for j,w in zip(joints[k],weights[k]) if j in arm_joints)/3.
                    torso=hood_bottom<y<neck_y-.035 and abs(x-hips[0])<.24
                    sleeve=arm>.60 and abs(x-hips[0])<hand_x-.025 and y>hood_bottom
                    covered=covered or torso or sleeve
                if covered:removed+=1
                else:
                    kept.extend(tri)
                    retained+=1
            if not kept:continue
            q=copy.deepcopy(prim)
            q.pop("targets",None)
            q["indices"]=accessor([(i,) for i in kept],"SCALAR",5125,34963)
            skinmat=copy.deepcopy(mat)
            skinmat["name"]="WardrobeBody"+mask+"Skin"+str(len(kept_primitives))
            q["material"]=len(doc["materials"])
            doc["materials"].append(skinmat)
            kept_primitives.append(q)
        if removed<100 or retained<100 or not kept_primitives:
            raise RuntimeError("Invalid coverage mask "+mask)
        add_mesh("WardrobeBody"+mask,kept_primitives)
        print("WARDROBE_BODY_MASK",mask,"removed",removed,"retained",retained,"waist",waist,"hood_bottom",hood_bottom)
    buf.extend(b"\0"*((-len(buf))%4))
    doc["buffers"][0]["byteLength"]=len(buf)
    return struct.pack("<II",len(buf),0x004E4942)+buf
