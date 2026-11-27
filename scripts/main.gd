extends Node

const Saves = preload("res://scripts/save_store.gd")
const FACILITY := "res://assets/facility.glb"
const UNIT := "res://assets/unit.glb"
const CHARACTER := "res://assets/locomotion.glb"
const AVATAR := "res://assets/shino.glb"
const HumanoidRetarget = preload("res://scripts/humanoid_retarget.gd")
const HouseholdProps = preload("res://scripts/household_props.gd")
const NaturalGait = preload("res://scripts/natural_gait.gd")
const SecondaryCollision = preload("res://scripts/secondary_collision.gd")
const DIRECTIONAL_CHARACTER := "res://assets/directional_walk.glb"
const SPEED := 3.4
const TRAVEL_TURN_RATE := deg_to_rad(420.0)
const TRAVEL_TURN_RESPONSE := 12.0
const CARRY_TURN_LIMIT := deg_to_rad(65.0)
var carry_backward := false
var carry_was_holding := false
var carry_was_moving := false
var carry_aim_ready := false
const ROLLUP_SCENE = preload("res://scenes/rollup_unit.tscn")
const CHARACTER_HEIGHT := 1.7
const PLAYER_CAPSULE_HEIGHT := 1.65
const PLAYER_CAPSULE_RADIUS := 0.27
const REACH := 2.0
const STEP_HEIGHT := 0.44
const STEP_PRESENTATION_RATE := 1.8
const STEP_EDGE_REACH := 0.27
const STEP_MARGIN := 0.002
const CAMERA_DISTANCE := 3.0
const CAMERA_PITCH_LIMIT := deg_to_rad(89.5)
const CAMERA_COLLISION_RADIUS := 0.16
const CAMERA_COLLISION_MARGIN := 0.035
const CAMERA_MIN_DISTANCE := 0.06
const CAMERA_RETURN_RATE := 10.0
const CAMERA_TARGET_HEIGHT := 1.1
const CAMERA_SENSITIVITY := 0.004
var camera_yaw := 0.0
var camera_pitch := 0.50
var camera_target := Vector3.ZERO
var camera_distance := CAMERA_DISTANCE
var camera_probe := SphereShape3D.new()
var camera_touch := -1
var camera_mouse_paused := false
var visual_step_offset := 0.0
var avatar_model: Node3D
var avatar_base_y := 0.0
var foot_offset := 0.0
var movement_joystick: Control
var stepped_last_frame := false
var reference_unit_height := 2.4
var rollup_unit: Node3D
var household: HouseholdProps
var natural_gait: NaturalGait
var secondary_collision: SecondaryCollision
var directional_animator: AnimationPlayer
var directional_rig: HumanoidRetarget
var direction_clips: Dictionary = {}
var gait_clip: StringName = &""
var gait_directional := false
var gait_blend := 1.0
var gait_from: Dictionary = {}
var force_pose_weight := 0.0
var force_target := Vector3.ZERO
var state: Dictionary = {}
var doors: Array[Dictionary] = []
var world: Node3D
var player: CharacterBody3D
var visual: Node3D
var animator: AnimationPlayer
var retargeter: HumanoidRetarget
var avatar_ready := false
var walk: StringName
var idle: StringName
var camera: Camera3D
var menu: Control
var hud: Control
var use_button: Button
var prompt: Label
var nearby := -1
var save_clock := 0.0
var mobile := OS.get_name() == "Android"

func _ready() -> void:
    # The mounted patch, not the original APK's updater, owns update dialogs.
    preload("res://scripts/update_bridge.gd").attach(self)
    for pair in [["move_up", KEY_W], ["move_down", KEY_S], ["move_left", KEY_A], ["move_right", KEY_D], ["use", KEY_E], ["grab", KEY_G]]:
        var action := StringName(pair[0])
        if not InputMap.has_action(action):
            InputMap.add_action(action)
        var key := InputEventKey.new()
        key.physical_keycode = pair[1]
        InputMap.action_add_event(action, key)
    show_menu()
    if "--storage-smoke" in OS.get_cmdline_user_args():
        call_deferred("_smoke")

func show_menu() -> void:
    var canvas := CanvasLayer.new()
    canvas.name = "MenuLayer"
    add_child(canvas)
    menu = Control.new()
    menu.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    canvas.add_child(menu)
    var bg := ColorRect.new()
    bg.color = Color(0.07, 0.09, 0.11)
    bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    menu.add_child(bg)
    var center := CenterContainer.new()
    center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    menu.add_child(center)
    var column := VBoxContainer.new()
    column.add_theme_constant_override("separation", 20)
    center.add_child(column)
    var new_button := Button.new()
    new_button.text = "New Game"
    new_button.custom_minimum_size = Vector2(280, 64)
    new_button.add_theme_font_size_override("font_size", 26)
    column.add_child(new_button)
    new_button.pressed.connect(func(): start_game(Saves.new_slot()))
    var continue_button := Button.new()
    continue_button.text = "Continue"
    continue_button.custom_minimum_size = Vector2(280, 64)
    continue_button.add_theme_font_size_override("font_size", 26)
    continue_button.disabled = Saves.latest().is_empty()
    column.add_child(continue_button)
    continue_button.pressed.connect(func():
        var saved := Saves.latest()
        if not saved.is_empty():
            start_game(saved)
    )

func model(path: String, parent: Node3D) -> Node3D:
    var scene := load(path) as PackedScene
    if scene == null:
        push_error("Missing imported asset: " + path + ". Run python tools/fetch_assets.py first.")
        return null
    var instance := scene.instantiate() as Node3D
    parent.add_child(instance)
    return instance

func animation_in(node: Node) -> AnimationPlayer:
    if node == null:
        return null
    if node is AnimationPlayer:
        return node
    for child in node.get_children():
        var found := animation_in(child)
        if found != null:
            return found
    return null

func named_animation(ap: AnimationPlayer, needle: String) -> StringName:
    if ap == null:
        return &""
    for clip in ap.get_animation_list():
        var lower := str(clip).to_lower().get_file()
        if lower == needle or lower.begins_with(needle + "_"):
            return clip
    for clip in ap.get_animation_list():
        if str(clip).to_lower().contains(needle):
            return clip
    return &""

