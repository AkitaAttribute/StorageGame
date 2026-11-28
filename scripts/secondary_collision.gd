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
var skirt_sample_bones: Dictionary = {}
var skirt_rest_positions: Dictionary = {}
var skirt_compression: Dictionary = {"left": 0.0, "right": 0.0}
var arm_residual: Dictionary = {"left": 0.0, "right": 0.0}
var last_contact_overlap := 0.0
var last_contact_compression := 0.0
# Sleeve geometry is measured once at load, not skinned/searched every tick.
var sleeve_profiles: Dictionary = {}
var skirt_enabled := true
var hoodie_enabled := false
var hoodie_sleeve_profiles: Dictionary = {}
var hoodie_samples: Array[Dictionary] = []
var hoodie_sample_bones: Dictionary = {}
var hoodie_arm_offset: Dictionary = {"left": 0.0, "right": 0.0}
var hoodie_back_radius := 0.0

func set_outfit(top: String, bottom: String) -> void:
    hoodie_enabled = top == "hoodie"
    skirt_enabled = bottom != "trousers"
    if not skirt_enabled:
        skirt_compression = {"left": 0.0, "right": 0.0}
        arm_residual = {"left": 0.0, "right": 0.0}
    if not hoodie_enabled:
        hoodie_arm_offset = {"left": 0.0, "right": 0.0}


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
    cache_skirt_surface(avatar)
    measure_sleeves(avatar)
    measure_sleeves(avatar, true)
    cache_hoodie(avatar)
    print("SECONDARY_COLLISION hair=", groups["HAIR"].size(), " skirt=", groups["SKIRT"].size(), " skirt_width=", skirt_half_width, " surface_samples=", skirt_samples.size())

# Cache a spatially decimated set of actual skin-weighted fabric
# vertices, including their influences on pelvis and skirt bones.
# Rest-to-pose transforms then follow the live deforming skirt.
func cache_skirt_surface(avatar: Node3D) -> void:
    var occupied: Dictionary = {}
    var pelvis := common_rest(int(rig.target_keys["hips"]))
    for node in avatar.find_children("*", "MeshInstance3D", true, false):
        var mesh_node := node as MeshInstance3D
        if str(mesh_node.name).to_lower().begins_with("wardrobe"):
            continue
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
                if influence < 0.25 or total < 0.001:
                    continue
                var local := skeleton.to_local(mesh_node.to_global(vertices[i]))
                var p: Vector3 = rig.target_basis * local * float(rig.target_scale) - pelvis
                if absf(p.x) > 0.45 or absf(p.z) > 0.40 or p.y > 0.20 or p.y < -0.65:
                    continue
                var cell := Vector3i(roundi(p.x / 0.018), roundi(p.y / 0.018), roundi(p.z / 0.018))
                if occupied.has(cell):
                    continue
                occupied[cell] = true
                for bone in ids:
                    skirt_sample_bones[bone] = skeleton.get_bone_global_rest(bone).affine_inverse()
                skirt_samples.append({"point": local, "ids": ids, "weights": amounts, "total": total})

