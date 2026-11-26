extends Node3D
## Reusable hinged panel attached to a single compound rigid body.
## Separate ray-pickable shape, visual pivot, and obstruction-checked motion.
signal fully_closed
signal accessible
const ACCESS_ANGLE := deg_to_rad(70.0)
const OPEN_ANGLE := deg_to_rad(105.0)
const ANGULAR_SPEED := deg_to_rad(120.0)
const PUSH_SPEED := 0.95
const PUSH_MARGIN := 0.001
var body: RigidBody3D
var panel_id := ""
var display_name := ""
var angle := 0.0
var goal := 0.0
var hinge_sign := 1.0
var panel_shape: CollisionShape3D
var local_box := Vector3.ZERO
var busy := false

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

func set_saved_angle(value: float) -> void:
    goal = clampf(value, 0.0, OPEN_ANGLE)
    busy = not is_equal_approx(goal, angle)

func step(delta: float) -> void:
    if not busy:
        return
    var next := move_toward(angle, goal, ANGULAR_SPEED * delta)
    var pivot := body.global_transform.affine_inverse() * global_transform
    pivot.basis = Basis(Vector3.UP, next * hinge_sign)
    var current_center := panel_shape.global_position
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
        var sweep := proposed.origin - current_center
        sweep.y = 0.0
        var fallback := sweep.normalized()
        if fallback.length_squared() < 0.0001:
            fallback = body.global_transform.basis.z.normalized()
        # A contact normal points from the obstacle toward the door. Move
        # loose props in the opposite direction; move the cabinet along it
        # for fixed geometry/player. Never cancel the requested goal.
        var info := space.get_rest_info(query)
        var normal: Vector3 = info.get("normal", -fallback)
        normal.y = 0.0
        normal = normal.normalized() if normal.length_squared() > 0.0001 else -fallback
        var distance := clampf(sweep.length() + 0.012, 0.003, PUSH_SPEED * delta)
        var pushed := false
        for contact in contacts:
            var obstacle := contact.get("collider") as RigidBody3D
            if obstacle != null and obstacle.has_meta("prop_id") and not obstacle.has_meta("storage_owner"):
                # Resolve each item's own contact normal, not another
                # object's contact from the aggregate query.
                var other_query := PhysicsShapeQueryParameters3D.new()
                other_query.shape = query.shape
                other_query.transform = query.transform
                other_query.margin = query.margin
                other_query.collision_mask = query.collision_mask
                var excluded: Array[RID] = [body.get_rid()]
                for other in contacts:
                    if other.get("collider") != obstacle:
                        var rid: RID = other["rid"]
                        if not excluded.has(rid):
                            excluded.append(rid)
                other_query.exclude = excluded
                var other_info := space.get_rest_info(other_query)
                var away: Vector3 = -Vector3(other_info.get("normal", normal))
                away.y = 0.0
                if away.length_squared() < 0.0001:
                    away = fallback
                if push_body(obstacle, away.normalized() * distance):
                    pushed = true
                    obstacle.set_meta("moved", true)
            else:
                # Immovable obstruction: the cabinet yields instead.
                pushed = push_body(body, normal * distance) or pushed
                break
        if not pushed:
            # An item backed against a wall can also force the cabinet back.
            pushed = push_body(body, normal * distance)
        if pushed:
            body.set_meta("moved", true)
        # Keep the door at its last clear angle and retry next physics
        # frame after the displaced collider has been synchronized.
        return
    apply_angle(next)
    busy = not is_equal_approx(angle, goal)

func push_body(target: RigidBody3D, motion: Vector3) -> bool:
    if motion.length_squared() < 0.0000001:
        return false
    var start := target.global_position
    # Swept, bounded displacement; never teleport through a floor or wall.
    # Keep the existing dynamic/frozen state, and do not inject throw speed.
    target.move_and_collide(motion, false, PUSH_MARGIN)
    var moved := target.global_position - start
    return moved.dot(motion.normalized()) > 0.0005

func highlight(material: Material) -> void:
    for node in find_children("*", "MeshInstance3D", true, false):
        if not node.has_meta("container_outline"):
            (node as MeshInstance3D).material_overlay = material
