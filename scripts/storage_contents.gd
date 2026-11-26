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
signal contents_changed
var inventory: Node
const CONTACT_TOLERANCE := 0.025

func configure(owner_body: RigidBody3D) -> void:
    body = owner_body
    body.set_meta("object_type", "container")

func register_compartment(id: String, volume: AABB, closure: HingeController) -> void:
    compartments[id] = {"volume": volume, "closure": closure}
    closure.fully_closed.connect(_capture.bind(id))
    closure.accessible.connect(_release_slot.bind(id))

func bind_inventory(owner: Node) -> void:
    inventory = owner

func reconcile_initial_contents() -> void:
    for id in compartments:
        if is_closed(str(id)):
            _capture(str(id))

func is_closed(id: String) -> bool:
    if not compartments.has(id):
        return false
    var closure: HingeController = compartments[id]["closure"]
    return is_zero_approx(closure.angle)

func is_open(id: String) -> bool:
    if not compartments.has(id):
        return false
    var closure: HingeController = compartments[id]["closure"]
    return closure.angle >= OPEN_CLEARANCE

func fits(id: String, local_pose: Transform3D, dimensions: Vector3) -> bool:
    if not compartments.has(id):
        return false
    # Entire item, not just its origin, must fit inside the cabinet.
    return fits_bounds(id, local_pose * AABB(-dimensions * 0.5, dimensions))

func fits_bounds(id: String, extents: AABB) -> bool:
    if not compartments.has(id):
        return false
    var volume: AABB = compartments[id]["volume"]
    # Contact offsets can leave a resting rigid body a few millimeters
    # inside the floor or side wall. Accept that contact, not an object
    # protruding through the doorway. The front face is +Z.
    var minimum := volume.position - Vector3.ONE * CONTACT_TOLERANCE
    var maximum := volume.end + Vector3(CONTACT_TOLERANCE, CONTACT_TOLERANCE, 0.018)
    return extents.position.x >= minimum.x and extents.position.y >= minimum.y and extents.position.z >= minimum.z and extents.end.x <= maximum.x and extents.end.y <= maximum.y and extents.end.z <= maximum.z

# Exact model envelope in cabinet-local coordinates. A rotated padded
# collision box is often wider than a screwdriver's real geometry.
# Cache mesh-space vertices once per item; only transform them on closure,
# save restoration or a specific containment query, never every frame.
func fits_item(id: String, item: RigidBody3D, local_pose: Transform3D) -> bool:
    var points: PackedVector3Array
    if item.has_meta("storage_vertices"):
        points = item.get_meta("storage_vertices")
    else:
        points = PackedVector3Array()
        var inverse := item.global_transform.affine_inverse()
        for node in item.find_children("*", "MeshInstance3D", true, false):
            var mesh_node := node as MeshInstance3D
            if mesh_node.mesh == null or not mesh_node.visible or mesh_node.has_meta("stored_mask"):
                continue
            var to_item := inverse * mesh_node.global_transform
            for vertex in mesh_node.mesh.get_faces():
                points.append(to_item * vertex)
        item.set_meta("storage_vertices", points)
    if points.is_empty():
        return fits(id, local_pose, item.get_meta("dimensions", Vector3.ZERO))
    var extents := AABB(local_pose * points[0], Vector3.ZERO)
    for vertex in points:
        extents = extents.expand(local_pose * vertex)
    return fits_bounds(id, extents)

func slot_for(item: RigidBody3D) -> String:
    var local_pose := body.global_transform.affine_inverse() * item.global_transform
    for id in compartments:
        if fits_item(str(id), item, local_pose):
            return str(id)
    return ""

func lock_item(item: RigidBody3D, id: String, local_pose: Transform3D, restoring: bool = false) -> bool:
    if item == body or item.has_meta("storage_owner") or item.get_meta("object_type", "") == "container":
        return false
    if (not is_closed(id) and (not restoring or is_open(id))) or not fits_item(id, item, local_pose):
        return false
    # Live contents have already been separated by the physics solver.
    # Overlapping axis-aligned bounds are not evidence of mesh intersection
    # (e.g. two angled tools), and must not prevent securing either item.
    locked[item] = {"slot": id, "local": local_pose, "parent": item.get_parent(), "process_mode": item.process_mode}
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
    # Remove the independent physics body from the space, then attach its
    # entire scene (including original meshes) to the cabinet. The scene
    # graph now supplies its world transform without a synchronization loop.
    item.disable_mode = CollisionObject3D.DISABLE_MODE_REMOVE
    item.process_mode = Node.PROCESS_MODE_DISABLED
    item.reparent(self, false)
    item.transform = local_pose
    contents_changed.emit()
    return true

func release_item(item: RigidBody3D) -> void:
    if not locked.has(item):
        return
    var entry: Dictionary = locked[item]
    locked.erase(item)
    if not is_instance_valid(item):
        contents_changed.emit()
        return
    var relative: Transform3D = entry["local"]
    var original_parent: Node = entry["parent"]
    var world_pose := body.global_transform * relative
    item.reparent(original_parent, false)
    item.global_transform = world_pose
    item.remove_meta("storage_owner")
    item.process_mode = int(entry["process_mode"])
    item.collision_layer = PROP_LAYER
    item.collision_mask = BODY_MASK
    item.gravity_scale = 1.0
    item.freeze = false
    item.sleeping = false
    # Inherit both translation and the tangential velocity of cabinet rotation.
    item.linear_velocity = body.linear_velocity + body.angular_velocity.cross(item.global_position - body.global_position)
    item.angular_velocity = body.angular_velocity
    contents_changed.emit()

# These methods run only on hinge signals, never during normal movement.
func _capture(id: String) -> void:
    if not is_instance_valid(inventory) or not inventory.placement_complete or bool(body.get_meta("recovering", false)):
        return
    for item in inventory.items:
        if not is_instance_valid(item) or item == body or item.get_meta("object_type", "") == "container" or item.has_meta("storage_owner") or bool(item.get_meta("recovering", false)):
            continue
        var relative: Transform3D = body.global_transform.affine_inverse() * item.global_transform
        # No sleeping, velocity or floor-contact condition. Capture even a
        # flying/held object if its actual geometry is inside at closure.
        if fits_item(id, item, relative):
            if item == inventory.held:
                inventory.drop()
            lock_item(item, id, relative)

func _release_slot(id: String) -> void:
    for item in locked.keys():
        if str(locked[item]["slot"]) == id:
            release_item(item)

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
    return lock_item(item, str(record.get("slot", "")), Transform3D(Basis.from_euler(local_rotation), local_position), true)

