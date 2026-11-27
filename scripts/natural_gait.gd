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
var skirt_half_width := 0.20
# Character-specific retarget pose. Preserve the animated local joint
# deltas and let children inherit the parent motion (FK). The calibrated
# pose is not the model's T-pose or a world-space wrist target.
var arm_reference: Dictionary = {}
var arm_neutral: Dictionary = {}
var idle_neutral: Dictionary = {}
var arm_previous: Dictionary = {}
var arm_clips: Dictionary = {}
var arm_transition_from: Dictionary = {}
var arm_state := ""
var arm_transition := 1.0
var arm_was_holding := false
const ARM_CLIP_SAMPLES := 48
const ARM_BLEND_SECONDS := 0.20
var arm_sides: Dictionary = {}
var hand_frames: Dictionary = {}
var hand_samples: Dictionary = {}
# Conservative physical skirt envelope (metres), refined from skin vertices.
var skirt_top := 0.10
var skirt_bottom := -0.40
var skirt_depth := 0.17
var measured_skirt_width := 0.0

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
    setup_hand_geometry()
    calibrate_arm_pose()
    measure_skirt_geometry()
    ready = true

func setup_hand_geometry() -> void:
    for side in ["left", "right"]:
        var hand: int = rig.target_keys[side + "Hand"]
        var middle := skeleton.find_bone("VRM_" + side + "MiddleProximal")
        var index := skeleton.find_bone("VRM_" + side + "IndexProximal")
        var little := skeleton.find_bone("VRM_" + side + "LittleProximal")
        if little < 0:
            little = skeleton.find_bone("VRM_" + side + "PinkyProximal")
        var samples: Array[int] = [hand]
        for finger in ["Thumb", "Index", "Middle", "Ring", "Little", "Pinky"]:
            for joint in ["Proximal", "Intermediate", "Distal"]:
                var bone := skeleton.find_bone("VRM_" + side + finger + joint)
                if bone >= 0:
                    samples.append(bone)
        hand_samples[side] = samples
        if mini(middle, mini(index, little)) < 0:
            continue
        var rest := skeleton.get_bone_global_rest(hand)
        var along := (skeleton.get_bone_global_rest(middle).origin - rest.origin).normalized()
        var across := skeleton.get_bone_global_rest(index).origin - skeleton.get_bone_global_rest(little).origin
        across = (across - along * across.dot(along)).normalized()
        if across.length_squared() < 0.001 or along.length_squared() < 0.001:
            continue
        var frame := Basis(across, along, across.cross(along)).orthonormalized()
        hand_frames[side] = frame.inverse() * rest.basis.orthonormalized()
        # Set a small permanent finger curl in the model's own rest axes.
        # Thumb stays in its authored pose; all fingers retain their lengths.
        var side_sign := signf((rig.target_basis * (skeleton.get_bone_global_rest(middle).origin - rest.origin)).x)
        if is_zero_approx(side_sign):
            side_sign = 1.0 if side == "left" else -1.0
        var palm_sign := side_sign
        var palm := frame.z * palm_sign
        # In the T pose, use the down-facing palm surface to disambiguate.
        var common_palm: Vector3 = rig.target_basis * palm
        if absf(common_palm.y) > 0.2 and common_palm.y > 0.0:
            palm = -palm
        for finger in ["Index", "Middle", "Ring", "Little", "Pinky"]:
            for joint in ["Proximal", "Intermediate", "Distal"]:
                var bone := skeleton.find_bone("VRM_" + side + finger + joint)
                if bone < 0:
                    continue
                var parent := skeleton.get_bone_parent(bone)
                if parent < 0:
                    continue
                var children := skeleton.get_bone_children(bone)
                var rest_bone := skeleton.get_bone_global_rest(bone)
                var axis := rest_bone.origin - skeleton.get_bone_global_rest(parent).origin
                if not children.is_empty():
                    axis = skeleton.get_bone_global_rest(children[0]).origin - rest_bone.origin
                var curl_axis := axis.normalized().cross(palm).normalized()
                if curl_axis.length_squared() < 0.001:
                    continue
                # A relaxed hand has a small graded finger curl, not four
                # identical straight fingers. Preserve the model's thumb.
                var digit_gain := 0.85 if finger == "Index" else (1.0 if finger == "Middle" else (1.15 if finger == "Ring" else 1.30))
                var curl := deg_to_rad((15.0 if joint == "Intermediate" else 9.0) * digit_gain)
                var rotated := Basis(curl_axis, curl) * rest_bone.basis
                var local := skeleton.get_bone_global_rest(parent).basis.inverse() * rotated
                skeleton.set_bone_pose_rotation(bone, local.orthonormalized().get_rotation_quaternion())
    skeleton.force_update_all_bone_transforms()
    print("HAND_RIG frames=", hand_frames.size(), " samples=", hand_samples)

