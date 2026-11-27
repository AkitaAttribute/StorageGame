extends RefCounted
## Bone-based secondary collision approximations: preserve the authored
## skin and constrain actual hair/skirt chains, not a world physics cloth.
var skeleton: Skeleton3D
var rig: RefCounted
var visual: Node3D
var groups: Dictionary = {"HAIR": [], "SKIRT": []}
var last_pose: Dictionary = {}
var skirt_half_width := 0.0
# Low-resolution surface samples of the actual skinned fabric. The
# waist stays attached; the lower skirt can yield inward to the hand.
const HAND_MARGIN := 0.012
const MAX_COMPRESSION := 0.065
var skirt_samples: Array[Dictionary] = []
var torso_samples: Array[Dictionary] = []
var torso_residual: Dictionary = {"left": 0.0, "right": 0.0}
var forearm_residual: Dictionary = {"left": 0.0, "right": 0.0}
var last_torso_overlap := 0.0
# Match the renderer's skinning transform instead of estimating limb
# radius around rest joints which need not coincide with the skin bind.
const BODY_MARGIN := 0.004
const BODY_CELL := 0.025
var arm_samples: Dictionary = {}
var arm_surface_counts: Dictionary = {}
var arm_evaluated_counts: Dictionary = {}
var arm_bone_keys: Dictionary = {}
var torso_grid: Dictionary = {}
var torso_triangle_vertices: Array[Dictionary] = []
var torso_triangles: Array[Vector3i] = []
var torso_triangle_grid: Dictionary = {}
var live_torso_vertices := PackedVector3Array()
var shoulder_pitch: Dictionary = {"left": 0.0, "right": 0.0}
var shoulder_state: Dictionary = {"left": "", "right": ""}
var shoulder_release_clock: Dictionary = {"left": 0.0, "right": 0.0}
var shoulder_search_clock: Dictionary = {"left": 0.0, "right": 0.0}
var torso_grid_bones: Dictionary = {}
var torso_grid_meshes: Dictionary = {}
var torso_grid_valid := false
var skirt_sample_bones: Dictionary = {}
var skirt_rest_positions: Dictionary = {}
var skirt_compression: Dictionary = {"left": 0.0, "right": 0.0}
var arm_residual: Dictionary = {"left": 0.0, "right": 0.0}
var last_contact_overlap := 0.0
var last_contact_compression := 0.0

func setup(retargeter: RefCounted, root: Node3D, avatar: Node3D) -> void:
    rig = retargeter
    skeleton = rig.target
    visual = root
    for i in range(skeleton.get_bone_count()):
        var name := str(skeleton.get_bone_name(i))
        for group in groups:
            if name.begins_with("SEC_" + str(group) + "_"):
                groups[group].append(i)
                last_pose[i] = skeleton.get_bone_rest(i).basis.get_rotation_quaternion()
    var hips: int = rig.target_keys["hips"]
    var pelvis := common_rest(hips)
    for i in groups["SKIRT"]:
        skirt_half_width = maxf(skirt_half_width, absf(common_rest(i).x - pelvis.x) + 0.025)
    skirt_half_width = clampf(skirt_half_width, 0.17, 0.26)
    for bone in groups["SKIRT"]:
        skirt_rest_positions[bone] = skeleton.get_bone_rest(bone).origin
    for side in ["left", "right"]:
        for suffix in ["UpperArm", "LowerArm"]:
            var key: String = str(side) + str(suffix)
            var bone: int = rig.target_keys[key]
            arm_bone_keys[bone] = key
            arm_samples[key] = []
            arm_evaluated_counts[key] = 0
    cache_skirt_surface(avatar)
    for key in arm_samples:
        arm_surface_counts[key] = arm_samples[key].size()
    # Cache only dependencies of the torso, not the entire skeleton.
    for sample in torso_triangle_vertices:
        for bone in sample["ids"]:
            torso_grid_bones[bone] = Transform3D.IDENTITY
        torso_grid_meshes[sample["mesh"]] = Transform3D.IDENTITY
    for sample in torso_samples:
        for bone in sample["ids"]:
            torso_grid_bones[bone] = Transform3D.IDENTITY
        torso_grid_meshes[sample["mesh"]] = Transform3D.IDENTITY
    print("ARM_SURFACE_SAMPLES ", arm_surface_counts, " torso_triangles=", torso_triangles.size())
    print("SECONDARY_COLLISION hair=", groups["HAIR"].size(), " skirt=", groups["SKIRT"].size(), " skirt_width=", skirt_half_width, " surface_samples=", skirt_samples.size(), " torso_samples=", torso_samples.size())