# Fit the proximal upper-arm/sleeve envelope from the avatar's actual
# weighted vertices. Ignore hair and distal bare arm geometry. The fitted
# volume follows the upper arm rather than inflating the entire torso.
func measure_sleeves(avatar: Node3D, hoodie: bool = false) -> void:
    for side in ["left", "right"]:
        var upper: int = rig.target_keys[side + "UpperArm"]
        var lower: int = rig.target_keys[side + "LowerArm"]
        var shoulder: int = rig.target_keys.get(side + "Shoulder", -1)
        var rest := skeleton.get_bone_global_rest(upper)
        var axis := skeleton.get_bone_global_rest(lower).origin - rest.origin
        var length := axis.length()
        if length < 0.0001:
            continue
        var radial: Array[float] = []
        for node in avatar.find_children("*", "MeshInstance3D", true, false):
            var mesh_node := node as MeshInstance3D
            var node_name := str(mesh_node.name).to_lower()
            if hoodie and not node_name.begins_with("wardrobetophoodie"):
                continue
            if not hoodie and node_name.begins_with("wardrobe"):
                continue
            var skin := mesh_node.skin
            if mesh_node.mesh == null or skin == null:
                continue
            var arm_binds: Dictionary = {}
            for bind in range(skin.get_bind_count()):
                var name := str(skin.get_bind_name(bind))
                var bone := skeleton.find_bone(name) if not name.is_empty() else skin.get_bind_bone(bind)
                if bone == upper or (shoulder >= 0 and bone == shoulder):
                    arm_binds[bind] = true
            if arm_binds.is_empty():
                continue
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
                    var influence := 0.0
                    for j in range(stride):
                        if arm_binds.has(bones[i * stride + j]):
                            influence += weights[i * stride + j]
                    if influence < 0.45:
                        continue
                    var offset := skeleton.to_local(mesh_node.to_global(vertices[i])) - rest.origin
                    var t := offset.dot(axis) / axis.length_squared()
                    if t < -0.08 or t > 0.48:
                        continue
                    var radius := (offset - axis * t).length() * float(rig.target_scale)
                    if radius > 0.015 and radius < 0.15:
                        radial.append(radius)
        radial.sort()
        # A percentile rejects isolated blended torso/armhole vertices.
        # Never enlarge the full arm; only the short proximal sleeve.
        var radius := 0.065
        if not radial.is_empty():
            radius = clampf(radial[floori(float(radial.size() - 1) * 0.92)] + 0.006, 0.045, 0.105)
        if hoodie:
            hoodie_sleeve_profiles[side] = {"radius": radius, "samples": radial.size()}
        else:
            sleeve_profiles[side] = {"radius": radius, "samples": radial.size()}
        print("HAIR_SLEEVE ", side, " hoodie=", hoodie, " samples=", radial.size(), " radius=", radius)

func sleeve_colliders() -> Array:
    var result: Array = []
    var profiles := hoodie_sleeve_profiles if hoodie_enabled else sleeve_profiles
    for side in ["left", "right"]:
        if not profiles.has(side):
            continue
        var shoulder := at(side + "UpperArm")
        var elbow := at(side + "LowerArm")
        var radius: float = profiles[side]["radius"]
        result.append([shoulder.lerp(elbow, 0.06), shoulder.lerp(elbow, 0.60 if hoodie_enabled else 0.30), radius])
    if hoodie_enabled and hoodie_back_radius > 0.0:
        var chest := at("chest")
        var neck := at("neck")
        # Short upper-back hood proxy only; no expansion of the whole torso.
        result.append([chest.lerp(neck, 0.35) + Vector3(0,0,-0.035), neck + Vector3(0,0,-0.035), hoodie_back_radius])
    return result

# Only a contacting link gets displaced. Preserve the original torso
# solver and do not add new rotations at hair roots or terminal bones.
# A narrow extra sample catches hair crossing a sleeve between joints.
func sleeve_link_goal(start: Vector3, end: Vector3, volumes: Array) -> Vector3:
    var correction := Vector3.ZERO
    for volume in volumes:
        for fraction in [0.65, 1.0]:
            var point := start.lerp(end, float(fraction))
            var center: Vector3 = (volume[0] + volume[1]) * 0.5
            var preferred := point - center
            if preferred.length_squared() < 0.000001:
                preferred = Vector3.UP
            var pushed := outside_capsule(point, volume[0], volume[1], float(volume[2]), preferred)
            var change := (pushed - point) / float(fraction)
            if change.length_squared() > correction.length_squared():
                correction = change
    return end + correction.limit_length(0.035)

