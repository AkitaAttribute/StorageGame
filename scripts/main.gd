extends Node

const Saves = preload("res://scripts/save_store.gd")
const FACILITY := "res://assets/facility.glb"
const UNIT := "res://assets/unit.glb"
const CHARACTER := "res://assets/player.glb"
const SPEED := 3.4
const REACH := 2.0
var state: Dictionary = {}
var doors: Array[Dictionary] = []
var world: Node3D
var player: CharacterBody3D
var visual: Node3D
var animator: AnimationPlayer
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
    for pair in [["move_up", KEY_W], ["move_down", KEY_S], ["move_left", KEY_A], ["move_right", KEY_D], ["use", KEY_E]]:
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
    for path in [FACILITY, UNIT, CHARACTER]:
        if not ResourceLoader.exists(path):
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
    ground.create_trimesh_collision()
    var facility := model(FACILITY, world)
    add_static_mesh_collisions(facility)
    # Starter scene is static. An additional row uses the pack's actual
    # animated, standalone units, with per-door collision and persistent IDs.
    for i in range(4):
        make_unit("unit_%02d" % i, Vector3(-13.0, 0, -4.5 + i * 3.15))
    player = CharacterBody3D.new()
    player.name = "Player"
    player.floor_snap_length = 0.24
    world.add_child(player)
    var collision := CollisionShape3D.new()
    var capsule := CapsuleShape3D.new()
    capsule.radius = 0.27
    capsule.height = 1.65
    collision.shape = capsule
    collision.position.y = 0.825
    player.add_child(collision)
    visual = model(CHARACTER, player)
    # Normalize the character's height without modifying its skin or rig.
    var bounds := model_bounds(visual)
    if bounds.size.y > 0.01:
        var factor := 1.7 / bounds.size.y
        visual.scale = Vector3.ONE * factor
        visual.position.y = -bounds.position.y * factor
    animator = animation_in(visual)
    walk = named_animation(animator, "walking_a")
    if walk == &"":
        walk = named_animation(animator, "walk")
    idle = named_animation(animator, "idle")
    if animator != null:
        for clip in [walk, idle]:
            if clip != &"":
                animator.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
        if idle != &"":
            animator.play(idle)
    var p: Array = state["position"]
    player.position = Vector3(float(p[0]), float(p[1]), float(p[2]))
    visual.rotation.y = float(state.get("rotation", 0.0))
    camera = Camera3D.new()
    camera.fov = 65
    world.add_child(camera)
    camera.current = true
    camera.position = player.position + Vector3(0, 4.8, 7.0)
    camera.look_at(player.position + Vector3.UP)
    create_hud()
    save_game()

func add_static_mesh_collisions(node: Node) -> void:
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

func _input(event: InputEvent) -> void:
    if not is_instance_valid(player):
        return
    if event is InputEventScreenTouch and event.pressed and mobile and is_instance_valid(use_button) and use_button.visible:
        if use_button.get_global_rect().has_point(event.position):
            use_nearby()
            get_viewport().set_input_as_handled()

func _physics_process(delta: float) -> void:
    if not is_instance_valid(player):
        return
    var input := Input.get_vector("move_left", "move_right", "move_up", "move_down")
    var direction := Vector3(input.x, 0, input.y)
    player.velocity.x = direction.x * SPEED
    player.velocity.z = direction.z * SPEED
    if not player.is_on_floor():
        player.velocity.y -= 18.0 * delta
    else:
        player.velocity.y = -0.1
    player.move_and_slide()
    player.position.x = clampf(player.position.x, -29, 29)
    player.position.z = clampf(player.position.z, -29, 29)
    if player.position.y < -5:
        player.position = Vector3(-10.4, 0.1, 5)
    if direction.length() > 0.05:
        visual.rotation.y = lerp_angle(visual.rotation.y, atan2(direction.x, direction.z), minf(1.0, delta * 14.0))
    if animator != null:
        var clip := walk if direction.length() > 0.05 else idle
        if clip != &"" and animator.current_animation != clip:
            animator.play(clip, 0.12)
    camera.position = camera.position.lerp(player.position + Vector3(0, 4.8, 7), minf(1, delta * 9))
    camera.look_at(player.position + Vector3.UP)
    update_nearby()
    if Input.is_action_just_pressed("use"):
        use_nearby()
    save_clock += delta
    if save_clock >= 2.0:
        save_clock = 0
        save_game()

func update_nearby() -> void:
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
    if nearby < 0 or nearby >= doors.size():
        return
    var door: Dictionary = doors[nearby]
    if door["busy"]:
        return
    var ap: AnimationPlayer = door["player"]
    var opening := not bool(door["open"])
    var node: Node3D = door["node"]
    var local := node.to_local(player.position)
    if not opening and absf(local.z - 1.42) < 0.55 and absf(local.x) < 1.6:
        return
    var clip := named_animation(ap, "open" if opening else "close")
    if clip == &"":
        return
    door["busy"] = true
    var blocker: StaticBody3D = door["blocker"]
    if not opening:
        blocker.set_deferred("collision_layer", 1)
    ap.stop()
    ap.get_animation(clip).loop_mode = Animation.LOOP_NONE
    ap.play(clip)
    await ap.animation_finished
    door["open"] = opening
    door["busy"] = false
    blocker.set_deferred("collision_layer", 0 if opening else 1)
    state["doors"][door["id"]] = opening
    save_game()

func save_game() -> void:
    if not is_instance_valid(player) or state.is_empty():
        return
    var p := player.position
    state["position"] = [p.x, p.y, p.z]
    state["rotation"] = visual.rotation.y
    if not Saves.write_slot(state):
        push_warning("Unable to write save slot.")

func _notification(what: int) -> void:
    if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
        save_game()
    if what == NOTIFICATION_WM_GO_BACK_REQUEST and is_instance_valid(player):
        save_game()
        get_tree().quit()

func _smoke() -> void:
    var initial := Saves.new_slot()
    start_game(initial)
    await get_tree().process_frame
    if not is_instance_valid(player) or animator == null or walk == &"" or idle == &"" or doors.size() != 4:
        push_error("Player, animations, or units failed to initialize")
        get_tree().quit(1)
        return
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
    print("STORAGE_SMOKE_PASS")
    get_tree().quit()
