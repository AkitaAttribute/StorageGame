extends RefCounted
## Authored animation first, bounded contact correction second.
## See Johnz86/locomotion-godot FootPlacementIK and gait_profiles, and RigKit
## for contact acquisition, release hysteresis and reach guards.
var rig: RefCounted
var skeleton: Skeleton3D
var player: CharacterBody3D
var visual: Node3D
var avatar: Node3D
var base_y := 0.0
var ankle_height: Dictionary = {}
var feet: Dictionary = {}
var ready := false
var last_facing := Vector3.FORWARD
var last_root := Vector3.ZERO
var pelvis_offset := 0.0

func setup(retargeter: RefCounted, body: CharacterBody3D, visual_root: Node3D, avatar_root: Node3D, rest_y: float) -> void:
    rig = retargeter
    skeleton = rig.target
    player = body
    visual = visual_root
    avatar = avatar_root
    base_y = rest_y
    for side in ["left", "right"]:
        for suffix in ["UpperLeg", "LowerLeg", "Foot"]:
            if not rig.target_keys.has(side + suffix):
                return
        var foot: int = rig.target_keys[side + "Foot"]
        var rest_world := skeleton.to_global(skeleton.get_bone_global_rest(foot).origin)
        ankle_height[side] = clampf(rest_world.y - player.global_position.y, 0.025, 0.22)
        feet[side] = {"locked": false, "anchor": Vector3.ZERO, "weight": 0.0, "previous_lift": 0.0}
    last_facing = visual.global_transform.basis.z.normalized()
    last_root = player.global_position
    ready = true

func set_global_rotation(bone: int, desired: Basis, blend: float) -> void:
    var parent := skeleton.get_bone_parent(bone)
    if parent >= 0:
        desired = skeleton.get_bone_global_pose(parent).basis.orthonormalized().inverse() * desired
    var original := skeleton.get_bone_pose_rotation(bone)
    skeleton.set_bone_pose_rotation(bone, original.slerp(desired.orthonormalized().get_rotation_quaternion(), blend))
    skeleton.force_update_all_bone_transforms()

func limit_torso() -> void:
    # Keep the base clip's subtle rotation but prevent a running-style bend.
    for key in ["hips", "spine", "chest", "upperChest", "neck", "head"]:
        if not rig.target_keys.has(key):
            continue
        var bone: int = rig.target_keys[key]
        var rest := skeleton.get_bone_global_rest(bone).basis.orthonormalized()
        var pose := skeleton.get_bone_global_pose(bone).basis.orthonormalized()
        var rest_q := rest.get_rotation_quaternion()
        var pose_q := pose.get_rotation_quaternion()
        var maximum := deg_to_rad(5.0 if key == "hips" else 8.0)
        var angle := rest_q.angle_to(pose_q)
        if angle > maximum:
            set_global_rotation(bone, Basis(rest_q.slerp(pose_q, maximum / angle)), 1.0)

func keep_arms_clear(holding: bool) -> void:
    var common: Basis = rig.target_basis
    for side in ["left", "right"]:
        if holding and side == "right":
            continue
        var upper: int = rig.target_keys[side + "UpperArm"]
        var lower: int = rig.target_keys[side + "LowerArm"]
        var hand: int = rig.target_keys[side + "Hand"]
        var shoulder := skeleton.get_bone_global_pose(upper).origin
        var elbow := skeleton.get_bone_global_pose(lower).origin
        var wrist := skeleton.get_bone_global_pose(hand).origin
        var rest_axis := skeleton.get_bone_global_rest(lower).origin - skeleton.get_bone_global_rest(upper).origin
        var sign_side := signf((common * rest_axis).x)
        if is_zero_approx(sign_side):
            sign_side = 1.0 if side == "left" else -1.0
        # Preserve the authored forward/back swing, with outward clearance
        # for this character's skirt and a limited, relaxed elbow bend.
        var u := (common * (elbow - shoulder)).normalized()
        var v := (common * (wrist - elbow)).normalized()
        var upper_z := clampf(u.z, -0.23, 0.23)
        var lower_z := clampf(v.z, upper_z - 0.05, upper_z + 0.18)
        var upper_dir := Vector3(sign_side * 0.27, -1.0, upper_z).normalized()
        var lower_dir := Vector3(sign_side * 0.19, -1.0, lower_z).normalized()
        rig.aim_arm_bone(upper, lower, common.inverse() * upper_dir, 1.0)
        rig.aim_arm_bone(lower, hand, common.inverse() * lower_dir, 1.0)
        # Neutral local wrist rather than a donor wrist rotated into the skirt.
        skeleton.set_bone_pose_rotation(hand, skeleton.get_bone_rest(hand).basis.get_rotation_quaternion())
        skeleton.force_update_all_bone_transforms()

func ground_at(point: Vector3) -> Dictionary:
    var query := PhysicsRayQueryParameters3D.create(point + Vector3.UP * 0.40, point - Vector3.UP * 0.55, 1, [player.get_rid()])
    var hit := player.get_world_3d().direct_space_state.intersect_ray(query)
    if not hit.is_empty() and Vector3(hit["normal"]).y > 0.65:
        return hit
    return {}

