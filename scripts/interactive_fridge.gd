extends Node3D
## Original refrigerator geometry: an open cabinet, two compartments,
## independently hinged doors, and a compound collider on the parent body.
const Panel = preload("res://scripts/hinged_panel.gd")
var panels: Array[Panel] = []
var body: RigidBody3D

func material(color: Color, metallic: float, roughness: float) -> StandardMaterial3D:
    var mat := StandardMaterial3D.new()
    mat.albedo_color = color
    mat.metallic = metallic
    mat.roughness = roughness
    return mat

func part(parent: Node3D, label: String, center: Vector3, size: Vector3, mat: Material, solid: bool = false) -> MeshInstance3D:
    var mesh := BoxMesh.new()
    mesh.size = size
    var node := MeshInstance3D.new()
    node.name = label
    node.mesh = mesh
    node.material_override = mat
    parent.add_child(node)
    node.position = center
    if solid:
        var col := CollisionShape3D.new()
        var shape := BoxShape3D.new()
        shape.size = size
        col.shape = shape
        body.add_child(col)
        col.transform = body.global_transform.affine_inverse() * node.global_transform
    return node

func build(owner_body: RigidBody3D, size: Vector3) -> void:
    body = owner_body
    var steel := material(Color(0.88, 0.90, 0.91), 0.22, 0.39)
    var liner := material(Color(0.93, 0.96, 0.98), 0.0, 0.58)
    var shelf := material(Color(0.65, 0.80, 0.84), 0.1, 0.38)
    var dark := material(Color(0.09, 0.11, 0.13), 0.15, 0.43)
    var handle := material(Color(0.48, 0.52, 0.56), 0.75, 0.30)
    var w := size.x
    var h := size.y
    var d := size.z
    var t := 0.045
    var door_depth := 0.065
    var front := d * 0.5 - door_depth
    var rear := -d * 0.5
    var cabinet_depth := front - rear
    var cz := (front + rear) * 0.5
    var bottom := -h * 0.5
    var top := h * 0.5
    var split := bottom + h * 0.67
    # Separate panels leave both compartments genuinely hollow.
    for side in [-1.0, 1.0]:
        part(self, "Side", Vector3(side * (w - t) * 0.5, 0, cz), Vector3(t, h, cabinet_depth), steel, true)
        part(self, "InnerLiner", Vector3(side * (w * 0.5 - t - 0.004), 0, cz), Vector3(0.008, h - 2.0 * t, cabinet_depth - 0.02), liner)
    part(self, "Back", Vector3(0, 0, rear + t * 0.5), Vector3(w - 2.0 * t, h, t), liner, true)
    part(self, "Top", Vector3(0, top - t * 0.5, cz), Vector3(w - 2.0 * t, t, cabinet_depth), steel, true)
    part(self, "Base", Vector3(0, bottom + t * 0.5, cz), Vector3(w - 2.0 * t, t, cabinet_depth), steel, true)
    part(self, "Divider", Vector3(0, split, cz), Vector3(w - 2.0 * t, t, cabinet_depth), liner, true)
    for fraction in [0.24, 0.49]:
        part(self, "Shelf", Vector3(0, bottom + h * fraction, cz - 0.015), Vector3(w - 2.0 * t - 0.008, 0.018, cabinet_depth - 0.075), shelf, true)
    part(self, "FreezerShelf", Vector3(0, split + (top - split) * 0.48, cz - 0.015), Vector3(w - 2.0 * t - 0.008, 0.018, cabinet_depth - 0.075), shelf, true)
    part(self, "LowerTrim", Vector3(0, bottom + 0.025, front - 0.004), Vector3(w - 0.02, 0.035, 0.012), dark)
    make_door("fridge", "fridge", bottom + 0.050, split - 0.012, w, d, door_depth, steel, liner, dark, handle)
    make_door("freezer", "freezer", split + 0.012, top - 0.008, w, d, door_depth, steel, liner, dark, handle)

func make_door(id: String, label: String, low: float, high: float, w: float, d: float, depth: float, steel: Material, liner: Material, dark: Material, handle: Material) -> void:
    var hinge := Panel.new()
    hinge.name = id.capitalize() + "Hinge"
    add_child(hinge)
    var width := w - 0.014
    var height := high - low
    # Right hinge; positive Y rotation swings the left edge toward +Z.
    var pivot := Vector3(w * 0.5 - 0.007, (low + high) * 0.5, d * 0.5 - depth * 0.5)
    var center := Vector3(-width * 0.5, 0, 0)
    hinge.configure(body, id, label, pivot, center, Vector3(width, height, depth), 1.0)
    part(hinge, "DoorSkin", center, Vector3(width, height, depth), steel)
    part(hinge, "InnerPanel", center + Vector3(0, 0, -depth * 0.5 - 0.004), Vector3(width - 0.045, height - 0.045, 0.008), liner)
    # Dark perimeter gasket, recessed slightly from the outer door face.
    for side in [-1.0, 1.0]:
        part(hinge, "GasketVertical", center + Vector3(side * (width * 0.5 - 0.019), 0, -depth * 0.5 - 0.006), Vector3(0.014, height - 0.02, 0.012), dark)
        part(hinge, "GasketHorizontal", center + Vector3(0, side * (height * 0.5 - 0.019), -depth * 0.5 - 0.006), Vector3(width - 0.04, 0.014, 0.012), dark)
    var grip_x := -width + 0.070
    var grip_y := height * 0.27 if id == "fridge" else -height * 0.24
    var grip_length := minf(0.28, height * 0.50)
    for side in [-1.0, 1.0]:
        part(hinge, "HandleMount", Vector3(grip_x, grip_y + side * (grip_length * 0.5 - 0.025), depth * 0.5 + 0.016), Vector3(0.035, 0.04, 0.032), handle)
    part(hinge, "Handle", Vector3(grip_x, grip_y, depth * 0.5 + 0.038), Vector3(0.028, grip_length, 0.023), handle)
    panels.append(hinge)

func snapshot() -> Dictionary:
    var result := {}
    for panel in panels:
        result[panel.panel_id] = panel.angle
    return result

func restore(data: Dictionary) -> void:
    for panel in panels:
        var value: Variant = data.get(panel.panel_id, 0.0)
        if (value is float or value is int) and is_finite(float(value)):
            panel.set_saved_angle(float(value))

func reset() -> void:
    for panel in panels:
        panel.goal = 0.0
        panel.busy = false
        panel.apply_angle(0.0)

func step(delta: float) -> void:
    for panel in panels:
        panel.step(delta)