# Cache a spatially decimated set of actual skin-weighted fabric
# vertices, including their influences on pelvis and skirt bones.
# Rest-to-pose transforms then follow the live deforming skirt.
func cache_skirt_surface(avatar: Node3D) -> void:
    var occupied: Dictionary = {}
    var torso_occupied: Dictionary = {}
    var arm_occupied: Dictionary = {}
    var torso_bones: Array[int] = []
    for key in ["hips", "spine", "chest", "upperChest"]:
        if rig.target_keys.has(key):
            torso_bones.append(int(rig.target_keys[key]))
    var pelvis := common_rest(int(rig.target_keys["hips"]))
    var shoulder_y := (common_rest(int(rig.target_keys["leftUpperArm"])).y + common_rest(int(rig.target_keys["rightUpperArm"])).y) * 0.5 - pelvis.y
    var shoulder_width := absf(common_rest(int(rig.target_keys["leftUpperArm"])).x - common_rest(int(rig.target_keys["rightUpperArm"])).x) * 0.5
    for node in avatar.find_children("*", "MeshInstance3D", true, false):
        var mesh_node := node as MeshInstance3D
        var skin := mesh_node.skin
        if mesh_node.mesh == null or skin == null:
            continue
        var binds: Dictionary = {}
        for i in range(skin.get_bind_count()):
            var name := str(skin.get_bind_name(i))
            var bone := skeleton.find_bone(name) if not name.is_empty() else skin.get_bind_bone(i)
            if bone >= 0 and bone < skeleton.get_bone_count():
                binds[i] = bone
        for surface in range(mesh_node.mesh.get_surface_count()):
            var arrays := mesh_node.mesh.surface_get_arrays(surface)
            if arrays[Mesh.ARRAY_BONES] == null or arrays[Mesh.ARRAY_WEIGHTS] == null:
                continue
            var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
            var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
            var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
            if vertices.is_empty() or bones.is_empty() or weights.size() != bones.size():
                continue
            var stride := int(bones.size() / vertices.size())
            var triangle_vertex_ids: Dictionary = {}
            for i in range(vertices.size()):
                var ids: Array[int] = []
                var amounts: Array[float] = []
                var bind_points: Array[Vector3] = []
                var arm_key := ""
                var arm_weight := 0.0
                var influence := 0.0
                var torso_influence := 0.0
                var total := 0.0
                for j in range(stride):
                    var bind := bones[i * stride + j]
                    var weight := weights[i * stride + j]
                    if weight <= 0.0001 or not binds.has(bind):
                        continue
                    var bone: int = binds[bind]
                    ids.append(bone)
                    amounts.append(weight)
                    bind_points.append(skin.get_bind_pose(bind) * vertices[i])
                    if arm_bone_keys.has(bone) and weight > arm_weight:
                        arm_weight = weight
                        arm_key = str(arm_bone_keys[bone])
                    total += weight
                    if groups["SKIRT"].has(bone):
                        influence += weight
                    if torso_bones.has(bone):
                        torso_influence += weight
                if total < 0.001:
                    continue
                var local := skeleton.to_local(mesh_node.to_global(vertices[i]))
                var common: Vector3 = rig.target_basis * local * float(rig.target_scale)
                # Keep a decimated surface for each arm. Use the actual
                # inverse bind matrices per influence, not inverse rest
                # transforms. Retain joint-blend weights in the sample.
                var rendered_sample := {"ids": ids, "weights": amounts, "total": total, "bind_points": bind_points, "mesh": mesh_node}
                # A connected armhole is not a pair of independent
                # colliding surfaces. Retain arm-owned vertices, including
                # the upper/lower arm transition, not torso-owned cloth.
                if arm_weight >= 0.45 and torso_influence <= 0.15:
                    var arm_cell := Vector3i(roundi(common.x / 0.012), roundi(common.y / 0.012), roundi(common.z / 0.012))
                    var arm_id := arm_key + str(arm_cell)
                    if not arm_occupied.has(arm_id):
                        arm_occupied[arm_id] = true
                        arm_samples[arm_key].append(rendered_sample)
                if influence < 0.25 and torso_influence < 0.90:
                    continue
                var p: Vector3 = common - pelvis
                var cell := Vector3i(roundi(p.x / 0.018), roundi(p.y / 0.018), roundi(p.z / 0.018))
                var garment := influence >= 0.25 and absf(p.x) <= 0.45 and absf(p.z) <= 0.40 and p.y <= 0.20 and p.y >= -0.65
                # Exclude the moving armhole/sleeve attachment from the fixed
                # torso surface; its skin is intentionally continuous with
                # the shoulder. Keep the ribs and waist, including sides.
                var body := torso_influence >= 0.90 and influence < 0.05 and absf(p.x) <= shoulder_width and absf(p.z) <= 0.30 and p.y >= -0.04 and p.y <= shoulder_y - 0.055
                if body:
                    triangle_vertex_ids[i] = torso_triangle_vertices.size()
                    torso_triangle_vertices.append(rendered_sample)
                var add_skirt := garment and not occupied.has(cell)
                var add_torso := body and not torso_occupied.has(cell)
                if not add_skirt and not add_torso:
                    continue
                for bone in ids:
                    skirt_sample_bones[bone] = skeleton.get_bone_global_rest(bone).affine_inverse()
                var sample := {"point": local, "ids": ids, "weights": amounts, "total": total}
                if add_skirt:
                    occupied[cell] = true
                    skirt_samples.append(sample)
                if add_torso:
                    torso_occupied[cell] = true
                    torso_samples.append(rendered_sample)
            # Keep the real connected triangles. No interpolation between
            # unrelated surface points, which can overestimate body width.
            if mesh_node.mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
                continue
            var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
            var count := vertices.size() if indices.is_empty() else indices.size()
            for i in range(0, count - 2, 3):
                var a := i if indices.is_empty() else indices[i]
                var b := i + 1 if indices.is_empty() else indices[i + 1]
                var c := i + 2 if indices.is_empty() else indices[i + 2]
                if triangle_vertex_ids.has(a) and triangle_vertex_ids.has(b) and triangle_vertex_ids.has(c):
                    torso_triangles.append(Vector3i(int(triangle_vertex_ids[a]), int(triangle_vertex_ids[b]), int(triangle_vertex_ids[c])))