func solve_leg(side: String, world_goal: Vector3, blend: float) -> void:
    var thigh: int = rig.target_keys[side + "UpperLeg"]
    var shin: int = rig.target_keys[side + "LowerLeg"]
    var foot: int = rig.target_keys[side + "Foot"]
    var hip := skeleton.get_bone_global_pose(thigh).origin
    var knee := skeleton.get_bone_global_pose(shin).origin
    var ankle := skeleton.get_bone_global_pose(foot).origin
    var upper_length := hip.distance_to(knee)
    var lower_length := knee.distance_to(ankle)
    var to_goal := skeleton.to_local(world_goal) - hip
    if minf(upper_length, lower_length) < 0.001 or to_goal.length_squared() < 0.000001:
        return
    var distance := clampf(to_goal.length(), absf(upper_length - lower_length) + 0.001, (upper_length + lower_length) * 0.985)
    var direction := to_goal.normalized()
    # Prefer the authored knee plane. If nearly straight, fall back to the
    # avatar's forward direction, never an arbitrary crossed-leg pole.
    var animated_knee := knee - hip
    var pole := animated_knee - direction * animated_knee.dot(direction)
    var forward: Vector3 = rig.target_basis.inverse() * Vector3(0, 0, 1)
    var forward_pole := forward - direction * forward.dot(direction)
    if pole.length_squared() < 0.00001 or pole.dot(forward_pole) < 0.0:
        pole = forward_pole
    if pole.length_squared() < 0.00001:
        return
    pole = pole.normalized()
    var along := (upper_length * upper_length + distance * distance - lower_length * lower_length) / (2.0 * distance)
    var bend := sqrt(maxf(0.0, upper_length * upper_length - along * along))
    var desired_knee := hip + direction * along + pole * bend
    var desired_ankle := hip + direction * distance
    var foot_basis := skeleton.get_bone_global_pose(foot).basis.orthonormalized()
    rig.aim_arm_bone(thigh, shin, desired_knee - hip, blend)
    var updated_knee := skeleton.get_bone_global_pose(shin).origin
    rig.aim_arm_bone(shin, foot, desired_ankle - updated_knee, blend)
    set_global_rotation(foot, foot_basis, 1.0)

func contact_step(side: String, delta: float, turning: bool, grounded: bool) -> void:
    var foot: int = rig.target_keys[side + "Foot"]
    var thigh: int = rig.target_keys[side + "UpperLeg"]
    var shin: int = rig.target_keys[side + "LowerLeg"]
    var animated := skeleton.to_global(skeleton.get_bone_global_pose(foot).origin)
    var hit := ground_at(animated)
    var record: Dictionary = feet[side]
    var lift := 1.0
    var terrain_target := animated
    if not hit.is_empty():
        var floor_y: float = Vector3(hit["position"]).y + float(ankle_height[side])
        lift = animated.y - floor_y
        terrain_target.y = maxf(animated.y, floor_y)
    var previous_lift: float = record["previous_lift"]
    record["previous_lift"] = lift
    var anchor: Vector3 = record["anchor"]
    var hip := skeleton.to_global(skeleton.get_bone_global_pose(thigh).origin)
    var knee := skeleton.to_global(skeleton.get_bone_global_pose(shin).origin)
    var reach := hip.distance_to(knee) + knee.distance_to(animated)
    var rest: Vector3 = rig.target_basis * skeleton.get_bone_global_rest(foot).origin
    var side_sign := signf(rest.x)
    var local_anchor := visual.to_local(anchor)
    var across_center := local_anchor.x * side_sign < 0.035
    var horizontal_error := Vector2(anchor.x - animated.x, anchor.z - animated.z).length()
    var permitted := grounded and not turning and not hit.is_empty()
    if bool(record["locked"]) and (not permitted or lift > 0.065 or horizontal_error > 0.14 or hip.distance_to(anchor) > reach * 0.94 or across_center):
        record["locked"] = false
        record["weight"] = 0.0
    elif not bool(record["locked"]) and permitted and lift < 0.035 and lift >= -0.10 and lift <= previous_lift + 0.003 and hip.distance_to(terrain_target) < reach * 0.94:
        var local_target := visual.to_local(terrain_target)
        if local_target.x * side_sign >= 0.035:
            record["anchor"] = terrain_target
            record["locked"] = true
    var influence := float(record["weight"])
    influence = move_toward(influence, 0.65 if bool(record["locked"]) else 0.0, delta * 10.0)
    record["weight"] = influence
    feet[side] = record
    if bool(record["locked"]) and influence > 0.0:
        solve_leg(side, record["anchor"], influence)
    elif grounded and not turning and not hit.is_empty() and lift < -0.015:
        # Only small upward corrections for a penetrating foot; preserve
        # the authored swing and do not invent a new stride.
        terrain_target.y = minf(terrain_target.y, animated.y + 0.10)
        solve_leg(side, terrain_target, 0.55)

func tick(delta: float, _velocity: Vector3, grounded: bool, holding: bool) -> void:
    if not ready:
        return
    var facing := visual.global_transform.basis.z.normalized()
    var angular_speed := last_facing.angle_to(facing) / maxf(delta, 0.001)
    var turning := angular_speed > deg_to_rad(85.0) or player.global_position.distance_to(last_root) > 0.35
    last_facing = facing
    last_root = player.global_position
    limit_torso()
    keep_arms_clear(holding)
    var correction := clampf(float(rig.foot_ground_correction()), -0.065, 0.065) if grounded else 0.0
    pelvis_offset = lerpf(pelvis_offset, correction, 1.0 - exp(-delta * 12.0))
    avatar.position.y = base_y + pelvis_offset
    for side in ["left", "right"]:
        contact_step(side, delta, turning, grounded)