func measure_skirt_geometry() -> void:
    var hips: int = rig.target_keys["hips"]
    var pelvis := visual.to_local(skeleton.to_global(skeleton.get_bone_global_rest(hips).origin))
    # Inspect rest mesh vertices weighted to skirt bones. This measures the
    # actual fabric rather than assuming that joint centers are its edge.
    for node in avatar.find_children("*", "MeshInstance3D", true, false):
        var mesh_node := node as MeshInstance3D
        var skin := mesh_node.skin
        if mesh_node.mesh == null or skin == null:
            continue
        var skirt_binds: Dictionary = {}
        for bind in range(skin.get_bind_count()):
            var name := str(skin.get_bind_name(bind))
            var bone := skin.get_bind_bone(bind)
            if name.is_empty() and bone >= 0 and bone < skeleton.get_bone_count():
                name = str(skeleton.get_bone_name(bone))
            if name.begins_with("SEC_SKIRT_"):
                skirt_binds[bind] = true
        if skirt_binds.is_empty():
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
                    if skirt_binds.has(bones[i * stride + j]):
                        influence += weights[i * stride + j]
                if influence < 0.25:
                    continue
                var point := visual.to_local(mesh_node.to_global(vertices[i])) - pelvis
                # Reject unrelated vertices if importer coordinates differ.
                if absf(point.x) > 0.45 or absf(point.z) > 0.40 or point.y > 0.20 or point.y < -0.65:
                    continue
                measured_skirt_width = maxf(measured_skirt_width, absf(point.x))
                skirt_depth = maxf(skirt_depth, absf(point.z))
                skirt_top = maxf(skirt_top, point.y)
                skirt_bottom = minf(skirt_bottom, point.y)
    print("SKIRT_GEOMETRY width=", measured_skirt_width, " depth=", skirt_depth, " range=", skirt_bottom, ",", skirt_top)

func set_global_rotation(bone: int, desired: Basis, blend: float) -> void:
    var parent := skeleton.get_bone_parent(bone)
    if parent >= 0:
        desired = skeleton.get_bone_global_pose(parent).basis.orthonormalized().inverse() * desired
    var original := skeleton.get_bone_pose_rotation(bone)
    skeleton.set_bone_pose_rotation(bone, original.slerp(desired.orthonormalized().get_rotation_quaternion(), blend))
    skeleton.force_update_all_bone_transforms()

func limit_torso(activity: float) -> void:
    # Keep the base clip's subtle rotation but prevent a running-style bend.
    for key in ["hips", "spine", "chest", "upperChest", "neck", "head"]:
        if not rig.target_keys.has(key):
            continue
        var bone: int = rig.target_keys[key]
        var rest := skeleton.get_bone_global_rest(bone).basis.orthonormalized()
        var pose := skeleton.get_bone_global_pose(bone).basis.orthonormalized()
        # Limit forward lean/roll independently of yaw. The old total-angle
        # clamp also suppressed the hip rotation needed for natural walking.
        var common: Basis = rig.target_basis
        var relative := common * pose * rest.inverse() * common.inverse()
        var euler := relative.get_euler()
        var maximum := deg_to_rad(5.0 if key == "hips" else 8.0)
        euler.x = clampf(euler.x, -maximum, maximum)
        euler.z = clampf(euler.z, -maximum, maximum)
        # Preserve and modestly enhance authored transverse rotation.
        # Do not exaggerate forward lean or add artificial hip sway.
        var yaw_gain := 1.0 + activity * (0.12 if key in ["hips", "spine", "chest", "upperChest"] else 0.0)
        euler.y = clampf(euler.y * yaw_gain, -deg_to_rad(20.0), deg_to_rad(20.0))
        set_global_rotation(bone, common.inverse() * Basis.from_euler(euler) * common * rest, 1.0)

