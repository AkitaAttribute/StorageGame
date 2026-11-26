extends RefCounted
## Footstep-driven humanoid locomotion. Inspired by Kovar et al. (2002),
## van Basten et al. (2010), and the support/swing phases of human walking.
## This is an original two-bone IK implementation, not motion matching.
var rig: RefCounted
var skeleton: Skeleton3D
var player: CharacterBody3D
var visual: Node3D
var avatar: Node3D
var base_y := 0.0
var ankle_height: Dictionary = {}
var feet: Dictionary = {}
var phase := 0.0
var weight := 0.0
var pelvis_offset := 0.0
var ready := false
var stride_forward := Vector3.FORWARD
var last_root := Vector3.ZERO
var last_facing := Vector3.FORWARD

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
        var ankle_world := skeleton.to_global(skeleton.get_bone_global_rest(foot).origin)
        ankle_height[side] = clampf(ankle_world.y - player.global_position.y, 0.025, 0.22)
    last_root = player.global_position
    last_facing = visual.global_transform.basis.z.normalized()
    ready = true

func neutral_ankle(side: String) -> Vector3:
    var foot: int = rig.target_keys[side + "Foot"]
    # Use actual rig stance width, independent of donor leg proportions.
    var rest := skeleton.get_bone_global_rest(foot).origin
    var local: Vector3 = rig.target_basis * rest * float(rig.target_scale)
    var side_sign := signf(local.x)
    if is_zero_approx(side_sign):
        side_sign = -1.0 if side == "right" else 1.0
    var lateral := clampf(absf(local.x), 0.07, 0.125) * side_sign
    var right := visual.global_transform.basis.x.normalized()
    return player.global_position + right * lateral

func floor_ankle(point: Vector3, side: String) -> Vector3:
    var start := Vector3(point.x, player.global_position.y + 0.75, point.z)
    var finish := Vector3(point.x, player.global_position.y - 0.85, point.z)
    var query := PhysicsRayQueryParameters3D.create(start, finish, 1, [player.get_rid()])
    var hit := player.get_world_3d().direct_space_state.intersect_ray(query)
    var floor_y := player.global_position.y
    if not hit.is_empty() and Vector3(hit["normal"]).y > 0.55:
        floor_y = Vector3(hit["position"]).y
    return Vector3(point.x, floor_y + float(ankle_height[side]), point.z)

func reset_feet() -> void:
    feet.clear()
    for side in ["left", "right"]:
        var at := floor_ankle(neutral_ankle(side), side)
        feet[side] = {"plant": at, "start": at, "end": at, "target": at, "swing": false}
    phase = 0.0

func set_global_rotation(bone: int, desired: Basis, blend: float) -> void:
    var parent := skeleton.get_bone_parent(bone)
    if parent >= 0:
        desired = skeleton.get_bone_global_pose(parent).basis.orthonormalized().inverse() * desired
    var original := skeleton.get_bone_pose_rotation(bone)
    skeleton.set_bone_pose_rotation(bone, original.slerp(desired.orthonormalized().get_rotation_quaternion(), blend))
    skeleton.force_update_all_bone_transforms()

# Anatomical two-bone solution: keep segment lengths fixed and choose a
# forward-facing knee pole. Never stretch a leg to reach an impossible target.
func solve_leg(side: String, world_goal: Vector3, blend: float, foot_pitch: float) -> void:
    var thigh: int = rig.target_keys[side + "UpperLeg"]
    var shin: int = rig.target_keys[side + "LowerLeg"]
    var foot: int = rig.target_keys[side + "Foot"]
    var hip := skeleton.get_bone_global_pose(thigh).origin
    var knee := skeleton.get_bone_global_pose(shin).origin
    var ankle := skeleton.get_bone_global_pose(foot).origin
    var upper_length := hip.distance_to(knee)
    var lower_length := knee.distance_to(ankle)
    if minf(upper_length, lower_length) < 0.001:
        return
    var to_goal := skeleton.to_local(world_goal) - hip
    var distance := clampf(to_goal.length(), absf(upper_length - lower_length) + 0.001, (upper_length + lower_length) * 0.985)
    if to_goal.length_squared() < 0.000001:
        return
    var direction := to_goal.normalized()
    var forward: Vector3 = rig.target_basis.inverse() * Vector3(0, 0, 1)
    var pole := forward - direction * forward.dot(direction)
    if pole.length_squared() < 0.00001:
        pole = Vector3.RIGHT - direction * direction.x
    pole = pole.normalized()
    var along := (upper_length * upper_length + distance * distance - lower_length * lower_length) / (2.0 * distance)
    var bend := sqrt(maxf(0.0, upper_length * upper_length - along * along))
    var desired_knee := hip + direction * along + pole * bend
    var desired_ankle := hip + direction * distance
    rig.aim_arm_bone(thigh, shin, desired_knee - hip, blend)
    var updated_knee := skeleton.get_bone_global_pose(shin).origin
    rig.aim_arm_bone(shin, foot, desired_ankle - updated_knee, blend)
    # Use the avatar's own rest ankle orientation and subtle heel/toe roll,
    # rather than inheriting the donor's incompatible foot rotation.
    var rest := skeleton.get_bone_global_rest(foot).basis.orthonormalized()
    var common: Basis = rig.target_basis
    var orientation := common.inverse() * Basis(Vector3.RIGHT, foot_pitch) * common * rest
    set_global_rotation(foot, orientation, blend)

