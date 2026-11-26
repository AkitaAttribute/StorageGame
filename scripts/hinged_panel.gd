extends Node3D
## Reusable hinged panel attached to a single compound rigid body.
## Separate ray-pickable shape, visual pivot, and obstruction-checked motion.
signal fully_closed
signal accessible
const ACCESS_ANGLE := deg_to_rad(70.0)
const OPEN_ANGLE := deg_to_rad(105.0)
const ANGULAR_SPEED := deg_to_rad(120.0)
# The motor is velocity limited, not a fixed displacement. A blocked
# hinge develops slowly increasing force until the obstruction yields.
const CONTACT_SPEED := 0.18
const CONTACT_GAIN := 24.0
const CONTACT_RAMP := 8.0
const PUSH_MARGIN := 0.001
# A finite numerical guard, not a gameplay torque setting.
const MAX_LOAD_ACCELERATION := 120.0
var body: RigidBody3D
var panel_id := ""
var display_name := ""
var angle := 0.0
var goal := 0.0
var hinge_sign := 1.0
var panel_shape: CollisionShape3D
var local_box := Vector3.ZERO
var busy := false
var load_acceleration := 0.0
var blocked_frames := 0

func configure(owner_body: RigidBody3D, id: String, label: String, hinge: Vector3, center: Vector3, dimensions: Vector3, sign_value: float = 1.0) -> void:
    body = owner_body
    panel_id = id
    display_name = label
    hinge_sign = sign_value
    position = hinge
    local_box = center
    panel_shape = CollisionShape3D.new()
    panel_shape.name = "Hinge_" + id
    var shape := BoxShape3D.new()
    shape.size = dimensions
    panel_shape.shape = shape
    panel_shape.set_meta("hinge_panel", self)
    body.add_child(panel_shape)
    apply_angle(0.0)

func apply_angle(value: float) -> void:
    var previous := angle
    angle = clampf(value, 0.0, OPEN_ANGLE)
    rotation.y = angle * hinge_sign
    # Shape belongs to the same rigid body as the cabinet, not a second body.
    # Convert its pivot-relative transform to body coordinates.
    panel_shape.transform = body.global_transform.affine_inverse() * global_transform * Transform3D(Basis.IDENTITY, local_box)
    if previous > 0.0 and is_zero_approx(angle):
        fully_closed.emit()
    if previous < ACCESS_ANGLE and angle >= ACCESS_ANGLE:
        accessible.emit()

func action_text() -> String:
    var opening := goal > 0.01 if busy else angle > deg_to_rad(2.0)
    return ("Close " if opening else "Open ") + display_name

func toggle() -> void:
    var opening := goal > 0.01 if busy else angle > deg_to_rad(2.0)
    goal = 0.0 if opening else OPEN_ANGLE
    busy = true
    load_acceleration = 0.0
    blocked_frames = 0

func set_saved_angle(value: float) -> void:
    goal = clampf(value, 0.0, OPEN_ANGLE)
    busy = not is_equal_approx(goal, angle)

func step(delta: float) -> void:
    if not busy:
        return
    var next := move_toward(angle, goal, ANGULAR_SPEED * delta)
    var pivot := body.global_transform.affine_inverse() * global_transform
    pivot.basis = Basis(Vector3.UP, next * hinge_sign)
    var proposed := body.global_transform * pivot * Transform3D(Basis.IDENTITY, local_box)
    var query := PhysicsShapeQueryParameters3D.new()
    query.shape = panel_shape.shape
    query.transform = proposed
    query.collision_mask = body.collision_mask
    query.exclude = [body.get_rid()]
    query.margin = PUSH_MARGIN
    var space := body.get_world_3d().direct_space_state
    var contacts := space.intersect_shape(query, 16)
    if not contacts.is_empty():
        blocked_frames += 1
        # Work at one actual contact per step. The physics solver handles
        # gravity, friction, translation and angular response. Never flatten
        # the normal to the ground plane or directly translate the cabinet.
        var info := space.get_rest_info(query)
        if info.is_empty():
            return
        var normal: Vector3 = info["normal"]
        var point: Vector3 = info["point"]
        var rid: RID = info["rid"]
        var obstacle: RigidBody3D = null
        for contact in contacts:
            if contact["rid"] == rid:
                obstacle = contact.get("collider") as RigidBody3D
                break
        if normal.length_squared() < 0.0001:
            return
        normal = normal.normalized()
        # Prefer moving an ordinary loose item. If it is backed into a solid,
        # apply the equal/opposite reaction to the cabinet instead.
        if obstacle != null and obstacle.has_meta("prop_id") and not obstacle.has_meta("storage_owner"):
            var away := -normal
            var blocked := obstacle.test_move(obstacle.global_transform, away * 0.012, null, PUSH_MARGIN)
            if not blocked or blocked_frames < 12:
                drive_contact(obstacle, point, away, delta)
            else:
                drive_contact(body, point, normal, delta)
        else:
            drive_contact(body, point, normal, delta)
        # Wait for actual physical clearance before advancing the hinge.
        # The target remains pending even if both bodies are trapped.
        return
    blocked_frames = 0
    load_acceleration = 0.0
    apply_angle(next)
    busy = not is_equal_approx(angle, goal)

func drive_contact(target: RigidBody3D, point: Vector3, normal: Vector3, delta: float) -> void:
    if target.freeze:
        target.freeze = false
    target.sleeping = false
    target.set_meta("moved", true)
    # Contact-point velocity includes the body's angular movement. The
    # force is applied off-center at the obstruction, generating a natural
    # moment about the center of mass and allowing the fridge to lift/tilt.
    var lever := point - target.global_position
    var velocity := target.linear_velocity + target.angular_velocity.cross(lever)
    var normal_speed := velocity.dot(normal)
    var error := CONTACT_SPEED - normal_speed
    # A slow integral ramp overcomes static friction or gravity if the
    # contact remains stalled. Unload immediately as the contact yields.
    # Keep a high finite ceiling to avoid a numerical explosion if trapped.
    if error > 0.0:
        load_acceleration = minf(MAX_LOAD_ACCELERATION, load_acceleration + CONTACT_RAMP * delta)
    else:
        load_acceleration = maxf(0.0, load_acceleration - CONTACT_RAMP * 4.0 * delta)
    var acceleration := maxf(0.0, CONTACT_GAIN * error + load_acceleration)
    if normal_speed >= CONTACT_SPEED:
        acceleration = 0.0
    # Do not apply a displacement or an arbitrary lateral kick. Contact
    # force is the sole source of reaction movement.
    if acceleration > 0.0:
        target.apply_force(normal * target.mass * acceleration, lever)

func highlight(material: Material) -> void:
    for node in find_children("*", "MeshInstance3D", true, false):
        if not node.has_meta("container_outline"):
            (node as MeshInstance3D).material_overlay = material
