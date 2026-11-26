extends Node3D
## Physics props, crosshair selection and gravity-free camera-directed grabbing.
const Fridge = preload("res://scripts/interactive_fridge.gd")
const StorageContents = preload("res://scripts/storage_contents.gd")
const StoredOutline = preload("res://scripts/stored_outline.gd")
var stored_outline: StoredOutline
const HingedPanel = preload("res://scripts/hinged_panel.gd")
const REACH := 2.1 # Three approximately 70 cm arm lengths.
const PROP_LAYER := 2
const WORLD_MASK := 3
const HOLD_SPEED_LIMIT := 14.0
const PULL_GAIN := 12.0
const PULL_ACCELERATION := 48.0
const LAYOUT_VERSION := 4
const PROP_BOUNDARY_LAYER := 8
const BODY_MASK := WORLD_MASK | PROP_BOUNDARY_LAYER
const PLAYABLE_LIMIT := 29.5
const MAX_PROP_HEIGHT := 18.0
const MAX_SAFE_SPEED := 32.0
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
    {"id": "screwdriver_00", "asset": "res://assets/prop_screwdriver.glb", "length": 0.28, "mass": 0.18},
    {"id": "boombox_00", "asset": "res://assets/prop_boombox.glb", "height": 0.30, "mass": 3.0},
]
var player: CharacterBody3D
var camera: Camera3D
var items: Array[RigidBody3D] = []
var selected: RigidBody3D
var selected_panel: HingedPanel
var held: RigidBody3D
var hold_distance := 4.0
var previous_linear_damp := 0.1
var previous_angular_damp := 0.65
var previous_lock_rotation := false
var glow: StandardMaterial3D
var dot: Crosshair
var button: Button
var mobile := false
var desired_position := Vector3.ZERO
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
    stored_outline = StoredOutline.new()
    add_child(stored_outline)
    stored_outline.setup(camera, hud)

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
    # Construct the body without physics participation until it has a
    # validated floor position. Never introduce collision at the world origin.
    body.collision_layer = 0
    body.collision_mask = 0
    body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
    body.freeze = true
    body.continuous_cd = true
    body.linear_damp = 0.1
    body.angular_damp = 0.65
    var material := PhysicsMaterial.new()
    material.bounce = 0.0
    material.friction = 0.8
    body.physics_material_override = material
    add_child(body)
    var art := Node3D.new()
    body.add_child(art)
    var model_root := Node3D.new()
    art.add_child(model_root)
    var asset := str(definition["asset"])
    if asset.is_empty():
        screwdriver(model_root)
    else:
        var scene := load(asset) as PackedScene
        if scene == null:
            body.queue_free()
            return null
        model_root.add_child(scene.instantiate())
    var bounds := mesh_bounds(art)
    if bounds.size.y <= 0.0001:
        body.queue_free()
        return null
    var scale_factor := 1.0
    if definition.has("length"):
        # Tools may be exported standing upright; lay their longest axis flat.
        if bounds.size.y > maxf(bounds.size.x, bounds.size.z):
            model_root.rotation.z = PI * 0.5
            bounds = mesh_bounds(art)
        scale_factor = float(definition["length"]) / maxf(bounds.size.x, bounds.size.z)
    else:
        scale_factor = float(definition["height"]) / bounds.size.y
    art.scale = Vector3.ONE * scale_factor
    art.position = -bounds.get_center() * scale_factor
    # A minimum collision thickness prevents thin tools tunneling or sinking
    # into the ground; their original visual proportions remain unchanged.
    var minimum := Vector3(0.025, 0.05, 0.025) if definition.has("length") else Vector3(0.025, 0.025, 0.025)
    var dimensions := (bounds.size * scale_factor).max(minimum)
    if str(definition["id"]) == "fridge_00":
        # Use the original asset's measured dimensions but replace its
        # material-merged mesh with a hollow, articulated cabinet.
        art.hide()
        art.queue_free()
        var fridge := Fridge.new()
        fridge.name = "InteractiveFridge"
        body.add_child(fridge)
        fridge.build(body, dimensions)
    else:
        var shape := BoxShape3D.new()
        shape.size = dimensions
        var collision := CollisionShape3D.new()
        collision.shape = shape
        collision.name = "PropCollision"
        body.add_child(collision)
    if not dimensions.is_finite() or dimensions.x > 4.0 or dimensions.y > 3.0 or dimensions.z > 4.0:
        push_error("Invalid normalized household prop dimensions: " + str(dimensions))
        body.queue_free()
        return null
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
    return not camera.is_position_behind(target) and camera.is_position_in_frustum(target)