# Cache a sparse, torso-weighted surface of the actual hoodie. Sleeve
# vertices must not repel the very arm to which they are attached.
func cache_hoodie(avatar: Node3D) -> void:
    var torso: Array[int] = []
    for key in ["hips","spine","chest","upperChest","neck"]:
        if rig.target_keys.has(key):
            torso.append(int(rig.target_keys[key]))
    var occupied: Dictionary = {}
    var chest := common_rest(int(rig.target_keys["chest"]))
    var neck := common_rest(int(rig.target_keys["neck"]))
    var hip := common_rest(int(rig.target_keys["hips"]))
    var back_depth := 0.0
    for node in avatar.find_children("*","MeshInstance3D",true,false):
        var mesh_node := node as MeshInstance3D
        if not str(mesh_node.name).to_lower().begins_with("wardrobetophoodie") or mesh_node.mesh == null or mesh_node.skin == null:
            continue
        var skin := mesh_node.skin
        var binds: Dictionary = {}
        for i in range(skin.get_bind_count()):
            var name := str(skin.get_bind_name(i))
            var bone := skeleton.find_bone(name) if not name.is_empty() else skin.get_bind_bone(i)
            if bone >= 0:
                binds[i] = bone
        for surface in range(mesh_node.mesh.get_surface_count()):
            var arrays := mesh_node.mesh.surface_get_arrays(surface)
            var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
            var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
            var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
            if vertices.is_empty() or bones.is_empty() or weights.size() != bones.size():
                continue
            var stride := int(bones.size()/vertices.size())
            for i in range(vertices.size()):
                var ids: Array[int] = []
                var amounts: Array[float] = []
                var influence := 0.0
                var total := 0.0
                for j in range(stride):
                    var bind := bones[i*stride+j]
                    var weight := weights[i*stride+j]
                    if weight <= 0.0001 or not binds.has(bind):
                        continue
                    var bone: int = binds[bind]
                    ids.append(bone)
                    amounts.append(weight)
                    total += weight
                    if torso.has(bone):
                        influence += weight
                if total < 0.001 or influence/total < 0.60:
                    continue
                var local := skeleton.to_local(mesh_node.to_global(vertices[i]))
                var point: Vector3 = rig.target_basis * local * float(rig.target_scale)
                if absf(point.x-hip.x) > 0.24:
                    continue
                if point.y > chest.y and point.y < neck.y+0.09:
                    back_depth = maxf(back_depth, chest.z-point.z)
                # Keep only the lower and side fabric for hand contact.
                if point.y < hip.y-0.25 or point.y > neck.y or absf(point.x-hip.x) < 0.055:
                    continue
                var cell := Vector3i(roundi(point.x/0.035),roundi(point.y/0.035),roundi(point.z/0.035))
                if occupied.has(cell):
                    continue
                occupied[cell] = true
                for bone in ids:
                    hoodie_sample_bones[bone] = skeleton.get_bone_global_rest(bone).affine_inverse()
                hoodie_samples.append({"point":local,"ids":ids,"weights":amounts,"total":total})
    if back_depth > 0.03:
        hoodie_back_radius = clampf(back_depth-0.035+0.010,0.065,0.125)
    print("HOODIE_CONTACT samples=",hoodie_samples.size()," hood_radius=",hoodie_back_radius)

func hoodie_surface() -> PackedVector3Array:
    var result := PackedVector3Array()
    var transforms: Dictionary = {}
    var to_visual := visual.global_transform.affine_inverse() * skeleton.global_transform
    for bone in hoodie_sample_bones:
        var inv: Transform3D = hoodie_sample_bones[bone]
        transforms[bone] = to_visual * skeleton.get_bone_global_pose(bone) * inv
    for sample in hoodie_samples:
        var p: Vector3 = sample["point"]
        var ids: Array = sample["ids"]
        var weights: Array = sample["weights"]
        var pos := Vector3.ZERO
        for i in range(ids.size()):
            var transform: Transform3D = transforms[ids[i]]
            pos += (transform*p)*float(weights[i])
        result.append(pos/float(sample["total"]))
    return result

func solve_hoodie_arms(delta: float, gait: RefCounted, holding: bool, held_side: String) -> void:
    if not hoodie_enabled or hoodie_samples.is_empty():
        return
    var surface := hoodie_surface()
    for side in ["left","right"]:
        if holding and (held_side == side or held_side == "both"):
            hoodie_arm_offset[side] = 0.0
            continue
        var sign_side: float = gait.arm_sides[side]
        var points: Array[Vector3] = gait.hand_points(side)
        var elbow := at(side+"LowerArm")
        var wrist := at(side+"Hand")
        points.append(elbow)
        points.append(elbow.lerp(wrist,0.5))
        var overlap := surface_overlap(points,surface,sign_side)
        var budget := maxf(0.0,deg_to_rad(12.0)-float(arm_residual[side]))
        var desired := clampf(overlap/0.42,0.0,minf(budget,deg_to_rad(8.0)))
        var offset := minf(budget,lerpf(float(hoodie_arm_offset[side]),desired,1.0-exp(-delta*12.0)))
        hoodie_arm_offset[side] = offset
        gait.abduct_chain(side,sign_side,offset)

