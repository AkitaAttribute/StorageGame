extends Node3D
## Reusable portable container. Compartments are local-space volumes associated
## with independent closures. Each stored item retains a full relative transform.
const HingeController = preload("res://scripts/hinged_panel.gd")
const OPEN_CLEARANCE := deg_to_rad(70.0)
const CLOSED_EPSILON := 0.005
const PROP_LAYER := 2
const BODY_MASK := 11
var body: RigidBody3D
var compartments: Dictionary = {}
var locked: Dictionary = {}

func configure(owner_body: RigidBody3D) -> void:
    body = owner_body
    body.set_meta("object_type", "container")

func register_compartment(id: String, volume: AABB, closure: HingeController) -> void:
    compartments[id] = {"volume": volume, "closure": closure}

func is_closed(id: String) -> bool:
    if not compartments.has(id):
        return false
    var closure: HingeController = compartments[id]["closure"]
    return closure.angle <= CLOSED_EPSILON and not closure.busy

func is_open(id: String) -> bool:
    if not compartments.has(id):
        return false
    var closure: HingeController = compartments[id]["closure"]
    return closure.angle >= OPEN_CLEARANCE

func fits(id: String, local_pose: Transform3D, dimensions: Vector3) -> bool:
    if not compartments.has(id):
        return false
    # Entire item, not just its origin, must fit inside the cabinet.
    var volume: AABB = compartments[id]["volume"]
    var extents := local_pose * AABB(-dimensions * 0.5, dimensions)
    return volume.grow(0.003).encloses(extents)

func slot_for(item: RigidBody3D) -> String:
    var dimensions: Vector3 = item.get_meta("dimensions", Vector3.ZERO)
    var local_pose := body.global_transform.affine_inverse() * item.global_transform
    for id in compartments:
        if fits(str(id), local_pose, dimensions):
            return str(id)
    return ""

func lock_item(item: RigidBody3D, id: String, local_pose: Transform3D) -> bool:
    if item == body or item.has_meta("storage_owner") or item.get_meta("object_type", "") == "container":
        return false
    var dimensions: Vector3 = item.get_meta("dimensions", Vector3.ZERO)
    if not is_closed(id) or not fits(id, local_pose, dimensions):
        return false
    var bounds := local_pose * AABB(-dimensions * 0.5, dimensions)
    for other in locked:
        if not is_instance_valid(other):
            continue
        var other_pose: Transform3D = locked[other]["local"]
        var other_dimensions: Vector3 = other.get_meta("dimensions")
        var other_bounds := other_pose * AABB(-other_dimensions * 0.5, other_dimensions)
        if bounds.grow(-0.004).intersects(other_bounds.grow(-0.004)):
            return false
    locked[item] = {"slot": id, "local": local_pose}
    item.set_meta("storage_owner", self)
    item.set_meta("moved", true)
    # No active contact solver for cargo in a closed compartment: otherwise
    # the moving cabinet and trapped items can impart explosive impulses.
    item.freeze = true
    item.collision_layer = 0
    item.collision_mask = 0
    item.gravity_scale = 0.0
    item.linear_velocity = Vector3.ZERO
    item.angular_velocity = Vector3.ZERO
    item.global_transform = body.global_transform * local_pose
    return true

func release_item(item: RigidBody3D) -> void:
    if not locked.has(item):
        return
    var relative: Transform3D = locked[item]["local"]
    locked.erase(item)
    if not is_instance_valid(item):
        return
    item.remove_meta("storage_owner")
    item.global_transform = body.global_transform * relative
    item.collision_layer = PROP_LAYER
    item.collision_mask = BODY_MASK
    item.gravity_scale = 1.0
    item.freeze = false
    item.sleeping = false
    # Inherit both translation and the tangential velocity of cabinet rotation.
    item.linear_velocity = body.linear_velocity + body.angular_velocity.cross(item.global_position - body.global_position)
    item.angular_velocity = body.angular_velocity

func sync_items() -> void:
    for item in locked.keys():
        if not is_instance_valid(item):
            locked.erase(item)
            continue
        var relative: Transform3D = locked[item]["local"]
        item.global_transform = body.global_transform * relative

func tick(items: Array[RigidBody3D], held: RigidBody3D) -> void:
    sync_items()
    for item in locked.keys():
        if is_open(str(locked[item]["slot"])):
            release_item(item)
    for item in items:
        if not is_instance_valid(item) or item == body or item == held or item.has_meta("storage_owner") or bool(item.get_meta("recovering", false)):
            continue
        var slot := slot_for(item)
        if not slot.is_empty() and is_closed(slot):
            lock_item(item, slot, body.global_transform.affine_inverse() * item.global_transform)

func serialize_item(item: RigidBody3D) -> Dictionary:
    if not locked.has(item):
        return {}
    var local_pose: Transform3D = locked[item]["local"]
    var pos := local_pose.origin
    var rot := local_pose.basis.get_euler()
    return {"owner": str(body.get_meta("prop_id")), "slot": str(locked[item]["slot"]), "position": [pos.x, pos.y, pos.z], "rotation": [rot.x, rot.y, rot.z]}

func restore_item(item: RigidBody3D, record: Dictionary) -> bool:
    var pos: Variant = record.get("position", [])
    var rot: Variant = record.get("rotation", [])
    if not pos is Array or not rot is Array or pos.size() != 3 or rot.size() != 3:
        return false
    var local_position := Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
    var local_rotation := Vector3(float(rot[0]), float(rot[1]), float(rot[2]))
    if not local_position.is_finite() or not local_rotation.is_finite():
        return false
    return lock_item(item, str(record.get("slot", "")), Transform3D(Basis.from_euler(local_rotation), local_position))