# Godot Skeleton3D supplies the renderer with global bone pose times
# Skin bind pose. Evaluate the same linear blend at sampled vertices.
func rendered_surface(samples: Array) -> PackedVector3Array:
    var output := PackedVector3Array()
    var poses: Dictionary = {}
    var mesh_transforms: Dictionary = {}
    var view_inverse := visual.global_transform.affine_inverse()
    for sample in samples:
        var ids: Array = sample["ids"]
        var weights: Array = sample["weights"]
        var points: Array = sample["bind_points"]
        var mesh_node: MeshInstance3D = sample["mesh"]
        if not mesh_transforms.has(mesh_node):
            mesh_transforms[mesh_node] = view_inverse * mesh_node.global_transform
        var mesh_to_visual: Transform3D = mesh_transforms[mesh_node]
        var point := Vector3.ZERO
        for i in range(ids.size()):
            var bone: int = ids[i]
            if not poses.has(bone):
                poses[bone] = skeleton.get_bone_global_pose(bone)
            var pose: Transform3D = poses[bone]
            var bind_point: Vector3 = points[i]
            point += (pose * bind_point) * float(weights[i])
        output.append(mesh_to_visual * (point / float(sample["total"])))
    return output

func refresh_torso_grid() -> void:
    # Reuse the exact mesh grid while the driving transforms are stable.
    # A small sub-millimetre tolerance avoids rebuilding for numerical
    # roundoff in a stationary character. Hair/skirt movement is irrelevant.
    var dirty := not torso_grid_valid
    for bone in torso_grid_bones:
        var current := skeleton.get_bone_global_pose(bone)
        var cached: Transform3D = torso_grid_bones[bone]
        if current.origin.distance_squared_to(cached.origin) > 0.00000001 or not current.basis.is_equal_approx(cached.basis):
            dirty = true
            break
    if not dirty:
        for mesh_node in torso_grid_meshes:
            var current: Transform3D = visual.global_transform.affine_inverse() * mesh_node.global_transform
            var cached: Transform3D = torso_grid_meshes[mesh_node]
            if current.origin.distance_squared_to(cached.origin) > 0.00000001 or not current.basis.is_equal_approx(cached.basis):
                dirty = true
                break
    if not dirty:
        return
    for bone in torso_grid_bones:
        torso_grid_bones[bone] = skeleton.get_bone_global_pose(bone)
    for mesh_node in torso_grid_meshes:
        torso_grid_meshes[mesh_node] = visual.global_transform.affine_inverse() * mesh_node.global_transform
    torso_grid_valid = true
    torso_grid.clear()
    torso_triangle_grid.clear()
    live_torso_vertices = rendered_surface(torso_triangle_vertices)
    for triangle in torso_triangles:
        var a := live_torso_vertices[triangle.x]
        var b := live_torso_vertices[triangle.y]
        var c := live_torso_vertices[triangle.z]
        var low := Vector2i(floori(minf(a.y, minf(b.y, c.y)) / BODY_CELL), floori(minf(a.z, minf(b.z, c.z)) / BODY_CELL))
        var high := Vector2i(floori(maxf(a.y, maxf(b.y, c.y)) / BODY_CELL), floori(maxf(a.z, maxf(b.z, c.z)) / BODY_CELL))
        for y in range(low.x, high.x + 1):
            for z in range(low.y, high.y + 1):
                var cell := Vector2i(y, z)
                if not torso_triangle_grid.has(cell):
                    torso_triangle_grid[cell] = []
                torso_triangle_grid[cell].append(triangle)
    for point in rendered_surface(torso_samples):
        var cell := Vector2i(floori(point.y / BODY_CELL), floori(point.z / BODY_CELL))
        if not torso_grid.has(cell):
            torso_grid[cell] = PackedVector3Array()
        var bucket: PackedVector3Array = torso_grid[cell]
        bucket.append(point)
        torso_grid[cell] = bucket

