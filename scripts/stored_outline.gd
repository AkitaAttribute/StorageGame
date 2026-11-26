extends Node
## Render only contained-item meshes to an independent silhouette mask.
## Walls, cabinet meshes and the player never enter this pass.
const MASK_LAYER := 1 << 19
var mask_view: SubViewport
var mask_camera: Camera3D
var source_camera: Camera3D
var output: TextureRect
var mask_material: StandardMaterial3D
var meshes: Dictionary = {}

func setup(view: Camera3D, hud: Control) -> void:
    source_camera = view
    source_camera.cull_mask = source_camera.cull_mask & ~MASK_LAYER
    mask_view = SubViewport.new()
    mask_view.name = "StoredItemMask"
    mask_view.world_3d = view.get_world_3d()
    mask_view.transparent_bg = true
    mask_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
    mask_view.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
    mask_view.size = Vector2i(view.get_viewport().get_visible_rect().size)
    add_child(mask_view)
    mask_camera = Camera3D.new()
    mask_camera.cull_mask = MASK_LAYER
    var env := Environment.new()
    env.background_mode = Environment.BG_COLOR
    env.background_color = Color.BLACK
    mask_camera.environment = env
    mask_view.add_child(mask_camera)
    mask_camera.current = true
    mask_material = StandardMaterial3D.new()
    mask_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    mask_material.albedo_color = Color.WHITE
    mask_material.cull_mode = BaseMaterial3D.CULL_DISABLED
    var shader := Shader.new()
    shader.code = """
shader_type canvas_item;
render_mode unshaded;
void fragment() {
    float center = texture(TEXTURE, UV).r;
    float edge = 0.0;
    vec2 px = TEXTURE_PIXEL_SIZE * 2.0;
    for (int i = 0; i < 8; i++) {
        float a = float(i) * 0.78539816;
        edge = max(edge, texture(TEXTURE, UV + vec2(cos(a), sin(a)) * px).r);
    }
    float border = smoothstep(0.05, 0.65, max(0.0, edge - center));
    COLOR = vec4(0.12, 0.95, 1.0, border);
}
"""
    var mat := ShaderMaterial.new()
    mat.shader = shader
    output = TextureRect.new()
    output.name = "StoredItemOutline"
    output.texture = mask_view.get_texture()
    output.material = mat
    output.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    output.stretch_mode = TextureRect.STRETCH_SCALE
    output.mouse_filter = Control.MOUSE_FILTER_IGNORE
    hud.add_child(output)
    hud.move_child(output, 0)
    output.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    output.hide()

func track(item: RigidBody3D) -> void:
    if meshes.has(item):
        return
    var copies: Array[MeshInstance3D] = []
    for node in item.find_children("*", "MeshInstance3D", true, false):
        var original := node as MeshInstance3D
        if original.mesh == null or original.has_meta("stored_mask"):
            continue
        var copy := MeshInstance3D.new()
        copy.name = "StoredSilhouette"
        copy.mesh = original.mesh
        copy.material_override = mask_material
        copy.layers = MASK_LAYER
        copy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        copy.set_meta("stored_mask", true)
        original.add_child(copy)
        copies.append(copy)
    meshes[item] = copies

func untrack(item: RigidBody3D) -> void:
    for copy in meshes[item]:
        if is_instance_valid(copy):
            copy.hide()
            copy.queue_free()
    meshes.erase(item)

func sync(contained: Array[RigidBody3D]) -> void:
    for item in meshes.keys():
        if not is_instance_valid(item) or not contained.has(item):
            untrack(item)
    for item in contained:
        if is_instance_valid(item):
            track(item)
    var active := not meshes.is_empty()
    output.visible = active
    mask_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED
    sync_camera()

# Only the rendering camera needs to follow the player's view continuously.
# The set of rendered cargo meshes changes exclusively on storage events.
func sync_camera() -> void:
    if meshes.is_empty():
        return
    var resolution := Vector2i(source_camera.get_viewport().get_visible_rect().size)
    if resolution.x > 0 and resolution.y > 0 and mask_view.size != resolution:
        mask_view.size = resolution
    mask_camera.global_transform = source_camera.global_transform
    mask_camera.projection = source_camera.projection
    mask_camera.fov = source_camera.fov
    mask_camera.size = source_camera.size
    mask_camera.near = source_camera.near
    mask_camera.far = source_camera.far
    mask_camera.keep_aspect = source_camera.keep_aspect