# Production retargeting pattern: calibrate an avatar-specific base pose,
# then transfer the animation relative to that pose. The idle reference
# is sampled once from the existing authored idle animation.
func calibrate_arm_pose() -> void:
    var common: Basis = rig.target_basis
    for side in ["left", "right"]:
        var upper: int = rig.target_keys[side + "UpperArm"]
        var lower: int = rig.target_keys[side + "LowerArm"]
        var hand: int = rig.target_keys[side + "Hand"]
        var rest_axis := skeleton.get_bone_global_rest(lower).origin - skeleton.get_bone_global_rest(upper).origin
        var sign_side := signf((common * rest_axis).x)
        if is_zero_approx(sign_side):
            sign_side = 1.0 if side == "left" else -1.0
        arm_sides[side] = sign_side
        for bone in [upper, lower, hand]:
            arm_reference[bone] = skeleton.get_bone_pose_rotation(bone)
        # Relaxed shoulder and elbow; the hand is slightly outboard of
        # the skirt. These are pose choices, not dynamic joint targets.
        orient_arm_segment(upper, lower, Vector3(sign_side * 0.22, -1.0, -0.025))
        orient_arm_segment(lower, hand, Vector3(sign_side * 0.12, -1.0, 0.16))
        stabilize_hand(side, sign_side)
        for bone in [upper, lower, hand]:
            arm_neutral[bone] = skeleton.get_bone_pose_rotation(bone)
            arm_previous[bone] = arm_neutral[bone]
        # A separate relaxed idle pose: elbows hang near the ribs and
        # hands rest against the skirt rather than clearing its widest hem.
        orient_arm_segment(upper, lower, Vector3(sign_side * 0.25, -1.0, -0.075))
        orient_arm_segment(lower, hand, Vector3(sign_side * 0.10, -1.0, 0.15))
        stabilize_hand(side, sign_side)
        for bone in [upper, lower, hand]:
            idle_neutral[bone] = skeleton.get_bone_pose_rotation(bone)
        # Do not leave the calibration applied to the donor animation.
        for bone in [upper, lower, hand]:
            skeleton.set_bone_pose_rotation(bone, arm_reference[bone])
        skeleton.force_update_all_bone_transforms()

# Reconstruct the bone orientation using the avatar's own rest axes.
# A shortest-arc aim from an arbitrarily twisted donor pose preserves its
# axial twist; the elbow can then appear bent sideways even with good angles.
# Match a rest flexion plane to a forward-facing anatomical plane instead.
func orient_arm_segment(bone: int, child: int, direction: Vector3) -> void:
    var common: Basis = rig.target_basis
    var rest := skeleton.get_bone_global_rest(bone)
    var rest_axis := (common * (skeleton.get_bone_global_rest(child).origin - rest.origin)).normalized()
    var axis := direction.normalized()
    var forward := Vector3.BACK
    var rest_forward := (forward - rest_axis * forward.dot(rest_axis)).normalized()
    var pose_forward := (forward - axis * forward.dot(axis)).normalized()
    if rest_forward.length_squared() < 0.001 or pose_forward.length_squared() < 0.001:
        rig.aim_arm_bone(bone, child, common.inverse() * direction, 1.0)
        return
    var from_frame := Basis(rest_axis, rest_forward, rest_axis.cross(rest_forward))
    var to_frame := Basis(axis, pose_forward, axis.cross(pose_forward))
    var desired := common.inverse() * to_frame * from_frame.inverse() * common * rest.basis
    set_global_rotation(bone, desired, 1.0)

