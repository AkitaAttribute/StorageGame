extends RefCounted
## Transfers the donor's animated joint turns in common character space,
## rather than copying incompatible local quaternions between rigs.

var source: Skeleton3D
var target: Skeleton3D
var pairs: Dictionary = {}
var source_basis := Basis.IDENTITY
var target_basis := Basis.IDENTITY
var corrections: Dictionary = {}
var target_keys: Dictionary = {}
var target_scale := 1.0
var rest_foot_height := 0.0

const CORE := ["hips", "spine", "head", "leftUpperArm", "rightUpperArm", "leftLowerArm", "rightLowerArm", "leftHand", "rightHand", "leftUpperLeg", "rightUpperLeg", "leftLowerLeg", "rightLowerLeg", "leftFoot", "rightFoot"]
const BODY := {
    "hips": ["hips", "hip", "pelvis"],
    "spine": ["spine001", "spine", "spine01", "spine1", "lowerback"],
    "chest": ["spine002", "chest", "spine02", "spine2", "upperbody", "upperback"],
    "upperChest": ["spine003", "upperchest", "spine03", "spine3"],
    "neck": ["neck", "neck01", "neck1"],
    "head": ["head"],
}
const LIMBS := {
    "Shoulder": ["shoulder", "clavicle", "collar"],
    "UpperArm": ["upperarm", "arm", "humerus"],
    "LowerArm": ["lowerarm", "forearm", "elbow"],
    "Hand": ["hand", "wrist"],
    "UpperLeg": ["upperleg", "thigh", "upleg", "femur"],
    "LowerLeg": ["lowerleg", "shin", "calf", "leg", "knee"],
    "Foot": ["foot", "ankle"],
    "Toes": ["toes", "toe", "toebase", "ball"],
}
const CHILD := {
    "hips": "spine", "spine": "chest", "chest": "neck", "upperChest": "neck", "neck": "head",
    "leftShoulder": "leftUpperArm", "rightShoulder": "rightUpperArm",
    "leftUpperArm": "leftLowerArm", "rightUpperArm": "rightLowerArm",
    "leftLowerArm": "leftHand", "rightLowerArm": "rightHand",
    "leftUpperLeg": "leftLowerLeg", "rightUpperLeg": "rightLowerLeg",
    "leftLowerLeg": "leftFoot", "rightLowerLeg": "rightFoot",
    "leftFoot": "leftToes", "rightFoot": "rightToes",
}

static func skeleton_in(root: Node) -> Skeleton3D:
    if root is Skeleton3D:
        return root
    for child in root.get_children():
        var found := skeleton_in(child)
        if found != null:
            return found
    return null

func normalized(value: String) -> String:
    return value.to_lower().replace("mixamorig", "").replace("def-", "").replace("rig_", "").replace(".", "").replace("_", "").replace("-", "").replace(":", "").replace(" ", "")

func source_id(aliases: Array, side: String = "") -> int:
    for alias in aliases:
        for i in range(source.get_bone_count()):
            var name := normalized(str(source.get_bone_name(i)))
            if side.is_empty():
                if name == alias:
                    return i
            else:
                var short := side.substr(0, 1)
                if name in [side + alias, alias + side, short + alias, alias + short]:
                    return i
    return -1

func add_pair(key: String, src: int) -> void:
    var dst := target.find_bone("VRM_" + key)
    if src >= 0 and dst >= 0 and not pairs.values().has(src):
        pairs[dst] = src
        target_keys[key] = dst

