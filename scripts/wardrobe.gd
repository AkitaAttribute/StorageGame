extends RefCounted
## Separate slots, stable item IDs, and one shared animated skeleton.
const CATALOG := {
    "top": [{"id":"original","label":"Original uniform"},{"id":"uniform","label":"Shibu uniform"},{"id":"hoodie","label":"Casual hoodie"}],
    "bottom": [{"id":"original","label":"Original skirt"},{"id":"uniform","label":"Shibu skirt"},{"id":"trousers","label":"Casual trousers"}],
}
const FUTURE_SLOTS := ["arm","hand","face","leg","feet"]
var selected: Dictionary = {"top":"original","bottom":"original"}
var variants: Dictionary = {}
var originals: Dictionary = {"top": [], "bottom": [], "neck": []}
var hidden_material: ShaderMaterial
var ready := false

func setup(avatar: Node3D) -> void:
    var shader := Shader.new()
    shader.code = "shader_type spatial; render_mode shadows_disabled; void fragment() { discard; }"
    hidden_material = ShaderMaterial.new()
    hidden_material.shader = shader
    for node in avatar.find_children("*","MeshInstance3D",true,false):
        var mesh_node := node as MeshInstance3D
        if mesh_node.mesh == null:
            continue
        for i in range(mesh_node.mesh.get_surface_count()):
            var mat := mesh_node.mesh.surface_get_material(i)
            if mat == null:
                continue
            var name := mat.resource_name.to_lower()
            var variant := ""
            for key in ["topuniform","tophoodie","bottomuniform","bottomtrousers"]:
                if name.contains("wardrobe"+key):
                    variant = key
                    break
            if not variant.is_empty():
                variants[variant] = mesh_node
                mesh_node.hide()
                continue
            var slot := ""
            if name.contains("_tops_"):
                slot = "top"
            elif name.contains("_bottoms_"):
                slot = "bottom"
            elif name.contains("_accessoryneck_"):
                slot = "neck"
            if not slot.is_empty():
                originals[slot].append({"node":mesh_node,"index":i})
    ready = variants.size()==4 and not originals["top"].is_empty() and not originals["bottom"].is_empty()
    print("WARDROBE_READY ",ready," variants=",variants.keys()," originals=",originals.keys())
    apply()

func valid(slot: String, id: String) -> bool:
    if not CATALOG.has(slot):
        return false
    for item in CATALOG[slot]:
        if item["id"] == id:
            return id == "original" or variants.has(slot+id)
    return false

func restore(data: Variant) -> void:
    for slot in CATALOG:
        var id := str(data.get(slot,"original")) if data is Dictionary else "original"
        selected[slot] = id if valid(slot,id) else "original"
    apply()

func choose(slot: String,id: String) -> bool:
    if not ready or not valid(slot,id):
        return false
    selected[slot] = id
    apply()
    return true

func show_original(slot: String, visible: bool) -> void:
    for entry in originals[slot]:
        var node: MeshInstance3D = entry["node"]
        node.set_surface_override_material(int(entry["index"]),null if visible else hidden_material)

func apply() -> void:
    for key in variants:
        var node: MeshInstance3D = variants[key]
        node.visible = key == "top"+str(selected["top"]) or key == "bottom"+str(selected["bottom"])
    show_original("top",selected["top"]=="original")
    show_original("bottom",selected["bottom"]=="original")
    show_original("neck",selected["top"]!="hoodie")

func consistent() -> bool:
    for key in variants:
        var node: MeshInstance3D = variants[key]
        if node.visible != (key == "top"+str(selected["top"]) or key == "bottom"+str(selected["bottom"])):
            return false
    for slot in ["top","bottom"]:
        for entry in originals[slot]:
            var node: MeshInstance3D = entry["node"]
            if (node.get_surface_override_material(int(entry["index"])) == null) != (selected[slot]=="original"):
                return false
    return true
