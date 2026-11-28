"""Fetch the CC0 model files prior to Godot import; no credentials required."""
import hashlib
import json
import pathlib
import struct
import shutil
import subprocess
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
ASSETS = ROOT / "assets"
ASSETS.mkdir(exist_ok=True)
CACHE = ROOT / ".asset-cache"
CACHE.mkdir(exist_ok=True)
(CACHE / ".gdignore").touch()
MODELS = {
    "prop_fridge.glb": ("https://raw.githubusercontent.com/trebeljahr/quaternius-showcase/0128ca510d653bb04d6d1e4885bd8890b5050b4f/public/glb/house_interior_pack/Kitchen_Fridge.glb", 17360, "b9fb5c84c574c12b307911ccac567a5369731560"),
    "prop_boombox.glb": ("https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Assets/e124e8d8d7330a5372bc2b4d00d39a4a9d7997ea/Models/BoomBox/glTF-Binary/BoomBox.glb", 10614184, "8d46a04283be023e3dd5154a4a8d65a68abf597c"),
    "facility.glb": ("https://cdn.3dassets.dev/assets/34733/v1/model.glb", 897836, None),
    "unit.glb": ("https://cdn.3dassets.dev/assets/34694/v1/model.glb", 26452, None),
    "shino.glb": ("https://raw.githubusercontent.com/madjin/vrm-samples/e16eb187100149a315ad92c3c9968f1d5baa6c7d/vroid/beta/Sendagaya_Shino.vrm", 15074328, "91f7c9e9ec990efb9de305e4c1d0e32a46498830"),
    "directional_walk.glb": ("https://raw.githubusercontent.com/tilakpatell/tilakverse-assets/85064399bbdacc0e8cc50807179490314bc4ff1c/quaternius/universal-animation-library-2/Unreal-Godot/UAL2.glb", 20717364, "e6add803561a0491cd0b8db8b1dc75dc77b3bee1"),
    "locomotion.glb": ("https://raw.githubusercontent.com/call-me-sensei-app/toonlab/2e354c52e5539e33fb3d8f339645b47e1ac937ca/public/characters/mannequin.glb", 6670948, "82ee8dd0bf8007d40572e74c5c70bd4c65cc484d"),
}
for filename, (url, size, git_sha) in MODELS.items():
    path = CACHE / filename
    def valid(data):
        return (len(data) == size and data[:4] == b"glTF" and
                (git_sha is None or hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest() == git_sha))
    if not path.exists() or not valid(path.read_bytes()):
        request = urllib.request.Request(url, headers={"User-Agent": "StorageGame asset bootstrap"})
        with urllib.request.urlopen(request, timeout=90) as response:
            data = response.read(size + 1)
        if not valid(data):
            raise RuntimeError(f"Unexpected asset contents: {filename}")
        temp = path.with_suffix(".tmp")
        temp.write_bytes(data)
        temp.replace(path)
    data = path.read_bytes()
    length, kind = struct.unpack_from("<II", data, 12)
    if kind != 0x4E4F534A:
        raise RuntimeError(f"No GLB JSON chunk: {filename}")
    doc = json.loads(data[20:20+length])
    names = [a.get("name", "") for a in doc.get("animations", [])]
    if filename == "unit.glb" and not {"open", "close"}.issubset(names):
        raise RuntimeError("Unit door animations missing")
    if filename == "locomotion.glb" and (not doc.get("skins") or not any("walk" in n.lower() for n in names)):
        raise RuntimeError("Player rig or walk animation missing")
    print(filename, len(data), "animations:", names)

    target = ASSETS / filename
    if filename == "directional_walk.glb":
        # Keep the authored eight-direction in-place walk cycles only.
        required = {"walk_fwd_loop", "walk_bwd_loop", "walk_l_loop", "walk_r_loop",
                    "walk_fwd_l_loop", "walk_fwd_r_loop", "walk_bwd_l_loop", "walk_bwd_r_loop"}
        doc["animations"] = [clip for clip in doc["animations"] if clip.get("name", "").lower().split("|")[-1] in required]
        actual = {clip.get("name", "").lower().split("|")[-1] for clip in doc["animations"]}
        if actual != required:
            raise RuntimeError("Directional locomotion clips missing: " + str(required - actual))
        for clip in doc["animations"]:
            clip["name"] = clip["name"].split("|")[-1]
        payload = json.dumps(doc, separators=(",", ":")).encode("utf-8")
        payload += b" " * ((-len(payload)) % 4)
        rest = data[20 + length:]
        intermediate = CACHE / "directional_walk_selected.glb"
        intermediate.write_bytes(struct.pack("<4sIIII", b"glTF", 2, 20 + len(payload) + len(rest), len(payload), 0x4E4F534A) + payload + rest)
        npx = shutil.which("npx.cmd" if __import__("os").name == "nt" else "npx")
        if not npx:
            raise RuntimeError("npx is required to prune unused animation data")
        subprocess.run([npx, "--yes", "@gltf-transform/cli@4.5.1", "prune", str(intermediate), str(target)], check=True)
        print("DIRECTIONAL_CLIPS", sorted(actual), "bytes:", target.stat().st_size)
        continue
    if filename == "shino.glb":
        # VRM 0.x is a GLB container. Preserve the skin, textures, morphs and
        # fallback glTF materials; turn the explicit humanoid map into stable
        # joint names for Godot. VRM-only spring bones/MToon are not required
        # for this first locomotion test.
        vrm = doc.get("extensions", {}).get("VRM", {})
        human = vrm.get("humanoid", {}).get("humanBones", [])
        if not human or not doc.get("skins"):
            raise RuntimeError("Shino has no VRM humanoid rig")
        for item in human:
            doc["nodes"][item["node"]]["name"] = "VRM_" + item["bone"]
        # Preserve the source model's secondary-motion chain identities in
        # ordinary glTF bone names. No runtime VRM extension parser required.
        nodes = doc["nodes"]
        human_ids = {item["node"] for item in human}
        joints = {joint for skin in doc["skins"] for joint in skin["joints"]}
        head = next(item["node"] for item in human if item["bone"] == "head")
        def descendants(node):
            yield node
            for child in nodes[node].get("children", []):
                yield from descendants(child)
        head_children = set(descendants(head))
        tagged = {}
        for group in vrm.get("secondaryAnimation", {}).get("boneGroups", []):
            for root in group.get("bones", []):
                name = nodes[root].get("name", "").lower()
                kind = "HAIR" if ("hair" in name or root in head_children) else "SKIRT" if ("skirt" in name or "bottom" in name) else ""
                if kind:
                    for idx in descendants(root):
                        if idx in joints and idx not in human_ids:
                            tagged[idx] = kind
        for idx in joints - human_ids:
            name = nodes[idx].get("name", "").lower()
            if "hair" in name:
                tagged[idx] = "HAIR"
            elif "skirt" in name:
                tagged[idx] = "SKIRT"
        for idx, kind in tagged.items():
            nodes[idx]["name"] = "SEC_" + kind + "_" + str(idx)
        print("SHINO_SECONDARY", {kind: sum(v == kind for v in tagged.values()) for kind in ("HAIR", "SKIRT")})
        def remove_vrm(value):
            if isinstance(value, dict):
                if "extensions" in value:
                    value["extensions"].pop("VRM", None)
                    if not value["extensions"]:
                        del value["extensions"]
                for key in ("extensionsUsed", "extensionsRequired"):
                    if key in value:
                        value[key] = [v for v in value[key] if v != "VRM"]
                for child in list(value.values()):
                    remove_vrm(child)
            elif isinstance(value, list):
                for child in value:
                    remove_vrm(child)
        from wardrobe_assets import add_wardrobe
        wardrobe_bin = add_wardrobe(doc, data[28 + length:], CACHE)
        remove_vrm(doc)
        payload = json.dumps(doc, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        payload += b" " * ((-len(payload)) % 4)
        rest = wardrobe_bin
        target.write_bytes(struct.pack("<4sIIII", b"glTF", 2, 20 + len(payload) + len(rest), len(payload), 0x4E4F534A) + payload + rest)
        print("Shino humanoid bones:", [item["bone"] for item in human])
        continue
    if filename == "locomotion.glb":
        print("Locomotion skin joint names:", [[doc["nodes"][i].get("name") for i in skin["joints"]] for skin in doc["skins"]])
    if "KHR_mesh_quantization" in doc.get("extensionsUsed", []) or "KHR_mesh_quantization" in doc.get("extensionsRequired", []):
        npx = shutil.which("npx.cmd" if __import__("os").name == "nt" else "npx")
        if not npx:
            raise RuntimeError("Node.js and npx are required to convert the facility models for Godot.")
        temp = ASSETS / (filename + ".converted.glb")
        subprocess.run([npx, "--yes", "@gltf-transform/cli@4.5.1", "dequantize", str(path), str(temp)], check=True)
        converted = temp.read_bytes()
        length, kind = struct.unpack_from("<II", converted, 12)
        converted_doc = json.loads(converted[20:20+length])
        if kind != 0x4E4F534A or "KHR_mesh_quantization" in converted_doc.get("extensionsRequired", []) or "KHR_mesh_quantization" in converted_doc.get("extensionsUsed", []):
            raise RuntimeError(f"Conversion did not remove mesh quantization: {filename}")
        converted_names = {a.get("name", "") for a in converted_doc.get("animations", [])}
        if not set(names).issubset(converted_names):
            raise RuntimeError(f"Conversion lost animations: {filename}")
        temp.replace(target)
        print("Godot-compatible model:", target.name, len(converted))
    else:
        shutil.copyfile(path, target)

# Poly Haven publishes glTF with external texture/buffer dependencies.
# Fetch its documented 1K asset set and bundle it as a self-contained GLB.
# Verify the source-provided hashes and size of every downloaded dependency.
import urllib.parse

def get_bytes(url):
    req = urllib.request.Request(url, headers={"User-Agent": "StorageGame asset bootstrap (AkitaAttribute/StorageGame)"})
    with urllib.request.urlopen(req, timeout=90) as response:
        return response.read()

def poly_file(info):
    content = get_bytes(info["url"])
    if info.get("size") is not None and len(content) != int(info["size"]):
        raise RuntimeError("Poly Haven size verification failed: " + info["url"])
    if info.get("md5") and hashlib.md5(content).hexdigest() != info["md5"].lower():
        raise RuntimeError("Poly Haven checksum verification failed: " + info["url"])
    return content

def fetch_poly_model(asset_id, output):
    listing = json.loads(get_bytes("https://api.polyhaven.com/files/" + asset_id))
    info = listing["gltf"]["1k"]["gltf"]
    folder = CACHE / ("polyhaven_" + asset_id)
    folder.mkdir(exist_ok=True)
    source = folder / (asset_id + "_1k.gltf")
    source.write_bytes(poly_file(info))
    for name, dep in info.get("include", {}).items():
        dest = (folder / name).resolve()
        if not dest.is_relative_to(folder.resolve()):
            raise RuntimeError("Invalid asset dependency path")
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(poly_file(dep))
    npx = shutil.which("npx.cmd" if __import__("os").name == "nt" else "npx")
    if not npx:
        raise RuntimeError("Node.js and npx are required to bundle textured models")
    target = ASSETS / output
    subprocess.run([npx, "--yes", "@gltf-transform/cli@4.5.1", "copy", str(source), str(target)], check=True)
    raw = target.read_bytes()
    length, kind = struct.unpack_from("<II", raw, 12)
    doc = json.loads(raw[20:20+length])
    if kind != 0x4E4F534A or not doc.get("meshes") or not doc.get("textures"):
        raise RuntimeError("Expected textured mesh: " + asset_id)
    if "KHR_mesh_quantization" in doc.get("extensionsUsed", []) or "KHR_mesh_quantization" in doc.get("extensionsRequired", []):
        temp = folder / "dequantized.glb"
        subprocess.run([npx, "--yes", "@gltf-transform/cli@4.5.1", "dequantize", str(target), str(temp)], check=True)
        shutil.copyfile(temp, target)
    print("Poly Haven textured asset:", asset_id, target.stat().st_size)

fetch_poly_model("metal_office_desk", "prop_desk.glb")
fetch_poly_model("flathead_screwdriver", "prop_screwdriver.glb")