func should_migrate_legacy(_id: String, record: Dictionary, layout: int) -> bool:
    if layout >= LAYOUT_VERSION:
        return false
    # One-time recovery for the unstable earlier layout: relocate untouched
    # items near the current character. Keep deliberately moved items if valid.
    if not bool(record.get("moved", false)):
        return true
    return false

func floor_candidates() -> Array[Vector3]:
    var candidates: Array[Vector3] = []
    # Start in front of the current saved character, not the New Game
    # spawn. The camera's horizontal forward vector defines the preferred area.
    var center := player.global_position
    var forward := -camera.global_transform.basis.z
    forward.y = 0.0
    forward = forward.normalized()
    if forward.length_squared() < 0.001:
        forward = Vector3.FORWARD
    for distance in [2.8, 3.6, 2.0, 4.8, 6.0, 8.0, 12.0, 16.0]:
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
    return candidates

func valid_world_position(at: Vector3) -> bool:
    return at.is_finite() and absf(at.x) < PLAYABLE_LIMIT and absf(at.z) < PLAYABLE_LIMIT and at.y >= -0.10 and at.y < MAX_PROP_HEIGHT

func find_floor_position(body: RigidBody3D, candidates: Array[Vector3], occupied: Array[AABB]) -> Vector3:
    var dimensions: Vector3 = body.get_meta("dimensions")
    for require_visible in [true, false]:
        for point in candidates:
            var y := ground_at(point, body, dimensions)
            if not is_finite(y):
                continue
            var at := Vector3(point.x, y + dimensions.y * 0.5 + 0.025, point.z)
            if not valid_world_position(at):
                continue
            if require_visible and not visible_floor_position(body, at):
                continue
            var bounds := AABB(at - dimensions * 0.5, dimensions)
            var overlap := false
            for prior in occupied:
                if bounds.grow(0.22).intersects(prior):
                    overlap = true
                    break
            if not overlap and clear_at(body, at):
                return at
    return Vector3.INF

func container_by_id(id: String) -> StorageContents:
    for item in items:
        if is_instance_valid(item) and str(item.get_meta("prop_id", "")) == id:
            return item.get_node_or_null("StorageContents") as StorageContents
    return null

func inside_open_container(body: RigidBody3D, pose: Transform3D) -> bool:
    for item in items:
        var storage := item.get_node_or_null("StorageContents") as StorageContents
        if storage == null:
            continue
        var relative := item.global_transform.affine_inverse() * pose
        for id in storage.compartments:
            var closure: HingedPanel = storage.compartments[id]["closure"]
            if closure.goal >= StorageContents.OPEN_CLEARANCE and storage.fits(str(id), relative, body.get_meta("dimensions")):
                return true
    return false

