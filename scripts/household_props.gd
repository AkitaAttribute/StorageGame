extends Node3D
## Physics props, crosshair selection and gravity-free camera-directed grabbing.
const REACH := 2.1 # Three approximately 70 cm arm lengths.
const PROP_LAYER := 2
const WORLD_MASK := 3
const HOLD_SPEED_LIMIT := 22.0
const LAYOUT_VERSION := 2
# Verified locations from build 21. Only migrate unhandled props still at
# these positions; an existing player's moved objects stay where they are.
const LEGACY_POSITIONS := {
    "fridge_00": Vector3(-8.4, 0.9, 5.0),
    "desk_00": Vector3(-9.4, 0.385, 6.732051),
    "screwdriver_00": Vector3(-8.667949, 0.043, 6.0),
}
const DEFINITIONS := [
    {"id": "fridge_00", "asset": "res://assets/prop_fridge.glb", "height": 1.75, "mass": 65.0},
    {"id": "desk_00", "asset": "res://assets/prop_desk.glb", "height": 0.78, "mass": 22.0},
    {"id": "screwdriver_00", "asset": "", "height": 0.036, "mass": 0.18},
]
var player: CharacterBody3D
var camera: Camera3D
var items: Array[RigidBody3D] = []
var selected: RigidBody3D
var held: RigidBody3D
var hold_distance := 4.0
var release_velocity := Vector3.ZERO
var glow: StandardMaterial3D
var dot: Crosshair
var button: Button
var mobile := false
var desired_position := Vector3.ZERO
var locator: Label
var locator_time := 22.0
var placement_complete := false

class Crosshair:
    extends Control
    var active := false
    func _draw() -> void:
        draw_circle(size * 0.5, 4.5, Color(0.08, 0.09, 0.11, 0.86))
        draw_circle(size * 0.5, 2.6, Color(1.0, 0.82, 0.30) if active else Color(1, 1, 1, 0.95))

func setup(body: CharacterBody3D, view: Camera3D, hud: Control, on_mobile: bool) -> void:
    player = body
    camera = view
    mobile = on_mobile
    glow = StandardMaterial3D.new()
    glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    glow.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    glow.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
    glow.albedo_color = Color(1.0, 0.66, 0.14, 0.38)
    dot = Crosshair.new()
    dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
    dot.set_anchors_preset(Control.PRESET_CENTER)
    dot.offset_left = -6
    dot.offset_right = 6
    dot.offset_top = -6
    dot.offset_bottom = 6
    hud.add_child(dot)
    button = Button.new()
    button.text = "Grab"
    button.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
    button.offset_left = -230
    button.offset_right = -34
    # Above the existing Open/Close button, not overlapping the joystick.
    button.offset_top = -418 if mobile else -106
    button.offset_bottom = -346 if mobile else -34
    button.add_theme_font_size_override("font_size", 26)
    button.mouse_filter = Control.MOUSE_FILTER_IGNORE if mobile else Control.MOUSE_FILTER_STOP
    if not mobile:
        button.pressed.connect(toggle_grab)
    button.hide()
    hud.add_child(button)
    locator = Label.new()
    locator.mouse_filter = Control.MOUSE_FILTER_IGNORE
    locator.position = Vector2(22, 18)
    locator.add_theme_font_size_override("font_size", 17)
    locator.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
    locator.add_theme_constant_override("shadow_offset_x", 2)
    locator.add_theme_constant_override("shadow_offset_y", 2)
    hud.add_child(locator)

func mesh_bounds(root: Node3D) -> AABB:
    var bounds := AABB()
    var first := true
    for node in root.find_children("*", "MeshInstance3D", true, false):
        var mesh_node := node as MeshInstance3D
        if mesh_node.mesh == null:
            continue
        var box: AABB = (root.global_transform.affine_inverse() * mesh_node.global_transform) * mesh_node.get_aabb()
        bounds = box if first else bounds.merge(box)
        first = false
    return bounds

