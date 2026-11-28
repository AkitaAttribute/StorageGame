extends RefCounted
## Separate slots, stable item IDs, and one shared animated skeleton.
const CATALOG := {
    "top": [{"id":"original","label":"Original uniform"},{"id":"uniform","label":"Shibu uniform"},{"id":"hoodie","label":"Casual hoodie"}],
    "bottom": [{"id":"original","label":"Original skirt"},{"id":"uniform","label":"Shibu skirt"},{"id":"trousers","label":"Casual trousers"}],
}
const FUTURE_SLOTS := ["arm","hand","face","leg","feet"]
var selected: Dictionary = {"top":"original","bottom":"original"}
var variants: Dictionary = {}
var originals: Dictionary = {"top": [], "bottom": [], "neck": [], "skin": []}
var trouser_body: MeshInstance3D
var hoodie_body: MeshInstance3D
var both_body: MeshInstance3D
var hoodie_skirt: MeshInstance3D
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
            if name.contains("wardrobetophoodieskirt"):
                hoodie_skirt = mesh_node
                mesh_node.hide()
                continue
            if name.contains("wardrobebodyhoodieskin"):
                hoodie_body = mesh_node
                mesh_node.hide()
                continue
            if name.contains("wardrobebodybothskin"):
                both_body = mesh_node
                mesh_node.hide()
                continue
            if name.contains("wardrobebodytrousersskin"):
                trouser_body = mesh_node
                mesh_node.hide()
                continue
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
            elif name.contains("_body_") and name.contains("_skin"):
                slot = "skin"
            if not slot.is_empty():
                originals[slot].append({"node":mesh_node,"index":i})
    ready = variants.size()==4 and is_instance_valid(hoodie_skirt) and is_instance_valid(hoodie_body) and is_instance_valid(both_body) and is_instance_valid(trouser_body) and not originals["skin"].is_empty() and not originals["top"].is_empty() and not originals["bottom"].is_empty()
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
        if str(node.name).to_lower().begins_with("originalskirt") or str(node.name).to_lower().begins_with("originalskin"):
            node.visible = visible
        else:
            node.set_surface_override_material(int(entry["index"]),null if visible else hidden_material)

func original_visible(entry: Dictionary) -> bool:
    var node: MeshInstance3D = entry["node"]
    if str(node.name).to_lower().begins_with("originalskirt") or str(node.name).to_lower().begins_with("originalskin"):
        return node.visible
    return node.get_surface_override_material(int(entry["index"])) == null

func apply() -> void:
    var pants: bool = selected["bottom"] == "trousers"
    var hood: bool = selected["top"] == "hoodie"
    for key in variants:
        var node: MeshInstance3D = variants[key]
        node.visible = (key == "top"+str(selected["top"]) or key == "bottom"+str(selected["bottom"])) and (key != "tophoodie" or pants)
    show_original("top",selected["top"]=="original")
    show_original("bottom",selected["bottom"]=="original")
    show_original("neck",selected["top"]!="hoodie")
    show_original("skin",not pants and not hood)
    if is_instance_valid(trouser_body):
        trouser_body.visible = pants and not hood
    if is_instance_valid(hoodie_body):
        hoodie_body.visible = hood and not pants
    if is_instance_valid(both_body):
        both_body.visible = hood and pants
    if is_instance_valid(hoodie_skirt):
        hoodie_skirt.visible = hood and not pants

func consistent() -> bool:
    var pants: bool = selected["bottom"] == "trousers"
    var hood: bool = selected["top"] == "hoodie"
    if not ready or trouser_body.visible != (pants and not hood) or hoodie_body.visible != (hood and not pants) or both_body.visible != (hood and pants) or hoodie_skirt.visible != (hood and not pants):
        return false
    for entry in originals["skin"]:
        if original_visible(entry) != (not pants and not hood):
            return false
    for key in variants:
        var node: MeshInstance3D = variants[key]
        var expected: bool = (key == "top"+str(selected["top"]) or key == "bottom"+str(selected["bottom"])) and (key != "tophoodie" or pants)
        if node.visible != expected:
            return false
    for slot in ["top","bottom"]:
        for entry in originals[slot]:
            if original_visible(entry) != (selected[slot]=="original"):
                return false
    return true