func spawn_items(saved: Dictionary, layout: int = 0) -> void:
    # Run after static collision shapes have entered the physics world.
    await get_tree().physics_frame
    await get_tree().physics_frame
    var occupied: Array[AABB] = []
    var candidates := floor_candidates()
    for definition in DEFINITIONS:
        var body := build_item(definition)
        if body == null:
            push_error("Could not build household prop " + str(definition["id"]))
            continue
        var dimensions: Vector3 = body.get_meta("dimensions")
        var placed := false
        var record: Variant = saved.get(str(definition["id"]), {})
        # Containers are constructed first. A valid stored item can be
        # restored inside its container without normal floor placement.
        if record is Dictionary and record.get("storage", {}) is Dictionary:
            var cargo: Dictionary = record.get("storage", {})
            var storage := container_by_id(str(cargo.get("owner", "")))
            if storage != null and storage.restore_item(body, cargo):
                items.append(body)
                continue
        if record is Dictionary and not should_migrate_legacy(str(definition["id"]), record, layout):
            body.set_meta("moved", bool(record.get("moved", false)))
            var pos: Variant = record.get("position", [])
            var rot: Variant = record.get("rotation", [])
            if pos is Array and rot is Array and pos.size() == 3 and rot.size() == 3:
                var at := Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
                var angles := Vector3(float(rot[0]), float(rot[1]), float(rot[2]))
                if valid_world_position(at) and angles.is_finite():
                    var restored_bounds := Transform3D(Basis.from_euler(angles), at) * AABB(-dimensions * 0.5, dimensions)
                    var overlap := false
                    for prior in occupied:
                        if restored_bounds.grow(0.02).intersects(prior):
                            overlap = true
                            break
                    var restored_pose := Transform3D(Basis.from_euler(angles), at)
                    if (not overlap or inside_open_container(body, restored_pose)) and clear_at(body, at, restored_pose.basis):
                        body.position = at
                        body.rotation = angles
                        occupied.append(restored_bounds)
                        placed = true
        if not placed:
            var at := find_floor_position(body, candidates, occupied)
            if at.is_finite():
                body.position = at
                body.rotation = Vector3.ZERO
                occupied.append(AABB(at - dimensions * 0.5, dimensions))
                body.set_meta("moved", false)
                placed = true
        if not placed:
            push_error("No clear floor location for " + str(definition["id"]))
            body.queue_free()
            continue
        body.set_meta("safe_position", body.global_position)
        body.set_meta("safe_rotation", body.rotation)
        body.linear_velocity = Vector3.ZERO
        body.angular_velocity = Vector3.ZERO
        # First sync the validated transform, then activate collision while
        # frozen. Untouched props are static until their first grab.
        await get_tree().physics_frame
        body.collision_layer = PROP_LAYER
        body.collision_mask = BODY_MASK
        await get_tree().physics_frame
        items.append(body)
        var fridge := body.get_node_or_null("InteractiveFridge") as Fridge
        if fridge != null and record is Dictionary:
            var saved_doors: Variant = record.get("hinges", {})
            if saved_doors is Dictionary:
                fridge.restore(saved_doors)
        print("HOUSEHOLD_PROP ", body.name, " ", body.position, " dimensions=", dimensions, " player_distance=", body.global_position.distance_to(player.global_position))
    placement_complete = true
    for item in items:
        var storage := item.get_node_or_null("StorageContents") as StorageContents
        if storage != null:
            storage.bind_inventory(self)
            storage.contents_changed.connect(refresh_stored_outline)
            storage.reconcile_initial_contents()
    refresh_stored_outline()

func ray_origin() -> Vector3:
    return camera.project_ray_origin(camera.get_viewport().get_visible_rect().size * 0.5)

func ray_direction() -> Vector3:
    return camera.project_ray_normal(camera.get_viewport().get_visible_rect().size * 0.5)

func set_highlight(body: RigidBody3D, enabled: bool) -> void:
    if not is_instance_valid(body):
        return
    for node in body.find_children("*", "MeshInstance3D", true, false):
        var mesh := node as MeshInstance3D
        if not mesh.has_meta("stored_mask"):
            mesh.material_overlay = glow if enabled else null

func select_at_crosshair() -> void:
    var next: RigidBody3D = null
    var next_panel: HingedPanel = null
    if not is_instance_valid(held):
        var origin := ray_origin()
        var query := PhysicsRayQueryParameters3D.create(origin, origin + ray_direction() * 9.0, WORLD_MASK, [player.get_rid()])
        var hit := get_world_3d().direct_space_state.intersect_ray(query)
        if not hit.is_empty():
            var candidate := hit.get("collider") as RigidBody3D
            var shoulder := player.global_position + Vector3.UP * 1.2
            if is_instance_valid(candidate) and items.has(candidate) and shoulder.distance_to(Vector3(hit["position"])) <= REACH:
                next = candidate
                next_panel = panel_from_hit(candidate, hit)
    if selected != next or selected_panel != next_panel:
        set_highlight(selected, false)
        selected = next
        selected_panel = next_panel
        if is_instance_valid(selected_panel):
            selected_panel.highlight(glow)
        else:
            set_highlight(selected, true)