func cylinder(parent: Node3D, center: Vector3, length: float, radius_a: float, radius_b: float, color: Color, metal: float = 0.0) -> void:
    var mesh := CylinderMesh.new()
    mesh.height = length
    mesh.top_radius = radius_a
    mesh.bottom_radius = radius_b
    mesh.radial_segments = 16
    var part := MeshInstance3D.new()
    part.mesh = mesh
    var mat := StandardMaterial3D.new()
    mat.albedo_color = color
    mat.metallic = metal
    mat.roughness = 0.36
    part.material_override = mat
    parent.add_child(part)
    part.position = center
    part.rotation.z = PI * 0.5

func screwdriver(parent: Node3D) -> void:
    # Laid horizontally: molded red handle, black grip bands, steel shaft and tip.
    cylinder(parent, Vector3(-0.077, 0, 0), 0.105, 0.018, 0.018, Color(0.68, 0.12, 0.08))
    for i in range(5):
        cylinder(parent, Vector3(-0.116 + i * 0.018, 0, 0), 0.007, 0.019, 0.019, Color(0.16, 0.17, 0.18))
    cylinder(parent, Vector3(-0.014, 0, 0), 0.022, 0.011, 0.011, Color(0.25, 0.26, 0.28))
    cylinder(parent, Vector3(0.057, 0, 0), 0.12, 0.0045, 0.0045, Color(0.62, 0.66, 0.69), 0.85)
    cylinder(parent, Vector3(0.125, 0, 0), 0.018, 0.0025, 0.0045, Color(0.53, 0.57, 0.60), 0.85)

func build_item(definition: Dictionary) -> RigidBody3D:
    var body := RigidBody3D.new()
    body.name = str(definition["id"])
    body.mass = float(definition["mass"])
    body.collision_layer = PROP_LAYER
    body.collision_mask = WORLD_MASK
    body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
    body.freeze = true
    body.continuous_cd = true
    body.linear_damp = 0.1
    body.angular_damp = 0.65
    add_child(body)
    var art := Node3D.new()
    body.add_child(art)
    var asset := str(definition["asset"])
    if asset.is_empty():
        screwdriver(art)
    else:
        var scene := load(asset) as PackedScene
        if scene == null:
            body.queue_free()
            return null
        art.add_child(scene.instantiate())
    var bounds := mesh_bounds(art)
    if bounds.size.y <= 0.0001:
        body.queue_free()
        return null
    var scale_factor := float(definition["height"]) / bounds.size.y
    art.scale = Vector3.ONE * scale_factor
    art.position = -bounds.get_center() * scale_factor
    var dimensions := (bounds.size * scale_factor).max(Vector3(0.025, 0.025, 0.025))
    var shape := BoxShape3D.new()
    shape.size = dimensions
    var collision := CollisionShape3D.new()
    collision.shape = shape
    collision.name = "PropCollision"
    body.add_child(collision)
    body.set_meta("dimensions", dimensions)
    body.set_meta("prop_id", definition["id"])
    return body

func ground_at(point: Vector3, body: RigidBody3D, dimensions: Vector3) -> float:
    var space := get_world_3d().direct_space_state
    var lowest := INF
    var highest := -INF
    # Test all corners as well as the center: no unsupported feet over edges.
    for corner in [Vector2.ZERO, Vector2(-0.45, -0.45), Vector2(0.45, -0.45), Vector2(-0.45, 0.45), Vector2(0.45, 0.45)]:
        var at: Vector3 = point + Vector3(corner.x * dimensions.x, 0.0, corner.y * dimensions.z)
        var query := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 0.65, at - Vector3.UP * 0.3, 1, [body.get_rid(), player.get_rid()])
        var hit := space.intersect_ray(query)
        if hit.is_empty() or Vector3(hit["normal"]).y < 0.9:
            return INF
        var y: float = Vector3(hit["position"]).y
        lowest = minf(lowest, y)
        highest = maxf(highest, y)
    return highest if highest - lowest < 0.055 else INF

