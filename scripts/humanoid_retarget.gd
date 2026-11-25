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

const CORE := ["hips", "spine", "head", "leftUpperArm", "rightUpperArm", "leftLowerArm", "rightLowerArm", "leftHand", "rightHand", "leftUpperLeg", "rightUpperLeg", "leftLowerLeg", "rightLowerLeg", "leftFoot", "rightFoot"]
const BODY := {
    "hips": ["hips", "hip", "pelvis"],
    "spine": ["spine", "spine01", "spine1", "lowerback"],
    "chest": ["chest", "spine02", "spine2", "upperbody", "upperback"],
    "upperChest": ["upperchest", "spine03", "spine3"],
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
    "Toes": ["toes", "toe", "toebase"],
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
    target_basis = (character.global_transform.affine_inverse() * target.global_transform).basis.orthonormalized()
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
    # Skeleton bone indices are parent-first on imported glTF skin trees.
    for dst in range(target.get_bone_count()):
        if not pairs.has(dst):
            continue
        var src: int = pairs[dst]
        var rest_source := source.get_bone_global_rest(src).basis.orthonormalized()
        var posed_source := source.get_bone_global_pose(src).basis.orthonormalized()
        var delta_common := source_basis * posed_source * rest_source.inverse() * source_basis.inverse()
        var correction: Basis = corrections.get(dst, Basis.IDENTITY)
        var rest_target := target.get_bone_global_rest(dst).basis.orthonormalized()
        var desired := target_basis.inverse() * delta_common * correction * target_basis * rest_target
        var parent := target.get_bone_parent(dst)
        if parent >= 0:
            desired = target.get_bone_global_pose(parent).basis.orthonormalized().inverse() * desired
        target.set_bone_pose_rotation(dst, desired.orthonormalized().get_rotation_quaternion())
    target.force_update_all_bone_transforms()
