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
    "facility.glb": ("https://cdn.3dassets.dev/assets/34733/v1/model.glb", 897836, None),
    "unit.glb": ("https://cdn.3dassets.dev/assets/34694/v1/model.glb", 26452, None),
    "shino.glb": ("https://raw.githubusercontent.com/madjin/vrm-samples/e16eb187100149a315ad92c3c9968f1d5baa6c7d/vroid/beta/Sendagaya_Shino.vrm", 15074328, "91f7c9e9ec990efb9de305e4c1d0e32a46498830"),
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
        remove_vrm(doc)
        payload = json.dumps(doc, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        payload += b" " * ((-len(payload)) % 4)
        rest = data[20 + length:]
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