func skirt_surface() -> PackedVector3Array:
    var result := PackedVector3Array()
    var transforms: Dictionary = {}
    var to_visual := visual.global_transform.affine_inverse() * skeleton.global_transform
    for bone in skirt_sample_bones:
        var inverse_rest: Transform3D = skirt_sample_bones[bone]
        transforms[bone] = to_visual * skeleton.get_bone_global_pose(bone) * inverse_rest
    for sample in skirt_samples:
        var p: Vector3 = sample["point"]
        var ids: Array = sample["ids"]
        var weights: Array = sample["weights"]
        var pos := Vector3.ZERO
        for i in range(ids.size()):
            var transform: Transform3D = transforms[ids[i]]
            pos += (transform * p) * float(weights[i])
        result.append(pos / float(sample["total"]))
    return result

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
            var dy := absf(cloth.y - hand.y)
            var dz := absf(cloth.z - hand.z)
            if dy >= 0.040 or dz >= 0.040:
                continue
            var proximity := (1.0 - smoothstep(0.015, 0.040, dy)) * (1.0 - smoothstep(0.015, 0.040, dz))
            overlap = maxf(overlap, maxf(0.0, (cloth.x - hand.x) * sign_side + HAND_MARGIN) * proximity)
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

func solve_hand_skirt(delta: float, gait: RefCounted, holding: bool, held_side: String = "right") -> void:
    if not skirt_enabled or skirt_samples.is_empty():
        last_contact_overlap = 0.0
        last_contact_compression = 0.0
        return
    reset_skirt_positions()
    var surface := skirt_surface()
    last_contact_compression = 0.0
    last_contact_overlap = 0.0
    for side in ["left", "right"]:
        var sign_side: float = gait.arm_sides[side]
        var demand := 0.0
        if not (holding and (held_side == side or held_side == "both")):
            demand = surface_overlap(gait.hand_points(side), surface, sign_side)
        var old: float = skirt_compression[side]
        # Fast contact, slower elastic return. The cloth yields before
        # considering an arm adjustment.
        skirt_compression[side] = minf(MAX_COMPRESSION, maxf(demand, move_toward(old, demand, delta * 0.20)))
        last_contact_compression = maxf(last_contact_compression, float(skirt_compression[side]))
    deform_skirt(gait)
    surface = skirt_surface()
    for side in ["left", "right"]:
        if holding and (held_side == side or held_side == "both"):
            arm_residual[side] = 0.0
            continue
        var sign_side: float = gait.arm_sides[side]
        var overlap := surface_overlap(gait.hand_points(side), surface, sign_side)
        var previous: float = arm_residual[side]
        # Continuous low-pass contact. Do not solve multiple shoulder
        # candidates in one tick or spread an arm into an A-pose.
        var desired := clampf(overlap / 0.48, 0.0, deg_to_rad(10.0))
        var offset := lerpf(previous, desired, 1.0 - exp(-delta * 12.0))
        gait.abduct_chain(side, sign_side, offset)
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

func tick(delta: float, gait: RefCounted = null, holding: bool = false, held_side: String = "right") -> void:
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
    # Keep the original five torso/arm proxies and endpoint behavior.
    # Process skirt first so the sleeves follow the final arm pose.
    for kind in ["SKIRT", "HAIR"]:
        if kind == "SKIRT" and not skirt_enabled:
            continue
        if kind == "HAIR" and gait != null:
            solve_hand_skirt(delta, gait, holding, held_side)
            solve_hoodie_arms(delta, gait, holding, held_side)
        var volumes := colliders(str(kind))
        var sleeves := sleeve_colliders() if kind == "HAIR" else []
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
                if kind == "HAIR":
                    goal = sleeve_link_goal(start, goal, sleeves)
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