func skirt_surface() -> PackedVector3Array:
    return skinned_surface(skirt_samples)

func skinned_surface(samples: Array[Dictionary]) -> PackedVector3Array:
    var result := PackedVector3Array()
    var transforms: Dictionary = {}
    var to_visual := visual.global_transform.affine_inverse() * skeleton.global_transform
    for bone in skirt_sample_bones:
        var inverse_rest: Transform3D = skirt_sample_bones[bone]
        transforms[bone] = to_visual * skeleton.get_bone_global_pose(bone) * inverse_rest
    for sample in samples:
        var p: Vector3 = sample["point"]
        var ids: Array = sample["ids"]
        var weights: Array = sample["weights"]
        var pos := Vector3.ZERO
        for i in range(ids.size()):
            var transform: Transform3D = transforms[ids[i]]
            pos += (transform * p) * float(weights[i])
        result.append(pos / float(sample["total"]))
    return result

# Compare the actual rendered arm surface to the actual rendered torso
# at matching height/depth. The proximal sleeve is attached to the
# shoulder; only the distal upper arm and free forearm are constrained.
func arm_body_overlap(side: String, sign_side: float, forearm: bool) -> float:
    var key := side + ("LowerArm" if forearm else "UpperArm")
    var a := at(key)
    var b := at(side + ("Hand" if forearm else "LowerArm"))
    var axis := b - a
    var center := at("hips")
    var overlap := 0.0
    var evaluated := 0
    for point in rendered_surface(arm_samples[key]):
        var t := (point - a).dot(axis) / maxf(axis.length_squared(), 0.000001)
        if t < (0.12 if forearm else 0.48) or t > 1.15:
            continue
        evaluated += 1
        var cell := Vector2i(floori(point.y / BODY_CELL), floori(point.z / BODY_CELL))
        var has_surface := false
        # Cast a lateral ray through the actual skinned torso triangles.
        # Barycentric interpolation at exactly this y/z avoids treating
        # a wider rib section 17 mm away as the current surface.
        for triangle in torso_triangle_grid.get(cell, []):
            var a3 := live_torso_vertices[triangle.x]
            var b3 := live_torso_vertices[triangle.y]
            var c3 := live_torso_vertices[triangle.z]
            var u := Vector2(b3.y - a3.y, b3.z - a3.z)
            var v := Vector2(c3.y - a3.y, c3.z - a3.z)
            var p := Vector2(point.y - a3.y, point.z - a3.z)
            var determinant := u.cross(v)
            if absf(determinant) < 0.00000001:
                continue
            var alpha := p.cross(v) / determinant
            var beta := u.cross(p) / determinant
            if alpha < -0.0001 or beta < -0.0001 or alpha + beta > 1.0001:
                continue
            var x := a3.x + alpha * (b3.x - a3.x) + beta * (c3.x - a3.x)
            if (x - center.x) * sign_side < 0.0:
                continue
            has_surface = true
            overlap = maxf(overlap, (x - point.x) * sign_side + BODY_MARGIN)
        # The filtered torso has open sleeve/waist boundaries. Preserve
        # contact against nearby sampled vertices at those boundaries.
        if not has_surface:
            for dy in range(-1, 2):
                for dz in range(-1, 2):
                    var bucket: PackedVector3Array = torso_grid.get(cell + Vector2i(dy, dz), PackedVector3Array())
                    for cloth in bucket:
                        if (cloth.x - center.x) * sign_side < 0.0:
                            continue
                        if Vector2(cloth.y - point.y, cloth.z - point.z).length() > 0.006:
                            continue
                        overlap = maxf(overlap, (cloth.x - point.x) * sign_side + BODY_MARGIN)
    arm_evaluated_counts[key] = evaluated
    return overlap

