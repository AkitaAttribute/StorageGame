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
# Use model-derived limb thickness rather than generic human capsules.
const BODY_MARGIN := 0.004
var arm_radii: Dictionary = {}
var arm_radius_counts: Dictionary = {}
var arm_rest_segments: Dictionary = {}
var arm_radius_observations: Dictionary = {}
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
            var child: String = str(side) + ("LowerArm" if suffix == "UpperArm" else "Hand")
            var bone: int = rig.target_keys[key]
            arm_rest_segments[bone] = [common_rest(bone), common_rest(int(rig.target_keys[child])), key]
            arm_radius_observations[key] = []
    cache_skirt_surface(avatar)
    for key in arm_radius_observations:
        var observations: Array = arm_radius_observations[key]
        observations.sort()
        arm_radius_counts[key] = observations.size()
        var fallback := 0.030 if str(key).ends_with("UpperArm") else 0.025
        arm_radii[key] = fallback if observations.is_empty() else clampf(float(observations[mini(observations.size() - 1, int(observations.size() * 0.90))]), 0.015, 0.050)
    print("ARM_COLLISION_RADII ", arm_radii, " samples=", arm_radius_counts)
    print("SECONDARY_COLLISION hair=", groups["HAIR"].size(), " skirt=", groups["SKIRT"].size(), " skirt_width=", skirt_half_width, " surface_samples=", skirt_samples.size(), " torso_samples=", torso_samples.size())

# Cache a spatially decimated set of actual skin-weighted fabric
# vertices, including their influences on pelvis and skirt bones.
# Rest-to-pose transforms then follow the live deforming skirt.
func cache_skirt_surface(avatar: Node3D) -> void:
    var occupied: Dictionary = {}
    var torso_occupied: Dictionary = {}
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
            for i in range(vertices.size()):
                var ids: Array[int] = []
                var amounts: Array[float] = []
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
                    total += weight
                    if groups["SKIRT"].has(bone):
                        influence += weight
                    if torso_bones.has(bone):
                        torso_influence += weight
                if total < 0.001:
                    continue
                var local := skeleton.to_local(mesh_node.to_global(vertices[i]))
                var common: Vector3 = rig.target_basis * local * float(rig.target_scale)
                # Radius samples exclude shoulder and wrist transitions,
                # which contain joint blends rather than limb cross sections.
                for j in range(ids.size()):
                    var id: int = ids[j]
                    if float(amounts[j]) < 0.65 or not arm_rest_segments.has(id):
                        continue
                    var segment: Array = arm_rest_segments[id]
                    var start: Vector3 = segment[0]
                    var finish: Vector3 = segment[1]
                    var axis := finish - start
                    var t := (common - start).dot(axis) / maxf(axis.length_squared(), 0.000001)
                    if t >= 0.25 and t <= 0.85:
                        var radius := common.distance_to(start + axis * t)
                        if radius > 0.005 and radius < 0.08:
                            arm_radius_observations[segment[2]].append(radius)
                if influence < 0.25 and torso_influence < 0.90:
                    continue
                var p: Vector3 = common - pelvis
                var cell := Vector3i(roundi(p.x / 0.018), roundi(p.y / 0.018), roundi(p.z / 0.018))
                var garment := influence >= 0.25 and absf(p.x) <= 0.45 and absf(p.z) <= 0.40 and p.y <= 0.20 and p.y >= -0.65
                # Exclude the moving armhole/sleeve attachment from the fixed
                # torso surface; its skin is intentionally continuous with
                # the shoulder. Keep the ribs and waist, including sides.
                var body := torso_influence >= 0.90 and influence < 0.05 and absf(p.x) <= shoulder_width and absf(p.z) <= 0.30 and p.y >= -0.04 and p.y <= shoulder_y - 0.055
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
                    torso_samples.append(sample)

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

