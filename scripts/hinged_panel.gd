extends Node3D
## Reusable hinged panel attached to a single compound rigid body.
## Separate ray-pickable shape, visual pivot, and obstruction-checked motion.
signal fully_closed
signal accessible
const ACCESS_ANGLE := deg_to_rad(70.0)
const OPEN_ANGLE := deg_to_rad(105.0)
const ANGULAR_SPEED := deg_to_rad(120.0)
# Predict contacts before moving the compound door collider, and enforce
# its prescribed surface velocity with contact-point impulses. The same
# angular motor speed is used loaded or unloaded.
const CONTACT_MARGIN := 0.018
const MAX_CONTACT_SPEED := 1.55
const MAX_CORRECTION_SPEED := 0.25
const MAX_IMPULSE_PER_KG := 2.0
const MAX_EXISTING_PENETRATION := 0.055
var body: RigidBody3D
var panel_id := ""
var display_name := ""
var angle := 0.0
var goal := 0.0
var hinge_sign := 1.0
var panel_shape: CollisionShape3D
var local_box := Vector3.ZERO
var busy := false
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
    blocked_frames = 0

func set_saved_angle(value: float) -> void:
    goal = clampf(value, 0.0, OPEN_ANGLE)
    busy = not is_equal_approx(goal, angle)

func step(delta: float) -> void:
    if not busy or delta <= 0.0:
        return
    var next := move_toward(angle, goal, ANGULAR_SPEED * delta)
    var pivot := body.global_transform.affine_inverse() * global_transform
    pivot.basis = Basis(Vector3.UP, next * hinge_sign)
    var current := panel_shape.global_transform
    var proposed := body.global_transform * pivot * Transform3D(Basis.IDENTITY, local_box)
    var query := PhysicsShapeQueryParameters3D.new()
    query.shape = panel_shape.shape
    query.transform = proposed
    query.collision_mask = body.collision_mask
    query.exclude = [body.get_rid()]
    query.margin = CONTACT_MARGIN
    var space := body.get_world_3d().direct_space_state
    var contacts := space.intersect_shape(query, 12)
    var jammed := false
    if not contacts.is_empty():
        blocked_frames += 1
        # Collect individual contact normals; a single aggregate normal
        # can ignore the floor when a second object touches the door.
        var processed: Array[RID] = []
        for contact in contacts:
            var rid: RID = contact["rid"]
            if processed.has(rid):
                continue
            processed.append(rid)
            var excluded: Array[RID] = [body.get_rid()]
            for other in contacts:
                var other_rid: RID = other["rid"]
                if other_rid != rid and not excluded.has(other_rid):
                    excluded.append(other_rid)
            query.exclude = excluded
            var info := space.get_rest_info(query)
            if info.is_empty():
                continue
            var normal: Vector3 = info["normal"]
            if normal.length_squared() < 0.0001:
                continue
            normal = normal.normalized()
            var point: Vector3 = info["point"]
            # Evaluate the actual swept motion of this door point, including
            # the lever arm. At the hinge this approaches zero; at the free
            # edge it is largest. No arbitrary translation or force ramp.
            var point_on_door := proposed.affine_inverse() * point
            var prior_point := current * point_on_door
            var door_velocity := (point - prior_point) / delta
            var approach := maxf(0.0, -door_velocity.dot(normal))
            if approach < 0.002:
                continue
            var obstacle := contact.get("collider") as RigidBody3D
            var target := body
            var push_normal := normal
            if obstacle != null and obstacle.has_meta("prop_id") and not obstacle.has_meta("storage_owner"):
                # Prefer pushing the loose object; if backed against an
                # immovable surface, let the cabinet take the reaction.
                var item_blocked := obstacle.test_move(obstacle.global_transform, -normal * 0.012, null, 0.001)
                if not item_blocked or blocked_frames < 3:
                    target = obstacle
                    push_normal = -normal
            # Measure existing penetration only as a safety guard for a
            # genuinely trapped assembly, not as a wait-for-clearance gate.
            query.transform = current
            query.margin = 0.0
            var pairs := space.collide_shape(query, 8)
            var penetration := 0.0
            for i in range(0, pairs.size() - 1, 2):
                penetration = maxf(penetration, absf((pairs[i] - pairs[i + 1]).dot(normal)))
            query.transform = proposed
            query.margin = CONTACT_MARGIN
            var correction := minf(MAX_CORRECTION_SPEED, penetration * 8.0)
            drive_contact(target, point, push_normal, minf(MAX_CONTACT_SPEED, approach + correction), delta)
            if penetration > MAX_EXISTING_PENETRATION:
                jammed = true
    else:
        blocked_frames = 0
    # In normal contact, advance every frame, not in alternating
    # push/wait increments. The rigid-body contact solver removes the
    # small remaining penetration and supports the cabinet against gravity.
    # Only a seriously embedded/trapped assembly pauses the motor.
    if jammed:
        return
    apply_angle(next)
    busy = not is_equal_approx(angle, goal)

func drive_contact(target: RigidBody3D, point: Vector3, normal: Vector3, target_speed: float, delta: float) -> void:
    if target.freeze:
        target.freeze = false
    target.sleeping = false
    target.set_meta("moved", true)
    var offset := point - target.global_position
    var lever := offset - target.global_transform.basis * target.center_of_mass
    var velocity := target.linear_velocity + target.angular_velocity.cross(lever)
    # Feed forward gravity for an upward contact. No integral wind-up or
    # low-force startup: solve the required normal velocity immediately.
    var gravity: float = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
    var gravity_step := maxf(0.0, normal.y) * gravity * target.gravity_scale * delta
    var change := target_speed + gravity_step - velocity.dot(normal)
    if change <= 0.0:
        return
    # Effective inverse mass at the point of contact includes the
    # rotational response, avoiding excessive lift when tilt suffices.
    var cross := lever.cross(normal)
    var inverse_inertia := target.get_inverse_inertia_tensor()
    var inverse_mass := 1.0 / target.mass
    if not target.lock_rotation:
        inverse_mass += maxf(0.0, cross.dot(inverse_inertia * cross))
    var impulse := minf(change / maxf(inverse_mass, 0.000001), target.mass * MAX_IMPULSE_PER_KG)
    target.apply_impulse(normal * impulse, offset)

func highlight(material: Material) -> void:
    for node in find_children("*", "MeshInstance3D", true, false):
        if not node.has_meta("container_outline"):
            (node as MeshInstance3D).material_overlay = material