func clear_at(body: RigidBody3D, position: Vector3, basis: Basis = Basis.IDENTITY) -> bool:
    var query := PhysicsShapeQueryParameters3D.new()
    var box := BoxShape3D.new()
    var dimensions: Vector3 = body.get_meta("dimensions")
    box.size = dimensions + Vector3(0.06, 0, 0.06)
    query.shape = box
    query.transform = Transform3D(basis, position)
    query.collision_mask = WORLD_MASK
    query.exclude = [body.get_rid()]
    return get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()

func visible_floor_position(body: RigidBody3D, at: Vector3) -> bool:
    # The object must be approachable from the player without a solid wall
    # between them. Prefer positions directly visible from the current camera.
    var target := at + Vector3.UP * 0.015
    var shoulder := player.global_position + Vector3.UP * 1.25
    for origin in [shoulder, camera.global_position]:
        var query := PhysicsRayQueryParameters3D.create(origin, target, 1, [body.get_rid(), player.get_rid()])
        if not get_world_3d().direct_space_state.intersect_ray(query).is_empty():
            return false
    return not camera.is_position_behind(target)

func should_migrate_legacy(id: String, record: Dictionary, layout: int) -> bool:
    if layout >= LAYOUT_VERSION or bool(record.get("moved", false)) or not LEGACY_POSITIONS.has(id):
        return false
    var pos: Variant = record.get("position", [])
    if not pos is Array or pos.size() != 3:
        return false
    var old := Vector2(float(pos[0]), float(pos[2]))
    var initial: Vector3 = LEGACY_POSITIONS[id]
    var current := Vector2(player.global_position.x, player.global_position.z)
    return old.distance_to(Vector2(initial.x, initial.z)) < 0.35 and old.distance_to(current) > 4.0

func spawn_items(saved: Dictionary, layout: int = 0) -> void:
    # Run after static collision shapes have entered the physics world.
    await get_tree().physics_frame
    await get_tree().physics_frame
    var occupied: Array[AABB] = []
    var candidates: Array[Vector3] = []
    # Start in front of the current saved character, not the New Game
    # spawn. The camera's horizontal forward vector defines the preferred area.
    var center := player.global_position
    var forward := -camera.global_transform.basis.z
    forward.y = 0.0
    forward = forward.normalized()
    if forward.length_squared() < 0.001:
        forward = Vector3.FORWARD
    for distance in [2.0, 2.8, 3.6, 4.8, 6.0, 8.0, 12.0, 16.0]:
        for degrees in [0, -25, 25, -50, 50, -75, 75, -100, 100, -125, 125, -150, 150, 180]:
            var point := center + forward.rotated(Vector3.UP, deg_to_rad(float(degrees))) * float(distance)
            if absf(point.x) < 27.0 and absf(point.z) < 27.0:
                candidates.append(point)
    # Ground-level fallback if the current character is on stairs or in a
    # crowded unit without enough floor area for furniture.
    for distance in [2.0, 3.5, 5.0, 7.0, 10.0, 14.0, 20.0]:
        for i in range(24):
            var angle := TAU * float(i) / 24.0
            var point := Vector3(-10.4 + cos(angle) * float(distance), 0, 5.0 + sin(angle) * float(distance))
            if absf(point.x) < 27.0 and absf(point.z) < 27.0:
                candidates.append(point)
    for definition in DEFINITIONS:
        var body := build_item(definition)
        if body == null:
            push_error("Could not build household prop " + str(definition["id"]))
            continue
        var dimensions: Vector3 = body.get_meta("dimensions")
        var placed := false
        var record: Variant = saved.get(str(definition["id"]), {})
        if record is Dictionary and not should_migrate_legacy(str(definition["id"]), record, layout):
            body.set_meta("moved", bool(record.get("moved", false)))
            var pos: Variant = record.get("position", [])
            var rot: Variant = record.get("rotation", [])
            if pos is Array and rot is Array and pos.size() == 3 and rot.size() == 3:
                var at := Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
                var angles := Vector3(float(rot[0]), float(rot[1]), float(rot[2]))
                if at.is_finite() and angles.is_finite() and absf(at.x) < 29.0 and absf(at.z) < 29.0 and at.y > -1.0 and at.y < 20.0:
                    var restored_bounds := Transform3D(Basis.from_euler(angles), at) * AABB(-dimensions * 0.5, dimensions)
                    var overlap := false
                    for prior in occupied:
                        if restored_bounds.grow(0.02).intersects(prior):
                            overlap = true
                            break
                    if not overlap and clear_at(body, at, Basis.from_euler(angles)):
                        body.position = at
                        body.rotation = angles
                        occupied.append(restored_bounds)
                        placed = true
        if not placed:
            # First pass: visible, nearby and unobstructed. Second pass:
            # allow a clear but out-of-view location rather than intersecting
            # existing facility geometry when the player is in a tight space.
            for require_visible in [true, false]:
                for point in candidates:
                    var y := ground_at(point, body, dimensions)
                    if not is_finite(y):
                        continue
                    var at := Vector3(point.x, y + dimensions.y * 0.5 + 0.025, point.z)
                    if require_visible and not visible_floor_position(body, at):
                        continue
                    var bounds := AABB(at - dimensions * 0.5, dimensions)
                    var overlap := false
                    for prior in occupied:
                        if bounds.grow(0.22).intersects(prior):
                            overlap = true
                            break
                    if overlap or not clear_at(body, at):
                        continue
                    body.position = at
                    occupied.append(bounds)
                    placed = true
                    break
                if placed:
                    break
        if not placed:
            push_error("No clear floor location for " + str(definition["id"]))
            body.queue_free()
            continue
        items.append(body)
        # Sync this body's new collision before searching for the next item.
        await get_tree().physics_frame
        body.freeze = false
        print("HOUSEHOLD_PROP ", body.name, " ", body.position, " player_distance=", body.global_position.distance_to(player.global_position))
    placement_complete = true