func panel_from_hit(candidate: RigidBody3D, hit: Dictionary) -> HingedPanel:
    var shape_index := int(hit.get("shape", -1))
    if shape_index < 0:
        return null
    var owner_id := candidate.shape_find_owner(shape_index)
    var shape_owner := candidate.shape_owner_get_owner(owner_id) as CollisionShape3D
    if shape_owner != null and shape_owner.has_meta("hinge_panel"):
        return shape_owner.get_meta("hinge_panel") as HingedPanel
    return null

func has_panel_action() -> bool:
    return is_instance_valid(selected_panel) and not is_instance_valid(held)

func panel_action_text() -> String:
    return selected_panel.action_text() if has_panel_action() else ""

func use_panel() -> void:
    if has_panel_action():
        selected_panel.toggle()

func toggle_grab() -> void:
    if is_instance_valid(held):
        drop()
    elif is_instance_valid(selected):
        grab(selected)

func grab(body: RigidBody3D) -> void:
    if not items.has(body) or is_instance_valid(held) or bool(body.get_meta("recovering", false)) or body.has_meta("storage_owner"):
        return
    held = body
    held.set_meta("moved", true)
    set_highlight(selected, false)
    selected = null
    selected_panel = null
    # Remain a dynamic rigid body with normal collision masks, contact solver
    # and CCD. Never move the transform directly during a grab.
    previous_linear_damp = held.linear_damp
    previous_angular_damp = held.angular_damp
    previous_lock_rotation = held.lock_rotation
    held.freeze = false
    held.sleeping = false
    held.gravity_scale = 0.0
    held.linear_damp = 0.0
    held.angular_damp = 6.0
    held.angular_velocity = Vector3.ZERO
    held.lock_rotation = true
    # Keep the grabbed object beyond the character rather than pulling it
    # into their chest as soon as the crosshair hits its near face.
    var dimensions: Vector3 = held.get_meta("dimensions")
    var extent := Vector2(dimensions.x, dimensions.z).length() * 0.5
    hold_distance = maxf((held.global_position - ray_origin()).dot(ray_direction()), camera.global_position.distance_to(player.global_position + Vector3.UP * 1.1) + extent + 0.42)
    hold_distance = minf(hold_distance, 6.0)
    desired_position = held.global_position
    set_highlight(held, true)

func drop() -> void:
    if not is_instance_valid(held):
        return
    var body := held
    held = null
    set_highlight(body, false)
    body.gravity_scale = 1.0
    body.linear_damp = previous_linear_damp
    body.angular_damp = previous_angular_damp
    body.lock_rotation = previous_lock_rotation
    body.sleeping = false
    # Keep the velocity that the actual physics solver allowed, not the
    # unfulfilled target velocity into a wall. No artificial throw impulse.

func pull_toward(target_position: Vector3, delta: float) -> void:
    if not is_instance_valid(held):
        return
    desired_position = target_position
    var error := target_position - held.global_position
    var target_velocity := (error * PULL_GAIN).limit_length(HOLD_SPEED_LIMIT)
    var next_velocity := held.linear_velocity.move_toward(target_velocity, PULL_ACCELERATION * delta)
    # Limit motion toward a blocking surface using the exact rigid-body
    # collision shape and physics-engine sweep; preserve tangential movement
    # so a prop can slide along the floor or wall. Solver + CCD remain active.
    var motion := next_velocity * delta
    if motion.length_squared() > 0.0000001:
        var hit := KinematicCollision3D.new()
        if held.test_move(held.global_transform, motion, hit, 0.002):
            var normal := hit.get_normal()
            var into := next_velocity.dot(normal)
            if into < 0.0:
                next_velocity -= normal * into
    held.linear_velocity = next_velocity
    held.sleeping = false

func update_hold(delta: float) -> void:
    if not is_instance_valid(held):
        return
    pull_toward(ray_origin() + ray_direction() * hold_distance, delta)

# Bound recovery applies only to escaped or numerically unstable items, not
# normal pulls. Normal motion always uses the rigid-body collision solver.
func needs_recovery(body: RigidBody3D) -> bool:
    if not valid_world_position(body.global_position):
        return true
    if not body.linear_velocity.is_finite() or not body.angular_velocity.is_finite():
        return true
    return body.linear_velocity.length() > MAX_SAFE_SPEED or body.angular_velocity.length() > 45.0