func setup(donor: Node3D, avatar: Node3D, character: Node3D) -> bool:
    source = skeleton_in(donor)
    target = skeleton_in(avatar)
    if source == null or target == null:
        return false
    source_basis = (character.global_transform.affine_inverse() * source.global_transform).basis.orthonormalized()
    var target_transform := character.global_transform.affine_inverse() * target.global_transform
    target_basis = target_transform.basis.orthonormalized()
    target_scale = target_transform.basis.get_scale().y
    for key in BODY:
        add_pair(key, source_id(BODY[key]))
    for side in ["left", "right"]:
        for limb in LIMBS:
            add_pair(side + limb, source_id(LIMBS[limb], side))
    var missing: Array[String] = []
    for key in CORE:
        if not target_keys.has(key):
            missing.append(key)
    var donor_names: Array[String] = []
    for i in range(source.get_bone_count()):
        donor_names.append(str(source.get_bone_name(i)))
    print("RETARGET_MAPPED ", target_keys.keys(), " source joints=", donor_names)
    if not missing.is_empty():
        push_error("Retarget missing required humanoid bones: " + str(missing))
        return false
    # Align the donor's anatomical left/right axis to the avatar's.
    var sl: int = pairs[target_keys["leftUpperLeg"]]
    var sr: int = pairs[target_keys["rightUpperLeg"]]
    var tl: int = target_keys["leftUpperLeg"]
    var tr: int = target_keys["rightUpperLeg"]
    var source_side := source_basis * (source.get_bone_global_rest(sl).origin - source.get_bone_global_rest(sr).origin)
    var target_side := target_basis * (target.get_bone_global_rest(tl).origin - target.get_bone_global_rest(tr).origin)
    source_side.y = 0.0
    target_side.y = 0.0
    if source_side.length_squared() > 0.000001 and target_side.length_squared() > 0.000001:
        source_basis = Basis(Vector3.UP, source_side.signed_angle_to(target_side, Vector3.UP)) * source_basis
    rest_foot_height = lowest_foot(true)
    # Match arm/leg rest directions as well as rest-space joint turns. This
    # prevents a T-pose avatar from keeping its arms straight out when the
    # donor's neutral pose has arms down.
    for key in CHILD:
        if not target_keys.has(key) or not target_keys.has(CHILD[key]):
            continue
        var dst: int = target_keys[key]
        var dst_child: int = target_keys[CHILD[key]]
        var src: int = pairs[dst]
        var src_child: int = pairs[dst_child]
        var from_dir := target_basis * (target.get_bone_global_rest(dst_child).origin - target.get_bone_global_rest(dst).origin)
        var to_dir := source_basis * (source.get_bone_global_rest(src_child).origin - source.get_bone_global_rest(src).origin)
        if from_dir.length_squared() > 0.000001 and to_dir.length_squared() > 0.000001:
            corrections[dst] = Basis(Quaternion(from_dir.normalized(), to_dir.normalized()))
    return true

func apply_pose() -> void:
    if source == null or target == null:
        return
    source.force_update_all_bone_transforms()
    # Compute current parent bases explicitly in hierarchy order, so child
    # rotations never depend on stale transforms from a previous frame.
    var global_bases: Array[Basis] = []
    for dst in range(target.get_bone_count()):
        var parent := target.get_bone_parent(dst)
        var parent_basis := Basis.IDENTITY if parent < 0 else global_bases[parent]
        if pairs.has(dst):
            var src: int = pairs[dst]
            var rest_source := source.get_bone_global_rest(src).basis.orthonormalized()
            var posed_source := source.get_bone_global_pose(src).basis.orthonormalized()
            var delta_common := source_basis * posed_source * rest_source.inverse() * source_basis.inverse()
            var correction: Basis = corrections.get(dst, Basis.IDENTITY)
            var rest_target := target.get_bone_global_rest(dst).basis.orthonormalized()
            var desired := target_basis.inverse() * delta_common * correction * target_basis * rest_target
            var local := parent_basis.inverse() * desired
            target.set_bone_pose_rotation(dst, local.orthonormalized().get_rotation_quaternion())
        var current := Basis(target.get_bone_pose_rotation(dst))
        global_bases.append((parent_basis * current).orthonormalized())
    target.force_update_all_bone_transforms()

func lowest_foot(rest: bool) -> float:
    var height := INF
    for key in ["leftFoot", "rightFoot", "leftToes", "rightToes"]:
        if not target_keys.has(key):
            continue
        var i: int = target_keys[key]
        var pose := target.get_bone_global_rest(i) if rest else target.get_bone_global_pose(i)
        height = minf(height, (target_basis * pose.origin).y * target_scale)
    return height

