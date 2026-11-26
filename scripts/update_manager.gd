extends Node
## Immutable startup bootstrap: mount the chosen patch before loading the main
## scene. All network/UI/install behavior lives in scripts/update_runtime.gd.
const CHANNEL := "storage-preview"
const UPDATE_DIR := "user://updates"
const INSTALLED_METADATA := "user://updates/installed.json"

var _installed_pack_path := ""
var _current_build := 0

func _init() -> void:
    _load_installed_pack()

func _ready() -> void:
    _current_build = _embedded_build()
    if not _installed_pack_path.is_empty():
        _current_build = maxi(_current_build, int(_read_installed_metadata().get("build", 0)))

func _embedded_build() -> int:
    var version := str(ProjectSettings.get_setting("application/config/version", "0.1.0"))
    return version.get_slice(".", 2).to_int()

func _read_installed_metadata() -> Dictionary:
    if not FileAccess.file_exists(INSTALLED_METADATA):
        return {}
    var file := FileAccess.open(INSTALLED_METADATA, FileAccess.READ)
    if file == null:
        return {}
    var parsed: Variant = JSON.parse_string(file.get_as_text())
    if typeof(parsed) != TYPE_DICTIONARY:
        return {}
    return parsed as Dictionary

func _load_installed_pack() -> void:
    var installed := _read_installed_metadata()
    if str(installed.get("channel", "")) != CHANNEL:
        return

    # Important for in-place Windows/Android recovery: the newest full
    # executable or APK must take precedence over a previously downloaded PCK.
    # Otherwise an installed (possibly broken) patch can override newly fixed
    # scripts on every startup, even after a full application update.
    var installed_build := int(installed.get("build", 0))
    var bundled_build := _embedded_build()
    if bundled_build > 0 and installed_build <= bundled_build:
        print(
            "Storage Game: skipping previous update pack build ",
            installed_build,
            "; bundled app build ",
            bundled_build,
            " is newer or equal."
        )
        return

    var path := str(installed.get("path", ""))
    if not path.begins_with(UPDATE_DIR + "/") or not path.ends_with(".pck"):
        return
    if not FileAccess.file_exists(path):
        push_warning("Storage Game update pack missing: " + path)
        return
    if ProjectSettings.load_resource_pack(ProjectSettings.globalize_path(path), true):
        _installed_pack_path = path
        print("Storage Game: loaded preview patch ", path)
    else:
        push_error("Storage Game: failed to load update " + path + "; starting bundled version.")

