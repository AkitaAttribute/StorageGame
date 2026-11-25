"""Fetch the CC0 model files prior to Godot import; no credentials required."""
import hashlib
import json
import pathlib
import struct
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
ASSETS = ROOT / "assets"
ASSETS.mkdir(exist_ok=True)
MODELS = {
    "facility.glb": ("https://cdn.3dassets.dev/assets/34733/v1/model.glb", 897836, None),
    "unit.glb": ("https://cdn.3dassets.dev/assets/34694/v1/model.glb", 26452, None),
    "player.glb": ("https://raw.githubusercontent.com/KayKit-Game-Assets/KayKit-Character-Pack-Adventures-1.0/672074b73ba276876a19e8816ecdc5241817ab47/addons/kaykit_character_pack_adventures/Characters/gltf/Rogue.glb", 3616284, "c8827661105eef7b2bfbef3bc676d41a47625733"),
}
for filename, (url, size, git_sha) in MODELS.items():
    path = ASSETS / filename
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
    if filename == "player.glb" and (not doc.get("skins") or not any("walk" in n.lower() for n in names)):
        raise RuntimeError("Player rig or walk animation missing")
    print(filename, len(data), "animations:", names)