func foot_ground_correction() -> float:
    var current := lowest_foot(false)
    if not is_finite(current) or not is_finite(rest_foot_height):
        return 0.0
    # Maintain the lowest support foot at its calibrated rest height without
    # forcing the swinging foot down. This is root grounding, not full foot IK.
    return clampf(rest_foot_height - current, -0.24, 0.24)

# Upper-body animation layer: keep the base walk/idle motion, then aim the
# right upper arm and forearm toward the held object. Blend in/out in gameplay.
func aim_arm_bone(bone: int, child: int, desired: Vector3, weight: float) -> void:
    var pose := target.get_bone_global_pose(bone)
    var child_pose := target.get_bone_global_pose(child)
    var axis := child_pose.origin - pose.origin
    if axis.length_squared() < 0.000001 or desired.length_squared() < 0.000001:
        return
    var turn := Quaternion(axis.normalized(), desired.normalized())
    var basis := Basis(turn) * pose.basis.orthonormalized()
    var parent := target.get_bone_parent(bone)
    if parent >= 0:
        basis = target.get_bone_global_pose(parent).basis.orthonormalized().inverse() * basis
    var original := target.get_bone_pose_rotation(bone)
    target.set_bone_pose_rotation(bone, original.slerp(basis.orthonormalized().get_rotation_quaternion(), weight))
    target.force_update_all_bone_transforms()

# Use the actual avatar's anatomical sides rather than assuming a
# particular global coordinate sign. A small dead band prevents flicker.
func carry_hand(world_point: Vector3, previous: String = "right") -> String:
    var midpoint := (target.get_bone_global_pose(int(target_keys["leftUpperArm"])).origin + target.get_bone_global_pose(int(target_keys["rightUpperArm"])).origin) * 0.5
    var lateral := target_basis * (target.to_local(world_point) - midpoint)
    var left_axis := target_basis * (target.get_bone_global_rest(target_keys["leftUpperArm"]).origin - target.get_bone_global_rest(target_keys["rightUpperArm"]).origin)
    var side_distance := lateral.x * signf(left_axis.x) * target_scale
    if side_distance > 0.055:
        return "left"
    if side_distance < -0.055:
        return "right"
    return previous

func apply_force_pose(world_point: Vector3, weight: float, side: String = "right") -> void:
    if target == null or not target_keys.has(side + "UpperArm") or not target_keys.has(side + "LowerArm") or not target_keys.has(side + "Hand"):
        return
    var upper: int = target_keys[side + "UpperArm"]
    var lower: int = target_keys[side + "LowerArm"]
    var hand: int = target_keys[side + "Hand"]
    var shoulder := target.get_bone_global_pose(upper).origin
    var other_side := "left" if side == "right" else "right"
    var other := target.get_bone_global_pose(target_keys[other_side + "UpperArm"]).origin
    var midpoint := (shoulder + other) * 0.5
    var sign_side := signf((target_basis * (skeleton_rest_arm(upper) - skeleton_rest_arm(int(target_keys[other_side + "UpperArm"])))).x)
    var local_goal := target_basis * (target.to_local(world_point) - midpoint)
    # While the previous hand lowers, never aim it across the chest.
    # Also keep the aiming ray in front during a quick camera reversal.
    local_goal.x = sign_side * maxf(0.0, local_goal.x * sign_side)
    local_goal.z = maxf(local_goal.z, 0.18 / maxf(target_scale, 0.001))
    var point := midpoint + target_basis.inverse() * local_goal
    var toward := (point - shoulder).normalized()
    var outward := target_basis.inverse() * Vector3(sign_side * 0.22, -0.19, 0.0)
    aim_arm_bone(upper, lower, toward + outward, weight)
    var elbow := target.get_bone_global_pose(lower).origin
    aim_arm_bone(lower, hand, point - elbow, weight)

func skeleton_rest_arm(bone: int) -> Vector3:
    return target.get_bone_global_rest(bone).origin