func start_game(data: Dictionary) -> void:
    if is_instance_valid(world):
        return
    for path in [FACILITY, UNIT, CHARACTER, AVATAR, DIRECTIONAL_CHARACTER, "res://assets/prop_fridge.glb", "res://assets/prop_desk.glb", "res://assets/prop_screwdriver.glb", "res://assets/prop_boombox.glb"]:
        if not (ResourceLoader.load(path) is PackedScene):
            OS.alert("Run python tools/fetch_assets.py and import the project first.", "Missing model assets")
            return
    state = data.duplicate(true)
    menu.get_parent().queue_free()
    world = Node3D.new()
    world.name = "FacilityWorld"
    add_child(world)
    var env := WorldEnvironment.new()
    env.environment = Environment.new()
    env.environment.background_mode = Environment.BG_COLOR
    env.environment.background_color = Color(0.55, 0.65, 0.75)
    env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    env.environment.ambient_light_color = Color(0.85, 0.89, 1.0)
    env.environment.ambient_light_energy = 0.8
    world.add_child(env)
    var sun := DirectionalLight3D.new()
    sun.rotation_degrees = Vector3(-55, -35, 0)
    sun.light_energy = 1.1
    sun.shadow_enabled = true
    world.add_child(sun)
    var ground := MeshInstance3D.new()
    var slab := BoxMesh.new()
    slab.size = Vector3(64, 0.2, 64)
    ground.mesh = slab
    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(0.37, 0.39, 0.39)
    ground.material_override = mat
    ground.position = Vector3(0, -0.13, 0)
    world.add_child(ground)
    # A solid primitive floor gives small fast-moving rigid bodies reliable
    # volume contact rather than depending on a thin triangle mesh.
    wall(world, ground.position, slab.size)
    # Invisible containment for physics props only. Player/camera behavior
    # and facility appearance are unchanged.
    for side in [-1.0, 1.0]:
        var x_boundary := wall(world, Vector3(side * 30.25, 9.0, 0), Vector3(0.5, 20.0, 61.0))
        x_boundary.collision_layer = HouseholdProps.PROP_BOUNDARY_LAYER
        x_boundary.collision_mask = HouseholdProps.PROP_LAYER
        var z_boundary := wall(world, Vector3(0, 9.0, side * 30.25), Vector3(61.0, 20.0, 0.5))
        z_boundary.collision_layer = HouseholdProps.PROP_BOUNDARY_LAYER
        z_boundary.collision_mask = HouseholdProps.PROP_LAYER
    var facility := model(FACILITY, world)
    add_static_mesh_collisions(facility)
    # Starter scene is static. An additional row uses the pack's actual
    # animated, standalone units, with per-door collision and persistent IDs.
    for i in range(4):
        make_unit("unit_%02d" % i, Vector3(-13.0, 0, -4.5 + i * 3.15))
    make_rollup_unit(facility)
    player = CharacterBody3D.new()
    player.name = "Player"
    player.collision_mask = 3
    player.floor_snap_length = STEP_HEIGHT + 0.04
    player.floor_max_angle = deg_to_rad(50.0)
    player.floor_constant_speed = true
    player.floor_stop_on_slope = true
    player.safe_margin = STEP_MARGIN
    world.add_child(player)
    var collision := CollisionShape3D.new()
    var capsule := CapsuleShape3D.new()
    capsule.radius = PLAYER_CAPSULE_RADIUS
    capsule.height = PLAYER_CAPSULE_HEIGHT
    collision.shape = capsule
    collision.position.y = PLAYER_CAPSULE_HEIGHT * 0.5
    player.add_child(collision)
    visual = Node3D.new()
    visual.name = "CharacterVisual"
    player.add_child(visual)
    var donor := model(CHARACTER, visual)
    var avatar := model(AVATAR, visual)
    avatar_model = avatar
    # The original VRM 0.x model faces -Z, while the game uses +Z forward.
    avatar.rotation.y = PI
    var bounds := model_bounds(avatar)
    if bounds.size.y > 0.01:
        var factor := CHARACTER_HEIGHT / bounds.size.y
        avatar.scale = Vector3.ONE * factor
        avatar.position.y = -bounds.position.y * factor
    avatar_base_y = avatar.position.y
    retargeter = HumanoidRetarget.new()
    avatar_ready = retargeter.setup(donor, avatar, visual)
    donor.visible = not avatar_ready
    avatar.visible = avatar_ready
    if not avatar_ready:
        push_error("Avatar retarget failed; showing the original character.")
    animator = animation_in(donor)
    walk = named_animation(animator, "walk_loop")
    if walk == &"":
        walk = named_animation(animator, "walk")
    idle = named_animation(animator, "idle_loop")
    if idle == &"":
        idle = named_animation(animator, "idle")
    if animator != null:
        for clip in [walk, idle]:
            if clip != &"":
                animator.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
        if idle != &"":
            animator.play(idle)
        animator.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
        animator.advance(0.0)
        if avatar_ready:
            retargeter.apply_pose()
    var p: Array = state["position"]
    player.position = Vector3(float(p[0]), float(p[1]), float(p[2]))
    visual.rotation.y = float(state.get("rotation", 0.0))
    if avatar_ready:
        natural_gait = NaturalGait.new()
        natural_gait.setup(retargeter, player, visual, avatar_model, avatar_base_y)
        secondary_collision = SecondaryCollision.new()
        secondary_collision.setup(retargeter, visual, avatar_model)
        natural_gait.skirt_half_width = secondary_collision.skirt_half_width
        var directional_donor := model(DIRECTIONAL_CHARACTER, visual)
        directional_donor.visible = false
        directional_rig = HumanoidRetarget.new()
        if directional_rig.setup(directional_donor, avatar, visual):
            directional_animator = animation_in(directional_donor)
            if directional_animator != null:
                directional_animator.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
                for suffix in ["fwd", "fwd_l", "l", "bwd_l", "bwd", "bwd_r", "r", "fwd_r"]:
                    # Godot's scene importer can strip the _Loop suffix
                    # when inferring looping playback. Match the exact
                    # normalized direction, not a prefix of a diagonal.
                    var expected := "walk" + str(suffix).replace("_", "")
                    for clip in directional_animator.get_animation_list():
                        var key := str(clip).get_file().to_lower().replace("_", "").replace("-", "").replace(" ", "").trim_suffix("loop")
                        if key == expected:
                            direction_clips[suffix] = clip
                            directional_animator.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
                            break
                print("DIRECTIONAL_RIG ", direction_clips, " imported=", directional_animator.get_animation_list())
        # Prepare masked arm streams once, with the same donor clips that
        # drive the existing lower-body locomotion.
        natural_gait.prepare_arm_clip("idle", animator, idle, retargeter, false)
        natural_gait.prepare_arm_clip("walk", animator, walk, retargeter, true)
        if direction_clips.has("bwd"):
            natural_gait.prepare_arm_clip("backward", directional_animator, direction_clips["bwd"], directional_rig, true)
        animator.play(idle)
        animator.seek(0.0, true)
        retargeter.apply_pose()
    camera = Camera3D.new()
    camera.fov = 65
    camera.near = 0.035
    camera_probe.radius = CAMERA_COLLISION_RADIUS
    world.add_child(camera)
    camera.current = true
    camera_yaw = float(state.get("camera_yaw", 0.0))
    camera_pitch = clampf(float(state.get("camera_pitch", 0.50)), -CAMERA_PITCH_LIMIT, CAMERA_PITCH_LIMIT)
    camera_target = player.position + Vector3.UP * CAMERA_TARGET_HEIGHT
    update_camera(0.0)
    create_hud()
    household = HouseholdProps.new()
    household.name = "HouseholdProps"
    world.add_child(household)
    household.setup(player, camera, hud, mobile)
    household.spawn_items(state.get("props", {}), int(state.get("prop_layout", 0)))
    if not mobile and DisplayServer.get_name() != "headless":
        Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
    save_game()

func add_static_mesh_collisions(node: Node) -> void:
    if node == null:
        return
    if node is MeshInstance3D and node.mesh != null:
        node.create_trimesh_collision()
    for child in node.get_children():
        if child is Node3D and not child is CollisionObject3D:
            add_static_mesh_collisions(child)

func model_bounds(root: Node3D) -> AABB:
    var result := AABB()
    var first := true
    for child in root.find_children("*", "MeshInstance3D", true, false):
        var mesh_node := child as MeshInstance3D
        if mesh_node.mesh == null:
            continue
        var local := root.global_transform.affine_inverse() * mesh_node.global_transform
        var bounds: AABB = local * mesh_node.get_aabb()
        result = bounds if first else result.merge(bounds)
        first = false
    return result

func wall(parent: Node3D, center: Vector3, size: Vector3) -> StaticBody3D:
    var body := StaticBody3D.new()
    parent.add_child(body)
    body.position = center
    var col := CollisionShape3D.new()
    var shape := BoxShape3D.new()
    shape.size = size
    col.shape = shape
    body.add_child(col)
    return body

func make_unit(id: String, at: Vector3) -> void:
    var unit := Node3D.new()
    unit.name = id
    world.add_child(unit)
    unit.position = at
    unit.rotation.y = PI / 2.0
    var asset := model(UNIT, unit)
    if doors.is_empty():
        var bounds := model_bounds(asset)
        if bounds.size.y > 1.8:
            reference_unit_height = bounds.size.y
    var ap := animation_in(asset)
    wall(unit, Vector3(-1.45, 1.2, 0), Vector3(0.12, 2.4, 3.0))
    wall(unit, Vector3(1.45, 1.2, 0), Vector3(0.12, 2.4, 3.0))
    wall(unit, Vector3(0, 1.2, -1.45), Vector3(3.0, 2.4, 0.12))
    var blocker := wall(unit, Vector3(0, 1.12, 1.42), Vector3(2.8, 2.24, 0.14))
    var opened := bool(state.get("doors", {}).get(id, false))
    var door := {"id": id, "node": unit, "player": ap, "blocker": blocker, "open": opened, "busy": false}
    doors.append(door)
    if ap != null:
        var clip := named_animation(ap, "open" if opened else "close")
        if clip != &"":
            ap.get_animation(clip).loop_mode = Animation.LOOP_NONE
            ap.play(clip)
            ap.seek(ap.get_animation(clip).length, true)
            ap.pause()
    blocker.collision_layer = 0 if opened else 1

# Choose a vacant ground-level footprint using the actual imported mesh
# triangles, not a guessed interior coordinate or a facility-wide AABB.
func make_rollup_unit(facility: Node3D) -> void:
    var obstacles: Array[AABB] = []
    for child in facility.find_children("*", "MeshInstance3D", true, false):
        var mesh_node := child as MeshInstance3D
        if mesh_node.mesh == null:
            continue
        var transform := mesh_node.global_transform
        var faces := mesh_node.mesh.get_faces()
        for i in range(0, faces.size(), 3):
            var p0 := transform * faces[i]
            var p1 := transform * faces[i + 1]
            var p2 := transform * faces[i + 2]
            var bounds := AABB(p0, Vector3.ZERO).expand(p1).expand(p2)
            # Ignore ground-level slabs and geometry wholly above the roof.
            if bounds.end.y <= 0.08 or bounds.position.y >= reference_unit_height + 0.1:
                continue
            obstacles.append(bounds.grow(0.025))
    for entry in doors:
        var existing: Node3D = entry["node"]
        obstacles.append(AABB(existing.position - Vector3(1.6, 0, 1.6), Vector3(3.2, reference_unit_height, 3.2)))
    var candidates: Array[Vector3] = [Vector3(-13, 0, 8.1), Vector3(-13, 0, -7.8)]
    # Search outward from the existing row, within the existing playable slab.
    for z in range(-26, 27, 4):
        for x in range(-26, 27, 4):
            candidates.append(Vector3(x, 0, z))
    var chosen := Vector3.ZERO
    var found := false
    for candidate in candidates:
        # Include a clear approach to the +X-facing entrance.
        var footprint := AABB(candidate + Vector3(-1.65, 0.08, -1.65), Vector3(5.1, reference_unit_height - 0.08, 3.3))
        if footprint.has_point(Vector3(-10.4, 0.1, 5)):
            continue
        var occupied := false
        for obstacle in obstacles:
            if footprint.intersects(obstacle):
                occupied = true
                break
        if not occupied:
            chosen = candidate
            found = true
            break
    if not found:
        push_error("No clear floor footprint for roll-up prototype")
        return
    var unit := ROLLUP_SCENE.instantiate()
    unit.name = "rollup_00"
    world.add_child(unit)
    unit.position = chosen
    unit.rotation.y = PI / 2.0
    var opened := bool(state.get("doors", {}).get("rollup_00", false))
    unit.build(reference_unit_height, opened)
    rollup_unit = unit
    doors.append({"id": "rollup_00", "node": unit, "player": unit.animator, "blocker": unit.blocker, "open": opened, "busy": false})
    print("ROLLUP_UNIT placement=", chosen, " height=", reference_unit_height)