# AnimGraph-style preparation: turn each donor clip into a complete
# avatar-specific arm pose stream once. Match each clip's own mean pose
# instead of treating walking as a large offset from the first idle frame.
# The independent idle/walk/backward streams share normalized phase with
# the base animation; no per-joint target reconstruction during gameplay.
func arm_bones() -> Array[int]:
    var result: Array[int] = []
    for side in ["left", "right"]:
        for suffix in ["UpperArm", "LowerArm", "Hand"]:
            result.append(int(rig.target_keys[side + suffix]))
    return result

func prepare_arm_clip(state: String, ap: AnimationPlayer, clip: StringName, donor: RefCounted, moving: bool) -> void:
    if ap == null or clip == &"" or not ap.has_animation(clip):
        return
    var duration := ap.get_animation(clip).length
    if duration <= 0.0:
        return
    var bones := arm_bones()
    var means: Dictionary = {}
    var raw: Array[Dictionary] = []
    ap.play(clip)
    ap.advance(0.0)
    for i in range(ARM_CLIP_SAMPLES):
        ap.seek(duration * float(i) / float(ARM_CLIP_SAMPLES), true)
        donor.apply_pose()
        var pose: Dictionary = {}
        for bone in bones:
            var q := skeleton.get_bone_pose_rotation(bone).normalized()
            pose[bone] = q
            if not means.has(bone):
                means[bone] = q
            else:
                var mean: Quaternion = means[bone]
                means[bone] = mean.slerp(q, 1.0 / float(i + 1)).normalized()
        raw.append(pose)
    var samples: Array[Dictionary] = []
    for i in range(ARM_CLIP_SAMPLES):
        ap.seek(duration * float(i) / float(ARM_CLIP_SAMPLES), true)
        donor.apply_pose()
        limit_torso(1.0 if moving else 0.0)
        for side in ["left", "right"]:
            var sign_side: float = arm_sides[side]
            var upper: int = rig.target_keys[side + "UpperArm"]
            var lower: int = rig.target_keys[side + "LowerArm"]
            var hand: int = rig.target_keys[side + "Hand"]
            var common: Basis = rig.target_basis
            # Transfer the authored rotation deltas, then extract the
            # sagittal swing. Retain the timing of the source gait rather
            # than inventing a separate procedural arm oscillator.
            for bone in [upper, lower]:
                var mean: Quaternion = means[bone]
                var source_pose: Quaternion = raw[i][bone]
                var neutral: Quaternion = arm_neutral[bone] if moving else idle_neutral[bone]
                var motion := (mean.inverse() * source_pose).normalized()
                var limit := 45.0 if moving else 5.0
                var gain := 1.0 if moving else 0.35
                var fraction := minf(gain, deg_to_rad(limit) / maxf(Quaternion.IDENTITY.angle_to(motion), 0.00001))
                skeleton.set_bone_pose_rotation(bone, (neutral * Quaternion.IDENTITY.slerp(motion, fraction)).normalized())
            skeleton.force_update_all_bone_transforms()
            var upper_axis := common * (skeleton.get_bone_global_pose(lower).origin - skeleton.get_bone_global_pose(upper).origin)
            var lower_axis := common * (skeleton.get_bone_global_pose(hand).origin - skeleton.get_bone_global_pose(lower).origin)
            var swing := clampf(atan2(upper_axis.z, -upper_axis.y), -0.52, 0.52) if moving else clampf(atan2(upper_axis.z, -upper_axis.y), -0.16, 0.05)
            var flex := clampf(atan2(lower_axis.z, -lower_axis.y) - swing, 0.12, 0.45) if moving else 0.20
            # Keep the elbow outboard, and flex the forearm forward, not
            # sideways through the ribs. No whole-skirt bounding box.
            var lateral := clampf(upper_axis.x * sign_side / maxf(0.001, -upper_axis.y), 0.18, 0.28) if moving else 0.25
            orient_arm_segment(upper, lower, Vector3(sign_side * lateral, -1.0, tan(swing)))
            orient_arm_segment(lower, hand, Vector3(sign_side * 0.10, -1.0, tan(swing + flex)))
            var wrist: Quaternion = arm_neutral[hand] if moving else idle_neutral[hand]
            skeleton.set_bone_pose_rotation(hand, wrist)
        skeleton.force_update_all_bone_transforms()
        var output: Dictionary = {}
        for bone in bones:
            output[bone] = skeleton.get_bone_pose_rotation(bone)
        samples.append(output)
    # A circular filter preserves the seam and removes abrupt direction
    # changes from retarget sampling, without any per-frame pose search.
    var baked: Array[Dictionary] = []
    for i in range(ARM_CLIP_SAMPLES):
        var output: Dictionary = {}
        for bone in bones:
            var before: Quaternion = samples[posmod(i - 1, ARM_CLIP_SAMPLES)][bone]
            var after: Quaternion = samples[(i + 1) % ARM_CLIP_SAMPLES][bone]
            var center: Quaternion = samples[i][bone]
            output[bone] = center.slerp(before.slerp(after, 0.5), 0.30).normalized()
        baked.append(output)
    arm_clips[state] = baked
    print("ARM_CLIP ", state, " samples=", baked.size(), " anatomical_flexion=true")

