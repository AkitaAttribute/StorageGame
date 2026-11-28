import urllib.request,json,struct
base="https://raw.githubusercontent.com/madjin/vrm-samples/e16eb187100149a315ad92c3c9968f1d5baa6c7d/vroid/beta/"
for name in ["Sendagaya_Shino.vrm","Sendagaya_Shibu.vrm","HairSample_Male.vrm","Sakurada_Fumiriya.vrm","Victoria_Rubin.vrm","Vivi.vrm","clothes/tshirt_tpose.glb","clothes/longsleeve_tpose.glb"]:
    req=urllib.request.Request(base+name,headers={"User-Agent":"StorageGame"})
    data=urllib.request.urlopen(req,timeout=90).read()
    d=json.loads(data[20:20+struct.unpack_from("<I",data,12)[0]])
    v=d.get("extensions",{}).get("VRM",{})
    print("ASSET",name,"LICENSE",v.get("meta",{}).get("licenseName"))
    human={j["bone"]:d["nodes"][j["node"]].get("translation",[0,0,0]) for j in v.get("humanoid",{}).get("humanBones",[]) if j["bone"] in ["hips","leftUpperArm","leftLowerArm","leftUpperLeg","leftLowerLeg","leftFoot"]}
    print("HUMAN",human)
    for node in d["nodes"]:
        if "mesh" not in node:continue
        mesh=d["meshes"][node["mesh"]]
        for p in mesh["primitives"]:
            a=d["accessors"][p["attributes"]["POSITION"]]
            mat=d.get("materials",[])[p["material"]].get("name","") if "material" in p else ""
            print("PRIMITIVE",node.get("name"),node.get("skin"),mat,a["count"],a.get("min"),a.get("max"))