func ray_origin() -> Vector3:
    return camera.project_ray_origin(camera.get_viewport().get_visible_rect().size * 0.5)

func ray_direction() -> Vector3:
    return camera.project_ray_normal(camera.get_viewport().get_visible_rect().size * 0.5)

func set_highlight(body: RigidBody3D, enabled: bool) -> void:
    if not is_instance_valid(body):
        return
    for node in body.find_children("*", "MeshInstance3D", true, false):
        var mesh := node as MeshInstance3D
        mesh.material_overlay = glow if enabled else null

func select_at_crosshair() -> void:
    var next: RigidBody3D = null
    if not is_instance_valid(held):
        var origin := ray_origin()
        var query := PhysicsRayQueryParameters3D.create(origin, origin + ray_direction() * 9.0, WORLD_MASK, [player.get_rid()])
        var hit := get_world_3d().direct_space_state.intersect_ray(query)
        if not hit.is_empty():
            var candidate := hit.get("collider") as RigidBody3D
            var shoulder := player.global_position + Vector3.UP * 1.2
            if is_instance_valid(candidate) and items.has(candidate) and shoulder.distance_to(Vector3(hit["position"])) <= REACH:
                next = candidate
    if selected != next:
        set_highlight(selected, false)
        selected = next
        set_highlight(selected, true)

func toggle_grab() -> void:
    if is_instance_valid(held):
        drop()
    elif is_instance_valid(selected):
        grab(selected)