func create_hud() -> void:
    var layer := CanvasLayer.new()
    add_child(layer)
    hud = Control.new()
    hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
    layer.add_child(hud)
    prompt = Label.new()
    prompt.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
    prompt.offset_left = -170
    prompt.offset_right = 170
    prompt.offset_top = -75
    prompt.offset_bottom = -30
    prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    prompt.add_theme_font_size_override("font_size", 24)
    hud.add_child(prompt)
    if not mobile:
        return
    var joystick := VirtualJoystick.new()
    joystick.name = "MovementJoystick"
    joystick.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
    joystick.offset_left = -242.0
    joystick.offset_top = -242.0
    joystick.offset_right = -22.0
    joystick.offset_bottom = -22.0
    joystick.joystick_size = 164.0
    joystick.tip_size = 62.0
    joystick.deadzone_ratio = 0.10
    joystick.joystick_mode = VirtualJoystick.JOYSTICK_FIXED
    joystick.visibility_mode = VirtualJoystick.VISIBILITY_ALWAYS
    joystick.action_up = &"move_up"
    joystick.action_down = &"move_down"
    joystick.action_left = &"move_left"
    joystick.action_right = &"move_right"

    var joystick_style := StyleBoxFlat.new()
    joystick_style.bg_color = Color(0.72, 0.78, 0.90, 0.11)
    joystick_style.border_color = Color(0.84, 0.89, 1.0, 0.28)
    joystick_style.set_border_width_all(2)
    joystick_style.set_corner_radius_all(999)

    var joystick_pressed := joystick_style.duplicate() as StyleBoxFlat
    joystick_pressed.bg_color = Color(0.72, 0.78, 0.90, 0.16)

    var tip_style := StyleBoxFlat.new()
    tip_style.bg_color = Color(0.84, 0.89, 1.0, 0.24)
    tip_style.border_color = Color(0.90, 0.94, 1.0, 0.40)
    tip_style.set_border_width_all(2)
    tip_style.set_corner_radius_all(999)

    var tip_pressed := tip_style.duplicate() as StyleBoxFlat
    tip_pressed.bg_color = Color(0.84, 0.89, 1.0, 0.32)

    joystick.add_theme_stylebox_override("normal_joystick", joystick_style)
    joystick.add_theme_stylebox_override("pressed_joystick", joystick_pressed)
    joystick.add_theme_stylebox_override("normal_tip", tip_style)
    joystick.add_theme_stylebox_override("pressed_tip", tip_pressed)
    hud.add_child(joystick)
    movement_joystick = joystick
    use_button = Button.new()
    use_button.text = "Use"
    use_button.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
    use_button.offset_left = -230
    use_button.offset_right = -34
    use_button.offset_top = -330
    use_button.offset_bottom = -258
    use_button.add_theme_font_size_override("font_size", 26)
    use_button.mouse_filter = Control.MOUSE_FILTER_IGNORE
    use_button.hide()
    hud.add_child(use_button)

func orbit_camera(relative: Vector2) -> void:
    camera_yaw = wrapf(camera_yaw - relative.x * CAMERA_SENSITIVITY, -PI, PI)
    camera_pitch = clampf(camera_pitch + relative.y * CAMERA_SENSITIVITY, -CAMERA_PITCH_LIMIT, CAMERA_PITCH_LIMIT)

func _input(event: InputEvent) -> void:
    if not is_instance_valid(player):
        return
    if mobile:
        if event is InputEventScreenTouch:
            if not event.pressed:
                if event.index == camera_touch:
                    camera_touch = -1
                return
            if is_instance_valid(household) and household.button.visible and household.button.get_global_rect().has_point(event.position):
                household.toggle_grab()
                get_viewport().set_input_as_handled()
                return
            if is_instance_valid(use_button) and use_button.visible and use_button.get_global_rect().has_point(event.position):
                use_nearby()
                get_viewport().set_input_as_handled()
                return
            if is_instance_valid(movement_joystick) and movement_joystick.get_global_rect().has_point(event.position):
                return
            if camera_touch == -1:
                camera_touch = event.index
                get_viewport().set_input_as_handled()
        elif event is InputEventScreenDrag and event.index == camera_touch:
            orbit_camera(event.relative)
            get_viewport().set_input_as_handled()
        return
    if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_ESCAPE:
        camera_mouse_paused = not camera_mouse_paused
        Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if camera_mouse_paused else Input.MOUSE_MODE_CAPTURED
        get_viewport().set_input_as_handled()
    elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
        orbit_camera(event.relative)
        get_viewport().set_input_as_handled()

func update_camera(delta: float) -> void:
    var target := player.position + Vector3.UP * (CAMERA_TARGET_HEIGHT + visual_step_offset)
    if delta <= 0.0:
        camera_target = target
    else:
        camera_target = camera_target.lerp(target, 1.0 - exp(-delta * 14.0))
    var offset := Vector3(0.0, sin(camera_pitch), cos(camera_pitch)).rotated(Vector3.UP, camera_yaw)
    # Never interpolate through an obstruction. Contract immediately and
    # ease outward only while the entire requested path remains clear.
    var allowed := camera_clear_distance(camera_target, offset)
    if delta <= 0.0 or allowed < camera_distance:
        camera_distance = allowed
    else:
        camera_distance = minf(allowed, lerpf(camera_distance, allowed, 1.0 - exp(-delta * CAMERA_RETURN_RATE)))
    camera.position = camera_target + offset * camera_distance
    camera.look_at(camera_target)

func camera_clear_distance(origin: Vector3, direction: Vector3) -> float:
    var space := player.get_world_3d().direct_space_state
    var motion := direction.normalized() * CAMERA_DISTANCE
    # A volume sweep accounts for near-plane clearance at wall edges,
    # unlike a ray alone. Ignore the player's own capsule and prop-only
    # perimeter boundaries, but include actual household props and walls.
    var query := PhysicsShapeQueryParameters3D.new()
    query.shape = camera_probe
    query.transform = Transform3D(Basis.IDENTITY, origin)
    query.motion = motion
    query.collision_mask = 3
    query.exclude = [player.get_rid()]
    query.margin = CAMERA_COLLISION_MARGIN
    var fractions := space.cast_motion(query)
    var allowed := CAMERA_DISTANCE
    if fractions.size() >= 2:
        allowed = CAMERA_DISTANCE * fractions[0]
    # cast_motion can ignore shapes that overlap the starting sphere.
    # A center ray also prevents passing through a solid in that case.
    var ray := PhysicsRayQueryParameters3D.create(origin, origin + motion, 3, [player.get_rid()])
    ray.hit_from_inside = true
    var hit := space.intersect_ray(ray)
    if not hit.is_empty():
        var hit_distance := origin.distance_to(Vector3(hit["position"]))
        allowed = minf(allowed, hit_distance - CAMERA_COLLISION_RADIUS - CAMERA_COLLISION_MARGIN)
    return clampf(allowed, CAMERA_MIN_DISTANCE, CAMERA_DISTANCE)

# Step up only when grounded, blocked by an obstacle, and a capsule sweep
# confirms clearance upward, forward, and a walkable landing below.
# This does not disable collision or let the player pass through tall walls.
func try_step_up(body: CharacterBody3D, motion: Vector3) -> bool:
    if motion.length_squared() < 0.000001:
        return false
    var start := body.global_transform
    var obstacle := KinematicCollision3D.new()
    if not body.test_move(start, motion, obstacle, STEP_MARGIN):
        return false
    if obstacle.get_normal().dot(Vector3.UP) >= cos(body.floor_max_angle):
        return false
    var rise := Vector3.UP * STEP_HEIGHT
    if body.test_move(start, rise, null, STEP_MARGIN):
        return false
    var raised := start
    raised.origin += rise
    # Advance exactly the requested movement, never a larger probe distance.
    if body.test_move(raised, motion, null, STEP_MARGIN):
        return false
    var ahead := raised
    ahead.origin += motion
    var landing := KinematicCollision3D.new()
    var down := -Vector3.UP * (STEP_HEIGHT + 0.08)
    var collided := body.test_move(ahead, down, landing, STEP_MARGIN)
    if not collided:
        return false
    var destination := ahead.origin + landing.get_travel()
    # A capsule meeting the edge of a tread may report an angled contact
    # instead of the actual horizontal landing. Probe the leading edge,
    # but do not move the body horizontally to that probe position.
    if landing.get_normal().dot(Vector3.UP) < cos(body.floor_max_angle):
        var edge := ahead.origin + motion.normalized() * STEP_EDGE_REACH
        var query := PhysicsRayQueryParameters3D.create(edge + Vector3.UP * 0.02, edge + down, body.collision_mask, [body.get_rid()])
        var hit := body.get_world_3d().direct_space_state.intersect_ray(query)
        if hit.is_empty() or Vector3(hit["normal"]).dot(Vector3.UP) < cos(body.floor_max_angle):
            return false
        var surface: Vector3 = hit["position"]
        var target_y := surface.y + STEP_MARGIN
        var edge_descent := Vector3.UP * (target_y - ahead.origin.y)
        if edge_descent.y > 0.0:
            return false
        var clearance := KinematicCollision3D.new()
        if body.test_move(ahead, edge_descent, clearance, STEP_MARGIN):
            if clearance.get_travel().distance_to(edge_descent) > 0.012:
                return false
        destination = Vector3(ahead.origin.x, target_y, ahead.origin.z)
    var height := destination.y - start.origin.y
    if height <= 0.005 or height > STEP_HEIGHT + STEP_MARGIN:
        return false
    destination.x = ahead.origin.x
    destination.z = ahead.origin.z
    body.global_position = destination
    return true