func clip_arm_pose(state: String, phase: float, bone: int) -> Quaternion:
    if not arm_clips.has(state):
        return arm_neutral[bone]
    var frames: Array = arm_clips[state]
    var cursor := fposmod(phase, 1.0) * float(frames.size())
    var first := floori(cursor)
    var second := (first + 1) % frames.size()
    var left: Quaternion = frames[first][bone]
    var right: Quaternion = frames[second][bone]
    return left.slerp(right, cursor - float(first)).normalized()

# A masked pose layer, with a single state-transition blend. The holding
# arm is excluded; the free arm continues to play its complete clip.
func keep_arms_clear(delta: float, _speed: float, holding: bool, state: String = "idle", phase: float = 0.0) -> void:
    if state != arm_state or holding != arm_was_holding:
        arm_transition_from = arm_previous.duplicate()
        # On release, start the formerly aimed arm from its current pose.
        if arm_was_holding and not holding:
            for suffix in ["UpperArm", "LowerArm", "Hand"]:
                var right_bone: int = rig.target_keys["right" + suffix]
                arm_transition_from[right_bone] = skeleton.get_bone_pose_rotation(right_bone)
        arm_transition = 0.0
        arm_state = state
        arm_was_holding = holding
    arm_transition = minf(1.0, arm_transition + delta / ARM_BLEND_SECONDS)
    var blend := smoothstep(0.0, 1.0, arm_transition)
    for side in ["left", "right"]:
        if holding and side == "right":
            continue
        for suffix in ["UpperArm", "LowerArm", "Hand"]:
            var bone: int = rig.target_keys[side + suffix]
            var desired := clip_arm_pose(state, phase, bone)
            var from: Quaternion = arm_transition_from.get(bone, arm_neutral[bone])
            var corrected := from.slerp(desired, blend).normalized()
            arm_previous[bone] = corrected
            skeleton.set_bone_pose_rotation(bone, corrected)
    skeleton.force_update_all_bone_transforms()

# This is used only once during calibration. In gameplay the wrist
# inherits forearm rotation through FK and retains authored local motion.
func stabilize_hand(side: String, sign_side: float) -> void:
    var hand: int = rig.target_keys[side + "Hand"]
    var lower: int = rig.target_keys[side + "LowerArm"]
    if not hand_frames.has(side):
        skeleton.set_bone_pose_rotation(hand, skeleton.get_bone_rest(hand).basis.get_rotation_quaternion())
        skeleton.force_update_all_bone_transforms()
        return
    var common: Basis = rig.target_basis
    var along := (common * (skeleton.get_bone_global_pose(hand).origin - skeleton.get_bone_global_pose(lower).origin)).normalized()
    var across := Vector3(0, 0, 1) - along * along.z
    if across.length_squared() < 0.001:
        across = Vector3(sign_side, 0, 0) - along * along.x * sign_side
    across = across.normalized()
    var frame := Basis(across, along, across.cross(along)).orthonormalized()
    var rest_offset: Basis = hand_frames[side]
    set_global_rotation(hand, common.inverse() * frame * rest_offset, 1.0)