func rotate_forearm(side: String, sign_side: float, angle: float) -> void:
    if angle <= 0.00001:
        return
    var bone: int = rig.target_keys[side + "LowerArm"]
    var hand: int = rig.target_keys[side + "Hand"]
    var common: Basis = rig.target_basis
    var axis := skeleton.get_bone_global_pose(hand).origin - skeleton.get_bone_global_pose(bone).origin
    var rotation := common.inverse() * Basis(Vector3.BACK, sign_side * angle) * common
    rig.aim_arm_bone(bone, hand, rotation * axis, 1.0)

func apply_shoulder_candidate(gait: RefCounted, bone: int, base: Quaternion, sign_side: float, lateral: float, sagittal: float) -> void:
    skeleton.set_bone_pose_rotation(bone, base)
    skeleton.force_update_all_bone_transforms()
    var common: Basis = rig.target_basis
    var pose := skeleton.get_bone_global_pose(bone).basis.orthonormalized()
    var correction := Basis(Vector3.RIGHT, sagittal) * Basis(Vector3.BACK, sign_side * lateral)
    gait.set_global_rotation(bone, common.inverse() * correction * common * pose, 1.0)

func solve_arm_torso(delta: float, gait: RefCounted, holding: bool) -> void:
    if torso_samples.is_empty():
        return
    refresh_torso_grid()
    last_torso_overlap = 0.0
    for side in ["left", "right"]:
        if holding and side == "right":
            torso_residual[side] = 0.0
            shoulder_pitch[side] = 0.0
            shoulder_state[side] = ""
            forearm_residual[side] = 0.0
            continue
        var sign_side: float = gait.arm_sides[side]
        # The base animation resets the pose each tick. Reuse the last
        # contact solution rather than searching the full angle grid every
        # time a gradual release enters the surface by a fraction of a mm.
        var bone: int = rig.target_keys[side + "UpperArm"]
        var base := skeleton.get_bone_pose_rotation(bone)
        var state: String = gait.arm_state
        var state_changed := str(shoulder_state[side]) != state
        shoulder_state[side] = state
        var shoulder_offset: float = torso_residual[side]
        var pitch: float = shoulder_pitch[side]
        if state_changed:
            shoulder_offset = 0.0
            pitch = 0.0
            shoulder_search_clock[side] = 0.0
        shoulder_release_clock[side] = float(shoulder_release_clock[side]) + delta
        shoulder_search_clock[side] = maxf(0.0, float(shoulder_search_clock[side]) - delta)
        apply_shoulder_candidate(gait, bone, base, sign_side, shoulder_offset, pitch)
        var contact := arm_body_overlap(side, sign_side, false)
        var best := Vector2(shoulder_offset, pitch)
        var best_overlap := contact
        # Occasionally try releasing toward neutral. Reject the candidate
        # if it would re-enter the torso, so resting contact stays steady.
        if contact <= 0.001 and float(shoulder_release_clock[side]) >= 0.25:
            shoulder_release_clock[side] = 0.0
            var candidate := Vector2(maxf(0.0, shoulder_offset - deg_to_rad(1.0)), move_toward(pitch, 0.0, deg_to_rad(1.0)))
            if not candidate.is_equal_approx(best):
                apply_shoulder_candidate(gait, bone, base, sign_side, candidate.x, candidate.y)
                var error := arm_body_overlap(side, sign_side, false)
                if error <= 0.001:
                    best = candidate
                    best_overlap = error
        if best_overlap > 0.001:
            # Local contact correction normally needs only a few candidate
            # evaluations. A full bounded search is reserved for initial
            # entry or a persistent error, at most once per quarter second.
            for step in [2.0, 4.0]:
                var origin := best
                for change in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1), Vector2(1, 1), Vector2(1, -1)]:
                    var candidate: Vector2 = origin + change * deg_to_rad(float(step))
                    candidate.x = clampf(candidate.x, 0.0, deg_to_rad(28.0))
                    candidate.y = clampf(candidate.y, -deg_to_rad(24.0), deg_to_rad(24.0))
                    apply_shoulder_candidate(gait, bone, base, sign_side, candidate.x, candidate.y)
                    var error := arm_body_overlap(side, sign_side, false)
                    if error < best_overlap:
                        best = candidate
                        best_overlap = error
                if best_overlap <= 0.001:
                    break
            if best_overlap > 0.001 and float(shoulder_search_clock[side]) <= 0.0:
                shoulder_search_clock[side] = 0.25
                var best_cost := 1000.0
                for lateral in [0.0, 4.0, 8.0, 12.0, 16.0, 20.0, 24.0, 28.0]:
                    for sagittal in [0.0, -8.0, 8.0, -16.0, 16.0, -24.0, 24.0]:
                        var cost := float(lateral) * 1.5 + absf(float(sagittal))
                        if best_overlap <= 0.001 and cost >= best_cost:
                            continue
                        var candidate := Vector2(deg_to_rad(float(lateral)), deg_to_rad(float(sagittal)))
                        apply_shoulder_candidate(gait, bone, base, sign_side, candidate.x, candidate.y)
                        var error := arm_body_overlap(side, sign_side, false)
                        if (error <= 0.001 and (best_overlap > 0.001 or cost < best_cost)) or (best_overlap > 0.001 and error < best_overlap):
                            best = candidate
                            best_overlap = error
                            best_cost = cost
        apply_shoulder_candidate(gait, bone, base, sign_side, best.x, best.y)
        torso_residual[side] = best.x
        shoulder_pitch[side] = best.y
        var elbow_offset := maxf(0.0, float(forearm_residual[side]) - delta * deg_to_rad(55.0))
        rotate_forearm(side, sign_side, elbow_offset)
        for iteration in range(6):
            var overlap := arm_body_overlap(side, sign_side, true)
            if overlap <= 0.001 or elbow_offset >= deg_to_rad(20.0):
                break
            var step := minf(deg_to_rad(20.0) - elbow_offset, clampf(overlap / 0.23, deg_to_rad(0.4), deg_to_rad(6.0)))
            rotate_forearm(side, sign_side, step)
            elbow_offset += step
        forearm_residual[side] = elbow_offset
        last_torso_overlap = maxf(last_torso_overlap, maxf(arm_body_overlap(side, sign_side, false), arm_body_overlap(side, sign_side, true)))