func grab(body: RigidBody3D) -> void:
    if not items.has(body) or is_instance_valid(held):
        return
    held = body
    held.set_meta("moved", true)
    locator_time = 0.0
    set_highlight(selected, false)
    selected = null
    held.freeze = true
    held.gravity_scale = 0.0
    held.linear_velocity = Vector3.ZERO
    held.angular_velocity = Vector3.ZERO
    held.add_collision_exception_with(player)
    player.add_collision_exception_with(held)
    # Keep the grabbed object beyond the character rather than pulling it
    # into their chest as soon as the crosshair hits its near face.
    var dimensions: Vector3 = held.get_meta("dimensions")
    var extent := Vector2(dimensions.x, dimensions.z).length() * 0.5
    hold_distance = maxf((held.global_position - ray_origin()).dot(ray_direction()), camera.global_position.distance_to(player.global_position + Vector3.UP * 1.1) + extent + 0.42)
    hold_distance = minf(hold_distance, 6.0)
    release_velocity = Vector3.ZERO
    desired_position = held.global_position
    set_highlight(held, true)

func drop() -> void:
    if not is_instance_valid(held):
        return
    var body := held
    held = null
    set_highlight(body, false)
    body.gravity_scale = 1.0
    body.remove_collision_exception_with(player)
    player.remove_collision_exception_with(body)
    body.freeze = false
    body.sleeping = false
    body.linear_velocity = release_velocity.limit_length(HOLD_SPEED_LIMIT)
    release_velocity = Vector3.ZERO

func update_hold(delta: float) -> void:
    if not is_instance_valid(held):
        return
    var start := held.global_position
    desired_position = ray_origin() + ray_direction() * hold_distance
    var motion := desired_position - start
    # No spring, mass-dependent lag or gravity. Sweep only to prevent passing
    # through physical walls and other props while the item is being carried.
    var col := held.get_node("PropCollision") as CollisionShape3D
    var query := PhysicsShapeQueryParameters3D.new()
    query.shape = col.shape
    query.transform = held.global_transform
    query.motion = motion
    query.collision_mask = WORLD_MASK
    query.exclude = [held.get_rid(), player.get_rid()]
    var fraction := get_world_3d().direct_space_state.cast_motion(query)
    if fraction.size() >= 2 and fraction[0] < 1.0:
        motion *= maxf(0.0, fraction[0] - 0.002)
    held.global_position = start + motion
    var actual := motion / maxf(delta, 0.001)
    # Preserve recent camera/player-driven velocity when released.
    release_velocity = release_velocity.lerp(actual.limit_length(HOLD_SPEED_LIMIT), 1.0 - exp(-delta * 22.0))

func tick(delta: float) -> void:
    update_hold(delta)
    update_locator(delta)
    select_at_crosshair()
    var active := is_instance_valid(held) or is_instance_valid(selected)
    button.visible = active
    button.text = ("Drop" if mobile else "G  Drop") if is_instance_valid(held) else ("Grab" if mobile else "G  Grab")
    if dot.active != active:
        dot.active = active
        dot.queue_redraw()

func update_locator(delta: float) -> void:
    if not placement_complete or locator_time <= 0.0:
        locator.hide()
        return
    locator_time = maxf(0.0, locator_time - delta)
    var lines := PackedStringArray()
    var forward := -camera.global_transform.basis.z
    forward.y = 0.0
    forward = forward.normalized()
    var right := camera.global_transform.basis.x
    right.y = 0.0
    right = right.normalized()
    for body in items:
        if not is_instance_valid(body):
            continue
        var offset := body.global_position - player.global_position
        offset.y = 0.0
        var direction := "ahead" if offset.dot(forward) >= 0.0 else "behind"
        if absf(offset.dot(right)) > absf(offset.dot(forward)):
            direction = "right" if offset.dot(right) >= 0.0 else "left"
        var label := str(body.get_meta("prop_id")).get_slice("_", 0).capitalize()
        lines.append("%s: %.1f m %s" % [label, offset.length(), direction])
    locator.text = "\n".join(lines)
    locator.show()

func snapshot() -> Dictionary:
    var result := {}
    for body in items:
        if not is_instance_valid(body):
            continue
        var pos := body.position
        var rot := body.rotation
        result[str(body.get_meta("prop_id"))] = {"position": [pos.x, pos.y, pos.z], "rotation": [rot.x, rot.y, rot.z], "moved": bool(body.get_meta("moved", false))}
    return result
