extends Node3D
## Procedural self-storage shell and corrugated curtain. Positive Z faces the aisle.
## The curtain travels up the guides and around a shrinking-radius winding path,
## rather than rotating as a rigid door or disappearing through the roof.
const WIDTH := 3.0
const DEPTH := 3.0
const SLAT_COUNT := 24
const FRONT := 1.42
const FLOOR := 0.025
var unit_height := 2.4
var clear_height := 1.9
var radius := 0.19
var slat_pitch := 0.08
var curtain_length := 1.9
var slats: Array[Node3D] = []
var bottom_bar: Node3D
var blocker: StaticBody3D
var animator: AnimationPlayer
var path_points: PackedVector2Array = []
var path_lengths: PackedFloat32Array = []
var opening: float = 0.0:
    set(value):
        opening = clampf(value, 0.0, 1.0)
        if not slats.is_empty():
            update_curtain()

func metal(color: Color, metallic: float = 0.65, roughness: float = 0.4) -> StandardMaterial3D:
    var mat := StandardMaterial3D.new()
    mat.albedo_color = color
    mat.metallic = metallic
    mat.roughness = roughness
    return mat

func box(parent: Node3D, at: Vector3, size: Vector3, mat: Material, solid: bool = false) -> MeshInstance3D:
    var mesh := BoxMesh.new()
    mesh.size = size
    var part := MeshInstance3D.new()
    part.mesh = mesh
    part.material_override = mat
    parent.add_child(part)
    part.position = at
    if solid:
        collision_box(parent, at, size)
    return part

func collision_box(parent: Node3D, at: Vector3, size: Vector3) -> StaticBody3D:
    var body := StaticBody3D.new()
    parent.add_child(body)
    body.position = at
    var col := CollisionShape3D.new()
    var shape := BoxShape3D.new()
    shape.size = size
    col.shape = shape
    body.add_child(col)
    return body

func build(height: float, initially_open: bool) -> void:
    unit_height = height
    # Match exterior height; reserve a headroom bay under the roof.
    var cavity := clampf(unit_height * 0.19, 0.38, 0.55)
    clear_height = unit_height - cavity
    radius = cavity * 0.39
    curtain_length = clear_height + radius - FLOOR
    slat_pitch = curtain_length / float(SLAT_COUNT)
    var siding := metal(Color(0.67, 0.70, 0.72), 0.25, 0.60)
    var trim := metal(Color(0.25, 0.29, 0.32))
    var rail := metal(Color(0.58, 0.63, 0.67))
    var panel := metal(Color(0.18, 0.37, 0.58), 0.48, 0.38)
    var ribs := metal(Color(0.22, 0.43, 0.64), 0.48, 0.38)
    var concrete := metal(Color(0.48, 0.49, 0.49), 0.0, 0.9)
    # Walkable floor, separate interior ceiling, and a sealed roof.
    box(self, Vector3(0, 0.0, 0), Vector3(WIDTH, 0.05, DEPTH), concrete, true)
    for side in [-1.0, 1.0]:
        box(self, Vector3(side * 1.46, unit_height * 0.5, 0), Vector3(0.08, unit_height, DEPTH), siding, true)
        # Raised sheet-metal seams on the side walls.
        for j in range(15):
            box(self, Vector3(side * 1.503, unit_height * 0.5, -1.4 + j * 0.20), Vector3(0.012, unit_height - 0.08, 0.025), rail)
        box(self, Vector3(side * 1.40, clear_height * 0.5, FRONT), Vector3(0.10, clear_height, 0.12), trim, true)
        box(self, Vector3(side * 1.345, clear_height * 0.5, FRONT + 0.035), Vector3(0.045, clear_height, 0.045), rail)
        box(self, Vector3(side * 1.38, clear_height + radius * 0.48, FRONT - radius), Vector3(0.055, cavity * 0.78, radius * 2.2), trim)
    box(self, Vector3(0, unit_height * 0.5, -1.46), Vector3(WIDTH, unit_height, 0.08), siding, true)
    box(self, Vector3(0, unit_height - 0.04, 0), Vector3(WIDTH, 0.08, DEPTH), trim, true)
    # Ceiling ends behind the barrel, leaving the winding bay unobstructed.
    var ceiling_end := FRONT - 2.0 * radius - 0.12
    var ceiling_depth := ceiling_end + 1.42
    box(self, Vector3(0, clear_height + 0.015, -1.42 + ceiling_depth * 0.5), Vector3(2.84, 0.03, ceiling_depth), siding, true)
    box(self, Vector3(0, clear_height + cavity * 0.5, 1.49), Vector3(WIDTH, cavity, 0.025), siding, true)
    box(self, Vector3(0, clear_height + 0.025, 1.49), Vector3(WIDTH, 0.05, 0.04), trim)
    var drum := CylinderMesh.new()
    drum.top_radius = radius * 0.56
    drum.bottom_radius = drum.top_radius
    drum.height = 2.72
    drum.radial_segments = 32
    var barrel := MeshInstance3D.new()
    barrel.mesh = drum
    barrel.material_override = rail
    add_child(barrel)
    barrel.position = Vector3(0, clear_height + radius, FRONT - radius)
    barrel.rotation.z = PI * 0.5
    build_path()
    for i in range(SLAT_COUNT):
        var slat := Node3D.new()
        slat.name = "CurtainSlat%02d" % i
        add_child(slat)
        # Thin painted metal with a raised horizontal corrugation and seam.
        box(slat, Vector3.ZERO, Vector3(2.71, slat_pitch * 0.98, 0.015), panel)
        box(slat, Vector3(0, 0, 0.013), Vector3(2.71, slat_pitch * 0.38, 0.016), ribs)
        box(slat, Vector3(0, -slat_pitch * 0.45, 0.006), Vector3(2.71, 0.008, 0.018), trim)
        slats.append(slat)
    bottom_bar = Node3D.new()
    bottom_bar.name = "BottomBar"
    add_child(bottom_bar)
    box(bottom_bar, Vector3.ZERO, Vector3(2.75, 0.045, 0.045), trim)
    box(bottom_bar, Vector3(0, 0.015, 0.036), Vector3(0.28, 0.035, 0.045), rail)
    for side in [-1.0, 1.0]:
        box(bottom_bar, Vector3(side * 0.12, 0.015, 0.020), Vector3(0.025, 0.055, 0.06), rail)
    box(bottom_bar, Vector3(1.13, 0.025, 0.032), Vector3(0.20, 0.065, 0.025), rail)
    box(bottom_bar, Vector3(1.20, 0.025, 0.052), Vector3(0.08, 0.025, 0.018), trim)
    blocker = collision_box(self, Vector3(0, clear_height * 0.5, FRONT), Vector3(2.72, clear_height, 0.10))
    blocker.collision_layer = 0 if initially_open else 1
    animator = AnimationPlayer.new()
    animator.name = "DoorAnimation"
    add_child(animator)
    animator.root_node = NodePath("..")
    var library := AnimationLibrary.new()
    for clip in ["open", "close"]:
        var animation := Animation.new()
        animation.length = 2.2
        var track := animation.add_track(Animation.TYPE_VALUE)
        animation.track_set_path(track, NodePath(".:opening"))
        animation.track_insert_key(track, 0.0, 0.0 if clip == "open" else 1.0)
        animation.track_insert_key(track, 2.2, 1.0 if clip == "open" else 0.0)
        library.add_animation(clip, animation)
    animator.add_animation_library(&"", library)
    opening = 1.0 if initially_open else 0.0