# Only compare against the local fabric patch next to each finger.
# A whole-skirt bounding box would falsely report contact at the waist
# and force the arms into an A-pose again.
func surface_overlap(points: Array[Vector3], surface: PackedVector3Array, sign_side: float) -> float:
    var pelvis := at("hips")
    var overlap := 0.0
    for hand in points:
        if (hand.x - pelvis.x) * sign_side < 0.015:
            continue
        for cloth in surface:
            if (cloth.x - pelvis.x) * sign_side <= 0.015:
                continue
            if absf(cloth.y - hand.y) > 0.022 or absf(cloth.z - hand.z) > 0.024:
                continue
            overlap = maxf(overlap, (cloth.x - hand.x) * sign_side + HAND_MARGIN)
    return overlap

func reset_skirt_positions() -> void:
    for bone in skirt_rest_positions:
        skeleton.set_bone_pose_position(bone, skirt_rest_positions[bone])
    skeleton.force_update_all_bone_transforms()

# Apply a bounded displacement to the garment's existing bones. Root
# offsets are tapered near the waist; children inherit their parent's
# displacement rather than accumulating compression down the chain.
func deform_skirt(gait: RefCounted) -> void:
    var hips := int(rig.target_keys["hips"])
    var pelvis := bone_at(hips)
    var rest_pelvis := common_rest(hips)
    var applied: Dictionary = {}
    var to_local := (visual.global_transform.affine_inverse() * skeleton.global_transform).basis.inverse()
    for bone in groups["SKIRT"]:
        var p := common_rest(bone) - rest_pelvis
        var side := "left" if p.x * float(gait.arm_sides["left"]) > 0.0 else "right"
        var direction: float = gait.arm_sides[side]
        var lateral_weight := smoothstep(0.025, 0.12, absf(p.x))
        var waist_weight := smoothstep(0.025, 0.22, -p.y)
        var requested := float(skirt_compression[side]) * lateral_weight * waist_weight
        var current := bone_at(bone)
        # Keep cloth outside the nearby thigh. The arm must yield if
        # there is no remaining space between garment and leg.
        var upper := at(side + "UpperLeg")
        var lower := at(side + "LowerLeg")
        var axis := lower - upper
        var t := clampf((current - upper).dot(axis) / maxf(axis.length_squared(), 0.00001), 0.0, 1.0)
        var center := upper + axis * t
        var depth := absf(current.z - center.z)
        if depth < 0.085:
            var leg_side := sqrt(maxf(0.0, 0.085 * 0.085 - depth * depth))
            requested = minf(requested, maxf(0.0, (current.x - center.x) * direction - leg_side))
        var absolute := Vector3(-direction * requested, 0.0, 0.0)
        var parent := skeleton.get_bone_parent(bone)
        var inherited: Vector3 = applied.get(parent, Vector3.ZERO)
        var local_delta: Vector3 = to_local * (absolute - inherited)
        if parent >= 0:
            local_delta = skeleton.get_bone_global_pose(parent).basis.inverse() * local_delta
        var rest: Vector3 = skirt_rest_positions[bone]
        skeleton.set_bone_pose_position(bone, rest + local_delta)
        skeleton.force_update_all_bone_transforms()
        applied[bone] = absolute