# Sample the fleshy part of the arm, not the shoulder joint which is
# intentionally embedded in the body. Test each capsule cross section
# against the measured side of the torso at the same height and depth.
func arm_body_overlap(side: String, sign_side: float, surface: PackedVector3Array, forearm: bool) -> float:
    var a := at(side + ("LowerArm" if forearm else "UpperArm"))
    var b := at(side + ("Hand" if forearm else "LowerArm"))
    var radius: float = arm_radii[side + ("LowerArm" if forearm else "UpperArm")] + BODY_MARGIN
    var center := at("hips")
    var overlap := 0.0
    # The upper-arm endpoint already owns elbow clearance. A forearm
    # rotation cannot move its elbow pivot; don't solve that point twice.
    var fractions := [0.20, 0.40, 0.60, 0.80, 1.0] if forearm else [0.52, 0.68, 0.84, 1.0]
    for fraction in fractions:
        var p := a.lerp(b, float(fraction))
        for cloth in surface:
            if (cloth.x - center.x) * sign_side < 0.0:
                continue
            var dy := absf(p.y - cloth.y)
            var dz := absf(p.z - cloth.z)
            # Allow for the 18 mm sampling grid while retaining a curved
            # capsule cross section rather than a full bounding box.
            var cross_distance := Vector2(maxf(0.0, dy - 0.009), maxf(0.0, dz - 0.009)).length()
            if cross_distance >= radius:
                continue
            var lateral := sqrt(maxf(0.0, radius * radius - cross_distance * cross_distance))
            overlap = maxf(overlap, (cloth.x - p.x) * sign_side + lateral)
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

func solve_arm_torso(delta: float, gait: RefCounted, holding: bool) -> void:
    if torso_samples.is_empty():
        return
    var surface := skinned_surface(torso_samples)
    last_torso_overlap = 0.0
    for side in ["left", "right"]:
        if holding and side == "right":
            torso_residual[side] = 0.0
            forearm_residual[side] = 0.0
            continue
        var sign_side: float = gait.arm_sides[side]
        # First clear the elbow/upper arm, then clear the forearm
        # independently. This minimizes whole-arm abduction.
        var shoulder_offset := maxf(0.0, float(torso_residual[side]) - delta * deg_to_rad(90.0))
        gait.abduct_chain(side, sign_side, shoulder_offset)
        for iteration in range(10):
            var overlap := arm_body_overlap(side, sign_side, surface, false)
            if overlap <= 0.001 or shoulder_offset >= deg_to_rad(28.0):
                break
            # Use the actual elbow lever arm and smaller corrections
            # near contact, rather than overshooting at every iteration.
            var lever := maxf(0.10, at(side + "UpperArm").distance_to(at(side + "LowerArm")) * 0.65)
            var step := minf(deg_to_rad(28.0) - shoulder_offset, clampf(overlap / lever, deg_to_rad(0.2), deg_to_rad(5.0)))
            gait.abduct_chain(side, sign_side, step)
            shoulder_offset += step
        torso_residual[side] = shoulder_offset
        var elbow_offset := maxf(0.0, float(forearm_residual[side]) - delta * deg_to_rad(55.0))
        rotate_forearm(side, sign_side, elbow_offset)
        for iteration in range(6):
            var overlap := arm_body_overlap(side, sign_side, surface, true)
            if overlap <= 0.001 or elbow_offset >= deg_to_rad(20.0):
                break
            var step := minf(deg_to_rad(20.0) - elbow_offset, clampf(overlap / 0.23, deg_to_rad(0.4), deg_to_rad(6.0)))
            rotate_forearm(side, sign_side, step)
            elbow_offset += step
        forearm_residual[side] = elbow_offset
        last_torso_overlap = maxf(last_torso_overlap, maxf(arm_body_overlap(side, sign_side, surface, false), arm_body_overlap(side, sign_side, surface, true)))

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
        var surface := skinned_surface(torso_samples)
        last_torso_overlap = 0.0
        for side in ["left", "right"]:
            if holding and side == "right":
                continue
            var sign_side: float = gait.arm_sides[side]
            last_torso_overlap = maxf(last_torso_overlap, maxf(arm_body_overlap(side, sign_side, surface, false), arm_body_overlap(side, sign_side, surface, true)))
