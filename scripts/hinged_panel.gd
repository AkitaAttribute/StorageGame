extends Node3D
## Reusable hinged panel attached to a single compound rigid body.
## Separate ray-pickable shape, visual pivot, and obstruction-checked motion.
const OPEN_ANGLE := deg_to_rad(105.0)
const ANGULAR_SPEED := deg_to_rad(120.0)
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
    angle = clampf(value, 0.0, OPEN_ANGLE)
    rotation.y = angle * hinge_sign
    # Shape belongs to the same rigid body as the cabinet, not a second body.
    # Convert its pivot-relative transform to body coordinates.
    panel_shape.transform = body.global_transform.affine_inverse() * global_transform * Transform3D(Basis.IDENTITY, local_box)

func action_text() -> String:
    return ("Close " if angle > deg_to_rad(2.0) else "Open ") + display_name

func toggle() -> void:
    goal = 0.0 if (goal > 0.01 or angle > deg_to_rad(2.0)) else OPEN_ANGLE
    busy = true

func set_saved_angle(value: float) -> void:
    goal = clampf(value, 0.0, OPEN_ANGLE)
    busy = not is_equal_approx(goal, angle)

func step(delta: float) -> void:
    if not busy:
        return
    # A refrigerator can be picked up with either door open. Do not alter
    # compound inertia while the cabinet is being thrown or moved rapidly.
    if not body.freeze and (body.linear_velocity.length() > 0.12 or body.angular_velocity.length() > 0.12):
        return
    var next := move_toward(angle, goal, ANGULAR_SPEED * delta)
    var pivot := body.global_transform.affine_inverse() * global_transform
    pivot.basis = Basis(Vector3.UP, next * hinge_sign)
    var query := PhysicsShapeQueryParameters3D.new()
    query.shape = panel_shape.shape
    query.transform = body.global_transform * pivot * Transform3D(Basis.IDENTITY, local_box)
    query.collision_mask = body.collision_mask
    query.exclude = [body.get_rid()]
    query.margin = 0.002
    if not body.get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty():
        # Stop at the last clear angle; never sweep through a wall/player.
        goal = angle
        busy = false
        return
    apply_angle(next)
    busy = not is_equal_approx(angle, goal)

func highlight(material: Material) -> void:
    for node in find_children("*", "MeshInstance3D", true, false):
        if not node.has_meta("container_outline"):
            (node as MeshInstance3D).material_overlay = material