func _physics_process(delta: float) -> void:
    if not is_instance_valid(player):
        return
    var input := Input.get_vector("move_left", "move_right", "move_up", "move_down")
    var direction := Vector3(input.x, 0, input.y).rotated(Vector3.UP, camera_yaw)
    # All joystick headings use the same shortest-arc turn. Ease translation
    # while making a large turn so the feet do not slide backward.
    if direction.length() > 0.05 and not (is_instance_valid(household) and is_instance_valid(household.held)):
        var target_yaw := travel_yaw(direction)
        var turn_error := absf(angle_difference(visual.rotation.y, target_yaw))
        var alignment := clampf(cos(turn_error), 0.0, 1.0)
        direction *= lerpf(0.48, 1.0, alignment)
    if is_instance_valid(rollup_unit):
        direction = rollup_unit.filter_player_motion(player, direction, PLAYER_CAPSULE_HEIGHT, PLAYER_CAPSULE_RADIUS)
    var grounded := player.is_on_floor() or stepped_last_frame
    var previous_position := player.position
    player.velocity.x = direction.x * SPEED
    player.velocity.z = direction.z * SPEED
    if not grounded:
        player.velocity.y -= 18.0 * delta
    else:
        player.velocity.y = -0.1
    var stepped := grounded and try_step_up(player, direction * SPEED * delta)
    if stepped:
        player.velocity.x = 0.0
        player.velocity.z = 0.0
        player.velocity.y = -0.1
    player.move_and_slide()
    if grounded and not player.is_on_floor() and player.velocity.y <= 0.0:
        player.apply_floor_snap()
    stepped_last_frame = stepped
    if is_instance_valid(rollup_unit):
        # Push before advancing the descending collision to avoid trapping
        # the capsule inside a suddenly enlarged shape.
        rollup_unit.push_player(player, delta, PLAYER_CAPSULE_HEIGHT, PLAYER_CAPSULE_RADIUS)
        rollup_unit.advance_door(delta)
    var height_change := player.position.y - previous_position.y
    if grounded and absf(height_change) > 0.025:
        visual_step_offset = clampf(visual_step_offset - height_change, -0.30, 0.30)
    visual_step_offset = move_toward(visual_step_offset, 0.0, STEP_PRESENTATION_RATE * delta)
    visual.position.y = visual_step_offset
    player.position.x = clampf(player.position.x, -29, 29)
    player.position.z = clampf(player.position.z, -29, 29)
    if player.position.y < -5:
        player.position = Vector3(-10.4, 0.1, 5)
        visual_step_offset = 0.0
        visual.position.y = 0.0
    var carrying := is_instance_valid(household) and is_instance_valid(household.held)
    if carrying:
        var facing := household.held.global_position - player.global_position
        facing.y = 0.0
        if facing.length_squared() > 0.01:
            var moving_input := direction.length() > 0.05
            var aim_yaw := travel_yaw(facing)
            if moving_input:
                var relative := facing.normalized().dot(direction.normalized())
                carry_backward = carry_reverse_mode(relative, carry_backward and carry_was_holding and carry_was_moving)
                # Turn toward travel (or the opposite for backpedaling),
                # but stay within reach of the held object. There are no
                # lateral/diagonal gait switches.
                var walk_yaw := travel_yaw(direction) + (PI if carry_backward else 0.0)
                aim_yaw += clampf(angle_difference(aim_yaw, walk_yaw), -CARRY_TURN_LIMIT, CARRY_TURN_LIMIT)
            else:
                carry_backward = false
            visual.rotation.y = smooth_travel_turn(visual.rotation.y, aim_yaw, delta)
            carry_was_moving = moving_input
    elif direction.length() > 0.05:
        visual.rotation.y = smooth_travel_turn(visual.rotation.y, travel_yaw(direction), delta)
    carry_was_holding = carrying
    if not carrying:
        carry_backward = false
        carry_was_moving = false
    if animator != null:
        var displacement := player.position - previous_position
        var ground_speed := Vector2(displacement.x, displacement.z).length() / maxf(delta, 0.001)
        var moving := ground_speed > 0.08 and direction.length() > 0.05
        if avatar_ready:
            var animation_velocity := displacement / maxf(delta, 0.001)
            # Explicit two-clip carrying locomotion. Never classify measured
            # diagonal velocity into a new animation on every physics tick.
            var requested_suffix := "bwd" if carrying and carry_backward else "fwd"
            animate_directional(delta, animation_velocity, moving, requested_suffix)
            if natural_gait != null and natural_gait.ready:
                var holding_prop := is_instance_valid(household) and is_instance_valid(household.held)
                var arm_state := "idle" if not moving else ("backward" if gait_directional else "walk")
                var arm_player := directional_animator if gait_directional else animator
                var arm_phase := 0.0
                if arm_player != null and gait_clip != &"" and arm_player.has_animation(gait_clip):
                    arm_phase = arm_player.current_animation_position / maxf(arm_player.get_animation(gait_clip).length, 0.001)
                natural_gait.tick(delta, displacement / maxf(delta, 0.001), player.is_on_floor() or stepped_last_frame, holding_prop, arm_state, arm_phase)
            else:
                foot_offset = lerpf(foot_offset, retargeter.foot_ground_correction(), 1.0 - exp(-delta * 24.0))
                avatar_model.position.y = avatar_base_y + foot_offset
    update_camera(delta)
    if is_instance_valid(household):
        household.tick(delta)
        if Input.is_action_just_pressed("grab"):
            household.toggle_grab()
        var holding := is_instance_valid(household.held)
        if holding:
            var target_point := household.held.global_position
            if not carry_aim_ready:
                force_target = target_point
                carry_aim_ready = true
            else:
                force_target = force_target.lerp(target_point, 1.0 - exp(-delta * 16.0))
        else:
            carry_aim_ready = false
        force_pose_weight = move_toward(force_pose_weight, 1.0 if holding else 0.0, delta * 6.0)
        if avatar_ready and force_pose_weight > 0.0:
            retargeter.apply_force_pose(force_target, force_pose_weight)
    if secondary_collision != null:
        secondary_collision.tick(delta, natural_gait, is_instance_valid(household) and is_instance_valid(household.held))
    update_nearby()
    if Input.is_action_just_pressed("use"):
        use_nearby()
    save_clock += delta
    if save_clock >= 2.0:
        save_clock = 0
        save_game()

# Direction classification occurs in the character's own anatomical
# coordinate space, not global axes or camera pitch.
func gait_suffix(local_velocity: Vector3) -> String:
    var left_sign := 1.0
    if avatar_ready:
        var left_bone: int = retargeter.target_keys["leftUpperLeg"]
        var right_bone: int = retargeter.target_keys["rightUpperLeg"]
        var left_axis: Vector3 = retargeter.target_basis * (retargeter.target.get_bone_global_rest(left_bone).origin - retargeter.target.get_bone_global_rest(right_bone).origin)
        left_sign = signf(left_axis.x)
    var heading := atan2(local_velocity.x * left_sign, local_velocity.z)
    var sector := posmod(roundi(heading / (PI / 4.0)), 8)
    return ["fwd", "fwd_l", "l", "bwd_l", "bwd", "bwd_r", "r", "fwd_r"][sector]

# Hysteresis prevents diagonal or jittering input from repeatedly
# switching the carry cycle. Rearward entry and exit have different limits.
func carry_reverse_mode(forward_dot: float, previously_backward: bool) -> bool:
    return forward_dot < (0.05 if previously_backward else -0.40)

func travel_yaw(direction: Vector3) -> float:
    return atan2(direction.x, direction.z)

func smooth_travel_turn(current: float, target: float, delta: float) -> float:
    var error := angle_difference(current, target)
    var step := clampf(error * (1.0 - exp(-delta * TRAVEL_TURN_RESPONSE)), -TRAVEL_TURN_RATE * delta, TRAVEL_TURN_RATE * delta)
    return wrapf(current + step, -PI, PI)