func solve_hand_skirt(delta: float, gait: RefCounted, holding: bool) -> void:
    if skirt_samples.is_empty():
        return
    reset_skirt_positions()
    var surface := skirt_surface()
    last_contact_compression = 0.0
    last_contact_overlap = 0.0
    for side in ["left", "right"]:
        var sign_side: float = gait.arm_sides[side]
        var demand := 0.0
        if not (holding and side == "right"):
            demand = surface_overlap(gait.hand_points(side), surface, sign_side)
        var old: float = skirt_compression[side]
        # Fast contact, slower elastic return. The cloth yields before
        # considering an arm adjustment.
        skirt_compression[side] = minf(MAX_COMPRESSION, maxf(demand, move_toward(old, demand, delta * 0.20)))
        last_contact_compression = maxf(last_contact_compression, float(skirt_compression[side]))
    deform_skirt(gait)
    surface = skirt_surface()
    for side in ["left", "right"]:
        if holding and side == "right":
            arm_residual[side] = 0.0
            continue
        var sign_side: float = gait.arm_sides[side]
        var overlap := surface_overlap(gait.hand_points(side), surface, sign_side)
        var previous: float = arm_residual[side]
        var offset := maxf(0.0, previous - delta * deg_to_rad(60.0))
        gait.abduct_chain(side, sign_side, offset)
        for iteration in range(6):
            overlap = surface_overlap(gait.hand_points(side), surface, sign_side)
            if overlap <= 0.001 or offset >= deg_to_rad(22.0):
                break
            var step := minf(deg_to_rad(22.0) - offset, clampf(overlap / 0.48, deg_to_rad(0.5), deg_to_rad(6.0)))
            gait.abduct_chain(side, sign_side, step)
            offset += step
        arm_residual[side] = offset
        last_contact_overlap = maxf(last_contact_overlap, surface_overlap(gait.hand_points(side), surface, sign_side))

func common_rest(bone: int) -> Vector3:
    return rig.target_basis * skeleton.get_bone_global_rest(bone).origin * float(rig.target_scale)

func at(key: String) -> Vector3:
    var bone: int = rig.target_keys[key]
    return visual.to_local(skeleton.to_global(skeleton.get_bone_global_pose(bone).origin))

func bone_at(bone: int) -> Vector3:
    return visual.to_local(skeleton.to_global(skeleton.get_bone_global_pose(bone).origin))

