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
# Track the fully closed transition independently of cabinet velocity.
var closed_state: Dictionary = {}
const CONTACT_TOLERANCE := 0.015

func configure(owner_body: RigidBody3D) -> void:
    body = owner_body
    body.set_meta("object_type", "container")

func register_compartment(id: String, volume: AABB, closure: HingeController) -> void:
    compartments[id] = {"volume": volume, "closure": closure}
    closed_state[id] = false

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
    # Contact offsets can leave a resting rigid body a few millimeters
    # inside the floor or side wall. Accept that contact, not an object
    # protruding through the doorway. The front face is +Z.
    var minimum := volume.position - Vector3.ONE * CONTACT_TOLERANCE
    var maximum := volume.end + Vector3(CONTACT_TOLERANCE, CONTACT_TOLERANCE, 0.006)
    return extents.position.x >= minimum.x and extents.position.y >= minimum.y and extents.position.z >= minimum.z and extents.end.x <= maximum.x and extents.end.y <= maximum.y and extents.end.z <= maximum.z

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
    # Live contents have already been separated by the physics solver.
    # Overlapping axis-aligned bounds are not evidence of mesh intersection
    # (e.g. two angled tools), and must not prevent securing either item.
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
    # Capture precisely on the first physics tick at full closure (or
    # initial saved-world reconciliation). Never wait for the cabinet to
    # move, and never repeatedly adopt an object through a closed door.
    for id in compartments:
        var slot := str(id)
        var closed_now := is_closed(slot)
        var just_closed := closed_now and not bool(closed_state.get(slot, false))
        closed_state[slot] = closed_now
        if not just_closed:
            continue
        for item in items:
            if not is_instance_valid(item) or item == body or item == held or item.has_meta("storage_owner") or bool(item.get_meta("recovering", false)):
                continue
            var relative := body.global_transform.affine_inverse() * item.global_transform
            if fits(slot, relative, item.get_meta("dimensions", Vector3.ZERO)):
                lock_item(item, slot, relative)

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

