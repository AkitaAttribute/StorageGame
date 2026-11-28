"""Bake modular garments onto Shino's existing glTF skin at asset-build time."""
import copy
import hashlib
import json
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
        doc["meshes"].append({"name":name,"primitives":[prim]})
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
    for category,name in [("Tops","WardrobeTopHoodie"),("Bottoms","WardrobeBottomTrousers")]:
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
                local=(local[0]*0.90,local[1],local[2]*0.90)
                fitted=point(target_rest[k],local)
                for a in range(3):result[a]+=fitted[a]*w
                total+=w
                combined[k]=combined.get(k,0.)+w
            if total<1e-6:raise RuntimeError("Unweighted garment vertex")
            pairs=sorted(combined.items(),key=lambda x:-x[1])[:4]
            norm=sum(w for _,w in pairs)
            out_pos.append(tuple(x/total for x in result))
            out_joints.append(tuple([j for j,w in pairs]+[0]*(4-len(pairs))))
            out_weights.append(tuple([w/norm for j,w in pairs]+[0.]*(4-len(pairs))))
        if len(selected)<100:raise RuntimeError("Garment geometry unexpectedly small")
        q={"attributes":{
            "POSITION":accessor(out_pos,"VEC3",5126,34962),
            "NORMAL":accessor([normals[v] for v in selected],"VEC3",5126,34962),
            "TEXCOORD_0":accessor([uv[v] for v in selected],"VEC2",5126,34962),
            "JOINTS_0":accessor(out_joints,"VEC4",5123,34962),
            "WEIGHTS_0":accessor(out_weights,"VEC4",5126,34962)},
            "indices":accessor([(remap[i],) for i in indexes],"SCALAR",5125,34963),
            "material":material(d,srcbuf,p["material"],name),"mode":4}
        add_mesh(name,q)
        print("WARDROBE_GEOMETRY",name,len(selected),"vertices",len(indexes)//3,"triangles",
              "bounds",q["attributes"]["POSITION"],doc["accessors"][q["attributes"]["POSITION"]]["min"],doc["accessors"][q["attributes"]["POSITION"]]["max"])
    buf.extend(b"\0"*((-len(buf))%4))
    doc["buffers"][0]["byteLength"]=len(buf)
    return struct.pack("<II",len(buf),0x004E4942)+buf