func outside_capsule(point: Vector3, a: Vector3, b: Vector3, radius: float, preferred: Vector3) -> Vector3:
    var axis := b - a
    var t := clampf((point - a).dot(axis) / maxf(axis.length_squared(), 0.000001), 0.0, 1.0)
    var center := a + axis * t
    var difference := point - center
    if difference.length() >= radius:
        return point
    var outward := difference.normalized()
    if difference.length_squared() < 0.000001:
        outward = preferred.normalized()
    return center + outward * radius

func colliders(kind: String) -> Array:
    var result: Array = []
    var pelvis := at("hips")
    var neck := at("neck") if rig.target_keys.has("neck") else at("head")
    var shoulders := at("leftUpperArm").distance_to(at("rightUpperArm"))
    if kind == "HAIR":
        var chest := at("chest") if rig.target_keys.has("chest") else pelvis.lerp(neck, 0.70)
        # Two slender overlapping torso capsules and a neck capsule.
        # The source hair is already styled; collision only corrects
        # strands that actually enter these body volumes.
        result.append([pelvis, chest, clampf(shoulders * 0.38, 0.10, 0.15)])
        result.append([chest, neck, clampf(shoulders * 0.38, 0.10, 0.15)])
        result.append([neck, at("head"), 0.078])
        for side in ["left", "right"]:
            result.append([at(side + "UpperArm"), at(side + "LowerArm"), 0.065])
    else:
        for side in ["left", "right"]:
            result.append([at(side + "UpperLeg"), at(side + "LowerLeg"), 0.082])
            var wrist := at(side + "Hand")
            var forearm := (wrist - at(side + "LowerArm")).normalized()
            result.append([wrist, wrist + forearm * 0.085, 0.048])
    return result

func tick(delta: float, gait: RefCounted = null, holding: bool = false) -> void:
    if skeleton == null:
        return
    reset_skirt_positions()
    # Restore the authored pose gradually. Contact corrections are
    # applied after that, so a strand does not wait to exit the body.
    for i in last_pose:
        var rest := skeleton.get_bone_rest(i).basis.get_rotation_quaternion()
        var previous: Quaternion = last_pose[i]
        skeleton.set_bone_pose_rotation(i, previous.slerp(rest, 1.0 - exp(-delta * 12.0)))
    skeleton.force_update_all_bone_transforms()
    if gait != null:
        solve_arm_torso(delta, gait, holding)
    for kind in groups:
        var volumes := colliders(str(kind))
        # Hand/cloth contact is handled by the skinned-surface solver
        # after the leg collision pass. Do not repel fabric from hands
        # in both directions at the same time.
        if kind == "SKIRT" and gait != null and not skirt_samples.is_empty():
            volumes = [volumes[0], volumes[2]]
        var members: Array = groups[kind]
        for parent in members:
            var children := skeleton.get_bone_children(parent)
            for child in children:
                if not members.has(child):
                    continue
                var start := bone_at(parent)
                var end := bone_at(child)
                var goal := end
                var preferred := Vector3(0, 0, -1) if kind == "HAIR" else (end - at("hips")).normalized()
                for volume in volumes:
                    goal = outside_capsule(goal, volume[0], volume[1], float(volume[2]), preferred)
                if goal.distance_squared_to(end) < 0.000001:
                    continue
                # Fixed segment lengths, bounded rotations, no bone scaling.
                var old_axis := end - start
                var new_axis := goal - start
                if old_axis.length_squared() < 0.000001 or new_axis.length_squared() < 0.000001:
                    continue
                var turn := old_axis.angle_to(new_axis)
                var blend := minf(1.0, deg_to_rad(24.0) / maxf(turn, 0.0001))
                var desired := skeleton.to_local(visual.to_global(goal)) - skeleton.get_bone_global_pose(parent).origin
                rig.aim_arm_bone(parent, child, desired, blend)
                break
    for i in last_pose:
        last_pose[i] = skeleton.get_bone_pose_rotation(i)
    if gait != null:
        solve_hand_skirt(delta, gait, holding)
        # Measure the final pose, not just the intermediate torso pass.
        # This includes any residual shoulder movement from skirt contact.
        refresh_torso_grid()
        last_torso_overlap = 0.0
        for side in ["left", "right"]:
            if holding and side == "right":
                continue
            var sign_side: float = gait.arm_sides[side]
            last_torso_overlap = maxf(last_torso_overlap, maxf(arm_body_overlap(side, sign_side, false), arm_body_overlap(side, sign_side, true)))
