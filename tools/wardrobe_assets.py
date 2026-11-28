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
    pants_waist=shirt_hem+.045
    hoodie_hem=skirt_waist-.018
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
                    local=(local[0]*0.90,local[1],local[2]*0.90)
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
            # Shorten only torso-weighted hem, leaving sleeves and upper
            # hoodie intact. The hem rests OVER the upper skirt/waistband.
            torso_joint={target_joint[target_human[k]] for k in ("hips","spine","chest","upperChest","neck") if k in target_human}
            torso_ids=[i for i,v in enumerate(out_pos) if abs(v[0]-hips[0])<.24 and sum(w for j,w in zip(out_joints[i],out_weights[i]) if j in torso_joint)>.55]
            old_hem=min(out_pos[i][1] for i in torso_ids)
            for i in torso_ids:
                x,y,z=out_pos[i]
                amount=1.-smooth(old_hem,old_hem+.22,y)
                y+=max(0.,hoodie_hem-old_hem)*amount
                dx,dz=x-hips[0],z-hips[2]
                radius=math.hypot(dx,dz)
                if radius>1e-6 and y<max(skirt_waist,pants_waist)+.06:
                    # The same top can fit over either bottom. Use the
                    # larger local section only at the actual hem overlap.
                    outer=max(section_radius(skirt_tri,y,dx/radius,dz/radius),
                              section_radius(pants_tri,y,dx/radius,dz/radius))
                    if outer>0:
                        new_radius=max(radius,outer+.014)
                        x,z=hips[0]+dx/radius*new_radius,hips[2]+dz/radius*new_radius
                    pin_waist(i,(1.-smooth(hoodie_hem,hoodie_hem+.13,y))*.85)
                out_pos[i]=(x,y,z)
            print("WARDROBE_HOODIE_HEM",old_hem,"->",min(out_pos[i][1] for i in torso_ids))
        # Validate actual fitted seam samples, rather than just the mesh
        # visibility flags. Only compare cross sections where both layers exist.
        tests=0
        bad=0
        min_gap=1.
        for i,(x,y,z) in enumerate(out_pos):
            dx,dz=x-hips[0],z-hips[2]
            radius=math.hypot(dx,dz)
            if radius<.025 or radius>.25:continue
            if category=="Bottoms" and y>=shirt_hem+.014:
                outer=section_radius(top_tri,y,dx/radius,dz/radius)
                gap=outer-radius
            elif category=="Tops" and i in torso_ids and y<=max(skirt_waist,pants_waist):
                outer=max(section_radius(skirt_tri,y,dx/radius,dz/radius),
                          section_radius(pants_tri,y,dx/radius,dz/radius))
                gap=radius-outer
            else:continue
            if outer<=0:continue
            tests+=1
            min_gap=min(min_gap,gap)
            bad+=gap<.004
        print("WARDROBE_LAYER_CHECK",name,"samples",tests,"bad",bad,"min_gap",min_gap)
        if tests<8 or bad:
            raise RuntimeError("Garment seam clearance failed: "+name)
        # Recalculate normals after the seam deformation; preserve smoothing
        # across coincident UV seam vertices by sharing their normal sum.
        sums={}
        for i in range(0,len(indexes),3):
            ids=[remap[k] for k in indexes[i:i+3]]
            a,b,c=[out_pos[k] for k in ids]
            ab=[b[j]-a[j] for j in range(3)]
            ac=[c[j]-a[j] for j in range(3)]
            normal=(ab[1]*ac[2]-ab[2]*ac[1],ab[2]*ac[0]-ab[0]*ac[2],ab[0]*ac[1]-ab[1]*ac[0])
            for k in ids:
                key=tuple(round(v,6) for v in out_pos[k])
                total=sums.setdefault(key,[0.,0.,0.])
                for j in range(3):total[j]+=normal[j]
        out_normals=[]
        for i,v in enumerate(out_pos):
            normal=sums[tuple(round(k,6) for k in v)]
            length=math.sqrt(sum(k*k for k in normal))
            out_normals.append(tuple(k/length for k in normal) if length>1e-9 else normals[selected[i]])
        q={"attributes":{
            "POSITION":accessor(out_pos,"VEC3",5126,34962),
            "NORMAL":accessor(out_normals,"VEC3",5126,34962),
            "TEXCOORD_0":accessor([uv[v] for v in selected],"VEC2",5126,34962),
            "JOINTS_0":accessor(out_joints,"VEC4",5123,34962),
            "WEIGHTS_0":accessor(out_weights,"VEC4",5126,34962)},
            "indices":accessor([(remap[i],) for i in indexes],"SCALAR",5125,34963),
            "material":material(d,srcbuf,p["material"],name),"mode":4}
        add_mesh(name,q)
        print("WARDROBE_GEOMETRY",name,len(selected),"vertices",len(indexes)//3,"triangles",
              "bounds",q["attributes"]["POSITION"],doc["accessors"][q["attributes"]["POSITION"]]["min"],doc["accessors"][q["attributes"]["POSITION"]]["max"])
    # Opaque trousers cover the original underwear/legs. Do not alter the
    # avatar skeleton or shrink its skin. Build an indexed skin substitute
    # with only the covered triangles removed; keep torso, hands and feet.
    # The cutoff comes from the fitted garment, not the source male body.
    waist=max(v[1] for v in pants_positions)-.020
    cuff=min(v[1] for v in pants_positions)+.025
    kept_primitives=[]
    removed=0
    retained=0
    for prim in doc["meshes"][base["mesh"]]["primitives"]:
        mat=doc["materials"][prim["material"]]
        if "_Body_" not in mat.get("name","") or "_SKIN" not in mat.get("name",""):
            continue
        pos=read(doc,buf,prim["attributes"]["POSITION"])
        ids=[v[0] for v in read(doc,buf,prim["indices"])]
        kept=[]
        for i in range(0,len(ids),3):
            tri=ids[i:i+3]
            center=[sum(pos[k][j] for k in tri)/3. for j in range(3)]
            # A small transition overlap hides the seam underneath the waist
            # and shoes. The rest of the body keeps its original vertices.
            if cuff < center[1] < waist and abs(center[0]) < .30:
                removed+=1
            else:
                kept.extend(tri)
                retained+=1
        if not kept:continue
        q=copy.deepcopy(prim)
        q.pop("targets",None)
        q["indices"]=accessor([(i,) for i in kept],"SCALAR",5125,34963)
        skinmat=copy.deepcopy(mat)
        skinmat["name"]="WardrobeBodyTrousersSkin"+str(len(kept_primitives))
        q["material"]=len(doc["materials"])
        doc["materials"].append(skinmat)
        kept_primitives.append(q)
    if removed<100 or retained<100 or not kept_primitives:
        raise RuntimeError("Trouser body coverage mask invalid")
    add_mesh("WardrobeBodyTrousers",kept_primitives)
    print("WARDROBE_TROUSER_MASK", "removed",removed,"retained",retained,"waist",waist,"cuff",cuff)
    buf.extend(b"\0"*((-len(buf))%4))
    doc["buffers"][0]["byteLength"]=len(buf)
    return struct.pack("<II",len(buf),0x004E4942)+buf