func animate_directional(delta: float, velocity: Vector3, moving: bool, requested_suffix: String = "") -> void:
    var suffix := gait_suffix(visual.global_transform.basis.inverse() * velocity) if moving else ""
    if moving and not requested_suffix.is_empty():
        suffix = requested_suffix
    var use_directional := moving and suffix == "bwd" and direction_clips.has("bwd")
    var ap := directional_animator if use_directional else animator
    var active_rig := directional_rig if use_directional else retargeter
    var clip: StringName = direction_clips[suffix] if use_directional else (walk if moving else idle)
    if clip == &"" or ap == null:
        return
    if clip != gait_clip or use_directional != gait_directional:
        var old_ap := directional_animator if gait_directional else animator
        var phase := 0.0
        if old_ap != null and gait_clip != &"" and old_ap.has_animation(gait_clip) and moving and gait_clip != idle:
            phase = fposmod(old_ap.current_animation_position / maxf(old_ap.get_animation(gait_clip).length, 0.001), 1.0)
        gait_from.clear()
        for bone in retargeter.target_keys.values():
            gait_from[bone] = retargeter.target.get_bone_pose_rotation(bone)
        gait_blend = 0.0
        gait_clip = clip
        gait_directional = use_directional
        ap.play(clip)
        ap.advance(0.0)
        if moving:
            ap.seek(phase * ap.get_animation(clip).length, true)
    var speed := Vector2(velocity.x, velocity.z).length()
    var playback := 1.0
    if moving:
        var cycle := lerpf(1.35, 1.02, clampf(speed / SPEED, 0.0, 1.0))
        if use_directional:
            cycle = lerpf(1.30, 1.05, clampf(speed / (SPEED * 0.68), 0.0, 1.0))
        playback = clampf(ap.get_animation(clip).length / cycle, 0.25, 1.15)
    ap.advance(delta * playback)
    active_rig.apply_pose()
    gait_blend = minf(1.0, gait_blend + delta / 0.12)
    if gait_blend < 1.0:
        var weight := smoothstep(0.0, 1.0, gait_blend)
        for bone in gait_from:
            var from_pose: Quaternion = gait_from[bone]
            retargeter.target.set_bone_pose_rotation(bone, from_pose.slerp(retargeter.target.get_bone_pose_rotation(bone), weight))
        retargeter.target.force_update_all_bone_transforms()

func update_nearby() -> void:
    if is_instance_valid(household) and household.has_panel_action():
        nearby = -2
        var text := household.panel_action_text()
        if mobile:
            use_button.visible = true
            use_button.text = text
        else:
            prompt.text = "E  " + text
        return
    nearby = -1
    var best := REACH
    for i in range(doors.size()):
        var door: Dictionary = doors[i]
        var node: Node3D = door["node"]
        var point := node.to_global(Vector3(0, 0, 1.7))
        var distance := player.position.distance_to(point)
        if distance < best and not door["busy"] and door["player"] != null:
            best = distance
            nearby = i
    if mobile:
        use_button.visible = nearby >= 0
        if nearby >= 0:
            use_button.text = "Close" if doors[nearby]["open"] else "Open"
    else:
        prompt.text = "" if nearby < 0 else ("E  Close" if doors[nearby]["open"] else "E  Open")

func use_nearby() -> void:
    if nearby == -2 and is_instance_valid(household):
        household.use_panel()
        return
    if nearby < 0 or nearby >= doors.size():
        return
    var door: Dictionary = doors[nearby]
    if door["busy"]:
        return
    var ap: AnimationPlayer = door["player"]
    var opening := not bool(door["open"])
    var node: Node3D = door["node"]
    var local := node.to_local(player.position)
    var rolling := node == rollup_unit
    if not rolling and not opening and absf(local.z - 1.42) < 0.55 and absf(local.x) < 1.6:
        return
    var clip := named_animation(ap, "open" if opening else "close")
    if clip == &"":
        return
    door["busy"] = true
    var blocker: StaticBody3D = door["blocker"]
    if rolling:
        rollup_unit.start_door_motion(opening)
    elif not opening:
        blocker.set_deferred("collision_layer", 1)
    ap.stop()
    ap.get_animation(clip).loop_mode = Animation.LOOP_NONE
    ap.play(clip)
    await ap.animation_finished
    door["open"] = opening
    door["busy"] = false
    if rolling:
        rollup_unit.stop_door_motion()
    else:
        blocker.set_deferred("collision_layer", 0 if opening else 1)
    state["doors"][door["id"]] = opening
    save_game()

func save_game() -> bool:
    if not is_instance_valid(player) or state.is_empty():
        return true
    var p := player.position
    state["position"] = [p.x, p.y, p.z]
    state["rotation"] = visual.rotation.y
    state["camera_yaw"] = camera_yaw
    state["camera_pitch"] = camera_pitch
    if is_instance_valid(household) and household.placement_complete and household.items.size() == HouseholdProps.DEFINITIONS.size():
        state["props"] = household.snapshot()
        state["prop_layout"] = HouseholdProps.LAYOUT_VERSION
    if not Saves.write_slot(state):
        push_warning("Unable to write save slot.")
        return false
    return true

func _notification(what: int) -> void:
    if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
        camera_touch = -1
        if not mobile and is_instance_valid(player):
            Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    if what == NOTIFICATION_APPLICATION_FOCUS_IN and not mobile and is_instance_valid(player) and not camera_mouse_paused and DisplayServer.get_name() != "headless":
        Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
    if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
        save_game()
    if what == NOTIFICATION_WM_GO_BACK_REQUEST and is_instance_valid(player):
        save_game()
        get_tree().quit()