func hand_points(side: String) -> Array[Vector3]:
    var result: Array[Vector3] = []
    for bone in hand_samples.get(side, []):
        var point := skeleton.get_bone_global_pose(bone).origin
        result.append(visual.to_local(skeleton.to_global(point)))
        # Include fingertip beyond the distal joint using its parent axis.
        var name := str(skeleton.get_bone_name(bone))
        if name.ends_with("Distal"):
            var parent := skeleton.get_bone_parent(bone)
            if parent >= 0:
                var axis := point - skeleton.get_bone_global_pose(parent).origin
                result.append(visual.to_local(skeleton.to_global(point + axis * 0.75)))
    if result.size() < 3:
        var wrist: int = rig.target_keys[side + "Hand"]
        var elbow: int = rig.target_keys[side + "LowerArm"]
        var at := visual.to_local(skeleton.to_global(skeleton.get_bone_global_pose(wrist).origin))
        var from := visual.to_local(skeleton.to_global(skeleton.get_bone_global_pose(elbow).origin))
        result.append(at + (at - from).normalized() * 0.12)
    return result

func hand_penetration(side: String, sign_side: float, extra_margin: float = 0.0) -> float:
    var hips: int = rig.target_keys["hips"]
    var pelvis := visual.to_local(skeleton.to_global(skeleton.get_bone_global_pose(hips).origin))
    var width := maxf(skirt_half_width, measured_skirt_width) + 0.035 + extra_margin
    var correction := 0.0
    for point in hand_points(side):
        var p := point - pelvis
        if p.y > skirt_top + 0.03 or p.y < skirt_bottom - 0.03:
            continue
        if absf(p.z) > skirt_depth + 0.035:
            continue
        # Conservative rectangle at hand height, rather than a narrow
        # ellipse that lets fingers clip the flared side of the garment.
        correction = maxf(correction, width - p.x * sign_side)
    return correction

# Rotate the entire arm chain about its shoulder. This retains the
# original elbow and wrist flexion, unlike a new IK pole every frame.
func abduct_chain(side: String, sign_side: float, radians: float) -> void:
    if radians <= 0.00001:
        return
    var bone: int = rig.target_keys[side + "UpperArm"]
    var common: Basis = rig.target_basis
    var pose := skeleton.get_bone_global_pose(bone).basis.orthonormalized()
    var turn := common.inverse() * Basis(Vector3.BACK, sign_side * radians) * common
    set_global_rotation(bone, turn * pose, 1.0)

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

func tick(delta: float, velocity: Vector3, grounded: bool, holding: bool, state: String = "idle", phase: float = 0.0) -> void:
    if not ready:
        return
    var facing := visual.global_transform.basis.z.normalized()
    var angular_speed := last_facing.angle_to(facing) / maxf(delta, 0.001)
    var turning := angular_speed > deg_to_rad(85.0) or player.global_position.distance_to(last_root) > 0.35
    last_facing = facing
    last_root = player.global_position
    var speed := Vector2(velocity.x, velocity.z).length()
    limit_torso(smoothstep(0.08, 2.5, speed))
    keep_arms_clear(delta, speed, holding, state, phase)
    var correction := clampf(float(rig.foot_ground_correction()), -0.065, 0.065) if grounded else 0.0
    pelvis_offset = lerpf(pelvis_offset, correction, 1.0 - exp(-delta * 12.0))
    avatar.position.y = base_y + pelvis_offset
    for side in ["left", "right"]:
        contact_step(side, delta, turning, grounded)