func step_foot(side: String, side_phase: float, stance: float, cycle: float, speed: float) -> Vector3:
    var record: Dictionary = feet[side]
    var neutral := neutral_ankle(side)
    var moving := speed > 0.10
    var swing := moving and side_phase >= stance
    var lead := clampf(speed * cycle * stance * 0.5, 0.08, 0.49)
    var forward := stride_forward
    if swing:
        if not bool(record["swing"]):
            record["start"] = record["target"]
            record["end"] = floor_ankle(neutral + forward * (lead + speed * cycle * (1.0 - stance) * 0.55), side)
        # Replan gradually if direction or terrain changes during swing.
        var landing := floor_ankle(neutral + forward * lead, side)
        var progress := (side_phase - stance) / (1.0 - stance)
        if progress < 0.65:
            var old_end: Vector3 = record["end"]
            record["end"] = old_end.lerp(landing, 0.12)
        var start: Vector3 = record["start"]
        var finish: Vector3 = record["end"]
        var at := start.lerp(finish, smoothstep(0.0, 1.0, progress))
        var lift := lerpf(0.075, 0.155, clampf(speed / 3.4, 0.0, 1.0))
        at.y += sin(PI * progress) * lift
        record["target"] = at
    else:
        if bool(record["swing"]):
            record["plant"] = record["end"]
        var plant: Vector3 = record["plant"]
        # On a sudden turn or very fast movement, avoid unreachable targets.
        # Normal support contact stays fixed in world space.
        var flat := plant - neutral
        flat.y = 0.0
        if flat.length() > 0.58:
            plant = floor_ankle(neutral - forward * minf(lead, 0.40), side)
        if not moving:
            var idle_target := floor_ankle(neutral, side)
            plant = plant.lerp(idle_target, 0.18)
        record["plant"] = plant
        record["target"] = plant
    record["swing"] = swing
    feet[side] = record
    return record["target"]

func arms(speed: float, holding: bool) -> void:
    var amount := clampf(speed / 3.4, 0.0, 1.0)
    for side in ["left", "right"]:
        if holding and side == "right":
            continue
        var upper: int = rig.target_keys[side + "UpperArm"]
        var lower: int = rig.target_keys[side + "LowerArm"]
        var hand: int = rig.target_keys[side + "Hand"]
        var side_sign := 1.0 if side == "left" else -1.0
        # Anatomical side is derived from the target rig, not donor naming.
        var rest_delta := skeleton.get_bone_global_rest(lower).origin - skeleton.get_bone_global_rest(upper).origin
        var common_delta: Vector3 = rig.target_basis * rest_delta
        if absf(common_delta.x) > 0.01:
            side_sign = signf(common_delta.x)
        var oscillation := sin(TAU * (phase + (0.5 if side == "left" else 0.0))) * amount
        var upper_vector := Vector3(side_sign * 0.14, -1.0, -oscillation * 0.36)
        var lower_vector := Vector3(side_sign * 0.06, -1.0, 0.12 - oscillation * 0.39)
        rig.aim_arm_bone(upper, lower, rig.target_basis.inverse() * upper_vector, 0.88)
        rig.aim_arm_bone(lower, hand, rig.target_basis.inverse() * lower_vector, 0.90)

func tick(delta: float, velocity: Vector3, grounded: bool, holding: bool) -> void:
    if not ready:
        return
    velocity.y = 0.0
    var speed := velocity.length()
    var facing := visual.global_transform.basis.z.normalized()
    if feet.is_empty() or player.global_position.distance_to(last_root) > 1.0 or facing.dot(last_facing) < 0.20:
        reset_feet()
    last_root = player.global_position
    last_facing = facing
    if speed > 0.10:
        stride_forward = velocity.normalized()
    var cycle := lerpf(1.05, 0.58, clampf(speed / 3.4, 0.0, 1.0))
    var stance := lerpf(0.62, 0.49, clampf(speed / 3.4, 0.0, 1.0))
    if grounded and speed > 0.10:
        phase = fposmod(phase + delta / cycle, 1.0)
    weight = move_toward(weight, 1.0 if grounded else 0.0, delta * 8.0)
    # A small pelvis drop keeps bent knees within reach; no exaggerated bob.
    var dip := (0.026 + 0.018 * absf(sin(TAU * phase * 2.0))) * clampf(speed / 3.4, 0.0, 1.0)
    pelvis_offset = lerpf(pelvis_offset, -dip if grounded else 0.0, 1.0 - exp(-delta * 14.0))
    avatar.position.y = base_y + pelvis_offset
    if weight > 0.0:
        for side in ["left", "right"]:
            var side_phase := fposmod(phase + (0.5 if side == "right" else 0.0), 1.0)
            var goal := step_foot(side, side_phase, stance, cycle, speed)
            var pitch := 0.0
            if side_phase >= stance and speed > 0.10:
                pitch = sin(PI * (side_phase - stance) / (1.0 - stance)) * 0.12
            solve_leg(side, goal, weight, pitch)
    arms(speed, holding)