func recover_item(body: RigidBody3D) -> void:
    if bool(body.get_meta("recovering", false)):
        return
    body.set_meta("recovering", true)
    if body == held:
        drop()
    if body == selected:
        set_highlight(selected, false)
        selected = null
        selected_panel = null
    body.freeze = true
    body.collision_layer = 0
    body.collision_mask = 0
    body.linear_velocity = Vector3.ZERO
    body.angular_velocity = Vector3.ZERO
    var fridge := body.get_node_or_null("InteractiveFridge") as Fridge
    if fridge != null:
        fridge.reset()
    var occupied: Array[AABB] = []
    for other in items:
        if other == body or not is_instance_valid(other) or not valid_world_position(other.global_position):
            continue
        if other.has_meta("storage_owner"):
            continue
        var dimensions: Vector3 = other.get_meta("dimensions")
        occupied.append(other.global_transform * AABB(-dimensions * 0.5, dimensions))
    var at := find_floor_position(body, floor_candidates(), occupied)
    if not at.is_finite():
        # Don't place into a wall or floor if the player is confined.
        # Hide the body while waiting for a free location.
        body.hide()
        body.set_meta("recovering", false)
        return
    body.global_transform = Transform3D(Basis.IDENTITY, at)
    body.set_meta("safe_position", at)
    body.set_meta("safe_rotation", Vector3.ZERO)
    body.set_meta("moved", false)
    body.gravity_scale = 1.0
    body.show()
    await get_tree().physics_frame
    body.collision_layer = PROP_LAYER
    body.collision_mask = BODY_MASK
    await get_tree().physics_frame
    body.set_meta("recovering", false)
    print("HOUSEHOLD_RECOVERED ", body.name, " ", at)

func tick(delta: float) -> void:
    if placement_complete:
        for body in items:
            if is_instance_valid(body) and not body.has_meta("storage_owner") and not bool(body.get_meta("recovering", false)) and (needs_recovery(body) or not body.visible):
                recover_item(body)
    for item in items:
        if is_instance_valid(item) and not bool(item.get_meta("recovering", false)) and item != held:
            var fridge := item.get_node_or_null("InteractiveFridge") as Fridge
            if fridge != null:
                fridge.step(delta)
    update_hold(delta)
    stored_outline.sync_camera()
    select_at_crosshair()
    var active := is_instance_valid(held) or is_instance_valid(selected)
    button.visible = active
    button.text = ("Drop" if mobile else "G  Drop") if is_instance_valid(held) else ("Grab" if mobile else "G  Grab")
    if dot.active != active:
        dot.active = active
        dot.queue_redraw()

# Membership changes are signaled by the container, not discovered every frame.
func refresh_stored_outline() -> void:
    var contained: Array[RigidBody3D] = []
    for item in items:
        if is_instance_valid(item) and item.has_meta("storage_owner"):
            contained.append(item)
    stored_outline.sync(contained)

func snapshot() -> Dictionary:
    var result := {}
    for body in items:
        if not is_instance_valid(body):
            continue
        # Stored bodies are parented to their cabinet; persist world-space
        # fallback coordinates plus the canonical relative cargo record.
        var pos := body.global_position
        var rot := body.global_rotation
        if not body.has_meta("storage_owner") and (needs_recovery(body) or bool(body.get_meta("recovering", false)) or not body.visible):
            pos = body.get_meta("safe_position", Vector3.ZERO)
            rot = body.get_meta("safe_rotation", Vector3.ZERO)
        if not valid_world_position(pos) or not rot.is_finite():
            continue
        var record := {"position": [pos.x, pos.y, pos.z], "rotation": [rot.x, rot.y, rot.z], "moved": bool(body.get_meta("moved", false))}
        var fridge := body.get_node_or_null("InteractiveFridge") as Fridge
        if fridge != null:
            record["hinges"] = fridge.snapshot()
        if body.has_meta("storage_owner"):
            var storage := body.get_meta("storage_owner") as StorageContents
            if is_instance_valid(storage):
                record["storage"] = storage.serialize_item(body)
        result[str(body.get_meta("prop_id"))] = record
    return result