func _smoke() -> void:
    var updater := get_node_or_null("PatchableUpdater")
    var bootstrap := get_tree().root.get_node_or_null("UpdateManager")
    if updater == null or bootstrap == null or int(updater.get("_current_build")) < int(bootstrap.get("_current_build")):
        push_error("Patchable updater bridge did not preserve active build")
        get_tree().quit(1)
        return
    var initial := Saves.new_slot()
    start_game(initial)
    await get_tree().process_frame
    if not is_instance_valid(player) or animator == null or walk == &"" or idle == &"" or doors.size() != 5 or not avatar_ready:
        push_error("Player, animations, or units failed to initialize")
        get_tree().quit(1)
        return
    if natural_gait == null or not natural_gait.ready:
        push_error("Footstep-driven gait did not initialize")
        get_tree().quit(1)
        return
    if direction_clips.size() != 8 or directional_rig == null or secondary_collision == null or secondary_collision.groups["HAIR"].is_empty():
        push_error("Directional animation or hair rig failed to initialize")
        get_tree().quit(1)
        return
    # Verify directions classify distinctly and authored clips actually
    # animate the target's thigh. No rendering-dependent assertions.
    var smoke_thigh: int = retargeter.target_keys["leftUpperLeg"]
    var back_clip: StringName = direction_clips["bwd"]
    directional_animator.play(back_clip)
    directional_animator.advance(0.0)
    directional_rig.apply_pose()
    var backward_before := retargeter.target.get_bone_pose_rotation(smoke_thigh)
    directional_animator.advance(0.25)
    directional_rig.apply_pose()
    if backward_before.angle_to(retargeter.target.get_bone_pose_rotation(smoke_thigh)) < 0.01 or gait_suffix(Vector3(0, 0, -1)) != "bwd" or gait_suffix(Vector3(1, 0, 0)) not in ["l", "r"]:
        push_error("Directional locomotion retarget regression")
        get_tree().quit(1)
        return
    # Every heading, including directly behind the player, turns by the
    # shorter arc without the old rear-sector discontinuity.
    var turn := smooth_travel_turn(deg_to_rad(179.0), deg_to_rad(-179.0), 1.0 / 60.0)
    var turn_step := angle_difference(deg_to_rad(179.0), turn)
    if turn_step <= 0.0 or turn_step > deg_to_rad(2.0) or absf(angle_difference(travel_yaw(Vector3.RIGHT), PI * 0.5)) > 0.001 or absf(angle_difference(travel_yaw(Vector3.BACK), 0.0)) > 0.001 or absf(angle_difference(travel_yaw(Vector3.FORWARD), PI)) > 0.001:
        push_error("Shortest-arc travel turning regression")
        get_tree().quit(1)
        return
    # Sample the actual forward clip after the arm constraint. Both arms
    # must retain visible sagittal motion instead of a static A-pose.
    animator.play(walk)
    animator.advance(0.0)
    var arm_min := {"left": INF, "right": INF}
    var arm_max := {"left": -INF, "right": -INF}
    for frame in range(120):
        animator.advance(animator.get_animation(walk).length / 60.0)
        retargeter.apply_pose()
        # Match the gameplay pose pipeline and the clip preparation.
        natural_gait.limit_torso(1.0)
        natural_gait.keep_arms_clear(1.0 / 60.0, SPEED, false, "walk", animator.current_animation_position / animator.get_animation(walk).length)
        if frame >= 60:
            for side in ["left", "right"]:
                var arm: int = retargeter.target_keys[side + "UpperArm"]
                var elbow: int = retargeter.target_keys[side + "LowerArm"]
                var axis := retargeter.target_basis * (retargeter.target.get_bone_global_pose(elbow).origin - retargeter.target.get_bone_global_pose(arm).origin)
                var swing := atan2(axis.z, -axis.y)
                arm_min[side] = minf(float(arm_min[side]), swing)
                arm_max[side] = maxf(float(arm_max[side]), swing)
    for side in ["left", "right"]:
        var range_degrees := rad_to_deg(float(arm_max[side]) - float(arm_min[side]))
        print("ARM_SWING ", side, " degrees=", range_degrees)
        if range_degrees < 12.0:
            push_error("Arm motion is too stiff: " + side)
            get_tree().quit(1)
            return
    if carry_reverse_mode(-0.2, false) or not carry_reverse_mode(-0.8, false) or not carry_reverse_mode(-0.2, true) or carry_reverse_mode(0.8, true):
        push_error("Carry forward/backward hysteresis regression")
        get_tree().quit(1)
        return
    if natural_gait.hand_frames.size() != 2 or natural_gait.hand_points("left").size() < 5 or natural_gait.hand_points("right").size() < 5:
        push_error("Anatomical hand rig failed to initialize")
        get_tree().quit(1)
        return
    # Check free-hand local FK stability across a full idle cycle and
    # ensure the carrying layer does not replace the aiming arm.
    animator.play(idle)
    animator.advance(0.0)
    var idle_wrist_max := 0.0
    var idle_overlap := 0.0
    var idle_compression := 0.0
    var idle_abduction := 0.0
    for frame in range(120):
        animator.advance(1.0 / 60.0)
        retargeter.apply_pose()
        natural_gait.limit_torso(0.0)
        natural_gait.keep_arms_clear(1.0 / 60.0, 0.0, false, "idle", animator.current_animation_position / animator.get_animation(idle).length)
        secondary_collision.tick(1.0 / 60.0, natural_gait, false)
        if frame >= 60:
            idle_compression = maxf(idle_compression, secondary_collision.last_contact_compression)
            idle_overlap = maxf(idle_overlap, secondary_collision.last_contact_overlap)
            for side in ["left", "right"]:
                var hand: int = retargeter.target_keys[side + "Hand"]
                var neutral: Quaternion = natural_gait.idle_neutral[hand]
                idle_wrist_max = maxf(idle_wrist_max, rad_to_deg(neutral.angle_to(retargeter.target.get_bone_pose_rotation(hand))))
                var upper: int = retargeter.target_keys[side + "UpperArm"]
                var lower: int = retargeter.target_keys[side + "LowerArm"]
                var axis := retargeter.target_basis * (retargeter.target.get_bone_global_pose(lower).origin - retargeter.target.get_bone_global_pose(upper).origin)
                idle_abduction = maxf(idle_abduction, rad_to_deg(atan2(absf(axis.x), maxf(0.001, -axis.y))))
    print("FK_IDLE wrist_deviation=", idle_wrist_max, " deformed_clearance_overlap=", idle_overlap, " skirt_compression=", idle_compression, " abduction=", idle_abduction)
    if natural_gait.arm_clips.size() != 3 or secondary_collision.skirt_samples.is_empty() or idle_overlap > 0.025:
        push_error("Prepared idle arm layer missing or exceeds skirt clearance")
        get_tree().quit(1)
        return
    if idle_wrist_max > 12.1:
        push_error("Idle wrist exceeded local retarget limit")
        get_tree().quit(1)
        return
    var fk_test_right_arm: int = retargeter.target_keys["rightUpperArm"]
    var right_before := retargeter.target.get_bone_pose_rotation(fk_test_right_arm)
    natural_gait.keep_arms_clear(1.0 / 60.0, 0.0, true)
    if right_before.angle_to(retargeter.target.get_bone_pose_rotation(fk_test_right_arm)) > 0.001:
        push_error("Free-arm layer modified carrying arm")
        get_tree().quit(1)
        return
    print("DIRECTIONAL_SMOKE_PASS")
    var prop_wait := 0
    while not household.placement_complete and prop_wait < 120:
        await get_tree().physics_frame
        prop_wait += 1
    if household.items.size() != HouseholdProps.DEFINITIONS.size():
        push_error("Household prop placement failed")
        get_tree().quit(1)
        return
    # Untouched items must actually remain at the placed floor locations,
    # not merely exist at the instant the initialization test runs.
    if natural_gait.feet.size() != 2:
        push_error("Gait foot contacts missing")
        get_tree().quit(1)
        return
    var initial_prop_positions: Array[Vector3] = []
    for item in household.items:
        initial_prop_positions.append(item.global_position)
    for i in range(120):
        await get_tree().physics_frame
    for i in range(household.items.size()):
        var item: RigidBody3D = household.items[i]
        if not item.freeze or item.global_position.distance_to(initial_prop_positions[i]) > 0.01 or household.needs_recovery(item):
            push_error("Untouched household prop drifted or escaped")
            get_tree().quit(1)
            return
    # Force an invalid old position and verify recovery returns it to the
    # playable floor without moving or deleting other items.
    var lost: RigidBody3D = household.items[-1]
    lost.global_position = Vector3(3736, -20, 0)
    for i in range(12):
        await get_tree().physics_frame
    if household.needs_recovery(lost) or bool(lost.get_meta("recovering", false)) or not lost.visible or not lost.freeze or lost.collision_layer != HouseholdProps.PROP_LAYER:
        push_error("Escaped prop recovery failed")
        get_tree().quit(1)
        return
    var test_prop: RigidBody3D = household.items[0]
    var fridge := test_prop.get_node_or_null("InteractiveFridge") as Node3D
    if fridge == null or fridge.panels.size() != 2:
        push_error("Refrigerator hinges missing")
        get_tree().quit(1)
        return
    # Isolate the fridge to exercise actual ray picking and both hinge
    # colliders without relying on a particular facility layout.
    set_physics_process(false)
    var saved_fridge_transform := test_prop.global_transform
    test_prop.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 23, 0))
    await get_tree().physics_frame
    await get_tree().physics_frame
    for panel in fridge.panels:
        var origin: Vector3 = test_prop.to_global(panel.position + Vector3(-0.25, 0, 1.0))
        var finish: Vector3 = origin - Vector3(0, 0, 2.0)
        var ray := PhysicsRayQueryParameters3D.create(origin, finish, HouseholdProps.PROP_LAYER)
        var hit := world.get_world_3d().direct_space_state.intersect_ray(ray)
        if hit.is_empty() or household.panel_from_hit(test_prop, hit) != panel:
            push_error("Independent refrigerator door ray selection failed")
            get_tree().quit(1)
            return
    fridge.panels[0].toggle()
    for i in range(65):
        fridge.step(1.0 / 60.0)
        await get_tree().physics_frame
    if fridge.panels[0].angle < 1.6 or not is_zero_approx(fridge.panels[1].angle):
        push_error("Fridge door did not open independently")
        get_tree().quit(1)
        return
    fridge.panels[1].toggle()
    for i in range(65):
        fridge.step(1.0 / 60.0)
        await get_tree().physics_frame
    fridge.panels[0].toggle()
    for i in range(65):
        fridge.step(1.0 / 60.0)
        await get_tree().physics_frame
    if not is_zero_approx(fridge.panels[0].angle) or fridge.panels[1].angle < 1.6:
        push_error("Fridge door close affected the freezer")
        get_tree().quit(1)
        return
    # The visible hinge pins are fixed to the cabinet, and the rotating
    # center knuckles remain coaxial with them even at full opening.
    for panel in fridge.panels:
        var fixed_mount := fridge.get_node(panel.panel_id.capitalize() + "CabinetHinges") as Node3D
        var moving_mount := panel.get_node("DoorHinges") as Node3D
        for index in range(2):
            var pin := fixed_mount.get_node("Pin%d" % index) as MeshInstance3D
            var knuckle := moving_mount.get_node("MovingKnuckle%d" % index) as MeshInstance3D
            if pin.global_position.distance_to(knuckle.global_position) > 0.001:
                push_error("Refrigerator hinge hardware detached")
                get_tree().quit(1)
                return
    # Verify the opaque fixed seam spans both door edges.
    var seam := fridge.get_node("CenterSeamSeal") as MeshInstance3D
    var seam_height := (seam.mesh as BoxMesh).size.y
    if seam_height < 0.02:
        push_error("Refrigerator door seam is not sealed")
        get_tree().quit(1)
        return
    var hinge_state: Dictionary = fridge.snapshot()
    if float(hinge_state.get("freezer", 0.0)) < 1.6:
        push_error("Refrigerator hinge state not captured")
        get_tree().quit(1)
        return
    fridge.reset()
    var cargo: RigidBody3D = household.items[2]
    var cargo_original := cargo.global_transform
    var lower_volume: AABB = fridge.storage.compartments["fridge"]["volume"]
    var cargo_dimensions: Vector3 = cargo.get_meta("dimensions")
    # Place cargo with the door open and the cabinet stationary. Include
    # a realistic 6 mm floor contact offset (the old inset rejected it).
    fridge.panels[0].apply_angle(1.7)
    var cargo_local := Transform3D(Basis.IDENTITY, Vector3(0, lower_volume.position.y + cargo_dimensions.y * 0.5 - 0.006, lower_volume.get_center().z))
    cargo.freeze = true
    cargo.global_transform = test_prop.global_transform * cargo_local
    await get_tree().physics_frame
    if cargo.has_meta("storage_owner"):
        push_error("Open compartment secured cargo prematurely")
        get_tree().quit(1)
        return
    # A moving, held item must also be captured if enclosed at closure.
    household.grab(cargo)
    cargo.freeze = true
    cargo.linear_velocity = Vector3(0.25, 0.0, 0.0)
    var stationary_pose := test_prop.global_transform
    fridge.panels[0].toggle()
    for i in range(65):
        fridge.step(1.0 / 60.0)
        if fridge.panels[0].angle > 0.005 and cargo.has_meta("storage_owner"):
            push_error("Cargo secured before door fully closed")
            get_tree().quit(1)
            return
        await get_tree().physics_frame
    if not test_prop.global_transform.is_equal_approx(stationary_pose) or not cargo.has_meta("storage_owner") or cargo.collision_layer != 0 or not cargo.freeze or not is_zero_approx(cargo.gravity_scale) or is_instance_valid(household.held):
        push_error("Stationary container did not secure moving/held cargo on closure")
        get_tree().quit(1)
        return
    test_prop.global_transform = Transform3D(Basis(Vector3.UP, 0.65), Vector3(1, 23, 0))
    if cargo.get_parent() != fridge.storage or cargo.process_mode != Node.PROCESS_MODE_DISABLED or not cargo.global_transform.is_equal_approx(test_prop.global_transform * cargo_local):
        push_error("Stored item did not follow container transform")
        get_tree().quit(1)
        return
    if not household.stored_outline.meshes.has(cargo) or household.stored_outline.meshes.has(test_prop):
        push_error("Outline must highlight stored cargo, not the container")
        get_tree().quit(1)
        return
    var cargo_record: Dictionary = fridge.storage.serialize_item(cargo)
    if str(cargo_record.get("slot", "")) != "fridge":
        push_error("Stored item save record missing compartment")
        get_tree().quit(1)
        return
    fridge.panels[1].apply_angle(1.7)
    if not cargo.has_meta("storage_owner"):
        push_error("Opening freezer released refrigerator contents")
        get_tree().quit(1)
        return
    fridge.panels[0].apply_angle(1.7)
    if cargo.has_meta("storage_owner") or cargo.get_parent() != household or cargo.process_mode == Node.PROCESS_MODE_DISABLED or cargo.freeze or not is_equal_approx(cargo.gravity_scale, 1.0):
        push_error("Opening refrigerator did not release cargo physics")
        get_tree().quit(1)
        return
    cargo.freeze = true
    cargo.global_transform = cargo_original
    if household.stored_outline.meshes.has(cargo):
        push_error("Removed cargo retained its stored-item outline")
        get_tree().quit(1)
        return
    cargo.linear_velocity = Vector3.ZERO
    cargo.angular_velocity = Vector3.ZERO
    fridge.reset()
    # Test a fixed obstruction with a real floor beneath the dynamic
    # refrigerator. A hinge reaction must move it without cancelling its goal.
    var hinge_probe: Node3D = fridge.panels[0]
    var fridge_dimensions: Vector3 = test_prop.get_meta("dimensions")
    var reaction_floor := wall(world, test_prop.global_position - Vector3.UP * (fridge_dimensions.y * 0.5 + 0.11), Vector3(8, 0.2, 8))
    var swing_point: Vector3 = hinge_probe.to_global(Basis(Vector3.UP, 0.45) * hinge_probe.local_box)
    var hinge_wall := wall(world, swing_point + Vector3(0, 0, 0.04), Vector3(0.12, 0.24, 0.12))
    await get_tree().physics_frame
    await get_tree().physics_frame
    var before_push := test_prop.global_position
    hinge_probe.toggle()
    for i in range(180):
        fridge.step(1.0 / 60.0)
        await get_tree().physics_frame
        if not hinge_probe.busy:
            break
    if hinge_probe.goal < 1.6 or test_prop.freeze or test_prop.global_position.distance_to(before_push) < 0.005:
        push_error("Obstructed hinge cancelled or failed to apply cabinet reaction")
        get_tree().quit(1)
        return
    hinge_wall.queue_free()
    reaction_floor.queue_free()
    test_prop.freeze = true
    test_prop.linear_velocity = Vector3.ZERO
    test_prop.angular_velocity = Vector3.ZERO
    fridge.reset()
    # Face-down regression: the floor must generate an upward reaction
    # with a torque, rather than the previous horizontal-only displacement.
    var face_fixture := Vector3(0, 26, 0)
    var face_floor := wall(world, face_fixture - Vector3.UP * 0.10, Vector3(10, 0.2, 10))
    test_prop.global_transform = Transform3D(Basis(Vector3.RIGHT, PI * 0.5), face_fixture + Vector3.UP * (fridge_dimensions.z * 0.5 + 0.008))
    await get_tree().physics_frame
    await get_tree().physics_frame
    var face_start := test_prop.global_transform
    hinge_probe.toggle()
    var max_lift := 0.0
    var max_tilt := 0.0
    var paused_ticks := 0
    var previous_angle: float = hinge_probe.angle
    var elapsed_ticks := 0
    for i in range(120):
        fridge.step(1.0 / 60.0)
        elapsed_ticks += 1
        if absf(float(hinge_probe.angle) - previous_angle) < 0.0001 and hinge_probe.busy:
            paused_ticks += 1
        previous_angle = hinge_probe.angle
        await get_tree().physics_frame
        max_lift = maxf(max_lift, test_prop.global_position.y - face_start.origin.y)
        max_tilt = maxf(max_tilt, face_start.basis.get_rotation_quaternion().angle_to(test_prop.global_transform.basis.get_rotation_quaternion()))
        if not hinge_probe.busy:
            break
    print("HINGE_FACE_DOWN ticks=", elapsed_ticks, " paused=", paused_ticks, " lift=", max_lift, " tilt=", max_tilt)
    # A free door needs 53 ticks at 60 Hz. Allow a small tolerance for
    # transient solver contacts, but reject the old push/wait behavior.
    if hinge_probe.busy or hinge_probe.angle < 1.82 or test_prop.freeze or max_lift < 0.008 or max_tilt < 0.015 or elapsed_ticks > 63 or paused_ticks > 10:
        push_error("Face-down hinge failed continuous opening: ticks=%d pauses=%d lift=%f tilt=%f" % [elapsed_ticks, paused_ticks, max_lift, max_tilt])
        get_tree().quit(1)
        return
    face_floor.queue_free()
    test_prop.freeze = true
    test_prop.linear_velocity = Vector3.ZERO
    test_prop.angular_velocity = Vector3.ZERO
    fridge.reset()
    test_prop.global_transform = saved_fridge_transform
    await get_tree().physics_frame
    await get_tree().physics_frame
    set_physics_process(true)
    household.grab(test_prop)
    if test_prop.freeze or not is_zero_approx(test_prop.gravity_scale):
        push_error("Grab did not disable gravity")
        get_tree().quit(1)
        return
    var right_arm: int = retargeter.target_keys["rightUpperArm"]
    var arm_before := retargeter.target.get_bone_pose_rotation(right_arm)
    retargeter.apply_force_pose(player.global_position + Vector3(1, 1.5, 1), 1.0)
    if arm_before.angle_to(retargeter.target.get_bone_pose_rotation(right_arm)) < 0.01:
        push_error("Right-arm grab pose failed")
        get_tree().quit(1)
        return
    var original_prop_position := test_prop.global_position
    var original_prop_rotation := test_prop.rotation
    test_prop.linear_velocity = Vector3.ZERO
    household.pull_toward(original_prop_position + Vector3.UP * 2.0, 1.0 / 60.0)
    if not test_prop.global_position.is_equal_approx(original_prop_position) or test_prop.linear_velocity.length() > 0.81:
        push_error("Grab teleported or exceeded the pull acceleration limit")
        get_tree().quit(1)
        return
    test_prop.linear_velocity = Vector3(2, 1, 0)
    household.drop()
    if test_prop.freeze or not is_equal_approx(test_prop.gravity_scale, 1.0) or not test_prop.linear_velocity.is_equal_approx(Vector3(2, 1, 0)):
        push_error("Drop did not restore gravity and momentum")
        get_tree().quit(1)
        return
    test_prop.linear_velocity = Vector3.ZERO
    # Exercise the actual dynamic grab solver against a test floor and wall,
    # isolated from the facility and the camera-driven main physics loop.
    set_physics_process(false)
    var pull_fixture := Node3D.new()
    world.add_child(pull_fixture)
    pull_fixture.position = Vector3(0, 24, 0)
    wall(pull_fixture, Vector3(0, -0.2, 0), Vector3(8, 0.4, 8))
    wall(pull_fixture, Vector3(2.0, 2.0, 0), Vector3(0.2, 4, 8))
    var size: Vector3 = test_prop.get_meta("dimensions")
    test_prop.freeze = true
    test_prop.rotation = Vector3.ZERO
    test_prop.global_position = pull_fixture.global_position + Vector3(0, size.y * 0.5 + 0.15, 0)
    await get_tree().physics_frame
    await get_tree().physics_frame
    household.grab(test_prop)
    for i in range(60):
        household.pull_toward(pull_fixture.global_position + Vector3(4, -2, 0), 1.0 / 60.0)
        await get_tree().physics_frame
    var local_prop := pull_fixture.to_local(test_prop.global_position)
    if local_prop.y < size.y * 0.5 - 0.035 or local_prop.x > 1.9 - size.x * 0.5 + 0.035:
        push_error("Grab penetrated a solid floor or wall")
        get_tree().quit(1)
        return
    household.drop()
    test_prop.freeze = true
    test_prop.global_position = original_prop_position
    test_prop.rotation = original_prop_rotation
    test_prop.linear_velocity = Vector3.ZERO
    test_prop.angular_velocity = Vector3.ZERO
    pull_fixture.queue_free()
    await get_tree().physics_frame
    test_prop.freeze = false
    set_physics_process(true)
    var thigh: int = retargeter.target_keys["leftUpperLeg"]
    animator.play(walk)
    animator.advance(0.0)
    retargeter.apply_pose()
    var pose_before: Quaternion = retargeter.target.get_bone_pose_rotation(thigh)
    animator.advance(0.23)
    retargeter.apply_pose()
    var pose_after: Quaternion = retargeter.target.get_bone_pose_rotation(thigh)
    if pose_before.angle_to(pose_after) < 0.01:
        push_error("Shino walking animation did not move the mapped thigh")
        get_tree().quit(1)
        return
    animator.play(idle)
    for door in doors:
        if named_animation(door["player"], "open") == &"" or named_animation(door["player"], "close") == &"":
            push_error("Door clips missing")
            get_tree().quit(1)
            return
    var saved := Saves.read_slot(str(initial["id"]))
    if saved.is_empty() or saved["position"].size() != 3:
        push_error("Save round trip failed")
        get_tree().quit(1)
        return
    var second := Saves.new_slot()
    if second["id"] == initial["id"] or not Saves.write_slot(second) or Saves.read_slot(str(second["id"])).is_empty() or Saves.read_slot(str(initial["id"])).is_empty():
        push_error("Independent save slots failed")
        get_tree().quit(1)
        return
    nearby = 0
    use_nearby()
    var elapsed := 0.0
    while doors[0]["busy"] and elapsed < 10:
        await get_tree().process_frame
        elapsed += get_process_delta_time()
    if not doors[0]["open"] or not Saves.read_slot(str(initial["id"])).get("doors", {}).get("unit_00", false):
        push_error("Door interaction or persistence failed")
        get_tree().quit(1)
        return
    # Exercise the new door through the same interaction and save pipeline.
    var roll_index := doors.size() - 1
    nearby = roll_index
    use_nearby()
    elapsed = 0.0
    var observed_partial := false
    while doors[roll_index]["busy"] and elapsed < 10.0:
        await get_tree().physics_frame
        elapsed += get_physics_process_delta_time()
        if rollup_unit.opening > 0.2 and rollup_unit.opening < 0.6:
            var physical_bottom: float = rollup_unit.blocker.position.y - rollup_unit.blocker_shape.size.y * 0.5
            if absf(physical_bottom - rollup_unit.bottom_edge) > 0.002 or rollup_unit.blocker.collision_layer != 1:
                push_error("Rising curtain collider does not follow the bar")
                get_tree().quit(1)
                return
            observed_partial = true
    if not observed_partial or rollup_unit.blocker.collision_layer != 0:
        push_error("Door collision did not clear during opening")
        get_tree().quit(1)
        return
    if not doors[roll_index]["open"] or not Saves.read_slot(str(initial["id"])).get("doors", {}).get("rollup_00", false):
        push_error("Roll-up door interaction or persistence failed")
        get_tree().quit(1)
        return
    if not is_equal_approx(rollup_unit.opening, 1.0) or not is_equal_approx(rollup_unit.unit_height, reference_unit_height):
        push_error("Roll-up door travel or height mismatch")
        get_tree().quit(1)
        return
    for slat in rollup_unit.slats:
        if slat.position.y < rollup_unit.clear_height - 0.01 or slat.position.y > rollup_unit.unit_height:
            push_error("Rolled curtain outside headroom")
            get_tree().quit(1)
            return
    # Start closing while the actual player stands directly in the doorway.
    var original_player_position := player.global_position
    player.global_position = rollup_unit.to_global(Vector3(0.0, 0.03, 1.43))
    player.velocity = Vector3.ZERO
    await get_tree().physics_frame
    await get_tree().physics_frame
    nearby = roll_index
    use_nearby()
    elapsed = 0.0
    while doors[roll_index]["busy"] and elapsed < 10.0:
        await get_tree().physics_frame
        elapsed += get_physics_process_delta_time()
    var pushed_position: Vector3 = rollup_unit.to_local(player.global_position)
    if absf(pushed_position.z - 1.42) < PLAYER_CAPSULE_RADIUS + 0.045:
        push_error("Closing curtain did not push player clear")
        get_tree().quit(1)
        return
    player.global_position = original_player_position
    player.velocity = Vector3.ZERO
    if doors[roll_index]["open"] or not is_zero_approx(rollup_unit.opening):
        push_error("Roll-up door close regression")
        get_tree().quit(1)
        return
    # Roof is the only shell piece reaching the exterior top plane.
    var roof_mesh := rollup_unit.get_node("Roof") as MeshInstance3D
    var roof_bottom := roof_mesh.position.y - (roof_mesh.mesh as BoxMesh).size.y * 0.5
    for piece_name in ["LeftWall", "RightWall", "BackWall", "FrontFascia"]:
        var piece := rollup_unit.get_node(piece_name) as MeshInstance3D
        var piece_top := piece.position.y + (piece.mesh as BoxMesh).size.y * 0.5
        if not is_equal_approx(piece_top, roof_bottom):
            push_error("Roll-up shell meets roof incorrectly: " + piece_name)
            get_tree().quit(1)
            return
    # Closed slats must overlap instead of leaving see-through seams.
    for i in range(rollup_unit.slats.size() - 1):
        var lower := rollup_unit.slats[i] as Node3D
        var upper := rollup_unit.slats[i + 1] as Node3D
        var lower_sheet := (lower.get_child(0) as MeshInstance3D).mesh as BoxMesh
        var upper_sheet := (upper.get_child(0) as MeshInstance3D).mesh as BoxMesh
        var lower_top := lower.position.y + lower_sheet.size.y * 0.5
        var upper_bottom := upper.position.y - upper_sheet.size.y * 0.5
        if lower_top <= upper_bottom:
            push_error("Closed roll-up curtain has a visible gap")
            get_tree().quit(1)
            return
    # Independent collision fixture above the facility: one ordinary stair
    # riser and one full wall. Exercise the same sweep used during gameplay.
    var fixture := Node3D.new()
    world.add_child(fixture)
    fixture.position = Vector3(0, 20, 0)
    wall(fixture, Vector3(0, -0.1, 0), Vector3(10, 0.2, 10))
    wall(fixture, Vector3(0.8, 0.10, 0), Vector3(0.6, 0.2, 2))
    wall(fixture, Vector3(-0.8, 0.75, 0), Vector3(0.6, 1.5, 2))
    var probe := CharacterBody3D.new()
    fixture.add_child(probe)
    var probe_collision := CollisionShape3D.new()
    var probe_capsule := CapsuleShape3D.new()
    probe_capsule.radius = 0.27
    probe_capsule.height = 1.65
    probe_collision.shape = probe_capsule
    probe_collision.position.y = 0.825
    probe.add_child(probe_collision)
    probe.position = Vector3(0.18, 0.003, 0)
    await get_tree().physics_frame
    await get_tree().physics_frame
    if not try_step_up(probe, Vector3(0.40, 0, 0)) or probe.position.y < 0.15:
        push_error("Stair step-up regression")
        get_tree().quit(1)
        return
    probe.position = Vector3(-0.18, 0.003, 0)
    if try_step_up(probe, Vector3(-0.40, 0, 0)):
        push_error("Step-up passed through a tall wall")
        get_tree().quit(1)
        return
    # Check that a step cannot move the capsule farther than the requested
    # horizontal displacement and that a compound top lip is also climbable.
    wall(fixture, Vector3(1.4, 0.22, 0), Vector3(0.6, 0.44, 2))
    probe.position = Vector3(0.84, 0.203, 0)
    await get_tree().physics_frame
    await get_tree().physics_frame
    if not try_step_up(probe, Vector3(0.40, 0, 0)) or probe.position.y < 0.38 or probe.position.x > 1.241:
        push_error("Top landing or horizontal step distance regression")
        get_tree().quit(1)
        return
    fixture.queue_free()
    # Isolated camera collision fixture: a floor and an obstruction behind
    # the target. This also tests the full unobstructed distance above it.
    var camera_fixture := Node3D.new()
    world.add_child(camera_fixture)
    camera_fixture.position = Vector3(0, 27, 0)
    wall(camera_fixture, Vector3(0, -0.1, 0), Vector3(8, 0.2, 8))
    var camera_wall := wall(camera_fixture, Vector3(0, 1.1, 1.4), Vector3(4, 3, 0.2))
    await get_tree().physics_frame
    await get_tree().physics_frame
    var pivot := camera_fixture.global_position + Vector3.UP * 1.1
    var down_distance := camera_clear_distance(pivot, Vector3.DOWN)
    var wall_distance := camera_clear_distance(pivot, Vector3.BACK)
    var up_distance := camera_clear_distance(pivot, Vector3.UP)
    if down_distance < 0.65 or down_distance > 1.0 or wall_distance < 0.85 or wall_distance > 1.2 or not is_equal_approx(up_distance, CAMERA_DISTANCE):
        push_error("Camera sweep failed floor/wall/open-space clearance")
        get_tree().quit(1)
        return
    camera_wall.queue_free()
    await get_tree().physics_frame
    await get_tree().physics_frame
    if not is_equal_approx(camera_clear_distance(pivot, Vector3.BACK), CAMERA_DISTANCE):
        push_error("Camera did not recover unobstructed radius")
        get_tree().quit(1)
        return
    camera_fixture.queue_free()
    var original_pitch := camera_pitch
    orbit_camera(Vector2(0, -10000))
    if not is_equal_approx(camera_pitch, -CAMERA_PITCH_LIMIT):
        push_error("Downward camera orbit range regression")
        get_tree().quit(1)
        return
    orbit_camera(Vector2(0, 20000))
    if not is_equal_approx(camera_pitch, CAMERA_PITCH_LIMIT):
        push_error("Upward camera orbit range regression")
        get_tree().quit(1)
        return
    camera_pitch = original_pitch
    var original_yaw := camera_yaw
    orbit_camera(Vector2(100, 50))
    if is_equal_approx(original_yaw, camera_yaw):
        push_error("Camera orbit regression")
        get_tree().quit(1)
        return
    update_camera(0.0)
    var orbit_direction := (camera.position - camera_target).normalized()
    if not is_equal_approx(camera.position.distance_to(camera_target), camera_clear_distance(camera_target, orbit_direction)):
        push_error("Camera collision-adjusted orbit radius regression")
        get_tree().quit(1)
        return
    save_game()
    if not is_equal_approx(float(Saves.read_slot(str(initial["id"])).get("camera_yaw", 99.0)), camera_yaw):
        push_error("Camera orientation persistence regression")
        get_tree().quit(1)
        return
    print("STORAGE_SMOKE_PASS")
    get_tree().quit()