func build_path() -> void:
    # Arc-length table means all slats move the same distance, maintaining
    # their spacing while bending around the drum. Radius shrinks as layers wind.
    path_points = PackedVector2Array([Vector2(FLOOR, FRONT), Vector2(clear_height + radius, FRONT)])
    path_lengths = PackedFloat32Array([0.0, curtain_length])
    var accumulated := curtain_length
    var previous := path_points[-1]
    var angle := 0.0
    while accumulated < curtain_length * 2.0 + 0.15 and angle < TAU * 5.0:
        angle += 0.035
        var winding_radius := maxf(radius * 0.58, radius - 0.026 * angle / TAU)
        var point := Vector2(clear_height + radius + sin(angle) * winding_radius, FRONT - radius + cos(angle) * winding_radius)
        accumulated += previous.distance_to(point)
        path_points.append(point)
        path_lengths.append(accumulated)
        previous = point

func sample_path(distance: float) -> Vector2:
    var d := clampf(distance, 0.0, path_lengths[-1])
    var lo := 0
    var hi := path_lengths.size() - 1
    while hi - lo > 1:
        var mid := (hi + lo) >> 1
        if path_lengths[mid] < d:
            lo = mid
        else:
            hi = mid
    var t := (d - path_lengths[lo]) / maxf(0.000001, path_lengths[hi] - path_lengths[lo])
    return path_points[lo].lerp(path_points[hi], t)

func place_on_path(part: Node3D, distance: float) -> void:
    var point := sample_path(distance)
    var tangent := sample_path(distance + 0.005) - sample_path(maxf(0.0, distance - 0.005))
    part.position = Vector3(0, point.x, point.y)
    part.rotation.x = atan2(tangent.y, tangent.x)

func update_curtain() -> void:
    var eased := smoothstep(0.0, 1.0, opening)
    var travel := eased * (curtain_length + 0.035)
    for i in range(slats.size()):
        place_on_path(slats[i], travel + (float(i) + 0.5) * slat_pitch)
    place_on_path(bottom_bar, travel)
